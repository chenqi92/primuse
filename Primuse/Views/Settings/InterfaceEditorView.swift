import SwiftUI
import PrimuseKit

/// 可以就地编辑的界面。
///
/// 版面这种东西说不清楚 —— 「双行横排」和「网格」光看名字分不出差别，条目数
/// 从 6 调到 12 到底占多高也只有看到才知道。所以这里不做抽象的开关列表，而是
/// 把真实界面原样嵌进来，改一下立刻看到结果。
enum InterfaceEditorSurface: String, CaseIterable, Identifiable, Sendable {
    case home, library, player

    var id: String { rawValue }
    var titleKey: String { "interface_editor_" + rawValue }
    var detailKey: String { "interface_editor_" + rawValue + "_detail" }

    var icon: String {
        switch self {
        case .home: "house"
        case .library: "books.vertical"
        case .player: "play.rectangle.on.rectangle"
        }
    }

    /// 逐个接：先把首页做通，验证这套「嵌真实界面 + 覆一层操作条」的路子成立，
    /// 再按同样的方式接资料库与播放器。没接通的先列出来但不可进入 —— 直接藏掉
    /// 会让人以为这里只能改首页。
    var isReady: Bool { self == .home }
}

#if os(iOS)
struct InterfaceEditorView: View {
    var body: some View {
        List {
            Section {
                ForEach(InterfaceEditorSurface.allCases) { surface in
                    if surface.isReady {
                        NavigationLink {
                            destination(for: surface)
                        } label: {
                            row(surface)
                        }
                        .accessibilityIdentifier("interfaceEditor." + surface.rawValue)
                    } else {
                        row(surface)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("interfaceEditor." + surface.rawValue)
                    }
                }
            } footer: {
                Text("interface_editor_footer")
            }
        }
        .navigationTitle("interface_editor_title")
    }

    private func row(_ surface: InterfaceEditorSurface) -> some View {
        HStack(spacing: 12) {
            Image(systemName: surface.icon)
                .font(.body)
                .frame(width: 26)
                .foregroundStyle(surface.isReady ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(surface.titleKey))
                Text(LocalizedStringKey(surface.detailKey))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if !surface.isReady {
                Text("interface_editor_coming_soon")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private func destination(for surface: InterfaceEditorSurface) -> some View {
        switch surface {
        case .home: HomeInterfaceEditor()
        case .library, .player: EmptyView()
        }
    }
}

/// 首页编辑：把首页本身嵌进来，每个区块套一条操作条。
///
/// 用的是环境里那份首页模型，不是新建一个 —— 编辑时看到的必须就是用户首页的
/// 真实内容和真实快照，另起一份会显示出不一样的东西。
private struct HomeInterfaceEditor: View {
    // 可选取值：环境里没有首页模型时（理论上不会发生，设置页就挂在首页那棵树
    // 下面）宁可给一句提示，也不要因为强制解包直接崩在设置里。
    @Environment(HomeView.Model.self) private var homeModel: HomeView.Model?
    @AppStorage(HomeSectionConfiguration.orderKey) private var sectionOrderRawValue = ""
    @AppStorage(HomeSectionLayoutConfiguration.storageKey) private var sectionLayoutRawValue = ""
    @State private var showsRestoreConfirm = false

    var body: some View {
        Group {
            if let homeModel {
                HomeView(model: homeModel, openLibrarySongs: {}, editorMode: true)
            } else {
                ContentUnavailableView(
                    "interface_editor_home",
                    systemImage: "house",
                    description: Text("interface_editor_unavailable")
                )
            }
        }
            .navigationTitle("interface_editor_home")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("home_settings_restore_all", role: .destructive) {
                        showsRestoreConfirm = true
                    }
                    .accessibilityIdentifier("interfaceEditor.home.restore")
                }
            }
            .confirmationDialog(
                "home_settings_restore_all",
                isPresented: $showsRestoreConfirm,
                titleVisibility: .visible
            ) {
                Button("home_settings_restore_all", role: .destructive) {
                    sectionOrderRawValue = HomeSectionConfiguration.encode(
                        HomeSectionConfiguration.defaultOrder
                    )
                    sectionLayoutRawValue = ""
                }
                Button("cancel", role: .cancel) {}
            }
    }
}
#endif
