import Foundation

public struct ImmersiveEffectInitialPresentation: Equatable, Sendable {
    public let dismissesPlayer: Bool
    public let showsEffectPicker: Bool
    public let startsPresentationWork: Bool

    public init(
        dismissesPlayer: Bool,
        showsEffectPicker: Bool,
        startsPresentationWork: Bool
    ) {
        self.dismissesPlayer = dismissesPlayer
        self.showsEffectPicker = showsEffectPicker
        self.startsPresentationWork = startsPresentationWork
    }
}

/// Keeps effect switching discoverable without turning entry into an extra
/// prompt. A saved immersive effect is honoured immediately — explicit and
/// automatic entry both continue directly with it, and the picker stays
/// reachable through the long press or the options screen. With native mode
/// saved there is nothing immersive to show, so an explicit entry opens the
/// picker instead of doing nothing; automatic entry still leaves native alone.
public enum ImmersiveEffectEntryPolicy {
    /// - Parameters:
    ///   - isUserInitiated: `true` for an explicit launch, `false` for the idle
    ///     auto-presentation.
    ///   - savedEffectIsNative: `true` when the persisted full-screen effect is
    ///     the native player, which has nothing to render immersively.
    public static func tvLaunchPresentsEffectPicker(
        isUserInitiated: Bool,
        savedEffectIsNative: Bool
    ) -> Bool {
        isUserInitiated && savedEffectIsNative
    }

    public static func initialPresentation(
        isNativeEffect: Bool,
        presentsEffectPicker: Bool
    ) -> ImmersiveEffectInitialPresentation {
        if isNativeEffect {
            return ImmersiveEffectInitialPresentation(
                dismissesPlayer: !presentsEffectPicker,
                showsEffectPicker: presentsEffectPicker,
                startsPresentationWork: false
            )
        }
        return ImmersiveEffectInitialPresentation(
            dismissesPlayer: false,
            showsEffectPicker: presentsEffectPicker,
            startsPresentationWork: true
        )
    }
}
