#!/usr/bin/env ruby
# frozen_string_literal: true
#
# gen_rgss_fixture.rb —— 生成 RPG Maker XP / VX / VX Ace 的最小测试工程数据。
#
# 为什么自合成：RM 各代的 Data/*.rxdata 没有可再分发的官方样本，自合成可以精确控制
# 编码、字段形状与对象链接，也不会带入第三方版权。
#
# 这套样本承担 Level-2 断言（见 Tests/e2e/cases/contract/19_marshal.mjs）：
#   事件指令文本（101/401/102/402/404/405）、提取路径、编码判定、边界值
#   （空串 / 超长串 / 换行与控制序列 / 中日英混排）。
# 外部真实样本（Fixtures/rmxp-real|rmvx-real）只承担 Level-1：结构解析 + 字节往返，
# 因为那两个工程的事件层是空壳（@events{} 为空，EventCommand 只有 code=0 终止符）。
#
# 编码规则（实测）：
#   · RGSS1 / RGSS2（Ruby 1.8）：字符串一律 ASCII-8BIT，内容按 Windows-31J(CP932) 写字节，
#     Marshal 不会写 :E ivar。注意嵌套在数组里的字符串（102 的选项）也要转，否则文件里
#     会出现 :E —— 用 File.binread(f).include?(":\x06E") 可以一眼验出来。
#   · RGSS3（Ruby 1.9+）：不调 .b，让 ruby 2.x 自动写 :E => true，内容 UTF-8。
#
# 字段形状（三版本各不相同，解析器不能共用一套假设）：
#   · XP    RPG::System::Words  @words = 20 个扁平字符串 ivar
#   · VX    RPG::System::Terms  @terms = 33 个扁平字符串 ivar
#   · VXAce RPG::System::Terms  @terms = 容器形态（@basic/@params/@etypes/... 数组 + 哈希）
#   · XP 的 Map @bgm/@bgs 是 RPG::AudioFile；VX/VXAce 是 RPG::BGM / RPG::BGS
#
# 用法：ruby Scripts/gen_rgss_fixture.rb        幂等，重复运行字节完全相同。

require "fileutils"
require "zlib"

ROOT = File.expand_path("..", __dir__)

# --- 桩类：只声明真实 RGSS 里的嵌套结构，Marshal 的类名必须逐字对上 -------------

module RPG
  class System
    class Words; end
    class Terms; end
  end
  class Actor; end
  class Class; end
  class Skill; end
  class Item; end
  class Weapon; end
  class Armor; end
  class Enemy; end
  class State; end
  class Animation; end
  class Tileset; end
  class CommonEvent; end
  class Troop
    class Page; end
  end
  class MapInfo; end
  class Map; end
  class Event
    class Page; end
  end
  class EventCommand; end
  class MoveRoute; end
  class AudioFile; end
  class BGM; end
  class BGS; end
end

# RGSS 内置的 Table。_dump 布局（实测与真实样本一致）：
# [dim, xsize, ysize, zsize, data.size].pack("V5") + data.pack("v*")
class Table
  attr_reader :dim, :xsize, :ysize, :zsize, :data

  def initialize(dim, xsize, ysize = 1, zsize = 1, data = [])
    @dim = dim
    @xsize = xsize
    @ysize = ysize
    @zsize = zsize
    @data = data
  end

  def _dump(_depth)
    [@dim, @xsize, @ysize, @zsize, @data.size].pack("V5") +
      @data.map { |v| v & 0xffff }.pack("v*")
  end

  def self._load(bytes)
    dim, xsize, ysize, zsize, count = bytes.unpack("V5")
    data = bytes.byteslice(20, count * 2).unpack("v*").map { |v| v >= 0x8000 ? v - 0x10000 : v }
    new(dim, xsize, ysize, zsize, data)
  end
end

# --- 构造助手 ---------------------------------------------------------------

def build(klass, fields)
  object = klass.allocate
  fields.each { |name, value| object.instance_variable_set("@#{name}", value) }
  object
end

# mode = :binary（RGSS1/2，CP932 + ASCII-8BIT）或 :utf8（RGSS3，UTF-8）
def text(value, mode)
  if mode == :binary
    value.encode("Windows-31J").b
  else
    value.dup
  end
end

# 事件指令的 parameters 是嵌套数组（选项是 [[...], n]），字符串在任意深度都要转编码：
# 只转顶层会让 RGSS1/2 的选项变成 UTF-8 字节，提取时被判定成 UTF-8。
def deep_text(value, mode)
  case value
  when String then text(value, mode)
  when Array then value.map { |item| deep_text(item, mode) }
  when Hash then value.each_with_object({}) { |(k, v), out| out[deep_text(k, mode)] = deep_text(v, mode) }
  else value
  end
end

def command(code, indent, parameters, mode)
  build(RPG::EventCommand, code: code, indent: indent,
                            parameters: deep_text(parameters, mode))
end

# 一段带对话/选项/滚动文本的指令列表：101 起消息、401 是正文、102/402 是选项、
# 404 结束选项、405 是滚动文本。
def dialogue_list(mode, speaker_face: "", lines: [], choices: nil, scroll: nil)
  list = []
  list << command(101, 0, [speaker_face, 0, 0, 2], mode)
  lines.each { |line| list << command(401, 0, [line], mode) }
  if choices
    list << command(102, 0, [choices, 1], mode)
    choices.each_with_index do |choice, index|
      list << command(402, 1, [index, choice], mode)
    end
    list << command(404, 1, [], mode)
  end
  scroll&.each { |line| list << command(405, 0, [line], mode) }
  list << command(0, 0, [], mode)
  list
end

def map_table(width, height, seed, depth = 1)
  data = Array.new(width * height * depth) { |index| ((index * seed) % 7).zero? ? 1 : 0 }
  Table.new(3, width, height, depth, data)
end

def audio(name, mode, version)
  klass = version == :rgss1 ? RPG::AudioFile : RPG::BGM
  build(klass, name: text(name, mode), volume: 100, pitch: 100)
end

def sound(name, mode, version)
  klass = version == :rgss1 ? RPG::AudioFile : RPG::BGS
  build(klass, name: text(name, mode), volume: 100, pitch: 100)
end

# --- 三个版本的 @words / @terms（形状真实、互不通用）-------------------------

# XP：RPG::System::Words，20 个扁平字符串 ivar
def xp_words(mode)
  pairs = [
    ["gold", "ゴールド"], ["hp", "HP"], ["sp", "SP"], ["str", "力"], ["dex", "器用さ"],
    ["agi", "敏捷性"], ["int", "知性"], ["atk", "攻撃力"], ["pdef", "物理防御"], ["mdef", "魔法防御"],
    ["weapon", "武器"], ["armor1", "盾"], ["armor2", "頭"], ["armor3", "体"], ["armor4", "装飾品"],
    ["skill", "特技"], ["item", "アイテム"], ["equip", "装備"], ["attack", "攻撃"], ["guard", "防御"]
  ]
  build(RPG::System::Words, pairs.map { |name, value| [name, text(value, mode)] })
end

# VX：RPG::System::Terms，33 个扁平字符串 ivar
def vx_terms(mode)
  pairs = [
    ["level", "レベル"], ["level_a", "レベル"], ["hp", "HP"], ["hp_a", "HP"], ["mp", "MP"], ["mp_a", "MP"],
    ["atk", "攻撃力"], ["def", "防御力"], ["spi", "精神力"], ["agi", "敏捷性"],
    ["weapon", "武器"], ["armor1", "盾"], ["armor2", "頭"], ["armor3", "体"], ["armor4", "装飾品"],
    ["head", "兜"], ["body", "鎧"], ["hands", "手"], ["feet", "足"], ["accessory", "装飾品"],
    ["fight", "戦う"], ["escape", "逃げる"], ["attack", "攻撃"], ["guard", "防御"], ["item", "アイテム"],
    ["special", "スペシャル"], ["new_game", "はじめから"], ["continue", "つづきから"], ["load", "ロード"],
    ["save", "セーブ"], ["game_end", "ゲーム終了"], ["title", "タイトル"], ["shop", "ショップ"]
  ]
  build(RPG::System::Terms, pairs.map { |name, value| [name, text(value, mode)] })
end

# VX Ace：RPG::System::Terms，值是容器（数组/哈希），形态与 XP/VX 完全不同
def vxace_terms(mode)
  build(RPG::System::Terms,
        basic: %w[レベル レベル HP HP MP MP TP TP].map { |s| text(s, mode) },
        params: %w[攻撃力 防御力 魔法力 魔法防御 敏捷性 運].map { |s| text(s, mode) },
        etypes: %w[物理 炎 氷 雷 水 土 風 光 闇].map { |s| text(s, mode) },
        stypes: [text("特技", mode), text("魔法", mode)],
        wtypes: %w[剣 斧 槍 弓 杖].map { |s| text(s, mode) },
        atypes: %w[盾 兜 鎧 装飾品].map { |s| text(s, mode) },
        commands: {
          text("fight", mode) => text("戦う", mode),
          text("escape", mode) => text("逃げる", mode),
          text("attack", mode) => text("攻撃", mode),
          text("guard", mode) => text("防御", mode),
          text("item", mode) => text("アイテム", mode),
          text("special", mode) => text("スペシャル", mode)
        },
        messages: {
          text("level_up", mode) => text("はレベルアップした！", mode),
          text("actor_damaged", mode) => text("はダメージを受けた！", mode)
        })
end

def system_object(mode, version)
  terms = case version
          when :rgss1 then xp_words(mode)
          when :rgss2 then vx_terms(mode)
          else vxace_terms(mode)
          end

  fields = {
    game_title: text(title_for(version), mode),
    version_id: 1,
    party_members: [1, 2],
    currency_unit: text(version == :rgss3 ? "金币" : "円", mode),
    title_name: text("Title", mode),
    battleback_name: text("Grassland", mode),
    battle_bgm: audio("Battle1", mode, version),
    battle_end_me: audio("Victory1", mode, version),
    saved_count: 3
  }
  if version == :rgss1
    fields[:words] = terms
  else
    fields[:terms] = terms
  end
  build(RPG::System, fields)
end

def title_for(version)
  case version
  when :rgss1 then "モチボックス テスト（XP）"
  when :rgss2 then "モチボックス テスト（VX）"
  else "摩奇箱 测试版 VX Ace"
  end
end

def actor_object(mode, version, id, name, description, nickname)
  build(RPG::Actor,
        id: id,
        name: text(name, mode),
        class_id: id,
        initial_level: 1,
        final_level: 99,
        exp_basis: 30,
        exp_inflation: 30,
        character_name: text("Actor#{id}", mode),
        character_index: 0,
        face_name: text("Face#{id}", mode),
        face_index: 0,
        nickname: text(nickname, mode),
        description: text(description, mode),
        parameters: [[1, 2, 3, 4, 5, 6], [1, 2, 3, 4, 5, 6]],
        weapon_id: 1,
        armor1_id: 2,
        armor2_id: 3,
        armor3_id: 0,
        armor4_id: 0,
        two_swords_style: false,
        fix_equipment: false,
        auto_battle: false,
        super_guard: false)
end

# 长文本：> 255 字节，逼着变长 long 走 2 字节分支（也压一下 CP932 的多字节转换）
LONG_TEXT = (1..60).map { |i| "第#{i}行：長い説明文がここに続きます。" }.join("\n")

def item_objects(mode, version)
  items = [
    nil,
    build(RPG::Item, id: 1, name: text("薬草", mode), description: text("HPを50回復する。", mode),
                     icon_index: 176, price: 50, consumable: true, scope: 7, occasion: 0,
                     animation_id: 0, hit: 100, message1: text("は薬草を使った！", mode),
                     message2: text("のHPが50回復した！", mode)),
    build(RPG::Item, id: 2, name: text("魔法の水", mode), description: text("MPを30回復する。", mode),
                     icon_index: 177, price: 120, consumable: true, scope: 7, occasion: 0,
                     animation_id: 0, hit: 100, message1: text("は魔法の水を使った！", mode),
                     message2: text("のMPが30回復した！", mode)),
    # 空串：Ruby 不会把 "" 折叠成 nil，往返必须保留
    build(RPG::Item, id: 3, name: text("", mode), description: text("", mode),
                     icon_index: 0, price: 0, consumable: false, scope: 0, occasion: 0,
                     animation_id: 0, hit: 100, message1: text("", mode), message2: text("", mode)),
    # 边界：控制序列（反斜杠 C 是 RMXP 的着色码，引擎按字节处理）+ 超长串 + 换行
    build(RPG::Item, id: 4, name: text("\\C[2]毒消し\\C[0]", mode), description: text(LONG_TEXT, mode),
                     icon_index: 178, price: 80, consumable: true, scope: 7, occasion: 0,
                     animation_id: 0, hit: 100, message1: text("は\\C[2]毒消し\\C[0]を使った！", mode),
                     message2: text("", mode))
  ]
  if version == :rgss3
    # 中日英混排只有 RGSS3（UTF-8）能表达；CP932 编不出简体中文，不该硬塞。
    items << build(RPG::Item, id: 5, name: text("测试用アイテムTest", mode),
                           description: text("这是中文，这是日本語，This is ASCII。", mode),
                           icon_index: 179, price: 200, consumable: true, scope: 7, occasion: 0,
                           animation_id: 0, hit: 100, message1: text("", mode), message2: text("", mode))
  end
  items
end

def common_event_objects(mode)
  [
    nil,
    build(RPG::CommonEvent,
          id: 1,
          name: text("宿屋", mode),
          trigger: 0,
          switch_id: 1,
          list: dialogue_list(mode, lines: ["一晩ゆっくり休んでいくかい？"])),
    build(RPG::CommonEvent,
          id: 2,
          name: text("看板", mode),
          trigger: 0,
          switch_id: 1,
          list: dialogue_list(mode, lines: ["この先、魔王の城。", "装備を整えてから行くんだな。"],
                                    scroll: ["（看板には古い文字が刻まれている）"]))
  ]
end

def troop_objects(mode)
  [
    nil,
    build(RPG::Troop,
          id: 1,
          name: text("スライム×2", mode),
          members: [],
          pages: [
            build(RPG::Troop::Page, condition: nil, span: 0,
                                    list: dialogue_list(mode, lines: ["スライムが現れた！"])),
            build(RPG::Troop::Page, condition: nil, span: 0,
                                    list: dialogue_list(mode, lines: ["スライムは倒れた。"],
                                                              choices: %w[勝つ 逃げる]))
          ])
  ]
end

# 真实的 MapInfos 是哈希 {地图 id => RPG::MapInfo}（实测 XP / VX 样本），不是数组
def map_info_objects(mode)
  {
    1 => build(RPG::MapInfo, id: 1, name: text("始まりの村", mode), parent_id: 0, order: 1,
                             expanded: false, scroll_x: 0, scroll_y: 0),
    2 => build(RPG::MapInfo, id: 2, name: text("村はずれの森", mode), parent_id: 0, order: 2,
                             expanded: false, scroll_x: 0, scroll_y: 0)
  }
end

def event_page(mode, lines, choices: nil, scroll: nil)
  build(RPG::Event::Page,
        condition: nil,
        graphic: nil,
        move_type: 0,
        move_speed: 3,
        move_frequency: 3,
        move_route: nil,
        walk_anime: true,
        step_anime: false,
        direction_fix: false,
        through: false,
        priority_type: 1,
        trigger: 0,
        list: dialogue_list(mode, lines: lines, choices: choices, scroll: scroll))
end

def map_object(mode, version)
  width = 20
  height = 15
  event = build(RPG::Event,
                id: 1,
                name: text("村人", mode),
                x: 5,
                y: 6,
                pages: [
                  event_page(mode, ["旅の人？　この村は初めてかい？", "ようこそ、始まりの村へ。"],
                             choices: %w[はい いいえ]),
                  event_page(mode, ["また会ったね。"], scroll: ["（村人は遠くを見つめている）"])
                ])

  # XP 的 Map 11 个 ivar、@bgm/@bgs 是 RPG::AudioFile；
  # VX/VXAce 18 个（parallax/scroll/disable_dashing），@bgm/@bgs 是 RPG::BGM/RPG::BGS。
  fields = {
    width: width,
    height: height,
    autoplay_bgm: false,
    bgm: audio("Field1", mode, version),
    autoplay_bgs: false,
    bgs: sound("", mode, version),
    encounter_list: [],
    encounter_step: 30,
    data: map_table(width, height, 3),
    events: { 1 => event }
  }
  if version == :rgss1
    fields[:tileset_id] = 1
    fields[:battleback_name] = text("Grassland", mode)
  else
    fields[:parallax_name] = text("", mode)
    fields[:parallax_loop_x] = false
    fields[:parallax_loop_y] = false
    fields[:parallax_sx] = 0
    fields[:parallax_sy] = 0
    fields[:parallax_show] = false
    fields[:disable_dashing] = false
    fields[:scroll_type] = 0
    fields[:display_name] = text("始まりの村", mode) if version == :rgss3
  end
  build(RPG::Map, fields)
end

# Scripts.rxdata 不是翻译目标，但解析器必须能过：[magic, name, zlib 压缩的 ruby 源码]
def script_objects(mode)
  [
    [1, text("▼ 素材", mode), Zlib::Deflate.deflate("$mochi = 1\n")],
    [2, text("Main", mode), Zlib::Deflate.deflate("main\n")]
  ]
end

# --- 落盘 -------------------------------------------------------------------

def write_marshaled(path, object)
  data = Marshal.dump(object)
  File.binwrite(path, data)
  data.bytesize
end

VERSIONS = [
  { dir: "rmxp",    ext: "rxdata",  library: "RGSS1", mode: :binary, version: :rgss1,
    engine: "XP",     proj: "Game.rxproj",  title: "モチボックス テスト（XP）" },
  { dir: "rmvx",    ext: "rvdata",  library: "RGSS2", mode: :binary, version: :rgss2,
    engine: "VX",     proj: "Game.rvproj",  title: "モチボックス テスト（VX）" },
  { dir: "rmvxace", ext: "rvdata2", library: "RGSS3", mode: :utf8,   version: :rgss3,
    engine: "VX Ace", proj: "Game.rvproj2", title: "摩奇箱 测试版 VX Ace" }
].freeze

total = 0
VERSIONS.each do |spec|
  data_dir = File.join(ROOT, "Fixtures", spec[:dir], "Data")
  FileUtils.mkdir_p(data_dir)
  mode = spec[:mode]
  ext = spec[:ext]
  version = spec[:version]

  files = {
    "Actors" => [nil,
                 actor_object(mode, version, 1, "アレン", "主人公。\n剣の使い手。", "剣士"),
                 actor_object(mode, version, 2, "リーナ", "回復魔法が得意な僧侶。", "僧侶")],
    "Items" => item_objects(mode, version),
    "CommonEvents" => common_event_objects(mode),
    "Troops" => troop_objects(mode),
    "MapInfos" => map_info_objects(mode),
    "Map001" => map_object(mode, version),
    "System" => system_object(mode, version),
    "Scripts" => script_objects(mode)
  }

  puts "== #{spec[:dir]} (#{spec[:library]}, mode=#{mode}) =="
  files.each do |name, object|
    path = File.join(data_dir, "#{name}.#{ext}")
    size = write_marshaled(path, object)
    total += size
    printf("  %-16s %6d bytes\n", "#{name}.#{ext}", size)
    if mode == :binary
      # 自检：RGSS1/2 的文件里绝不该出现 :E 符号（漏转嵌套字符串时会出现）
      raise "!! #{path} 里出现了 :E ivar（嵌套字符串漏转编码）" if File.binread(path).include?(":\x06E")
    end
  end

  ini = "[Game]\nRTP=Standard\nLibrary=#{spec[:library]}\n" \
        "Scripts=Data\\Scripts.#{ext}\nTitle=#{spec[:title]}\n"
  File.binwrite(File.join(ROOT, "Fixtures", spec[:dir], "Game.ini"), ini)

  write_marshaled(File.join(ROOT, "Fixtures", spec[:dir], spec[:proj]),
                  { "Library" => spec[:library], "Version" => 1, "Title" => text(spec[:title], mode) })

  provenance = <<~MD
    # #{spec[:dir]} 测试样本来源

    本目录下的 Data/*.#{ext}、Game.ini、#{spec[:proj]} 全部由
    Scripts/gen_rgss_fixture.rb 用系统 ruby（#{RUBY_VERSION}）合成，
    **不含任何第三方游戏素材或文本**，可随仓库分发（与仓库同许可）。

    - 引擎：RPG Maker #{spec[:engine]}（#{spec[:library]}）
    - 编码：#{mode == :binary ? "字符串为 ASCII-8BIT（无 :E ivar），字节按 Windows-31J(CP932) 编码；生成时已自检文件内不含 :E 符号" : "字符串为 UTF-8，Ruby 会自动写入 :E => true"}
    - 术语字段形状：#{version == :rgss1 ? "RPG::System::Words，@words 为 20 个扁平字符串 ivar" : version == :rgss2 ? "RPG::System::Terms，@terms 为 33 个扁平字符串 ivar" : "RPG::System::Terms，@terms 为容器形态（@basic/@params/@etypes 等数组 + @commands/@messages 哈希）"}
    - 覆盖层级：**Level-2**（文本路径与编码/边界断言）。事件指令含 101/401 对话、102/402/404 选项、405 滚动文本；
      边界含空串、超长串（超过 255 字节，走多字节长度分支）、反斜杠 C 着色控制序列、换行#{version == :rgss3 ? "、中日英混排" : ""}。
    - 文本内容：占位用的原创日文/中文短句
    - 重新生成：ruby Scripts/gen_rgss_fixture.rb（幂等，重复运行字节完全相同）
  MD
  File.write(File.join(ROOT, "Fixtures", spec[:dir], "PROVENANCE.md"), provenance)
end

puts
puts "合计 #{total} 字节，覆盖 #{VERSIONS.size} 个版本"
puts "重新运行本脚本应产出完全相同的字节（Marshal 对同一对象图是确定性的）"
