#if os(iOS) || os(macOS)
import SwiftUI
import UniformTypeIdentifiers
import PrimuseKit
#if os(iOS)
import UIKit
#else
import AppKit
#endif

extension UTType {
    static let primuseShare = UTType(exportedAs: "com.welape.primuse.listening-share", conformingTo: .data)
}

struct ListeningShareFile: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .primuseShare) { SentTransferredFile($0.url) }
    }
}

struct ListeningShareJSONFile: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .json) { SentTransferredFile($0.url) }
    }
}

private enum ListeningShareClipboard {
    static func copy(_ value: String) {
        #if os(iOS)
        UIPasteboard.general.string = value
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        #endif
    }
}

struct ListeningShareExportView: View {
    let selection: ListeningShareSelection
    @Environment(\.dismiss) private var dismiss
    private enum Method { case offline, online }
    private struct PreparationOptions: Hashable {
        let includeSettings: Bool
        let publicSharing: Bool
    }
    private var preparationOptions: PreparationOptions {
        PreparationOptions(includeSettings: includeSettings, publicSharing: method == .online &&
            (!selection.stations.isEmpty || !selection.podcasts.isEmpty || selection.bookURL != nil))
    }
    @State private var method: Method = .offline
    @State private var copiedCode = false
    @State private var includeSettings: Bool
    @State private var export: ListeningShareService.Export?
    @State private var preparationID = UUID()
    @State private var preparing = false
    @State private var uploading = false
    @State private var progress = 0.0
    @State private var error: String?
    @State private var skippedItems: [String] = []
    @State private var publicURL: URL?
    @State private var lifetime = 24
    @State private var password = ""
    @State private var nearby = false
    @State private var uploadTask: Task<Void, Never>?

    init(selection: ListeningShareSelection) {
        self.selection = selection
        _includeSettings = State(initialValue: selection.settings)
    }
    private func t(_ key: String) -> String { ListeningShareText.string(key) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(selection.title).font(.headline)
                    if !selection.stations.isEmpty { Label("\(export?.package.stations.count ?? selection.stations.count) " + t("stations"), systemImage: "dot.radiowaves.left.and.right") }
                    if !selection.podcasts.isEmpty { Label("\(export?.package.podcasts.count ?? selection.podcasts.count) " + t("podcasts"), systemImage: "mic") }
                    if !selection.bookSongs.isEmpty || selection.bookURL != nil { Label(t("audiobook"), systemImage: "book") }
                    if !selection.settings {
                        Toggle(t("includeSettings"), isOn: $includeSettings).disabled(uploading)
                    }
                }
                Picker(t("shareMethod"), selection: $method) {
                    Text(t("offlineCode")).tag(Method.offline)
                    Text(t("onlineCode")).tag(Method.online)
                }
                .pickerStyle(.segmented)
                .disabled(uploading)
                .accessibilityIdentifier("sharing.method")
                if preparing || uploading {
                    Section { ProgressView(uploading ? t("uploading") : t("preparing"), value: progress) }
                }
                if let export, !preparing {
                    if method == .offline {
                        Section {
                            if let code = export.offlineCode {
                                copyCodeButton(code)
                            } else {
                                Text(t(export.codeError == .requiresFile ? "codeNeedsFile" : "codeTooLarge"))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Section {
                            Picker(t("lifetime"), selection: $lifetime) {
                                Text(t("oneDay")).tag(24)
                                Text(t("sevenDays")).tag(168)
                                Text(t("untilRevoked")).tag(0)
                            }.disabled(uploading || publicURL != nil)
                            SecureField(t("passwordOptional"), text: $password).disabled(uploading || publicURL != nil)
                            if let publicURL {
                                ListeningSharePublishedLinkView(url: publicURL, title: selection.title)
                            } else {
                                Button(t("createOnlineCode")) { upload(export) }.disabled(uploading)
                                    .accessibilityIdentifier("sharing.createOnlineCode")
                            }
                        }
                    }
                    Section {
                        if let json = export.jsonURL {
                            ShareLink(item: ListeningShareJSONFile(url: json), preview: SharePreview(selection.title)) {
                                Label(t("exportJSON"), systemImage: "doc.text")
                            }
                            .accessibilityIdentifier("sharing.exportJSON")
                        }
                        ShareLink(item: ListeningShareFile(url: export.url), preview: SharePreview(selection.title)) {
                            Label(t("shareFile"), systemImage: "square.and.arrow.up")
                        }
                        Button { nearby = true } label: { Label(t("nearby"), systemImage: "wifi") }
                    }.disabled(uploading)
                }
                if !skippedItems.isEmpty {
                    Section {
                        DisclosureGroup(String(format: t("skippedItems"), skippedItems.count)) {
                            ForEach(Array(skippedItems.enumerated()), id: \.offset) { Text($0.element) }
                        }
                        .accessibilityIdentifier("sharing.skippedItems")
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red).textSelection(.enabled) } }
            }
            .formStyle(.grouped)
            .navigationTitle(t("share"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(uploading ? t("cancel") : t("done")) {
                        if uploading { uploadTask?.cancel() } else { dismiss() }
                    }
                }
            }
            .sheet(isPresented: $nearby) { if let export { ListeningShareNearbyView(export: export) } }
        }
        .frame(minWidth: 320, idealWidth: 560, minHeight: 400, idealHeight: 660)
        .interactiveDismissDisabled(uploading)
        .task(id: preparationOptions) { await prepare() }
        .onChange(of: method) { _, _ in copiedCode = false }
        .onDisappear {
            uploadTask?.cancel()
            if let export { try? FileManager.default.removeItem(at: export.directory) }
        }
    }

    private func copyCodeButton(_ code: String) -> some View {
        Button {
            ListeningShareClipboard.copy(code)
            copiedCode = true
        } label: {
            Label(t(copiedCode ? "copied" : "copyCode"), systemImage: copiedCode ? "checkmark" : "doc.on.doc")
        }
        .accessibilityIdentifier("sharing.copyCode")
    }

    private func prepare() async {
        let id = UUID(); preparationID = id
        preparing = true; error = nil; publicURL = nil; copiedCode = false; progress = 0; skippedItems = []
        if let export { try? FileManager.default.removeItem(at: export.directory) }; export = nil
        defer { if preparationID == id { preparing = false } }
        do {
            let prepared = try await ListeningShareService.prepare(selection, includeSettings: includeSettings, publicSharing: preparationOptions.publicSharing) { value in
                if preparationID == id { progress = value }
            }
            if Task.isCancelled || preparationID != id { try? FileManager.default.removeItem(at: prepared.directory); return }
            export = prepared
            skippedItems = prepared.skippedItems
        } catch is CancellationError { }
        catch let failure as ListeningShareService.NoShareableContent {
            if preparationID == id {
                skippedItems = failure.skippedItems
                error = t("nothingShareable")
            }
        } catch { if preparationID == id { self.error = ListeningShareText.error(error) } }
    }
    private func upload(_ export: ListeningShareService.Export) {
        uploading = true; error = nil; progress = 0
        uploadTask = Task {
            defer { uploading = false; uploadTask = nil }
            do {
                publicURL = try await ListeningShareRelay.upload(export,
                    expiresAt: lifetime == 0 ? nil : Date().addingTimeInterval(Double(lifetime) * 3600), password: password) { progress = $0 }
                password = ""
            } catch { self.error = ListeningShareText.error(error) }
        }
    }
}

struct ListeningShareLinkButton: View {
    let url: URL
    let title: String
    private var shareText: String { title + "\n" + url.absoluteString }
    #if os(iOS)
    @State private var sharing = false
    #endif

    var body: some View {
        #if os(iOS)
        Button { sharing = true } label: {
            Label(ListeningShareText.string("shareLink"), systemImage: "link")
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier("sharing.shareLink")
        .sheet(isPresented: $sharing) { ShareSheet(items: [shareText]) }
        #else
        ShareLink(item: shareText, subject: Text(verbatim: title)) {
            Label(ListeningShareText.string("shareLink"), systemImage: "link")
        }
        #endif
    }
}

struct ListeningSharePublishedLinkView: View {
    let url: URL
    let title: String
    @State private var copied = false

    var body: some View {
        if let code = try? ListeningShareCode.networkCode(for: url) {
            Button {
                ListeningShareClipboard.copy(code)
                copied = true
            } label: {
                Label(ListeningShareText.string(copied ? "copied" : "copyCode"),
                      systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("sharing.copyCode")
            Text(code).font(.caption.monospaced()).textSelection(.enabled)
        }
        ListeningShareLinkButton(url: url, title: title)
        MediaRelayQRCodeView(value: (try? ListeningShareCode.appImportURL(for: url))?.absoluteString ?? url.absoluteString)
            .frame(maxWidth: .infinity)
            .accessibilityLabel(ListeningShareText.string("importShare"))
    }
}

struct ListeningShareCodeImportRequest: Identifiable {
    let id = UUID()
    let reference: ListeningShareCode.NetworkReference

    init?(url: URL) {
        guard let reference = try? ListeningShareCode.networkReference(appImportURL: url) else { return nil }
        self.reference = reference
    }
}

#if DEBUG && os(iOS)
struct ListeningShareEvidenceHost: View {
    @State private var presented = false
    private let url = URL(string: "https://share.example.invalid/s/123456#k=" + String(repeating: "A", count: 43))!

    var body: some View {
        Button(ListeningShareText.string("shareLink")) { presented = true }
            .accessibilityIdentifier("sharing.test.open")
            .sheet(isPresented: $presented) {
                if ProcessInfo.processInfo.environment["PRIMUSE_SHARE_TEST_BATCH"] == "1" {
                    ListeningShareExportView(selection: .init(title: "电台", stations: [
                        RadioStation(name: "公开电台", streamURL: "https://radio.example.org/live?token=public&key=channel",
                                     remoteLogoURL: "https://user:secret@radio.example.org/logo.png"),
                        RadioStation(name: "内网电台", streamURL: "http://192.168.1.2/live"),
                        RadioStation(name: "异常电台", streamURL: "file:///private/radio.mp3")
                    ]))
                } else {
                    NavigationStack {
                        Form {
                            Section { ListeningSharePublishedLinkView(url: url, title: "Radio sharing") }
                        }
                        .navigationTitle(ListeningShareText.string("share"))
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("done") { presented = false }
                            }
                        }
                    }
                }
            }
    }
}
#endif

struct ListeningShareImportView: View {
    let incoming: ListeningShareCoordinator.Incoming
    @Environment(\.dismiss) private var dismiss
    @State private var stations: Set<Int>
    @State private var podcasts: Set<Int>
    @State private var books: Set<Int>
    @State private var applySettings = false
    @State private var replaceExisting = false
    @State private var busy = false
    @State private var result: ListeningShareService.ImportResult?
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    private var package: ListeningSharePackage { incoming.contents.package }
    private func t(_ key: String) -> String { ListeningShareText.string(key) }

    init(incoming: ListeningShareCoordinator.Incoming) {
        self.incoming = incoming
        _stations = State(initialValue: Set(incoming.contents.package.stations.indices))
        _podcasts = State(initialValue: Set(incoming.contents.package.podcasts.indices))
        _books = State(initialValue: Set(incoming.contents.package.books.indices))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section { Text(package.title).font(.headline) }
                if let result {
                    Section {
                        Label(String(format: t("importResult"), result.added, result.skipped), systemImage: "checkmark.circle")
                        ForEach(Array(result.failures.enumerated()), id: \.offset) { Text($0.element).foregroundStyle(.red) }
                    }
                } else {
                    if !package.stations.isEmpty {
                        Section(t("stations")) {
                            ForEach(package.stations.indices, id: \.self) { index in
                                Toggle(isOn: selected(index, in: $stations)) {
                                    HStack {
                                        if let logo = package.stations[index].logo, let image = PlatformImage(data: logo) {
                                            Image(platformImage: image).resizable().scaledToFit().frame(width: 36, height: 36)
                                        }
                                        Text(package.stations[index].name)
                                    }
                                }
                            }
                        }
                    }
                    if !package.podcasts.isEmpty {
                        Section(t("podcasts")) {
                            ForEach(package.podcasts.indices, id: \.self) { index in
                                Toggle(package.podcasts[index].title, isOn: selected(index, in: $podcasts))
                            }
                        }
                    }
                    if !package.books.isEmpty {
                        Section(t("audiobooks")) {
                            ForEach(package.books.indices, id: \.self) { index in
                                Toggle(package.books[index].title, isOn: selected(index, in: $books))
                            }
                        }
                    }
                    Section {
                        if !package.settings.isEmpty { Toggle(t("applySettings"), isOn: $applySettings) }
                        if !package.stations.isEmpty || !package.podcasts.isEmpty { Toggle(t("replaceExisting"), isOn: $replaceExisting) }
                        Button(t("import")) { apply() }
                            .disabled(stations.isEmpty && podcasts.isEmpty && books.isEmpty && !applySettings)
                    }
                }
                if busy { Section { ProgressView(t("importing")) } }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .formStyle(.grouped).disabled(busy)
            .navigationTitle(t("importPreview"))
            .toolbar { ToolbarItem(placement: .cancellationAction) {
                Button(busy ? t("cancel") : t("done")) { if busy { task?.cancel() } else { dismiss() } }
            } }
        }
        .frame(minWidth: 320, idealWidth: 560, minHeight: 400, idealHeight: 660)
        .interactiveDismissDisabled(busy)
        .onDisappear { task?.cancel(); ListeningShareCoordinator.shared.discard(incoming) }
    }

    private func selected(_ index: Int, in set: Binding<Set<Int>>) -> Binding<Bool> {
        Binding(get: { set.wrappedValue.contains(index) }, set: { selected in
            if selected { set.wrappedValue.insert(index) } else { set.wrappedValue.remove(index) }
        })
    }
    private func apply() {
        busy = true; error = nil
        let options = ListeningShareService.ImportOptions(stationIndices: stations, podcastIndices: podcasts,
            bookIndices: books, settings: applySettings, replaceExisting: replaceExisting)
        task = Task {
            defer { busy = false; task = nil }
            do { result = try await ListeningShareService.apply(incoming.contents, options: options) }
            catch { self.error = ListeningShareText.error(error) }
        }
    }
}

struct ListeningShareNearbyView: View {
    let export: ListeningShareService.Export
    @Environment(\.dismiss) private var dismiss
    @State private var discovery = WiFiTransferDiscovery(serviceType: "_primuse-share._tcp")
    @State private var peer: WiFiTransferPeer?
    @State private var address = ""
    @State private var code = ""
    @State private var busy = false
    @State private var sent = false
    @State private var progress = 0.0
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    private func t(_ key: String) -> String { ListeningShareText.string(key) }

    var body: some View {
        NavigationStack {
            Form {
                Section(t("devices")) {
                    ForEach(discovery.peers) { device in
                        Button {
                            peer = device; address = device.address; sent = false
                        } label: {
                            HStack { Text(device.identity.name); Spacer(); if peer?.id == device.id { Image(systemName: "checkmark") } }
                        }
                    }
                    if discovery.peers.isEmpty { Text(t("openReceive")) }
                    if let failure = discovery.error { Text(WiFiTransferText.string(failure)).foregroundStyle(.red) }
                }
                Section {
                    TextField(t("address"), text: $address).onChange(of: address) { _, value in
                        if peer?.address != value { peer = nil }
                    }
                    TextField(t("code"), text: $code)
                    Button(t("send")) { send() }.disabled(code.count != 6 || address.isEmpty || sent)
                }
                if busy { ProgressView(t("sending"), value: progress) }
                if sent { Label(t("sent"), systemImage: "checkmark.circle") }
                if let error { Text(error).foregroundStyle(.red) }
            }.formStyle(.grouped).disabled(busy)
            .navigationTitle(t("nearby"))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(busy ? t("cancel") : t("done")) { task?.cancel(); dismiss() } } }
        }
        .frame(minWidth: 320, idealWidth: 520, minHeight: 400)
        .task { discovery.start() }
        .onDisappear { task?.cancel(); discovery.stop() }
    }

    private func send() {
        busy = true; error = nil; progress = 0
        let expectedID = peer?.id
        task = Task {
            defer { busy = false; task = nil }
            var client: WiFiTransferClient?
            var ticket: String?
            do {
                let connection = try WiFiTransferClient(address: address, code: code)
                client = connection
                let destination = try await connection.destination()
                if let expectedID, destination.identity?.id != expectedID { throw WiFiTransferError.unavailable }
                guard destination.identity?.supportsListeningShares == true else { throw ListeningShareError.unsupportedVersion }
                let size = Int64(try export.url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
                let invitation = try await connection.invite(sender: WiFiTransferText.identity.name, fileCount: 1, byteCount: size)
                ticket = invitation.id
                try await connection.waitForAcceptance(invitation.id)
                try await connection.upload(file: export.url, path: "Share-\(UUID().uuidString).primuseshare", size: size,
                    ticket: invitation.id) { bytes in Task { @MainActor in progress = Double(bytes) / Double(max(1, size)) } }
                sent = true
            } catch { self.error = WiFiTransferText.error(error) }
            if let client, let ticket { await Task.detached { await client.finish(ticket) }.value }
        }
    }
}

struct ListeningShareReceiveView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var receiver = WiFiTransferReceiver()
    @State private var visible = false
    @State private var directory: URL?
    @State private var incoming: ListeningShareCoordinator.Incoming?
    @State private var error: String?
    private func t(_ key: String) -> String { ListeningShareText.string(key) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(WiFiTransferText.identity.name).font(.headline)
                    Text(receiver.code).font(.largeTitle.monospaced()).textSelection(.enabled)
                    if let address = receiver.address { Text(address).textSelection(.enabled) }
                }
                if let invitation = receiver.invitation {
                    Section {
                        Text(invitation.sender)
                        Button(t("accept")) { receiver.allow(true) }
                        Button(t("decline"), role: .cancel) { receiver.allow(false) }
                    }
                }
                if receiver.hasActiveTransfers { ProgressView(value: receiver.progress) }
                if let error { Text(error).foregroundStyle(.red) }
                if let failure = receiver.error { Text(WiFiTransferText.string(failure)).foregroundStyle(.red) }
            }.formStyle(.grouped)
            .navigationTitle(t("receive"))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(t("done")) { dismiss() } } }
            .sheet(item: $incoming, onDismiss: { if visible, scenePhase == .active { start() } }) { ListeningShareImportView(incoming: $0) }
        }
        .frame(minWidth: 320, idealWidth: 520, minHeight: 400)
        .task { visible = true; start() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { receiver.stop() }
            else if phase == .active, incoming == nil { start() }
        }

        .onChange(of: receiver.stopping) { _, stopping in
            if !stopping, visible, scenePhase == .active, incoming == nil { start() }
        }
        .onDisappear {
            visible = false
            receiver.stop()
            let currentReceiver = receiver
            let ownedDirectory = directory
            Task { @MainActor in
                while currentReceiver.running || currentReceiver.stopping { try? await Task.sleep(for: .milliseconds(100)) }
                if let ownedDirectory { try? FileManager.default.removeItem(at: ownedDirectory) }
            }
        }
    }

    private func start() {
        guard !receiver.running, !receiver.stopping else { return }
        let root = directory ?? FileManager.default.temporaryDirectory.appendingPathComponent("primuse-share-receive-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            directory = root
            receiver.start(root: root, identity: .init(id: WiFiTransferText.identity.id, name: WiFiTransferText.identity.name,
                platform: WiFiTransferText.identity.platform, supportsListeningShares: true), page: WiFiTransferText.page) { path, deleted in
                guard !deleted, path.lowercased().hasSuffix(".primuseshare") else { return }
                Task {
                    do { incoming = try await ListeningShareCoordinator.shared.stage(root.appendingPathComponent(path)) }
                    catch { self.error = ListeningShareText.error(error) }
                    receiver.stop()
                }
            }
        } catch { self.error = ListeningShareText.error(error) }
    }
}

struct ListeningShareMenu: View {
    enum Scope: String { case settings, stations, podcasts, audiobooks }
    let scope: Scope
    var selection: ListeningShareSelection?
    @State private var outgoing: ListeningShareSelection?
    @State private var importFile = false
    @State private var importsCode = false
    @State private var receive = false
    @State private var managesLinks = false
    @State private var sharesBookLink = false
    @State private var incoming: ListeningShareCoordinator.Incoming?
    @State private var backupAction: OfflineSettingsBackupAction?
    @State private var error: String?

    private var canShare: Bool {
        guard let selection else { return false }
        return selection.settings || !selection.stations.isEmpty || !selection.podcasts.isEmpty
            || !selection.bookSongs.isEmpty || selection.bookURL != nil
    }

    var body: some View {
        Menu {
            if scope == .settings {
                Button("settings_backup_export", systemImage: "square.and.arrow.up") { backupAction = .export }
                    .accessibilityIdentifier("settings.backup.export")
                Button("settings_backup_import", systemImage: "square.and.arrow.down") { backupAction = .import }
                    .accessibilityIdentifier("settings.backup.import")
                Divider()
            }
            if selection != nil {
                Button(ListeningShareText.string(scope == .settings ? "shareSettings" : "share"), systemImage: "square.and.arrow.up") {
                    outgoing = selection
                }.disabled(!canShare)
            }
            if scope == .audiobooks {
                Button(ListeningShareText.string("shareBookLink"), systemImage: "link") { sharesBookLink = true }
            }
            if scope != .settings {
                Button(ListeningShareText.string("importFile"), systemImage: "square.and.arrow.down") { importFile = true }
            }
            Button(ListeningShareText.string("importCode"), systemImage: "text.badge.plus") { importsCode = true }
                .accessibilityIdentifier("sharing.importCode")
            Button(ListeningShareText.string("receive"), systemImage: "wifi") { receive = true }
            Divider()
            Button(ListeningShareText.string("managedLinks"), systemImage: "link") { managesLinks = true }
        } label: {
            Label(ListeningShareText.string("hub"), systemImage: "square.and.arrow.up")
        }
        .accessibilityIdentifier("sharing.menu." + scope.rawValue)
        .sheet(item: $outgoing) { ListeningShareExportView(selection: $0) }
        .sheet(isPresented: $receive) { ListeningShareReceiveView() }
        .sheet(isPresented: $importsCode) { ListeningShareCodeImportView() }
        .sheet(isPresented: $managesLinks) { ListeningShareLinksView() }
        .sheet(isPresented: $sharesBookLink) { ListeningShareBookLinkView() }
        .sheet(item: $incoming) { ListeningShareImportView(incoming: $0) }
        .offlineSettingsBackup(action: $backupAction)
        .fileImporter(isPresented: $importFile, allowedContentTypes: [.primuseShare, .json, .data]) { result in
            switch result {
            case .success(let url):
                Task {
                    do { incoming = try await ListeningShareCoordinator.shared.stage(url) }
                    catch { self.error = ListeningShareText.error(error) }
                }
            case .failure(let failure): error = ListeningShareText.error(failure)
            }
        }
        .alert(ListeningShareText.string("hub"), isPresented: Binding(
            get: { error != nil }, set: { if !$0 { error = nil } }
        )) { Button("ok", role: .cancel) {} } message: { Text(error ?? "") }
    }
}

struct ListeningShareCodeImportView: View {
    @Environment(\.dismiss) private var dismiss
    private let scannedReference: ListeningShareCode.NetworkReference?
    @State private var text: String
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @State private var incoming: ListeningShareCoordinator.Incoming?
    @State private var remote: MediaRelayImportRequest?
    @State private var task: Task<Void, Never>?
    @State private var started = false
    @State private var needsPassword = false

    init(reference: ListeningShareCode.NetworkReference? = nil) {
        scannedReference = reference
        _text = State(initialValue: reference?.shareURL.absoluteString ?? "")
    }

    private var reference: ListeningShareCode.NetworkReference? { try? ListeningShareCode.networkReference(text) }
    private var input: Binding<String> {
        Binding(get: { text }, set: { value in
            guard value.utf8.count <= ListeningShareCode.maximumCharacters * 2 else {
                error = ListeningShareText.string("codeError.tooLarge"); return
            }
            if text != value { password = "" }
            text = value; error = nil
        })
    }

    var body: some View {
        NavigationStack {
            Form {
                if scannedReference == nil {
                    Section {
                        TextEditor(text: input)
                            .font(.body.monospaced())
                            .frame(minHeight: 120, maxHeight: 240)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                            .accessibilityLabel(ListeningShareText.string("importCode"))
                            .accessibilityIdentifier("sharing.code.input")
                        PasteButton(payloadType: String.self) { if let value = $0.first { input.wrappedValue = value } }
                            .accessibilityIdentifier("sharing.code.paste")
                    }
                }
                if let reference {
                    Section {
                        Label(reference.origin.host ?? "", systemImage: "network")
                        if scannedReference == nil || needsPassword {
                            SecureField(needsPassword ? String(localized: "password") : ListeningShareText.string("passwordOptional"), text: $password)
                                .accessibilityIdentifier("sharing.code.password")
                        }
                    }
                }
                if busy { ProgressView() }
                Button(ListeningShareText.string("importPreview")) { importCode() }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
                    .accessibilityIdentifier("sharing.code.preview")
                if let error { Text(error).foregroundStyle(.red) }
            }
            .disabled(busy)
            .formStyle(.grouped)
            .navigationTitle(ListeningShareText.string(scannedReference == nil ? "importCode" : "importShare"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("cancel") { task?.cancel(); dismiss() }
                }
            }
        }
        .frame(minWidth: 320, idealWidth: 560, minHeight: 400)
        .sheet(item: $incoming) { ListeningShareImportView(incoming: $0) }
        .sheet(item: $remote) { MediaRelayImportSheet(request: $0, automaticallyDownload: true) }
        .task {
            if scannedReference != nil, !started {
                started = true
                importCode()
            }
        }
        .onDisappear { task?.cancel() }
    }

    private func importCode() {
        busy = true; error = nil
        let value = text
        let passphrase = password
        task = Task {
            defer { busy = false; task = nil }
            do {
                let code = try ListeningShareCode.normalized(value)
                if code.hasPrefix(ListeningShareCode.offlinePrefix) {
                    incoming = try await ListeningShareCoordinator.shared.stage(code: code)
                } else {
                    let reference = try ListeningShareCode.networkReference(code)
                    let url = try await ListeningShareCodeResolver.resolve(reference, password: passphrase)
                    try Task.checkCancellation()
                    var deepLink = URLComponents()
                    deepLink.scheme = "primuse"; deepLink.host = "import-share"
                    deepLink.queryItems = [.init(name: "url", value: url.absoluteString)]
                    guard let link = deepLink.url, let request = MediaRelayImportRequest(url: link) else {
                        throw ListeningShareCodeError.invalidCode
                    }
                    password = ""
                    remote = request
                }
            } catch is CancellationError { }
            catch {
                needsPassword = (error as? ListeningShareCodeResolver.Failure) == .passwordRequired
                self.error = ListeningShareText.error(error)
            }
        }
    }
}

private struct ListeningShareBookLinkView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var address = ""
    @State private var outgoing: ListeningShareSelection?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField(ListeningShareText.string("title"), text: $title)
                TextField(ListeningShareText.string("link"), text: $address)
                Button(ListeningShareText.string("share")) {
                    do {
                        let url = try ListeningShareURLPolicy.validate(address.trimmingCharacters(in: .whitespacesAndNewlines), publicSharing: true)
                        outgoing = .init(title: title.trimmingCharacters(in: .whitespacesAndNewlines), bookURL: url)
                    } catch { self.error = ListeningShareText.error(error) }
                }
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || address.isEmpty)
                if let error { Text(error).foregroundStyle(.red) }
            }
            .formStyle(.grouped)
            .navigationTitle(ListeningShareText.string("shareBookLink"))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("done") { dismiss() } } }
        }
        .frame(minWidth: 320, idealWidth: 520, minHeight: 280)
        .sheet(item: $outgoing) { ListeningShareExportView(selection: $0) }
    }
}

private struct ListeningShareLinksView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var records = ListeningShareRelay.records
    @State private var copiedID: String?
    @State private var revoking = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                ForEach(records) { record in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(record.title)
                        if let expiresAt = record.expiresAt { Text(expiresAt, style: .date).font(.caption).foregroundStyle(.secondary) }
                        HStack {
                            if let url = record.url {
                                if let code = try? ListeningShareCode.networkCode(for: url) {
                                    Button(ListeningShareText.string(copiedID == record.id ? "copied" : "copyCode")) {
                                        ListeningShareClipboard.copy(code)
                                        copiedID = record.id
                                    }
                                }
                                ListeningShareLinkButton(url: url, title: record.title)
                            }
                            Spacer()
                            Button(ListeningShareText.string("revoke"), role: .destructive) {
                                revoking = true
                                Task {
                                    defer { revoking = false; records = ListeningShareRelay.records }
                                    do { try await ListeningShareRelay.revoke(record.id) }
                                    catch { self.error = ListeningShareText.error(error) }
                                }
                            }.disabled(revoking)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            .overlay { if records.isEmpty { ContentUnavailableView(ListeningShareText.string("noLinks"), systemImage: "link") } }
            .navigationTitle(ListeningShareText.string("managedLinks"))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("done") { dismiss() }.disabled(revoking) } }
        }
        .frame(minWidth: 320, idealWidth: 560, minHeight: 400)
        .interactiveDismissDisabled(revoking)
        .alert(ListeningShareText.string("managedLinks"), isPresented: Binding(
            get: { error != nil }, set: { if !$0 { error = nil } }
        )) { Button("ok", role: .cancel) {} } message: { Text(error ?? "") }
    }
}
#endif
