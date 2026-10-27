import SwiftUI
import PrimuseKit

#if os(iOS)
/// 首页编辑：把首页本身嵌进来，每个区块套一条操作条。
///
/// 用的是环境里那份首页模型，不是新建一个 —— 编辑时看到的必须就是用户首页的
/// 真实内容和真实快照，另起一份会显示出不一样的东西。
struct HomeInterfaceEditor: View {
    // 可选取值：环境里没有首页模型时（理论上不会发生，设置页就挂在首页那棵树
    // 下面）宁可给一句提示，也不要因为强制解包直接崩在设置里。
    @Environment(HomeView.Model.self) private var homeModel: HomeView.Model?
    @Environment(MusicLibrary.self) private var library
    @AppStorage(HomeSectionConfiguration.orderKey) private var sectionOrderRawValue = ""
    @AppStorage(HomeSectionLayoutConfiguration.storageKey) private var sectionLayoutRawValue = ""
    @AppStorage(HomeCoverSize.legacyStorageKey) private var legacyCoverSize: HomeCoverSize = .large
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
                    // 挂在工具栏的按钮上，弹框从按钮长出来。
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
                            // 各块的封面大小在上面那份布局里;老版本的全局大小也放回「大」,否则没单独调过的块还跟着它。
                            legacyCoverSize = .large
                            // 关掉的区块重新显示,收藏里拿掉的「我喜欢」放回来:只恢复顺序和样式的话,
                            // 删过东西的人点了这里什么也看不出变化。
                            HomeView.restoreDefaultSectionVisibility()
                            FavoriteCollectionStore.shared.restoreDefaultEntries(library: library)
                        }
                        Button("cancel", role: .cancel) {}
                    } message: {
                        Text("home_settings_restore_all_message")
                    }
                }
            }
    }
}
#endif
