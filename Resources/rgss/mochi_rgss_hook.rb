# -*- coding: utf-8 -*-
# frozen_string_literal: false
#
# MochiBox —— RGSS 文本通道 hook 骨架（XP / VX / VX Ace 共用）
#
# 用途：
#   在 mkxp-z 的 preloadScript 阶段加载，拦截三版 Window_Message 的文本入口，
#   把屏上真实文本发给本机 MochiBox 进程，并把译文写回，再调用原方法渲染。
#
# 加载方式（mkxp.json，路径相对进程 cwd，即游戏根目录）：
#   {"preloadScript": ["/absolute/path/to/mochi_rgss_hook.rb"]}
#   或 {"preloadScript": ["mochi_rgss_hook.rb"]}   # 文件放在游戏根目录时
#
# 环境变量：
#   MOCHI_RGSS_HOOK=off     完全不安装（游戏行为不变）
#   MOCHI_RGSS_SURFACES=... 逗号分隔的界面清单，默认全开：
#                           message,menu,choice,help,battle
#                           （choice 在 XP/VX 上并入 message，见 docs/rgss-text-channel.md）
#   MOCHI_RGSS_HOST=...     默认 127.0.0.1
#   MOCHI_RGSS_PORT=...     默认 47123
#   MOCHI_RGSS_LOG=...      默认 /tmp/mochi-rgss.log（超过 1 MB 自动截断）
#
# 行协议（UTF-8 文本，字段用 TAB 分隔，行尾 LF，base64 用 pack('m0')）：
#   → TEXT\t<seq>\t<RGSS1|RGSS2|RGSS3>\t<base64(原文)>
#   ← RESP\t<seq>\t<base64(译文)>                      正常译文（会进本进程缓存）
#   ← RESP\t<seq>\t<base64(原文的 UTF-8 版本)>\tPENDING  还没译好：先显示原文，不缓存
#
# 设计约束：
#   * 只依赖 Ruby 内置的 socket；不 require json / net/http / yaml / uri / time。
#   * 任何失败（连不上、超时、协议错、base64 错）都静默放行原文。
#   * 用非阻塞 IO + 截止时间，绝不无限期阻塞游戏主线程。
#   * 幂等：重复加载不会重复 hook（$mochi_hook_installed）。

# ----------------------------------------------------------------------
# Win32API shim 接线（早于游戏脚本，且不受 MOCHI_RGSS_HOOK=off 影响）
#
# mkxp-z 的 Win32API 在 macOS 上把 dll 名当相对路径 dlopen，任何用 Win32API
# 的 XP/VX 游戏都会在 new 阶段崩。shim 在 preload 阶段重开 Win32API.new，按
# (dll, func) 分派到纯 Ruby 安全实现。这里加载失败只记日志并继续——本文件
# 其余部分（翻译通道）必须照常工作。
# ----------------------------------------------------------------------
begin
  load File.join(__dir__, 'mochi_win32_shim.rb')
  MochiWin32Shim.install!
rescue Exception => e
  begin
    path = ENV['MOCHI_RGSS_LOG'] || '/tmp/mochi-rgss.log'
    File.open(path, 'a:UTF-8') do |file|
      file.puts("[#{Time.now.strftime('%Y-%m-%d %H:%M:%S')}] [mochi-rgss] " \
                "win32 shim load failed (hook continues): #{e.class}: #{e.message}")
    end
  rescue Exception
  end
end

module MochiRGSSHook
  # 重复 load 时不要重定义常量（Ruby 会刷 already initialized constant 警告）。
  HOST_DEFAULT      = '127.0.0.1' unless const_defined?(:HOST_DEFAULT, false)
  PORT_DEFAULT      = 47_123      unless const_defined?(:PORT_DEFAULT, false)
  CONNECT_TIMEOUT   = 0.2         unless const_defined?(:CONNECT_TIMEOUT, false)
  IO_TIMEOUT        = 0.2         unless const_defined?(:IO_TIMEOUT, false)
  COOLDOWN_SECONDS  = 2.0         unless const_defined?(:COOLDOWN_SECONDS, false)
  # 宿主回 PENDING（"这次还没译好，先显示原文"）后，同一句在这么短时间内不再重复问。
  # 它不是失败冷却：不阻塞别的句子，也不影响下一次消息。1.5s 是"首屏晚一拍"的窗口。
  PENDING_SECONDS   = 1.5         unless const_defined?(:PENDING_SECONDS, false)
  LOG_MAX_BYTES     = 1024 * 1024 unless const_defined?(:LOG_MAX_BYTES, false)
  CACHE_MAX         = 256         unless const_defined?(:CACHE_MAX, false)

  # 顺序即优先级：VX Ace 有 process_all_text，VX 有 start_message，XP 有 refresh。
  # 不要只认一个方法名——XP 没有 draw_text_ex，XP/VX 都没有 process_all_text。
  ENTRY_TABLE = [
    [:process_all_text, 'RGSS3'],
    [:start_message,    'RGSS2'],
    [:refresh,          'RGSS1']
  ].freeze unless const_defined?(:ENTRY_TABLE, false)

  # 文本面。每个面对应一个“有语义的上层入口”，绝不 hook Window_Base#draw_text
  # （它是逐字调用的，单字送翻译会丢语义并放大请求量）。
  SURFACE_MESSAGE = 'message' unless const_defined?(:SURFACE_MESSAGE, false)
  SURFACE_MENU    = 'menu'    unless const_defined?(:SURFACE_MENU, false)
  SURFACE_CHOICE  = 'choice'  unless const_defined?(:SURFACE_CHOICE, false)
  SURFACE_HELP    = 'help'    unless const_defined?(:SURFACE_HELP, false)
  SURFACE_BATTLE  = 'battle'  unless const_defined?(:SURFACE_BATTLE, false)

  ALL_SURFACES = [
    SURFACE_MESSAGE, SURFACE_MENU, SURFACE_CHOICE, SURFACE_HELP, SURFACE_BATTLE
  ].freeze unless const_defined?(:ALL_SURFACES, false)

  # 需要等 :end 的类。VX 的战斗日志叫 Window_BattleMessage，VX Ace 叫
  # Window_BattleLog；两者都是战斗面，先出现的那个生效。
  TARGET_CLASSES = [
    'Window_Message', 'Window_Command', 'Window_ChoiceList',
    'Window_Help', 'Window_BattleMessage', 'Window_BattleLog'
  ].freeze unless const_defined?(:TARGET_CLASSES, false)

  class << self
    # ------------------------------------------------------------------
    # 安装
    # ------------------------------------------------------------------
    def install
      return if $mochi_hook_installed

      $mochi_hook_installed = true

      if disabled?
        log('hook disabled by MOCHI_RGSS_HOOK=off')
        return
      end

      enabled = enabled_surfaces
      log("socket probe: Socket.tcp=#{defined?(Socket) && Socket.respond_to?(:tcp) ? 'yes' : 'no'} TCPSocket=#{defined?(TCPSocket) ? 'yes' : 'no'}")
      log("surfaces enabled: #{enabled.empty? ? '(none)' : enabled.join(',')}")

      if enabled.empty?
        log('no surfaces enabled; pass-through only')
        return
      end

      hook_available_surfaces('defined-at-load')
      arm_tracepoint if wait_for_more_surfaces?
    rescue Exception => e
      log("install failed: #{e.class}: #{e.message}")
    end

    def disabled?
      ENV['MOCHI_RGSS_HOOK'].to_s.downcase == 'off'
    rescue Exception
      false
    end

    # MOCHI_RGSS_SURFACES 只认白名单里的名字；未知名字记日志后忽略。
    # 空值 = 全开；显式 none 会得到空清单（只做原文直通）。
    def enabled_surfaces
      return $mochi_hook_enabled_surfaces if $mochi_hook_enabled_surfaces

      raw = ENV['MOCHI_RGSS_SURFACES']
      $mochi_hook_enabled_surfaces =
        if raw.nil? || raw.strip.empty?
          ALL_SURFACES.dup
        else
          names = raw.split(',').map { |name| name.strip.downcase }.reject { |name| name.empty? }
          unknown = names - ALL_SURFACES
          log("unknown surfaces ignored: #{unknown.join(',')}") unless unknown.empty?
          names & ALL_SURFACES
        end
    rescue Exception => e
      log("surface list failed: #{e.class}: #{e.message}")
      ALL_SURFACES.dup
    end

    def surface_enabled?(surface)
      enabled_surfaces.include?(surface)
    end

    def installed_surfaces
      $mochi_hook_installed_surfaces ||= {}
    end

    def surface_installed?(surface)
      installed_surfaces.key?(surface)
    end

    def mark_installed(surface, detail)
      installed_surfaces[surface] = detail
      log("hooked #{surface}: #{detail}")
    end

    def class_defined?(name)
      Object.const_defined?(name) && Object.const_get(name).is_a?(Class)
    rescue Exception
      false
    end

    def method_present?(cls, name)
      cls.method_defined?(name) || cls.private_method_defined?(name)
    rescue Exception
      false
    end

    # 只看本类自身定义的方法：子类会继承父类的 mochi_orig_*，
    # 用 method_defined? 判断会误以为子类已经挂过，从而漏挂子类覆盖的入口。
    def own_method_defined?(cls, name)
      cls.instance_methods(false).include?(name) ||
        cls.private_instance_methods(false).include?(name)
    rescue Exception
      false
    end

    # 只在类定义结束时挂“已经存在”的面；每个面各自 begin/rescue，
    # 一个面失败不会影响其它面。
    def hook_available_surfaces(trigger)
      [
        SURFACE_MESSAGE, SURFACE_MENU, SURFACE_CHOICE,
        SURFACE_HELP, SURFACE_BATTLE
      ].each do |surface|
        next unless surface_enabled?(surface)
        next if surface_installed?(surface)

        begin
          case surface
          when SURFACE_MESSAGE then hook_message(trigger)
          when SURFACE_MENU    then hook_menu(trigger)
          when SURFACE_CHOICE  then hook_choice(trigger)
          when SURFACE_HELP    then hook_help(trigger)
          when SURFACE_BATTLE  then hook_battle(trigger)
          end
        rescue Exception => e
          log("#{surface} hook failed: #{e.class}: #{e.message}")
        end
      end

      warn_embedded_surfaces
      maybe_disarm_tracepoint
    end

    # preload 阶段目标类还没定义：等类定义结束再挂。
    def arm_tracepoint
      return if $mochi_hook_trace

      $mochi_hook_trace = TracePoint.new(:end) do |tp|
        begin
          next unless tp.self.is_a?(Class)

          name = tp.self.name
          next unless name && TARGET_CLASSES.include?(name)

          hook_available_surfaces("tracepoint:#{name}")
        rescue Exception => e
          log("tracepoint callback error: #{e.class}: #{e.message}")
        end
      end
      $mochi_hook_trace.enable
      log('tracepoint armed; waiting for surface classes')
    rescue Exception => e
      log("tracepoint arm failed: #{e.class}: #{e.message}")
    end

    def wait_for_more_surfaces?
      expected = expected_surfaces
      return true if expected.nil?

      expected.any? { |surface| !surface_installed?(surface) }
    end

    # 当前版本上“可以独立 hook”的面。XP 的选项/战斗日志都走 message，
    # VX 的选项也走 message；它们不阻塞 TracePoint 关闭。
    def expected_surfaces
      list = case detect_version
             when 'RGSS1' then [SURFACE_MESSAGE, SURFACE_MENU, SURFACE_HELP]
             when 'RGSS2' then [SURFACE_MESSAGE, SURFACE_MENU, SURFACE_HELP, SURFACE_BATTLE]
             when 'RGSS3' then [SURFACE_MESSAGE, SURFACE_MENU, SURFACE_CHOICE, SURFACE_HELP, SURFACE_BATTLE]
             end
      list && list.select { |surface| surface_enabled?(surface) }
    end

    def maybe_disarm_tracepoint
      return unless $mochi_hook_trace

      expected = expected_surfaces
      return if expected.nil?
      return unless expected.all? { |surface| surface_installed?(surface) }

      $mochi_hook_trace.disable
      log("tracepoint disabled (version=#{detect_version})")
    rescue Exception => e
      log("tracepoint disarm failed: #{e.class}: #{e.message}")
    end

    def detect_version
      if class_defined?('Window_Message')
        cls = Object.const_get(:Window_Message)
        return 'RGSS3' if method_present?(cls, :process_all_text)
        return 'RGSS2' if method_present?(cls, :start_message)
        return 'RGSS1' if method_present?(cls, :refresh)
      end

      return 'RGSS3' if class_defined?('Window_BattleLog') || class_defined?('Window_ChoiceList')
      return 'RGSS2' if class_defined?('Window_BattleMessage')

      nil
    rescue Exception
      nil
    end

    def rgss_version
      $mochi_hook_version ||= detect_version || 'RGSS1'
    end

    # 旧版本没有独立入口的面：不谎报 hooked，但要在日志里说清楚它挂在谁身上。
    def warn_embedded_surfaces
      version = detect_version
      return unless version

      embedded = case version
                 when 'RGSS1' then [SURFACE_CHOICE, SURFACE_BATTLE]
                 when 'RGSS2' then [SURFACE_CHOICE]
                 else []
                 end

      embedded.each do |surface|
        next unless surface_enabled?(surface)

        $mochi_hook_embedded_noted ||= {}
        next if $mochi_hook_embedded_noted[surface]

        $mochi_hook_embedded_noted[surface] = true
        log("#{surface} on #{version} has no separate entry; it rides #{SURFACE_MESSAGE}")
        unless surface_enabled?(SURFACE_MESSAGE)
          log("warning: #{surface} needs #{SURFACE_MESSAGE} on #{version}, but message is disabled")
        end
      end
    end

    def message_entry(cls)
      ENTRY_TABLE.each do |name, version|
        return [name, version] if method_present?(cls, name)
      end
      nil
    rescue Exception
      nil
    end

    def hook_message(trigger)
      return false unless class_defined?('Window_Message')

      cls = Object.const_get(:Window_Message)
      entry, version = message_entry(cls)
      unless entry
        log('Window_Message found but no known text entry; waiting for another class end')
        return false
      end

      was_private = cls.private_method_defined?(entry)
      already_wrapped = own_method_defined?(cls, :"mochi_orig_#{entry}")

      cls.class_eval do
        if already_wrapped
          # 上一次安装中途失败时留下的 alias：不要再包一层。
        else
          alias_method :"mochi_orig_#{entry}", entry

          define_method(entry) do |*args|
            begin
              MochiRGSSHook.rewrite(version)
            rescue Exception => e
              MochiRGSSHook.log("message hook body error: #{e.class}: #{e.message}")
            end
            send(:"mochi_orig_#{entry}", *args)
          end
        end

        private entry if was_private
      end

      $mochi_hook_entry = entry
      $mochi_hook_version = version
      mark_installed(SURFACE_MESSAGE, "Window_Message##{entry} as #{version} (trigger=#{trigger})")
      true
    rescue Exception => e
      log("hook_message failed: #{e.class}: #{e.message}")
      false
    end

    def hook_menu(trigger)
      return false unless class_defined?('Window_Command')

      cls = Object.const_get(:Window_Command)
      return false unless method_present?(cls, :draw_item)

      install_method_hooks(SURFACE_MENU, cls, [:draw_item], trigger)
    rescue Exception => e
      log("hook_menu failed: #{e.class}: #{e.message}")
      false
    end

    def hook_choice(trigger)
      return false unless class_defined?('Window_ChoiceList')

      cls = Object.const_get(:Window_ChoiceList)
      methods = [:start, :draw_item].select { |name| method_present?(cls, name) }
      return false if methods.empty?

      install_method_hooks(SURFACE_CHOICE, cls, methods, trigger)
    rescue Exception => e
      log("hook_choice failed: #{e.class}: #{e.message}")
      false
    end

    def hook_help(trigger)
      return false unless class_defined?('Window_Help')

      cls = Object.const_get(:Window_Help)
      return false unless method_present?(cls, :set_text)

      install_method_hooks(SURFACE_HELP, cls, [:set_text], trigger)
    rescue Exception => e
      log("hook_help failed: #{e.class}: #{e.message}")
      false
    end

    def hook_battle(trigger)
      if class_defined?('Window_BattleMessage')
        cls = Object.const_get(:Window_BattleMessage)
        methods = [:add_instant_text, :replace_instant_text].select do |name|
          method_present?(cls, name)
        end
        return install_method_hooks(SURFACE_BATTLE, cls, methods, trigger) unless methods.empty?
      end

      if class_defined?('Window_BattleLog')
        cls = Object.const_get(:Window_BattleLog)
        methods = [:add_text, :replace_text].select do |name|
          method_present?(cls, name)
        end
        return install_method_hooks(SURFACE_BATTLE, cls, methods, trigger) unless methods.empty?
      end

      false
    rescue Exception => e
      log("hook_battle failed: #{e.class}: #{e.message}")
      false
    end

    def install_method_hooks(surface, cls, methods, trigger)
      return false if methods.empty? || surface_installed?(surface)

      methods.each do |method|
        was_private = cls.private_method_defined?(method)
        already_wrapped = own_method_defined?(cls, :"mochi_orig_#{method}")

        cls.class_eval do
          if already_wrapped
            # 上一次安装中途失败时留下的 alias：不要再包一层。
          else
            alias_method :"mochi_orig_#{method}", method

            define_method(method) do |*args|
              begin
                MochiRGSSHook.rewrite_surface(surface, self, args, method)
              rescue Exception => e
                MochiRGSSHook.log("#{surface} hook body error: #{e.class}: #{e.message}")
              end
              send(:"mochi_orig_#{method}", *args)
            end
          end

          private method if was_private
        end
      end

      mark_installed(surface, "#{cls}##{methods.join('/')} (trigger=#{trigger})")
      true
    rescue Exception => e
      log("install_method_hooks(#{surface}) failed: #{e.class}: #{e.message}")
      false
    end

    # ------------------------------------------------------------------
    # 改写：调用原方法之前，把当前消息源替换成译文
    # ------------------------------------------------------------------
    def rewrite(version)
      case version
      when 'RGSS1'
        rewrite_rgss1
      when 'RGSS2', 'RGSS3'
        rewrite_texts(version)
      end
    rescue Exception => e
      log("rewrite failed: #{e.class}: #{e.message}")
    end

    # ------------------------------------------------------------------
    # 非消息面的改写：拿到上层入口的字符串 / 列表项，替换后原样调用 super
    # ------------------------------------------------------------------
    def rewrite_surface(surface, window, args, method = nil)
      case surface
      when SURFACE_CHOICE
        if method == :start
          rewrite_choices
        else
          rewrite_command_item(window, args[0])
        end
      when SURFACE_MENU
        rewrite_command_item(window, args[0])
      when SURFACE_HELP, SURFACE_BATTLE
        rewrite_text_argument(args, 0)
      end
    rescue Exception => e
      log("#{surface} rewrite failed: #{e.class}: #{e.message}")
    end

    # XP/VX 的 Window_Command 用 @commands[index]；VX Ace 用 @list[index][:name]。
    # 只改数组/哈希里的那一项，不 replace 原字符串（避免改到 Vocab 常量）。
    def rewrite_command_item(window, index)
      return unless index.is_a?(Integer) && index >= 0

      if window.instance_variable_defined?(:@commands)
        list = window.instance_variable_get(:@commands)
        if list.is_a?(Array) && index < list.size && list[index].is_a?(String)
          original = list[index]
          translated = translate_line(original, rgss_version)
          list[index] = translated if translated && translated != original
          return
        end
      end

      return unless window.instance_variable_defined?(:@list)

      list = window.instance_variable_get(:@list)
      return unless list.is_a?(Array) && index < list.size

      entry = list[index]
      return unless entry.is_a?(Hash)

      key = entry.key?(:name) ? :name : (entry.key?('name') ? 'name' : nil)
      return unless key && entry[key].is_a?(String)

      original = entry[key]
      translated = translate_line(original, rgss_version)
      entry[key] = translated if translated && translated != original
    rescue Exception => e
      log("rewrite_command_item failed: #{e.class}: #{e.message}")
    end

    # VX Ace 的选项是 $game_message.choices 数组：在 start 里先整组替换，
    # 这样 update_placement 量宽度时用的就是译文，不会按原文裁掉。
    def rewrite_choices
      return unless defined?($game_message) && $game_message
      return unless $game_message.respond_to?(:choices)

      choices = $game_message.choices
      return unless choices.is_a?(Array)

      choices.map! do |choice|
        if choice.is_a?(String) && !choice.empty?
          translate_line(choice, rgss_version) || choice
        else
          choice
        end
      end
    rescue Exception => e
      log("rewrite_choices failed: #{e.class}: #{e.message}")
    end

    # Window_Help#set_text / Window_BattleLog#add_text 等都是单字符串参数。
    def rewrite_text_argument(args, index)
      text = args[index]
      return unless text.is_a?(String) && !text.empty?

      translated = translate_line(text, rgss_version)
      args[index] = translated if translated && translated != text
    rescue Exception => e
      log("rewrite_text_argument failed: #{e.class}: #{e.message}")
    end

    # XP：$game_temp.message_text 是单个字符串（可含 \n 与控制符）。
    def rewrite_rgss1
      return unless defined?($game_temp) && $game_temp
      return unless $game_temp.respond_to?(:message_text) &&
                    $game_temp.respond_to?(:message_text=)

      original = $game_temp.message_text
      return unless original.is_a?(String) && !original.empty?

      translated = translate_line(original, 'RGSS1')
      $game_temp.message_text = translated if translated && translated != original
    rescue Exception => e
      log("rewrite_rgss1 failed: #{e.class}: #{e.message}")
    end

    # VX / VX Ace：$game_message.texts 是数组，逐行请求。
    def rewrite_texts(version)
      return unless defined?($game_message) && $game_message
      return unless $game_message.respond_to?(:texts)

      texts = $game_message.texts
      return unless texts.is_a?(Array) && !texts.empty?

      texts.map! do |line|
        if line.is_a?(String) && !line.empty?
          translate_line(line, version) || line
        else
          line
        end
      end
    rescue Exception => e
      log("rewrite_texts failed: #{e.class}: #{e.message}")
    end

    # 返回 nil 表示“这次不改”，调用方保留原文。
    def translate_line(text, version)
      return nil unless text.is_a?(String) && !text.empty?

      key = text.b
      cached = cache[key]
      return cached if cached

      # 刚回过 PENDING：同一句在 1.5s 内不重复请求（重绘 / 立刻重开对话时）。
      # 窗口过后再问，那时宿主缓存通常已经有译文了。
      until_time = pending[key]
      return nil if until_time && monotonic < until_time

      response = request(text, version)
      return nil unless response
      translated, is_pending = response

      if is_pending
        # 显示原文的 UTF-8 版本，但**不写进缓存**：下一次同一句还要再问一次。
        pending[key] = monotonic + PENDING_SECONDS
        pending.shift while pending.size > CACHE_MAX
        log("PENDING (display original) #{translated.inspect}")
        return translated
      end

      pending.delete(key)
      cache[key] = translated
      # 反向登记：下一轮 refresh/process_all_text 若拿到的是已经替换过的译文，
      # 不再重复请求（也避免服务端把译文再翻一遍）。
      cache[translated.b] = translated
      cache.shift while cache.size > CACHE_MAX
      translated
    rescue Exception => e
      log("translate_line failed: #{e.class}: #{e.message}")
      nil
    end

    # ------------------------------------------------------------------
    # 协议
    # ------------------------------------------------------------------
    def request(text, version)
      return nil unless socket_available?
      return nil if cooling_down?

      seq = next_seq
      payload = [text].pack('m0')
      sock = nil

      begin
        sock = open_socket
        sock.sync = true

        wire = "TEXT\t#{seq}\t#{version}\t#{payload}\n"
        unless write_all(sock, wire, IO_TIMEOUT)
          note_failure
          log("write failed seq=#{seq}")
          return nil
        end

        line = read_line(sock, IO_TIMEOUT)
        unless line
          note_failure
          log("read timeout/eof seq=#{seq}")
          return nil
        end

        # 4 段协议：`RESP\t<seq>\t<base64>\tPENDING`；第 4 段省略 = 正常译文。
        fields = line.split("\t", 4)
        unless fields.size >= 3 && fields[0] == 'RESP' && fields[1] == seq.to_s
          note_failure
          log("bad response seq=#{seq} #{line[0, 160].inspect}")
          return nil
        end

        is_pending = fields.size >= 4 && fields[3].strip == 'PENDING'
        translated = fields[2].strip.unpack1('m0').force_encoding('UTF-8')
        unless translated.valid_encoding? && !translated.empty?
          note_failure
          log("bad payload seq=#{seq}")
          return nil
        end

        log("RESP seq=#{seq}#{is_pending ? ' (pending)' : ''} #{translated.inspect}")
        [translated, is_pending]
      rescue Exception => e
        note_failure
        log("request failed seq=#{seq}: #{e.class}: #{e.message}")
        nil
      ensure
        begin
          sock.close if sock && !sock.closed?
        rescue Exception
        end
      end
    end

    # mkxp-z 的 socket 库不一定带 Socket.tcp（实测只有 TCPSocket），两条路都留着。
    # TCPSocket.new 没有 connect_timeout；默认 host 是 127.0.0.1，连接要么立即成功，
    # 要么立即被拒绝，不会出现远端不可达那种长阻塞。
    def open_socket
      if defined?(Socket) && Socket.respond_to?(:tcp)
        Socket.tcp(host, port, connect_timeout: CONNECT_TIMEOUT)
      elsif defined?(TCPSocket)
        TCPSocket.new(host, port)
      else
        raise 'no socket class'
      end
    end

    def write_all(sock, data, timeout)
      deadline = monotonic + timeout
      data = data.b

      until data.empty?
        written = sock.write_nonblock(data, exception: false)

        case written
        when :wait_writable
          remain = deadline - monotonic
          return false if remain <= 0
          return false unless IO.select(nil, [sock], nil, remain)
        when :wait_readable
          remain = deadline - monotonic
          return false if remain <= 0
          return false unless IO.select([sock], nil, nil, remain)
        else
          return false if written.nil? || written == 0
          data = data.byteslice(written, data.bytesize - written)
        end

        return false if monotonic > deadline
      end

      true
    rescue Exception => e
      log("write_all failed: #{e.class}: #{e.message}")
      false
    end

    def read_line(sock, timeout)
      deadline = monotonic + timeout
      buf = String.new
      buf.force_encoding(Encoding::BINARY)

      loop do
        chunk = sock.read_nonblock(4096, exception: false)

        case chunk
        when :wait_readable
          remain = deadline - monotonic
          return nil if remain <= 0
          return nil unless IO.select([sock], nil, nil, remain)
        when :wait_writable
          remain = deadline - monotonic
          return nil if remain <= 0
          return nil unless IO.select(nil, [sock], nil, remain)
        when nil
          break
        else
          buf << chunk
          idx = buf.index("\n")
          return buf[0, idx] if idx
        end

        return nil if monotonic > deadline
      end

      buf.empty? ? nil : buf
    rescue Exception => e
      log("read_line failed: #{e.class}: #{e.message}")
      nil
    end

    # ------------------------------------------------------------------
    # 小工具
    # ------------------------------------------------------------------
    def socket_available?
      return true if defined?(TCPSocket)
      return true if defined?(Socket) && Socket.respond_to?(:tcp)

      unless $mochi_hook_socket_warned
        $mochi_hook_socket_warned = true
        log('socket unavailable; pass-through only')
      end
      false
    rescue Exception
      false
    end

    def host
      value = ENV['MOCHI_RGSS_HOST']
      value && !value.empty? ? value : HOST_DEFAULT
    end

    def port
      value = ENV['MOCHI_RGSS_PORT'].to_i
      value > 0 && value < 65_536 ? value : PORT_DEFAULT
    end

    def next_seq
      $mochi_hook_seq = ($mochi_hook_seq || 0) + 1
    end

    def cache
      $mochi_hook_cache ||= {}
    end

    # key → 可以再次请求的时刻。与 cache 分开：PENDING 的原文不是译文，不能混进 cache。
    def pending
      $mochi_hook_pending ||= {}
    end

    def cooling_down?
      until_time = $mochi_hook_cooldown_until
      until_time && monotonic < until_time
    end

    def note_failure
      $mochi_hook_cooldown_until = monotonic + COOLDOWN_SECONDS
    rescue Exception
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    rescue Exception
      Time.now.to_f
    end

    def log(message)
      path = ENV['MOCHI_RGSS_LOG'] || '/tmp/mochi-rgss.log'

      begin
        if File.exist?(path) && File.size(path) > LOG_MAX_BYTES
          File.open(path, 'w') do |f|
            f.puts("[mochi-rgss] log truncated at #{Time.now}")
          end
        end
      rescue Exception
      end

      begin
        File.open(path, 'a:UTF-8') do |f|
          f.puts("[#{Time.now.strftime('%Y-%m-%d %H:%M:%S')}] #{message}")
        end
      rescue Exception
      end
    end
  end
end

begin
  require 'socket'
rescue LoadError => e
  MochiRGSSHook.log("socket unavailable at load: #{e.class}: #{e.message}")
end

MochiRGSSHook.install
