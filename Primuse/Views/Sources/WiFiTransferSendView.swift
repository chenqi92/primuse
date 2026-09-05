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
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()

    var files: [WiFiTransferOutgoingFile] { selection?.files.filter { !excluded.contains($0.id) } ?? [] }
    var bytes: Int64 { files.reduce(0) { $0 + $1.size } }

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
                self.selection = selection
                excluded = []
                completed = 0
                failed = []
                failures = []
                status = ""
                if selection.files.isEmpty { error = WiFiTransferText.string("emptySelection") }
            } catch {
                self.error = WiFiTransferText.error(error)
                status = error is CancellationError ? "cancelled" : ""
            }
        }
    }

    func remove(_ id: String) { excluded.insert(id) }

    func send(address: String, code: String, expectedPeerID: String?, retry: Bool = false) {
        guard !busy else { return }
        let files = retry ? failed : self.files
        guard !files.isEmpty else { return }
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
            do {
                let connection = try WiFiTransferClient(address: address, code: code)
                client = connection
                let destination = try await connection.destination()
                if let expectedPeerID, destination.identity?.id != expectedPeerID { throw WiFiTransferError.unauthorized }
                destinationName = destination.identity?.name ?? address
                let total = files.reduce(Int64(0)) { $0 + $1.size }
                guard destination.availableBytes > total + 64 * 1024 * 1024 else { throw WiFiTransferError.notEnoughSpace }
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
    @Bindable var sender: WiFiTransferSender
    @State private var discovery = WiFiTransferDiscovery()
    @State private var address = ""
    @State private var code = ""
    @State private var expectedPeerID: String?
    @State private var showImporter = false
    @State private var pickFolder = false
    @State private var showLocalFiles = false
    @State private var manualConnection = false
    @State private var pickerError: String?
    @State private var dropTargeted = false

    private var canSend: Bool { !sender.files.isEmpty && code.count == 6 && !address.isEmpty && !sender.busy }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                ScrollView {
                    Group {
                        if geometry.size.width >= 680 {
                            HStack(alignment: .top, spacing: 22) {
                                filePane(headerHeight: TransferAppearance.compactTarget).frame(maxWidth: .infinity)
                                devicePane.frame(width: 280)
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 22) {
                                filePane()
                                devicePane
                            }
                        }
                    }
                    .padding(22)
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
        .sheet(isPresented: $showLocalFiles) { WiFiTransferLocalPicker { sender.choose($0) } }
        .onAppear { discovery.start() }
        .onDisappear { discovery.stop() }
    }

    private func filePane(headerHeight: CGFloat = 0) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            TransferSectionHeading(title: WiFiTransferText.string("sendFilesTitle"),
                detail: sender.files.isEmpty ? nil : "\(sender.files.count) · \(ByteCountFormatter.string(fromByteCount: sender.bytes, countStyle: .file))")
                .frame(minHeight: headerHeight)
            VStack(spacing: 0) {
                if sender.files.isEmpty {
                    VStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 18).fill(TransferAppearance.accent.opacity(0.08))
                                .frame(width: 84, height: 84).rotationEffect(.degrees(-9))
                            Image(systemName: "music.note")
                                .font(.system(size: 34, weight: .medium))
                                .foregroundStyle(TransferAppearance.accent)
                        }.padding(.top, 16)
                        Text(WiFiTransferText.string("drop")).font(.system(size: 17, weight: .semibold))
                        Text(WiFiTransferText.string("formats"))
                            .font(.system(size: TransferAppearance.captionSize))
                            .foregroundStyle(TransferAppearance.muted).multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        fileActions
                    }.padding(22).frame(maxWidth: .infinity, minHeight: 275)
                } else {
                    ScrollView(.vertical, showsIndicators: sender.files.count > 4) {
                        LazyVStack(spacing: 0) {
                            ForEach(sender.files) { file in
                                HStack(spacing: 12) {
                                    Image(systemName: fileIcon(file.path))
                                        .font(.system(size: 17)).foregroundStyle(TransferAppearance.accent)
                                        .frame(width: 30, height: 36)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(URL(fileURLWithPath: file.path).lastPathComponent)
                                            .font(.system(size: TransferAppearance.bodySize, weight: .medium)).lineLimit(1)
                                        Text(file.path.contains("/") ? file.path : ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                                            .font(.system(size: TransferAppearance.captionSize))
                                            .foregroundStyle(TransferAppearance.muted).lineLimit(1).truncationMode(.middle)
                                    }
                                    Spacer(minLength: 4)
                                    Button { sender.remove(file.id) } label: {
                                        Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                                            .frame(width: TransferAppearance.compactTarget, height: TransferAppearance.compactTarget).contentShape(.rect)
                                    }.buttonStyle(.plain).foregroundStyle(TransferAppearance.muted)
                                        .disabled(sender.busy).accessibilityLabel(WiFiTransferText.string("remove") + " " + file.path)
                                }.padding(.horizontal, 14).padding(.vertical, 7)
                                Rectangle().fill(TransferAppearance.line).frame(height: 0.5).padding(.leading, 56)
                            }
                        }
                    }.frame(height: min(CGFloat(sender.files.count) * (max(36, TransferAppearance.compactTarget) + 14.5), 235))
                    fileActions.padding(14)
                }
            }
            .background(TransferAppearance.surface, in: .rect(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(dropTargeted ? TransferAppearance.accent : TransferAppearance.line,
                                  style: StrokeStyle(lineWidth: dropTargeted ? 1.5 : 1, dash: sender.files.isEmpty ? [5, 5] : []))
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard !sender.busy else { return false }
                sender.choose(urls)
                return !urls.isEmpty
            } isTargeted: { dropTargeted = $0 }
            if (sender.selection?.skipped ?? 0) > 0 {
                Text("\(WiFiTransferText.string("skipped")): \(sender.selection?.skipped ?? 0)")
                    .font(.system(size: TransferAppearance.captionSize)).foregroundStyle(TransferAppearance.muted)
            }
            if !sender.status.isEmpty {
                progressSummary
            }
            if let error = sender.error ?? pickerError { TransferFeedback(text: error, isError: true) }
        }
    }

    private var fileActions: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Button { pickFolder = false; showImporter = true } label: {
                    Label(WiFiTransferText.string("files"), systemImage: "doc.badge.plus")
                }.buttonStyle(TransferButtonStyle(prominent: sender.files.isEmpty, compact: true))
                Button { pickFolder = true; showImporter = true } label: {
                    Label(WiFiTransferText.string("folder"), systemImage: "folder")
                }.buttonStyle(TransferButtonStyle(compact: true))
            }
            Button { showLocalFiles = true } label: {
                Label(WiFiTransferText.string("localFiles"), systemImage: "music.note.list")
                    .font(.system(size: TransferAppearance.captionSize, weight: .medium))
                    .foregroundStyle(TransferAppearance.accent)
                    .padding(.vertical, 4)
                    .frame(minHeight: TransferAppearance.compactTarget)
            }.buttonStyle(.plain)
        }.disabled(sender.busy).frame(maxWidth: .infinity)
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
                        Image(systemName: "wifi").font(.system(size: 26, weight: .light))
                            .foregroundStyle(TransferAppearance.muted)
                        Text(WiFiTransferText.string("noDevices")).font(.system(size: TransferAppearance.bodySize, weight: .medium))
                        Text(WiFiTransferText.string("discoveryHint"))
                            .font(.system(size: TransferAppearance.captionSize))
                            .foregroundStyle(TransferAppearance.muted).multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }.padding(18).frame(maxWidth: .infinity)
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
                    .textFieldStyle(.plain).font(.system(size: 24, weight: .medium, design: .monospaced))
                    .tracking(6).multilineTextAlignment(.center)
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
            if let error = discovery.error { TransferFeedback(text: WiFiTransferText.string(error), isError: true) }
        }
    }

    private var progressSummary: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                if sender.busy { ProgressView().controlSize(.small) }
                Text(WiFiTransferText.string(sender.status))
                Spacer()
                if !sender.busy { Text("\(sender.completed) / \(sender.completed + sender.failed.count)").monospacedDigit() }
            }.font(.system(size: TransferAppearance.bodySize, weight: .medium))
            if sender.busy && !sender.currentFile.isEmpty {
                Text(sender.currentFile).font(.system(size: TransferAppearance.captionSize))
                    .foregroundStyle(TransferAppearance.muted).lineLimit(1).truncationMode(.middle)
                ProgressView(value: sender.progress).tint(TransferAppearance.accent)
            }
            ForEach(Array(sender.failures.prefix(3).enumerated()), id: \.offset) { _, failure in
                TransferFeedback(text: failure, isError: true)
            }
            if !sender.busy && !sender.failed.isEmpty {
                Button(WiFiTransferText.string("retry"), systemImage: "arrow.clockwise") {
                    sender.send(address: address, code: code, expectedPeerID: expectedPeerID, retry: true)
                }.buttonStyle(TransferButtonStyle(compact: true)).disabled(code.count != 6 || address.isEmpty)
            }
        }.modifier(TransferSurface(padding: 14))
    }

    private var footer: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(sender.files.isEmpty ? WiFiTransferText.string("emptySelection") : "\(sender.files.count) · \(ByteCountFormatter.string(fromByteCount: sender.bytes, countStyle: .file))")
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
                    sender.send(address: address, code: code, expectedPeerID: expectedPeerID)
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

private struct WiFiTransferLocalPicker: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<URL> = []
    let onSelect: ([URL]) -> Void

    var body: some View {
        NavigationStack {
            WiFiTransferLocalFolder(folder: LocalImportService.ensureMusicDirectory(), selected: $selected)
                .navigationTitle(WiFiTransferText.string("localFiles"))
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button(WiFiTransferText.string("cancel")) { dismiss() }
                    .buttonStyle(TransferButtonStyle())
                Spacer()
                Button("\(WiFiTransferText.string("selected")) (\(selected.count))") {
                    onSelect(Array(selected)); dismiss()
                }
                .buttonStyle(TransferButtonStyle(prominent: true)).disabled(selected.isEmpty)
                .accessibilityIdentifier("transfer.confirmSelection")
            }.padding().background(.bar)
        }
        #if os(macOS)
        .frame(width: 620, height: 540)
        #endif
    }
}

private struct WiFiTransferLocalFolder: View {
    struct Entry: Identifiable, Sendable {
        let url: URL
        let folder: Bool
        var id: URL { url }
    }
    let folder: URL
    @Binding var selected: Set<URL>
    @State private var entries: [Entry] = []
    @State private var error: String?

    var body: some View {
        List {
            ForEach(entries) { entry in
                HStack {
                    Button {
                        if selected.contains(entry.url) { selected.remove(entry.url) } else { selected.insert(entry.url) }
                    } label: {
                        Image(systemName: selected.contains(entry.url) ? "checkmark.circle.fill" : "circle")
                    }.buttonStyle(.plain).accessibilityLabel(entry.url.lastPathComponent)
                    if entry.folder {
                        NavigationLink {
                            WiFiTransferLocalFolder(folder: entry.url, selected: $selected)
                                .navigationTitle(entry.url.lastPathComponent)
                        } label: { Label(entry.url.lastPathComponent, systemImage: "folder") }
                    } else { Text(entry.url.lastPathComponent) }
                }
            }
            if entries.isEmpty { Text(error ?? WiFiTransferText.string("emptySelection")).foregroundStyle(.secondary) }
        }
        .task(id: folder) {
            do {
                entries = try await Task.detached(priority: .utility) {
                    try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
                        .compactMap { url -> Entry? in
                            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                            guard values.isSymbolicLink != true else { return nil }
                            return Entry(url: url, folder: values.isDirectory == true)
                        }.sorted { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
                }.value
            } catch { self.error = WiFiTransferText.error(error) }
        }
    }
}
#endif
