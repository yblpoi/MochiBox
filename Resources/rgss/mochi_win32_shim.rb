# -*- coding: utf-8 -*-
# frozen_string_literal: false
#
# MochiBox —— Win32API Ruby shim（XP / VX / VX Ace 共用）
#
# 解决什么：
#   mkxp-z 在 macOS 上确实注册了 Win32API（rb_define_const(rb_cObject, "Win32API",
#   cMiniFFI)，与 MiniFFI 是**同一个类对象**），但它的 .new 走 dlopen，把 'kernel32'
#   当成**相对路径**拼到 cwd：
#
#     RuntimeError: Failed loading /private/tmp/win32probe/kernel32:
#       dlopen(/private/tmp/win32probe/kernel32, 0x0006): tried:
#       '/private/tmp/win32probe/kernel32' (no such file), ...
#
#   user32 同理，libc.dylib 也会被拼成相对路径。于是任何一用 Win32API 的国产
#   XP/VX 游戏都在 Win32API.new 阶段就崩，游戏脚本根本没机会跑。这是
#   docs/rpgmaker-classic-compat.md「mkxp-z 跑不动依赖 Win32API / 外部 DLL 的国产
#   游戏」的根因层。
#
# 做法（不改 mkxp-z 二进制）：
#   在 preload 阶段 reopen Win32API（也就是 MiniFFI）的单例方法 new，换成纯 Ruby
#   分派：按 (dll, func) 查本文件的 handler 注册表；命中就调用对应的 Ruby 实现，
#   未命中则按 exports 类型返回安全默认（P→""、L/N/I→0、V→nil、其余 0）并记一次
#   日志。**任何路径都不 raise**，避免把「不兼容」变回「启动崩溃」。
#   覆盖只影响之后的 Win32API.new；覆盖前保存的旧 method(:new) 仍会抛原
#   RuntimeError（实测），所以不需要动二进制，也不影响其它 MiniFFI 语义。
#
# 安装：
#   Resources/rgss/mochi_rgss_hook.rb 在**文件顶部**（早于 MOCHI_RGSS_HOOK=off 的
#   提前返回）load 本文件并调用 MochiWin32Shim.install!；也就是说翻译通道关掉时
#   shim 仍然生效。也可以把本文件单独放进 mkxp.json 的 preloadScript（文件末尾会
#   自动 install!）。
#
# 环境变量：
#   MOCHI_WIN32_SHIM=off   完全不安装（Win32API 恢复原行为：用即崩，仅用于对照）
#   MOCHI_RGSS_LOG=...     日志路径，默认 /tmp/mochi-rgss.log（超过 1 MB 自动截断）
#
# 日志前缀 [win32]，与 hook 的 [mochi-rgss] 共用同一个文件。
#
# 约束：
#   * 纯 Ruby，不 require gem；只读写 INI 与日志。
#   * 同时兼容 Ruby 2.6（Tests 里的单测）与 Ruby 3.1（mkxp-z）。不用 endless
#     method / pattern matching / 3.x 专属语法。
#   * 幂等：重复 load / 重复 install! 不会重复覆盖、不会重复初始化常量。
#   * 每个 handler 自己 rescue，dispatch 再兜一层；imports/exports 为 String、
#     Array、Integer、nil 等任意形状都不许 raise。
#
# 详见 docs/win32-shim.md（支持矩阵、安全降级、已知限制、验证命令）。

module MochiWin32Shim
  VERSION = '0.1.0' unless const_defined?(:VERSION, false)

  # 与 hook 一致：日志超过 1 MB 就截断，避免长跑游戏把磁盘写满。
  LOG_MAX_BYTES = 1024 * 1024 unless const_defined?(:LOG_MAX_BYTES, false)

  # 单条日志里参数值/命令文本的最大长度。参数可能含路径、密钥等敏感数据，
  # 一律截断，绝不整段输出。
  LOG_VALUE_MAX = 24 unless const_defined?(:LOG_VALUE_MAX, false)

  # Sleep 的单次上限（毫秒）。商业脚本常用 Sleep(1) 做帧节流，但也有拿它做
  # 长等待的；封顶避免 shim 把游戏主线程卡死。
  SLEEP_MAX_MS = 16 unless const_defined?(:SLEEP_MAX_MS, false)

  # exports 单字符类型码 → 安全默认类型。
  #   P=pointer → ""；L/N/I=整数 → 0；V=void → nil；其余按 0 处理。
  EXPORT_TYPES = {
    'p' => :string,
    'l' => :int,
    'n' => :int,
    'i' => :int,
    'v' => :void,
    'q' => :int,
    'h' => :int,
    'f' => :float,
    'd' => :float,
    'b' => :int,
    'c' => :int
  }.freeze unless const_defined?(:EXPORT_TYPES, false)

  # imports/exports 用**整数**类型码传入时的映射（老 Win32API 允许整数常量）。
  # 只是「可以接受」的兼容映射，不承诺与某个 DL 常量表逐位一致。
  INTEGER_TYPE_CODES = {
    0 => 'v', 1 => 'i', 2 => 'l', 3 => 'p', 4 => 'n', 5 => 'q', 6 => 'f', 7 => 'd'
  }.freeze unless const_defined?(:INTEGER_TYPE_CODES, false)

  # DLL 别名。kernelbase 是 kernel32 在 Win8+ 的转发层，函数名一致。
  DLL_ALIASES = { 'kernelbase' => 'kernel32' }.freeze unless const_defined?(:DLL_ALIASES, false)

  # ------------------------------------------------------------------
  # handler 注册表：dll（小写、去目录、去扩展名）→ func（小写）→ 方法名。
  # 测试与排查直接看这张表：新增 API 只改这里 + 一个 handler 方法。
  # A/W 变体共用同一个 handler，由 func 末尾的 'a'/'w' 决定编码。
  # ------------------------------------------------------------------
  HANDLERS = {
    'kernel32' => {
      'getprivateprofilestringa'   => :handle_get_private_profile_string,
      'getprivateprofilestringw'   => :handle_get_private_profile_string,
      'getprivateprofileinta'      => :handle_get_private_profile_int,
      'getprivateprofileintw'      => :handle_get_private_profile_int,
      'writeprivateprofilestringa' => :handle_write_private_profile_string,
      'writeprivateprofilestringw' => :handle_write_private_profile_string,
      'gettickcount'               => :handle_get_tick_count,
      'gettickcount64'             => :handle_get_tick_count_64,
      'sleep'                      => :handle_sleep,
      'queryperformancecounter'    => :handle_query_performance_counter,
      'queryperformancefrequency'  => :handle_query_performance_frequency,
      'getmodulehandlea'           => :handle_get_module_handle,
      'getmodulehandlew'           => :handle_get_module_handle,
      'getmodulefilenamea'         => :handle_get_module_file_name,
      'getmodulefilenamew'         => :handle_get_module_file_name,
      'lstrlena'                   => :handle_lstrlen,
      'lstrlenw'                   => :handle_lstrlen,
      'rtlmovememory'              => :handle_nil,
      'globalalloc'                => :handle_global_alloc,
      'globalfree'                 => :handle_global_free,
      'getcommandlinea'            => :handle_get_command_line,
      'getcommandlinew'            => :handle_get_command_line,
      'getlasterror'               => :handle_zero,
      'setlasterror'               => :handle_nil,
      'getversion'                 => :handle_zero
    },
    'user32' => {
      'getasynckeystate'    => :handle_zero,
      'getkeystate'         => :handle_zero,
      'getkeyboardstate'    => :handle_get_keyboard_state,
      'getcursorpos'        => :handle_get_cursor_pos,
      'setcursorpos'        => :handle_one,
      'messageboxa'         => :handle_message_box,
      'messageboxw'         => :handle_message_box,
      'findwindowa'         => :handle_zero,
      'findwindoww'         => :handle_zero,
      'setwindowtexta'      => :handle_one,
      'setwindowtextw'      => :handle_one,
      'getsystemmetrics'    => :handle_get_system_metrics,
      'showcursor'          => :handle_show_cursor,
      'getforegroundwindow' => :handle_zero,
      'getactivewindow'     => :handle_zero,
      'getdc'               => :handle_zero,
      'releasedc'           => :handle_one,
      'keybd_event'         => :handle_nil,
      'mouse_event'         => :handle_nil,
      'getdoubleclicktime'  => :handle_get_double_click_time
    },
    'winmm' => {
      'mcisendstringa'  => :handle_mci_send_string,
      'mcisendstringw'  => :handle_mci_send_string,
      'playsounda'      => :handle_one,
      'playsoundw'      => :handle_one,
      'timegettime'     => :handle_time_get_time,
      'timebeginperiod' => :handle_zero,
      'timeendperiod'   => :handle_zero
    },
    'version' => {
      'getfileversioninfosizea' => :handle_zero,
      'getfileversioninfosizew' => :handle_zero,
      'getfileversioninfoa'     => :handle_zero,
      'getfileversioninfow'     => :handle_zero,
      'verqueryvaluea'          => :handle_one_ver_query_value,
      'verqueryvaluew'          => :handle_one_ver_query_value
    },
    'gdi32' => {
      'createfontindirecta' => :handle_zero,
      'createfontindirectw' => :handle_zero,
      'deleteobject'        => :handle_one,
      'getdevicecaps'       => :handle_zero
    },
    'advapi32' => {
      'regopenkeyexa'    => :handle_reg_open_key_ex,
      'regopenkeyexw'    => :handle_reg_open_key_ex,
      'regcreatekeyexa'  => :handle_reg_open_key_ex,
      'regcreatekeyexw'  => :handle_reg_open_key_ex,
      'regqueryvalueexa' => :handle_reg_query_value_ex,
      'regqueryvalueexw' => :handle_reg_query_value_ex,
      'regsetvalueexa'   => :handle_reg_query_value_ex,
      'regsetvalueexw'   => :handle_reg_query_value_ex,
      'regclosekey'      => :handle_zero
    }
  }.freeze unless const_defined?(:HANDLERS, false)

  # ------------------------------------------------------------------
  # shim 对象：Win32API.new 的返回值。只提供 call / Call（等价，任意参数个数），
  # 不继承 MiniFFI —— 免得 C 层对 MiniFFI 实例有额外假设。
  # ------------------------------------------------------------------
  class Api
    attr_reader :dll, :func, :imports, :exports

    def initialize(dll, func, imports = nil, exports = nil)
      @dll = dll
      @func = func
      @imports = imports
      @exports = exports
      @export_type = :int
      @import_types = []
      begin
        @export_type = MochiWin32Shim.export_type(exports)
        @import_types = MochiWin32Shim.import_types(imports)
      rescue Exception
        # 解析失败也要能构造：默认按整数返回 0。
      end
    end

    # 等价于 Win32API#call；参数个数/类型不做校验，交给具体 handler。
    def call(*args)
      MochiWin32Shim.dispatch(@dll, @func, args, @export_type)
    rescue Exception => e
      begin
        MochiWin32Shim.log("call failed #{@dll}/#{@func}: #{e.class}: #{e.message}")
      rescue Exception
      end
      0
    end
    alias Call call

    def to_s
      "#<MochiWin32Shim #{@dll}!#{@func}>"
    rescue Exception
      '#<MochiWin32Shim>'
    end
    alias inspect to_s

    # 便于排查：日志里能看到声明的参数/返回类型。
    def import_types
      @import_types
    rescue Exception
      []
    end

    def export_type
      @export_type
    rescue Exception
      :int
    end
  end

  class << self
    # ------------------------------------------------------------------
    # 安装
    # ------------------------------------------------------------------

    # 幂等。返回 true 表示「shim 已生效（或按开关关闭）」，false 表示宿主里没有
    # Win32API/MiniFFI，可以稍后重试（单测会先定义 stub 再调用）。
    def install!
      return true if $mochi_win32_shim_installed

      if disabled?
        log('disabled by MOCHI_WIN32_SHIM=off (Win32API keeps original dlopen behavior)')
        $mochi_win32_shim_installed = true
        return true
      end

      installed = install_win32api!
      $mochi_win32_shim_installed = true if installed
      installed
    rescue Exception => e
      log("install! failed: #{e.class}: #{e.message}")
      false
    end

    def disabled?
      ENV['MOCHI_WIN32_SHIM'].to_s.downcase == 'off'
    rescue Exception
      false
    end

    # 覆盖 Win32API.new。mkxp-z 里 Win32API 与 MiniFFI 是同一个类对象，所以
    # 通常只 patch 一次；若宿主把两者定义成不同类，两个都 patch。
    def install_win32api!
      targets = []
      targets << ::Win32API if defined?(::Win32API) && ::Win32API.is_a?(Module)
      if defined?(::MiniFFI) && ::MiniFFI.is_a?(Module) && !targets.include?(::MiniFFI)
        targets << ::MiniFFI
      end

      if targets.empty?
        log('Win32API/MiniFFI not defined (non-mkxp host?); shim idle, retry install! later')
        return false
      end

      patched = []
      targets.each do |klass|
        next if klass.instance_variable_get(:@mochi_win32_shim_new)

        begin
          klass.singleton_class.class_eval do
            def new(dll = nil, func = nil, imports = nil, exports = nil, *rest)
              MochiWin32Shim.build_api(dll, func, imports, exports)
            end
          end
          klass.instance_variable_set(:@mochi_win32_shim_new, true)
          patched << klass.to_s
        rescue Exception => e
          log("patch failed #{klass}: #{e.class}: #{e.message}")
        end
      end

      return false if patched.empty?

      log("installed: reopened #{patched.join(', ')}; handlers=#{handler_count}; " \
          "log=#{ENV['MOCHI_RGSS_LOG'] || '/tmp/mochi-rgss.log'}")
      true
    rescue Exception => e
      log("install_win32api! failed: #{e.class}: #{e.message}")
      false
    end

    # 构造 shim 对象。任何异常都不能漏到游戏脚本里（否则又是一次启动崩溃）。
    def build_api(dll, func, imports = nil, exports = nil)
      Api.new(dll, func, imports, exports)
    rescue Exception => e
      log("Win32API.new failed (#{dll}/#{func}): #{e.class}: #{e.message}")
      begin
        api = Api.allocate
        api.instance_variable_set(:@dll, dll)
        api.instance_variable_set(:@func, func)
        api.instance_variable_set(:@imports, imports)
        api.instance_variable_set(:@exports, exports)
        api.instance_variable_set(:@export_type, :int)
        api.instance_variable_set(:@import_types, [])
        api
      rescue Exception
        nil
      end
    end

    def handler_count
      count = 0
      HANDLERS.each_value { |table| count += table.size }
      count
    rescue Exception
      0
    end

    # ------------------------------------------------------------------
    # 分派
    # ------------------------------------------------------------------

    def dispatch(dll, func, args, export_type)
      args = [] unless args.is_a?(Array)
      dll_key = normalize_dll(dll)
      func_key = normalize_func(func)
      handler = handler_for(dll_key, func_key)
      return send(handler, args, func_key) if handler

      handle_unknown(dll_key, func_key, args, export_type)
    rescue Exception => e
      log("dispatch #{dll}/#{func} failed: #{e.class}: #{e.message}")
      default_for(export_type)
    end

    def normalize_dll(dll)
      name = safe_text(dll).strip
      return '' if name.empty?

      name = name.tr('\\', '/').split('/').last.to_s
      name = name.sub(/\.(dll|exe|so|dylib)\z/i, '')
      name.downcase
    rescue Exception
      ''
    end

    def normalize_func(func)
      safe_text(func).strip.downcase
    rescue Exception
      ''
    end

    def handler_for(dll_key, func_key)
      dll = normalize_dll(dll_key)
      key = DLL_ALIASES[dll] || dll
      table = HANDLERS[key]
      return nil if table.nil?

      table[normalize_func(func_key)]
    rescue Exception
      nil
    end

    # 未注册的 API：按 exports 推断安全默认，同一 (dll, func) 只记一次日志。
    def handle_unknown(dll_key, func_key, args, export_type)
      log_once(:unknown, "#{dll_key}!#{func_key}",
               "unknown api #{dll_key}!#{func_key} export=#{export_type} " \
               "argc=#{args.size} args=#{summarize_args(args)}")
      default_for(export_type)
    rescue Exception
      default_for(export_type)
    end

    def default_for(export_type)
      case export_type
      when :string then ''
      when :void then nil
      else 0
      end
    rescue Exception
      0
    end

    # exports 形状：String（'L'）、Symbol、Array（['P'] / [1]）、Integer、nil。
    # 没有声明返回类型（nil / 空串 / 'V'）一律按 void 处理（返回 nil），与
    # Windows 上「不写 export 就是无返回值」的直觉一致；显式 P/L/N/I 才返回
    # ""/0。注意：若脚本把未知 void API 的返回值直接做算术，nil 会抛
    # NoMethodError —— 这是"按声明推断"的代价，记录在 docs/win32-shim.md 的已知限制。
    def export_type(exports)
      code = first_type_code(exports)
      return :void if code.nil? || code.to_s.strip.empty?

      EXPORT_TYPES[code.to_s.downcase] || :int
    rescue Exception
      :int
    end

    def first_type_code(value)
      return nil if value.nil?

      if value.is_a?(String)
        value.empty? ? nil : value[0, 1]
      elsif value.is_a?(Symbol)
        first_type_code(value.to_s)
      elsif value.is_a?(Integer)
        INTEGER_TYPE_CODES[value]
      elsif value.is_a?(Array)
        value.empty? ? nil : first_type_code(value[0])
      end
    rescue Exception
      nil
    end

    # imports 只用于日志与排查（真正的参数按位置处理，不依赖类型串）。
    def import_types(imports)
      return [] if imports.nil?

      if imports.is_a?(String)
        imports.each_char.to_a
      elsif imports.is_a?(Symbol)
        imports.to_s.each_char.to_a
      elsif imports.is_a?(Integer)
        [imports.to_s]
      elsif imports.is_a?(Array)
        imports.map { |item| item.to_s }.reject { |item| item.empty? }
      else
        []
      end
    rescue Exception
      []
    end

    # ------------------------------------------------------------------
    # kernel32
    # ------------------------------------------------------------------

    def handle_get_private_profile_string(args, func)
      wide = wide_func?(func)
      section = to_str(arg(args, 0))
      key = to_str(arg(args, 1))
      default = to_str(arg(args, 2))
      default = '' if default.nil?
      buffer = arg(args, 3)
      size = to_int(arg(args, 4))
      filename = arg(args, 5)

      value = ini_get(section, key, filename)
      value = default if value.nil?

      write_buffer(buffer, value, size, wide)
    rescue Exception => e
      log("GetPrivateProfileString failed: #{e.class}: #{e.message}")
      begin
        write_buffer(arg(args, 3), '', to_int(arg(args, 4)), wide_func?(func))
      rescue Exception
        0
      end
    end

    def handle_get_private_profile_int(args, func)
      section = to_str(arg(args, 0))
      key = to_str(arg(args, 1))
      default = to_int(arg(args, 2))
      value = ini_get(section, key, arg(args, 3))
      return default if value.nil?

      parse_ini_int(value)
    rescue Exception
      to_int(arg(args, 2))
    end

    def handle_write_private_profile_string(args, func)
      section = to_str(arg(args, 0))
      key = to_str(arg(args, 1))
      value = to_str(arg(args, 2))
      ini_write(section, key, value, arg(args, 3))
    rescue Exception => e
      log("WritePrivateProfileString failed: #{e.class}: #{e.message}")
      0
    end

    def handle_get_tick_count(args, func)
      tick32
    end

    def handle_get_tick_count_64(args, func)
      monotonic_ms
    end

    def handle_sleep(args, func)
      ms = to_int(arg(args, 0))
      return nil if ms <= 0

      ms = SLEEP_MAX_MS if ms > SLEEP_MAX_MS
      begin
        sleep(ms / 1000.0)
      rescue Exception
      end
      nil
    end

    def handle_query_performance_counter(args, func)
      (monotonic * 1_000_000_000.0).to_i
    rescue Exception
      0
    end

    def handle_query_performance_frequency(args, func)
      1_000_000_000
    end

    def handle_get_module_handle(args, func)
      0
    end

    # 很多脚本用 GetModuleFileName 取"exe 路径"再 dirname 找 Game.ini；我们返回
    # cwd/Game.ini，dirname 正好是游戏目录（mkxp.json 的路径基准也是 cwd）。
    def handle_get_module_file_name(args, func)
      path = File.join(Dir.pwd, 'Game.ini')
      write_buffer(arg(args, 1), path, to_int(arg(args, 2)), wide_func?(func))
    rescue Exception
      0
    end

    def handle_lstrlen(args, func)
      value = to_str(arg(args, 0))
      return 0 if value.nil?

      value.bytesize
    end

    def handle_global_alloc(args, func)
      0
    end

    def handle_global_free(args, func)
      1
    end

    def handle_get_command_line(args, func)
      ''
    end

    # ------------------------------------------------------------------
    # user32
    # ------------------------------------------------------------------

    # mkxp-z 的按键走 SDL，不经过 Win32；这里恒 0 表示"没按下"。
    # 依赖 GetAsyncKeyState 的作弊/热键脚本会失效，但不会崩。
    def handle_get_keyboard_state(args, func)
      buffer = arg(args, 0)
      if buffer.is_a?(String) && buffer.bytesize >= 256
        begin
          buffer.force_encoding(Encoding::BINARY)
          buffer.replace("\x00".b * 256)
        rescue Exception
        end
      end
      0
    end

    def handle_get_cursor_pos(args, func)
      buffer = arg(args, 0)
      if buffer.is_a?(String) && buffer.bytesize >= 8
        begin
          buffer.force_encoding(Encoding::BINARY)
          buffer.replace("\x00".b * 8)
        rescue Exception
        end
      end
      1
    end

    # 真弹窗会卡住无头/自动化场景，所以只记文本并返回 IDOK(1)。
    def handle_message_box(args, func)
      text = to_str(arg(args, 1))
      caption = to_str(arg(args, 2))
      line = truncate(text, 80)
      unless caption.nil? || caption.empty?
        line = "#{line} / #{truncate(caption, 40)}"
      end
      log_once(:messagebox, line, "MessageBox: #{line}")
      1
    end

    def handle_get_system_metrics(args, func)
      case to_int(arg(args, 0))
      when 0 then 1024
      when 1 then 768
      else 0
      end
    end

    def handle_show_cursor(args, func)
      0
    end

    def handle_get_double_click_time(args, func)
      500
    end

    # ------------------------------------------------------------------
    # winmm
    # ------------------------------------------------------------------

    # 只维护最小状态机，不真的播放：
    #   open ... alias X → X=open；play X → playing；stop/pause X → paused；
    #   close X → 删除；status X mode → playing/paused/stopped/""
    # 这样轮询 "status bgm mode" 的脚本不会因为空字符串死循环。
    def handle_mci_send_string(args, func)
      wide = wide_func?(func)
      command = to_str(arg(args, 0))
      command = '' if command.nil?
      buffer = arg(args, 1)
      size = to_int(arg(args, 2))

      cmd = command.strip
      log_once(:mci, cmd.downcase, "MCI: #{truncate(cmd, 80)}") unless cmd.empty?

      state = mci_state
      down = cmd.downcase
      if down.start_with?('open')
        name = mci_alias(cmd)
        state[name] = :open if name
      elsif down.start_with?('play')
        name = mci_target(cmd)
        state[name] = :playing if name && state.key?(name)
      elsif down.start_with?('pause') || down.start_with?('stop')
        name = mci_target(cmd)
        state[name] = :paused if name && state.key?(name)
      elsif down.start_with?('close')
        name = mci_target(cmd)
        state.delete(name) if name
      elsif down.start_with?('status')
        name = mci_target(cmd)
        mode = cmd.split(/\s+/)[2].to_s.downcase
        write_buffer(buffer, mci_status_text(state[name], mode), size, wide)
      end
      0
    rescue Exception => e
      log("mciSendString failed: #{e.class}: #{e.message}")
      0
    end

    def handle_time_get_time(args, func)
      tick32
    end

    # ------------------------------------------------------------------
    # version（统一返回"没有版本信息"，让脚本走默认分支）
    # ------------------------------------------------------------------

    # VerQueryValue 的返回值是 BOOL；返回 1 但把长度写 0 会让脚本读到空字符串。
    # 这里返回 0（失败），与"无版本资源"一致，脚本通常有 fallback。
    def handle_one_ver_query_value(args, func)
      0
    end

    # ------------------------------------------------------------------
    # advapi32（注册表：安全失败，不假造成功）
    # ------------------------------------------------------------------

    # 返回 2=ERROR_FILE_NOT_FOUND；phkResult 若是 String 缓冲区，写 0 句柄。
    def handle_reg_open_key_ex(args, func)
      write_int32(arg(args, 4), 0)
      2
    end

    def handle_reg_query_value_ex(args, func)
      2
    end

    # ------------------------------------------------------------------
    # 通用 handler
    # ------------------------------------------------------------------

    def handle_zero(args, func)
      0
    end

    def handle_one(args, func)
      1
    end

    def handle_nil(args, func)
      nil
    end

    # ------------------------------------------------------------------
    # INI 实现
    # ------------------------------------------------------------------

    # 路径基准是 Dir.pwd（mkxp.json 里所有相对路径也以它为基准）。
    # Windows 风格反斜杠统一换成正斜杠；盘符去掉后按相对路径处理。
    def ini_path(filename)
      name = to_str(filename)
      return nil if name.nil?

      name = name.gsub("\0", '').strip
      return nil if name.empty?

      name = name.tr('\\', '/')
      name = name.sub(/\A[A-Za-z]:/, '')
      return name if name.start_with?('/')

      File.join(Dir.pwd, name)
    rescue Exception
      nil
    end

    def ini_read_text(path)
      return '' if path.nil? || !File.exist?(path)

      decode_ini_bytes(File.binread(path))
    rescue Exception => e
      log("ini read failed #{path}: #{e.class}: #{e.message}")
      ''
    end

    # 编码优先级：UTF-16LE BOM → UTF-8 BOM → 合法 UTF-8 → GBK/CP936 → scrub。
    # 任何编码问题都降级成替换字符，绝不 raise。
    def decode_ini_bytes(raw)
      return '' if raw.nil? || raw.empty?

      if raw.bytesize >= 2 && raw.getbyte(0) == 0xFF && raw.getbyte(1) == 0xFE
        body = raw.byteslice(2, raw.bytesize - 2)
        return body.force_encoding(Encoding::UTF_16LE)
                   .encode(Encoding::UTF_8, :invalid => :replace, :undef => :replace)
      end

      if raw.bytesize >= 3 && raw.getbyte(0) == 0xEF && raw.getbyte(1) == 0xBB && raw.getbyte(2) == 0xBF
        raw = raw.byteslice(3, raw.bytesize - 3)
      end

      utf8 = raw.dup.force_encoding(Encoding::UTF_8)
      return utf8 if utf8.valid_encoding?

      begin
        raw.dup.force_encoding(Encoding::GBK)
           .encode(Encoding::UTF_8, :invalid => :replace, :undef => :replace)
      rescue Exception
        utf8.scrub('?')
      end
    rescue Exception
      ''
    end

    # 返回 { 'section' => { 'key' => 'value' } }，section/key 均小写。
    def ini_parse(text)
      data = {}
      current = nil

      text.each_line do |line|
        line = line.sub(/\r?\n\z/, '')
        stripped = line.strip
        next if stripped.empty?
        next if stripped.start_with?(';') || stripped.start_with?('#')

        if stripped.start_with?('[') && stripped.include?(']')
          name = stripped[1, stripped.index(']') - 1].to_s.strip.downcase
          current = (data[name] ||= {})
          next
        end

        next if current.nil?

        eq = stripped.index('=')
        next if eq.nil?

        key = stripped[0, eq].strip.downcase
        next if key.empty?

        current[key] = stripped[(eq + 1)..-1].to_s.strip
      end

      data
    rescue Exception
      {}
    end

    def ini_get(section, key, filename)
      return nil if section.nil? || key.nil?

      section = section.strip.downcase
      key = key.strip.downcase
      return nil if section.empty? || key.empty?

      path = ini_path(filename)
      return nil if path.nil?
      return nil unless File.exist?(path)

      text = ini_read_text(path)
      return nil if text.empty?

      values = ini_parse(text)[section]
      return nil if values.nil?

      values[key]
    rescue Exception => e
      log("ini get failed: #{e.class}: #{e.message}")
      nil
    end

    # 缺失 key → nDefault；存在但不是数字 → 0（atoi 语义，与 Windows 实测一致）。
    def parse_ini_int(value)
      text = value.to_s.strip
      return 0 if text.empty?

      if text.start_with?('0x', '0X')
        Integer(text[2..-1].to_s, 16)
      else
        Integer(text, 10)
      end
    rescue Exception
      0
    end

    # 返回 1=成功、0=失败。section 为空/文件名为空视为调用错误，记日志后返 0；
    # 其余 IO/编码问题记日志后返 0，不 raise。
    def ini_write(section, key, value, filename)
      if section.nil? || section.strip.empty?
        log('WritePrivateProfileString ignored: empty section')
        return 0
      end

      path = ini_path(filename)
      if path.nil?
        log('WritePrivateProfileString ignored: empty filename')
        return 0
      end

      section = section.strip
      key = key.nil? ? nil : key.strip
      key = nil if key && key.empty?
      value = value.nil? ? nil : value.to_s

      text = File.exist?(path) ? ini_read_text(path) : ''
      lines = text.split(/\r?\n/, -1)
      lines.pop while lines.size > 1 && lines.last.to_s.strip.empty?

      ok = if key.nil?
             ini_remove_section(lines, section)
           elsif value.nil?
             ini_remove_key(lines, section, key)
           else
             ini_set_key(lines, section, key, value)
           end
      return 0 unless ok

      body = lines.join("\n")
      body += "\n" unless body.empty? || body.end_with?("\n")

      begin
        File.open(path, 'wb') { |file| file.write(body) }
      rescue Exception => e
        log("ini write failed #{path}: #{e.class}: #{e.message}")
        return 0
      end

      1
    rescue Exception => e
      log("WritePrivateProfileString failed: #{e.class}: #{e.message}")
      0
    end

    # 行级改写：保留注释、顺序与其它段，只动目标 key。
    def ini_set_key(lines, section, key, value)
      sec_down = section.downcase
      key_down = key.downcase
      current = nil
      section_index = nil
      section_last = nil
      key_index = nil

      lines.each_with_index do |line, index|
        stripped = line.strip
        if stripped.start_with?('[') && stripped.include?(']')
          name = stripped[1, stripped.index(']') - 1].to_s.strip.downcase
          current = name
          if name == sec_down && section_index.nil?
            section_index = index
            section_last = index
          end
          next
        end

        next unless current == sec_down

        section_last = index unless stripped.empty?
        next if key_index
        next if stripped.empty?

        eq = stripped.index('=')
        next if eq.nil?

        key_index = index if stripped[0, eq].strip.downcase == key_down
      end

      if key_index
        # 保留磁盘上原有的 key 拼写（Windows 的 INI 也是大小写不敏感更新），
        # 这样 "Lang=en" 不会被改写成 "lang=en"。
        existing = lines[key_index].to_s
        eq = existing.index('=')
        original_key = eq ? existing[0, eq].strip : ''
        original_key = key if original_key.empty?
        lines[key_index] = "#{original_key}=#{value}"
        return true
      end

      if section_index.nil?
        lines << '' unless lines.empty? || lines.last.to_s.strip.empty?
        lines << "[#{section}]"
        lines << "#{key}=#{value}"
        return true
      end

      insert_at = (section_last || section_index) + 1
      lines.insert(insert_at, "#{key}=#{value}")
      true
    rescue Exception
      false
    end

    def ini_remove_key(lines, section, key)
      sec_down = section.downcase
      key_down = key.downcase
      current = nil
      found_section = false
      target = nil

      lines.each_with_index do |line, index|
        stripped = line.strip
        if stripped.start_with?('[') && stripped.include?(']')
          current = stripped[1, stripped.index(']') - 1].to_s.strip.downcase
          found_section = true if current == sec_down
          next
        end

        next unless current == sec_down

        eq = stripped.index('=')
        next if eq.nil?

        if stripped[0, eq].strip.downcase == key_down
          target = index
          break
        end
      end

      return false unless found_section
      return true if target.nil?

      lines.delete_at(target)
      true
    rescue Exception
      false
    end

    def ini_remove_section(lines, section)
      sec_down = section.downcase
      start = nil

      lines.each_with_index do |line, index|
        stripped = line.strip
        next unless stripped.start_with?('[') && stripped.include?(']')

        name = stripped[1, stripped.index(']') - 1].to_s.strip.downcase
        if name == sec_down
          start = index
          break
        end
      end

      return false if start.nil?

      finish = start
      index = start + 1
      while index < lines.size
        stripped = lines[index].strip
        break if stripped.start_with?('[') && stripped.include?(']')

        finish = index
        index += 1
      end

      finish -= 1 while finish > start && lines[finish].to_s.strip.empty?
      lines.slice!(start..finish)
      true
    rescue Exception
      false
    end

    # ------------------------------------------------------------------
    # 缓冲区 / 类型小工具
    # ------------------------------------------------------------------

    # 把 value 写进调用方给的 String 缓冲区（大小按调用方声明的 size），
    # 末尾补 NUL（W 变体补 UTF-16LE 双字节 NUL），其余补 0。
    # 返回写入的"字符数"（A = 字节，W = UTF-16 码元），与 Windows 返回值口径一致。
    def write_buffer(buffer, text, size, wide)
      return 0 unless buffer.is_a?(String)

      limit = to_int(size)
      return 0 if limit <= 0

      value = text.nil? ? '' : text.to_s
      unit = wide ? 2 : 1

      begin
        bytes = if wide
                  value.encode(Encoding::UTF_16LE, :invalid => :replace, :undef => :replace)
                else
                  value.encode(Encoding::UTF_8, :invalid => :replace, :undef => :replace)
                end
      rescue Exception
        bytes = value.to_s.b
      end
      bytes = bytes.b

      max = limit - unit
      max = 0 if max < 0
      bytes = bytes.byteslice(0, max) || ''.b

      if unit > 1
        remainder = bytes.bytesize % unit
        bytes = bytes.byteslice(0, bytes.bytesize - remainder) if remainder != 0
      else
        bytes = trim_to_utf8_boundary(bytes)
      end

      terminator = wide ? "\x00\x00".b : "\x00".b
      payload = bytes + terminator
      padding = limit - payload.bytesize
      padding = 0 if padding < 0

      begin
        buffer.force_encoding(Encoding::BINARY)
        buffer.replace(payload + ("\x00".b * padding))
      rescue Exception => e
        log("buffer write failed: #{e.class}: #{e.message}")
      end

      bytes.bytesize / unit
    rescue Exception => e
      log("write_buffer failed: #{e.class}: #{e.message}")
      0
    end

    # 截断可能切开 UTF-8 多字节字符；回退到最近的合法边界。
    def trim_to_utf8_boundary(bytes)
      trimmed = bytes
      while trimmed.bytesize > 0
        candidate = trimmed.dup.force_encoding(Encoding::UTF_8)
        return trimmed if candidate.valid_encoding?

        trimmed = trimmed.byteslice(0, trimmed.bytesize - 1)
      end
      ''.b
    rescue Exception
      bytes
    end

    def write_int32(buffer, value)
      return false unless buffer.is_a?(String) && buffer.bytesize >= 4

      begin
        buffer.force_encoding(Encoding::BINARY)
        buffer.replace([value.to_i & 0xFFFFFFFF].pack('V') + ("\x00".b * (buffer.bytesize - 4)))
      rescue Exception
        return false
      end
      true
    rescue Exception
      false
    end

    def wide_func?(func)
      func.to_s.downcase.end_with?('w')
    rescue Exception
      false
    end

    def arg(args, index)
      args.is_a?(Array) ? args[index] : nil
    rescue Exception
      nil
    end

    def to_str(value)
      return nil if value.nil?

      if value.is_a?(String)
        begin
          if value.encoding == Encoding::UTF_16LE || value.encoding == Encoding::UTF_16BE
            return value.encode(Encoding::UTF_8, :invalid => :replace, :undef => :replace)
          end
          if value.encoding == Encoding::BINARY || value.encoding == Encoding::US_ASCII
            converted = value.dup.force_encoding(Encoding::UTF_8)
            return converted.valid_encoding? ? converted : converted.scrub('?')
          end
          return value if value.valid_encoding?

          return value.scrub('?')
        rescue Exception
          return value.to_s.scrub('?')
        end
      end

      value.to_s
    rescue Exception
      ''
    end

    def to_int(value)
      return 0 if value.nil?

      if value.is_a?(Integer)
        value
      elsif value.is_a?(Numeric)
        begin
          value.to_i
        rescue Exception
          0
        end
      else
        begin
          Integer(value.to_s.strip, 10)
        rescue Exception
          0
        end
      end
    rescue Exception
      0
    end

    # ------------------------------------------------------------------
    # 日志 / 去重
    # ------------------------------------------------------------------

    # 同一 (dll, func) / 同一 MessageBox 文本 / 同一 MCI 命令只记第一次，
    # 防止商业脚本每帧轮询把日志打爆。
    def log_once(bucket, key, message)
      store = (@log_once ||= {})
      seen = (store[bucket] ||= {})
      return if seen.key?(key)

      seen[key] = true
      seen.shift while seen.size > 256
      log(message)
    rescue Exception
    end

    def mci_state
      @mci_state ||= {}
    rescue Exception
      {}
    end

    def mci_alias(cmd)
      matched = cmd.match(/\balias\s+("[^"]+"|\S+)/i)
      return nil if matched.nil?

      matched[1].to_s.gsub(/\A"|"\z/, '').downcase
    rescue Exception
      nil
    end

    def mci_target(cmd)
      parts = cmd.split(/\s+/)
      return nil if parts.size < 2

      parts[1].to_s.gsub(/\A"|"\z/, '').downcase
    rescue Exception
      nil
    end

    def mci_status_text(state, mode)
      return '' if mode.nil? || mode.empty?

      case mode
      when 'mode'
        case state
        when :playing then 'playing'
        when :paused then 'paused'
        when :open then 'stopped'
        else ''
        end
      when 'length', 'position'
        '0'
      else
        ''
      end
    rescue Exception
      ''
    end

    def summarize_args(args)
      args.map { |value| summarize_value(value) }.join(',')
    rescue Exception
      ''
    end

    def summarize_value(value)
      case value
      when nil then 'nil'
      when String then "s(#{value.bytesize}):#{truncate(value, 16)}"
      when true, false then "b:#{value}"
      when Array then "a(#{value.size})"
      when Hash then "h(#{value.size})"
      else
        value.is_a?(Numeric) ? "#{value.class.name.downcase}:#{value}" : value.class.to_s
      end
    rescue Exception
      '?'
    end

    def truncate(value, max = LOG_VALUE_MAX)
      text = safe_text(value).gsub(/[\r\n\t]/, ' ')
      text.length > max ? text[0, max] + '…' : text
    rescue Exception
      ''
    end

    def safe_text(value)
      return '' if value.nil?

      text = value.is_a?(String) ? value : value.to_s
      if text.encoding == Encoding::BINARY
        text = text.dup.force_encoding(Encoding::UTF_8)
      elsif text.encoding == Encoding::UTF_16LE || text.encoding == Encoding::UTF_16BE
        text = text.encode(Encoding::UTF_8, :invalid => :replace, :undef => :replace)
      end
      text.valid_encoding? ? text : text.scrub('?')
    rescue Exception
      ''
    end

    def log(message)
      path = ENV['MOCHI_RGSS_LOG'] || '/tmp/mochi-rgss.log'

      begin
        if File.exist?(path) && File.size(path) > LOG_MAX_BYTES
          File.open(path, 'w') do |file|
            file.puts("[win32] log truncated at #{Time.now}")
          end
        end
      rescue Exception
      end

      begin
        File.open(path, 'a:UTF-8') do |file|
          file.puts("[#{Time.now.strftime('%Y-%m-%d %H:%M:%S')}] [win32] #{safe_text(message)}")
        end
      rescue Exception
      end
    rescue Exception
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    rescue Exception
      Time.now.to_f
    end

    def monotonic_ms
      (monotonic * 1000.0).to_i
    rescue Exception
      0
    end

    # GetTickCount 是 32 位无符号，会回绕；游戏一般只做差值。
    def tick32
      monotonic_ms & 0xFFFFFFFF
    end
  end
end

# 文件末尾自动安装：单独 preload 本文件也能生效；hook 里再调用 install! 是幂等的。
MochiWin32Shim.install!
