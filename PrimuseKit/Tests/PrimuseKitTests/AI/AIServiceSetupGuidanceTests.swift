import Foundation
import Testing
@testable import PrimuseKit

struct AIServiceSetupGuidanceTests {
    private let primary = UUID()
    private let backup = UUID()

    @Test func providerStateFollowsSwitchKeyThenModel() {
        #expect(AIProviderSetupState(isEnabled: false, hasAPIKey: true, generationModel: "m") == .disabled)
        #expect(AIProviderSetupState(isEnabled: true, hasAPIKey: false, generationModel: "m") == .needsAPIKey)
        #expect(AIProviderSetupState(isEnabled: true, hasAPIKey: true, generationModel: "  ") == .needsModel)
        #expect(AIProviderSetupState(isEnabled: true, hasAPIKey: true, generationModel: "gpt") == .ready)
    }

    @Test func relayOnWithoutOwnServiceNeedsNoGuidance() {
        let guidance = AIServiceSetupGuidance.resolve(
            relayEnabled: true,
            relaySupportedOnDevice: true,
            primaryProviderID: primary,
            providers: [AIProviderSetupSummary(id: primary, state: .needsAPIKey)]
        )
        #expect(guidance == .none)
    }

    @Test func relayOnWithReadyServiceExplainsPriority() {
        let guidance = AIServiceSetupGuidance.resolve(
            relayEnabled: true,
            relaySupportedOnDevice: true,
            primaryProviderID: primary,
            providers: [
                AIProviderSetupSummary(id: primary, state: .needsAPIKey),
                AIProviderSetupSummary(id: backup, state: .ready),
            ]
        )
        #expect(guidance == .relayTakesPriority)
    }

    @Test func relayOffWithoutReadyServicePointsAtPrimary() {
        let guidance = AIServiceSetupGuidance.resolve(
            relayEnabled: false,
            relaySupportedOnDevice: true,
            primaryProviderID: primary,
            providers: [
                AIProviderSetupSummary(id: backup, state: .needsModel),
                AIProviderSetupSummary(id: primary, state: .needsAPIKey),
            ]
        )
        #expect(guidance == .configureOwnService(providerID: primary))
    }

    @Test func disabledPrimaryFallsBackToFirstEnabledService() {
        let guidance = AIServiceSetupGuidance.resolve(
            relayEnabled: false,
            relaySupportedOnDevice: true,
            primaryProviderID: primary,
            providers: [
                AIProviderSetupSummary(id: primary, state: .disabled),
                AIProviderSetupSummary(id: backup, state: .needsAPIKey),
            ]
        )
        #expect(guidance == .configureOwnService(providerID: backup))
    }

    @Test func allServicesDisabledStillPointsAtPrimary() {
        let guidance = AIServiceSetupGuidance.resolve(
            relayEnabled: false,
            relaySupportedOnDevice: true,
            primaryProviderID: primary,
            providers: [
                AIProviderSetupSummary(id: backup, state: .disabled),
                AIProviderSetupSummary(id: primary, state: .disabled),
            ]
        )
        #expect(guidance == .configureOwnService(providerID: primary))
    }

    @Test func relayUnsupportedOnDeviceCountsAsOff() {
        let guidance = AIServiceSetupGuidance.resolve(
            relayEnabled: true,
            relaySupportedOnDevice: false,
            primaryProviderID: primary,
            providers: [AIProviderSetupSummary(id: primary, state: .needsAPIKey)]
        )
        #expect(guidance == .configureOwnService(providerID: primary))
    }

    @Test func relayOffWithReadyServiceNeedsNoGuidance() {
        let guidance = AIServiceSetupGuidance.resolve(
            relayEnabled: false,
            relaySupportedOnDevice: true,
            primaryProviderID: primary,
            providers: [
                AIProviderSetupSummary(id: primary, state: .needsAPIKey),
                AIProviderSetupSummary(id: backup, state: .ready),
            ]
        )
        #expect(guidance == .none)
    }

    @Test func emptyProviderListNeedsNoGuidance() {
        let guidance = AIServiceSetupGuidance.resolve(
            relayEnabled: false,
            relaySupportedOnDevice: true,
            primaryProviderID: primary,
            providers: []
        )
        #expect(guidance == .none)
    }

    @Test func activeEngineIsBuiltInWheneverRelayIsUsable() {
        let engine = AIActiveEngine.resolve(
            relayEnabled: true,
            relaySupportedOnDevice: true,
            primaryProviderID: primary,
            providers: [AIProviderSetupSummary(id: primary, state: .ready)],
            hasOfflinePacks: true
        )
        #expect(engine == .builtIn)
    }

    @Test func activeEnginePrefersReadyPrimaryThenFirstReadyService() {
        let primaryReady = AIActiveEngine.resolve(
            relayEnabled: true,
            relaySupportedOnDevice: false,
            primaryProviderID: primary,
            providers: [
                AIProviderSetupSummary(id: backup, state: .ready),
                AIProviderSetupSummary(id: primary, state: .ready),
            ],
            hasOfflinePacks: false
        )
        #expect(primaryReady == .ownService(providerID: primary))

        let backupOnly = AIActiveEngine.resolve(
            relayEnabled: false,
            relaySupportedOnDevice: true,
            primaryProviderID: primary,
            providers: [
                AIProviderSetupSummary(id: primary, state: .needsModel),
                AIProviderSetupSummary(id: backup, state: .ready),
            ],
            hasOfflinePacks: true
        )
        #expect(backupOnly == .ownService(providerID: backup))
    }

    @Test func activeEngineFallsBackToOfflinePacksThenNone() {
        let providers = [AIProviderSetupSummary(id: primary, state: .needsAPIKey)]
        let offline = AIActiveEngine.resolve(
            relayEnabled: false,
            relaySupportedOnDevice: true,
            primaryProviderID: primary,
            providers: providers,
            hasOfflinePacks: true
        )
        #expect(offline == .offlinePacks)
        let nothing = AIActiveEngine.resolve(
            relayEnabled: false,
            relaySupportedOnDevice: true,
            primaryProviderID: primary,
            providers: providers,
            hasOfflinePacks: false
        )
        #expect(nothing == .none)
    }

    @Test func homeHintShowsOnceForLargeLibrariesWithoutBuiltInAI() {
        func show(
            dismissed: Bool = false,
            exposes: Bool = true,
            supported: Bool = true,
            relay: Bool = false,
            available: Bool = false,
            count: Int = 200
        ) -> Bool {
            AIHomeHintPolicy.shouldShow(
                dismissed: dismissed,
                exposesRemoteConfiguration: exposes,
                relaySupportedOnDevice: supported,
                relayEnabled: relay,
                recommendationsAvailable: available,
                musicSongCount: count
            )
        }
        #expect(show())
        #expect(!show(count: 199))
        #expect(!show(dismissed: true))
        #expect(!show(exposes: false))
        #expect(!show(supported: false))
        #expect(!show(relay: true))
        #expect(!show(available: true))
    }
}
