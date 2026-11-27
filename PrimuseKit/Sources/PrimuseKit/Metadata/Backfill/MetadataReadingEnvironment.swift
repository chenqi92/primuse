import Foundation

public enum MetadataReadingMode: String, CaseIterable, Sendable {
    case automatic
    case fast
    case energySaving
    /// 完全停掉自动标签读取。热降级只会压低速度, 压不到零 —— 一个上万首的
    /// 云端曲库要读几个小时, 用户必须能把这几个小时的后台工作整个关掉, 而不是
    /// 在三个被热状态压成同一个节奏的档位之间来回换。手动单首/单源重读不受影响。
    case paused

    /// 会自动发起读取的档位。
    public static let automaticCases: [Self] = [.automatic, .fast, .energySaving]

    public var readsAutomatically: Bool { self != .paused }

    /// 用户刚刚点下、必须跑完的工作 (tvOS 扫描的标签富集、手动重读) 不能因为
    /// "暂停自动读取"而停在零并发上。暂停在那里按最保守的读取档位执行。
    public var resolvedForExplicitWork: Self { self == .paused ? .energySaving : self }

    /// 档位选择只对要操心发热、耗电和后台配额的设备有意义。Mac 一直插着电、
    /// 散热余量也够, 读取速度不该让用户自己权衡: 桌面端不显示这个选择, 固定
    /// 按全速跑。播放中、高温和低电量下的自动降速仍然照常生效。
    public static var offersUserSelection: Bool {
        #if os(macOS)
        false
        #else
        true
        #endif
    }

    public static func resolve(
        storedValue: String?,
        legacyFastEnabled: Bool,
        offersUserSelection: Bool = Self.offersUserSelection
    ) -> Self {
        guard offersUserSelection else { return .fast }
        if let storedValue, let mode = Self(rawValue: storedValue) { return mode }
        return legacyFastEnabled ? .fast : .automatic
    }
}

/// 热状态到 `serious` 之后每一档应该歇多久。
///
/// 歇多久按最近实测的 CPU 工作量折算, 纯等网络的便宜标签不该被按最坏情况罚站;
/// 但折算结果必须按档位分层, 否则 `serious` 会把三档压成同一个节奏 —— 这正是
/// "无论调到哪一档都一样烫"的直接原因。天花板同时是测量缺失时的保守取值。
public struct MetadataReadingThermalRest: Sendable, Equatable {
    public let multiplier: Double
    public let floor: TimeInterval
    public let ceiling: TimeInterval

    public static func budget(for preference: MetadataReadingMode) -> Self {
        switch preference {
        case .fast: Self(multiplier: 3, floor: 0.1, ceiling: 1.5)
        case .automatic: Self(multiplier: 8, floor: 1.5, ceiling: 4)
        case .energySaving, .paused: Self(multiplier: 16, floor: 3, ceiling: 6)
        }
    }

    public func cooldown(recentProcessingDuration: TimeInterval?) -> TimeInterval {
        guard let recentProcessingDuration, recentProcessingDuration.isFinite,
              recentProcessingDuration >= 0 else { return ceiling }
        return min(ceiling, max(floor, recentProcessingDuration * multiplier))
    }
}

public enum MetadataReadingThermalState: Sendable {
    case nominal, fair, serious, critical
}

public enum MetadataReadingConstraint: String, Sendable {
    case none, playback, lowPower, thermal, cooling, background, paused
}

public struct MetadataReadingDeviceProfile: Sendable, Equatable {
    public enum Platform: Sendable {
        case mobile, desktop, television
    }

    public let platform: Platform
    public let activeProcessorCount: Int
    public let physicalMemory: UInt64

    public init(platform: Platform, activeProcessorCount: Int, physicalMemory: UInt64) {
        self.platform = platform
        self.activeProcessorCount = max(1, activeProcessorCount)
        self.physicalMemory = physicalMemory
    }

    // A deterministic compatibility profile for callers without device context.
    public static let baseline = Self(
        platform: .mobile, activeProcessorCount: 6, physicalMemory: 4 * 1_024 * 1_024 * 1_024
    )

    /// 读取预算每排一首歌都要问一次, 机器的核数和内存在进程里不会变, 只取一次。
    public static var current: Self { measuredCurrent }

    private static let measuredCurrent: Self = {
        #if os(macOS)
        let platform = Platform.desktop
        #elseif os(tvOS)
        let platform = Platform.television
        #else
        let platform = Platform.mobile
        #endif
        return Self(platform: platform,
                    activeProcessorCount: ProcessInfo.processInfo.activeProcessorCount,
                    physicalMemory: ProcessInfo.processInfo.physicalMemory)
    }()

    public func maximumWorkers(offlineSource: Bool, pooledHTTPRemoteSource: Bool = false) -> Int {
        let gib: UInt64 = 1_024 * 1_024 * 1_024
        // These are conservative admission limits, not a CPU benchmark. Leave
        // room for rendering/playback and bound tag plus artwork allocations;
        // a large desktop's logical core count must not multiply readers freely.
        let platformLimit: Int
        let memoryPerWorker: UInt64
        let reservedProcessors: Int
        switch platform {
        case .mobile:
            platformLimit = 6
            memoryPerWorker = gib
            reservedProcessors = 1
        case .desktop:
            platformLimit = 8
            memoryPerWorker = 2 * gib
            reservedProcessors = 2
        case .television:
            platformLimit = 4
            memoryPerWorker = gib
            reservedProcessors = 1
        }
        let processors = max(1, activeProcessorCount - reservedProcessors)
        let memory = max(1, Int(clamping: physicalMemory / memoryPerWorker))
        // Remote reads also compete for one source's connection/rate budget.
        // 走 URLSession 连接池的源(WebDAV / NAS File Station / S3)例外: 每主机
        // 备了 8 条 keep-alive 连接, 而标签读取绝大部分时间在等网络, 4 个位留了
        // 太多空连接。给标签读取开了专用会话的 SMB/FTP/SFTP/NFS 同样适用; 云盘不走
        // 这条, 见 `MusicSourceType.supportsParallelMetadataRangeReads`。
        let remoteLimit = pooledHTTPRemoteSource ? 6 : 4
        return min(platformLimit, processors, memory, offlineSource ? platformLimit : remoteLimit)
    }
}

public struct MetadataReadingEnvironment: Sendable {
    public var thermalState: MetadataReadingThermalState
    public var lowPowerMode: Bool
    public var playbackActive: Bool
    public var offlineSource: Bool
    /// 这一轮要读的源**全部**走 URLSession 连接池。只要混进一个 SMB 之类的
    /// 单会话源就不成立 —— 多开的读取位会一起堵在那条串行会话上。
    public var pooledHTTPRemoteSource: Bool
    public var device: MetadataReadingDeviceProfile

    public init(
        thermalState: MetadataReadingThermalState = .nominal,
        lowPowerMode: Bool = false,
        playbackActive: Bool = false,
        offlineSource: Bool = false,
        pooledHTTPRemoteSource: Bool = false,
        device: MetadataReadingDeviceProfile = .baseline
    ) {
        self.thermalState = thermalState
        self.lowPowerMode = lowPowerMode
        self.playbackActive = playbackActive
        self.offlineSource = offlineSource
        self.pooledHTTPRemoteSource = pooledHTTPRemoteSource
        self.device = device
    }

    public static func current(
        playbackActive: Bool,
        offlineSource: Bool,
        pooledHTTPRemoteSource: Bool = false
    ) -> Self {
        let thermal: MetadataReadingThermalState = switch ProcessInfo.processInfo.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .serious
        }
        #if os(iOS) || os(macOS)
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        #else
        let lowPower = false
        #endif
        return Self(thermalState: thermal, lowPowerMode: lowPower,
                    playbackActive: playbackActive, offlineSource: offlineSource,
                    pooledHTTPRemoteSource: pooledHTTPRemoteSource, device: .current)
    }
}
