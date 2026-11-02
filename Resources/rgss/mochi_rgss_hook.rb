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
#   MOCHI_RGSS_HOST=...     默认 127.0.0.1
#   MOCHI_RGSS_PORT=...     默认 47123
#   MOCHI_RGSS_LOG=...      默认 /tmp/mochi-rgss.log（超过 1 MB 自动截断）
#
# 行协议（UTF-8 文本，字段用 TAB 分隔，行尾 LF，base64 用 pack('m0')）：
#   → TEXT\t<seq>\t<RGSS1|RGSS2|RGSS3>\t<base64(原文)>
#   ← RESP\t<seq>\t<base64(译文)>
#
# 设计约束：
#   * 只依赖 Ruby 内置的 socket；不 require json / net/http / yaml / uri / time。
#   * 任何失败（连不上、超时、协议错、base64 错）都静默放行原文。
#   * 用非阻塞 IO + 截止时间，绝不无限期阻塞游戏主线程。
#   * 幂等：重复加载不会重复 hook（$mochi_hook_installed）。

module MochiRGSSHook
  # 重复 load 时不要重定义常量（Ruby 会刷 already initialized constant 警告）。
  HOST_DEFAULT      = '127.0.0.1' unless const_defined?(:HOST_DEFAULT, false)
  PORT_DEFAULT      = 47_123      unless const_defined?(:PORT_DEFAULT, false)
  CONNECT_TIMEOUT   = 0.2         unless const_defined?(:CONNECT_TIMEOUT, false)
  IO_TIMEOUT        = 0.2         unless const_defined?(:IO_TIMEOUT, false)
  COOLDOWN_SECONDS  = 2.0         unless const_defined?(:COOLDOWN_SECONDS, false)
  LOG_MAX_BYTES     = 1024 * 1024 unless const_defined?(:LOG_MAX_BYTES, false)
  CACHE_MAX         = 256         unless const_defined?(:CACHE_MAX, false)

  # 顺序即优先级：VX Ace 有 process_all_text，VX 有 start_message，XP 有 refresh。
  # 不要只认一个方法名——XP 没有 draw_text_ex，XP/VX 都没有 process_all_text。
  ENTRY_TABLE = [
    [:process_all_text, 'RGSS3'],
    [:start_message,    'RGSS2'],
    [:refresh,          'RGSS1']
  ].freeze unless const_defined?(:ENTRY_TABLE, false)

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

      log("socket probe: Socket.tcp=#{defined?(Socket) && Socket.respond_to?(:tcp) ? 'yes' : 'no'} TCPSocket=#{defined?(TCPSocket) ? 'yes' : 'no'}")

      if window_message_defined?
        hook_window_message('defined-at-load')
      else
        arm_tracepoint
      end
    rescue Exception => e
      log("install failed: #{e.class}: #{e.message}")
    end

    def disabled?
      ENV['MOCHI_RGSS_HOOK'].to_s.downcase == 'off'
    rescue Exception
      false
    end

    def window_message_defined?
      Object.const_defined?(:Window_Message) &&
        Object.const_get(:Window_Message).is_a?(Class)
    rescue Exception
      false
    end

    # preload 阶段 Window_Message 还没定义：等类定义结束再挂。
    def arm_tracepoint
      $mochi_hook_trace = TracePoint.new(:end) do |tp|
        begin
          next unless tp.self.is_a?(Class) && tp.self.name == 'Window_Message'

          hook_window_message('tracepoint')
          if $mochi_hook_entry && $mochi_hook_trace
            $mochi_hook_trace.disable
          end
        rescue Exception => e
          log("tracepoint callback error: #{e.class}: #{e.message}")
        end
      end
      $mochi_hook_trace.enable
      log('tracepoint armed; waiting for Window_Message')
    rescue Exception => e
      log("tracepoint arm failed: #{e.class}: #{e.message}")
    end

    # 只 hook 一个入口；按“方法存在”判断（默认脚本的入口都定义在 Window_Message 自身）。
    def hook_window_message(trigger)
      return if $mochi_hook_entry

      cls = Object.const_get(:Window_Message)
      entry = nil
      version = nil

      ENTRY_TABLE.each do |name, ver|
        if cls.method_defined?(name) || cls.private_method_defined?(name)
          entry = name
          version = ver
          break
        end
      end

      unless entry
        log('Window_Message found but no known text entry; waiting for another class end')
        return
      end

      hook_entry = entry
      hook_version = version
      was_private = cls.private_method_defined?(entry)

      cls.class_eval do
        alias_method :"mochi_orig_#{hook_entry}", hook_entry

        define_method(hook_entry) do |*args|
          begin
            MochiRGSSHook.rewrite(hook_version)
          rescue Exception => e
            MochiRGSSHook.log("hook body error: #{e.class}: #{e.message}")
          end
          send(:"mochi_orig_#{hook_entry}", *args)
        end

        private hook_entry if was_private
      end

      $mochi_hook_entry = entry
      $mochi_hook_version = version
      log("hooked Window_Message##{entry} as #{version} (trigger=#{trigger})")
    rescue Exception => e
      log("hook_window_message failed: #{e.class}: #{e.message}")
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

      translated = request(text, version)
      return nil unless translated

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

        fields = line.split("\t", 3)
        unless fields.size == 3 && fields[0] == 'RESP' && fields[1] == seq.to_s
          note_failure
          log("bad response seq=#{seq} #{line[0, 160].inspect}")
          return nil
        end

        translated = fields[2].strip.unpack1('m0').force_encoding('UTF-8')
        unless translated.valid_encoding? && !translated.empty?
          note_failure
          log("bad payload seq=#{seq}")
          return nil
        end

        log("RESP seq=#{seq} #{translated.inspect}")
        translated
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
