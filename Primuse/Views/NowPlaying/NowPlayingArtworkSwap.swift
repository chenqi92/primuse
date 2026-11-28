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

/// 播放页封面换歌宿主：
/// - 能判定下一首 / 上一首方向且允许方向切换时，沿方向滑动缩放换图；
/// - 其余换歌（直接点歌、全铺封面、歌词模式缩略图或开启减少动态效果）统一做双层原地交叉渐变，
///   消除直接替换的生硬跳变。
///
/// 每一层是一个完整的「封面 + 飞行修饰」,由调用方的 `layer` 画出来;这里只在外面加
/// 位移、缩放和透明度。状态都在这一层里,换歌时多出来的重画只落在封面上。
struct NowPlayingArtworkSwapHost<Layer: View>: View {
    let subject: NowPlayingArtworkSwapSubject
    /// 这次换歌允许按方向滑动换图。
    let allowsDirectionalSwap: Bool
    /// 这次换歌允许平滑原地交叉渐变（不满足方向换图时回退到此路径）。
    var allowsCrossfadeSwap: Bool = true
    /// 封面在这一层里的位置:缩放围着它的中心,位移按它的宽度算。
    let artworkRect: CGRect
    let containerSize: CGSize
    @ViewBuilder let layer: (NowPlayingArtworkSwapSubject) -> Layer

    @Environment(AudioPlayerService.self) private var player
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.displayScale) private var displayScale

    @State private var layers: [SwapLayer] = [SwapLayer(id: 0, frozen: nil, phase: .resting, mode: .none)]
    @State private var nextLayerID = 1
    /// 上一次换歌之后记下的「接下来那首」「前一首」,下一次换歌时拿来判断是不是自然播完。
    /// 不参与绘制,放在引用里,更新它不重画。
    @State private var neighbours = Neighbours()
    /// 当前那一层画的这一首。换歌那一帧它还是旧歌(要退场的那一首),等判断完方式才换成新歌:
    /// 不然要退场的那一层会先被换成新歌、再被拉回旧歌,中间闪一下。
    @State private var displayed: NowPlayingArtworkSwapSubject?

    private final class Neighbours {
        struct RecordKey: Equatable {
            let songID: String?
            let queueGeneration: Int
            let shuffleEnabled: Bool
            let repeatMode: RepeatMode
        }

        var recordedKey: RecordKey?
        var nextSong: Song?
        var nextID: String?
        var previousID: String?
        var prewarmedSongID: String?
        var prewarmedRevision: Int?
        var prewarmGeneration = 0
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
        var mode: TrackSwitchTransitionPolicy.ArtworkTransitionMode
    }

    var body: some View {
        ZStack {
            ForEach(layers) { item in
                layer(item.frozen ?? displayed ?? subject)
                    .modifier(NowPlayingArtworkSwapMotion(
                        progress: item.phase == .exiting ? 1 : 0,
                        mode: item.mode,
                        artworkRect: artworkRect,
                        containerSize: containerSize,
                        isRightToLeft: layoutDirection == .rightToLeft
                    ))
                    .transition(entryTransition(for: item.mode))
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
            } else if !allowsCrossfadeSwap {
                // 开始往歌词那边飞、播放页收起时,还在退场的那一层直接收掉,不跟着飞。
                dropExitingLayers()
            }
        }
        .onChange(of: allowsCrossfadeSwap) { _, allows in
            if !allows {
                dropExitingLayers()
            }
        }
    }

    private func entryTransition(for mode: TrackSwitchTransitionPolicy.ArtworkTransitionMode) -> AnyTransition {
        guard mode != .none else { return .identity }
        return .asymmetric(
            insertion: .modifier(
                active: NowPlayingArtworkSwapMotion(
                    progress: -1,
                    mode: mode,
                    artworkRect: artworkRect,
                    containerSize: containerSize,
                    isRightToLeft: layoutDirection == .rightToLeft
                ),
                identity: NowPlayingArtworkSwapMotion(
                    progress: 0,
                    mode: mode,
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
        let directionalStyle = ArtworkSwapPolicy.style(
            newSongID: subject.song?.id,
            predictedNextID: neighbours.nextID,
            predictedPreviousID: neighbours.previousID,
            manualIntent: intent?.direction,
            intentAge: intent?.age
        )
        recordNeighbours()

        let mode = TrackSwitchTransitionPolicy.artworkTransition(
            outgoingSongID: outgoing?.song?.id,
            incomingSongID: subject.song?.id,
            allowsDirectionalSwap: allowsDirectionalSwap,
            allowsCrossfadeSwap: allowsCrossfadeSwap,
            reduceMotion: reduceMotion,
            directionalStyle: directionalStyle
        )
        guard mode != .none, let outgoing else {
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
        let motion: PMMotion = switch mode {
        case .directional(let style):
            style.isGentle ? .trackSwapGentle : .trackSwap
        case .crossfade, .none:
            .trackChange
        }
        withAnimation(motion.animation) {
            for index in layers.indices where layers[index].phase == .resting {
                layers[index].phase = .exiting
                layers[index].frozen = outgoing
                layers[index].mode = mode
            }
            layers.append(SwapLayer(id: newID, frozen: nil, phase: .resting, mode: mode))
        }

        let retiring = Set(layers.filter { $0.phase == .exiting }.map(\.id))
        let cleanupDelay = motion.settleDuration + 0.04
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(cleanupDelay))
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
        let key = Neighbours.RecordKey(
            songID: subject.song?.id,
            queueGeneration: player.queueGeneration,
            shuffleEnabled: player.shuffleEnabled,
            repeatMode: player.repeatMode
        )
        if neighbours.recordedKey == key {
            prewarm(neighbours.nextSong)
            return
        }
        let entries = player.queueEntries
        let next = player.upcomingQueueTraversalTargets(maximumCount: 1, respectsRepeatOne: false)
            .first
            .flatMap { entries.indices.contains($0.queueIndex) ? entries[$0.queueIndex].song : nil }
        neighbours.recordedKey = key
        neighbours.nextSong = next
        neighbours.nextID = next?.id
        neighbours.previousID = player.previousQueueTraversalTarget()
            .flatMap { entries.indices.contains($0.queueIndex) ? entries[$0.queueIndex].song.id : nil }
        prewarm(next)
    }

    /// 播放页露着时把下一首的大封面先解码进内存:按下一首时新封面从第一帧就在,不是滑到一半才冒出来。
    /// 上一首刚刚画过,本来就在内存里。只读本机已存的封面,稍等一会儿再做,不跟起播抢资源。
    private func prewarm(_ song: Song?) {
        guard allowsDirectionalSwap, !reduceMotion, let song,
              song.sourceID != AppleMusicLibraryService.systemSourceID else {
            neighbours.prewarmTask?.cancel()
            neighbours.prewarmTask = nil
            neighbours.prewarmGeneration &+= 1
            neighbours.prewarmedSongID = nil
            neighbours.prewarmedRevision = nil
            return
        }
        let revision = subject.coverRevision
        if neighbours.prewarmedSongID == song.id, neighbours.prewarmedRevision == revision {
            return
        }
        neighbours.prewarmTask?.cancel()
        neighbours.prewarmGeneration &+= 1
        let generation = neighbours.prewarmGeneration
        neighbours.prewarmedSongID = song.id
        neighbours.prewarmedRevision = revision
        let scale = displayScale
        neighbours.prewarmTask = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else {
                await MainActor.run {
                    if neighbours.prewarmGeneration == generation {
                        neighbours.prewarmedSongID = nil
                        neighbours.prewarmedRevision = nil
                    }
                }
                return
            }
            let succeeded = await CachedArtworkView.prewarm(
                songID: song.id,
                coverRef: song.coverArtFileName,
                sourceID: song.sourceID,
                filePath: song.filePath,
                fileFormat: song.fileFormat,
                revisionToken: revision,
                size: NowPlayingView.artworkRenderSize,
                displayScale: scale
            )
            guard neighbours.prewarmGeneration == generation else { return }
            neighbours.prewarmTask = nil
            if !succeeded || Task.isCancelled {
                neighbours.prewarmedSongID = nil
                neighbours.prewarmedRevision = nil
            }
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
    let mode: TrackSwitchTransitionPolicy.ArtworkTransitionMode
    let artworkRect: CGRect
    let containerSize: CGSize
    let isRightToLeft: Bool

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let pose = pose
        // 停在原位时 scale 恒为 1，锚点固定为 .center，避免封面 ⇄ 歌词转场因 artworkRect 变化触发逐帧缩放锚点插值。
        content
            .scaleEffect(pose.scale, anchor: pose.scale == 1 ? .center : anchor)
            .offset(x: pose.offset)
            .opacity(pose.opacity)
    }

    private var pose: (offset: CGFloat, scale: CGFloat, opacity: Double) {
        guard progress != 0 else { return (0, 1, 1) }
        switch mode {
        case .none:
            return (0, 1, 1)
        case .crossfade:
            return (0, 1, TrackSwitchTransitionPolicy.crossfadeLayerOpacity(signedProgress: progress))
        case .directional(let style):
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
    }

    private var anchor: UnitPoint {
        guard containerSize.width > 0, containerSize.height > 0 else { return .center }
        return UnitPoint(
            x: artworkRect.midX / containerSize.width,
            y: artworkRect.midY / containerSize.height
        )
    }
}
