#if os(macOS)
import SwiftUI

/// Mac 主窗口里一页按它的显示规则(`MacPageKind.readiness`)出现(6c 单元 4 U2b):
/// - `.always` / `.catalog`:主窗口已经等到「曲库可用」,直接画;
/// - `.legacy`:歌曲模型在内存里才画;放掉了(或这次启动没装)时显示加载,并替这一页占用模型
///   (`.songModelPage`),装回来就画。页面消失、App 隐藏或失去前台时放手。
struct MacLibraryPageGate: ViewModifier {
    let kind: MacPageKind
    @Environment(MusicLibrary.self) private var library

    func body(content: Content) -> some View {
        let readiness = kind.readiness
        if kind.keepsInputOnRelease {
            // 编辑器:显示过就挂着,模型不在时盖上加载(UB)。
            content.modifier(SongModelInputPageModifier(readiness: readiness))
        } else {
            Group {
                if MacPageKind.showsContent(readiness, isUsable: library.isUsable, isReady: library.isReady) {
                    content
                } else {
                    MacLibraryPageLoading()
                }
            }
            .songModelPage(needsArrays: readiness == .legacy)
        }
    }
}

extension View {
    /// 这一页按 `kind` 的显示规则出现;还读整库数组的页在歌曲模型装回来之前显示加载。
    func macLibraryPage(_ kind: MacPageKind) -> some View {
        modifier(MacLibraryPageGate(kind: kind))
    }
}

extension MacRoute {
    /// 侧栏、标题栏选中的这一项是哪种页(显示规则见 `MacPageKind.readiness`)。
    var pageKind: MacPageKind {
        switch self {
        case .home: .home
        case .stats: .listeningStats
        case .search: .search
        case .sources: .sources
        case .section(let section): .section(section)
        case .liked: .likedSongs
        case .playlist: .playlist
        case .smartPlaylist: .smartPlaylist
        case .source: .source
        }
    }
}

/// 一页在等歌曲模型装回来:只铺底色,慢的时候(半秒后)再亮出进度与一句话,同主窗口的启动占位。
struct MacLibraryPageLoading: View {
    @State private var showsProgress = false

    var body: some View {
        ZStack {
            PMColor.bg.ignoresSafeArea()
            if showsProgress {
                VStack(spacing: 16) {
                    ProgressView()
                    Text("library_preparing")
                        .font(.subheadline)
                        .foregroundStyle(PMColor.textMuted)
                }
                .pmFadeTransition(motion: .contentAppear)
            }
        }
        // 弹框里也有个像样的大小(弹框的尺寸本来由里面的页面给)。
        .frame(minWidth: 320, maxWidth: .infinity, minHeight: 200, maxHeight: .infinity)
        .task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            showsProgress = true
        }
    }
}
#endif
