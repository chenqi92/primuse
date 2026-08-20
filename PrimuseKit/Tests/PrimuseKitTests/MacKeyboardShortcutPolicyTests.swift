import Foundation
import Testing
@testable import PrimuseKit

@Suite("Mac keyboard shortcuts")
struct MacKeyboardShortcutPolicyTests {
    @Test("Defaults provide one unique shortcut per action")
    func defaultsAreUnique() {
        let shortcuts = MacKeyboardShortcutPolicy.defaults
        #expect(shortcuts.count == MacKeyboardShortcutAction.allCases.count)
        #expect(Set(shortcuts.values).count == shortcuts.count)
        #expect(MacKeyboardShortcutPolicy.shortcutsMatch(
            shortcuts[.playPause]!,
            MacKeyboardShortcut(keyCode: 49, keyEquivalent: " ")
        ))
    }

    @Test("Bare typing keys require a modifier")
    func protectsTypingKeys() {
        #expect(MacKeyboardShortcutPolicy.validate(
            MacKeyboardShortcut(keyCode: 0)
        ) == .modifierRequired)
        #expect(MacKeyboardShortcutPolicy.validate(
            MacKeyboardShortcut(keyCode: 49)
        ) == .accepted)
        #expect(MacKeyboardShortcutPolicy.validate(
            MacKeyboardShortcut(keyCode: 0, modifiers: MacKeyboardShortcut.commandModifier)
        ) == .accepted)
    }

    @Test("Reserved and modifier-only keys are rejected")
    func rejectsReservedKeys() {
        #expect(MacKeyboardShortcutPolicy.validate(
            MacKeyboardShortcut(keyCode: 53)
        ) == .reserved)
        #expect(MacKeyboardShortcutPolicy.validate(
            MacKeyboardShortcut(keyCode: 55)
        ) == .reserved)
        #expect(MacKeyboardShortcutPolicy.validate(
            MacKeyboardShortcut(keyCode: 12, modifiers: MacKeyboardShortcut.commandModifier)
        ) == .reserved)
    }

    @Test("Assigning a duplicate removes the old binding")
    func assignmentResolvesConflict() {
        let target = MacKeyboardShortcut(keyCode: 49)
        let updated = MacKeyboardShortcutPolicy.assigning(
            target,
            to: .nextTrack,
            in: MacKeyboardShortcutPolicy.defaults
        )
        #expect(updated[.nextTrack] == target)
        #expect(updated[.playPause] == nil)
    }

    @Test("Semantic keys match across keyboard layouts")
    func semanticKeyMatching() {
        let defaultMiniPlayer = MacKeyboardShortcutAction.showMiniPlayer.defaultShortcut
        let alternatePhysicalM = MacKeyboardShortcut(
            keyCode: 41,
            modifiers: MacKeyboardShortcut.commandModifier | MacKeyboardShortcut.shiftModifier,
            keyEquivalent: "M"
        )
        #expect(MacKeyboardShortcutPolicy.shortcutsMatch(defaultMiniPlayer, alternatePhysicalM))
    }

    @Test("Storage round trip keeps custom values and cleared actions")
    func storageRoundTrip() throws {
        var shortcuts = MacKeyboardShortcutPolicy.defaults
        shortcuts[.playPause] = MacKeyboardShortcut(
            keyCode: 35,
            modifiers: MacKeyboardShortcut.commandModifier
        )
        let data = try #require(MacKeyboardShortcutPolicy.encode(shortcuts))
        #expect(MacKeyboardShortcutPolicy.decode(data) == shortcuts)

        shortcuts.removeValue(forKey: .playPause)
        let cleared = try #require(MacKeyboardShortcutPolicy.encode(shortcuts))
        #expect(MacKeyboardShortcutPolicy.decode(cleared)[.playPause] == nil)
    }

    @Test("Development dictionary storage migrates without losing defaults")
    func migratesLegacyStorage() throws {
        let custom = MacKeyboardShortcut(
            keyCode: 35,
            modifiers: MacKeyboardShortcut.commandModifier,
            keyEquivalent: "p"
        )
        let data = try JSONEncoder().encode(["playPause": custom])
        let decoded = MacKeyboardShortcutPolicy.decode(data)
        #expect(decoded[.playPause] == custom)
        #expect(decoded[.nextTrack] == MacKeyboardShortcutAction.nextTrack.defaultShortcut)
    }

    @Test("Text editing, recording, and unrelated windows bypass dispatch")
    func eventDispatchGate() {
        #expect(MacKeyboardShortcutPolicy.shouldHandleEvent(
            isEditingText: false,
            isEligibleWindow: true,
            isRecordingShortcut: false
        ))
        #expect(!MacKeyboardShortcutPolicy.shouldHandleEvent(
            isEditingText: true,
            isEligibleWindow: true,
            isRecordingShortcut: false
        ))
        #expect(!MacKeyboardShortcutPolicy.shouldHandleEvent(
            isEditingText: false,
            isEligibleWindow: true,
            isRecordingShortcut: true
        ))
        #expect(!MacKeyboardShortcutPolicy.shouldHandleEvent(
            isEditingText: false,
            isEligibleWindow: false,
            isRecordingShortcut: false
        ))
    }

    @Test("Key repeat is consumed once, except for continuous volume changes")
    func repeatBehavior() {
        #expect(!MacKeyboardShortcutPolicy.shouldPerform(action: .playPause, isRepeat: true))
        #expect(!MacKeyboardShortcutPolicy.shouldPerform(action: .nextTrack, isRepeat: true))
        #expect(MacKeyboardShortcutPolicy.shouldPerform(action: .volumeUp, isRepeat: true))
        #expect(MacKeyboardShortcutPolicy.shouldPerform(action: .volumeDown, isRepeat: true))
        #expect(MacKeyboardShortcutPolicy.shouldPerform(action: .playPause, isRepeat: false))
    }

    @Test("Title-bar search ignores whitespace and releases focus outside Search")
    func titleBarSearchRouting() {
        #expect(!MacTitleBarSearchPolicy.shouldActivateSearch(for: " ", isOnSearch: false))
        #expect(!MacTitleBarSearchPolicy.shouldActivateSearch(for: "\n\t", isOnSearch: false))
        #expect(MacTitleBarSearchPolicy.shouldActivateSearch(for: " song ", isOnSearch: false))
        #expect(!MacTitleBarSearchPolicy.shouldActivateSearch(for: "song", isOnSearch: true))
        #expect(MacTitleBarSearchPolicy.shouldReleaseFocus(isOnSearch: false))
        #expect(!MacTitleBarSearchPolicy.shouldReleaseFocus(isOnSearch: true))
        #expect(MacTitleBarSearchPolicy.queryAfterReleasingFocus("  \n") == "")
        #expect(MacTitleBarSearchPolicy.queryAfterReleasingFocus(" song ") == " song ")
    }
}
