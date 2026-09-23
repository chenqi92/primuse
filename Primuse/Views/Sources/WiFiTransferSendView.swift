#if os(iOS) || os(macOS)
import SwiftUI
import UniformTypeIdentifiers
import PrimuseKit

@MainActor @Observable
final class WiFiTransferSender {
    let libraryTree = TransferLibraryTreeModel()
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
    @State private var showConnection = false
    @State private var pickerError: String?
    @State private var dropTargeted = false
    @State private var isSearching = false

    private var canSend: Bool { (!sender.files.isEmpty || !sender.selectedSongIDs.isEmpty) && code.count == 6 && !address.isEmpty && !sender.busy }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                if geometry.size.width >= 680 {
                    HStack(alignment: .top, spacing: 20) {
                        musicPane(compact: false).frame(maxWidth: .infinity, maxHeight: .infinity)
                        ScrollView { devicePane }.frame(width: 250)
                    }
                    .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 12)
                } else {
                    VStack(spacing: 12) {
                        #if os(iOS)
                        if !isSearching { connectionSummary }
                        #endif
                        musicPane(compact: true).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .padding(.horizontal, 16).padding(.bottom, 12)
                }
            }
            #if os(macOS)
            footer
            #endif
        }
        .foregroundStyle(TransferAppearance.text)
        #if os(iOS)
        .toolbar { sendAction(library: library, sources: sources, sourceManager: sourceManager) }
        #endif
        .fileImporter(isPresented: $showImporter, allowedContentTypes: pickFolder ? [.folder] : [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): pickerError = nil; sender.choose(urls)
            case .failure(let error): pickerError = WiFiTransferText.error(error)
            }
        }
        #if os(iOS)
        .sheet(isPresented: $showConnection) { connectionSheet }
        #endif
        .onChange(of: address) { _, value in
            if !discovery.peers.contains(where: { $0.address == value && $0.id == expectedPeerID }) {
                expectedPeerID = nil
            }
        }
        .onAppear { discovery.start() }
        .onDisappear { discovery.stop() }
    }

    private func musicPane(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !compact || !isSearching {
            HStack {
                Text(String(localized: "sidebar_all_songs"))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                fileActions
            }
            }
            WiFiTransferLibraryTree(selected: Binding(get: { sender.selectedSongIDs },
                                                       set: { if !sender.busy { sender.selectedSongIDs = $0 } }),
                                    model: sender.libraryTree,
                                    onSearchFocusChange: { isSearching = $0 })
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
                .font(.subheadline)
                .frame(minHeight: TransferAppearance.compactTarget)
        }
        #if os(macOS)
        .menuStyle(.borderlessButton)
        #endif
        .buttonStyle(.plain)
        .foregroundStyle(TransferAppearance.accent)
        .fixedSize(horizontal: true, vertical: false)
        .disabled(sender.busy)
        .accessibilityIdentifier("transfer.addMusic")
    }

    private var selectedPeer: WiFiTransferPeer? {
        discovery.peers.first { $0.id == expectedPeerID }
    }

    private var refreshButton: some View {
        Button { discovery.start() } label: {
            Image(systemName: "arrow.clockwise")
                .font(.subheadline)
                .frame(width: TransferAppearance.compactTarget, height: TransferAppearance.compactTarget)
                .contentShape(.rect)
        }
        .buttonStyle(.plain).disabled(sender.busy)
        .accessibilityLabel(WiFiTransferText.string("refresh"))
    }

    private var devicePane: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(WiFiTransferText.string("receivingDevice")).font(.subheadline.weight(.semibold))
                Spacer()
                refreshButton
            }
            VStack(spacing: 0) {
                if discovery.peers.isEmpty {
                    Label(WiFiTransferText.string("noDevices"), systemImage: "laptopcomputer.and.iphone")
                        .font(.system(size: TransferAppearance.bodySize))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
                        .padding(.horizontal, 12)
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(discovery.peers) { peer in
                                peerButton(peer).padding(.horizontal, 12)
                                    .background(expectedPeerID == peer.id ? TransferAppearance.accent.opacity(0.08) : .clear)
                                if peer.id != discovery.peers.last?.id { Divider().padding(.leading, 46) }
                            }
                        }
                    }.frame(height: min(CGFloat(discovery.peers.count) * 58, 174))
                }
            }
            .background(TransferAppearance.surface, in: .rect(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(TransferAppearance.line, lineWidth: 0.5) }
            Text(WiFiTransferText.string("discoveryHint"))
                .font(.system(size: TransferAppearance.captionSize))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text(WiFiTransferText.string("manualAddress"))
                    .font(.system(size: TransferAppearance.captionSize)).foregroundStyle(.secondary)
                addressField.padding(.horizontal, 10).frame(minHeight: 36)
                    .background(TransferAppearance.surface, in: .rect(cornerRadius: 6))
                    .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(TransferAppearance.line, lineWidth: 0.5) }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(WiFiTransferText.string("code"))
                    .font(.system(size: TransferAppearance.captionSize)).foregroundStyle(.secondary)
                codeField.padding(.horizontal, 10).frame(minHeight: 36)
                    .background(TransferAppearance.surface, in: .rect(cornerRadius: 6))
                    .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(TransferAppearance.line, lineWidth: 0.5) }
                Text(WiFiTransferText.string("codeHint"))
                    .font(.system(size: TransferAppearance.captionSize)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            discoveryFeedback
        }
    }

    private func peerButton(_ peer: WiFiTransferPeer) -> some View {
        Button {
            address = peer.address
            expectedPeerID = peer.id
        } label: {
            HStack(spacing: 10) {
                Image(systemName: TransferAppearance.deviceIcon(peer.identity.platform))
                    .font(.title3).foregroundStyle(TransferAppearance.accent).frame(width: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text(peer.identity.name).font(.subheadline.weight(.medium)).lineLimit(1)
                    Text(peer.identity.platform).font(.caption).foregroundStyle(.secondary)
                }.foregroundStyle(TransferAppearance.text)
                Spacer(minLength: 4)
                if expectedPeerID == peer.id {
                    Image(systemName: "checkmark").font(.subheadline.weight(.semibold))
                        .foregroundStyle(TransferAppearance.accent)
                }
            }.frame(maxWidth: .infinity, minHeight: 58, alignment: .leading).contentShape(.rect)
        }.buttonStyle(.plain).disabled(sender.busy)
    }

    private var addressField: some View {
        TextField("192.168.1.8:12345", text: $address)
            .textFieldStyle(.plain).font(.subheadline)
            .autocorrectionDisabled().disabled(sender.busy)
            #if os(iOS)
            .textInputAutocapitalization(.never).keyboardType(.URL)
            #endif
            .accessibilityLabel(WiFiTransferText.string("manualAddress"))
            .accessibilityIdentifier("transfer.address")
    }

    private var codeField: some View {
        TextField("000000", text: $code)
            .textFieldStyle(.plain).font(.body.monospaced()).tracking(2)
            .disabled(sender.busy).accessibilityLabel(WiFiTransferText.string("code"))
            .accessibilityIdentifier("transfer.code")
            #if os(iOS)
            .keyboardType(.numberPad).textContentType(.oneTimeCode)
            #endif
            .onChange(of: code) { _, value in code = String(value.filter { $0.isASCII && $0.isNumber }.prefix(6)) }
    }

    @ViewBuilder private var discoveryFeedback: some View {
        if let error = discovery.error {
            Label(WiFiTransferText.string(error), systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        }
    }

    #if os(iOS)
    private var connectionSummary: some View {
        Button { showConnection = true } label: {
            HStack(spacing: 12) {
                Image(systemName: selectedPeer.map { TransferAppearance.deviceIcon($0.identity.platform) } ?? "laptopcomputer.and.iphone")
                    .font(.title3).foregroundStyle(TransferAppearance.accent).frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(address.isEmpty ? WiFiTransferText.string("chooseReceiver") : selectedPeer?.identity.name ?? address)
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                    Text(address.isEmpty ? WiFiTransferText.string("sameNetwork") : code.count == 6 ? WiFiTransferText.string("receivingDevice") : WiFiTransferText.string("codeHint"))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .background(TransferAppearance.surface, in: .rect(cornerRadius: 12))
            .contentShape(.rect)
        }
        .buttonStyle(.plain).disabled(sender.busy)
        .accessibilityIdentifier("transfer.receiver")
    }

    private var connectionSheet: some View {
        NavigationStack {
            SkinForm {
                Section {
                    if discovery.peers.isEmpty {
                        Label(WiFiTransferText.string("noDevices"), systemImage: "laptopcomputer.and.iphone")
                            .font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        ForEach(discovery.peers) { peer in peerButton(peer) }
                    }
                } header: {
                    HStack {
                        Text(WiFiTransferText.string("nearby"))
                        Spacer()
                        refreshButton
                    }
                } footer: {
                    Text(WiFiTransferText.string("discoveryHint"))
                }
                Section(WiFiTransferText.string("manualAddress")) { addressField }
                Section { codeField } header: {
                    Text(WiFiTransferText.string("code"))
                } footer: {
                    Text(WiFiTransferText.string("codeHint"))
                }
                discoveryFeedback
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(WiFiTransferText.string("receivingDevice"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(WiFiTransferText.string("done")) { showConnection = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
    #endif

    private var progressSummary: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                if sender.busy {
                    ProgressView().controlSize(.small)
                        .pmFadeTransition(motion: .contentAppear)
                }
                Text(WiFiTransferText.string(sender.status))
                Spacer()
                if !sender.busy && sender.completed + sender.failed.count > 0 && sender.status != "libraryPrepared" {
                    Text("\(sender.completed) / \(sender.completed + sender.failed.count)").monospacedDigit()
                        .pmFadeTransition(motion: .contentAppear)
                }
            }.font(.system(size: TransferAppearance.bodySize, weight: .medium))
            #if os(iOS)
            if !sender.destinationName.isEmpty && sender.completed > 0 {
                Text(sender.destinationName).font(.system(size: TransferAppearance.captionSize))
                    .foregroundStyle(TransferAppearance.muted).lineLimit(1)
            }
            #endif
            if sender.busy && !sender.currentFile.isEmpty {
                Text(sender.currentFile).font(.system(size: TransferAppearance.captionSize))
                    .foregroundStyle(TransferAppearance.muted).lineLimit(1).truncationMode(.middle)
                    .pmFadeTransition(motion: .contentAppear)
                ProgressView(value: sender.progress).tint(TransferAppearance.accent)
                    .pmFadeTransition(motion: .contentAppear)
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
                    .pmFadeTransition(motion: .contentAppear)
            }
        }.modifier(TransferSurface(padding: 14))
    }

    #if os(macOS)
    private var footer: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(String(format: WiFiTransferText.string("librarySelectedSummary"), sender.selectedSongIDs.count, sender.externalFiles.count))
                    .font(.caption.weight(.medium))
                if !sender.destinationName.isEmpty && sender.completed > 0 {
                    Text(sender.destinationName).font(.system(size: TransferAppearance.captionSize)).foregroundStyle(TransferAppearance.muted)
                }
            }.foregroundStyle(TransferAppearance.muted).lineLimit(2)
            Spacer(minLength: 4)
            if sender.busy {
                Button(WiFiTransferText.string("cancel")) { sender.cancel() }
                    .buttonStyle(TransferButtonStyle())
                    .pmAppearFade(.contentAppear)
            } else {
                Button {
                    sender.send(address: address, code: code, expectedPeerID: expectedPeerID,
                                library: library, sources: sources, sourceManager: sourceManager)
                } label: {
                    Label(WiFiTransferText.string("sendNow"), systemImage: "paperplane.fill")
                }.buttonStyle(TransferButtonStyle(prominent: true))
                    .disabled(!canSend).accessibilityIdentifier("transfer.send")
                    .keyboardShortcut(.defaultAction)
                    .pmAppearFade(.contentAppear)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(TransferAppearance.surface)
        .overlay(alignment: .top) { Rectangle().fill(TransferAppearance.line).frame(height: 0.5) }
    }
    #endif

    #if os(iOS)
    /// 主操作放导航栏右上角。模型按值传入：工具栏内容在自己的 bar item
    /// 视图图里求值,读 @Environment 会在转场期间 trap。
    @ToolbarContentBuilder
    private func sendAction(library: MusicLibrary, sources: SourcesStore,
                            sourceManager: SourceManager) -> some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            if sender.busy {
                Button(WiFiTransferText.string("cancel")) { sender.cancel() }
            } else {
                Button(WiFiTransferText.string("sendNow")) {
                    sender.send(address: address, code: code, expectedPeerID: expectedPeerID,
                                library: library, sources: sources, sourceManager: sourceManager)
                }
                .fontWeight(.semibold)
                .disabled(!canSend)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("transfer.send")
            }
        }
    }
    #endif

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
