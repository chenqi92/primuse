import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import PrimuseKit

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct RadioStationsView: View {
    @Environment(RadioStationsStore.self) private var store
    @Environment(AudioPlayerService.self) private var player
    @State private var editingStation: RadioStation?
    @State private var showingNewStation = false
    @State private var pendingInsecureStation: RadioStation?

    private let columns = [
        GridItem(.adaptive(minimum: 190, maximum: 280), spacing: 16)
    ]

    var body: some View {
        Group {
            if store.stations.isEmpty {
                ContentUnavailableView {
                    Label("radio_empty_title", systemImage: "radio")
                } description: {
                    Text("radio_empty_description")
                } actions: {
                    Button("radio_add") { showingNewStation = true }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                        ForEach(store.stations) { station in
                            RadioStationCard(
                                station: station,
                                isCurrent: player.currentRadioStation?.id == station.id,
                                isPlaying: player.currentRadioStation?.id == station.id
                                    && (player.isPlaying || player.isLoading),
                                metadataTitle: player.currentRadioStation?.id == station.id
                                    ? player.radioMetadataTitle
                                    : nil,
                                onPlay: { toggle(station) },
                                onEdit: { editingStation = station },
                                onDelete: { store.remove(id: station.id) }
                            )
                        }
                    }
                    .padding(16)
                }
            }
        }
        .navigationTitle("radio_title")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingNewStation = true
                } label: {
                    Label("radio_add", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showingNewStation) {
            RadioStationEditorView(station: nil)
        }
        .sheet(item: $editingStation) { station in
            RadioStationEditorView(station: station)
        }
        .alert("insecure_http_warning_title", isPresented: Binding(
            get: { pendingInsecureStation != nil },
            set: { if !$0 { pendingInsecureStation = nil } }
        )) {
            Button("cancel", role: .cancel) {
                pendingInsecureStation = nil
            }
            Button("insecure_http_continue", role: .destructive) {
                guard let station = pendingInsecureStation,
                      let host = station.url?.host else { return }
                SSLTrustStore.shared.allowInsecureHTTP(domain: host)
                pendingInsecureStation = nil
                performToggle(station)
            }
        } message: {
            Text(String(
                format: String(localized: "insecure_http_warning_message %@"),
                pendingInsecureStation?.url?.host ?? ""
            ))
        }
    }

    private func toggle(_ station: RadioStation) {
        if let url = station.url,
           TrustedHTTPTransport.requiresPlainSocket(for: url),
           let host = url.host,
           !SSLTrustStore.allowsInsecureHTTPHostSync(domain: host) {
            pendingInsecureStation = station
            return
        }
        performToggle(station)
    }

    private func performToggle(_ station: RadioStation) {
        if player.currentRadioStation?.id == station.id,
           player.isPlaying || player.isLoading {
            player.pause()
        } else {
            Task { await player.play(station: station, within: store.stations) }
        }
    }
}

private struct RadioStationCard: View {
    let station: RadioStation
    let isCurrent: Bool
    let isPlaying: Bool
    let metadataTitle: String?
    let onPlay: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: onPlay) {
            HStack(spacing: 13) {
                RadioStationArtworkView(station: station, size: 64, cornerRadius: 14)

                VStack(alignment: .leading, spacing: 5) {
                    Text(station.name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(metadataTitle ?? station.playbackSubtitle)
                        .font(.caption)
                        .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isPlaying ? Color.red : Color.accentColor)
                    .frame(width: 36, height: 36)
                    .background(.thinMaterial, in: Circle())
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
            .background(
                isCurrent ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.07),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(isCurrent ? Color.accentColor.opacity(0.35) : Color.secondary.opacity(0.1), lineWidth: 0.7)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("edit", action: onEdit)
            Button("delete", role: .destructive, action: onDelete)
        }
    }
}

struct RadioStationArtworkView: View {
    let station: RadioStation
    var size: CGFloat
    var cornerRadius: CGFloat

    var body: some View {
        Group {
            if let data = station.logoData, let image = PlatformRadioImage(data: data) {
                Image(platformRadioImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    LinearGradient(
                        colors: [.purple.opacity(0.85), .blue.opacity(0.7)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Image(systemName: "radio.fill")
                        .font(.system(size: size * 0.34, weight: .medium))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

private struct RadioStationEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(RadioStationsStore.self) private var store
    @Environment(AudioPlayerService.self) private var player

    let station: RadioStation?
    @State private var name: String
    @State private var urlString: String
    @State private var logoData: Data?
    @State private var pickerItem: PhotosPickerItem?
    @State private var isTesting = false
    @State private var isSaving = false
    @State private var resultMessage: String?
    @State private var insecureHTTPHost: String?
    @State private var pendingTestAfterTrust = false

    init(station: RadioStation?) {
        self.station = station
        _name = State(initialValue: station?.name ?? "")
        _urlString = State(initialValue: station?.streamURL ?? "")
        _logoData = State(initialValue: station?.logoData)
    }

    private var canSave: Bool {
        RadioStationValidation.isValid(name: name, urlString: urlString) && !isSaving
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("radio_details") {
                    TextField("radio_name", text: $name)
                    TextField("radio_stream_url", text: $urlString)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                }

                Section("radio_logo_optional") {
                    HStack(spacing: 16) {
                        RadioEditorArtwork(data: logoData)
                        VStack(alignment: .leading, spacing: 10) {
                            PhotosPicker(selection: $pickerItem, matching: .images) {
                                Label("radio_choose_logo", systemImage: "photo")
                            }
                            if logoData != nil {
                                Button("radio_remove_logo", role: .destructive) {
                                    pickerItem = nil
                                    logoData = nil
                                }
                            }
                        }
                    }
                }

                Section {
                    Button {
                        beginTest()
                    } label: {
                        HStack {
                            Label("radio_test_playback", systemImage: "waveform")
                            Spacer()
                            if isTesting { ProgressView().controlSize(.small) }
                        }
                    }
                    .disabled(!canSave || isTesting)

                    if let resultMessage {
                        Text(resultMessage)
                            .font(.caption)
                            .foregroundStyle(resultMessage == String(localized: "radio_test_success") ? .green : .secondary)
                    }
                } footer: {
                    Text("radio_test_description")
                }
            }
            .navigationTitle(station == nil ? "radio_add" : "radio_edit")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("save") { save() }
                        .disabled(!canSave)
                }
            }
            .onChange(of: pickerItem) { _, item in
                guard let item else { return }
                Task {
                    guard let data = try? await item.loadTransferable(type: Data.self),
                          let processed = RadioLogoProcessor.process(data) else {
                        resultMessage = String(localized: "radio_logo_invalid")
                        return
                    }
                    logoData = processed
                }
            }
            .alert("insecure_http_warning_title", isPresented: Binding(
                get: { insecureHTTPHost != nil },
                set: { if !$0 { insecureHTTPHost = nil; pendingTestAfterTrust = false } }
            )) {
                Button("cancel", role: .cancel) {
                    insecureHTTPHost = nil
                    pendingTestAfterTrust = false
                }
                Button("insecure_http_continue", role: .destructive) {
                    guard let host = insecureHTTPHost else { return }
                    SSLTrustStore.shared.allowInsecureHTTP(domain: host)
                    insecureHTTPHost = nil
                    if pendingTestAfterTrust {
                        pendingTestAfterTrust = false
                        runTest()
                    }
                }
            } message: {
                Text(String(format: String(localized: "insecure_http_warning_message %@"), insecureHTTPHost ?? ""))
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 470)
        #endif
    }

    private func beginTest() {
        guard let normalized = RadioStationValidation.normalizedURLString(urlString),
              let url = URL(string: normalized) else { return }
        if TrustedHTTPTransport.requiresPlainSocket(for: url),
           let host = url.host,
           !SSLTrustStore.allowsInsecureHTTPHostSync(domain: host) {
            pendingTestAfterTrust = true
            insecureHTTPHost = host
            return
        }
        runTest()
    }

    private func runTest() {
        guard let normalized = RadioStationValidation.normalizedURLString(urlString),
              let url = URL(string: normalized) else { return }
        isTesting = true
        resultMessage = nil
        Task {
            let result = await player.testRadioStream(url: url)
            isTesting = false
            switch result {
            case .success:
                resultMessage = String(localized: "radio_test_success")
            case .failure(let error):
                resultMessage = String(format: String(localized: "radio_test_failed %@"), error.localizedDescription)
            }
        }
    }

    private func save() {
        guard let normalizedURL = RadioStationValidation.normalizedURLString(urlString) else { return }
        isSaving = true
        Task {
            let id = station?.id ?? UUID().uuidString
            let logoFileName: String?
            if let logoData {
                logoFileName = await MetadataAssetStore.shared.storeCover(logoData, for: "radio:\(id)")
            } else {
                logoFileName = nil
            }
            let value = RadioStation(
                id: id,
                name: RadioStationValidation.normalizedName(name),
                streamURL: normalizedURL,
                logoData: logoData,
                logoFileName: logoFileName,
                streamFormat: station?.streamFormat ?? RadioStreamFormat.inferred(from: URL(string: normalizedURL)!),
                bitRate: station?.bitRate,
                createdAt: station?.createdAt ?? Date(),
                modifiedAt: Date(),
                lastPlayedAt: station?.lastPlayedAt
            )
            store.upsert(value)
            isSaving = false
            dismiss()
        }
    }
}

private struct RadioEditorArtwork: View {
    let data: Data?

    var body: some View {
        Group {
            if let data, let image = PlatformRadioImage(data: data) {
                Image(platformRadioImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color.secondary.opacity(0.12)
                    Image(systemName: "radio")
                        .font(.title)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 84, height: 84)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private enum RadioLogoProcessor {
    static func process(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat else {
            return nil
        }
        let maxDimension: CGFloat = 512
        let scale = min(1, maxDimension / max(width, height))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(max(width, height) * scale),
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination),
              output.length <= RadioStationValidation.maximumLogoBytes else { return nil }
        return output as Data
    }
}

#if os(iOS)
private typealias PlatformRadioImage = UIImage

private extension Image {
    init(platformRadioImage image: UIImage) { self.init(uiImage: image) }
}
#elseif os(macOS)
private typealias PlatformRadioImage = NSImage

private extension Image {
    init(platformRadioImage image: NSImage) { self.init(nsImage: image) }
}
#endif
