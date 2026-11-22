import Foundation
import Observation
import PrimuseKit

/// A prepared mix is never a replacement for the library's original media.
final class EmbeddedKaraokeFile: Sendable {
    let songID: String
    let url: URL
    private let ownsFile: Bool

    init(songID: String, url: URL, ownsFile: Bool = true) {
        self.songID = songID
        self.url = url
        self.ownsFile = ownsFile
    }

    deinit {
        if ownsFile { try? FileManager.default.removeItem(at: url) }
    }
}

@Observable @MainActor
final class EmbeddedKaraokePlayback {
    private(set) var inventory: EmbeddedMediaTrackInventory?
    private(set) var selected: [Int]?
    private(set) var requested: [Int]?
    private(set) var isPreparing = false
    private(set) var failed = false
    @ObservationIgnored private var loadedSong: Song?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var inspection: Task<Void, Never>?
    @ObservationIgnored private var preparation: Task<Void, Never>?
    @ObservationIgnored private var original: EmbeddedKaraokeFile?
    @ObservationIgnored private var opening: (id: UUID, task: Task<EmbeddedKaraokeFile, Error>)?

    private(set) var backingOrdinals: [Int]?
    private(set) var originalOrdinals: [Int]?
    private(set) var isStemMix = false
    private(set) var isBacking = false

    private func backingTracks(in inventory: EmbeddedMediaTrackInventory) -> [Int]? {
        guard inventory.audioTracks.count > 1 else { return nil }
        if let track = inventory.instrumentalTracks.first(where: { $0.stemName == nil }) {
            return [track.ordinal]
        }
        let stems = inventory.stemTracks
        let backing = stems.filter { !$0.isVocalStem }.map(\.ordinal)
        return stems.contains(where: \.isVocalStem) && !backing.isEmpty ? backing.sorted() : nil
    }

    private func isBackingSelection(_ selected: [Int]?, in inventory: EmbeddedMediaTrackInventory?) -> Bool {
        guard let inventory else { return false }
        guard let selected else { return defaultTrack(in: inventory)?.isInstrumental == true }
        if selected.count == 1, inventory.instrumentalTracks.contains(where: { $0.ordinal == selected[0] }) {
            return true
        }
        let stems = inventory.stemTracks
        return !selected.isEmpty && stems.contains(where: \.isVocalStem)
            && selected.allSatisfy { ordinal in stems.contains { $0.ordinal == ordinal && !$0.isVocalStem } }
    }

    private func defaultTrack(in inventory: EmbeddedMediaTrackInventory) -> EmbeddedMediaTrackInventory.AudioTrack? {
        inventory.audioTracks.first(where: \.isDefault) ?? inventory.audioTracks.first
    }

    private func setInventory(_ value: EmbeddedMediaTrackInventory?) {
        guard inventory != value else { return }
        inventory = value
        backingOrdinals = value.flatMap(backingTracks)
        originalOrdinals = nil
        if let value, let original = value.originalTrack, original.ordinal != defaultTrack(in: value)?.ordinal {
            originalOrdinals = [original.ordinal]
        }
        setSelection(selected)
    }

    private func setSelection(_ value: [Int]?) {
        selected = value
        if let value, let inventory {
            isStemMix = value.isEmpty || inventory.stemTracks.contains { value.contains($0.ordinal) }
        } else {
            isStemMix = false
        }
        isBacking = isBackingSelection(value, in: inventory)
    }

    /// nil plays the authored master. A selection of zero stems plays silence on its timeline.
    func togglingStem(_ track: EmbeddedMediaTrackInventory.AudioTrack) -> [Int]? {
        let stems = inventory?.stemTracks.map(\.ordinal) ?? []
        var enabled = Set(requested ?? stems).intersection(stems)
        if !enabled.insert(track.ordinal).inserted { enabled.remove(track.ordinal) }
        return enabled == Set(stems) ? nil : enabled.sorted()
    }

    func load(for song: Song?, inspect: @escaping @MainActor (Song) async -> EmbeddedMediaTrackInventory?) {
        if let song, let loadedSong, EmbeddedMediaTrackInventory.sameMediaFile(song, loadedSong) {
            if let stored = song.embeddedMediaTracks { setInventory(stored) }
            return
        }
        reset()
        guard let song, !song.isStreamDescriptor, EmbeddedMediaTrackInventory.supports(song) else { return }
        loadedSong = song
        if let stored = song.embeddedMediaTracks {
            setInventory(stored)
        } else {
            inspection = Task { [weak self] in
                let result = await inspect(song)
                guard !Task.isCancelled, self?.loadedSong?.id == song.id else { return }
                self?.setInventory(result)
            }
        }
    }

    func reset() {
        inspection?.cancel()
        preparation?.cancel()
        opening?.task.cancel()
        opening = nil
        inspection = nil
        preparation = nil
        generation = UUID()
        loadedSong = nil
        setSelection(nil)
        setInventory(nil)
        requested = nil
        original = nil
        isPreparing = false
        failed = false
    }

    func select(
        _ ordinals: [Int]?, for song: Song,
        source: @escaping @MainActor () async throws -> KaraokeAudioFile,
        apply: @escaping @MainActor (EmbeddedKaraokeFile?) -> Bool
    ) {
        guard let loadedSong, EmbeddedMediaTrackInventory.sameMediaFile(song, loadedSong), let inventory else { return }
        let ordinals = ordinals.map { Set($0).sorted() }
        if let ordinals, !Set(ordinals).isSubset(of: inventory.audioTracks.map(\.ordinal)) { return }
        if requested == ordinals && !failed { return }
        preparation?.cancel()
        let ticket = UUID()
        generation = ticket
        requested = ordinals
        failed = false
        if ordinals == nil {
            opening?.task.cancel()
            opening = nil
        }
        if ordinals == selected {
            isPreparing = false
            return
        }
        guard let ordinals else {
            isPreparing = false
            if apply(nil) {
                setSelection(nil)
            } else {
                failed = true
                requested = selected
            }
            return
        }
        isPreparing = true
        preparation = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == ticket {
                    isPreparing = false
                    preparation = nil
                }
            }
            do {
                let input = try await originalFile(for: song, source: source)
                try Task.checkCancellation()
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("primuse-karaoke-\(ticket.uuidString).caf")
                let mix = EmbeddedKaraokeFile(songID: song.id, url: url)
                defer { withExtendedLifetime(input) {} }
                try await EmbeddedKaraokeAudio.render(from: input.url, audioOrdinals: ordinals, to: mix.url)
                try Task.checkCancellation()
                guard generation == ticket else { return }
                guard apply(mix) else { throw KaraokeSeparationError.unreadableAudio }
                setSelection(ordinals)
            } catch {
                guard !Task.isCancelled, generation == ticket else { return }
                failed = true
                requested = selected
            }
        }
    }
    private func originalFile(for song: Song, source: @escaping @MainActor () async throws -> KaraokeAudioFile) async throws -> EmbeddedKaraokeFile {
        if let original { return original }
        if let opening { return try await opening.task.value }
        let id = UUID()
        let task = Task {
            let file = try await source()
            let input = EmbeddedKaraokeFile(songID: song.id, url: file.url, ownsFile: file.removeAfterDecoding)
            try Task.checkCancellation()
            return input
        }
        opening = (id, task)
        defer { if opening?.id == id { opening = nil } }
        let input = try await task.value
        guard opening?.id == id else { throw CancellationError() }
        original = input
        return input
    }

}
