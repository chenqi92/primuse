#if os(iOS)
import Foundation
import Observation
import PrimuseKit

@MainActor
@Observable
final class CarPlaySettingsStore {
    static let shared = CarPlaySettingsStore()
    private static let savedLayoutsKey = "primuse.carplay.savedLayouts.v1"

    var savedLayouts: [CarPlaySavedLayout] {
        didSet {
            guard savedLayouts != oldValue, let data = try? JSONEncoder().encode(savedLayouts) else { return }
            defaults.set(data, forKey: Self.savedLayoutsKey)
        }
    }

    var configuration: CarPlayLayoutConfiguration {
        didSet {
            guard configuration != oldValue else { return }
            configuration.save(to: defaults)
        }
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        configuration = CarPlayLayoutConfiguration.load(from: defaults)
        savedLayouts = defaults.data(forKey: Self.savedLayoutsKey)
            .flatMap { try? JSONDecoder().decode([CarPlaySavedLayout].self, from: $0) } ?? []
    }
}

/// CarPlay can cold-launch before the phone's HomeDiscoveryObserver exists.
/// Build from committed scan identities so opaque provider IDs remain folders.
@MainActor
@Observable
final class CarPlayFolderLibrary {
    static let shared = CarPlayFolderLibrary()
    private(set) var index: LibraryFolderIndex?
    private(set) var isLoading = false
    private(set) var revision = 0
    @ObservationIgnored private var owners: Set<UUID> = []
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var buildTask: Task<Void, Never>?
    @ObservationIgnored private var namesObserver: NSObjectProtocol?
    @ObservationIgnored private var namesRevision = 0
    @ObservationIgnored private var cachedInput: InputStamp?

    private struct InputStamp: Equatable {
        let songs: Int
        let playlists: Int
        let hierarchy: UInt64
        let sources: [LibraryFolderSourceDescriptor]
        let names: Int
    }

    func acquire(_ owner: UUID) {
        guard owners.insert(owner).inserted, owners.count == 1 else { return }
        generation &+= 1
        observeInputs(generation: generation)
        if namesObserver == nil { namesObserver = NotificationCenter.default.addObserver(
            forName: CloudDirectoryNameStore.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.namesRevision &+= 1
                self?.scheduleRebuild()
            }
        } }
        scheduleRebuild()
    }

    func release(_ owner: UUID) {
        owners.remove(owner)
        guard owners.isEmpty else { return }
        generation &+= 1
        buildTask?.cancel()
        buildTask = nil
        isLoading = false
    }

    func songs(in id: LibraryFolderNodeID, scope: LibraryFolderSongScope = .descendants) -> [Song] {
        let library = AppServices.shared.musicLibrary
        return (index?.songIDs(in: id, scope: scope) ?? [])
            .compactMap { library.unobservedVisibleSong(id: $0) }
            .sorted {
                if $0.discNumber != $1.discNumber { return ($0.discNumber ?? 0) < ($1.discNumber ?? 0) }
                if $0.trackNumber != $1.trackNumber { return ($0.trackNumber ?? 0) < ($1.trackNumber ?? 0) }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
    }

    private func observeInputs(generation expectedGeneration: Int) {
        withObservationTracking {
            _ = AppServices.shared.musicLibrary.visibleSongCollectionRevision
            _ = AppServices.shared.musicLibrary.playlistCollectionRevision
            _ = AppServices.shared.scanService.folderHierarchyRevision
            _ = AppServices.shared.sourcesStore.allSources
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, !self.owners.isEmpty, self.generation == expectedGeneration else { return }
                self.scheduleRebuild()
                self.observeInputs(generation: expectedGeneration)
            }
        }
    }

    private struct ProviderInput: Sendable {
        let items: [String: SourceSyncIndexedItem]
        let rootNames: [String: String]
        let indexedRoots: Bool
    }

    private func scheduleRebuild() {
        guard !owners.isEmpty else { return }
        let services = AppServices.shared
        let stamp = InputStamp(songs: services.musicLibrary.visibleSongCollectionRevision,
            playlists: services.musicLibrary.playlistCollectionRevision,
            hierarchy: UInt64(services.scanService.folderHierarchyRevision),
            sources: services.sourcesStore.allSources.map(LibraryFolderSourceDescriptor.init(source:)), names: namesRevision)
        guard stamp != cachedInput else { return }
        buildTask?.cancel()
        isLoading = true
        buildTask = Task { [weak self] in
            guard let self else { return }
            if self.index != nil {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
            guard !Task.isCancelled else { return }
            let library = AppServices.shared.musicLibrary
            let sources = AppServices.shared.sourcesStore.allSources
            let songs = library.visibleSongs
            let spokenWordSongIDs = library.spokenWordSongIDs
            let collections = library.appleMusicFolderCollections(availableSongs: songs)
            var descriptors = sources.map(LibraryFolderSourceDescriptor.init(source:))
            var known = Set(descriptors.map(\.sourceID))
            for song in songs where known.insert(song.sourceID).inserted {
                descriptors.append(LibraryFolderSourceDescriptor(
                    sourceID: song.sourceID,
                    displayName: song.sourceID == AppleMusicLibraryIdentity.sourceID
                        ? String(localized: "apple_music_library_section") : String(localized: "source_label"),
                    scanRoots: [], pathSemantics: .opaque
                ))
            }
            var providers: [String: ProviderInput] = [:]
            for source in sources where source.type.isCloudDrive || source.type.isServerLibrary || source.type == .upnp {
                providers[source.id] = ProviderInput(
                    items: AppServices.shared.scanService.libraryFolderSyncIndex(for: source.id),
                    rootNames: source.type.isCloudDrive ? CloudDirectoryNameStore.displayNames(for: source.id) : [:],
                    indexedRoots: source.type.isServerLibrary || source.type == .upnp
                )
            }
            let task = Task.detached(priority: .utility) { [descriptors, providers] in
                let resolved = descriptors.map { descriptor in
                    guard let provider = providers[descriptor.sourceID], !provider.items.isEmpty else { return descriptor }
                    let indexedRoots = provider.items.values.filter { $0.isDirectory && $0.parentPath == nil }
                        .sorted { $0.path < $1.path }
                    let paths = provider.indexedRoots && !indexedRoots.isEmpty
                        ? indexedRoots.map(\.path) : descriptor.scanRoots
                    let roots = paths.map { path in
                        let indexedName = indexedRoots.first { $0.path == path }?.displayName
                        let pathName = descriptor.pathSemantics == .hierarchical && path != "/"
                            ? (path as NSString).lastPathComponent : nil
                        return LibraryFolderProviderRootDescriptor(
                            path: path, displayName: indexedName ?? provider.rootNames[path] ?? pathName
                        )
                    }
                    return descriptor.withProviderHierarchy(LibraryFolderProviderHierarchy(
                        roots: roots,
                        items: provider.items.values.map {
                            LibraryFolderProviderItemDescriptor(
                                path: $0.path, displayName: $0.displayName,
                                parentPath: $0.parentPath, isDirectory: $0.isDirectory
                            )
                        }
                    ))
                }
                return LibraryFolderIndexBuilder.build(sources: resolved, songs: songs, virtualCollections: collections,
                                                       spokenWordSongIDs: spokenWordSongIDs)
            }
            let result = await withTaskCancellationHandler {
                await task.value
            } onCancel: { task.cancel() }
            guard !Task.isCancelled else { return }
            self.index = result
            self.cachedInput = stamp
            self.revision &+= 1
            self.isLoading = false
            self.buildTask = nil
        }
    }
}
#endif
