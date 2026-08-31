import Foundation
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
import PrimuseKit

/// Per-song dominant-color cache. Used by HomeView's recommendation /
/// continue-listening cards to tint their backgrounds with a soft
/// gradient pulled from the song's cover art — the "your music drives
/// the visuals" idea, no static decoration art needed.
///
/// Distinct from `ThemeService` (global accent for the currently
/// playing song): this never mutates app-wide state. Each card asks
/// for its own song's tint, gets a `Color?` back; the provider
/// schedules background extraction on first request and caches the
/// result for the rest of the app session.
@MainActor
@Observable
final class CoverTintProvider {
    /// In-memory cache: songID → derived tint. Reset on memory
    /// pressure via `clearCache()`. Covers don't change often, so a
    /// cold launch + extract pass for ~12 visible cards is cheap and
    /// the cache stays warm afterwards.
    private var cache: [String: ImmersiveArtworkPalette] = [:]
    /// A valid cover was decoded but contained no representative chromatic
    /// region. Remembering that negative result avoids re-decoding grayscale
    /// artwork every time HomeView refreshes.
    private var noColorCache: Set<String> = []
    private var inFlight: Set<String> = []
    private var invalidatedWhileInFlight: Set<String> = []
    /// Latest Home inputs let an artwork cache notification retry immediately
    /// even when the visible song identity itself did not change.
    private var knownSongs: [String: Song] = [:]

    /// Synchronous read. Returns the cached tint if extraction has
    /// finished. Returns nil while computation is pending — callers
    /// fall back to plain Material until the cache fills in, at which
    /// point @Observable triggers a re-render.
    func tint(forSongID songID: String) -> Color? {
        cache[songID]?.primary
    }

    /// 沉浸播放器使用完整的明暗双色，而不是把一个固定色套到所有场景。
    func palette(forSongID songID: String) -> ImmersiveArtworkPalette? {
        cache[songID]
    }

    /// Schedule background extraction for any songs not already
    /// cached. Idempotent — safe to call on every body re-eval.
    func prepare(_ songs: [Song]) {
        for song in songs {
            knownSongs[song.id] = song
        }
        let pending = songs.filter {
            cache[$0.id] == nil
                && !noColorCache.contains($0.id)
                && !inFlight.contains($0.id)
        }
        guard !pending.isEmpty else { return }

        let pendingIDs = Set(pending.map(\.id))
        inFlight.formUnion(pendingIDs)
        Task.detached(priority: .utility) {
            // Read/decode the small visible set serially on one utility task.
            // Publishing one completed dictionary avoids re-evaluating the
            // entire HomeView once for every individual cover tint.
            var extracted: [String: ImmersiveArtworkPalette] = [:]
            var noColorIDs: Set<String> = []
            extracted.reserveCapacity(pending.count)
            for song in pending {
                guard !Task.isCancelled else { break }
                let result = Self.computeTint(
                    songID: song.id,
                    coverFileName: song.coverArtFileName
                )
                if let palette = result.palette {
                    extracted[song.id] = palette
                } else if result.analyzedImage {
                    noColorIDs.insert(song.id)
                }
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                let invalidated = self.invalidatedWhileInFlight.intersection(pendingIDs)
                let validIDs = pendingIDs.subtracting(invalidated)
                let validExtracted = extracted.filter { validIDs.contains($0.key) }
                if !validExtracted.isEmpty {
                    var nextCache = self.cache
                    nextCache.merge(validExtracted) { _, new in new }
                    self.cache = nextCache
                }
                self.noColorCache.formUnion(noColorIDs.intersection(validIDs))
                self.inFlight.subtract(pendingIDs)
                self.invalidatedWhileInFlight.subtract(pendingIDs)
                if !invalidated.isEmpty {
                    self.prepare(invalidated.compactMap { self.knownSongs[$0] })
                }
            }
        }
    }

    func clearCache() {
        cache.removeAll(keepingCapacity: false)
        noColorCache.removeAll(keepingCapacity: false)
        invalidatedWhileInFlight.formUnion(inFlight)
    }

    /// Artwork writes and replacements invalidate both positive and negative
    /// results. Notifications without song identities conservatively clear the
    /// small session cache because their object may be a legacy filename.
    func invalidateArtwork(from notification: Notification) {
        var songIDs = Set(notification.userInfo?["songIDs"] as? [String] ?? [])
        if let songID = notification.userInfo?["songID"] as? String {
            songIDs.insert(songID)
        }
        if notification.name == .primuseArtworkDidCache,
           let songID = notification.object as? String {
            songIDs.insert(songID)
        }
        guard !songIDs.isEmpty else {
            clearCache()
            prepare(Array(knownSongs.values))
            return
        }
        for songID in songIDs {
            cache.removeValue(forKey: songID)
            noColorCache.remove(songID)
            if inFlight.contains(songID) {
                invalidatedWhileInFlight.insert(songID)
            }
        }
        prepare(songIDs.compactMap { knownSongs[$0] })
    }

    /// Off-main extraction. Mirrors ThemeService's load-then-extract
    /// flow: try songID-derived hashed filename first, fall back to
    /// the legacy filename column. `MetadataAssetStore.readCoverData`
    /// is `nonisolated`, so no actor hop needed.
    nonisolated private static func computeTint(
        songID: String,
        coverFileName: String?
    ) -> (palette: ImmersiveArtworkPalette?, analyzedImage: Bool) {
        let hashedName = MetadataAssetStore.shared.expectedCoverFileName(for: songID)
        var data = MetadataAssetStore.shared.readCoverData(named: hashedName)
        if data == nil,
           let coverFileName,
           !coverFileName.isEmpty,
           !coverFileName.contains("/"),
           !coverFileName.contains("://") {
            data = MetadataAssetStore.shared.readCoverData(named: coverFileName)
        }
        guard let data, let image = PlatformImage(data: data) else { return (nil, false) }
        let result = ThemeService.extractDominantColor(from: image)
        return (result.map {
            ImmersiveArtworkPalette(primary: $0.accent, secondary: $0.secondaryDark)
        }, true)
    }
}
