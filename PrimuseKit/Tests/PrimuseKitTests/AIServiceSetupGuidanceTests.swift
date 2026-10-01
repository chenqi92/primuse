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
}
