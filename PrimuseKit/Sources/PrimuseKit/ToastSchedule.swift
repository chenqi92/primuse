import Foundation

/// 底部提示条(PMToast)的排队规则。
///
/// 一次只露一条:新来的直接替换正在显示的那条,不叠成一摞。提示分两种:
/// - 临时的(有时长):到点自己退下,比如「已加入队列」「已清理 12 MB」。
/// - 常驻的(没有时长):由发起方撤,比如批量删除的进度、等着撤销的删除。
///
/// 常驻的垫在底下,临时的盖在上面;临时的退下后底下的常驻那条重新露出来。
/// 同一个来源(`key`)的新条目会顶掉它自己的旧条目,不管旧的在哪一层 ——
/// 进度换成结果之后,进度不该在结果退下时又冒出来。
public struct ToastSchedule: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        /// 提示的来源。同一个来源只留最新的一条。
        public let key: String
        /// 每次 `show` 都换一个新号,界面靠它分辨「换了一条」与「还是那一条」。
        public let serial: UInt64
        /// nil 表示常驻,等发起方撤。
        public let deadline: TimeInterval?

        public var isPersistent: Bool { deadline == nil }
    }

    /// 界面上这一次该怎么动。
    public enum Change: Equatable, Sendable {
        /// 没有变化。
        case none
        /// 原来没有,浮上来。
        case appear
        /// 原来有,换成另一条:原地换内容,不先沉下去再浮上来。
        case replace
        /// 原来有,现在没有:沉下去。
        case disappear
    }

    public private(set) var transient: Entry?
    public private(set) var persistent: Entry?
    private var lastSerial: UInt64 = 0

    public init() {}

    /// 现在该露出来的那一条。
    public var visible: Entry? { transient ?? persistent }

    /// 下一次需要醒来处理到期的时刻。只有临时的那条会到期。
    public var nextDeadline: TimeInterval? { transient?.deadline }

    /// 放一条新提示。`duration` 为 nil 表示常驻。
    @discardableResult
    public mutating func show(key: String, duration: TimeInterval?, now: TimeInterval) -> Entry {
        lastSerial &+= 1
        let deadline = duration.map { now + max(0, $0) }
        let entry = Entry(key: key, serial: lastSerial, deadline: deadline)
        if transient?.key == key { transient = nil }
        if persistent?.key == key { persistent = nil }
        if entry.isPersistent {
            persistent = entry
        } else {
            transient = entry
        }
        return entry
    }

    /// 撤掉某个来源的提示(两层都撤)。返回是否真的撤掉了什么。
    @discardableResult
    public mutating func dismiss(key: String) -> Bool {
        var changed = false
        if transient?.key == key {
            transient = nil
            changed = true
        }
        if persistent?.key == key {
            persistent = nil
            changed = true
        }
        return changed
    }

    /// 只撤掉某一次放出来的那条。到期的计时器用它:计时期间同一来源又放了一条新的,
    /// 旧计时器不能把新的撤掉。
    @discardableResult
    public mutating func dismiss(serial: UInt64) -> Bool {
        if transient?.serial == serial {
            transient = nil
            return true
        }
        if persistent?.serial == serial {
            persistent = nil
            return true
        }
        return false
    }

    /// 撤掉到期的临时提示。返回是否有变化。
    @discardableResult
    public mutating func expire(now: TimeInterval) -> Bool {
        guard let deadline = transient?.deadline, deadline <= now else { return false }
        transient = nil
        return true
    }

    /// 全部撤掉。
    public mutating func removeAll() {
        transient = nil
        persistent = nil
    }

    /// 从 `old` 换到 `new` 时界面该做的动作。
    public static func change(from old: Entry?, to new: Entry?) -> Change {
        switch (old, new) {
        case (nil, nil):
            return .none
        case (nil, .some):
            return .appear
        case (.some, nil):
            return .disappear
        case let (.some(old), .some(new)):
            return old.serial == new.serial ? .none : .replace
        }
    }
}
