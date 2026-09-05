#if os(tvOS)
import SwiftUI
import UIKit
import PrimuseKit

enum TVTransferText {
    static func string(_ key: String) -> String {
        NSLocalizedString(key, tableName: "WiFiTransfer", bundle: .main,
                          value: WiFiTransferPage.english[key] ?? key, comment: "")
    }
}

struct TVTransferReceiveView: View {
    @Environment(TVStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var receiver = WiFiTransferReceiver()
    @State private var error: String?
    @State private var previousIdleTimer: Bool?
    @State private var showMusic = false
    @State private var showStopConfirmation = false
    @State private var requestedAction = "stop"
    @State private var actionAfterStop: String?
    @Namespace private var transferFocus

    var body: some View {
        ZStack {
            TVColor.bg.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 34) {
                HStack(spacing: 20) {
                    Image(systemName: "tray.and.arrow.down").font(.system(size: 32, weight: .medium))
                        .foregroundStyle(TVColor.brand).frame(width: 66, height: 66)
                        .background(TVColor.brand.opacity(0.12), in: .rect(cornerRadius: 18))
                    VStack(alignment: .leading, spacing: 8) {
                        Text(TVTransferText.string("receive")).font(.system(size: 38, weight: .bold))
                        Text(UIDevice.current.name).font(.system(size: 20)).foregroundStyle(TVColor.textMuted)
                    }
                    Spacer()
                    action(TVTransferText.string("done"), icon: "xmark") { requestAction("close") }.frame(width: 180)
                }
                .alert(TVTransferText.string("stopReceiveTitle"), isPresented: $showStopConfirmation) {
                    Button(TVTransferText.string(requestedAction == "close" ? "stopAndClose" : "stopReceiving"), role: .destructive) {
                        performAction(requestedAction)
                    }
                    Button(TVTransferText.string("keepTransferring"), role: .cancel) {}
                } message: { Text(TVTransferText.string("closeReceiverHint")) }
                HStack(alignment: .top, spacing: 34) {
                    VStack(alignment: .leading, spacing: 28) {
                        HStack(spacing: 20) {
                            Image(systemName: "appletv")
                                .font(.system(size: 55, weight: .light)).foregroundStyle(TVColor.brand)
                            VStack(alignment: .leading, spacing: 8) {
                                Text(TVTransferText.string(receiver.running ? (receiver.receipts.contains { !$0.finished } ? "receiving" : "receiverReady") : "receiveEmptyTitle"))
                                    .font(.system(size: 28, weight: .semibold))
                                Text(TVTransferText.string("receiveEmptyHint")).font(.system(size: 20))
                                    .foregroundStyle(TVColor.textMuted).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Rectangle().fill(TVColor.text.opacity(0.09)).frame(height: 1)
                        if let address = receiver.address {
                            Text(TVTransferText.string("code")).font(.system(size: 18, weight: .medium)).foregroundStyle(TVColor.textMuted)
                            Text(receiver.code).font(.system(size: 64, weight: .semibold, design: .monospaced))
                                .tracking(12).accessibilityIdentifier("wifiTransfer.code")
                            Text(TVTransferText.string("receiveHint")).font(.system(size: 20))
                                .foregroundStyle(TVColor.textMuted).fixedSize(horizontal: false, vertical: true)
                            Text(address).font(.system(size: 20, design: .monospaced))
                                .foregroundStyle(TVColor.textMuted).accessibilityIdentifier("wifiTransfer.address")
                        } else if receiver.running {
                            ProgressView(TVTransferText.string("waiting")).font(.system(size: 22))
                                .frame(height: 190)
                        } else {
                            Text(TVTransferText.string("receiveHint")).font(.system(size: 22))
                                .foregroundStyle(TVColor.textMuted).lineSpacing(6)
                                .fixedSize(horizontal: false, vertical: true).frame(minHeight: 190, alignment: .topLeading)
                        }
                        action(TVTransferText.string(receiver.running ? "stopReceiving" : "startReceiving"),
                               icon: receiver.running ? "stop.circle" : "tray.and.arrow.down",
                               enabled: !receiver.stopping) {
                            if receiver.running { requestAction("stop") } else { start() }
                        }.frame(maxWidth: 360)
                            .prefersDefaultFocus(true, in: transferFocus)
                    }
                    .padding(36).frame(maxWidth: .infinity, alignment: .leading)
                    .background(TVColor.card, in: .rect(cornerRadius: 22))
                    .focusSection()

                    VStack(alignment: .leading, spacing: 24) {
                        receiptCard
                        VStack(alignment: .leading, spacing: 18) {
                            Label(TVTransferText.string("browserAccess"), systemImage: "globe")
                                .font(.system(size: 26, weight: .semibold))
                            Text(TVTransferText.string("browserHint")).font(.system(size: 20))
                                .foregroundStyle(TVColor.textMuted).fixedSize(horizontal: false, vertical: true)
                            browserAccessToggle
                        }.padding(28).background(TVColor.card, in: .rect(cornerRadius: 22))
                        if let error = error ?? receiver.error.map(TVTransferText.string) ?? store.transferScanError.map(TVTransferText.string) {
                            Text(error).font(.system(size: 18)).foregroundStyle(.red)
                        }
                        Text(TVTransferText.string("tvStorage")).font(.system(size: 18))
                            .foregroundStyle(TVColor.textMuted).lineSpacing(4)
                    }.frame(width: 520).focusSection()
                }
                Text(TVTransferText.string("keepOpen")).font(.system(size: 18)).foregroundStyle(TVColor.textMuted)
                Spacer(minLength: 0)
            }.padding(.horizontal, 80).padding(.vertical, 56).foregroundStyle(TVColor.text)
        }
        .focusScope(transferFocus)
        .onExitCommand { requestAction("close") }
        .alert(TVTransferText.string("requestTitle"), isPresented: Binding(
            get: { receiver.invitation != nil }, set: { if !$0 { receiver.allow(false) } }
        ), presenting: receiver.invitation) { _ in
            Button(TVTransferText.string("accept")) { receiver.allow(true) }
            Button(TVTransferText.string("decline"), role: .cancel) { receiver.allow(false) }
        } message: { invitation in
            Text(String(format: TVTransferText.string("requestSummary"), invitation.sender, invitation.fileCount,
                        ByteCountFormatter.string(fromByteCount: invitation.byteCount, countStyle: .file)))
        }
        .fullScreenCover(isPresented: $showMusic) { TVReceivedMusicView().environment(store) }
        .onDisappear { stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { receiver.stop(reason: "backgroundStopped"); restoreIdleTimer() }
        }
        .onChange(of: receiver.running) { _, running in
            if running {
                if previousIdleTimer == nil { previousIdleTimer = UIApplication.shared.isIdleTimerDisabled }
                UIApplication.shared.isIdleTimerDisabled = true
            } else {
                restoreIdleTimer()
                if let next = actionAfterStop { actionAfterStop = nil; performAction(next) }
            }
        }
    }

    private var receiptCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let receipt = receiver.receipts.first {
                Label(TVTransferText.string(receipt.finished ? (receipt.succeeded ? "receiveCompleted" : "receiveInterrupted") : "receiving"),
                      systemImage: receipt.succeeded ? "checkmark.circle.fill" : "tray.and.arrow.down")
                    .font(.system(size: 26, weight: .semibold))
                HStack {
                    Text(receipt.sender ?? TVTransferText.string("browserSender"))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(String(format: TVTransferText.string("receiveCount"), receipt.completed, receipt.fileCount))
                        .monospacedDigit()
                }.font(.system(size: 20)).foregroundStyle(TVColor.textMuted)
                if !receipt.finished {
                    ProgressView(value: receipt.progress).tint(TVColor.brand)
                    Text(receipt.files.last(where: { !$0.finished })?.path ?? TVTransferText.string("receiveWaitingFiles"))
                        .font(.system(size: 18)).lineLimit(1).truncationMode(.middle)
                }
                if let failure = receipt.error {
                    Text(TVTransferText.string(failure)).font(.system(size: 18))
                        .foregroundStyle(.orange).lineLimit(3)
                }
                if store.transferIsIndexing {
                    ProgressView(TVTransferText.string("indexing")).font(.system(size: 18))
                } else if receipt.completed > 0, store.transferScanError == nil {
                    Text(TVTransferText.string("receiveStored")).font(.system(size: 18)).foregroundStyle(TVColor.textMuted)
                }
            } else {
                Text(TVTransferText.string("receiveActivity")).font(.system(size: 26, weight: .semibold))
                Text(TVTransferText.string("receiverReady")).font(.system(size: 20)).foregroundStyle(TVColor.textMuted)
            }
            action(TVTransferText.string("library"), icon: "music.note.list") { requestAction("music") }
        }.padding(28).background(TVColor.card, in: .rect(cornerRadius: 22))
    }

    private func requestAction(_ value: String) {
        if receiver.running {
            requestedAction = value
            showStopConfirmation = true
        } else { performAction(value) }
    }

    private func performAction(_ value: String) {
        if receiver.running {
            actionAfterStop = value
            stop()
        } else if value == "close" { dismiss() }
        else if value == "music" { showMusic = true }
    }

    private var browserAccessToggle: some View {
        TVFocusButton(radius: 14, scale: 1.0, lift: 0, action: {
            receiver.setBrowserEnabled(!receiver.browserEnabled)
        }) { focused in
            HStack(spacing: 18) {
                Text(TVTransferText.string(receiver.browserEnabled ? "enabled" : "disabled"))
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(TVColor.text)
                Spacer(minLength: 12)
                ZStack(alignment: receiver.browserEnabled ? .trailing : .leading) {
                    Capsule().fill(receiver.browserEnabled ? TVColor.brand : TVColor.surfaceStrong)
                        .frame(width: 62, height: 34)
                    Circle().fill(.white).frame(width: 28, height: 28).padding(3)
                }
                .animation(.easeOut(duration: 0.18), value: receiver.browserEnabled)
            }
            .padding(.horizontal, 22).padding(.vertical, 16)
            .background(focused ? TVColor.surfaceStrong : TVColor.surface, in: .rect(cornerRadius: 14))
        }
        .accessibilityLabel(TVTransferText.string("browserAccess"))
        .accessibilityValue(TVTransferText.string(receiver.browserEnabled ? "enabled" : "disabled"))
        .disabled(!receiver.running || receiver.stopping)
        .opacity(receiver.running && !receiver.stopping ? 1 : 0.4)
    }

    private func action(_ title: String, icon: String, enabled: Bool = true, perform: @escaping () -> Void) -> some View {
        TVFocusButton(radius: 14, scale: 1.02, lift: 0, action: perform) { focused in
            Label(title, systemImage: icon).font(.system(size: 22, weight: .semibold))
                .foregroundStyle(focused ? TVColor.onBrand : TVColor.text)
                .padding(.horizontal, 24).padding(.vertical, 18).frame(maxWidth: .infinity, alignment: .leading)
                .background(focused ? TVColor.brand : TVColor.surface, in: RoundedRectangle(cornerRadius: 14))
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }

    private func start() {
        error = nil
        do {
            let source = try store.prepareTransferSource()
            let strings = Dictionary(uniqueKeysWithValues: WiFiTransferPage.english.keys.map { ($0, TVTransferText.string($0)) })
            receiver.start(root: TVLocalTransferSource.root,
                           identity: .init(id: WiFiTransferIdentity.localID, name: UIDevice.current.name, platform: "Apple TV"),
                           page: WiFiTransferPage.html(strings: strings, language: Bundle.main.preferredLocalizations.first ?? "en"),
                           willChange: { TVLocalTransferSource.markPendingScan() }) { path, deleted in
                refresh(source: source, path: path, deleted: deleted)
            }
            refresh(source: source, path: "", deleted: false)
        } catch { self.error = (error as? WiFiTransferError).map { TVTransferText.string($0.rawValue) } ?? error.localizedDescription }
    }

    private func stop() { receiver.stop(); restoreIdleTimer() }

    private func restoreIdleTimer() {
        if let previousIdleTimer {
            UIApplication.shared.isIdleTimerDisabled = previousIdleTimer
            self.previousIdleTimer = nil
        }
    }

    private func refresh(source: MusicSource, path: String, deleted: Bool) {
        store.queueTransferScan(source: source, path: path, deleted: deleted)
    }

}

private struct TVReceivedMusicView: View {
    @Environment(TVStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private var songs: [Song] { store.library.songs.filter { $0.sourceID == TVLocalTransferSource.sourceID } }

    var body: some View {
        ZStack {
            TVColor.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text(TVTransferText.string("library")).font(.system(size: 38, weight: .bold))
                    TVFocusButton(scale: 1.02, lift: 0, action: { dismiss() }) { focused in
                        Label(TVTransferText.string("done"), systemImage: "xmark")
                            .font(.system(size: 22, weight: .semibold))
                            .padding(.horizontal, 24).padding(.vertical, 16)
                            .foregroundStyle(focused ? TVColor.onBrand : TVColor.text)
                            .background(focused ? TVColor.brand : TVColor.surface, in: .rect(cornerRadius: 14))
                    }
                    if songs.isEmpty { Text(TVTransferText.string("emptySelection")).foregroundStyle(TVColor.textMuted) }
                    ForEach(songs) { song in
                        TVFocusButton(scale: 1.01, lift: 0, action: {
                            if store.currentSongID == song.id { store.togglePlayPause() }
                            else { _ = store.playResolvedQueue(songIDs: [song.id] + songs.filter { $0.id != song.id }.map(\.id), shuffled: false) }
                        }) { focused in
                            HStack(spacing: 22) {
                                Image(systemName: store.currentSongID == song.id && store.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                    .font(.system(size: 32))
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(song.title).font(.system(size: 24, weight: .semibold))
                                    Text(song.artistName ?? "").font(.system(size: 18))
                                }
                                Spacer()
                            }
                            .padding(22).foregroundStyle(focused ? TVColor.onBrand : TVColor.text)
                            .background(focused ? TVColor.brand : TVColor.surface, in: RoundedRectangle(cornerRadius: TVRadius.card))
                        }
                    }
                }.padding(.horizontal, 80).padding(.vertical, 56)
            }
        }
        .onPlayPauseCommand { store.togglePlayPause() }
    }
}
#endif
