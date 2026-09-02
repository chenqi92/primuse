public enum AppleMusicCatalogSearchAvailabilityPolicy {
    public static func isEnabled(
        catalogSearchEnabled: Bool,
        disabledSourceIDs: Set<String>
    ) -> Bool {
        catalogSearchEnabled
            && !disabledSourceIDs.contains(AppleMusicLibraryIdentity.sourceID)
    }
}
