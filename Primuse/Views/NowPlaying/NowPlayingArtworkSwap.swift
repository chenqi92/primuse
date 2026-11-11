import SwiftUI
import PrimuseKit

/// 用户刚按下的下一首 / 上一首。播放器在 `next()` / `previous()` 里记下(按钮、手势、线控、
/// CarPlay 都经过那里),播放页大封面换歌时取用一次,决定往哪边换(见 `ArtworkSwapPolicy`)。
@MainActor
enum ManualTrackTraversal {
    private static var last: (direction: ArtworkSwapDirection, at: TimeInterval)?

    static func note(_ direction: ArtworkSwapDirection) {
        last = (direction, ProcessInfo.processInfo.systemUptime)
    }

    /// 取走最近一次按键和它过去了多久;取一次就清掉。
    static func take() -> (direction: ArtworkSwapDirection, age: TimeInterval)? {
        guard let last else { return nil }
        self.last = nil
        return (last.direction, ProcessInfo.processInfo.systemUptime - last.at)
    }
}

/// 封面层画哪一首:歌和它当时的封面版本一起冻住,退场那一层一直画旧歌。
struct NowPlayingArtworkSwapSubject: Equatable {
    let song: Song?
    let coverRevision: Int
}

/// 播放页大封面换歌时按方向换:下一首,旧封面向左退并略缩,新封面从右边略小一点滑进来、
/// 回弹到位;上一首反过来;自己播完换到下一首时同一方向,但更柔、不回弹。
///
/// 只管播放页大封面这一层,`CachedArtworkView` 的通用换图路径(原地交叉淡入)不动:
/// 判不出方向(从列表点一首、换了整个队列)、不在大封面位、封面⇄歌词正在飞、
/// 播放页没露出来、开着减少动态效果时,照旧只有一层、原地交叉淡入。
///
/// 每一层是一个完整的「封面 + 飞行修饰」,由调用方的 `layer` 画出来;这里只在外面加
/// 位移、缩放和透明度。状态都在这一层里,换歌时多出来的重画只落在封面上。
struct NowPlayingArtworkSwapHost<Layer: View>: View {
    let subject: NowPlayingArtworkSwapSubject
    /// 这次换歌允许按方向换。
    let allowsDirectionalSwap: Bool
    /// 封面在这一层里的位置:缩放围着它的中心,位移按它的宽度算。
    let artworkRect: CGRect
    let containerSize: CGSize
    @ViewBuilder let layer: (NowPlayingArtworkSwapSubject) -> Layer

    @Environment(AudioPlayerService.self) private var player
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.displayScale) private var displayScale

    @State private var layers: [SwapLayer] = [SwapLayer(id: 0, frozen: nil, phase: .resting, style: nil)]
    @State private var nextLayerID = 1
    /// 上一次换歌之后记下的「接下来那首」「前一首」,下一次换歌时拿来判断是不是自然播完。
    /// 不参与绘制,放在引用里,更新它不重画。
    @State private var neighbours = Neighbours()
    /// 当前那一层画的这一首。换歌那一帧它还是旧歌(要退场的那一首),等判断完方向才换成新歌:
    /// 不然要退场的那一层会先被换成新歌、再被拉回旧歌,中间闪一下。
    @State private var displayed: NowPlayingArtworkSwapSubject?

    private final class Neighbours {
        var nextID: String?
        var previousID: String?
        var prewarmTask: Task<Void, Never>?
    }

    fileprivate enum Phase: Equatable {
        case resting
        case exiting
    }

    fileprivate struct SwapLayer: Identifiable {
        let id: Int
        /// nil 表示跟着当前这首(`displayed`)走。
        var frozen: NowPlayingArtworkSwapSubject?
        var phase: Phase
        var style: ArtworkSwapStyle?
    }

    var body: some View {
        ZStack {
            ForEach(layers) { item in
                layer(item.frozen ?? displayed ?? subject)
                    .modifier(NowPlayingArtworkSwapMotion(
                        progress: item.phase == .exiting ? 1 : 0,
                        style: item.style,
                        artworkRect: artworkRect,
                        containerSize: containerSize,
                        isRightToLeft: layoutDirection == .rightToLeft
                    ))
                    .transition(entryTransition(for: item.style))
                    .zIndex(item.phase == .exiting ? 0 : 1)
            }
        }
        .onAppear {
            displayed = subject
            recordNeighbours()
        }
        .onChange(of: subject) { old, new in
            if old.song?.id != new.song?.id {
                handleSongChange()
            } else {
                // 同一首换了封面(刮削、改标签):原地换,和原来一样交叉淡入。
                displayed = new
            }
        }
        .onChange(of: allowsDirectionalSwap) { _, allows in
            if allows {
                // 播放页刚露出来:下一首的封面这时候再备。
                recordNeighbours()
            } else {
                // 开始往歌词那边飞、播放页收起时,还在退场的那一层直接收掉,不跟着飞。
                dropExitingLayers()
            }
        }
    }

    private func entryTransition(for style: ArtworkSwapStyle?) -> AnyTransition {
        guard let style else { return .identity }
        return .asymmetric(
            insertion: .modifier(
                active: NowPlayingArtworkSwapMotion(
                    progress: -1,
                    style: style,
                    artworkRect: artworkRect,
                    containerSize: containerSize,
                    isRightToLeft: layoutDirection == .rightToLeft
                ),
                identity: NowPlayingArtworkSwapMotion(
                    progress: 0,
                    style: style,
                    artworkRect: artworkRect,
                    containerSize: containerSize,
                    isRightToLeft: layoutDirection == .rightToLeft
                )
            ),
            removal: .identity
        )
    }

    private func handleSongChange() {
        let outgoing = displayed
        displayed = subject
        let intent = ManualTrackTraversal.take()
        let style = ArtworkSwapPolicy.style(
            newSongID: subject.song?.id,
            predictedNextID: neighbours.nextID,
            predictedPreviousID: neighbours.previousID,
            manualIntent: intent?.direction,
            intentAge: intent?.age
        )
        recordNeighbours()

        guard allowsDirectionalSwap, !reduceMotion,
              let style, let outgoing, outgoing.song != nil else {
            // 判不出方向:只留一层,原地交叉淡入(CachedArtworkView 自己的换图)。
            dropExitingLayers()
            return
        }

        // 连着按好几下:只留最近一层退场,更早的直接收掉,屏幕上最多两张封面。
        let exitingIDs = Set(layers.filter { $0.phase == .exiting }.map(\.id))
        if !exitingIDs.isEmpty {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                layers.removeAll { exitingIDs.contains($0.id) }
            }
        }

        let newID = nextLayerID
        nextLayerID &+= 1
        let motion: PMMotion = style.isGentle ? .trackSwapGentle : .trackSwap
        withAnimation(motion.animation) {
            for index in layers.indices where layers[index].phase == .resting {
                layers[index].phase = .exiting
                layers[index].frozen = outgoing
                layers[index].style = style
            }
            layers.append(SwapLayer(id: newID, frozen: nil, phase: .resting, style: style))
        }

        let retiring = Set(layers.filter { $0.phase == .exiting }.map(\.id))
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(motion.settleDuration))
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                layers.removeAll { retiring.contains($0.id) }
            }
        }
    }

    private func dropExitingLayers() {
        guard layers.contains(where: { $0.phase == .exiting }) else { return }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            layers.removeAll { $0.phase == .exiting }
        }
    }

    /// 记下这一首之后、之前是哪一首。只在换歌时读一次队列,不在绘制里读,不建立观察。
    private func recordNeighbours() {
        let entries = player.queueEntries
        let next = player.upcomingQueueTraversalTargets(maximumCount: 1, respectsRepeatOne: false)
            .first
            .flatMap { entries.indices.contains($0.queueIndex) ? entries[$0.queueIndex].song : nil }
        neighbours.nextID = next?.id
        neighbours.previousID = player.previousQueueTraversalTarget()
            .flatMap { entries.indices.contains($0.queueIndex) ? entries[$0.queueIndex].song.id : nil }
        prewarm(next)
    }

    /// 播放页露着时把下一首的大封面先解码进内存:按下一首时新封面从第一帧就在,不是滑到一半才冒出来。
    /// 上一首刚刚画过,本来就在内存里。只读本机已存的封面,稍等一会儿再做,不跟起播抢资源。
    private func prewarm(_ song: Song?) {
        neighbours.prewarmTask?.cancel()
        guard allowsDirectionalSwap, !reduceMotion, let song,
              song.sourceID != AppleMusicLibraryService.systemSourceID else { return }
        let revision = subject.coverRevision
        let scale = displayScale
        neighbours.prewarmTask = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            _ = await CachedArtworkView.prewarm(
                songID: song.id,
                coverRef: song.coverArtFileName,
                sourceID: song.sourceID,
                filePath: song.filePath,
                fileFormat: song.fileFormat,
                revisionToken: revision,
                size: NowPlayingView.artworkRenderSize,
                displayScale: scale
            )
        }
    }
}

/// 一层封面在换歌途中的样子:退场时往一边让、缩一点、淡掉;入场从另一边进来,同样先小一点,
/// 透明度按 `ArtworkSwapPolicy.layerOpacity` 走:新封面早早就不透明,盖住重叠的那一块,不和旧封面叠成一团。
///
/// 位移、缩放、透明度都从同一个 `progress` 算出来(可动画的那个值):0 停在原位,0→1 退场,-1→0 入场。
/// 透明度和位移用不同的曲线,所以不能各自交给 SwiftUI 插值。
private struct NowPlayingArtworkSwapMotion: ViewModifier, Animatable {
    var progress: Double
    let style: ArtworkSwapStyle?
    let artworkRect: CGRect
    let containerSize: CGSize
    let isRightToLeft: Bool

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let pose = pose
        content
            .scaleEffect(pose.scale, anchor: anchor)
            .offset(x: pose.offset)
            .opacity(pose.opacity)
    }

    private var pose: (offset: CGFloat, scale: CGFloat, opacity: Double) {
        guard let style, progress != 0 else { return (0, 1, 1) }
        let fraction = ArtworkSwapPolicy.exitOffsetFraction(for: style.direction, isRightToLeft: isRightToLeft)
        // 自然播完那种挪得近一点、缩得少一点。
        let reach = CGFloat(fraction) * artworkRect.width * (style.isGentle ? 0.7 : 1)
        let smallest: CGFloat = style.isGentle ? 0.92 : 0.86
        let amount = CGFloat(min(abs(progress), 1))
        return (
            reach * CGFloat(progress),
            1 - (1 - smallest) * amount,
            ArtworkSwapPolicy.layerOpacity(signedProgress: progress)
        )
    }

    private var anchor: UnitPoint {
        guard containerSize.width > 0, containerSize.height > 0 else { return .center }
        return UnitPoint(
            x: artworkRect.midX / containerSize.width,
            y: artworkRect.midY / containerSize.height
        )
    }
}
