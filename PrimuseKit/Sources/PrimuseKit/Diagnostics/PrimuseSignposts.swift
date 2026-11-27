import Foundation
import os

/// Shared signposters for performance work that has to be measured on device
/// with Instruments. Nothing here logs: when no Instruments session is
/// attached `OSSignposter` short-circuits and the intervals cost a predicate
/// check, so the calls can stay in shipping builds.
///
/// Interval names are deliberately stable — an Animation Hitches / Time
/// Profiler trace is compared across builds by name:
/// - `library.addSongs` — scan flush merge on the main actor
/// - `library.applyVisibleCache` — derived-index apply (lookup swap)
/// - `library.assetPatchBatch` — coalesced scraped cover/lyrics/MV patches
/// - `library.lyricsTextBatch` — lyrics-text batch publication
/// - `backfill.flushApply` / `backfill.remainingCounts` — tag-reading backfill
/// - `player.nowPlayingPublish` / `player.sessionPersist` — playback publishing
/// - `sync.statsEncode` / `sync.statsDecode` — listening-stats CloudKit payload
/// - `tv.installPayload` / `tv.reloadMerging` — tvOS snapshot install + reload
/// - `player.widgetPublish` / `player.widgetCover` — iOS widget publication
/// - `player.sessionActivate` / `player.sessionDeactivate` / `player.hardwareRate` — audio session IPC
public enum PrimuseSignposts {
    public static let hitch = OSSignposter(
        subsystem: "com.welape.primuse",
        category: "hitch"
    )
}
