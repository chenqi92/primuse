#if os(iOS)
import UIKit

/// 竖版叙事页进场时请求竖屏，退场时还原进来之前的朝向。
///
/// 年度报告这类满屏卡片是按 1080×1920 的竖版画幅排的，上下滑又是切卡手势，
/// 横屏下每张卡都溢出且没法靠滚动救回来。与其为这种页面另排一套横版，
/// 不如进页面时把界面转回竖屏。
///
/// 这是尽力而为的锁：请求只改当前的界面朝向，用户之后再转动设备，系统仍可能转回横屏 ——
/// 那种情况下的表现与不加锁时一样，不会更糟。
///
/// 播放页的 MV 全屏另有一套同样基于场景几何请求的控制器。两者各自记各自的还原值，
/// 也不会同时处于激活态（年度报告是首页上的全屏 cover），所以还原时不会顶掉对方记下的朝向。
@MainActor
enum InterfaceOrientationLock {
    /// 进入时记下的朝向；nil 表示当前没有处于锁定态。
    private static var restoreMask: UIInterfaceOrientationMask?

    static func enterPortrait() {
        // 平板与折叠屏内屏本来就装得下这类页面，不去强转；也只有手机会接受朝向请求。
        // 折叠屏内屏的 idiom 仍是手机，但系统不接受它的朝向请求（被拒时的回调在后台队列上），
        // 按宽高都是常规尺寸把它认出来。
        guard UIDevice.current.userInterfaceIdiom == .phone,
              let scene = foregroundWindowScene,
              !isRegularCanvas(scene) else { return }

        // 只在第一次进入时记录。页面重新出现（例如分享面板收起）时再记一次，
        // 记下的就成了已经被自己转成的竖屏，原来的朝向会丢。
        if restoreMask == nil {
            restoreMask = mask(for: scene.interfaceOrientation)
        }
        request(.portrait, in: scene)
    }

    static func restore() {
        guard let restoreMask else { return }
        // 先清掉再看能不能真的发请求：退到后台时取不到前台场景，这一份记录留着的话，
        // 下次进页面会把它当成「进来之前的朝向」还原，反而转到一个用户没要过的方向。
        self.restoreMask = nil
        guard UIDevice.current.userInterfaceIdiom == .phone,
              let scene = foregroundWindowScene,
              !isRegularCanvas(scene) else { return }
        request(restoreMask, in: scene)
    }

    /// 宽高都是常规尺寸：iPhone Duo 展开的内屏。Plus / Pro Max 横屏是常规宽度、紧凑高度，照旧请求。
    private static func isRegularCanvas(_ scene: UIWindowScene) -> Bool {
        let traits = scene.traitCollection
        return traits.horizontalSizeClass == .regular && traits.verticalSizeClass == .regular
    }

    #if DEBUG
    /// 调试构建的启动自动化用：模拟器没有命令行转屏，`PRIMUSE_ORIENTATION=landscape|portrait` 时由 App 自己请求。
    static func debugRequest(landscape: Bool) {
        guard UIDevice.current.userInterfaceIdiom == .phone,
              let scene = foregroundWindowScene else { return }
        request(landscape ? .landscapeRight : .portrait, in: scene)
    }
    #endif

    private static var foregroundWindowScene: UIWindowScene? {
        let applicationScenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter {
                $0.activationState == .foregroundActive
                    && $0.session.role == .windowApplication
            }
        // CarPlay 与外接屏的场景可能与手机同时处于前台活跃状态，只有主应用场景
        // 能接受手机的朝向请求，优先取有 key window 的那个。
        return applicationScenes.first { $0.keyWindow != nil }
            ?? applicationScenes.first
    }

    private static func mask(for orientation: UIInterfaceOrientation) -> UIInterfaceOrientationMask {
        switch orientation {
        case .landscapeLeft: return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        case .portraitUpsideDown: return .portraitUpsideDown
        default: return .portrait
        }
    }

    private static func request(_ orientations: UIInterfaceOrientationMask, in scene: UIWindowScene) {
        // 系统拒绝请求时在后台队列回调:闭包不能沿用外面的主线程隔离,否则运行时的隔离检查当场崩溃。
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientations)) { @Sendable error in
            plog("⚠️ Interface orientation request failed: \(error.localizedDescription)")
        }
    }
}
#endif
