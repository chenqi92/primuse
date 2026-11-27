public enum OfflinePlaybackPolicy {
    /// A cached audio file must remain immediately playable unless the network
    /// is already known to be reachable. A sidecar music video is supplemental
    /// and must not hold the local audio path behind a remote timeout during
    /// cold-start reachability detection or while fully offline.
    public static func shouldSkipRemoteMusicVideo(
        hasUsableCachedAudio: Bool,
        isStandaloneMusicVideo: Bool,
        hasDeterminedNetworkPath: Bool,
        isNetworkReachable: Bool
    ) -> Bool {
        hasUsableCachedAudio
            && !isStandaloneMusicVideo
            && (!hasDeterminedNetworkPath || !isNetworkReachable)
    }

    /// A prefetch that started before a complete offline download became
    /// available is no longer relevant to playback and must not delay it.
    public static func shouldWaitForBackgroundCache(
        hasUsableCachedAudio: Bool,
        hasInFlightTask: Bool
    ) -> Bool {
        hasInFlightTask && !hasUsableCachedAudio
    }
}
