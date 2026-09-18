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
    /// 「转为我自己的电台」之后交给调用方接着编辑新电台；不给就直接关掉弹框。
    private let onDetach: ((RadioStation) -> Void)?

    @State private var name: String
    @State private var urlString: String
    @State private var logoData: Data?
    @State private var logoURLString: String
    @State private var isTesting = false
    @State private var isSaving = false
    @State private var testResult: TestResult?
    @State private var insecureHTTPHost: String?
    @State private var pendingTestAfterTrust = false

    private enum TestResult: Equatable {
        case success
        case failure(String)
    }

    init(station: RadioStation?, onDetach: ((RadioStation) -> Void)? = nil) {
        self.station = station
        self.onDetach = onDetach
        _name = State(initialValue: station?.name ?? "")
        _urlString = State(initialValue: station?.streamURL ?? "")
        _logoData = State(initialValue: station?.logoData)
        _logoURLString = State(initialValue: station?.remoteLogoURL ?? "")
    }

    /// 填了地址就必须是个能用的 http(s) 地址。留空表示不要远程台标。
    private var normalizedLogoURL: String? {
        RadioLogoURLPolicy.normalized(logoURLString)
    }

    private var isLogoURLAcceptable: Bool {
        logoURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || normalizedLogoURL != nil
    }

    private var canSave: Bool {
        RadioStationValidation.isValid(name: name, urlString: urlString)
            && isLogoURLAcceptable
            && !isSaving
    }

    /// 订阅电台的名称和地址归清单所有，这里只读。
    private var isSubscribed: Bool { station?.isSubscribed == true }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Rectangle().fill(PMColor.divider).frame(height: 0.5)

            ScrollView {
                VStack(alignment: .leading, spacing: PMSpace.m14) {
                    logoRow
                    logoURLRow
                    fieldRow(label: String(localized: "radio_name"), text: $name, isReadOnly: isSubscribed)
                    fieldRow(
                        label: String(localized: "radio_stream_url"),
                        text: $urlString,
                        monospaced: true,
                        isReadOnly: isSubscribed
                    )
                    if let station, station.isSubscribed {
                        subscriptionRow(for: station)
                    }
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
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: PMRadius.l, style: .continuous))
                } else if let previewURL = normalizedLogoURL {
                    // 走和列表同一套加载器，矢量台标在这里也能预览；
                    // 加载不出来时它自己会显示默认台标。
                    RadioCandidateLogoView(
                        urlString: previewURL,
                        size: 72,
                        cornerRadius: PMRadius.l
                    )
                } else {
                    RadioStationPlaceholderArtwork()
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: PMRadius.l, style: .continuous))
                }
            }
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

    private var logoURLRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            fieldRow(
                label: String(localized: "radio_logo_url"),
                text: $logoURLString,
                monospaced: true
            )
            HStack(spacing: PMSpace.s10) {
                Text(verbatim: "").frame(width: 96)
                Text(isLogoURLAcceptable ? "radio_logo_url_hint" : "radio_logo_url_invalid")
                    .font(PMFont.caption)
                    .foregroundStyle(isLogoURLAcceptable ? PMColor.textFaint : PMColor.bad)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
    }

    private func fieldRow(
        label: String,
        text: Binding<String>,
        monospaced: Bool = false,
        isReadOnly: Bool = false
    ) -> some View {
        HStack(alignment: .center, spacing: PMSpace.s10) {
            Text(label)
                .font(PMFont.bodyS)
                .foregroundStyle(PMColor.textMuted)
                .frame(width: 96, alignment: .leading)

            TextField(label, text: text, prompt: Text(verbatim: "—"))
                .textFieldStyle(.plain)
                .font(monospaced ? PMFont.mono : PMFont.bodyS)
                .foregroundStyle(isReadOnly ? PMColor.textMuted : PMColor.text)
                .padding(.horizontal, PMSpace.s10)
                .frame(height: 28)
                .background(PMColor.bgElev, in: .rect(cornerRadius: PMRadius.s))
                .overlay {
                    RoundedRectangle(cornerRadius: PMRadius.s, style: .continuous)
                        .strokeBorder(PMColor.dividerStrong, lineWidth: 0.5)
                }
                .disabled(isReadOnly)
        }
    }

    /// 订阅电台的说明和「转为我自己的电台」。
    private func subscriptionRow(for station: RadioStation) -> some View {
        HStack(alignment: .top, spacing: PMSpace.s10) {
            Text(verbatim: "")
                .frame(width: 96)

            VStack(alignment: .leading, spacing: PMSpace.s) {
                Label(RadioSubscriptionText.editorNote(for: station), systemImage: "arrow.triangle.2.circlepath")
                    .font(PMFont.caption)
                    .foregroundStyle(PMColor.textMuted)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    detach()
                } label: {
                    Text("radio_subscription_detach")
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
                .help(String(localized: "radio_subscription_detach_footer"))
            }

            Spacer(minLength: 0)
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

    private func detach() {
        guard let station,
              let ownID = store.detachFromSubscription(id: station.id),
              let own = store.station(id: ownID) else { return }
        if let onDetach {
            onDetach(own)
        } else {
            dismiss()
        }
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
              let url = URL(string: normalizedURL),
              isLogoURLAcceptable else { return }
        isSaving = true
        Task {
            let id = station?.id ?? UUID().uuidString
            let logoFileName: String?
            if let logoData {
                logoFileName = await MetadataAssetStore.shared.storeCover(logoData, for: "radio:\(id)")
            } else {
                logoFileName = nil
                // 用户把台标清掉了，磁盘上那张旧图得一起清 —— 否则锁屏与车机
                // 仍会按电台的 songID 从缓存里把它读出来。
                await MetadataAssetStore.shared.invalidateCoverCache(forSongID: "radio:\(id)")
            }
            let logoURL = normalizedLogoURL
            // 地址没动过就保留原来的来源 —— 打开编辑页按一下保存，不该把自动
            // 找来的台标"升格"成用户指定的，那会让自动发现从此再也不更新它。
            let logoSource: RadioLogoSource?
            if let logoURL {
                logoSource = logoURL == station?.remoteLogoURL
                    ? (station?.remoteLogoSource ?? .userProvidedURL)
                    : .userProvidedURL
            } else {
                logoSource = nil
            }
            if logoURL != station?.remoteLogoURL {
                await MetadataAssetStore.shared.invalidateCoverCache(
                    forSongID: RadioStationArtworkResolutionPolicy.remoteLogoCacheSongID(for: id)
                )
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
                sortOrder: station?.sortOrder,
                homepageURL: station?.homepageURL,
                remoteLogoURL: logoURL,
                remoteLogoSource: logoSource,
                folderName: station?.folderName,
                tagNames: station?.tagNames
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
        // 矢量图先栅格化再往下走：`logoData` 会进 CloudKit 同步，被电视端、
        // 小组件和锁屏直接读，那些地方没有矢量解析器。
        // NSOpenPanel 的 `.image` 类型包含 SVG，所以这条路是走得到的。
        if SVGImageSupport.looksLikeSVG(data) {
            guard let rasterized = SVGArtworkRasterizer.pngData(
                from: data,
                maximumPixelSize: 512
            ) else { return nil }
            return process(rasterized)
        }
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
