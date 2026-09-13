#if os(tvOS)
import PrimuseKit
import SwiftUI

/// Apple TV 上的云盘授权页。
///
/// 电视没有浏览器、也不适合输长网址,所以不复用手机端的 `ASWebAuthenticationSession`,
/// 改走提供方为无浏览器设备准备的通道:电视画二维码,用户拿手机扫码并在手机上确认,
/// 电视这边按提供方给的间隔轮询,拿到 token 后写进与 iPhone / Mac 同一份钥匙串。
struct TVCloudAuthView: View {
    @Environment(\.dismiss) private var dismiss

    let source: MusicSource
    let clientID: String
    let clientSecret: String?
    /// 授权成功回调:此时 token 已落钥匙串,调用方继续保存音乐源即可。
    let onAuthorized: () -> Void

    @State private var session: CloudDeviceAuthSession?
    @State private var phase: Phase = .starting
    @State private var manualCode = ""
    @State private var message: String?
    @State private var pollTask: Task<Void, Never>?

    private enum Phase: Equatable {
        case starting
        case waiting
        case scanned
        case redeeming
        case failed(String)
        case done
    }

    var body: some View {
        ZStack {
            TVAmbientBackdrop(tint: TVColor.brand, tint2: TVColor.brandSecondary, strength: 0.45)
            TVColor.bg.opacity(0.38).ignoresSafeArea()

            VStack(spacing: 28) {
                header
                content
                footer
            }
            .frame(maxWidth: 980)
            .padding(48)
            .tvPanel(radius: 28)
            .padding(.horizontal, 120)
        }
        .onAppear(perform: start)
        .onDisappear { pollTask?.cancel() }
        .onExitCommand { dismiss() }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: source.type.iconName)
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(TVColor.brand)
            Text(PMString("ext.tv.cloud.auth.title", source.type.displayName))
                .tvFont(.pageTitle).foregroundStyle(TVColor.text)
            Text(subtitle).tvFont(.caption).foregroundStyle(TVColor.textFaint)
                .multilineTextAlignment(.center)
        }
    }

    private var subtitle: String {
        switch session?.kind {
        case .manualCode: return PMString("ext.tv.cloud.auth.manualSubtitle")
        default: return PMString("ext.tv.cloud.auth.scanSubtitle")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .starting:
            ProgressView().tint(TVColor.brand).frame(height: 300)
        case .failed(let text):
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 40)).foregroundStyle(TVColor.warn)
                Text(text).tvFont(.caption).foregroundStyle(TVColor.textMuted)
                    .multilineTextAlignment(.center).lineSpacing(4)
            }
            .frame(height: 300)
        case .done:
            VStack(spacing: 14) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 48)).foregroundStyle(TVColor.brand)
                Text(PMString("ext.tv.cloud.auth.done")).tvFont(.body).foregroundStyle(TVColor.text)
            }
            .frame(height: 300)
        case .waiting, .scanned, .redeeming:
            if let session {
                HStack(alignment: .center, spacing: 44) {
                    qrCodeView(session.qrCode)
                    VStack(alignment: .leading, spacing: 18) {
                        if let userCode = session.userCode, !userCode.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                TVEyebrow(text: PMString("ext.tv.cloud.auth.userCode"))
                                Text(userCode)
                                    .tvFont(.heroTitle, weight: .bold, design: .monospaced)
                                    .foregroundStyle(TVColor.text)
                            }
                        }
                        if let url = session.verificationURL, !url.isEmpty,
                           session.kind != .manualCode {
                            VStack(alignment: .leading, spacing: 6) {
                                TVEyebrow(text: PMString("ext.tv.cloud.auth.openURL"))
                                Text(url).tvFont(.meta).foregroundStyle(TVColor.textMuted)
                                    .lineLimit(3)
                            }
                        }
                        statusLine
                        if session.kind == .manualCode {
                            TVFormField(
                                label: PMString("ext.tv.cloud.auth.codeField"),
                                text: $manualCode,
                                mono: true
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 300)
            }
        }
    }

    @ViewBuilder
    private func qrCodeView(_ qrCode: CloudDeviceAuthQRCode) -> some View {
        switch qrCode {
        case .content(let payload):
            TVQRCode(content: payload, size: 300)
        case .imageURL(let url):
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.interpolation(.none).resizable().scaledToFit()
                case .failure:
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(TVColor.warn)
                default:
                    ProgressView().tint(TVColor.brand)
                }
            }
            .padding(12)
            .frame(width: 300, height: 300)
            .background(.white, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private var statusLine: some View {
        HStack(spacing: 10) {
            if phase == .waiting || phase == .scanned || phase == .redeeming {
                ProgressView().tint(TVColor.brand)
            }
            Text(message ?? statusText).tvFont(.meta).foregroundStyle(TVColor.textFaint)
        }
    }

    private var statusText: String {
        switch phase {
        case .scanned: return PMString("ext.tv.cloud.auth.scanned")
        case .redeeming: return PMString("ext.tv.cloud.auth.redeeming")
        default: return PMString("ext.tv.cloud.auth.waiting")
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            if session?.kind == .manualCode {
                TVFocusButton(radius: 14, accent: TVColor.brand, scale: 1.04, lift: 0, action: redeem) { focused in
                    Text(PMString("ext.tv.cloud.auth.confirm"))
                        .tvFont(.meta, weight: .bold).foregroundStyle(TVColor.onBrand)
                        .frame(maxWidth: .infinity).padding(.vertical, 18)
                        .background(TVColor.brand.opacity(focused ? 1 : 0.88),
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .disabled(manualCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            TVFocusButton(radius: 14, scale: 1.04, lift: 0, action: start) { focused in
                Text(PMString("ext.tv.cloud.auth.refresh"))
                    .tvFont(.meta, weight: .medium).foregroundStyle(TVColor.text)
                    .frame(maxWidth: .infinity).padding(.vertical, 18)
                    .background(focused ? TVColor.surfaceStrong : TVColor.surface,
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            TVFocusButton(radius: 14, scale: 1.04, lift: 0, action: { dismiss() }) { focused in
                Text(PMString("ext.tv.sources.cancel"))
                    .tvFont(.meta, weight: .medium).foregroundStyle(TVColor.text)
                    .frame(maxWidth: .infinity).padding(.vertical, 18)
                    .background(focused ? TVColor.surfaceStrong : TVColor.surfaceSubtle,
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }

    // MARK: - 流程

    private func start() {
        pollTask?.cancel()
        message = nil
        phase = .starting
        let type = source.type
        let id = clientID
        let secret = clientSecret
        pollTask = Task {
            do {
                let started = try await CloudDeviceAuthService.shared.begin(
                    provider: type, clientID: id, clientSecret: secret
                )
                guard !Task.isCancelled else { return }
                session = started
                phase = .waiting
                if started.kind != .manualCode {
                    await pollLoop(started)
                }
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed(Self.describe(error))
            }
        }
    }

    private func pollLoop(_ started: CloudDeviceAuthSession) async {
        let deadline = Date().addingTimeInterval(started.expiresIn)
        let step = UInt64(max(1, started.interval) * 1_000_000_000)
        while !Task.isCancelled, Date() < deadline {
            try? await Task.sleep(nanoseconds: step)
            guard !Task.isCancelled else { return }
            do {
                let progress = try await CloudDeviceAuthService.shared.poll(
                    started, clientID: clientID, clientSecret: clientSecret
                )
                switch progress {
                case .pending:
                    continue
                case .scanned:
                    phase = .scanned
                case .denied:
                    phase = .failed(PMString("ext.tv.cloud.auth.denied"))
                    return
                case .expired:
                    phase = .failed(PMString("ext.tv.cloud.auth.expired"))
                    return
                case .authorized(let result):
                    await finish(result)
                    return
                }
            } catch {
                phase = .failed(Self.describe(error))
                return
            }
        }
        if !Task.isCancelled {
            phase = .failed(PMString("ext.tv.cloud.auth.expired"))
        }
    }

    private func redeem() {
        guard let started = session else { return }
        pollTask?.cancel()
        phase = .redeeming
        let code = manualCode
        pollTask = Task {
            do {
                let result = try await CloudDeviceAuthService.shared.redeemManualCode(
                    started, code: code, clientID: clientID, clientSecret: clientSecret
                )
                await finish(result)
            } catch {
                phase = .failed(Self.describe(error))
            }
        }
    }

    private func finish(_ result: CloudDeviceAuthResult) async {
        await TVCloudConnectorFactory.persist(sourceID: source.id, result: result)
        phase = .done
        onAuthorized()
    }

    private static func describe(_ error: Error) -> String {
        guard let authError = error as? CloudDeviceAuthError else {
            return error.localizedDescription
        }
        switch authError {
        case .unsupportedProvider:
            return PMString("ext.tv.cloud.auth.unsupported")
        case .missingClientCredentials:
            return PMString("ext.tv.cloud.auth.missingClient")
        case .badServerResponse(let code):
            return PMString("ext.tv.cloud.auth.serverError", String(code))
        case .invalidResponse, .cannotBuildURL:
            return PMString("ext.tv.cloud.auth.invalidResponse")
        case .providerRejected(let detail):
            return detail.isEmpty
                ? PMString("ext.tv.cloud.auth.invalidResponse")
                : PMString("ext.tv.cloud.auth.rejected", detail)
        }
    }
}
#endif
