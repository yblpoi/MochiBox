# -*- coding: utf-8 -*-
#
# rgss_surfaces_probe.rb —— 在 MRI 里用假 Window_* 类验证 hook 的文本提取与分派。
#
# 用法：ruby rgss_surfaces_probe.rb <hook.rb> <scenario>
#   scenario: xp | vx | vxace | gate-menu | failure-isolation | off
#
# 每个场景单独一个进程：hook 的安装、TracePoint、面开关都是进程级状态。
# 假类用 eval 在顶层定义，按真实默认脚本的定义顺序出现，走的是 preload 之后
# TracePoint(:end) 的路径（Class.new 不会触发 :end，不能用）。
#
# 断言只检查 hook 自己的职责：原文是否原样取到、译文是否写回、面之间是否串台、
# 关闭某个面后其它面是否真的不动。控制符分段在翻译层，这里只验证不被 hook 吞掉。

require 'socket'

$total = 0
$passed = 0
$failed = 0

def ok(condition, name, detail = nil)
  $total += 1
  if condition
    $passed += 1
    puts "ok #{$total} - #{name}"
  else
    $failed += 1
    puts "not ok #{$total} - #{name} # 条件不成立"
    puts "#   #{detail}" if detail
  end
end

def eq(actual, expected, name)
  ok(actual == expected, name, "期望: #{expected.inspect}\n实际: #{actual.inspect}")
end

def include_text(list, expected, name)
  ok(list.include?(expected), name, "期望包含: #{expected.inspect}\n实际: #{list.inspect}")
end

def define_ruby(source)
  TOPLEVEL_BINDING.eval(source)
end

class MockServer
  attr_reader :port, :requests

  def initialize(prefix)
    @prefix = prefix
    @server = TCPServer.new('127.0.0.1', 0)
    @port = @server.addr[1]
    @requests = []
    @mutex = Mutex.new
    @thread = Thread.new { serve }
  end

  def serve
    loop do
      sock = @server.accept
      begin
        while (line = sock.gets)
          fields = line.chomp.split("\t", 4)
          next unless fields[0] == 'TEXT' && fields.size >= 4

          text = fields[3].unpack1('m0').force_encoding('UTF-8')
          @mutex.synchronize { @requests << [fields[2], text] }
          sock.write("RESP\t#{fields[1]}\t#{[(@prefix + text)].pack('m0')}\n")
        end
      rescue Exception
      ensure
        begin
          sock.close unless sock.closed?
        rescue Exception
        end
      end
    end
  rescue Exception
  end

  def texts
    @mutex.synchronize { @requests.map { |request| request[1] } }
  end

  def versions
    @mutex.synchronize { @requests.map { |request| request[0] }.uniq }
  end

  def close
    begin
      @server.close
    rescue Exception
    end
    begin
      @thread.kill
    rescue Exception
    end
  end
end

def prepare(scenario, surfaces = nil)
  $seen = {}
  $surface_calls = []
  log_path = "/tmp/mochi-rgss-surfaces-#{scenario}-#{Process.pid}.log"
  begin
    File.delete(log_path)
  rescue Exception
  end

  server = MockServer.new('译:')
  ENV['MOCHI_RGSS_HOST'] = '127.0.0.1'
  ENV['MOCHI_RGSS_PORT'] = server.port.to_s
  ENV['MOCHI_RGSS_LOG'] = log_path
  if scenario == 'off'
    ENV['MOCHI_RGSS_HOOK'] = 'off'
  else
    ENV.delete('MOCHI_RGSS_HOOK')
  end
  if surfaces.nil?
    ENV.delete('MOCHI_RGSS_SURFACES')
  else
    ENV['MOCHI_RGSS_SURFACES'] = surfaces
  end

  load ARGV[0]

  # 记录分派，不改行为：hook 仍调用原方法。
  define_ruby(<<~'RUBY')
    module MochiRGSSHook
      class << self
        alias_method :probe_orig_rewrite_surface, :rewrite_surface unless method_defined?(:probe_orig_rewrite_surface)
        alias_method :probe_orig_rewrite, :rewrite unless method_defined?(:probe_orig_rewrite)

        def rewrite_surface(surface, window, args, method = nil)
          $surface_calls << [surface, window.class.name, method]
          probe_orig_rewrite_surface(surface, window, args, method)
        end

        def rewrite(version)
          $surface_calls << ['message', version, nil]
          probe_orig_rewrite(version)
        end
      end
    end
  RUBY

  [server, log_path]
end

def read_log(path)
  File.read(path)
rescue Exception
  ''
end

def define_window_base
  define_ruby(<<~'RUBY')
    class Window_Base
      def draw_text(*args)
        $seen[:draw_text] = args[4] if args.size >= 5
        true
      end
    end
  RUBY
end

def surface_names
  $surface_calls.map { |call| call[0] }.uniq
end

def run_xp
  server, log_path = prepare('xp')
  define_window_base

  define_ruby(<<~'RUBY')
    class Window_Command
      def initialize(commands)
        @commands = commands
      end

      def draw_item(index, color)
        $seen[:menu] = @commands[index]
      end
    end

    class Window_Help
      def set_text(text, align = 0)
        $seen[:help] = text
      end
    end

    class Window_Message
      def refresh
        $seen[:message] = $game_temp.message_text
      end
    end
  RUBY

  $game_temp = Struct.new(:message_text).new('こんにちは')

  message = Window_Message.new
  message.refresh
  Window_Command.new(['アイテム', 'スキル']).draw_item(0, 0)
  Window_Help.new.set_text('説明文')
  $game_temp.message_text = 'スライムが現れた！'
  message.refresh

  text = read_log(log_path)
  eq(server.versions, ['RGSS1'], 'XP 请求版本标签全部是 RGSS1')
  eq($seen[:message], '译:スライムが現れた！', 'XP 消息/战斗旁白写回译文（同一 refresh 入口）')
  eq($seen[:menu], '译:アイテム', 'XP 菜单项写回译文')
  eq($seen[:help], '译:説明文', 'XP 帮助栏写回译文')
  eq(server.texts, ['こんにちは', 'アイテム', '説明文', 'スライムが現れた！'], 'XP 送出的原文逐项正确')
  include_text(surface_names, 'message', 'XP 消息面被调用')
  include_text(surface_names, 'menu', 'XP 菜单面被调用')
  include_text(surface_names, 'help', 'XP 帮助面被调用')
  ok(text.include?('choice on RGSS1 has no separate entry'), 'XP 选项面如实记录为并入 message', text)
  ok(text.include?('battle on RGSS1 has no separate entry'), 'XP 战斗面如实记录为并入 message', text)
  ok(text.include?('tracepoint disabled (version=RGSS1)'), 'XP 所有可挂面完成后关闭 TracePoint', text)
  ok(!Window_Base.instance_methods(false).include?(:mochi_orig_draw_text), 'XP 未 hook Window_Base#draw_text')
  server.close
end

def run_vx
  server, log_path = prepare('vx')
  define_window_base

  define_ruby(<<~'RUBY')
    class Window_Command
      def initialize(commands)
        @commands = commands
      end

      def draw_item(index, enabled = true)
        $seen[:menu] = @commands[index]
      end
    end

    class Window_Help
      def set_text(text, align = 0)
        $seen[:help] = text
      end
    end

    class Window_Message
      def start_message
        $seen[:message] = $game_message.texts.dup
      end
    end

    class Window_BattleMessage < Window_Message
      def add_instant_text(text)
        $seen[:battle_add] = text
      end

      def replace_instant_text(text)
        $seen[:battle_replace] = text
      end
    end
  RUBY

  $game_message = Struct.new(:texts).new(['こんにちは'])

  Window_Message.new.start_message
  Window_Command.new(['アイテム']).draw_item(0)
  Window_Help.new.set_text('説明文')
  battle = Window_BattleMessage.new
  battle.add_instant_text('スライムが現れた！')
  battle.replace_instant_text('スライムに 10 のダメージ')

  text = read_log(log_path)
  eq(server.versions, ['RGSS2'], 'VX 请求版本标签全部是 RGSS2')
  eq($seen[:message], ['译:こんにちは'], 'VX 消息数组逐行写回译文')
  eq($seen[:menu], '译:アイテム', 'VX 菜单项写回译文')
  eq($seen[:help], '译:説明文', 'VX 帮助栏写回译文')
  eq($seen[:battle_add], '译:スライムが現れた！', 'VX 战斗日志 add_instant_text 写回译文')
  eq($seen[:battle_replace], '译:スライムに 10 のダメージ', 'VX 战斗日志 replace_instant_text 写回译文')
  eq(server.texts, ['こんにちは', 'アイテム', '説明文', 'スライムが現れた！', 'スライムに 10 のダメージ'], 'VX 送出的原文逐项正确')
  include_text(surface_names, 'battle', 'VX 战斗面被调用')
  ok(text.include?('choice on RGSS2 has no separate entry'), 'VX 选项面如实记录为并入 message', text)
  ok(text.include?('tracepoint disabled (version=RGSS2)'), 'VX 所有面完成后关闭 TracePoint', text)
  ok(!Window_Base.instance_methods(false).include?(:mochi_orig_draw_text), 'VX 未 hook Window_Base#draw_text')
  server.close
end

def run_vxace
  server, log_path = prepare('vxace')
  define_window_base

  define_ruby(<<~'RUBY')
    class Window_Command
      def initialize(list)
        @list = list
      end

      def draw_item(index)
        $seen[:menu] = @list[index][:name]
      end
    end

    class GameMessage
      attr_accessor :texts, :choices

      def initialize
        @texts = ['こんにちは']
        @choices = ['はい', 'いいえ']
      end

      def all_text
        @texts.inject('') { |result, line| result += line + "\n" }
      end
    end

    class Window_Message
      def process_all_text
        $seen[:message] = $game_message.all_text
      end
    end

    class Window_ChoiceList < Window_Command
      def initialize
        super([])
      end

      def start
        @list = $game_message.choices.map { |choice| { :name => choice, :symbol => :choice } }
        $seen[:choice_start] = $game_message.choices.dup
      end

      def draw_item(index)
        $seen[:choice_draw] = @list[index][:name]
      end
    end

    class Window_Help
      def set_text(text)
        $seen[:help] = text
      end
    end

    class Window_BattleLog
      def add_text(text)
        $seen[:battle_add] = text
      end

      def replace_text(text)
        $seen[:battle_replace] = text
      end
    end
  RUBY

  $game_message = GameMessage.new

  Window_Message.new.process_all_text
  Window_Command.new([{ :name => 'アイテム', :symbol => :item }]).draw_item(0)
  choice = Window_ChoiceList.new
  choice.start
  choice.draw_item(0)
  Window_Help.new.set_text('説明文')
  battle = Window_BattleLog.new
  battle.add_text('スライムが現れた！')
  battle.replace_text('スライムに 10 のダメージ')

  text = read_log(log_path)
  eq(server.versions, ['RGSS3'], 'VX Ace 请求版本标签全部是 RGSS3')
  eq($seen[:message], "译:こんにちは\n", 'VX Ace 消息数组写回译文（process_all_text 读到译文）')
  eq($seen[:menu], '译:アイテム', 'VX Ace 菜单项写回译文')
  eq($seen[:choice_start], ['译:はい', '译:いいえ'], 'VX Ace 选项 start 前整组写回译文')
  eq($seen[:choice_draw], '译:はい', 'VX Ace 选项 draw_item 画的是译文')
  eq($seen[:help], '译:説明文', 'VX Ace 帮助栏写回译文')
  eq($seen[:battle_add], '译:スライムが現れた！', 'VX Ace 战斗日志 add_text 写回译文')
  eq($seen[:battle_replace], '译:スライムに 10 のダメージ', 'VX Ace 战斗日志 replace_text 写回译文')
  eq(server.texts, ['こんにちは', 'アイテム', 'はい', 'いいえ', '説明文', 'スライムが現れた！', 'スライムに 10 のダメージ'], 'VX Ace 送出的原文逐项正确')
  include_text(surface_names, 'choice', 'VX Ace 选项面被调用')
  ok(!$surface_calls.include?(['menu', 'Window_ChoiceList', :draw_item]), 'VX Ace 选项 draw_item 不会被 menu 面抢走', $surface_calls.inspect)
  ok(!$surface_calls.include?(['menu', 'Window_ChoiceList', :start]), 'VX Ace 选项 start 不会被 menu 面抢走', $surface_calls.inspect)
  ok(text.include?('tracepoint disabled (version=RGSS3)'), 'VX Ace 所有面完成后关闭 TracePoint', text)
  ok(!Window_Base.instance_methods(false).include?(:mochi_orig_draw_text), 'VX Ace 未 hook Window_Base#draw_text')
  server.close
end

def run_gate_menu
  server, log_path = prepare('gate-menu', 'menu')
  define_window_base

  define_ruby(<<~'RUBY')
    class Window_Command
      def initialize(commands)
        @commands = commands
      end

      def draw_item(index, color)
        $seen[:menu] = @commands[index]
      end
    end

    class Window_Help
      def set_text(text, align = 0)
        $seen[:help] = text
      end
    end

    class Window_Message
      def refresh
        $seen[:message] = $game_temp.message_text
      end
    end
  RUBY

  $game_temp = Struct.new(:message_text).new('こんにちは')

  Window_Command.new(['アイテム']).draw_item(0, 0)
  Window_Message.new.refresh
  Window_Help.new.set_text('説明文')

  text = read_log(log_path)
  eq(server.texts, ['アイテム'], 'MOCHI_RGSS_SURFACES=menu 只请求菜单文本')
  eq($seen[:menu], '译:アイテム', '只开 menu 时菜单仍然翻译')
  eq($seen[:message], 'こんにちは', '只开 menu 时消息保持原文')
  eq($seen[:help], '説明文', '只开 menu 时帮助保持原文')
  ok(text.include?('surfaces enabled: menu'), '日志记录实际启用的面', text)
  ok(!text.include?('hooked message:'), '只开 menu 时没有安装消息 hook', text)
  ok(!text.include?('hooked help:'), '只开 menu 时没有安装帮助 hook', text)
  server.close
end

def run_failure_isolation
  server, log_path = prepare('failure-isolation')
  define_window_base

  define_ruby(<<~'RUBY')
    class Window_Command
      def initialize(commands)
        @commands = commands
      end

      def draw_item(index, color)
        $seen[:menu] = @commands[index]
      end

      freeze
    end

    class Window_Help
      def set_text(text, align = 0)
        $seen[:help] = text
      end
    end

    class Window_Message
      def refresh
        $seen[:message] = $game_temp.message_text
      end
    end
  RUBY

  $game_temp = Struct.new(:message_text).new('こんにちは')

  Window_Command.new(['アイテム']).draw_item(0, 0)
  Window_Message.new.refresh
  Window_Help.new.set_text('説明文')

  text = read_log(log_path)
  eq($seen[:menu], 'アイテム', '菜单面 hook 失败时菜单保持原文')
  eq($seen[:message], '译:こんにちは', '菜单面失败不影响消息面')
  eq($seen[:help], '译:説明文', '菜单面失败不影响帮助面')
  ok(text.include?('install_method_hooks(menu) failed') || text.include?('menu hook failed'), '日志留下菜单面失败原因', text)
  ok(server.texts.include?('こんにちは') && server.texts.include?('説明文'), '失败隔离后其它面仍能发出请求', server.texts.inspect)
  server.close
end

def run_off
  server, log_path = prepare('off')
  define_window_base

  define_ruby(<<~'RUBY')
    class Window_Command
      def initialize(commands)
        @commands = commands
      end

      def draw_item(index, color)
        $seen[:menu] = @commands[index]
      end
    end

    class Window_Help
      def set_text(text, align = 0)
        $seen[:help] = text
      end
    end

    class Window_Message
      def refresh
        $seen[:message] = $game_temp.message_text
      end
    end
  RUBY

  $game_temp = Struct.new(:message_text).new('こんにちは')

  Window_Command.new(['アイテム']).draw_item(0, 0)
  Window_Message.new.refresh
  Window_Help.new.set_text('説明文')

  text = read_log(log_path)
  eq(server.texts, [], 'MOCHI_RGSS_HOOK=off 不发出任何请求')
  eq($seen[:menu], 'アイテム', 'off 时菜单保持原文')
  eq($seen[:message], 'こんにちは', 'off 时消息保持原文')
  eq($seen[:help], '説明文', 'off 时帮助保持原文')
  ok(text.include?('hook disabled by MOCHI_RGSS_HOOK=off'), '日志记录 hook 被关闭', text)
  server.close
end

scenario = ARGV[1]
case scenario
when 'xp' then run_xp
when 'vx' then run_vx
when 'vxace' then run_vxace
when 'gate-menu' then run_gate_menu
when 'failure-isolation' then run_failure_isolation
when 'off' then run_off
else
  puts "not ok 1 - 未知场景 #{scenario}"
  $failed += 1
  $total += 1
end

puts "1..#{$total}"
puts "# pass #{$passed} fail #{$failed}"
exit($failed.zero? ? 0 : 1)
