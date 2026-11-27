import Foundation

/// 常规宽度的 iPhone 画布(iPhone Duo 内屏横握)上,详情页与首页从竖向单栏重排成两栏。
///
/// 苹果「音乐」在 Duo 上的做法:外屏是竖向单栏,内屏变宽时同一份内容重排成两栏,不换功能、不换层级。
/// iPad 有自己的侧边栏版式,不跟着变;Duo 内屏竖握(比宽还高)和外屏都保持单栏。
public enum WideCanvasColumnsPolicy {
    /// 画布至少这么宽才分两栏:内屏横握(约 890 与 951)能分,iPhone 与内屏竖握(669)不分。
    public static let minimumWidth: Double = 760
    /// 详情页左栏(头图:封面、标题、操作行)的宽度范围与比例。
    public static let detailLeadingFraction: Double = 0.42
    public static let detailLeadingMinimum: Double = 340
    public static let detailLeadingMaximum: Double = 440

    public static func usesTwoColumns(
        isPhone: Bool,
        isRegularWidth: Bool,
        isCompactHeight: Bool,
        width: Double,
        height: Double
    ) -> Bool {
        guard width.isFinite, height.isFinite else { return false }
        return isPhone && isRegularWidth && !isCompactHeight && width > height && width >= minimumWidth
    }

    /// 详情页左栏宽度;右栏是剩下的。
    public static func detailLeadingColumnWidth(pageWidth: Double) -> Double {
        guard pageWidth.isFinite, pageWidth > 0 else { return 0 }
        return min(max(pageWidth * detailLeadingFraction, detailLeadingMinimum), detailLeadingMaximum)
    }

    /// 两栏底部差在这个范围内就算齐了,不为了再齐一点去打乱「放进较矮那栏」的顺序。
    public static let homeColumnsBalanceTolerance: Double = 48
    /// 重新分配时高度按这个粒度取整算子集和:误差每块不过半格,最后仍按真实高度比较。
    private static let homeColumnsHeightUnit: Double = 4
    private static let homeColumnsMaximumBalancedHeight: Double = 200_000

    /// 首页各区块分到两栏,返回左、右两栏各自的下标(各栏里保持原来的先后)。`heights` 是各块
    /// 按栏宽量出来的高度,`spacing` 是同一栏里相邻两块的间距。
    ///
    /// 头两块一左一右,首屏的顺序和单栏一样。之后每块放进当时较矮的那一栏(一样高放左栏)。
    /// 区块高矮差得多 —— 网格样式的「最近添加」半栏宽时动辄七八百点、而且排在后面 —— 这样排完
    /// 两栏底部还可能差出大半屏,较短那栏下面一大片空白;这时把第三块起的区块按子集和重新分,
    /// 让两栏底部尽量齐平。
    public static func homeColumns(heights: [Double], spacing: Double) -> (leading: [Int], trailing: [Int]) {
        let count = heights.count
        guard count > 0 else { return ([], []) }
        guard count > 1 else { return ([0], []) }
        let gap = spacing.isFinite ? max(0, spacing) : 0
        // 每块连同它下面的间距一起算:两栏都有区块时各少一个间距,不影响比较。
        let weights = heights.map { ($0.isFinite ? max(0, $0) : 0) + gap }

        var greedy: [Bool] = [true, false]
        var leading = weights[0]
        var trailing = weights[1]
        for weight in weights.dropFirst(2) {
            let toLeading = leading <= trailing
            greedy.append(toLeading)
            if toLeading { leading += weight } else { trailing += weight }
        }
        let greedyDifference = abs(leading - trailing)
        guard greedyDifference > homeColumnsBalanceTolerance, count > 2 else { return split(greedy) }

        // 子集和按 4 点一格开数组:真实首页几千点高;量出离谱的高度时不开大数组,照「放进较矮那栏」排。
        guard weights.dropFirst(2).reduce(0, +) <= homeColumnsMaximumBalancedHeight else { return split(greedy) }
        let balanced = balancedAssignment(weights: weights)
        let balancedDifference = difference(of: balanced, weights: weights)
        let chosen = balancedDifference + homeColumnsBalanceTolerance < greedyDifference ? balanced : greedy
        return split(chosen)
    }

    /// 第一块在左、第二块在右,其余区块挑一个子集放左栏,让两栏总高最接近。
    private static func balancedAssignment(weights: [Double]) -> [Bool] {
        let free = Array(weights.indices.dropFirst(2))
        let units = free.map { Int((weights[$0] / homeColumnsHeightUnit).rounded()) }
        let total = units.reduce(0, +)
        // 左栏要从剩下的区块里再拿走多少,两栏才一样高。
        let target = (Double(total) + (weights[1] - weights[0]) / homeColumnsHeightUnit) / 2

        // reachedBy[s]:第一次凑出总量 s 时最后用上的那一块(在 free 里的位置);-1 表示还凑不出。
        // 区块按顺序一块块试、总量从大往小填,每块只用一次,倒推出来的那条链下标严格递减。
        var reachedBy = [Int](repeating: -1, count: total + 1)
        var reachable = [Bool](repeating: false, count: total + 1)
        reachable[0] = true
        for (position, unit) in units.enumerated() where unit > 0 {
            var sum = total
            while sum >= unit {
                if !reachable[sum], reachable[sum - unit] {
                    reachable[sum] = true
                    reachedBy[sum] = position
                }
                sum -= 1
            }
        }
        var best = 0
        for sum in 0...total where reachable[sum] && abs(Double(sum) - target) < abs(Double(best) - target) {
            best = sum
        }

        var assignment = [Bool](repeating: false, count: weights.count)
        assignment[0] = true
        var sum = best
        while sum > 0, reachedBy[sum] >= 0 {
            let position = reachedBy[sum]
            assignment[free[position]] = true
            sum -= units[position]
        }
        return assignment
    }

    private static func difference(of assignment: [Bool], weights: [Double]) -> Double {
        var leading = 0.0
        var trailing = 0.0
        for (index, toLeading) in assignment.enumerated() {
            if toLeading { leading += weights[index] } else { trailing += weights[index] }
        }
        return abs(leading - trailing)
    }

    private static func split(_ assignment: [Bool]) -> (leading: [Int], trailing: [Int]) {
        (assignment.indices.filter { assignment[$0] }, assignment.indices.filter { !assignment[$0] })
    }
}
