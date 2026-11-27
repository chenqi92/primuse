import Foundation

public enum ImmersiveControlsAction: Sendable {
    case present
    case contentTap
    case lock
    case unlock
    case autoHide
    case dismiss
}

/// Interaction state shared by distraction-free lyrics and locked player surfaces.
/// Locking hides the chrome and intercepts content gestures; tapping the surface
/// toggles only the unlock affordance so accidental playback changes stay
/// impossible until the user explicitly unlocks the surface.
public struct ImmersiveControlsState: Equatable, Sendable {
    public let isVisible: Bool
    public let isLocked: Bool

    public static let inactive = Self(isVisible: false, isLocked: false)
    public static let presented = Self(isVisible: true, isLocked: false)

    public var showsPrimaryControls: Bool {
        isVisible && !isLocked
    }

    public var showsUnlockControl: Bool {
        isVisible && isLocked
    }

    public func showsUnlockControl(keepingVisibleForAccessibility: Bool) -> Bool {
        isLocked && (isVisible || keepingVisibleForAccessibility)
    }

    public func applying(_ action: ImmersiveControlsAction) -> Self {
        switch action {
        case .present:
            return .presented
        case .contentTap:
            return Self(isVisible: !isVisible, isLocked: isLocked)
        case .lock:
            return Self(isVisible: false, isLocked: true)
        case .unlock:
            return .presented
        case .autoHide:
            return Self(isVisible: false, isLocked: isLocked)
        case .dismiss:
            return .inactive
        }
    }
}
