//
//  GlossarySeed.swift
//  MochiBox
//
//  内置通用术语表：只覆盖 RPG Maker MV/MZ 的**官方默认日文术语**。
//
//  取值原则（重要）：
//  · 只收能逐条核对官方简体中文资源包 `data/System.json` 的词；核对不上的宁可不收，
//    交给模型翻、由用户在术语页改。凭记忆写错一个词，会污染整局游戏的译名。
//  · `keepAsIs` 的条目（HP/MP/TP/EXP/Lv）目标值等于原文：命中即短路，不送模型。
//  · terms.basic 是**成对**的（全称/缩写），两套写法都要收；NFKC 后 `Ｌｖ`/`LV` 会归一。
//  · 这里只有日文源；英文/中文源的游戏不命中，模型照常翻。
//

import Foundation

enum GlossarySeed {
    static let entries: [GlossaryEntry] = build()

    private static func build() -> [GlossaryEntry] {
        var list: [GlossaryEntry] = []

        func term(_ source: String, _ target: String) {
            list.append(GlossaryEntry(source: source, target: target, kind: .system))
        }
        func keep(_ source: String) {
            list.append(GlossaryEntry(source: source, target: source, kind: .system, keepAsIs: true))
        }

        // 界面术语（terms.basic / commands / params 的官方默认值）
        term("レベル", "等级")
        term("経験値", "经验值")
        term("所持金", "持有金钱")
        term("戦う", "战斗")
        term("逃げる", "逃跑")
        term("攻撃", "攻击")
        term("防御", "防御")
        term("アイテム", "物品")
        term("スキル", "技能")
        term("装備", "装备")
        term("状態", "状态")
        term("並び替え", "整队")
        term("セーブ", "保存")
        term("ゲーム終了", "游戏结束")
        term("オプション", "选项")
        term("購入する", "购买")
        term("売却する", "出售")
        term("武器", "武器")
        term("防具", "防具")

        // 能力值（terms.params）
        term("攻撃力", "攻击力")
        term("防御力", "防御力")
        term("魔法攻撃", "魔法攻击")
        term("魔法防御", "魔法防御")
        term("敏捷性", "敏捷")
        term("運", "幸运")
        term("命中率", "命中率")
        term("回避率", "回避率")

        // 保留原样的缩写与复合词（NFKC 会处理全角）
        keep("HP")
        keep("MP")
        keep("TP")
        keep("EXP")
        keep("Lv")
        keep("最大HP")
        keep("最大MP")

        return list
    }
}
