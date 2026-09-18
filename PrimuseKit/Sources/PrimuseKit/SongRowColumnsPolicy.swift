import Foundation

/// 歌曲行在够宽的容器里显示的对齐列。
///
/// 手机横屏时一行有七百多点宽，封面和标题之后全是 `Spacer()`，而副标题里本来
/// 就把「艺术家 · 专辑 · 时长」串成一条 caption。够宽时把专辑与时长从那条串里
/// 拿出来单独成列，信息量不变，只是换了对齐方式。
///
/// 默认值 `hidden` 表示一列都不显示：竖屏手机、分屏小窗，以及任何没有挂容器
/// 修饰符的列表都落在这一档，行的排布与原来完全一致。
public struct SongRowColumns: Equatable, Sendable {
    /// 专辑列（左对齐、定宽）。
    public let showsAlbum: Bool
    /// 时长列（右对齐、等宽数字）。
    public let showsDuration: Bool
    /// 专辑列宽度；`showsAlbum` 为假时是 0。
    public let albumWidth: CGFloat
    /// 时长列宽度；`showsDuration` 为假时是 0。
    public let durationWidth: CGFloat

    public init(
        showsAlbum: Bool,
        showsDuration: Bool,
        albumWidth: CGFloat,
        durationWidth: CGFloat
    ) {
        self.showsAlbum = showsAlbum
        self.showsDuration = showsDuration
        self.albumWidth = albumWidth
        self.durationWidth = durationWidth
    }

    /// 一列都不显示。
    public static let hidden = SongRowColumns(
        showsAlbum: false,
        showsDuration: false,
        albumWidth: 0,
        durationWidth: 0
    )

    /// 行里是否出现了任何一列。
    public var isActive: Bool { showsAlbum || showsDuration }
}

/// 按承载歌曲行的**容器宽度**决定行里露出哪几列、每列多宽。
///
/// 判据只有宽度，不看设备也不看尺寸等级：手机横屏、iPad、Mac 上的窄侧栏都用
/// 同一条曲线，窗口一窄列就自己收回去。门槛按容器宽度标定（行本身还要再减去
/// 列表的左右内边距与字母索引让出的那一段），所以这两个数比行宽略大一点。
public enum SongRowColumnsPolicy {
    /// 时长列出现的容器宽度门槛。竖屏手机（约 390）与分屏小窗都够不到。
    public static let durationThreshold: CGFloat = 600
    /// 专辑列出现的容器宽度门槛。只有时长列时标题仍然能占满中段，不会显得空。
    public static let albumThreshold: CGFloat = 680
    /// 时长列宽度。caption 等宽数字下「1:23:45」也放得下。
    public static let durationWidth: CGFloat = 56
    /// 专辑列的宽度下限：再窄就只剩两三个字，不如留在副标题里。
    public static let minimumAlbumWidth: CGFloat = 156
    /// 专辑列的宽度上限：宽屏上再宽只会把标题挤窄。
    public static let maximumAlbumWidth: CGFloat = 260
    /// 专辑列占容器宽度的比例。
    private static let albumWidthRatio: CGFloat = 0.22

    /// - Parameters:
    ///   - containerWidth: 承载这批行的容器宽度。
    ///   - allowsAlbum: 调用方本来就不显示专辑时（专辑详情页）传 false。
    public static func columns(
        containerWidth: CGFloat,
        allowsAlbum: Bool = true
    ) -> SongRowColumns {
        guard containerWidth.isFinite, containerWidth >= durationThreshold else {
            return .hidden
        }
        guard allowsAlbum, containerWidth >= albumThreshold else {
            return SongRowColumns(
                showsAlbum: false,
                showsDuration: true,
                albumWidth: 0,
                durationWidth: durationWidth
            )
        }
        // 取最近的整点：比例乘出来的小数尾巴在浮点里会差出 1e-13，向下取整会
        // 让整点宽度偶尔掉一格。
        let proportional = (containerWidth * albumWidthRatio).rounded()
        let albumWidth = min(max(proportional, minimumAlbumWidth), maximumAlbumWidth)
        return SongRowColumns(
            showsAlbum: true,
            showsDuration: true,
            albumWidth: albumWidth,
            durationWidth: durationWidth
        )
    }
}
