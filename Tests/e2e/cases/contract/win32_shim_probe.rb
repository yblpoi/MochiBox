# -*- coding: utf-8 -*-
# frozen_string_literal: false
#
# win32_shim_probe.rb —— Resources/rgss/mochi_win32_shim.rb 的合同测试探针。
#
# 用法：ruby win32_shim_probe.rb <hook.rb> <shim.rb> <scenario>
#   contract          纯 MRI：stub Win32API 后 load shim，验证安装/分派/INI/兜底
#   disabled          MOCHI_WIN32_SHIM=off：保留原 new 行为，shim 不接管
#   no-host           宿主没有 Win32API：install! 返回 false，之后可重试
#   hook-on           load mochi_rgss_hook.rb：hook 正常 + shim 在 preload 链上生效
#   hook-off-shim-on  MOCHI_RGSS_HOOK=off：hook 提前返回，但 shim 仍安装
#   hook-missing-shim 把 hook 复制到没有 shim 的目录：hook 照常安装并记录失败
#
# 断言只测 shim 自己的契约：不依赖 GUI、不依赖 mkxp-z；每个场景独立进程。
# TAP 输出与 Tests/e2e/lib/tap.mjs 的 absorbTap 兼容，退出码 = 失败数 > 0 ? 1 : 0。

require 'tmpdir'
require 'fileutils'

$total = 0
$passed = 0
$failed = 0

LOG_PATH = File.join(Dir.tmpdir, "mochi-win32-shim-#{Process.pid}.log")
ENV['MOCHI_RGSS_LOG'] = LOG_PATH
begin
  File.delete(LOG_PATH)
rescue Exception
end

def ok(condition, name, detail = nil)
  $total += 1
  if condition
    $passed += 1
    puts "ok #{$total} - #{name}"
  else
    $failed += 1
    puts "not ok #{$total} - #{name}"
    if detail
      detail.to_s.split("\n").each { |line| puts "#   #{line}" }
    end
  end
end

def eq(actual, expected, name)
  ok(actual == expected, name, "期望: #{expected.inspect}\n实际: #{actual.inspect}")
end

def no_raise(name)
  yield
  ok(true, name)
rescue Exception => e
  ok(false, name, "#{e.class}: #{e.message}")
end

def log_text
  File.exist?(LOG_PATH) ? File.read(LOG_PATH) : ''
rescue Exception
  ''
end

# 模拟 mkxp-z 之外的真实 Win32API：new 直接失败（dlopen 找不到 DLL）。
def define_stub_win32api
  return if Object.const_defined?(:Win32API)

  klass = Class.new
  def klass.new(*_args)
    raise 'original Win32API.new unavailable (dlopen failed)'
  end
  Object.const_set(:Win32API, klass)
end

# ----------------------------------------------------------------------
# contract：核心契约
# ----------------------------------------------------------------------
def scenario_contract(shim)
  define_stub_win32api
  load shim

  ok(defined?(MochiWin32Shim) == 'constant', 'shim 定义 MochiWin32Shim')
  ok(MochiWin32Shim.handler_count >= 60, '注册表覆盖至少 60 个 (dll, func)', MochiWin32Shim.handler_count)
  eq(MochiWin32Shim.handler_for('kernel32', 'gettickcount'), :handle_get_tick_count, 'kernel32 函数名大小写不敏感')
  eq(MochiWin32Shim.handler_for('KERNEL32.DLL', 'gettickcount'), :handle_get_tick_count, 'dll 名忽略大小写与后缀')
  eq(MochiWin32Shim.handler_for('kernelbase', 'gettickcount'), :handle_get_tick_count, 'kernelbase 别名到 kernel32')

  api = Win32API.new('kernel32', 'GetTickCount', '', 'L')
  ok(api.is_a?(MochiWin32Shim::Api), 'Win32API.new 返回 shim 对象')
  eq(api.dll, 'kernel32', 'shim 对象保留 dll')
  eq(api.export_type, :int, "exports 'L' 解析为 int")
  eq(api.import_types, [], 'imports 空串解析为空清单')
  ok(log_text.include?('[win32] installed'), '安装日志带 [win32] 前缀')

  before = Win32API.method(:new)
  eq(MochiWin32Shim.install!, true, '重复 install! 仍返回 true')
  eq(Win32API.method(:new), before, '重复 install! 不重复覆盖 new')

  # imports / exports 的所有声明形状都必须能构造且 call 不 raise。
  shapes = [
    ['PPPPLLP', 'L'],
    [['P', 'P', 'P', 'P', 'L', 'L', 'P'], ['L']],
    [nil, nil],
    ['', ''],
    [0, 2],
    [['n'], ['L']],
    [Object.new, Object.new],
    [{ 'a' => 1 }, [1, 2, 3]]
  ]
  shapes.each_with_index do |pair, index|
    no_raise("imports/exports 形状 #{index} 可构造且 call 不 raise") do
      object = Win32API.new('kernel32', 'ProbeUnknownShape', pair[0], pair[1])
      object.call(1, 'x', nil)
    end
  end

  # 未知函数按 exports 兜底
  eq(Win32API.new('kernel32', 'ProbeUnknownPtr', '', 'P').Call, '', '未知 P 返回空串')
  eq(Win32API.new('kernel32', 'ProbeUnknownInt', '', 'L').Call, 0, '未知 L 返回 0')
  eq(Win32API.new('kernel32', 'ProbeUnknownInt2', '', 'N').Call, 0, '未知 N 返回 0')
  eq(Win32API.new('kernel32', 'ProbeUnknownInt3', '', 'I').Call, 0, '未知 I 返回 0')
  eq(Win32API.new('kernel32', 'ProbeUnknownVoid', '', 'V').Call, nil, '未知 V 返回 nil')
  eq(Win32API.new('kernel32', 'ProbeUnknownNil', '', nil).Call, nil, '未知 nil exports 返回 nil')
  eq(Win32API.new('kernel32', 'ProbeUnknownArr', '', ['P']).Call, '', '未知 Array exports 按首字符兜底')
  eq(Win32API.new('kernel32', 'ProbeUnknownCode', '', 2).Call, 0, '未知整数类型码按 int 兜底')
  eq(Win32API.new('kernel32', 'ProbeUnknownSym', '', :l).Call, 0, '未知 Symbol exports 不 raise')
  eq(Win32API.new(nil, nil, nil, nil).Call, nil, 'dll/func 为 nil 时安全兜底')

  ptr_api = Win32API.new('kernel32', 'ProbeUnknownPtr', '', 'P')
  eq(ptr_api.call, ptr_api.Call, 'call 与 Call 等价')
  eq(ptr_api.Call(1, 2, 3), ptr_api.call(4, 5, 6), '任意参数个数下 call/Call 一致')

  logged = Win32API.new('kernel32', 'ProbeUnknownLogged', '', 'L')
  3.times { logged.call }
  eq(log_text.scan('unknown api kernel32!probeunknownlogged').size, 1, '同一未知 API 只记一次日志')

  no_raise('未知 API 的日志参数只摘要，不整段输出') do
    Win32API.new('kernel32', 'ProbeSecret', '', 'L').Call('secret-value-1234567890', 7)
  end
  ok(log_text.include?('ProbeSecret'.downcase), '未知 API 记录函数名')
  ok(!log_text.include?('secret-value-1234567890'), '未知 API 不整段记录参数值')

  # ---- INI 真读写（cwd 相对路径） ----
  dir = Dir.mktmpdir('mochi-win32-contract')
  begin
    Dir.chdir(dir) do
      write_a = Win32API.new('kernel32', 'WritePrivateProfileStringA', 'SSSS', 'L')
      read_a = Win32API.new('kernel32', 'GetPrivateProfileStringA', 'SSSSLP', 'L')
      int_a = Win32API.new('kernel32', 'GetPrivateProfileIntA', 'SSSL', 'L')
      write_w = Win32API.new('kernel32', 'WritePrivateProfileStringW', 'SSSS', 'L')
      read_w = Win32API.new('kernel32', 'GetPrivateProfileStringW', 'SSSSLP', 'L')

      eq(write_a.Call('Mochi', 'Lang', 'zh-CN', 'Game.ini'), 1, 'WritePrivateProfileStringA 返回 1')
      content = File.binread(File.join(dir, 'Game.ini'))
      ok(content.include?("[Mochi]\nLang=zh-CN"), 'INI 落盘内容正确', content.inspect)

      buf = ("\x00".b * 64)
      n = read_a.Call('mochi', 'LANG', 'fallback', buf, 64, 'Game.ini')
      eq(n, 5, 'GetPrivateProfileStringA 返回写入字节数')
      eq(buf.byteslice(0, 5), 'zh-CN'.b, '缓冲区写入值')
      eq(buf.getbyte(5), 0, '缓冲区以 NUL 终止')
      eq(buf.bytesize, 64, '不改变调用方缓冲区大小')
      eq(buf.byteslice(6, 58), ("\x00".b * 58), '缓冲区剩余部分清零')

      buf2 = ('X'.b * 32)
      n2 = read_a.Call('Mochi', 'Missing', 'fallback', buf2, 32, 'Game.ini')
      eq(n2, 8, '缺失 key 返回默认值长度')
      eq(buf2.byteslice(0, 8), 'fallback'.b, '缺失 key 写入默认值')

      small = ("\x00".b * 5)
      n3 = read_a.Call('Mochi', 'Lang', 'x', small, 5, 'Game.ini')
      eq(n3, 4, '缓冲区不足时返回实际写入字节数')
      eq(small.byteslice(0, 4), 'zh-C'.b, '缓冲区不足时截断并保留 NUL')
      eq(small.getbyte(4), 0, '截断后仍以 NUL 终止')

      eq(int_a.Call('Mochi', 'Missing', 7, 'Game.ini'), 7, 'GetPrivateProfileIntA 缺失返回默认')
      write_a.Call('Mochi', 'Text', 'abc', 'Game.ini')
      eq(int_a.Call('Mochi', 'Text', 99, 'Game.ini'), 0, '非数字值按 atoi 语义返回 0')
      write_a.Call('Mochi', 'Hex', '0x1f', 'Game.ini')
      eq(int_a.Call('Mochi', 'Hex', 0, 'Game.ini'), 31, '0x 前缀按十六进制解析')
      write_a.Call('Mochi', 'Neg', '-3', 'Game.ini')
      eq(int_a.Call('Mochi', 'Neg', 0, 'Game.ini'), -3, '负整数正常解析')

      # 大小写不敏感写入 + 不产生重复 key
      eq(write_a.Call('MOCHI', 'lang', 'en', 'Game.ini'), 1, 'section/key 大小写不敏感地更新')
      content = File.binread(File.join(dir, 'Game.ini'))
      eq(content.scan(/^lang=/i).size, 1, '更新已有 key 不产生重复行')
      ok(content.include?('Lang=en'), '更新后的值写回')

      # W 变体：写 UTF-8 参数、读 UTF-16LE 缓冲区
      eq(write_w.Call('Mochi', 'Wide', '你好', 'Game.ini'), 1, 'WritePrivateProfileStringW 返回 1')
      wbuf = ("\x00".b * 64)
      wn = read_w.Call('Mochi', 'Wide', '', wbuf, 64, 'Game.ini')
      eq(wn, 2, 'W 变体返回 UTF-16 码元数')
      eq(wbuf.byteslice(0, 4).force_encoding(Encoding::UTF_16LE).encode(Encoding::UTF_8), '你好', 'W 缓冲区是 UTF-16LE')

      # 注释与顺序保留
      comments = File.join(dir, 'Comments.ini')
      File.binwrite(comments, "; top\n[Sec]\n; keep me\nAlpha=1\nBeta=2\n")
      eq(write_a.Call('Sec', 'Beta', '9', 'Comments.ini'), 1, '改写已有 key 返回 1')
      text = File.binread(comments)
      ok(text.include?('; keep me'), '改写保留注释')
      ok(text.include?('Alpha=1'), '改写保留其它 key')
      ok(text.include?('Beta=9'), '改写写入新值')
      eq(text.scan(/^Beta=/i).size, 1, '改写不产生重复 key')

      eq(write_a.Call('Sec', 'Alpha', nil, 'Comments.ini'), 1, 'value=nil 删除 key 返回 1')
      text = File.binread(comments)
      ok(!text.include?('Alpha=1'), '删除 key 生效')

      eq(write_a.Call('Sec', nil, nil, 'Comments.ini'), 1, 'key/value 均为 nil 删除整段')
      text = File.binread(comments)
      ok(!text.include?('[Sec]'), '删除整段生效')

      eq(write_a.Call('', 'K', 'V', 'Game.ini'), 0, '空 section 返回 0 不 raise')
      eq(write_a.Call('S', 'K', 'V', ''), 0, '空文件名返回 0 不 raise')
      eq(write_a.Call('S', 'K', 'V', 'no/such/dir/Game.ini'), 0, '目录不存在返回 0 不 raise')

      no_raise('GetPrivateProfileStringA 全 nil 参数不 raise') do
        read_a.Call(nil, nil, nil, nil, nil, nil)
      end
      no_raise('read 的缓冲区为 frozen String 时不 raise') do
        read_a.Call('Mochi', 'Lang', 'x', ('x' * 8).freeze, 8, 'Game.ini')
      end

      # 编码：GBK / UTF-8 BOM / UTF-16LE BOM / 非法字节
      gbk = File.join(dir, 'Gbk.ini')
      File.binwrite(gbk, "[Mochi]\nName=".b + "\xC4\xE3\xBA\xC3".b + "\n".b)
      gbuf = ("\x00".b * 32)
      gn = read_a.Call('Mochi', 'Name', '?', gbuf, 32, 'Gbk.ini')
      eq(gn, 6, 'GBK 值按 CP936 转 UTF-8 后返回字节数')
      eq(gbuf.byteslice(0, 6).force_encoding(Encoding::UTF_8), '你好', 'GBK 值正确解码')

      bom = File.join(dir, 'Bom.ini')
      File.binwrite(bom, "\xEF\xBB\xBF".b + "[Mochi]\nName=bom\n".b)
      bbuf = ("\x00".b * 16)
      eq(read_a.Call('Mochi', 'Name', '?', bbuf, 16, 'Bom.ini'), 3, 'UTF-8 BOM 不进入值')
      eq(bbuf.byteslice(0, 3), 'bom'.b, 'UTF-8 BOM 文件读取正确')

      utf16 = File.join(dir, 'Utf16.ini')
      File.binwrite(utf16, "\xFF\xFE".b + "[Mochi]\nName=wide\n".encode('UTF-16LE').b)
      ubuf = ("\x00".b * 16)
      eq(read_a.Call('Mochi', 'Name', '?', ubuf, 16, 'Utf16.ini'), 4, 'UTF-16LE BOM 文件可读')
      eq(ubuf.byteslice(0, 4), 'wide'.b, 'UTF-16LE 值转成 UTF-8')

      bad = File.join(dir, 'Bad.ini')
      File.binwrite(bad, "[Mochi]\nName=".b + "\xFF\xFE\xFD".b + "\n".b)
      no_raise('非法编码字节不 raise') do
        bad_buf = ("\x00".b * 32)
        read_a.Call('Mochi', 'Name', '?', bad_buf, 32, 'Bad.ini')
      end

      # ---- kernel32 其它 ----
      tick = Win32API.new('kernel32', 'GetTickCount', '', 'L').Call
      ok(tick.is_a?(Integer) && tick >= 0, 'GetTickCount 返回非负整数', tick.inspect)
      t64 = Win32API.new('kernel32', 'GetTickCount64', '', 'Q').Call
      ok(t64.is_a?(Integer) && t64 >= tick, 'GetTickCount64 >= GetTickCount', [tick, t64].inspect)

      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      Win32API.new('kernel32', 'Sleep', 'L', 'V').Call(5000)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
      ok(elapsed < 0.5, 'Sleep 单次封顶（5000ms 不会真睡 5 秒）', elapsed)
      ok(elapsed >= 0.005, 'Sleep 至少睡了一小会儿', elapsed)

      qpc = Win32API.new('kernel32', 'QueryPerformanceCounter', 'P', 'L').Call(0)
      ok(qpc.is_a?(Integer), 'QueryPerformanceCounter 返回整数')
      eq(Win32API.new('kernel32', 'QueryPerformanceFrequency', 'P', 'L').Call(0), 1_000_000_000, 'QueryPerformanceFrequency 固定 1e9')
      eq(Win32API.new('kernel32', 'GetModuleHandleA', 'P', 'L').Call('kernel32'), 0, 'GetModuleHandleA 返回 0')

      module_path = ("\x00".b * 512)
      module_len = Win32API.new('kernel32', 'GetModuleFileNameA', 'LPL', 'L').Call(0, module_path, 512)
      expected_path = File.join(Dir.pwd, 'Game.ini')
      eq(module_len, expected_path.bytesize, 'GetModuleFileNameA 返回路径长度')
      eq(module_path.byteslice(0, expected_path.bytesize), expected_path.b, 'GetModuleFileNameA 写 cwd/Game.ini')

      eq(Win32API.new('kernel32', 'lstrlenA', 'P', 'L').Call('abc'), 3, 'lstrlenA 返回字节数')
      eq(Win32API.new('kernel32', 'lstrlenA', 'P', 'L').Call('你好'), 6, 'lstrlenA 对 UTF-8 返回字节数')
      eq(Win32API.new('kernel32', 'GlobalAlloc', 'LL', 'L').Call(0, 16), 0, 'GlobalAlloc 不假造内存')
      eq(Win32API.new('kernel32', 'GlobalFree', 'L', 'L').Call(0), 1, 'GlobalFree 返回 1')
      eq(Win32API.new('kernel32', 'GetCommandLineA', '', 'P').Call, '', 'GetCommandLineA 返回空串')
      eq(Win32API.new('kernel32', 'GetLastError', '', 'L').Call, 0, 'GetLastError 返回 0')
      eq(Win32API.new('kernel32', 'SetLastError', 'L', 'V').Call(5), nil, 'SetLastError 无返回值')
      eq(Win32API.new('kernel32', 'GetVersion', '', 'L').Call, 0, 'GetVersion 返回 0')

      # ---- user32 ----
      eq(Win32API.new('user32', 'GetAsyncKeyState', 'L', 'L').Call(0x41), 0, 'GetAsyncKeyState 恒 0')
      eq(Win32API.new('user32', 'GetKeyState', 'L', 'L').Call(0x41), 0, 'GetKeyState 恒 0')
      keyboard = ("\xFF".b * 256)
      eq(Win32API.new('user32', 'GetKeyboardState', 'P', 'L').Call(keyboard), 0, 'GetKeyboardState 返回 0')
      eq(keyboard, ("\x00".b * 256), 'GetKeyboardState 清零缓冲区')
      cursor = ("\xFF".b * 8)
      eq(Win32API.new('user32', 'GetCursorPos', 'P', 'L').Call(cursor), 1, 'GetCursorPos 返回 1')
      eq(cursor, ("\x00".b * 8), 'GetCursorPos 写 0,0')
      eq(Win32API.new('user32', 'SetCursorPos', 'LL', 'L').Call(10, 20), 1, 'SetCursorPos 返回 1')
      eq(Win32API.new('user32', 'MessageBoxA', 'LSSLL', 'L').Call(0, 'hello', 'cap', 0), 1, 'MessageBoxA 返回 IDOK')
      ok(log_text.include?('MessageBox: hello / cap'), 'MessageBox 文本进日志')
      eq(Win32API.new('user32', 'FindWindowA', 'SS', 'L').Call('a', 'b'), 0, 'FindWindowA 返回 0')
      eq(Win32API.new('user32', 'SetWindowTextA', 'LP', 'L').Call(0, 'x'), 1, 'SetWindowTextA 返回 1')
      eq(Win32API.new('user32', 'GetSystemMetrics', 'L', 'L').Call(0), 1024, 'GetSystemMetrics(0)=1024')
      eq(Win32API.new('user32', 'GetSystemMetrics', 'L', 'L').Call(1), 768, 'GetSystemMetrics(1)=768')
      eq(Win32API.new('user32', 'GetSystemMetrics', 'L', 'L').Call(99), 0, 'GetSystemMetrics 其它=0')
      eq(Win32API.new('user32', 'ShowCursor', 'L', 'L').Call(1), 0, 'ShowCursor 返回 0')
      eq(Win32API.new('user32', 'GetForegroundWindow', '', 'L').Call, 0, 'GetForegroundWindow 返回 0')
      eq(Win32API.new('user32', 'GetActiveWindow', '', 'L').Call, 0, 'GetActiveWindow 返回 0')
      eq(Win32API.new('user32', 'GetDC', 'L', 'L').Call(0), 0, 'GetDC 返回 0')
      eq(Win32API.new('user32', 'ReleaseDC', 'LL', 'L').Call(0, 0), 1, 'ReleaseDC 返回 1')
      no_raise('keybd_event/mouse_event 不 raise') do
        Win32API.new('user32', 'keybd_event', 'LLLL', 'V').Call(65, 0, 0, 0)
        Win32API.new('user32', 'mouse_event', 'LLLLL', 'V').Call(1, 0, 0, 0, 0)
      end
      eq(Win32API.new('user32', 'GetDoubleClickTime', '', 'L').Call, 500, 'GetDoubleClickTime=500')

      # ---- winmm ----
      mci = Win32API.new('winmm', 'mciSendStringA', 'SSLP', 'L')
      eq(mci.Call('open bgm.mp3 alias bgm', nil, 0, 0), 0, 'MCI open 返回 0')
      eq(mci.Call('play bgm', nil, 0, 0), 0, 'MCI play 返回 0（不实现播放）')
      status = ("\x00".b * 32)
      eq(mci.Call('status bgm mode', status, 32, 0), 0, 'MCI status 返回 0')
      eq(status.byteslice(0, 7), 'playing'.b, 'MCI status 写 playing')
      eq(mci.Call('close bgm', nil, 0, 0), 0, 'MCI close 返回 0')
      closed = ("\x00".b * 16)
      mci.Call('status bgm mode', closed, 16, 0)
      eq(closed.getbyte(0), 0, 'MCI close 后 status 为空')
      eq(mci.Call('set bgm volume 100', nil, 0, 0), 0, '未知 MCI 命令返回 0')
      ok(log_text.include?('MCI: open bgm.mp3 alias bgm'), 'MCI 命令进日志')
      eq(Win32API.new('winmm', 'PlaySoundA', 'PLL', 'L').Call('x.wav', 0, 0), 1, 'PlaySoundA 返回 1')
      ok(Win32API.new('winmm', 'timeGetTime', '', 'L').Call.is_a?(Integer), 'timeGetTime 返回整数')
      eq(Win32API.new('winmm', 'timeBeginPeriod', 'L', 'L').Call(1), 0, 'timeBeginPeriod 返回 0')
      eq(Win32API.new('winmm', 'timeEndPeriod', 'L', 'L').Call(1), 0, 'timeEndPeriod 返回 0')

      # ---- version / gdi32 / advapi32 ----
      eq(Win32API.new('version', 'GetFileVersionInfoSizeA', 'SP', 'L').Call('x.exe', 0), 0, 'GetFileVersionInfoSizeA 返回 0')
      eq(Win32API.new('version', 'GetFileVersionInfoA', 'SLLP', 'L').Call('x.exe', 0, 0, nil), 0, 'GetFileVersionInfoA 返回 0')
      eq(Win32API.new('version', 'VerQueryValueA', 'PSPP', 'L').Call(nil, '\\', nil, nil), 0, 'VerQueryValueA 返回 0')
      eq(Win32API.new('gdi32', 'CreateFontIndirectA', 'P', 'L').Call(0), 0, 'CreateFontIndirectA 返回 0')
      eq(Win32API.new('gdi32', 'DeleteObject', 'L', 'L').Call(0), 1, 'DeleteObject 返回 1')
      eq(Win32API.new('gdi32', 'GetDeviceCaps', 'LL', 'L').Call(0, 88), 0, 'GetDeviceCaps 返回 0')

      handle = ("\xFF".b * 4)
      eq(Win32API.new('advapi32', 'RegOpenKeyExA', 'PLLLPL', 'L').Call('HKEY_CURRENT_USER', 'Software\\Probe', 0, 0x20019, handle, 260), 2, 'RegOpenKeyExA 返回 ERROR_FILE_NOT_FOUND')
      eq(handle.unpack('V').first, 0, 'RegOpenKeyExA 写 0 句柄')
      eq(Win32API.new('advapi32', 'RegQueryValueExA', 'LPLLLL', 'L').Call(0, 'x', 0, 0, nil, nil), 2, 'RegQueryValueExA 返回 2')
      eq(Win32API.new('advapi32', 'RegCloseKey', 'L', 'L').Call(0), 0, 'RegCloseKey 返回 0')

      no_raise('已知 API 全 nil/garbage 参数不 raise') do
        read_a.Call(nil, nil, nil, nil, nil, nil)
        Win32API.new('kernel32', 'GetModuleFileNameA', 'LPL', 'L').Call(nil, nil, nil)
        mci.Call(nil, nil, nil, nil)
        Win32API.new('user32', 'MessageBoxA', 'LSSLL', 'L').Call(nil, nil, nil, nil)
        Win32API.new('advapi32', 'RegOpenKeyExA', 'PLLLPL', 'L').Call(nil, nil, nil, nil, nil, nil)
      end
    end
  ensure
    begin
      FileUtils.remove_entry(dir)
    rescue Exception
    end
  end
end

# ----------------------------------------------------------------------
# disabled / no-host / hook 集成
# ----------------------------------------------------------------------
def scenario_disabled(_hook, shim)
  define_stub_win32api
  load shim

  eq($mochi_win32_shim_installed, true, 'MOCHI_WIN32_SHIM=off 时 install! 仍标记已处理')
  raised = false
  begin
    Win32API.new('kernel32', 'GetTickCount', '', 'L')
  rescue Exception
    raised = true
  end
  ok(raised, '关闭时保留原 new 行为（仍抛错）')
  ok(log_text.include?('disabled by MOCHI_WIN32_SHIM=off'), '关闭状态写日志')
  ok(!log_text.include?('[win32] installed'), '关闭时不写安装日志')
end

def scenario_no_host(_hook, shim)
  ok(!defined?(Win32API), '测试进程里故意没有 Win32API 常量')
  load shim

  eq(MochiWin32Shim.install!, false, '宿主没有 Win32API 时 install! 返回 false')
  ok(log_text.include?('Win32API/MiniFFI not defined'), '记录未定义日志')
  define_stub_win32api
  eq(MochiWin32Shim.install!, true, '定义 Win32API 后可重试安装')
  ok(Win32API.new('kernel32', 'GetTickCount', '', 'L').is_a?(MochiWin32Shim::Api), '重试后 new 返回 shim 对象')
end

def scenario_hook(hook, _shim, hook_disabled)
  define_stub_win32api
  load hook

  eq($mochi_hook_installed, true, 'hook 自身完成安装')
  ok(Win32API.new('kernel32', 'GetTickCount', '', 'L').is_a?(MochiWin32Shim::Api), 'preload 链上 Win32API shim 生效')
  eq(Win32API.new('user32', 'GetAsyncKeyState', 'L', 'L').Call(0x41), 0, 'hook 链上 user32 走安全实现')
  ok(log_text.include?('[win32] installed'), 'hook 链上记录 shim 安装日志')

  if hook_disabled
    ok(log_text.include?('hook disabled by MOCHI_RGSS_HOOK=off'), 'MOCHI_RGSS_HOOK=off 记录关闭日志')
    ok(!log_text.include?('surfaces enabled'), 'MOCHI_RGSS_HOOK=off 时 hook 翻译逻辑未启动')
  else
    ok(log_text.include?('surfaces enabled'), 'hook 翻译逻辑照常启动')
  end
end

def scenario_missing_shim(hook, _shim)
  dir = Dir.mktmpdir('mochi-win32-hookcopy')
  copy = File.join(dir, 'mochi_rgss_hook.rb')
  FileUtils.cp(hook, copy)
  define_stub_win32api

  begin
    load copy
    ok(true, 'shim 文件缺失时 hook 加载不抛异常')
  rescue Exception => e
    ok(false, 'shim 文件缺失时 hook 加载不抛异常', "#{e.class}: #{e.message}")
    return
  ensure
    begin
      FileUtils.remove_entry(dir)
    rescue Exception
    end
  end

  eq($mochi_hook_installed, true, 'shim 缺失时 hook 仍完成安装')
  ok(log_text.include?('win32 shim load failed (hook continues)'), 'shim 缺失写日志并继续')
  raised = false
  begin
    Win32API.new('kernel32', 'GetTickCount', '', 'L')
  rescue Exception
    raised = true
  end
  ok(raised, 'shim 缺失时 Win32API 保持原行为（证明 hook 没被拖挂）')
end

hook_path = ARGV[0].to_s
shim_path = ARGV[1].to_s
scenario = ARGV[2].to_s

case scenario
when 'contract'
  scenario_contract(shim_path)
when 'disabled'
  scenario_disabled(hook_path, shim_path)
when 'no-host'
  scenario_no_host(hook_path, shim_path)
when 'hook-on'
  scenario_hook(hook_path, shim_path, false)
when 'hook-off-shim-on'
  scenario_hook(hook_path, shim_path, true)
when 'hook-missing-shim'
  scenario_missing_shim(hook_path, shim_path)
else
  puts "not ok 1 - 未知场景 #{scenario}"
  $failed += 1
end

puts "# pass #{$passed} fail #{$failed}"
exit($failed.zero? ? 0 : 1)
