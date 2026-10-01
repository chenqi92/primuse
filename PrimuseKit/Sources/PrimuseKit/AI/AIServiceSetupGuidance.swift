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
