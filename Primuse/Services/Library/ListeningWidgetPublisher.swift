import Foundation
import Observation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import WidgetKit
import PrimuseKit

@MainActor
final class ListeningWidgetPublisher {
    private let library: MusicLibrary
    private let radioStations: @MainActor () -> [RadioStation]
    private var observers: [NSObjectProtocol] = []
    private var pending: Task<Void, Never>?
    private var settingsSignature = ""

    init(library: MusicLibrary, radioStations: @escaping @MainActor () -> [RadioStation]) {
        self.library = library
        self.radioStations = radioStations
    }

    func start() {
        settingsSignature = currentSettingsSignature
        for name in [Notification.Name.primusePodcastsDidChange, .primuseRadioStationsDidChange,
                     .primuseSpokenWordDidChange, .primuseArtworkDidCache] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.schedule() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.settingsSignature != self.currentSettingsSignature else { return }
                self.settingsSignature = self.currentSettingsSignature
                self.schedule()
            }
        })
        observeLibrary()
        schedule()
    }

    private var currentSettingsSignature: String {
        "\(WidgetSettings.syncEnabled())|\(WidgetSettings.sharedDataScope().rawValue)"
    }

    private func observeLibrary() {
        withObservationTracking {
            _ = library.localPodcastSongs
            _ = radioStations()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.schedule()
                self?.observeLibrary()
            }
        }
    }

    private func schedule() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.publish()
        }
    }

    private func publish() async {
        let scope = WidgetSettings.sharedDataScope()
        guard WidgetSettings.syncEnabled() else {
            for kind in [ListeningWidgetKind.podcast, .radio] {
                kind.clear()
                WidgetCenter.shared.reloadTimelines(ofKind: kind.widgetKind)
            }
            WidgetCenter.shared.reloadTimelines(ofKind: "ListeningDeskWidget")
            Self.pruneCovers(keeping: [])
            return
        }
        let store = PodcastStore.shared
        let positions = SpokenWordStore.shared
        var candidates: [ListeningWidgetPolicy.Candidate] = []
        var artworkIDs: [String: String] = [:]
        // The store's visible shows already enforce storefront availability.
        for show in store.shows {
            for episode in store.episodes(forShowID: show.id) {
                let state = store.state(for: episode)
                let fraction = state.position.flatMap { position in
                    episode.duration.flatMap { $0 > 0 ? floor(position / $0 * 100) / 100 : nil }
                }
                candidates.append(.init(
                    item: .init(id: episode.id, title: episode.title, subtitle: show.title, fractionComplete: fraction),
                    lastPlayedAt: state.isInProgress ? positions.position(forSongID: episode.id)?.updatedAt : nil,
                    publishedAt: episode.publishedAt ?? episode.firstSeenAt, isFinished: state.isFinished
                ))
                artworkIDs[episode.id] = episode.artworkURL == nil ? show.id : episode.id
            }
        }
        for song in library.localPodcastSongs {
            let position = positions.position(forSongID: song.id)
            candidates.append(.init(
                item: .init(id: song.id, title: song.title, subtitle: song.albumTitle ?? song.artistName ?? "",
                            fractionComplete: position.map { floor($0.fractionComplete * 100) / 100 }),
                lastPlayedAt: position?.updatedAt, publishedAt: song.dateAdded,
                isFinished: positions.isFinished(songID: song.id)
            ))
            artworkIDs[song.id] = song.id
        }
        var podcasts = ListeningWidgetPolicy.select(candidates)
        let stations = Array(radioStations().sorted {
            if $0.lastPlayedAt != $1.lastPlayedAt {
                return ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast)
            }
            return ($0.sortOrder ?? Int.max, $0.id) < ($1.sortOrder ?? Int.max, $1.id)
        }.prefix(4))
        var radios = stations.map { ListeningWidgetSnapshot.Item(id: $0.id, title: $0.name, subtitle: $0.folderName ?? "") }
        if scope.includesCover {
            for index in podcasts.indices {
                let key = artworkIDs[podcasts[index].id] ?? podcasts[index].id
                let data = await MetadataAssetStore.shared.cachedCoverData(forSongID: key)
                podcasts[index].coverImageName = await Self.writeCover(data, id: podcasts[index].id)
            }
            for index in radios.indices {
                let plan = RadioStationArtworkResolutionPolicy.makePlan(for: stations[index])
                for candidate in plan.candidates {
                    let data: Data?
                    switch candidate {
                    case .inline(let inline):
                        data = inline
                    case .cachedOrSource(let request):
                        if let stored = await MetadataAssetStore.shared.coverData(named: request.coverReference) {
                            data = stored
                        } else {
                            data = await MetadataAssetStore.shared.cachedCoverData(forSongID: request.songID)
                        }
                    }
                    if let name = await Self.writeCover(data, id: radios[index].id) {
                        radios[index].coverImageName = name
                        break
                    }
                }
            }
        }
        // A privacy or library change during artwork work invalidates this publication.
        guard !Task.isCancelled, WidgetSettings.syncEnabled(), WidgetSettings.sharedDataScope() == scope else {
            if !WidgetSettings.syncEnabled() || !WidgetSettings.sharedDataScope().includesCover {
                Self.pruneCovers(keeping: [])
            }
            return
        }
        let podcastSnapshot = ListeningWidgetSnapshot(items: podcasts).limited(to: scope)
        let radioSnapshot = ListeningWidgetSnapshot(items: radios).limited(to: scope)
        var changed = false
        for (kind, snapshot) in [(ListeningWidgetKind.podcast, podcastSnapshot), (.radio, radioSnapshot)] {
            if kind.save(snapshot) {
                changed = true
                WidgetCenter.shared.reloadTimelines(ofKind: kind.widgetKind)
            }
        }
        if changed { WidgetCenter.shared.reloadTimelines(ofKind: "ListeningDeskWidget") }
        Self.pruneCovers(keeping: Set((podcastSnapshot.items + radioSnapshot.items).compactMap(\.coverImageName)))
    }

    private nonisolated static func writeCover(_ data: Data?, id: String) async -> String? {
        guard let data else { return nil }
        return await Task.detached(priority: .utility) {
            guard let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: PrimuseConstants.appGroupIdentifier),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 240,
                    kCGImageSourceCreateThumbnailWithTransform: true
                  ] as CFDictionary) else { return nil }
            // Content-addressed names refresh a changed cover even when its item's ID is unchanged.
            let digest = SHA256.hash(data: Data(id.utf8) + data).prefix(16).map { String(format: "%02x", $0) }.joined()
            let name = ListeningWidgetPolicy.coverPrefix + digest + ".jpg"
            let url = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { return name }
            let encoded = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(encoded, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { return nil }
            do {
                try (encoded as Data).write(to: url, options: .atomic)
                return name
            } catch {
                return nil
            }
        }.value
    }

    private static func pruneCovers(keeping: Set<String>) {
        guard let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: PrimuseConstants.appGroupIdentifier),
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files where file.lastPathComponent.hasPrefix(ListeningWidgetPolicy.coverPrefix) && !keeping.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
