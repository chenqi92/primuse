import Testing
@testable import PrimuseKit

@Suite("Interface orientation lock policy")
struct InterfaceOrientationLockPolicyTests {
    @Test func storedValueFallsBackToAutomatic() {
        #expect(InterfaceOrientationPreference(storedValue: nil) == .automatic)
        #expect(InterfaceOrientationPreference(storedValue: "") == .automatic)
        #expect(InterfaceOrientationPreference(storedValue: "sideways") == .automatic)
        #expect(InterfaceOrientationPreference(storedValue: "landscape") == .landscape)
        #expect(InterfaceOrientationPreference(storedValue: "portrait") == .portrait)
    }

    @Test func preferenceAppliesWhenNothingElseHoldsTheOrientation() {
        #expect(InterfaceOrientationLockPolicy.allowance(content: nil, player: nil, preference: .automatic) == .any)
        #expect(InterfaceOrientationLockPolicy.allowance(content: nil, player: nil, preference: .portrait) == .portrait)
        #expect(InterfaceOrientationLockPolicy.allowance(content: nil, player: nil, preference: .landscape) == .landscape)
    }

    @Test func playerToggleOverridesTheFixedPreferenceWhileOpen() {
        #expect(
            InterfaceOrientationLockPolicy.allowance(content: nil, player: .portrait, preference: .landscape)
                == .portrait
        )
        #expect(
            InterfaceOrientationLockPolicy.allowance(content: nil, player: .landscape, preference: .portrait)
                == .landscape
        )
    }

    @Test func fullScreenVideoOverridesEverything() {
        #expect(
            InterfaceOrientationLockPolicy.allowance(content: .landscape, player: .portrait, preference: .portrait)
                == .landscape
        )
    }

    @Test func followingTheDeviceOnlyCountsWhenTheOrientationIsNotFixed() {
        #expect(InterfaceOrientationLockPolicy.followsDevice(true, preference: .automatic))
        #expect(!InterfaceOrientationLockPolicy.followsDevice(false, preference: .automatic))
        #expect(!InterfaceOrientationLockPolicy.followsDevice(true, preference: .landscape))
        #expect(!InterfaceOrientationLockPolicy.followsDevice(true, preference: .portrait))
    }
}
