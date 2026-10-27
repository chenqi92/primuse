#if os(tvOS)
import SwiftUI
import PrimuseKit

/// 专辑的 CD 盒:海报墙上按下一张专辑,先像打开 CD 盒那样掀开盒盖、露出盘片,再进专辑页;
/// 专辑页的封面后面探出半张盘,这张专辑正在放时盘慢慢转。
///
/// 动画只用变换(3D 旋转、位移、转动)和透明度,不动模糊、不改布局:
/// 老款 Apple TV 上也只是多几层合成。「减弱动态效果」打开时不掀盖、盘不转。
enum TVJewelCaseMotion {
    /// 盒盖掀开的角度。铰链在左边,右沿朝人转过来再往左倒。
    static let lidAngle: Double = -72
    /// 透视压得很浅:透视一深,转向镜头的那条边会放大到盖住下面的标题和旁边的卡片。
    static let lidPerspective: CGFloat = 0.18
    /// 盖子转开以后背光,压暗一点。
    static let lidShade: Double = 0.3
    static let lid = Animation.easeOut(duration: 0.36)
    /// 盘片比盒盖晚一点、带一点回弹地滑出来。
    static let disc = Animation.spring(response: 0.46, dampingFraction: 0.78).delay(0.06)
    /// 掀开到这一刻再打开专辑页:盖子差不多到位,盘刚露出来。
    static let handoff: Duration = .milliseconds(400)
    /// 盘转一圈的秒数:慢到看得出在转、又不晃眼。
    static let revolutionSeconds: Double = 14
}

/// 盘片中间那一圈:透明塑料的内环,圆心有孔。印刷面从这一圈外面开始。
private struct TVDiscRing: Shape {
    /// 内圆直径占整张盘的比例。
    var innerRatio: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addEllipse(in: rect)
        let inset = rect.width * (1 - innerRatio) / 2
        path.addEllipse(in: rect.insetBy(dx: inset, dy: inset))
        return path
    }
}

/// 一张印着专辑封面的 CD。印刷面(封面,专辑文件夹里有盘面图时用盘面图)和内环跟着转;
/// 上面那层彩虹反光固定不动,光源不会随盘转。
struct TVCompactDisc: View {
    let album: TVAlbum
    let size: CGFloat
    var spinning = false
    /// 专辑文件夹里的盘面图(`TVAlbumDiscArtwork`)。
    var faceImage: CGImage?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 停着时的角度;转起来以后从这里接着转,停下就停在当时的角度,不跳回原位。
    @State private var restingAngle: Double = 0
    @State private var spinStart: Date?

    /// 实物 CD:中心孔 15mm、透明内环到 46mm,整张 120mm。
    private static let printRatio: CGFloat = 0.38
    private static let holeRatio: CGFloat = 0.125

    private var spins: Bool { spinning && !reduceMotion }

    var body: some View {
        // 印刷面在时间线外面建好,每一帧只改转角,封面视图不跟着重算。
        let face = Group {
            if let faceImage {
                Image(decorative: faceImage, scale: 1)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else {
                TVArtworkView(album: album, size: size, radius: 0)
            }
        }
        .mask(TVDiscRing(innerRatio: Self.printRatio).fill(style: FillStyle(eoFill: true)))
        ZStack {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !spins)) { context in
                face.rotationEffect(.degrees(angle(at: context.date)))
            }
            hub
            sheen
            Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 1.5)
        }
        .frame(width: size, height: size)
        .compositingGroup()
        .shadow(color: .black.opacity(0.4), radius: size * 0.05, y: size * 0.025)
        .accessibilityHidden(true)
        .onChange(of: spins, initial: true) { _, spins in
            if spins {
                spinStart = .now
            } else {
                restingAngle = angle(at: .now)
                spinStart = nil
            }
        }
    }

    private func angle(at date: Date) -> Double {
        guard let spinStart else { return restingAngle }
        let turns = date.timeIntervalSince(spinStart) / TVJewelCaseMotion.revolutionSeconds
        return (restingAngle + turns * 360).truncatingRemainder(dividingBy: 360)
    }

    /// 内环:半透明塑料,外沿一道细亮线,中间一圈叠放环,圆心是孔。
    private var hub: some View {
        ZStack {
            TVDiscRing(innerRatio: Self.holeRatio / Self.printRatio)
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.30), Color.white.opacity(0.10)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    style: FillStyle(eoFill: true)
                )
            Circle().strokeBorder(Color.white.opacity(0.28), lineWidth: 1.5)
            Circle().strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                .frame(width: size * 0.22, height: size * 0.22)
            Circle().strokeBorder(Color.black.opacity(0.35), lineWidth: 1)
                .frame(width: size * Self.holeRatio, height: size * Self.holeRatio)
        }
        .frame(width: size * Self.printRatio, height: size * Self.printRatio)
    }

    /// 盘面的反光:一圈很淡的彩虹(只落在印刷面上)和一道斜向白光。
    private var sheen: some View {
        ZStack {
            AngularGradient(
                colors: [
                    .clear, Color(red: 1, green: 0.4, blue: 0.7).opacity(0.16),
                    Color(red: 0.4, green: 0.8, blue: 1).opacity(0.18), .clear,
                    .clear, Color(red: 1, green: 0.85, blue: 0.4).opacity(0.14),
                    Color(red: 0.5, green: 1, blue: 0.7).opacity(0.12), .clear,
                ],
                center: .center,
                angle: .degrees(-30)
            )
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.30),
                    .init(color: .white.opacity(0.16), location: 0.46),
                    .init(color: .clear, location: 0.60),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .blendMode(.screen)
        .mask(TVDiscRing(innerRatio: Self.printRatio).fill(style: FillStyle(eoFill: true)))
        .allowsHitTesting(false)
    }
}

/// 掀开的 CD 盒里面:盒底(深色塑料,左边一道铰链)和盒里那张盘。
/// 只在海报墙上按下专辑、掀盖的那一下才建出来,平时海报墙上不多画任何东西。
struct TVJewelCaseInterior: View {
    let album: TVAlbum
    let size: CGFloat
    var radius: CGFloat = TVRadius.cover
    /// 盘滑出来了没有:先在盖子底下建好,再滑出来。
    var discOut: Bool
    var discFace: CGImage?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack(alignment: .leading) {
            shape
                .fill(TVColor.bgDeep.opacity(0.92))
                .overlay {
                    shape.fill(
                        LinearGradient(
                            colors: [album.tint.opacity(0.35), album.tint2.opacity(0.18)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                }
                .overlay { shape.strokeBorder(Color.white.opacity(0.18), lineWidth: 1.5) }
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(width: size * 0.05)
                .clipShape(shape)
            TVCompactDisc(album: album, size: size * 0.9, faceImage: discFace)
                .rotationEffect(.degrees(discOut ? 30 : 0))
                .offset(x: size * 0.05 + (discOut ? size * 0.16 : 0))
                .animation(TVJewelCaseMotion.disc, value: discOut)
        }
        .frame(width: size, height: size)
    }
}

/// 专辑页左上角的封面:后面探出半张盘。进页时盘从封面后面滑出来;
/// 这张专辑正在放时盘慢慢转,暂停就停。
struct TVAlbumCaseArtwork<Cover: View>: View {
    let album: TVAlbum
    let size: CGFloat
    var spinning = false
    var discFace: CGImage?
    @ViewBuilder var cover: () -> Cover

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var discOut = false

    /// 盘露在封面右边的那一截占封面宽的比例。
    static var peekRatio: CGFloat { 0.34 }

    var body: some View {
        let disc = size * 0.92
        ZStack(alignment: .leading) {
            TVCompactDisc(album: album, size: disc, spinning: spinning && discOut, faceImage: discFace)
                .offset(x: (size - disc) / 2 + (discOut ? size * Self.peekRatio : 0))
            cover()
        }
        .frame(width: size * (1 + Self.peekRatio), height: size, alignment: .leading)
        .task {
            guard !discOut else { return }
            guard !reduceMotion else {
                discOut = true
                return
            }
            // 等专辑页呈现完再滑出来,和海报墙上掀开的盒子接上。
            try? await Task.sleep(for: .milliseconds(260))
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.7, dampingFraction: 0.82)) { discOut = true }
        }
    }
}
#endif
