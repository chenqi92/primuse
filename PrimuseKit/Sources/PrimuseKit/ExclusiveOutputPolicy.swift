import Foundation

/// Mac「独占输出设备」(Core Audio hog mode)这一刻是谁占着。Core Audio 用 pid
/// 表示占用者，-1 表示没有进程独占。
public enum ExclusiveOutputOwner: Equatable, Sendable {
    case nobody
    case thisProcess
    case otherProcess(pid: Int32)

    public init(hogModePID: Int32, currentPID: Int32) {
        if hogModePID < 0 {
            self = .nobody
        } else if hogModePID == currentPID {
            self = .thisProcess
        } else {
            self = .otherProcess(pid: hogModePID)
        }
    }
}

/// 要不要去拿独占、拿不到时怎么报。
///
/// Core Audio 把 hog mode 当开关用：写入的值被忽略，没人独占时写一次是拿下，
/// 本进程独占时写一次是放掉，别的进程独占时写了也不变。所以只有「没人独占」
/// 时才写，放掉时也必须先确认占用者是自己，否则一次「放掉」会变成「拿下」。
public enum ExclusiveOutputClaimPolicy {
    public enum Decision: Equatable, Sendable {
        /// 已经是本进程独占，不用再写。
        case alreadyHeld
        /// 没人独占，去拿。
        case claim
        /// 别的 App 正独占这台设备，不抢，按共享方式继续播。
        case heldByOther(pid: Int32)
        /// AirPlay、蓝牙这类系统管理的无线输出，或这台设备的独占属性不可写。
        case unsupported
    }

    public static func decision(
        owner: ExclusiveOutputOwner,
        isSettable: Bool,
        isSystemManagedWireless: Bool
    ) -> Decision {
        if case .thisProcess = owner { return .alreadyHeld }
        guard !isSystemManagedWireless, isSettable else { return .unsupported }
        switch owner {
        case .nobody: return .claim
        case .otherProcess(let pid): return .heldByOther(pid: pid)
        case .thisProcess: return .alreadyHeld
        }
    }

    /// 放掉独占前的检查：只有占用者是本进程时才写。
    public static func shouldWriteToRelease(owner: ExclusiveOutputOwner) -> Bool {
        owner == .thisProcess
    }
}

/// 独占输出时让设备的物理位深跟随歌曲。
public enum PhysicalOutputBitDepthPolicy {
    /// 设备该工作在多少位。nil 表示不动设备(有损格式、读不到位深)。
    ///
    /// DoP 的标记在 24bit 采样的高 8 位，低于 24bit 会被截掉；DSD 转 PCM 也按
    /// 24bit 给。PCM 的位深向上取到 16/24/32 这三档，设备只认这几种。
    public static func targetBitDepth(sourceBitDepth: Int?, carriesDSD: Bool) -> Int? {
        if carriesDSD { return 24 }
        guard let bits = sourceBitDepth, bits > 0 else { return nil }
        switch bits {
        case ...16: return 16
        case ...24: return 24
        default: return 32
        }
    }

    /// 设备列出的一种物理格式。
    public struct Candidate: Equatable, Sendable {
        public let bitsPerChannel: Int
        public let channelCount: Int
        public let isLinearPCM: Bool
        public let isFloat: Bool
        /// 不可混音的格式(AC-3 直通这类)要整台设备配合，不在这里用。
        public let isMixable: Bool
        /// 支持的采样率范围；两端都是 0 表示任意采样率。
        public let minimumSampleRate: Double
        public let maximumSampleRate: Double

        public init(
            bitsPerChannel: Int,
            channelCount: Int,
            isLinearPCM: Bool,
            isFloat: Bool,
            isMixable: Bool,
            minimumSampleRate: Double,
            maximumSampleRate: Double
        ) {
            self.bitsPerChannel = bitsPerChannel
            self.channelCount = channelCount
            self.isLinearPCM = isLinearPCM
            self.isFloat = isFloat
            self.isMixable = isMixable
            self.minimumSampleRate = minimumSampleRate
            self.maximumSampleRate = maximumSampleRate
        }

        func supports(sampleRate: Double) -> Bool {
            if minimumSampleRate == 0, maximumSampleRate == 0 { return true }
            return sampleRate >= minimumSampleRate - 1 && sampleRate <= maximumSampleRate + 1
        }
    }

    /// 从设备列出的物理格式里挑一个，返回下标。只考虑整数线性 PCM、可混音、
    /// 声道数和采样率都不变的格式；位深正好相等的优先，没有就取比它大的里
    /// 最小的，再没有就取最大的。同一位深有多种排法时取设备列出的第一个。
    public static func select(
        from candidates: [Candidate],
        sampleRate: Double,
        channelCount: Int,
        targetBitDepth: Int
    ) -> Int? {
        let usable = candidates.indices.filter { index in
            let candidate = candidates[index]
            return candidate.isLinearPCM
                && !candidate.isFloat
                && candidate.isMixable
                && candidate.bitsPerChannel > 0
                && candidate.channelCount == channelCount
                && candidate.supports(sampleRate: sampleRate)
        }
        if let exact = usable.first(where: { candidates[$0].bitsPerChannel == targetBitDepth }) {
            return exact
        }
        let deeper = usable.filter { candidates[$0].bitsPerChannel > targetBitDepth }
        if let smallestDeeper = deeper.min(by: { lhs, rhs in
            candidates[lhs].bitsPerChannel < candidates[rhs].bitsPerChannel
                || (candidates[lhs].bitsPerChannel == candidates[rhs].bitsPerChannel && lhs < rhs)
        }) {
            return smallestDeeper
        }
        return usable.max { lhs, rhs in
            candidates[lhs].bitsPerChannel < candidates[rhs].bitsPerChannel
                || (candidates[lhs].bitsPerChannel == candidates[rhs].bitsPerChannel && lhs > rhs)
        }
    }
}
