/// Keeps the macOS bare-space playback shortcut from stealing keystrokes from
/// text editors, modified shortcuts, sheets, or unrelated app windows.
public enum MacPlaybackSpacebarPolicy {
    /// AppKit's hardware-independent virtual key code for the space bar.
    public static let spaceKeyCode: UInt16 = 49

    public static func shouldTogglePlayback(
        keyCode: UInt16,
        hasDisallowedModifiers: Bool,
        isRepeat: Bool,
        isEditingText: Bool,
        isPlaybackWindow: Bool
    ) -> Bool {
        keyCode == spaceKeyCode
            && !hasDisallowedModifiers
            && !isRepeat
            && !isEditingText
            && isPlaybackWindow
    }
}
