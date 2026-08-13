import Testing
@testable import PrimuseKit

@Suite("Mac playback spacebar")
struct MacPlaybackSpacebarPolicyTests {
    @Test("Bare space toggles playback in a playback window")
    func bareSpaceTogglesPlayback() {
        #expect(shouldToggle())
    }

    @Test("Text editing keeps the space keystroke")
    func textEditingKeepsSpace() {
        #expect(!shouldToggle(isEditingText: true))
    }

    @Test("Modified, repeated, and unrelated key events are ignored")
    func rejectsOtherKeyEvents() {
        #expect(!shouldToggle(hasDisallowedModifiers: true))
        #expect(!shouldToggle(isRepeat: true))
        #expect(!shouldToggle(keyCode: 36))
        #expect(!shouldToggle(isPlaybackWindow: false))
    }

    private func shouldToggle(
        keyCode: UInt16 = MacPlaybackSpacebarPolicy.spaceKeyCode,
        hasDisallowedModifiers: Bool = false,
        isRepeat: Bool = false,
        isEditingText: Bool = false,
        isPlaybackWindow: Bool = true
    ) -> Bool {
        MacPlaybackSpacebarPolicy.shouldTogglePlayback(
            keyCode: keyCode,
            hasDisallowedModifiers: hasDisallowedModifiers,
            isRepeat: isRepeat,
            isEditingText: isEditingText,
            isPlaybackWindow: isPlaybackWindow
        )
    }
}
