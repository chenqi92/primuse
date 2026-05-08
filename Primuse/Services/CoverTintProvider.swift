import Foundation
import SwiftUI
import UIKit
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
    private var cache: [String: Color] = [:]
    private var inFlight: Set<String> = []

    /// Synchronous read. Returns the cached tint if extraction has
    /// finished. Returns nil while computation is pending — callers
    /// fall back to plain Material until the cache fills in, at which
    /// point @Observable triggers a re-render.
    func tint(forSongID songID: String) -> Color? {
        cache[songID]
    }

    /// Schedule background extraction for any songs not already
    /// cached. Idempotent — safe to call on every body re-eval.
    func prepare(_ songs: [Song]) {
        for song in songs {
            guard cache[song.id] == nil, !inFlight.contains(song.id) else { continue }
            inFlight.insert(song.id)
            let songID = song.id
            let coverFileName = song.coverArtFileName
            Task.detached(priority: .utility) {
                let color = Self.computeTint(songID: songID, coverFileName: coverFileName)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    if let color {
                        self.cache[songID] = color
                    }
                    self.inFlight.remove(songID)
                }
            }
        }
    }

    func clearCache() {
        cache.removeAll(keepingCapacity: false)
    }

    /// Off-main extraction. Mirrors ThemeService's load-then-extract
    /// flow: try songID-derived hashed filename first, fall back to
    /// the legacy filename column. `MetadataAssetStore.readCoverData`
    /// is `nonisolated`, so no actor hop needed.
    nonisolated private static func computeTint(songID: String, coverFileName: String?) -> Color? {
        let hashedName = MetadataAssetStore.shared.expectedCoverFileName(for: songID)
        var data = MetadataAssetStore.shared.readCoverData(named: hashedName)
        if data == nil,
           let coverFileName,
           !coverFileName.isEmpty,
           !coverFileName.contains("/"),
           !coverFileName.contains("://") {
            data = MetadataAssetStore.shared.readCoverData(named: coverFileName)
        }
        guard let data, let image = UIImage(data: data) else { return nil }
        return ThemeService.extractDominantColor(from: image).accent
    }
}
