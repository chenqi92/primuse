import PhotosUI
import PrimuseKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Environment

private struct MotionCoverLookupEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// 关掉以后封面位不再自己去找歌曲、专辑的视频动态封面。专辑大图在最上层统一放一份，
    /// 里面借用的歌曲封面层就不要各放一份（同一段视频两个解码器叠在一起）。
    var motionCoverLookupEnabled: Bool {
        get { self[MotionCoverLookupEnabledKey.self] }
        set { self[MotionCoverLookupEnabledKey.self] = newValue }
    }
}

// MARK: - Album hero overlay

/// 专辑大图最上层的视频动态封面。静态层（自动、选的歌、上传的图）照常画在下面：视频没准备好、
/// 暂停、低电量、减少动态效果或关了总开关时露出来的就是它。
struct MotionCoverHeroOverlay: View {
    let albumID: String
    var isVisible = true
    var requiresPlayback = false
    var isPlaying = true

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityPlayAnimatedImages) private var playAnimatedImages
    @State private var runtimeRevision = 0

    var body: some View {
        Group {
            if let url = MotionCoverStore.shared.videoURL(songID: nil, albumID: albumID) {
                let _ = runtimeRevision
                MotionArtworkVideoView(url: url, shouldAnimate: policy.shouldAnimate) {
                    Color.clear
                }
                .onReceive(NotificationCenter.default.publisher(
                    for: Notification.Name.NSProcessInfoPowerStateDidChange
                )) { _ in
                    runtimeRevision &+= 1
                }
                .onReceive(NotificationCenter.default.publisher(
                    for: ProcessInfo.thermalStateDidChangeNotification
                )) { _ in
                    runtimeRevision &+= 1
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var policy: ArtworkAnimationPolicy {
        ArtworkAnimationPolicy(
            isEnabled: AnimatedArtworkPreferences.shared.animatedArtworkEnabled,
            presentationRole: .animatedHero,
            isVisible: isVisible,
            isSceneActive: scenePhase == .active,
            requiresPlayback: requiresPlayback,
            isPlaying: isPlaying,
            reduceMotion: reduceMotion,
            playAnimatedImages: playAnimatedImages,
            isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermalCondition: MotionCoverDisplay.thermalCondition(ProcessInfo.processInfo.thermalState)
        )
    }
}

// MARK: - Display helpers

enum MotionCoverDisplay {
    nonisolated static func thermalCondition(_ state: ProcessInfo.ThermalState) -> ArtworkThermalCondition {
        switch state {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .critical
        }
    }

    /// 「12 秒 · 3:4 · 4.2 MB」。
    static func summary(of asset: MotionCoverAsset) -> String {
        let seconds = max(1, Int(asset.duration.rounded()))
        let duration = Duration.seconds(seconds).formatted(
            .units(allowed: [.minutes, .seconds], width: .abbreviated)
        )
        let aspect = asset.aspect == .tall ? "3:4" : "1:1"
        let size = ByteCountFormatter.string(fromByteCount: asset.byteCount, countStyle: .file)
        return "\(duration) · \(aspect) · \(size)"
    }

    @MainActor
    static func statusKey(owner: MotionCoverOwner, albumID: String?) -> LocalizedStringKey {
        let store = MotionCoverStore.shared
        if store.asset(for: owner) != nil { return "motion_cover_status_set" }
        if case .song(let songID) = owner,
           store.effectiveAsset(songID: songID, albumID: albumID) != nil {
            return "motion_cover_following_album"
        }
        return "motion_cover_status_none"
    }
}

// MARK: - Editor

/// 「动态封面」编辑页：给一首歌或一张专辑选视频或动图、预览、移除（#411）。
/// 选好就生效，不跟标签编辑的「保存」走。
struct MotionCoverEditorView<Preview: View>: View {
    let owner: MotionCoverOwner
    /// 单曲所在专辑：单曲自己没设时显示「跟随专辑」。
    var albumID: String? = nil
    var showsDoneButton = false
    @ViewBuilder let preview: () -> Preview

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityPlayAnimatedImages) private var playAnimatedImages
    @State private var controller = MotionCoverImportController()
    @State private var isFileImporterPresented = false
    @State private var photoItem: PhotosPickerItem?

    private var ownAsset: MotionCoverAsset? {
        MotionCoverStore.shared.asset(for: owner)
    }

    private var effectiveAsset: MotionCoverAsset? {
        switch owner {
        case .song(let songID):
            MotionCoverStore.shared.effectiveAsset(songID: songID, albumID: albumID)?.asset
        case .album(let id):
            MotionCoverStore.shared.effectiveAsset(songID: nil, albumID: id)?.asset
        }
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    previewTile
                    VStack(alignment: .leading, spacing: 4) {
                        Text(MotionCoverDisplay.statusKey(owner: owner, albumID: albumID))
                            .font(.headline)
                        if let effectiveAsset {
                            Text(verbatim: MotionCoverDisplay.summary(of: effectiveAsset))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
            }

            Section {
                PhotosPicker(
                    selection: $photoItem,
                    matching: .any(of: [.videos, .images]),
                    preferredItemEncoding: .current
                ) {
                    Label("motion_cover_choose_photos", systemImage: "photo.on.rectangle")
                }
                Button {
                    isFileImporterPresented = true
                } label: {
                    Label("motion_cover_choose_file", systemImage: "folder")
                }
                if ownAsset != nil {
                    Button(role: .destructive) {
                        MotionCoverStore.shared.removeAsset(for: owner)
                    } label: {
                        Label("motion_cover_remove", systemImage: "trash")
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("motion_cover_footer")
                    if case .album = owner {
                        Text("motion_cover_album_footer")
                    }
                    if !AnimatedArtworkPreferences.shared.animatedArtworkEnabled {
                        Text("motion_cover_disabled_hint")
                    }
                }
            }
            .disabled(controller.isProcessing)
        }
        .formStyle(.grouped)
        .navigationTitle(Text("motion_cover_title"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if showsDoneButton {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "done")) { dismiss() }
                        .disabled(controller.isProcessing)
                }
            }
        }
        .overlay {
            if controller.isProcessing {
                processingCard
            }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            photoItem = nil
            controller.importPhotosItem(item, for: owner)
        }
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.movie, .gif],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            controller.importFile(at: url, for: owner)
        }
        .alert(
            String(localized: "motion_cover_failed_title"),
            isPresented: Binding(
                get: { controller.errorMessage != nil },
                set: { if !$0 { controller.errorMessage = nil } }
            )
        ) {
            Button("ok", role: .cancel) {}
        } message: {
            Text(controller.errorMessage ?? "")
        }
        .onDisappear { controller.cancel() }
        #if DEBUG
        .task {
            // 取证:`PRIMUSE_DEBUG_MOTION_COVER_IMPORT=<Documents 里的文件名>` 打开编辑页后直接导入这个文件,
            // 看处理中的进度卡和导入后的预览。
            guard let name = ProcessInfo.processInfo.environment["PRIMUSE_DEBUG_MOTION_COVER_IMPORT"],
                  !name.isEmpty else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            let url = URL.documentsDirectory.appendingPathComponent(name)
            plog("🧪 Debug: motion cover import \(url.lastPathComponent)")
            controller.importFile(at: url, for: owner)
        }
        #endif
    }

    private var previewTile: some View {
        ZStack {
            preview()
            if let effectiveAsset, !reduceMotion, playAnimatedImages {
                MotionArtworkVideoView(
                    url: MotionCoverStore.videoURL(for: effectiveAsset),
                    shouldAnimate: true
                ) {
                    Color.clear
                }
                .allowsHitTesting(false)
            }
        }
        .frame(width: 96, height: 96)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityHidden(true)
    }

    private var processingCard: some View {
        VStack(spacing: 12) {
            ProgressView(value: controller.progress) {
                Text("motion_cover_processing")
            }
            .frame(width: 200)
            Button(String(localized: "cancel")) { controller.cancel() }
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// 导入在后台跑：拷文件、规整视频、写进动态封面目录，最后在主线程登记。
@MainActor
@Observable
final class MotionCoverImportController {
    private(set) var isProcessing = false
    private(set) var progress: Double = 0
    var errorMessage: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    func importPhotosItem(_ item: PhotosPickerItem, for owner: MotionCoverOwner) {
        run(owner: owner) { report in
            if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                guard let movie = try await item.loadTransferable(type: MotionCoverPickedMovie.self) else {
                    throw MotionCoverImportError.rejected(.unreadable)
                }
                defer { try? FileManager.default.removeItem(at: movie.url) }
                return try await MotionCoverImporter.importItem(at: movie.url, progress: report)
            }
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw MotionCoverImportError.rejected(.unreadable)
            }
            return try await MotionCoverImporter.importAnimation(data: data, progress: report)
        }
    }

    func importFile(at url: URL, for owner: MotionCoverOwner) {
        run(owner: owner) { report in
            try await MotionCoverImporter.importPickedFile(at: url, progress: report)
        }
    }

    func cancel() {
        task?.cancel()
    }

    private func run(
        owner: MotionCoverOwner,
        work: @escaping @Sendable (@escaping @Sendable (Double) -> Void) async throws -> MotionCoverAsset
    ) {
        task?.cancel()
        generation &+= 1
        let current = generation
        isProcessing = true
        progress = 0
        errorMessage = nil
        let report: @Sendable (Double) -> Void = { [weak self] value in
            Task { @MainActor [weak self] in
                guard let self, self.isProcessing else { return }
                self.progress = min(1, max(self.progress, value))
            }
        }
        task = Task { [weak self] in
            do {
                let asset = try await work(report)
                try Task.checkCancellation()
                MotionCoverStore.shared.setAsset(asset, for: owner)
                self?.finish(current)
            } catch {
                // 用户点了取消就不再报错。
                let cancelled = error is CancellationError || Task.isCancelled
                self?.finish(current)
                if !cancelled {
                    self?.errorMessage = error.localizedDescription
                }
            }
        }
    }

    /// 被新一次导入顶替的旧任务收尾时不能把新任务的状态清掉。
    private func finish(_ finishedGeneration: Int) {
        guard finishedGeneration == generation else { return }
        isProcessing = false
        progress = 0
        task = nil
    }
}

/// 从照片里选的视频：系统给的临时文件只在回调里有效，先拷进动态封面的暂存目录。
struct MotionCoverPickedMovie: Transferable, Sendable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension.lowercased()
            let destination = try MotionCoverImporter.makeStagingURL(pathExtension: ext)
            try FileManager.default.copyItem(at: received.file, to: destination)
            return MotionCoverPickedMovie(url: destination)
        }
    }
}

// MARK: - Entry points

/// 编辑页预览里垫在视频下面的静态封面。
struct SongMotionCoverPreview: View {
    let song: Song

    var body: some View {
        CachedArtworkView(
            coverRef: song.coverArtFileName,
            songID: song.id,
            size: 96,
            cornerRadius: 0,
            sourceID: song.sourceID,
            filePath: song.filePath,
            fileFormat: song.fileFormat
        )
    }
}

struct AlbumMotionCoverPreview: View {
    let albumID: String
    @Environment(MusicLibrary.self) private var library

    var body: some View {
        if let album = library.visibleAlbum(id: albumID) {
            AlbumArtworkView(album: album, size: 96, cornerRadius: 0)
        } else {
            CachedArtworkView(
                coverRef: nil,
                songID: nil,
                size: 96,
                cornerRadius: 0,
                placeholderIcon: "square.stack"
            )
        }
    }
}

/// 标签编辑页（iPhone / iPad）里的「动态封面」卡片，样式跟歌词卡片一致。
struct SongMotionCoverCard: View {
    let song: Song
    #if DEBUG
    @State private var debugOpensEditor = false
    #endif

    var body: some View {
        card
            #if DEBUG
            // 取证:`PRIMUSE_DEBUG_MOTION_COVER=open` 标签编辑页一打开就推进「动态封面」编辑页
            // (配合 `PRIMUSE_DEBUG_TAG_EDITOR` 打开标签编辑)。
            .navigationDestination(isPresented: $debugOpensEditor) {
                MotionCoverEditorView(owner: .song(song.id), albumID: song.albumID) {
                    SongMotionCoverPreview(song: song)
                }
            }
            .task {
                guard ProcessInfo.processInfo.environment["PRIMUSE_DEBUG_MOTION_COVER"] == "open" else { return }
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                debugOpensEditor = true
            }
            #endif
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("motion_cover_title")
                .font(.caption)
                .foregroundStyle(.secondary)
            NavigationLink {
                MotionCoverEditorView(owner: .song(song.id), albumID: song.albumID) {
                    SongMotionCoverPreview(song: song)
                }
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(MotionCoverDisplay.statusKey(owner: .song(song.id), albumID: song.albumID))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                        Text("motion_cover_entry_hint")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(14)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.secondary.opacity(0.08))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color.secondary.opacity(0.14), lineWidth: 0.5)
                        }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
    }
}

/// 专辑封面编辑页（iPhone / iPad）里的「动态封面」一行。
struct AlbumMotionCoverRow: View {
    let albumID: String

    var body: some View {
        NavigationLink {
            MotionCoverEditorView(owner: .album(albumID)) {
                AlbumMotionCoverPreview(albumID: albumID)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "film")
                    .frame(width: 28)
                Text("motion_cover_title")
                Spacer()
                Text(MotionCoverDisplay.statusKey(owner: .album(albumID), albumID: albumID))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#if os(macOS)
/// Mac 标签编辑页顶栏和专辑封面编辑页里的「动态封面」按钮，点开一张单独的面板。
struct MotionCoverMacButton<ButtonLabel: View>: View {
    let owner: MotionCoverOwner
    var albumID: String? = nil
    @ViewBuilder let label: () -> ButtonLabel
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            label()
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $isPresented) {
            NavigationStack {
                MotionCoverEditorView(owner: owner, albumID: albumID, showsDoneButton: true) {
                    switch owner {
                    case .song(let songID):
                        MacMotionCoverSongPreview(songID: songID)
                    case .album(let id):
                        AlbumMotionCoverPreview(albumID: id)
                    }
                }
            }
            .frame(width: 460, height: 480)
        }
    }
}

private struct MacMotionCoverSongPreview: View {
    let songID: String
    @Environment(MusicLibrary.self) private var library

    var body: some View {
        if let song = library.song(id: songID) {
            SongMotionCoverPreview(song: song)
        } else {
            Color.secondary.opacity(0.15)
        }
    }
}
#endif
