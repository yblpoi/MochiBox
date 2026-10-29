//
//  Appearance.swift
//  MochiBox
//
//  外观自适应的集中出口。
//
//  为什么单独一个文件：压暗层与四处弱填充原先都是"照深色桌面调出来的固定不透明度"，
//  到浅色下要么把桌面压成灰泥（0.22 的黑），要么弱到看不见（0.05 的 .secondary）。
//  把它们收在这里，只有一套规则、一条改法，不再散落在各个视图里。
//
//  规则：
//    · 压暗层 —— 两个外观都是 0。0.22 当年是在"左右两栏各自还有一层材质挡住压暗层"
//      的前提下调的；那层材质收掉之后，同样的 0.22 会把整窗再压暗一档（左栏 40.0 → 31.0），
//      所以归零。详见 `dim(_:)` 的注释。
//    · 弱填充 —— 深色保持各调用点原来的不透明度；浅色下 `.secondary` 与背景的明度差
//      更小，按 1.5 倍补回来（0.12 → 0.18，0.15 → 0.20，0.05 → 0.08，0.08 → 0.12）。
//      只放大不透明度，不改语义色本身（.red/.green/.orange 等状态色一律不动）。
//
//  用法刻意做成 View 修饰器：内部自己读 `colorScheme`，调用点不必各自加
//  `@Environment(\.colorScheme)`，也就不会有人忘了加。
//

import SwiftUI

enum Appearance {
    /// 全窗压暗层：垫在窗口级毛玻璃之上、内容之下。
    ///
    /// 深色也是 0：这层**同时盖住标题栏**（实测 0.22 → 0 时标题栏 32.1 → 41.1），
    /// 逐档实测（0.22/0.16/0.12/0.08/0.06/0）里，任何非零值都会把左右两栏一起压低，
    /// 只有 0 能让两栏回到收材质之前的 40.0/39.3。
    static func dim(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.black.opacity(0.0) : Color.clear
    }

    /// 弱填充（胶囊 / 行底）：`dark` 是深色下的原值，浅色按 1.5 倍放大。
    static func weakFill(_ dark: Double, _ scheme: ColorScheme) -> Color {
        Color.secondary.opacity(scheme == .dark ? dark : min(dark * 1.5, 0.30))
    }
}

extension View {
    /// 按外观取值的全窗压暗层。
    func dimOverlay() -> some View { modifier(DimOverlayModifier()) }

    /// 按外观取值的弱填充底色。
    func weakFill(_ dark: Double) -> some View { modifier(WeakFillModifier(dark: dark)) }
}

private struct DimOverlayModifier: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content.background(Appearance.dim(scheme))
    }
}

private struct WeakFillModifier: ViewModifier {
    let dark: Double
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content.background(Appearance.weakFill(dark, scheme))
    }
}
