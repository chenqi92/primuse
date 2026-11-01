import Foundation
import PrimuseKit
#if canImport(FoundationModels) && !os(tvOS) && !os(watchOS)
import FoundationModels
#endif
#if os(macOS)
import Security
#endif

enum AppleIntelligenceError: Error, LocalizedError, Equatable {
    case unavailable, modelNotReady, permissionMissing, quotaReached, contextLimit, refused

    var errorDescription: String? {
        switch self {
        case .unavailable: String(localized: "ai_apple_unavailable")
        case .modelNotReady: String(localized: "ai_apple_not_ready")
        case .permissionMissing: String(localized: "ai_apple_permission_missing")
        case .quotaReached: String(localized: "ai_apple_quota_reached")
        case .contextLimit: String(localized: "ai_apple_context_limit")
        case .refused: String(localized: "ai_apple_refused")
        }
    }
}

struct AppleIntelligenceQuotaFailure: Error, LocalizedError {
    let resetDate: Date?
    var errorDescription: String? { AppleIntelligenceError.quotaReached.errorDescription }
}

/// Keeps system inference separate from HTTP and credential storage, including
/// when callers reuse the same prompts and response validation.
struct AppleIntelligenceClient: Sendable {
    var availability: @Sendable (AIProviderBackend) async -> AIProviderRuntimeAvailability
    var generate: @Sendable (AIProviderBackend, String, String, Int) async throws -> String

    static let live = Self(
        availability: { AppleIntelligenceRuntime.availability(for: $0) },
        generate: { try await AppleIntelligenceRuntime.generate(backend: $0, instructions: $1, input: $2, maximumTokens: $3) }
    )
}

enum AppleIntelligenceRuntime {
    static func supportsOnCurrentPlatform(_ backend: AIProviderBackend) -> Bool {
        #if os(tvOS) || os(watchOS)
        return backend == .remote
        #else
        return true
        #endif
    }

    static func availability(for backend: AIProviderBackend) -> AIProviderRuntimeAvailability {
        #if canImport(FoundationModels) && !os(tvOS) && !os(watchOS)
        switch backend {
        case .appleOnDevice:
            if #available(iOS 26, macOS 26, visionOS 26, *) {
                switch SystemLanguageModel.default.availability {
                case .available: return .available
                case .unavailable(.modelNotReady): return .unavailable(.modelNotReady)
                default: return .unavailable(.unsupportedDevice)
                }
            }
        case .applePrivateCloudCompute:
            if #available(iOS 27, macOS 27, visionOS 27, *) {
                guard hasPCCEntitlement else { return .unavailable(.missingConfiguration) }
                let model = PrivateCloudComputeLanguageModel()
                switch model.availability {
                case .available: return .available
                case .unavailable(.systemNotReady): return .unavailable(.modelNotReady)
                default: return .unavailable(.unsupportedDevice)
                }
            }
        case .remote: break
        }
        #endif
        return .unavailable(.unsupportedDevice)
    }

    private static var hasPCCEntitlement: Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(task, "com.apple.developer.private-cloud-compute" as CFString, nil) as? Bool == true
        #else
        // iOS installation validates the managed entitlement in the signed
        // provisioning profile. SecTask is not a public iOS API.
        return true
        #endif
    }

    static func generate(backend: AIProviderBackend, instructions: String, input: String,
                         maximumTokens: Int) async throws -> String {
        try Task.checkCancellation()
        switch availability(for: backend) {
        case .available: break
        case .unavailable(.modelNotReady): throw AppleIntelligenceError.modelNotReady
        case .unavailable(.missingConfiguration): throw AppleIntelligenceError.permissionMissing
        default: throw AppleIntelligenceError.unavailable
        }
        #if canImport(FoundationModels) && !os(tvOS) && !os(watchOS)
        if #available(iOS 26, macOS 26, visionOS 26, *) {
            let session: LanguageModelSession
            var responseTokens = min(maximumTokens, 4_000)
            if backend == .applePrivateCloudCompute {
                if #available(iOS 27, macOS 27, visionOS 27, *) {
                    let model = PrivateCloudComputeLanguageModel()
                    guard !model.quotaUsage.isLimitReached else {
                        throw AppleIntelligenceQuotaFailure(resetDate: model.quotaUsage.resetDate)
                    }
                    session = LanguageModelSession(model: model, instructions: instructions)
                } else { throw AppleIntelligenceError.unavailable }
            } else {
                let model = SystemLanguageModel.default
                if #available(iOS 26.4, macOS 26.4, visionOS 26.4, *) {
                    let inputTokens = try await model.tokenCount(for: input)
                    let instructionTokens = try await model.tokenCount(for: Instructions(instructions))
                    let remaining = model.contextSize - inputTokens - instructionTokens - 256
                    guard remaining >= 512 else { throw AppleIntelligenceError.contextLimit }
                    responseTokens = min(responseTokens, remaining)
                } else {
                    responseTokens = min(responseTokens, 1_024)
                }
                session = LanguageModelSession(model: model, instructions: instructions)
            }
            do {
                let response = try await session.respond(
                    to: input,
                    options: GenerationOptions(temperature: 0.2, maximumResponseTokens: responseTokens)
                )
                try Task.checkCancellation()
                return response.content
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                if #available(iOS 27, macOS 27, visionOS 27, *) {
                    if case PrivateCloudComputeLanguageModel.Error.quotaLimitReached(let detail) = error {
                        throw AppleIntelligenceQuotaFailure(resetDate: detail.resetDate)
                    }
                    if case LanguageModelError.contextSizeExceeded = error { throw AppleIntelligenceError.contextLimit }
                    if case LanguageModelError.guardrailViolation = error { throw AppleIntelligenceError.refused }
                    if case LanguageModelError.refusal = error { throw AppleIntelligenceError.refused }
                }
                if case LanguageModelSession.GenerationError.exceededContextWindowSize = error {
                    throw AppleIntelligenceError.contextLimit
                }
                if case LanguageModelSession.GenerationError.guardrailViolation = error {
                    throw AppleIntelligenceError.refused
                }
                throw error
            }
        }
        #endif
        throw AppleIntelligenceError.unavailable
    }
}
