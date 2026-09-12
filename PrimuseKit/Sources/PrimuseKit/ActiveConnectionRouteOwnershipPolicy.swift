import Foundation

/// A retired connector's router keeps publishing route changes while its
/// transport shuts down. The published slot is keyed by source, so a late
/// update from a replaced connector would erase the route of the connector
/// that now owns the source. Updates therefore carry the identity of the build
/// that claimed the cached slot.
public enum ActiveConnectionRouteOwnershipPolicy {
    public static func acceptsRouteUpdate(
        updateOwner: UUID?,
        currentOwner: UUID?
    ) -> Bool {
        guard let updateOwner else { return true }
        return updateOwner == currentOwner
    }
}
