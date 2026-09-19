import SwiftUI

/// 「更多」菜单的三种整理手法。全部是系统菜单自己的元素，外观（含 iOS 26 的玻璃质感）、
/// 无障碍和键盘操作都由系统负责 —— 菜单里放不进自绘控件，想要「横排」「左右切换」
/// 只能从这几样里选：
///
/// - `PMMenuQuickActions`：最常用的两三个**动作**排成顶部一行，图标在上、短文字在下。
/// - `PMMenuPalettePicker`：两三个选项的**单选**排成一条图标，选中的那个高亮。
/// - `PMMenuSubmenuPicker`：选项多的**单选**收成一行，行上带着当前值，点开才是全部选项。
///
/// 这里的视图都不读环境：工具栏条目、长按菜单跑在独立宿主里，必读的环境对象
/// 在那边拿不到。
struct PMMenuQuickActions<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        #if os(iOS)
        // 系统按个数决定样式：三个以内是「图标 + 短文字」，四个就只剩图标。
        // 所以这一行最多放三个，文字取最短的那一版，长了会被截断。
        ControlGroup { content() }
        #else
        // macOS 的菜单没有横排，ControlGroup 在那边会变成一个没有名字的子菜单。
        content()
        #endif
    }
}

struct PMMenuPalettePicker<Value: Hashable, Content: View>: View {
    let title: LocalizedStringKey
    @Binding var selection: Value
    @ViewBuilder let content: () -> Content

    var body: some View {
        #if os(iOS)
        // 横排里只显示图标，文字留给旁白读。只给「每个选项的图标一眼能认」的单选用；
        // 认不出来的宁可用 `PMMenuSubmenuPicker`。
        Picker(title, selection: $selection) { content() }
            .pickerStyle(.palette)
        #else
        Picker(title, selection: $selection) { content() }
            .pickerStyle(.inline)
        #endif
    }
}

struct PMMenuSubmenuPicker<Value: Hashable, Content: View>: View {
    let title: LocalizedStringKey
    let systemImage: String
    @Binding var selection: Value
    @ViewBuilder let content: () -> Content

    var body: some View {
        Picker(selection: $selection) {
            content()
        } label: {
            Label(title, systemImage: systemImage)
        }
        .pickerStyle(.menu)
    }
}
