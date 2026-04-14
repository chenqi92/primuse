import SwiftUI
import PrimuseKit

/// Connection flow view for cloud drive sources (Baidu, Aliyun, Google, OneDrive, Dropbox).
/// Handles: credential check → OAuth authorization → file browsing.
struct CloudDriveConnectionView: View {
    let source: MusicSource
    @Binding var selectedDirectories: [String]
    @Environment(\.dismiss) private var dismiss
    @Environment(SourceManager.self) private var sourceManager

    @State private var step: FlowStep = .checking
    @State private var errorMessage = ""
    @State private var isAuthorizing = false

    enum FlowStep {
        case checking     // Checking if credentials/token exist
        case needsSetup   // No client_id configured
        case readyToAuth  // Has client_id, needs OAuth
        case authorizing  // OAuth in progress
        case browsing     // Authorized, browsing files
        case failed       // Something went wrong
    }

    var body: some View {
        if step == .browsing {
            // ConnectorDirectoryBrowserView has its own NavigationStack
            ConnectorDirectoryBrowserView(
                source: source,
                connector: sourceManager.connector(for: source),
                selectedDirectories: $selectedDirectories
            )
        } else {
            NavigationStack {
                Group {
                    switch step {
                    case .checking:
                        checkingView
                    case .needsSetup:
                        setupGuideView
                    case .readyToAuth:
                        authPromptView
                    case .authorizing:
                        authorizingView
                    case .failed:
                        failedView
                    case .browsing:
                        EmptyView() // Handled above
                    }
                }
                .navigationTitle(source.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("cancel") { dismiss() }
                    }
                }
            }
            .onAppear { checkStatus() }
        }
    }

    // MARK: - Checking View

    private var checkingView: some View {
        VStack(spacing: 20) {
            Spacer()
            ProgressView().scaleEffect(1.3)
            Text("正在检查授权状态…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: - Setup Guide View

    private var setupGuideView: some View {
        ScrollView {
            VStack(spacing: 24) {
                Spacer().frame(height: 30)

                Image(systemName: "key.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.orange.gradient)

                VStack(spacing: 8) {
                    Text("需要配置开发者凭证")
                        .font(.title3).fontWeight(.bold)
                    Text("请先在「编辑源」中填写 Client ID，然后再回来授权连接。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }

                VStack(alignment: .leading, spacing: 12) {
                    guideStep(number: 1, text: platformGuideText)
                    guideStep(number: 2, text: "创建应用，获取 Client ID（和 Client Secret）")
                    guideStep(number: 3, text: "回到猿音，编辑此源，填入凭证")
                    guideStep(number: 4, text: "再次点击「连接」即可授权")
                }
                .padding(.horizontal, 30)

                Spacer().frame(height: 40)
            }
        }
    }

    private var platformGuideText: String {
        switch source.type {
        case .baiduPan: return "前往 pan.baidu.com/union 注册开发者应用"
        case .aliyunDrive: return "前往 alipan.com/developer 申请接入"
        case .googleDrive: return "前往 console.cloud.google.com 创建 OAuth 凭证"
        case .oneDrive: return "前往 entra.microsoft.com 注册应用"
        case .dropbox: return "前往 dropbox.com/developers/apps 创建应用"
        default: return "前往对应平台的开发者中心注册"
        }
    }

    private func guideStep(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.caption).fontWeight(.bold)
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Color.accentColor.gradient)
                .clipShape(Circle())
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.primary)
        }
    }

    // MARK: - Auth Prompt View

    private var authPromptView: some View {
        VStack(spacing: 28) {
            Spacer()

            Image(systemName: cloudIcon)
                .font(.system(size: 52))
                .foregroundStyle(.blue.gradient)

            VStack(spacing: 8) {
                Text("连接 \(source.type.displayName)")
                    .font(.title3).fontWeight(.bold)
                Text("点击下方按钮，将在浏览器中打开授权页面。\n登录并同意授权后，猿音即可访问您的文件。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 36)
            }

            Button {
                startOAuth()
            } label: {
                Label("授权连接", systemImage: "link.badge.plus")
                    .font(.body).fontWeight(.semibold)
                    .frame(maxWidth: 260).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            if !errorMessage.isEmpty {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 30)
                    .multilineTextAlignment(.center)
            }

            Spacer()
        }
    }

    private var cloudIcon: String {
        switch source.type {
        case .googleDrive: return "externaldrive.badge.icloud"
        case .oneDrive: return "cloud.fill"
        case .dropbox: return "shippingbox.fill"
        default: return "cloud.fill"
        }
    }

    // MARK: - Authorizing View

    private var authorizingView: some View {
        VStack(spacing: 20) {
            Spacer()
            ProgressView().scaleEffect(1.3)
            VStack(spacing: 6) {
                Text("正在授权…")
                    .font(.headline)
                Text("请在弹出的浏览器中完成登录")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    // MARK: - Failed View

    private var failedView: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "xmark.circle")
                .font(.system(size: 52))
                .foregroundStyle(.red)
            Text("连接失败")
                .font(.headline)
            Text(errorMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            HStack(spacing: 16) {
                Button { startOAuth() } label: {
                    Label("重试授权", systemImage: "arrow.clockwise")
                        .fontWeight(.medium)
                }
                .buttonStyle(.borderedProminent)

                Button { checkStatus() } label: {
                    Label("重新检查", systemImage: "arrow.triangle.2.circlepath")
                        .fontWeight(.medium)
                }
                .buttonStyle(.bordered)
            }
            Spacer()
        }
    }

    // MARK: - Logic

    private func checkStatus() {
        step = .checking
        errorMessage = ""

        Task {
            let tokenManager = CloudTokenManager(sourceID: source.id)

            // Check if we already have valid tokens
            if let tokens = await tokenManager.getTokens(), !tokens.isExpired {
                // Already authorized — go directly to browsing
                withAnimation { step = .browsing }
                return
            }

            // Resolve credentials with a preference for built-in credentials unless
            // the source explicitly stores a custom client_id in the model.
            if let creds = await resolvedCredentials(using: tokenManager) {
                await tokenManager.saveAppCredentials(creds)
                withAnimation { step = .readyToAuth }
            } else {
                // No credentials at all — need manual setup
                withAnimation { step = .needsSetup }
            }
        }
    }

    private func resolvedCredentials(using tokenManager: CloudTokenManager) async -> CloudTokenManager.AppCredentials? {
        let hasCustomCredentials = !(source.username?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)

        if hasCustomCredentials,
           let creds = await tokenManager.getAppCredentials(),
           !creds.clientId.isEmpty {
            return creds
        }

        if let builtIn = BuiltInCloudCredentials.credentials(for: source.type) {
            return .init(clientId: builtIn.clientId, clientSecret: builtIn.clientSecret)
        }

        if let creds = await tokenManager.getAppCredentials(), !creds.clientId.isEmpty {
            return creds
        }

        return nil
    }

    private func startOAuth() {
        step = .authorizing
        errorMessage = ""

        Task {
            let tokenManager = CloudTokenManager(sourceID: source.id)
            guard let creds = await resolvedCredentials(using: tokenManager) else {
                errorMessage = "未配置 Client ID"
                withAnimation { step = .needsSetup }
                return
            }

            await tokenManager.saveAppCredentials(creds)

            let config = oauthConfig(for: source.type, clientId: creds.clientId, clientSecret: creds.clientSecret)

            do {
                let tokens = try await OAuthService.shared.authorize(config: config)
                await tokenManager.saveTokens(tokens)

                // Refresh the connector so it picks up the new tokens
                await sourceManager.refreshConnector(for: source.id)

                withAnimation { step = .browsing }
            } catch let error as OAuthError {
                if case .userCancelled = error {
                    withAnimation { step = .readyToAuth }
                } else {
                    errorMessage = error.localizedDescription ?? "授权失败"
                    withAnimation { step = .failed }
                }
            } catch {
                errorMessage = error.localizedDescription
                withAnimation { step = .failed }
            }
        }
    }

    private func oauthConfig(for type: MusicSourceType, clientId: String, clientSecret: String?) -> CloudOAuthConfig {
        switch type {
        case .baiduPan:
            return BaiduPanSource.oauthConfig(clientId: clientId, clientSecret: clientSecret)
        case .aliyunDrive:
            return AliyunDriveSource.oauthConfig(clientId: clientId, clientSecret: clientSecret)
        case .googleDrive:
            return GoogleDriveSource.oauthConfig(clientId: clientId)
        case .oneDrive:
            return OneDriveSource.oauthConfig(clientId: clientId)
        case .dropbox:
            return DropboxSource.oauthConfig(clientId: clientId, clientSecret: clientSecret)
        default:
            // Fallback — shouldn't happen
            return CloudOAuthConfig(
                authURL: "", tokenURL: "",
                clientId: clientId, clientSecret: clientSecret,
                scopes: [], redirectURI: "\(CloudOAuthConfig.callbackScheme)://callback"
            )
        }
    }
}
