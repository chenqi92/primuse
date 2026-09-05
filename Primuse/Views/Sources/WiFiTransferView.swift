#if os(iOS) || os(macOS)
import SwiftUI
import PrimuseKit
#if os(iOS)
import UIKit
#else
import AppKit
#endif

enum WiFiTransferText {
    static func string(_ key: String) -> String {
        NSLocalizedString(key, tableName: "WiFiTransfer", bundle: .main,
                          value: WiFiTransferPage.english[key] ?? key, comment: "")
    }

    @MainActor static var identity: WiFiTransferIdentity {
        #if os(iOS)
        let platform = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        let name = UIDevice.current.name
        #else
        let platform = "Mac"
        let name = Host.current().localizedName ?? "Mac"
        #endif
        return .init(id: WiFiTransferIdentity.localID, name: name, platform: platform)
    }

    static var page: String {
        let strings = Dictionary(uniqueKeysWithValues: WiFiTransferPage.english.keys.map { ($0, string($0)) })
        return WiFiTransferPage.html(strings: strings, language: Bundle.main.preferredLocalizations.first ?? "en")
    }

    static func error(_ error: Error) -> String {
        if let error = error as? WiFiTransferError { return string(error.rawValue) }
        if error is CancellationError { return string("cancelled") }
        return error.localizedDescription
    }
}

struct WiFiTransferView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(SourceManager.self) private var sourceManager
    @Environment(SourcesStore.self) private var sourceStore
    @Environment(MusicLibrary.self) private var library
    @Environment(ScanService.self) private var scanService
    @Environment(MusicScraperService.self) private var scraperService
    @Environment(AudioPlayerService.self) private var player
    @State private var receiver = WiFiTransferReceiver()
    @State private var sender = WiFiTransferSender()
    @State private var mode = "send"
    @State private var pendingScan: Task<Void, Never>?
    @State private var needsScan = false
    @State private var changedLyrics: Set<String> = []
    @State private var setupError: String?
    @State private var receivingSource: MusicSource?
    @State private var copied = false
    @State private var showStopConfirmation = false
    @State private var closeAfterStopping = false
    @State private var dismissWhenStopped = false
    @State private var showReceiveHistory = false
    #if os(iOS)
    @State private var previousIdleTimer: Bool?
    #endif

    init(initialMode: String = "send") { _mode = State(initialValue: initialMode) }

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            header
            #endif
            modeSelector
                .alert(WiFiTransferText.string(closeAfterStopping ? "closeTransferTitle" : "stopReceiveTitle"),
                       isPresented: $showStopConfirmation) {
                    Button(WiFiTransferText.string(closeAfterStopping ? "stopAndClose" : "stopReceiving"), role: .destructive) {
                        if closeAfterStopping { finishAndClose() } else { receiver.stop() }
                    }
                    Button(WiFiTransferText.string("keepTransferring"), role: .cancel) {}
                } message: {
                    Text(WiFiTransferText.string(sender.busy ? "closeSenderHint" : "closeReceiverHint"))
                }
            if mode == "send" { WiFiTransferSendView(sender: sender) }
            else { receiveForm }
        }
        .background(TransferAppearance.background)
        .foregroundStyle(TransferAppearance.text)
        #if os(iOS)
        .navigationTitle(WiFiTransferText.string("nativeTitle"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(WiFiTransferText.string("done")) { requestClose() }
            }
        }
        #else
        .frame(width: 820, height: 620)
        #endif
        .interactiveDismissDisabled()
        .alert(WiFiTransferText.string("requestTitle"), isPresented: Binding(
            get: { receiver.invitation != nil },
            set: { if !$0 { receiver.allow(false) } }
        ), presenting: receiver.invitation) { _ in
            Button(WiFiTransferText.string("accept")) { receiver.allow(true) }
            Button(WiFiTransferText.string("decline"), role: .cancel) { receiver.allow(false) }
        } message: { invitation in
            Text(String(format: WiFiTransferText.string("requestSummary"), invitation.sender,
                        invitation.fileCount, ByteCountFormatter.string(fromByteCount: invitation.byteCount, countStyle: .file)))
        }
        .onDisappear { stop() }
        .onChange(of: receiver.running) { _, running in
            if !running, dismissWhenStopped { dismiss() }
        }
        .onChange(of: scenePhase) { _, phase in
            #if os(iOS)
            if phase == .background { receiver.stop(reason: "backgroundStopped"); sender.cancel(); restoreIdleTimer() }
            #endif
        }
        .onChange(of: receiver.running || sender.busy) { _, active in
            #if os(iOS)
            if active {
                if previousIdleTimer == nil { previousIdleTimer = UIApplication.shared.isIdleTimerDisabled }
                UIApplication.shared.isIdleTimerDisabled = true
            } else { restoreIdleTimer() }
            #endif
        }
    }

    #if os(macOS)
    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(PMColor.brand).frame(width: 42, height: 42)
                .background(PMColor.brand.opacity(0.11), in: .rect(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 4) {
                Text(WiFiTransferText.string("nativeTitle")).font(.system(size: 18, weight: .semibold))
                Text(WiFiTransferText.string("nativeSubtitle")).font(.system(size: 12))
                    .foregroundStyle(PMColor.textMuted).lineLimit(2)
            }
            Spacer(minLength: 20)
            Button { requestClose() } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(PMColor.textMuted).frame(width: 28, height: 28)
                    .background(PMColor.glassBtn, in: .circle)
            }.buttonStyle(.plain).keyboardShortcut(.cancelAction)
                .accessibilityLabel(WiFiTransferText.string("done"))
        }.padding(.horizontal, 22).padding(.vertical, 18)
            .background(PMColor.bgElev)
            .overlay(alignment: .bottom) { Rectangle().fill(PMColor.divider).frame(height: 0.5) }
    }
    #endif

    private var modeSelector: some View {
        HStack(spacing: 3) {
            modeButton("send", icon: "paperplane")
            modeButton("receive", icon: "tray.and.arrow.down")
        }
        .padding(3).background(TransferAppearance.line.opacity(0.65), in: .rect(cornerRadius: 10))
        #if os(macOS)
        .frame(width: 316)
        #endif
        .padding(.horizontal, 22).padding(.top, 14)
        .disabled(receiver.running || sender.busy)
    }

    private func modeButton(_ value: String, icon: String) -> some View {
        Button { mode = value } label: {
            Label(WiFiTransferText.string(value), systemImage: icon)
                .font(.system(size: TransferAppearance.bodySize, weight: mode == value ? .semibold : .medium))
                .foregroundStyle(mode == value ? TransferAppearance.text : TransferAppearance.muted)
                .frame(maxWidth: .infinity).padding(.vertical, 9)
                .frame(minHeight: TransferAppearance.compactTarget)
                .background(mode == value ? TransferAppearance.surface : .clear, in: .rect(cornerRadius: 8))
                .contentShape(.rect)
        }.buttonStyle(.plain)
            .accessibilityAddTraits(mode == value ? .isSelected : [])
    }

    private var receiveForm: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if let receipt = receiver.receipts.first {
                            TransferSectionHeading(title: WiFiTransferText.string("receiveActivity"))
                            TransferReceiveReceiptView(receipt: receipt,
                                indexing: needsScan || pendingScan != nil, indexError: setupError)
                        }
                        if receiver.running, let address = receiver.address {
                            Group {
                                if geometry.size.width >= 680 {
                                    HStack(spacing: 30) {
                                        receivingIdentity.frame(maxWidth: .infinity, alignment: .leading)
                                        accessCode
                                    }
                                } else {
                                    VStack(alignment: .leading, spacing: 24) {
                                        receivingIdentity
                                        accessCode.frame(maxWidth: .infinity)
                                    }
                                }
                            }.modifier(TransferSurface(padding: 24))
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: "globe").font(.system(size: 23, weight: .light))
                                    .foregroundStyle(TransferAppearance.accent).frame(width: 32)
                                VStack(alignment: .leading, spacing: 7) {
                                    Toggle(WiFiTransferText.string("browserAccess"), isOn: Binding(
                                        get: { receiver.browserEnabled }, set: { receiver.setBrowserEnabled($0) }
                                    )).toggleStyle(.switch).font(.system(size: TransferAppearance.bodySize, weight: .semibold))
                                        .accessibilityIdentifier("wifiTransfer.browser")
                                    Text(WiFiTransferText.string("browserHint"))
                                        .font(.system(size: TransferAppearance.captionSize))
                                        .foregroundStyle(TransferAppearance.muted)
                                        .fixedSize(horizontal: false, vertical: true)
                                    if receiver.browserEnabled {
                                        addressRow(address)
                                    }
                                }
                            }.modifier(TransferSurface())
                        } else if receiver.running {
                            ProgressView(WiFiTransferText.string("waiting"))
                                .frame(maxWidth: .infinity, minHeight: 280)
                        } else if receiver.receipts.isEmpty {
                            VStack(spacing: 16) {
                                Image(systemName: TransferAppearance.deviceIcon(WiFiTransferText.identity.platform))
                                    .font(.system(size: 54, weight: .ultraLight))
                                    .foregroundStyle(TransferAppearance.accent)
                                    .frame(width: 112, height: 106)
                                    .background(TransferAppearance.accent.opacity(0.07), in: .rect(cornerRadius: 24))
                                Text(WiFiTransferText.identity.name).font(.system(size: 20, weight: .semibold))
                                Text(WiFiTransferText.string("receiveEmptyHint"))
                                    .font(.system(size: TransferAppearance.bodySize)).foregroundStyle(TransferAppearance.muted)
                                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: 400)
                            }.frame(maxWidth: .infinity, minHeight: 285)
                        }
                        if receiver.receipts.count > 1 {
                            DisclosureGroup(isExpanded: $showReceiveHistory) {
                                VStack(spacing: 14) {
                                    ForEach(receiver.receipts.dropFirst()) { receipt in
                                        TransferReceiveReceiptView(receipt: receipt,
                                            indexing: needsScan || pendingScan != nil, indexError: setupError)
                                    }
                                }.padding(.top, 14)
                            } label: {
                                Text(WiFiTransferText.string("receiveHistory"))
                                    .font(.system(size: TransferAppearance.bodySize, weight: .medium))
                                    .frame(minHeight: TransferAppearance.compactTarget)
                            }.tint(TransferAppearance.accent)
                        }
                        if let error = setupError ?? receiver.error.map(WiFiTransferText.string) {
                            TransferFeedback(text: error, isError: true)
                            if let source = receivingSource, LocalImportService.hasPendingScan, pendingScan == nil {
                                Button(WiFiTransferText.string("refresh"), systemImage: "arrow.clockwise") {
                                    refreshLibrary(source: source, path: "", deleted: false)
                                }.buttonStyle(TransferButtonStyle(compact: true))
                            }
                        }
                        #if os(iOS)
                        if receiver.running {
                            Text(WiFiTransferText.string("sessionHint"))
                                .font(.system(size: TransferAppearance.captionSize))
                                .foregroundStyle(TransferAppearance.muted)
                        }
                        #endif
                    }.padding(22).id("receiveTop")
                }
                .onChange(of: receiver.receipts.first?.id) { _, _ in
                    showReceiveHistory = false
                    withAnimation { scroll.scrollTo("receiveTop", anchor: .top) }
                }
                }
            }
            HStack(spacing: 18) {
                Label(WiFiTransferText.string("sameNetwork"), systemImage: "wifi")
                    .font(.system(size: TransferAppearance.captionSize)).foregroundStyle(TransferAppearance.muted)
                Spacer()
                if receiver.running {
                    Button(WiFiTransferText.string("stopReceiving")) {
                        closeAfterStopping = false
                        showStopConfirmation = true
                    }
                        .buttonStyle(TransferButtonStyle()).accessibilityIdentifier("wifiTransfer.stop")
                        .disabled(receiver.stopping)
                } else {
                    Button { start() } label: {
                        Label(WiFiTransferText.string("startReceiving"), systemImage: "tray.and.arrow.down.fill")
                    }.buttonStyle(TransferButtonStyle(prominent: true)).accessibilityIdentifier("wifiTransfer.start")
                }
            }.padding(.horizontal, 22).padding(.vertical, 14)
                .background(TransferAppearance.surface)
                .overlay(alignment: .top) { Rectangle().fill(TransferAppearance.line).frame(height: 0.5) }
        }
    }

    private var receivingIdentity: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(WiFiTransferText.identity.name, systemImage: TransferAppearance.deviceIcon(WiFiTransferText.identity.platform))
                .font(.system(size: 17, weight: .semibold))
            Label(WiFiTransferText.string(receiver.receipts.contains { !$0.finished } ? "receiving" : "receiverReady"), systemImage: "circle.fill")
                .font(.system(size: TransferAppearance.captionSize, weight: .medium))
                .foregroundStyle(TransferAppearance.accent)
            Text(WiFiTransferText.string("receiveHint"))
                .font(.system(size: TransferAppearance.captionSize)).foregroundStyle(TransferAppearance.muted)
                .fixedSize(horizontal: false, vertical: true)
            if let address = receiver.address {
                Text(address).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(TransferAppearance.muted)
                    .textSelection(.enabled).accessibilityIdentifier("wifiTransfer.address")
            }
        }
    }

    private var accessCode: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(WiFiTransferText.string("code")).font(.system(size: TransferAppearance.captionSize, weight: .medium))
                .foregroundStyle(TransferAppearance.muted)
            Text(receiver.code)
                .font(.system(size: 36, weight: .semibold, design: .monospaced)).tracking(6)
                .padding(.horizontal, 18).padding(.vertical, 14)
                .background(TransferAppearance.background, in: .rect(cornerRadius: 10))
                .textSelection(.enabled).accessibilityIdentifier("wifiTransfer.code")
            Text(WiFiTransferText.string("sessionCode"))
                .font(.system(size: TransferAppearance.captionSize)).foregroundStyle(TransferAppearance.muted)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 260, alignment: .leading)
        }
    }

    private func addressRow(_ address: String) -> some View {
        HStack(spacing: 8) {
            Text(address).font(.system(size: TransferAppearance.captionSize, design: .monospaced)).lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            Button {
                #if os(iOS)
                UIPasteboard.general.string = address
                #else
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(address, forType: .string)
                #endif
                copied = true
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .frame(width: TransferAppearance.compactTarget, height: TransferAppearance.compactTarget).contentShape(.rect)
            }.buttonStyle(.plain).foregroundStyle(TransferAppearance.accent)
                .accessibilityLabel(WiFiTransferText.string(copied ? "copied" : "copyAddress"))
        }.padding(8).background(TransferAppearance.background, in: .rect(cornerRadius: 8)).padding(.top, 5)
    }

    private func stop() {
        receiver.stop()
        sender.cancel()
        #if os(iOS)
        restoreIdleTimer()
        #endif
    }

    private func requestClose() {
        guard receiver.running || sender.busy else { dismiss(); return }
        closeAfterStopping = true
        showStopConfirmation = true
    }

    private func finishAndClose() {
        dismissWhenStopped = receiver.running
        stop()
        if !dismissWhenStopped { dismiss() }
    }

    #if os(iOS)
    private func restoreIdleTimer() {
        if let previousIdleTimer {
            UIApplication.shared.isIdleTimerDisabled = previousIdleTimer
            self.previousIdleTimer = nil
        }
    }
    #endif

    private func start() {
        setupError = nil
        copied = false
        do {
            let existing = sourceStore.source(id: LocalImportService.sourceID)
            let source: MusicSource
            if let existing, !existing.isDeleted {
                guard LocalImportService.isManagedSource(existing) else { throw WiFiTransferError.unavailable }
                var current = existing
                current.basePath = LocalImportService.musicDirectory.path
                if current.basePath != existing.basePath {
                    try sourceStore.updateDurably(existing.id) { $0.basePath = current.basePath }
                }
                source = sourceStore.source(id: existing.id) ?? current
            } else {
                source = LocalImportService.makeSource(name: String(localized: "local_import_source_name"))
                try sourceStore.addDurably(source)
            }
            guard source.isEnabled else { setupError = WiFiTransferText.string("enableSource"); return }
            receivingSource = source
            receiver.start(root: LocalImportService.ensureMusicDirectory(), identity: WiFiTransferText.identity,
                           page: WiFiTransferText.page, willChange: { LocalImportService.markPendingScan() }) { path, deleted in
                refreshLibrary(source: source, path: path, deleted: deleted)
            }
            if LocalImportService.hasPendingScan { refreshLibrary(source: source, path: "", deleted: false) }
        } catch { setupError = WiFiTransferText.error(error) }
    }

    private func refreshLibrary(source: MusicSource, path: String, deleted: Bool) {
        setupError = nil
        needsScan = true
        let changedURL = URL(fileURLWithPath: "/" + path)
        if PrimuseConstants.supportedLyricsExtensions.contains(changedURL.pathExtension.lowercased()) {
            changedLyrics.insert(changedURL.deletingPathExtension().path)
        }
        if deleted {
            let removed = library.songs.filter { $0.sourceID == source.id && $0.filePath == "/" + path }
            if !removed.isEmpty {
                Task { await player.prepareQueueForRemovingSongs(withIDs: Set(removed.map(\.id))) }
            }
        }
        guard pendingScan == nil else { return }
        // Keep this task alive after navigation: a completed upload must still
        // reach the library even if the user closes the transfer screen at once.
        pendingScan = Task { @MainActor in
            defer { pendingScan = nil }
            while needsScan {
                do { try await Task.sleep(for: .milliseconds(750)) } catch { return }
                while scanService.scanStates[source.id]?.isScanning == true {
                    do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                }
                needsScan = false
                let started = scanService.scanSource(source, sourceManager: sourceManager, library: library,
                                                     sourceStore: sourceStore, scraperService: scraperService)
                guard started else { setupError = WiFiTransferText.string("unavailable"); return }
                while scanService.scanStates[source.id]?.isScanning == true {
                    do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                }
                if let failure = scanService.scanStates[source.id]?.failureMessage {
                    setupError = failure
                    return
                }
                if needsScan { continue }
                let lyricsStems = changedLyrics
                changedLyrics.removeAll()
                let changedSongs = library.songs.filter {
                    $0.sourceID == source.id && lyricsStems.contains(URL(fileURLWithPath: $0.filePath).deletingPathExtension().path)
                }
                for song in changedSongs {
                    if await MetadataAssetStore.shared.invalidateLyricsCache(forSongID: song.id) {
                        NotificationCenter.default.post(name: .primuseLyricsDidChange, object: song.id)
                    }
                }
            }
        }
    }
}
#endif
