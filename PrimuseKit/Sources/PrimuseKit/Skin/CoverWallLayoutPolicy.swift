import Foundation

/// 封面墙里的一格。
public struct CoverWallTile: Sendable, Equatable, Identifiable {
    /// 视图身份。同一张封面在一面墙里出现多次时靠它区分,同时让同一张封面
    /// 在换构图时被当成「同一个视图移动了」,而不是一个消失、一个出现。
    public let id: String
    /// 这一格画哪张封面(调用方传进来的 id)。
    public let coverID: String
    public let column: Int
    public let row: Int
    /// 占几格见方:1 或 2。
    public let span: Int
    public let isFocus: Bool
}

public struct CoverWallComposition: Sendable, Equatable {
    public let columns: Int
    public let rows: Int
    public let tiles: [CoverWallTile]
}

/// 可以上墙的一张封面:代表它的那首歌,以及用来判断「是不是同一张封面」的分组键
/// (通常是专辑 id —— 同一张专辑的十首歌只该占一格)。
public struct CoverWallCandidate: Sendable, Equatable {
    public let songID: String
    public let groupKey: String
    /// 已知有封面文件。没有的歌大概率只能画出占位图,不上墙。
    public let hasKnownArtwork: Bool

    public init(songID: String, groupKey: String, hasKnownArtwork: Bool) {
        self.songID = songID
        self.groupKey = groupKey
        self.hasKnownArtwork = hasKnownArtwork
    }
}

/// 整面墙在头图区域里的摆放:格子大小、间距、整体偏移与倾角。
public struct CoverWallGeometry: Sendable, Equatable {
    public let cellSize: Double
    public let gap: Double
    public let originX: Double
    public let originY: Double
    public let rotationDegrees: Double

    public var pitch: Double { cellSize + gap }

    public func planeSide(columns: Int) -> Double {
        Double(columns) * cellSize + Double(max(0, columns - 1)) * gap
    }

    /// 一格在墙平面(未旋转)里的位置与边长。
    public func frame(of tile: CoverWallTile) -> (x: Double, y: Double, side: Double) {
        let side = Double(tile.span) * cellSize + Double(tile.span - 1) * gap
        return (Double(tile.column) * pitch, Double(tile.row) * pitch, side)
    }
}

/// 封面墙的构图规则。
///
/// 墙是一张 5×5 的方格,少数封面占 2×2,整体倾斜后铺满头图。构图是手工排好的几张模板,
/// 而不是随机生成:随机容易出现「大图挤在一角」「同一张封面挨着出现」这类一眼就难看的
/// 结果,而模板可以逐张在本机验证「无空洞、无重叠、焦点落在看得见的位置」。
public enum CoverWallLayoutPolicy {
    public static let columns = 5
    public static let rows = 5
    /// 低于这个数量就不铺墙,改用单封面头图 —— 三两张封面反复出现只会显得凑数。
    public static let minimumDistinctCovers = 4
    /// 换构图的间隔(秒)。
    public static let reflowInterval: Double = 6

    struct Slot: Sendable, Equatable {
        let column: Int
        let row: Int
        let span: Int
    }

    /// 每张模板的第一格是焦点位:一块 2×2,落在倾斜之后头图的可见区域内。
    static let templates: [[Slot]] = [
        [
            Slot(column: 1, row: 0, span: 2), Slot(column: 3, row: 1, span: 2),
            Slot(column: 0, row: 2, span: 2), Slot(column: 2, row: 3, span: 2),
            Slot(column: 0, row: 0, span: 1), Slot(column: 3, row: 0, span: 1),
            Slot(column: 4, row: 0, span: 1), Slot(column: 0, row: 1, span: 1),
            Slot(column: 2, row: 2, span: 1), Slot(column: 4, row: 3, span: 1),
            Slot(column: 0, row: 4, span: 1), Slot(column: 1, row: 4, span: 1),
            Slot(column: 4, row: 4, span: 1),
        ],
        [
            Slot(column: 2, row: 1, span: 2), Slot(column: 0, row: 0, span: 2),
            Slot(column: 1, row: 3, span: 2), Slot(column: 2, row: 0, span: 1),
            Slot(column: 3, row: 0, span: 1), Slot(column: 4, row: 0, span: 1),
            Slot(column: 4, row: 1, span: 1), Slot(column: 0, row: 2, span: 1),
            Slot(column: 1, row: 2, span: 1), Slot(column: 4, row: 2, span: 1),
            Slot(column: 0, row: 3, span: 1), Slot(column: 3, row: 3, span: 1),
            Slot(column: 4, row: 3, span: 1), Slot(column: 0, row: 4, span: 1),
            Slot(column: 3, row: 4, span: 1), Slot(column: 4, row: 4, span: 1),
        ],
        [
            Slot(column: 2, row: 0, span: 2), Slot(column: 0, row: 1, span: 2),
            Slot(column: 2, row: 3, span: 2), Slot(column: 0, row: 0, span: 1),
            Slot(column: 1, row: 0, span: 1), Slot(column: 4, row: 0, span: 1),
            Slot(column: 4, row: 1, span: 1), Slot(column: 2, row: 2, span: 1),
            Slot(column: 3, row: 2, span: 1), Slot(column: 4, row: 2, span: 1),
            Slot(column: 0, row: 3, span: 1), Slot(column: 1, row: 3, span: 1),
            Slot(column: 4, row: 3, span: 1), Slot(column: 0, row: 4, span: 1),
            Slot(column: 1, row: 4, span: 1), Slot(column: 4, row: 4, span: 1),
        ],
    ]

    public static var compositionCount: Int { templates.count }

    public static func prefersWall(distinctCoverCount: Int) -> Bool {
        distinctCoverCount >= minimumDistinctCovers
    }

    /// 从一个集合里挑出上墙的封面:按集合内的顺序,每个分组只取第一首,跳过没有封面的。
    ///
    /// 大歌单不必扫到底 —— 墙上最多二十来张,扫过 `scanLimit` 首还没凑够也就不凑了。
    /// `focusGroupKey`(正在播放的那首所在的分组)即使排在很后面也保证入选,否则
    /// 「正在播放的封面成为焦点」在长歌单里永远不会发生;但也只多找几倍的距离,
    /// 不会为了一首不在这个集合里的歌把几万首扫到底。
    ///
    /// 返回值带着原始元素,调用方不必再按 id 回查一遍。
    public static func pool<Element>(
        from elements: some Sequence<Element>,
        focusGroupKey: String? = nil,
        limit: Int = 24,
        scanLimit: Int = 600,
        candidate: (Element) -> CoverWallCandidate
    ) -> [(candidate: CoverWallCandidate, element: Element)] {
        guard limit > 0 else { return [] }
        var seen: Set<String> = []
        var pool: [(candidate: CoverWallCandidate, element: Element)] = []
        var focus: (candidate: CoverWallCandidate, element: Element)?
        var scanned = 0

        for element in elements {
            scanned += 1
            let entry = candidate(element)
            if entry.hasKnownArtwork {
                if focus == nil, let focusGroupKey, entry.groupKey == focusGroupKey {
                    focus = (entry, element)
                }
                if pool.count < limit, seen.insert(entry.groupKey).inserted {
                    pool.append((entry, element))
                }
            }
            let focusSettled = focusGroupKey == nil || focus != nil
            if pool.count >= limit, focusSettled { break }
            if scanned >= scanLimit, focusSettled || scanned >= scanLimit * 4 { break }
        }

        if let focus, !pool.contains(where: { $0.candidate.groupKey == focus.candidate.groupKey }) {
            if pool.count >= limit { pool.removeLast() }
            pool.append(focus)
        }
        return pool
    }

    public static func pool(
        from candidates: some Sequence<CoverWallCandidate>,
        focusGroupKey: String? = nil,
        limit: Int = 24,
        scanLimit: Int = 600
    ) -> [CoverWallCandidate] {
        pool(
            from: candidates,
            focusGroupKey: focusGroupKey,
            limit: limit,
            scanLimit: scanLimit,
            candidate: { $0 }
        ).map(\.candidate)
    }

    /// 某一拍的构图。
    ///
    /// - Parameters:
    ///   - coverIDs: 可用的封面(按集合内的顺序,允许重复,内部会去重)。
    ///   - step: 第几拍。模板按拍循环,封面的取样窗口也跟着移动,所以大歌单每一拍都能看到新封面。
    ///   - focusID: 要突出的封面(通常是正在播放的那首);为 nil 或不在列表里时,焦点位按普通格处理。
    public static func composition(
        coverIDs: [String],
        step: Int,
        focusID: String? = nil
    ) -> CoverWallComposition {
        var seen: Set<String> = []
        let pool = coverIDs.filter { seen.insert($0).inserted }
        guard !pool.isEmpty else {
            return CoverWallComposition(columns: columns, rows: rows, tiles: [])
        }

        let safeStep = ((step % templates.count) + templates.count) % templates.count
        let slots = templates[safeStep]
        let focus = focusID.flatMap { pool.contains($0) ? $0 : nil }

        // 取样窗口随拍移动;封面不够铺满时循环取用。
        let stride = max(1, slots.count / 2)
        var cursor = (max(0, step) * stride) % pool.count
        var assigned: [(Slot, String)] = []

        for (index, slot) in slots.enumerated() {
            if index == 0, let focus {
                assigned.append((slot, focus))
                continue
            }
            var candidate = pool[cursor % pool.count]
            var attempts = 0
            // 尽量不让同一张封面与相邻格重复,也不让焦点封面在别处再出现一次。
            while attempts < pool.count,
                  candidate == focus
                    || assigned.contains(where: { $0.1 == candidate && areAdjacent($0.0, slot) })
                    || (pool.count >= slots.count && assigned.contains(where: { $0.1 == candidate })) {
                cursor += 1
                attempts += 1
                candidate = pool[cursor % pool.count]
            }
            assigned.append((slot, candidate))
            cursor += 1
        }

        var occurrences: [String: Int] = [:]
        let tiles = assigned.enumerated().map { index, pair -> CoverWallTile in
            let (slot, coverID) = pair
            let occurrence = occurrences[coverID, default: 0]
            occurrences[coverID] = occurrence + 1
            return CoverWallTile(
                id: occurrence == 0 ? coverID : "\(coverID)#\(occurrence)",
                coverID: coverID,
                column: slot.column,
                row: slot.row,
                span: slot.span,
                isFocus: index == 0 && focus != nil
            )
        }
        return CoverWallComposition(columns: columns, rows: rows, tiles: tiles)
    }

    static func areAdjacent(_ first: Slot, _ second: Slot) -> Bool {
        // 两个方块的外扩一格的范围有交集,即边或角相邻。
        let firstMaxColumn = first.column + first.span
        let firstMaxRow = first.row + first.span
        let secondMaxColumn = second.column + second.span
        let secondMaxRow = second.row + second.span
        return first.column <= secondMaxColumn && second.column <= firstMaxColumn
            && first.row <= secondMaxRow && second.row <= firstMaxRow
    }

    /// 让倾斜之后的墙面盖满 `width × height` 的头图区域。
    ///
    /// 比例取自设计稿(390 宽时每格 118、间距 8、整体左移 150 上移 170、倾角 −14°),
    /// 按宽度等比缩放;头图比设计稿更高时再整体放大,保证下沿不露底。
    public static func geometry(width: Double, height: Double) -> CoverWallGeometry {
        guard width > 0, height > 0 else {
            return CoverWallGeometry(cellSize: 0, gap: 0, originX: 0, originY: 0, rotationDegrees: -14)
        }
        let designWidth = 390.0
        let designHeroHeight = 400.0
        let scale = max(width / designWidth, height / designHeroHeight)
        let cellSize = 118.0 * scale
        let gap = 8.0 * scale
        let side = Double(columns) * cellSize + Double(columns - 1) * gap
        // 设计稿里墙面中心在头图中线左侧 34、距顶 141(头图高 400)的位置。
        let planeCenterX = width / 2 - 34.0 * scale
        let planeCenterY = height * (141.0 / designHeroHeight)
        return CoverWallGeometry(
            cellSize: cellSize,
            gap: gap,
            originX: planeCenterX - side / 2,
            originY: planeCenterY - side / 2,
            rotationDegrees: -14
        )
    }

    /// 头图区域是否被倾斜后的墙面完全盖住(用于断言几何)。
    static func covers(width: Double, height: Double, geometry: CoverWallGeometry) -> Bool {
        let side = geometry.planeSide(columns: columns)
        let centerX = geometry.originX + side / 2
        let centerY = geometry.originY + side / 2
        let radians = -geometry.rotationDegrees * Double.pi / 180
        let cosine = cos(radians)
        let sine = sin(radians)
        for (x, y) in [(0.0, 0.0), (width, 0.0), (0.0, height), (width, height)] {
            let dx = x - centerX
            let dy = y - centerY
            let localX = dx * cosine - dy * sine
            let localY = dx * sine + dy * cosine
            if abs(localX) > side / 2 || abs(localY) > side / 2 { return false }
        }
        return true
    }
}
