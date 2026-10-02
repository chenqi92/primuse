#if os(iOS)
import PrimuseKit
import SwiftUI

/// `primuse://tv-cloud-auth` 扫码端点的 Identifiable 包装,供 `.sheet(item:)` 驱动。
struct TVCloudAuthorizationTarget: Identifiable {
    let id = UUID()
    let link: LANCloudAuthorizationLink
}

/// 扫 Apple TV 上的代为登录二维码后弹出:在这台设备上走一遍浏览器登录,把授权用二维码里的
/// 一次性密钥加密后经局域网交给电视。本机不建音乐源,也不保存这份授权。
struct TVCloudAuthorizationSheet: View {
    let link: LANCloudAuthorizationLink

    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .ready
    /// 登录成功但还没送到电视时留着,重发不必再登录一次。
    @State private var pendingPayload: LANCloudAuthorizationPayload?

    private enum Phase: Equatable {
        case ready
        case signingIn
        case sending
        case done
        case failed(String)
    }

    private var providerName: String { link.provider.displayName }
    private var isBusy: Bool { phase == .signingIn || phase == .sending }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    Image(systemName: link.provider.iconName)
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 76, height: 76)
                        .background(link.provider.brandTint.gradient, in: .rect(cornerRadius: 18))
                        .accessibilityHidden(true)

                    VStack(spacing: 8) {
                        Text(verbatim: String(format: String(localized: "tv_cloud_auth_title"), providerName))
                            .font(.title3.weight(.bold))
                        Text("tv_cloud_auth_message")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                    VStack(spacing: 6) {
                        Text("tv_cloud_auth_code_hint")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text(verbatim: link.endpoint.displayPairCode)
                            .font(.system(size: 34, weight: .bold, design: .monospaced))
                            .accessibilityLabel(Text(verbatim: link.endpoint.pairCode.map(String.init).joined(separator: " ")))
                    }
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity)
                    .background(Color.secondary.opacity(0.1), in: .rect(cornerRadius: 14))

                    status
                    actions
                }
                .padding(24)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(phase == .done ? String(localized: "done") : String(localized: "cancel")) {
                        dismiss()
                    }
                    .disabled(isBusy)
                }
            }
        }
        .interactiveDismissDisabled(isBusy)
    }

    @ViewBuilder
    private var status: some View {
        switch phase {
        case .ready:
            EmptyView()
        case .signingIn:
            ProgressView { Text("tv_cloud_auth_signing_in") }
        case .sending:
            ProgressView { Text("tv_cloud_auth_sending") }
        case .done:
            Label("tv_cloud_auth_done", systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.green)
                .multilineTextAlignment(.center)
        case .failed(let message):
            Label {
                Text(verbatim: message)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(.subheadline)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch phase {
        case .ready, .failed:
            VStack(spacing: 10) {
                // 已经登录过、只是没送到电视时,重发是主操作;重新登录退到次要位置。
                if pendingPayload != nil {
                    Button {
                        resend()
                    } label: {
                        Label("tv_cloud_auth_resend", systemImage: "arrow.clockwise")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    Button(action: signIn) { signInLabel }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                } else {
                    Button(action: signIn) { signInLabel }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
            }
        case .signingIn, .sending, .done:
            EmptyView()
        }
    }

    private var signInLabel: some View {
        Label(String(format: String(localized: "tv_cloud_auth_sign_in"), providerName),
              systemImage: "person.crop.circle.badge.checkmark")
            .fontWeight(.semibold)
            .frame(maxWidth: .infinity)
    }

    private func signIn() {
        guard !isBusy else { return }
        guard let credentials = BuiltInCloudCredentials.credentials(for: link.provider),
              let config = Self.oauthConfig(for: link.provider, clientID: credentials.clientId) else {
            phase = .failed(String(localized: "tv_cloud_auth_unsupported"))
            return
        }
        phase = .signingIn
        Task {
            do {
                // 要求重新同意:Google 只在同意页之后才保证发 refresh token,电视离了它一小时就掉线。
                let tokens = try await OAuthService.shared.authorize(
                    config: config,
                    loginIntent: .useSignedInAccount
                )
                guard let refreshToken = tokens.refreshToken, !refreshToken.isEmpty else {
                    phase = .failed(String(format: String(localized: "tv_cloud_auth_failed_no_refresh"), providerName))
                    return
                }
                let payload = LANCloudAuthorizationPayload(
                    provider: link.provider,
                    clientID: credentials.clientId,
                    accessToken: tokens.accessToken,
                    refreshToken: refreshToken,
                    expiresAt: tokens.expiresAt,
                    tokenType: tokens.tokenType
                )
                pendingPayload = payload
                await send(payload)
            } catch OAuthError.userCancelled {
                phase = .ready
            } catch {
                plog("☁️ TV companion sign-in failed provider=\(link.provider.rawValue) error=\(error.localizedDescription)")
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func resend() {
        guard !isBusy, let pendingPayload else { return }
        Task { await send(pendingPayload) }
    }

    private func send(_ payload: LANCloudAuthorizationPayload) async {
        phase = .sending
        guard let url = link.requestURL,
              let body = try? payload.jsonData(),
              let sealed = LANSyncCrypto.seal(body, key: link.endpoint.key) else {
            phase = .failed(String(localized: "tv_cloud_auth_failed_tv"))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(link.endpoint.pairCode, forHTTPHeaderField: "X-Primuse-Pair-Code")
        request.timeoutInterval = 30
        do {
            let (_, response) = try await URLSession.shared.upload(for: request, from: sealed)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            plog("☁️ TV companion sign-in sent provider=\(link.provider.rawValue) HTTP \(status)")
            switch status {
            case 200:
                pendingPayload = nil
                phase = .done
            case 403:
                // 二维码已换过或密钥不对,同一份授权再发也进不去。
                pendingPayload = nil
                phase = .failed(String(localized: "tv_cloud_auth_failed_rejected"))
            default:
                phase = .failed(String(localized: "tv_cloud_auth_failed_tv"))
            }
        } catch {
            plog("☁️ TV companion sign-in could not reach Apple TV — \(error.localizedDescription)")
            phase = .failed(String(localized: "tv_cloud_auth_failed_network"))
        }
    }

    private static func oauthConfig(for provider: MusicSourceType, clientID: String) -> CloudOAuthConfig? {
        switch provider {
        case .googleDrive: return GoogleDriveSource.oauthConfig(clientId: clientID)
        default: return nil
        }
    }
}
#endif
