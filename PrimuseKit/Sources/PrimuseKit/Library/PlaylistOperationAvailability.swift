import Foundation

public struct PlaylistOperationAvailability: Equatable, Sendable {
    public let supportsImport: Bool

    public static let standard = PlaylistOperationAvailability(supportsImport: true)
    public static let television = PlaylistOperationAvailability(supportsImport: false)

    public init(supportsImport: Bool) {
        self.supportsImport = supportsImport
    }
}
