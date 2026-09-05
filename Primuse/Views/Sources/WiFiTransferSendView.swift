#if os(iOS) || os(macOS)
import SwiftUI
import UniformTypeIdentifiers
import PrimuseKit

@MainActor @Observable
final class WiFiTransferSender {
    private(set) var selection: WiFiTransferSelection?
    private(set) var excluded: Set<String> = []
    private(set) var busy = false
    private(set) var status = ""
    private(set) var currentFile = ""
    private(set) var progress: Double = 0
    private(set) var completed = 0
    private(set) var failed: [WiFiTransferOutgoingFile] = []
    private(set) var failures: [String] = []
    private(set) var error: String?
    private(set) var destinationName = ""
    private(set) var preparationFailures: [String: String] = [:]
    private(set) var preparationWarnings: [String] = []
    private(set) var preparationDetail = ""
    var selectedSongIDs: Set<String> = [] {
        didSet { if selectedSongIDs != oldValue { clearPreparedMusic() } }
    }
    private var preparedMusic: WiFiTransferSelection?
    private var preparedVersions: [String: WiFiTransferLibraryPreparation.Version] = [:]
    private var songFiles: [String: Set<String>] = [:]
    private var songByFileID: [String: String] = [:]
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()

    var externalFiles: [WiFiTransferOutgoingFile] { selection?.files.filter { !excluded.contains($0.id) } ?? [] }
    var files: [WiFiTransferOutgoingFile] { externalFiles + (preparedMusic?.files ?? []) }
    var bytes: Int64 { files.reduce(0) { $0 + $1.size } }
    var addedSongIDs: Set<String> {
        let queued = Set(files.map(\.id))
        return Set(songFiles.filter { !$0.value.isDisjoint(with: queued) }.keys)
    }

    private func append(_ addition: WiFiTransferSelection) throws {
        if let selection {
            let retained = selection.keeping(Set(externalFiles.map(\.id)))
            self.selection = try retained.appending(addition, conflictFolder: WiFiTransferText.string("addMusic"))
        } else {
            selection = addition
        }
        excluded = []
        completed = 0
        failed = []
        failures = []
    }

    private func clearPreparedMusic() {
        preparedMusic = nil
        preparedVersions = [:]
        songFiles = [:]
        songByFileID = [:]
        preparationFailures = [:]
        preparationWarnings = []
        failed = []
        failures = []
        status = ""
        completed = 0
    }

    private func preparedMusicIsCurrent(library: MusicLibrary, sources: SourcesStore) -> Bool {
        preparedVersions.allSatisfy { id, version in
            guard let song = library.visibleSong(id: id), let source = sources.source(id: song.sourceID) else { return false }
            return WiFiTransferLibraryPreparation.Version(song: song, source: source) == version
        }
    }

    private func prepareSongs(library: MusicLibrary, sources: SourcesStore, sourceManager: SourceManager) async throws {
        if !preparedMusicIsCurrent(library: library, sources: sources) { clearPreparedMusic() }
        let ids = selectedSongIDs.subtracting(addedSongIDs).sorted()
        preparationFailures = preparationFailures.filter { selectedSongIDs.contains($0.key) }
        guard !ids.isEmpty else { return }
        status = "libraryPreparing"
        progress = 0
        preparationDetail = ""
        let result = try await WiFiTransferLibraryPreparation.prepare(
            songIDs: ids, library: library, sources: sources, sourceManager: sourceManager
        ) { [weak self] title, index, total, received, size in
            guard let self else { return }
            self.currentFile = title
            self.progress = min(1, (Double(index) + (size > 0 ? Double(received) / Double(size) : 0)) / Double(max(1, total)))
            self.preparationDetail = String(format: WiFiTransferText.string("libraryPreparationDetail"),
                                           min(index + 1, total), total,
                                           ByteCountFormatter.string(fromByteCount: received, countStyle: .file))
        }
        try Task.checkCancellation()
        if let preparedMusic {
            self.preparedMusic = try preparedMusic.appending(result.selection, conflictFolder: WiFiTransferText.string("addMusic"))
        } else { preparedMusic = result.selection }
        preparedVersions.merge(result.versions) { _, latest in latest }
        songFiles.merge(result.songFiles) { _, latest in latest }
        for (songID, fileIDs) in result.songFiles {
            for fileID in fileIDs { songByFileID[fileID] = songID }
        }
        for id in ids { preparationFailures[id] = nil }
        preparationFailures.merge(result.failures) { _, latest in latest }
        preparationWarnings = result.warnings
    }

    func choose(_ urls: [URL]) {
        guard !busy else { return }
        busy = true
        error = nil
        status = "preparing"
        task = Task {
            defer { busy = false; task = nil }
            do {
                let selection = try await WiFiTransferSelection.prepare(urls)
                try Task.checkCancellation()
                try append(selection)
                status = ""
                if selection.files.isEmpty { error = WiFiTransferText.string("emptySelection") }
            } catch {
                self.error = WiFiTransferText.error(error)
                status = error is CancellationError ? "cancelled" : ""
            }
        }
    }

    func remove(_ id: String) { excluded.insert(id) }

    func send(address: String, code: String, expectedPeerID: String?,
              library: MusicLibrary, sources: SourcesStore, sourceManager: SourceManager, retry: Bool = false) {
        guard !busy else { return }
        let retryFiles = failed
        guard !files.isEmpty || !selectedSongIDs.isEmpty else { return }
        let generation = UUID()
        self.generation = generation
        busy = true
        error = nil
        status = "waiting"
        completed = 0
        failed = []
        failures = []
        progress = 0
        task = Task {
            defer { busy = false; task = nil; currentFile = "" }
            var client: WiFiTransferClient?
            var ticket: String?
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("primuse-device-send-\(UUID().uuidString)")
            defer {
                try? FileManager.default.removeItem(at: directory)
                if let client, let ticket { Task { await client.finish(ticket) } }
            }
            var files: [WiFiTransferOutgoingFile] = []
            do {
                if !retry {
                    try await prepareSongs(library: library, sources: sources, sourceManager: sourceManager)
                    guard preparationFailures.isEmpty else { status = "failed"; return }
                }
                guard preparedMusicIsCurrent(library: library, sources: sources) else {
                    throw WiFiTransferLibraryPreparation.PreparationError.sourceChanged
                }
                let external = selection?.keeping(Set(externalFiles.map(\.id)))
                let combined: WiFiTransferSelection?
                if let external, let preparedMusic {
                    combined = try external.appending(preparedMusic, conflictFolder: WiFiTransferText.string("addMusic"))
                } else { combined = external ?? preparedMusic }
                let retryIDs = Set(retryFiles.map(\.id))
                files = combined?.files.filter { !retry || retryIDs.contains($0.id) } ?? []
                guard !files.isEmpty else { status = ""; return }
                try WiFiTransferFilePreparation.checkSpace(at: FileManager.default.temporaryDirectory,
                                                          additionalBytes: files.map(\.size).max() ?? 0)
                let connection = try WiFiTransferClient(address: address, code: code)
                client = connection
                let destination = try await connection.destination()
                if let expectedPeerID, destination.identity?.id != expectedPeerID { throw WiFiTransferError.unauthorized }
                destinationName = destination.identity?.name ?? address
                let total = files.reduce(Int64(0)) { $0 + $1.size }
                guard destination.availableBytes > total + 64 * 1024 * 1024 else { throw WiFiTransferError.notEnoughSpace }
                guard preparedMusicIsCurrent(library: library, sources: sources) else {
                    throw WiFiTransferLibraryPreparation.PreparationError.sourceChanged
                }
                let invitation = try await connection.invite(sender: WiFiTransferText.identity.name, fileCount: files.count, byteCount: total)
                ticket = invitation.id
                status = "waitingApproval"
                try await connection.waitForAcceptance(invitation.id)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                var sent: Int64 = 0
                for (index, file) in files.enumerated() {
                    try Task.checkCancellation()
                    currentFile = file.path
                    status = "preparing"
                    do {
                        if let songID = songByFileID[file.id] {
                            guard let song = library.visibleSong(id: songID),
                                  let source = sources.source(id: song.sourceID),
                                  let version = preparedVersions[songID],
                                  WiFiTransferLibraryPreparation.Version(song: song, source: source) == version else {
                                throw WiFiTransferLibraryPreparation.PreparationError.sourceChanged
                            }
                        }
                        let staged = try await WiFiTransferSelection.stage(file, in: directory)
                        defer { try? FileManager.default.removeItem(at: staged) }
                        try Task.checkCancellation()
                        status = "sending"
                        let preceding = sent
                        try await connection.upload(file: staged, path: file.path, size: file.size, ticket: invitation.id) { [weak self] bytes in
                            Task { @MainActor in
                                guard let self, self.generation == generation, self.busy else { return }
                                self.progress = Double(preceding + bytes) / Double(max(total, 1))
                            }
                        }
                        completed += 1
                    } catch {
                        if Task.isCancelled { throw CancellationError() }
                        failed.append(file)
                        failures.append(file.path + ": " + WiFiTransferText.error(error))
                        if !(error is WiFiTransferError) || (error as? WiFiTransferError) == .unauthorized
                            || (error as? WiFiTransferError) == .notEnoughSpace {
                            failed.append(contentsOf: files.dropFirst(index + 1))
                            throw error
                        }
                    }
                    sent += file.size
                    progress = Double(sent) / Double(max(total, 1))
                }
                status = "finished"
            } catch {
                status = Task.isCancelled ? "cancelled" : "failed"
                self.error = WiFiTransferText.error(error)
                if failed.isEmpty && !Task.isCancelled { failed = files }
            }
        }
    }

    func cancel() { task?.cancel() }
}

struct WiFiTransferSendView: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(SourcesStore.self) private var sources
    @Environment(SourceManager.self) private var sourceManager
    @Bindable var sender: WiFiTransferSender
    @State private var discovery = WiFiTransferDiscovery()
    @State private var address = ""
    @State private var code = ""
    @State private var expectedPeerID: String?
    @State private var showImporter = false
    @State private var pickFolder = false
    @State private var manualConnection = true
    @State private var pickerError: String?
    @State private var dropTargeted = false

    private var canSend: Bool { (!sender.files.isEmpty || !sender.selectedSongIDs.isEmpty) && code.count == 6 && !address.isEmpty && !sender.busy }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                if geometry.size.width >= 680 {
                    HStack(alignment: .top, spacing: 20) {
                        musicPane.frame(maxWidth: .infinity, maxHeight: .infinity)
                        ScrollView { devicePane.padding(.bottom, 12) }.frame(width: 260)
                    }.padding(18)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            musicPane.frame(height: max(380, geometry.size.height * 0.7))
                            devicePane
                        }.padding(16)
                    }
                }
            }
            footer
        }
        .foregroundStyle(TransferAppearance.text)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: pickFolder ? [.folder] : [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): pickerError = nil; sender.choose(urls)
            case .failure(let error): pickerError = WiFiTransferText.error(error)
            }
        }
        .onAppear { discovery.start() }
        .onDisappear { discovery.stop() }
    }

    private var musicPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TransferSectionHeading(title: String(localized: "sidebar_all_songs"))
                fileActions
            }
            WiFiTransferLibraryTree(selected: Binding(get: { sender.selectedSongIDs },
                                                       set: { if !sender.busy { sender.selectedSongIDs = $0 } }))
                .disabled(sender.busy)
                .frame(maxHeight: .infinity)
                .dropDestination(for: URL.self) { urls, _ in
                    guard !sender.busy else { return false }
                    sender.choose(urls)
                    return !urls.isEmpty
                } isTargeted: { dropTargeted = $0 }
                .overlay { if dropTargeted { RoundedRectangle(cornerRadius: 10).stroke(TransferAppearance.accent, lineWidth: 2) } }
            if !sender.externalFiles.isEmpty {
                DisclosureGroup("\(WiFiTransferText.string("files")) · \(sender.externalFiles.count)") {
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(sender.externalFiles) { file in
                                HStack(spacing: 8) {
                                    Image(systemName: fileIcon(file.path)).foregroundStyle(TransferAppearance.accent)
                                    Text(file.path).font(.caption).lineLimit(1).truncationMode(.middle)
                                    Spacer(minLength: 0)
                                    Button { sender.remove(file.id) } label: { Image(systemName: "xmark.circle") }
                                        .buttonStyle(.plain).disabled(sender.busy)
                                        .accessibilityLabel(WiFiTransferText.string("remove") + " " + file.path)
                                }
                            }
                        }
                    }.frame(maxHeight: 100)
                }.font(.callout)
            }
            if (sender.selection?.skipped ?? 0) > 0 {
                Text("\(WiFiTransferText.string("skipped")): \(sender.selection?.skipped ?? 0)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !sender.status.isEmpty { progressSummary }
            if let failure = sender.preparationFailures.values.sorted().first {
                TransferFeedback(text: failure, isError: true)
            }
            if let warning = sender.preparationWarnings.first {
                Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            if let error = sender.error ?? pickerError { TransferFeedback(text: error, isError: true) }
        }
    }

    private var fileActions: some View {
        Menu {
            Button { pickFolder = false; showImporter = true } label: {
                Label(WiFiTransferText.string("files"), systemImage: "doc.badge.plus")
            }
            Button { pickFolder = true; showImporter = true } label: {
                Label(WiFiTransferText.string("folder"), systemImage: "folder")
            }
        } label: {
            Label(WiFiTransferText.string("files"), systemImage: "plus")
                .font(.callout.weight(.semibold))
                #if os(iOS)
                .frame(minHeight: 28)
                #endif
        }
        #if os(macOS)
        .menuStyle(.borderlessButton)
        #endif
        .buttonStyle(TransferButtonStyle())
        .fixedSize(horizontal: true, vertical: false)
        .disabled(sender.busy)
        .accessibilityIdentifier("transfer.addMusic")
    }

    private var devicePane: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TransferSectionHeading(title: WiFiTransferText.string("nearby"))
                Button { discovery.start() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .medium))
                        .frame(width: TransferAppearance.compactTarget, height: TransferAppearance.compactTarget).contentShape(.rect)
                }.buttonStyle(.plain).disabled(sender.busy)
                    .accessibilityLabel(WiFiTransferText.string("refresh"))
            }
            VStack(spacing: 0) {
                if discovery.peers.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "laptopcomputer.and.iphone").font(.system(size: 20, weight: .regular))
                            .foregroundStyle(TransferAppearance.muted)
                        Text(WiFiTransferText.string("noDevices")).font(.system(size: TransferAppearance.bodySize, weight: .medium))
                        Text(WiFiTransferText.string("discoveryHint"))
                            .font(.system(size: TransferAppearance.captionSize))
                            .foregroundStyle(TransferAppearance.muted).multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }.padding(14).frame(maxWidth: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(discovery.peers) { peer in
                                Button {
                                    address = peer.address
                                    expectedPeerID = peer.id
                                    manualConnection = false
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: TransferAppearance.deviceIcon(peer.identity.platform))
                                            .font(.system(size: 25, weight: .light)).frame(width: 36)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(peer.identity.name).font(.system(size: TransferAppearance.bodySize, weight: .semibold)).lineLimit(1)
                                            Text(peer.identity.platform).font(.system(size: TransferAppearance.captionSize))
                                                .foregroundStyle(TransferAppearance.muted)
                                        }
                                        Spacer(minLength: 2)
                                        if expectedPeerID == peer.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(TransferAppearance.accent) }
                                    }.padding(12).frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                                        .background(expectedPeerID == peer.id ? TransferAppearance.accent.opacity(0.09) : .clear, in: .rect(cornerRadius: 8))
                                        .contentShape(.rect)
                                }.buttonStyle(.plain).disabled(sender.busy)
                            }
                        }.padding(6)
                    }.frame(height: min(CGFloat(discovery.peers.count) * 76 + 12, 180))
                }
            }
            .background(TransferAppearance.surface, in: .rect(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(TransferAppearance.line, lineWidth: 0.5) }

            DisclosureGroup(isExpanded: $manualConnection) {
                TextField("192.168.1.8:12345", text: $address)
                    .textFieldStyle(.plain).font(.system(size: TransferAppearance.bodySize))
                    .padding(10).background(TransferAppearance.surface, in: .rect(cornerRadius: 7))
                    .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(TransferAppearance.line, lineWidth: 1) }
                    .autocorrectionDisabled().disabled(sender.busy)
                    #if os(iOS)
                    .textInputAutocapitalization(.never).keyboardType(.URL)
                    #endif
                    .accessibilityLabel(WiFiTransferText.string("manualAddress"))
                    .padding(.top, 8)
                    .onChange(of: address) { _, value in
                        if !discovery.peers.contains(where: { $0.address == value && $0.id == expectedPeerID }) { expectedPeerID = nil }
                    }
            } label: {
                Text(WiFiTransferText.string("manualConnection")).font(.system(size: TransferAppearance.captionSize))
            }.tint(TransferAppearance.muted).disabled(sender.busy)

            VStack(alignment: .leading, spacing: 10) {
                Text(WiFiTransferText.string("code")).font(.system(size: TransferAppearance.bodySize, weight: .semibold))
                TextField("000000", text: $code)
                    .textFieldStyle(.plain).font(.system(size: 18, weight: .medium, design: .monospaced))
                    .tracking(3).multilineTextAlignment(.center)
                    .padding(.vertical, 10)
                    .background(TransferAppearance.background, in: .rect(cornerRadius: 8))
                    .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(TransferAppearance.line, lineWidth: 1) }
                    .disabled(sender.busy).accessibilityLabel(WiFiTransferText.string("code"))
                    #if os(iOS)
                    .keyboardType(.numberPad).textContentType(.oneTimeCode)
                    #endif
                    .onChange(of: code) { _, value in code = String(value.filter { $0.isASCII && $0.isNumber }.prefix(6)) }
                Text(WiFiTransferText.string("codeHint")).font(.system(size: TransferAppearance.captionSize))
                    .foregroundStyle(TransferAppearance.muted).fixedSize(horizontal: false, vertical: true)
            }.modifier(TransferSurface(padding: 14))
            if let error = discovery.error {
                Label(WiFiTransferText.string(error), systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var progressSummary: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                if sender.busy { ProgressView().controlSize(.small) }
                Text(WiFiTransferText.string(sender.status))
                Spacer()
                if !sender.busy && sender.completed + sender.failed.count > 0 && sender.status != "libraryPrepared" {
                    Text("\(sender.completed) / \(sender.completed + sender.failed.count)").monospacedDigit()
                }
            }.font(.system(size: TransferAppearance.bodySize, weight: .medium))
            if sender.busy && !sender.currentFile.isEmpty {
                Text(sender.currentFile).font(.system(size: TransferAppearance.captionSize))
                    .foregroundStyle(TransferAppearance.muted).lineLimit(1).truncationMode(.middle)
                ProgressView(value: sender.progress).tint(TransferAppearance.accent)
                if sender.status == "libraryPreparing" {
                    Text(sender.preparationDetail).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            ForEach(Array(sender.failures.prefix(3).enumerated()), id: \.offset) { _, failure in
                TransferFeedback(text: failure, isError: true)
            }
            if !sender.busy && !sender.failed.isEmpty {
                Button(WiFiTransferText.string("retry"), systemImage: "arrow.clockwise") {
                    sender.send(address: address, code: code, expectedPeerID: expectedPeerID,
                                library: library, sources: sources, sourceManager: sourceManager, retry: true)
                }.buttonStyle(TransferButtonStyle(compact: true)).disabled(code.count != 6 || address.isEmpty)
            }
        }.modifier(TransferSurface(padding: 14))
    }

    private var footer: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(String(format: WiFiTransferText.string("librarySelectedSummary"), sender.selectedSongIDs.count, sender.externalFiles.count))
                    .font(.system(size: TransferAppearance.captionSize, weight: .medium))
                if !sender.destinationName.isEmpty && sender.completed > 0 {
                    Text(sender.destinationName).font(.system(size: TransferAppearance.captionSize)).foregroundStyle(TransferAppearance.muted)
                }
            }.foregroundStyle(TransferAppearance.muted).lineLimit(2)
            Spacer(minLength: 4)
            if sender.busy {
                Button(WiFiTransferText.string("cancel")) { sender.cancel() }
                    .buttonStyle(TransferButtonStyle())
            } else {
                Button {
                    sender.send(address: address, code: code, expectedPeerID: expectedPeerID,
                                library: library, sources: sources, sourceManager: sourceManager)
                } label: {
                    Label(WiFiTransferText.string("sendNow"), systemImage: "paperplane.fill")
                }.buttonStyle(TransferButtonStyle(prominent: true))
                    .disabled(!canSend).accessibilityIdentifier("transfer.send")
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 14)
        .background(TransferAppearance.surface)
        .overlay(alignment: .top) { Rectangle().fill(TransferAppearance.line).frame(height: 0.5) }
    }

    private func fileIcon(_ path: String) -> String {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "lrc", "ttml": "text.alignleft"
        case "jpg", "jpeg", "png", "webp", "heic": "photo"
        case "cue": "list.bullet.rectangle"
        default: "music.note"
        }
    }
}

#endif
