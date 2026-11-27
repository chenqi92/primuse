import Foundation

/// An AVPlayer end notification is valid only for the item that is both still
/// active in the engine and still installed on the player. This rejects queued
/// notifications from an item detached by a newer selection or cancellation.
public enum PlaybackEndIdentityPolicy {
    public static func shouldAdvance<ItemID: Equatable>(
        endedItemID: ItemID,
        activeItemID: ItemID?,
        currentItemID: ItemID?
    ) -> Bool {
        endedItemID == activeItemID && endedItemID == currentItemID
    }
}
