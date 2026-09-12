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
