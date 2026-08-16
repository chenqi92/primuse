#if os(macOS)
import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import PrimuseKit

/// macOS 电台编辑弹框。跟 Mac 其它自定义弹框一致：自绘标题栏(左上角只留关闭灯) +
/// PM token 的字段行 + 底部主次按钮，不用 iOS 那套 NavigationStack + Form。
struct MacRadioStationEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(RadioStationsStore.self) private var store
    @Environment(AudioPlayerService.self) private var player

    let station: RadioStation?

    @State private var name: String
    @State private var urlString: String
    @State private var logoData: Data?
    @State private var isTesting = false
    @State private var isSaving = false
    @State private var testResult: TestResult?
    @State private var insecureHTTPHost: String?
    @State private var pendingTestAfterTrust = false

    private enum TestResult: Equatable {
        case success
        case failure(String)
    }

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
        VStack(spacing: 0) {
            titleBar
            Rectangle().fill(PMColor.divider).frame(height: 0.5)

            ScrollView {
                VStack(alignment: .leading, spacing: PMSpace.m14) {
                    logoRow
                    fieldRow(label: String(localized: "radio_name"), text: $name)
                    fieldRow(
                        label: String(localized: "radio_stream_url"),
                        text: $urlString,
                        monospaced: true
                    )
                    testRow
                }
                .padding(.horizontal, PMSpace.l24)
                .padding(.vertical, PMSpace.l)
            }

            Rectangle().fill(PMColor.divider).frame(height: 0.5)
            footer
        }
        .frame(width: 540, height: 460)
        .background(PMColor.bg)
        .foregroundStyle(PMColor.text)
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

    // MARK: - Chrome

    private var titleBar: some View {
        HStack(spacing: PMSpace.m) {
            Text(station == nil ? "radio_add" : "radio_edit")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(PMColor.text)
            Spacer()
        }
        .padding(.horizontal, PMSpace.m16)
        .padding(.vertical, PMSpace.m14)
    }

    private var footer: some View {
        HStack(spacing: PMSpace.s10) {
            Spacer()

            Button {
                dismiss()
            } label: {
                Text("cancel")
                    .font(PMFont.bodyM)
                    .foregroundStyle(PMColor.text)
                    .frame(height: 26)
                    .padding(.horizontal, 14)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .disabled(isSaving)

            Button {
                save()
            } label: {
                Group {
                    if isSaving {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("save")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(height: 26)
                .padding(.horizontal, 16)
                .background(
                    canSave ? PMColor.brand : PMColor.textFaint.opacity(0.45),
                    in: .rect(cornerRadius: PMRadius.s)
                )
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .disabled(!canSave)
        }
        .padding(.horizontal, PMSpace.l24)
        .padding(.vertical, PMSpace.m)
    }

    // MARK: - Fields

    private var logoRow: some View {
        HStack(spacing: PMSpace.m14) {
            Group {
                if let logoData, let image = NSImage(data: logoData) {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    ZStack {
                        PMColor.card
                        Image(systemName: "radio")
                            .font(.system(size: 22))
                            .foregroundStyle(PMColor.textFaint)
                    }
                }
            }
            .frame(width: 72, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: PMRadius.l, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: PMRadius.l, style: .continuous)
                    .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
            }

            VStack(alignment: .leading, spacing: PMSpace.s) {
                Text("radio_logo_optional")
                    .font(PMFont.bodyS)
                    .foregroundStyle(PMColor.textMuted)

                HStack(spacing: PMSpace.s) {
                    Button {
                        pickLogo()
                    } label: {
                        Text("radio_choose_logo")
                            .font(PMFont.bodyM)
                            .foregroundStyle(PMColor.text)
                            .frame(height: 24)
                            .padding(.horizontal, 12)
                            .background(PMColor.glassBtn, in: .rect(cornerRadius: PMRadius.s))
                            .overlay {
                                RoundedRectangle(cornerRadius: PMRadius.s, style: .continuous)
                                    .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
                            }
                    }
                    .buttonStyle(.plain)

                    if logoData != nil {
                        Button {
                            logoData = nil
                        } label: {
                            Text("radio_remove_logo")
                                .font(PMFont.bodyM)
                                .foregroundStyle(PMColor.bad)
                                .frame(height: 24)
                                .padding(.horizontal, 12)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Spacer(minLength: 0)
        }
    }

    private func fieldRow(
        label: String,
        text: Binding<String>,
        monospaced: Bool = false
    ) -> some View {
        HStack(alignment: .center, spacing: PMSpace.s10) {
            Text(label)
                .font(PMFont.bodyS)
                .foregroundStyle(PMColor.textMuted)
                .frame(width: 96, alignment: .leading)

            TextField(label, text: text, prompt: Text(verbatim: "—"))
                .textFieldStyle(.plain)
                .font(monospaced ? PMFont.mono : PMFont.bodyS)
                .foregroundStyle(PMColor.text)
                .padding(.horizontal, PMSpace.s10)
                .frame(height: 28)
                .background(PMColor.bgElev, in: .rect(cornerRadius: PMRadius.s))
                .overlay {
                    RoundedRectangle(cornerRadius: PMRadius.s, style: .continuous)
                        .strokeBorder(PMColor.dividerStrong, lineWidth: 0.5)
                }
        }
    }

    private var testRow: some View {
        VStack(alignment: .leading, spacing: PMSpace.s) {
            HStack(spacing: PMSpace.s10) {
                Text(verbatim: "")
                    .frame(width: 96, alignment: .leading)

                Button {
                    beginTest()
                } label: {
                    HStack(spacing: 6) {
                        if isTesting {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "waveform")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        Text("radio_test_playback")
                            .font(PMFont.bodyM)
                    }
                    .foregroundStyle(PMColor.text)
                    .frame(height: 26)
                    .padding(.horizontal, 12)
                    .background(PMColor.glassBtn, in: .rect(cornerRadius: PMRadius.s))
                    .overlay {
                        RoundedRectangle(cornerRadius: PMRadius.s, style: .continuous)
                            .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
                    }
                }
                .buttonStyle(.plain)
                .disabled(!canSave || isTesting)

                Spacer(minLength: 0)
            }

            HStack(alignment: .top, spacing: PMSpace.s10) {
                Text(verbatim: "")
                    .frame(width: 96)

                Group {
                    switch testResult {
                    case .success:
                        Label("radio_test_success", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(PMColor.ok)
                    case .failure(let message):
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(PMColor.bad)
                    case nil:
                        Text("radio_test_description")
                            .foregroundStyle(PMColor.textFaint)
                    }
                }
                .font(PMFont.caption)
                .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Actions

    /// macOS 没有 PhotosPicker 的沙箱直读，走 NSOpenPanel 更符合桌面习惯。
    private func pickLogo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK,
              let url = panel.url,
              let raw = try? Data(contentsOf: url) else { return }
        logoData = MacRadioLogoProcessor.process(raw) ?? raw
    }

    private func beginTest() {
        guard let normalized = RadioStationValidation.normalizedURLString(urlString),
              let url = URL(string: normalized) else { return }
        if TrustedHTTPTransport.requiresPlainSocket(for: url),
           let trustTarget = TrustedHTTPTransport.trustTarget(for: url),
           !SSLTrustStore.allowsInsecureHTTPHostSync(domain: trustTarget) {
            pendingTestAfterTrust = true
            insecureHTTPHost = trustTarget
            return
        }
        runTest()
    }

    private func runTest() {
        guard let normalized = RadioStationValidation.normalizedURLString(urlString),
              let url = URL(string: normalized) else { return }
        isTesting = true
        testResult = nil
        Task {
            let result = await player.testRadioStream(url: url)
            isTesting = false
            switch result {
            case .success:
                testResult = .success
            case .failure(let error):
                testResult = .failure(String(
                    format: String(localized: "radio_test_failed %@"),
                    error.localizedDescription
                ))
            }
        }
    }

    private func save() {
        guard let normalizedURL = RadioStationValidation.normalizedURLString(urlString),
              let url = URL(string: normalizedURL) else { return }
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
                streamFormat: station?.streamFormat ?? RadioStreamFormat.inferred(from: url),
                bitRate: station?.bitRate,
                createdAt: station?.createdAt ?? Date(),
                modifiedAt: Date(),
                lastPlayedAt: station?.lastPlayedAt,
                sortOrder: station?.sortOrder
            )
            store.upsert(value)
            isSaving = false
            dismiss()
        }
    }
}

/// 把选中的图缩到 512 长边再转 JPEG，控制在 store 的体积上限内。
enum MacRadioLogoProcessor {
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
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(
            destination, image,
            [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination),
              output.length <= RadioStationValidation.maximumLogoBytes else { return nil }
        return output as Data
    }
}
#endif
