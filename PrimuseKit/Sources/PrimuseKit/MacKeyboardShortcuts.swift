import Foundation

public struct MacKeyboardShortcut: Codable, Equatable, Hashable, Sendable {
    public static let commandModifier = 1 << 0
    public static let optionModifier = 1 << 1
    public static let controlModifier = 1 << 2
    public static let shiftModifier = 1 << 3

    public let keyCode: UInt16
    public let modifiers: Int
    public let keyEquivalent: String?

    public init(keyCode: UInt16, modifiers: Int = 0, keyEquivalent: String? = nil) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyEquivalent = keyEquivalent?.lowercased()
    }

    public var hasShortcutModifier: Bool {
        modifiers & Self.shortcutModifierMask != 0
    }

    public static let shortcutModifierMask = commandModifier
        | optionModifier
        | controlModifier
        | shiftModifier
}

public enum MacKeyboardShortcutAction: String, Codable, CaseIterable, Sendable {
    case playPause
    case nextTrack
    case previousTrack
    case shuffle
    case repeatMode
    case volumeUp
    case volumeDown
    case focusSearch
    case showMiniPlayer
    case showDesktopLyrics
    case toggleDesktopLyricsLock

    public var defaultShortcut: MacKeyboardShortcut {
        switch self {
        case .playPause:
            return MacKeyboardShortcut(keyCode: 49, keyEquivalent: " ")
        case .nextTrack:
            return MacKeyboardShortcut(
                keyCode: 124,
                modifiers: MacKeyboardShortcut.commandModifier,
                keyEquivalent: "\u{F703}"
            )
        case .previousTrack:
            return MacKeyboardShortcut(
                keyCode: 123,
                modifiers: MacKeyboardShortcut.commandModifier,
                keyEquivalent: "\u{F702}"
            )
        case .shuffle:
            return MacKeyboardShortcut(
                keyCode: 1,
                modifiers: MacKeyboardShortcut.commandModifier | MacKeyboardShortcut.shiftModifier,
                keyEquivalent: "s"
            )
        case .repeatMode:
            return MacKeyboardShortcut(
                keyCode: 15,
                modifiers: MacKeyboardShortcut.commandModifier | MacKeyboardShortcut.shiftModifier,
                keyEquivalent: "r"
            )
        case .volumeUp:
            return MacKeyboardShortcut(
                keyCode: 126,
                modifiers: MacKeyboardShortcut.commandModifier,
                keyEquivalent: "\u{F700}"
            )
        case .volumeDown:
            return MacKeyboardShortcut(
                keyCode: 125,
                modifiers: MacKeyboardShortcut.commandModifier,
                keyEquivalent: "\u{F701}"
            )
        case .focusSearch:
            return MacKeyboardShortcut(
                keyCode: 3,
                modifiers: MacKeyboardShortcut.commandModifier,
                keyEquivalent: "f"
            )
        case .showMiniPlayer:
            return MacKeyboardShortcut(
                keyCode: 46,
                modifiers: MacKeyboardShortcut.commandModifier | MacKeyboardShortcut.shiftModifier,
                keyEquivalent: "m"
            )
        case .showDesktopLyrics:
            return MacKeyboardShortcut(
                keyCode: 37,
                modifiers: MacKeyboardShortcut.commandModifier,
                keyEquivalent: "l"
            )
        case .toggleDesktopLyricsLock:
            return MacKeyboardShortcut(
                keyCode: 37,
                modifiers: MacKeyboardShortcut.commandModifier | MacKeyboardShortcut.shiftModifier,
                keyEquivalent: "l"
            )
        }
    }
}

public enum MacKeyboardShortcutValidation: Equatable, Sendable {
    case accepted
    case reserved
    case modifierRequired
}

public enum MacKeyboardShortcutPolicy {
    public static let storageKey = "primuse.mac.keyboardShortcuts.v1"

    private static let modifierOnlyKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
    private static let reservedKeyCodes: Set<UInt16> = [53, 71]
    private static let safeBareKeyCodes: Set<UInt16> = [
        49,
        64, 79, 80, 90, 96, 97, 98, 99, 100, 101, 103, 105, 106, 107,
        109, 111, 113, 118, 120, 122,
    ]
    private static let reservedShortcuts: [MacKeyboardShortcut] = [
        MacKeyboardShortcut(keyCode: 12, modifiers: MacKeyboardShortcut.commandModifier, keyEquivalent: "q"),
        MacKeyboardShortcut(keyCode: 4, modifiers: MacKeyboardShortcut.commandModifier, keyEquivalent: "h"),
        MacKeyboardShortcut(keyCode: 46, modifiers: MacKeyboardShortcut.commandModifier, keyEquivalent: "m"),
        MacKeyboardShortcut(keyCode: 13, modifiers: MacKeyboardShortcut.commandModifier, keyEquivalent: "w"),
        MacKeyboardShortcut(keyCode: 43, modifiers: MacKeyboardShortcut.commandModifier, keyEquivalent: ","),
        MacKeyboardShortcut(keyCode: 48, modifiers: MacKeyboardShortcut.commandModifier, keyEquivalent: "\t"),
        MacKeyboardShortcut(keyCode: 49, modifiers: MacKeyboardShortcut.commandModifier, keyEquivalent: " "),
        MacKeyboardShortcut(
            keyCode: 3,
            modifiers: MacKeyboardShortcut.commandModifier | MacKeyboardShortcut.controlModifier,
            keyEquivalent: "f"
        ),
    ]

    private struct StoragePayload: Codable {
        let version: Int
        let bindings: [StoredBinding]
    }

    private struct StoredBinding: Codable {
        let action: String
        let shortcut: MacKeyboardShortcut?
    }

    public static var defaults: [MacKeyboardShortcutAction: MacKeyboardShortcut] {
        Dictionary(uniqueKeysWithValues: MacKeyboardShortcutAction.allCases.map {
            ($0, $0.defaultShortcut)
        })
    }

    public static func validate(_ shortcut: MacKeyboardShortcut) -> MacKeyboardShortcutValidation {
        if modifierOnlyKeyCodes.contains(shortcut.keyCode)
            || reservedKeyCodes.contains(shortcut.keyCode)
            || reservedShortcuts.contains(where: { shortcutsMatch($0, shortcut) }) {
            return .reserved
        }
        if !shortcut.hasShortcutModifier && !safeBareKeyCodes.contains(shortcut.keyCode) {
            return .modifierRequired
        }
        return .accepted
    }

    public static func action(
        matching shortcut: MacKeyboardShortcut,
        in shortcuts: [MacKeyboardShortcutAction: MacKeyboardShortcut]
    ) -> MacKeyboardShortcutAction? {
        MacKeyboardShortcutAction.allCases.first {
            shortcuts[$0].map { shortcutsMatch($0, shortcut) } == true
        }
    }

    public static func conflictingAction(
        for shortcut: MacKeyboardShortcut,
        excluding action: MacKeyboardShortcutAction,
        in shortcuts: [MacKeyboardShortcutAction: MacKeyboardShortcut]
    ) -> MacKeyboardShortcutAction? {
        MacKeyboardShortcutAction.allCases.first {
            $0 != action && shortcuts[$0].map { shortcutsMatch($0, shortcut) } == true
        }
    }

    public static func shortcutsMatch(
        _ lhs: MacKeyboardShortcut,
        _ rhs: MacKeyboardShortcut
    ) -> Bool {
        guard lhs.modifiers == rhs.modifiers else { return false }
        if let lhsKey = lhs.keyEquivalent, !lhsKey.isEmpty,
           let rhsKey = rhs.keyEquivalent, !rhsKey.isEmpty {
            return lhsKey.lowercased() == rhsKey.lowercased()
        }
        return lhs.keyCode == rhs.keyCode
    }

    public static func assigning(
        _ shortcut: MacKeyboardShortcut,
        to action: MacKeyboardShortcutAction,
        in shortcuts: [MacKeyboardShortcutAction: MacKeyboardShortcut]
    ) -> [MacKeyboardShortcutAction: MacKeyboardShortcut] {
        var result = shortcuts
        if let conflict = conflictingAction(
            for: shortcut,
            excluding: action,
            in: shortcuts
        ) {
            result.removeValue(forKey: conflict)
        }
        result[action] = shortcut
        return result
    }

    public static func encode(
        _ shortcuts: [MacKeyboardShortcutAction: MacKeyboardShortcut]
    ) -> Data? {
        let payload = StoragePayload(
            version: 1,
            bindings: MacKeyboardShortcutAction.allCases.map {
                StoredBinding(action: $0.rawValue, shortcut: shortcuts[$0])
            }
        )
        return try? JSONEncoder().encode(payload)
    }

    public static func decode(_ data: Data?) -> [MacKeyboardShortcutAction: MacKeyboardShortcut] {
        guard let data else { return defaults }
        let decoder = JSONDecoder()

        if let payload = try? decoder.decode(StoragePayload.self, from: data) {
            var result: [MacKeyboardShortcutAction: MacKeyboardShortcut] = [:]
            let storedActions = Set(payload.bindings.map(\.action))
            for action in MacKeyboardShortcutAction.allCases {
                guard storedActions.contains(action.rawValue) else {
                    result = assigning(action.defaultShortcut, to: action, in: result)
                    continue
                }
                guard let shortcut = payload.bindings.first(where: {
                    $0.action == action.rawValue
                })?.shortcut,
                      validate(shortcut) == .accepted else { continue }
                result = assigning(shortcut, to: action, in: result)
            }
            return result
        }

        // Migrate the initial dictionary-only format used by development builds.
        guard let raw = try? decoder.decode([String: MacKeyboardShortcut].self, from: data) else {
            return defaults
        }
        var result = defaults
        for action in MacKeyboardShortcutAction.allCases {
            guard let shortcut = raw[action.rawValue],
                  validate(shortcut) == .accepted else { continue }
            result = assigning(shortcut, to: action, in: result)
        }
        return result
    }

    public static func shouldHandleEvent(
        isEditingText: Bool,
        isEligibleWindow: Bool,
        isRecordingShortcut: Bool
    ) -> Bool {
        !isEditingText && isEligibleWindow && !isRecordingShortcut
    }

    public static func shouldPerform(
        action: MacKeyboardShortcutAction,
        isRepeat: Bool
    ) -> Bool {
        !isRepeat || action == .volumeUp || action == .volumeDown
    }
}

/// Keeps the title-bar search field from stealing the bare-space playback
/// shortcut after navigation leaves Search.
public enum MacTitleBarSearchPolicy {
    public static func shouldActivateSearch(for query: String, isOnSearch: Bool) -> Bool {
        !isOnSearch && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public static func shouldReleaseFocus(isOnSearch: Bool) -> Bool {
        !isOnSearch
    }

    public static func queryAfterReleasingFocus(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : query
    }
}
