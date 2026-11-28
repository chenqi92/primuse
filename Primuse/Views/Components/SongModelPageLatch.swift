import SwiftUI
import PrimuseKit

extension LibraryPageReadiness {
    /// 按这条规则此刻能不能画内容:`.always` 随时;`.catalog` 曲库可用(模型在不在内存里都行);`.legacy` 模型在内存里。
    func showsContent(isUsable: Bool, isReady: Bool) -> Bool {
        switch self {
        case .always: true
        case .catalog: isUsable || isReady
        case .legacy: isReady
        }
    }
}

/// 收用户输入的页(编辑器、编辑弹框)在歌曲模型被放掉时怎么显示(6c 单元 4 UB)。
/// 第一次显示过内容之后就一直挂着,不换成加载页:输入、`@State`、滚动位置都留着。模型不在内存里的这段时间
/// 上面盖一层不透明的加载、不接输入,用户不会看到它对着空数组重新排版;回到前台时页面再占用模型
/// (`.songModelPage`),装回来就揭开。还没显示过内容时与别的页一样等模型。
struct SongModelPageLatch: Equatable, Sendable {
    enum Presentation: Equatable, Sendable {
        /// 还没显示过内容,在等歌曲模型(画加载)。
        case loading
        /// 画内容。
        case content
        /// 显示过内容,模型这会儿不在:内容挂着,盖上加载、不接输入。
        case covered
    }

    let readiness: LibraryPageReadiness
    private(set) var hasShownContent = false

    init(readiness: LibraryPageReadiness, hasShownContent: Bool = false) {
        self.readiness = readiness
        self.hasShownContent = hasShownContent
    }
}

extension SongModelPageLatch {
    static func presentation(
        readiness: LibraryPageReadiness, hasShownContent: Bool, isUsable: Bool, isReady: Bool
    ) -> Presentation {
        if readiness.showsContent(isUsable: isUsable, isReady: isReady) { return .content }
        return hasShownContent ? .covered : .loading
    }

    /// 此刻怎么画;画了内容就记下「显示过」。
    mutating func update(isUsable: Bool, isReady: Bool) -> Presentation {
        let presentation = Self.presentation(
            readiness: readiness, hasShownContent: hasShownContent, isUsable: isUsable, isReady: isReady
        )
        if presentation == .content { hasShownContent = true }
        return presentation
    }
}

/// `SongModelPageLatch` 的视图一侧:加载、内容、盖着三种样子,加上页面的占用(`SongModelPageModifier`)。
@MainActor
struct SongModelInputPageModifier: ViewModifier {
    let readiness: LibraryPageReadiness
    @Environment(MusicLibrary.self) private var library
    @State private var hasShownContent = false

    func body(content: Content) -> some View {
        let presentation = SongModelPageLatch.presentation(
            readiness: readiness, hasShownContent: hasShownContent,
            isUsable: library.isUsable, isReady: library.isReady
        )
        ZStack {
            // 盖着的时候同一个分支:内容不重建,输入与滚动位置留着。
            if presentation != .loading {
                content
                    .disabled(presentation == .covered)
                    .accessibilityHidden(presentation == .covered)
            }
            if presentation != .content {
                SongModelPageCover()
            }
        }
        .onChange(of: presentation, initial: true) { _, presentation in
            if presentation == .content, !hasShownContent { hasShownContent = true }
        }
        .modifier(SongModelPageModifier(needsArrays: readiness == .legacy))
    }
}

/// 等歌曲模型时盖在页面上的那一层:不透明的页面底色,半秒后亮出进度与「准备资料库」,挡住点按。
struct SongModelPageCover: View {
    @State private var showsProgress = false

    var body: some View {
        ZStack {
            Self.background.ignoresSafeArea()
            if showsProgress {
                VStack(spacing: 16) {
                    ProgressView()
                    Text("library_preparing")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .transition(.opacity)
            }
        }
        .frame(minWidth: 320, maxWidth: .infinity, minHeight: 200, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {}
        .task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { showsProgress = true }
        }
    }

    private static var background: Color {
        #if os(macOS)
        PMColor.bg
        #else
        Color(uiColor: .systemBackground)
        #endif
    }
}
