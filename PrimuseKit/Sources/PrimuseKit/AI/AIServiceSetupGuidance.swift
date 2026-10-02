import Foundation

/// 「我的 AI 服务」里一项服务配到了哪一步。
///
/// 开关打开不等于能用:还要有 API 密钥和生成模型。列表行和设置页的引导都按这里
/// 判断,用户一眼就能看出卡在哪一步,而不是打开开关后功能静悄悄地不工作。
public enum AIProviderSetupState: Equatable, Sendable {
    case disabled
    case needsAPIKey
    case needsModel
    case ready

    public init(isEnabled: Bool, hasAPIKey: Bool, generationModel: String) {
        if !isEnabled {
            self = .disabled
        } else if !hasAPIKey {
            self = .needsAPIKey
        } else if generationModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self = .needsModel
        } else {
            self = .ready
        }
    }
}

public struct AIProviderSetupSummary: Equatable, Sendable {
    public var id: UUID
    public var state: AIProviderSetupState

    public init(id: UUID, state: AIProviderSetupState) {
        self.id = id
        self.state = state
    }
}

/// 智能功能设置页在「内置 AI」开关下方要不要给一句引导。
public enum AIServiceSetupGuidance: Equatable, Sendable {
    case none
    /// 内置 AI 关着(或这台设备用不了),自己的服务里又没有一个配好的:
    /// 带用户去把这一项服务的密钥填上。
    case configureOwnService(providerID: UUID)
    /// 自己的服务已经配好,但内置 AI 开着时总是先走内置 AI,自己的服务只做备用。
    case relayTakesPriority

    public static func resolve(
        relayEnabled: Bool,
        relaySupportedOnDevice: Bool,
        primaryProviderID: UUID,
        providers: [AIProviderSetupSummary]
    ) -> AIServiceSetupGuidance {
        guard !providers.isEmpty else { return .none }
        let hasReadyProvider = providers.contains { $0.state == .ready }
        let relayActive = relayEnabled && relaySupportedOnDevice
        if relayActive {
            return hasReadyProvider ? .relayTakesPriority : .none
        }
        guard !hasReadyProvider else { return .none }
        return .configureOwnService(
            providerID: setupTarget(primaryProviderID: primaryProviderID, providers: providers)
        )
    }

    /// 先看主服务;主服务被停用时找第一项已启用的,全都停用就还是主服务
    /// (详情页里能直接把它重新启用)。
    private static func setupTarget(
        primaryProviderID: UUID,
        providers: [AIProviderSetupSummary]
    ) -> UUID {
        if let primary = providers.first(where: { $0.id == primaryProviderID }),
           primary.state != .disabled {
            return primary.id
        }
        if let enabled = providers.first(where: { $0.state != .disabled }) {
            return enabled.id
        }
        return providers.contains { $0.id == primaryProviderID }
            ? primaryProviderID
            : providers[0].id
    }
}

/// 智能功能此刻由谁来做。设置页第一段的状态行照这个写:内置 AI、自己填的服务、
/// 只有下载到本机的离线翻译素材包,或者都没有。
public enum AIActiveEngine: Equatable, Sendable {
    case builtIn
    /// 内置 AI 关着(或这台设备用不了)时,第一项配好的自己的服务;先看主服务。
    case ownService(providerID: UUID)
    /// 没有可用的在线服务,只有离线翻译素材包(只管歌词翻译)。
    case offlinePacks
    case none

    public static func resolve(
        relayEnabled: Bool,
        relaySupportedOnDevice: Bool,
        primaryProviderID: UUID,
        providers: [AIProviderSetupSummary],
        hasOfflinePacks: Bool
    ) -> AIActiveEngine {
        if relayEnabled, relaySupportedOnDevice { return .builtIn }
        let ready = providers.filter { $0.state == .ready }
        if let primary = ready.first(where: { $0.id == primaryProviderID }) {
            return .ownService(providerID: primary.id)
        }
        if let first = ready.first { return .ownService(providerID: first.id) }
        return hasOfflinePacks ? .offlinePacks : .none
    }
}

/// 首页「为你推荐」下方那张开启智能推荐的指引卡:曲库有一定规模、内置 AI 还没开、
/// 推荐也还不能用时出现一次;关掉或点过之后不再出现。
public enum AIHomeHintPolicy {
    public static let dismissedKey = "primuse.home.aiHintDismissed"
    /// 曲库太小时按心情、场景重排没什么可排的。
    public static let minimumMusicSongCount = 200

    public static func shouldShow(
        dismissed: Bool,
        exposesRemoteConfiguration: Bool,
        relaySupportedOnDevice: Bool,
        relayEnabled: Bool,
        recommendationsAvailable: Bool,
        musicSongCount: Int
    ) -> Bool {
        !dismissed
            && exposesRemoteConfiguration
            && relaySupportedOnDevice
            && !relayEnabled
            && !recommendationsAvailable
            && musicSongCount >= minimumMusicSongCount
    }
}
