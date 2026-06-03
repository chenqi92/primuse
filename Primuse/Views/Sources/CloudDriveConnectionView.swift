import SwiftUI
import PrimuseKit

/// Connection flow view for cloud drive sources (Baidu, Aliyun, Google, OneDrive, Dropbox).
/// Handles: credential check → OAuth authorization → file browsing.
struct CloudDriveConnectionView: View {
    let source: MusicSource
    @Binding var selectedDirectories: [String]
    @Environment(\.dismiss) private var dismiss
    @Environment(SourceManager.self) private var sourceManager
    @Environment(SourcesStore.self) private var sourcesStore

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
            #if os(macOS)
            macAuthChrome
            #else
            NavigationStack {
                stepContent
                .navigationTitle(source.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("cancel") { dismiss() }
                            .keyboardShortcut(.cancelAction)
                    }
                }
            }
            .onAppear { checkStatus() }
            #endif
        }
    }

    @ViewBuilder
    private var stepContent: some View {
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

    #if os(macOS)
    /// 云盘 OAuth 授权页的设计稿外壳 —— closeOnly traffic-light 窗头
    /// (「百度网盘 · OAuth」+ 授权说明) + 步骤内容 + 取消底栏, 跟其它源弹框统一,
    /// 不再用 NavigationStack 的原生标题栏 (那个跟整套自定义弹框对不上)。
    private var macAuthChrome: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                PMWindowTrafficLights(closeOnly: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "\(source.type.displayName) · OAuth")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(PMColor.text)
                    Text(verbatim: "系统浏览器授权")
                        .font(.system(size: 11))
                        .foregroundStyle(PMColor.textFaint)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(height: 56)

            Rectangle().fill(PMColor.divider).frame(height: 0.5)

            stepContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Rectangle().fill(PMColor.divider).frame(height: 0.5)

            HStack {
                Spacer()
                Button("cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(PMColor.text)
                    .padding(.horizontal, 16)
                    .frame(height: 30)
                    .background(PMColor.glassBtn, in: .rect(cornerRadius: 7))
            }
            .padding(.horizontal, 16)
            .frame(height: 56)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PMColor.bg)
        .onAppear { checkStatus() }
    }

    #endif

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
        case .pan115: return "前往 115.com 开放平台申请开发者应用"
        case .pan123: return "前往 123pan.cn/developer 申请开发者应用"
        default: return "前往对应平台的开发者中心注册"
        }
    }

    private func guideStep(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            #if os(macOS)
            // macOS 用 SF Symbol 数字圆,跟系统字号风格一致,颜色用 accent。
            Image(systemName: "\(number).circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(Color.accentColor)
                .padding(.top, 1)
            #else
            Text("\(number)")
                .font(.caption).fontWeight(.bold)
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Color.accentColor.gradient)
                .clipShape(Circle())
            #endif
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.primary)
        }
    }

    // MARK: - Auth Prompt View

    private var authPromptView: some View {
        #if os(macOS)
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: cloudIcon)
                .font(.system(size: 42))
                .foregroundStyle(.blue.gradient)

            VStack(spacing: 6) {
                Text("连接 \(source.type.displayName)")
                    .font(.title3).fontWeight(.semibold)
                Text("点击「授权连接」,将在系统浏览器中打开授权页。\n登录并同意授权后会自动返回猿音。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 36)
            }

            Button {
                startOAuth()
            } label: {
                Label("授权连接", systemImage: "link.badge.plus")
                    .frame(maxWidth: 220)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)

            if !errorMessage.isEmpty {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 30)
                    .multilineTextAlignment(.center)
            }

            Spacer()
        }
        #else
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
        #endif
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
        VStack(spacing: 22) {
            Spacer(minLength: 18)

            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.14))
                Image(systemName: cloudIcon)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 72, height: 72)

            VStack(spacing: 7) {
                Text("\(source.type.displayName) · 授权")
                    .font(.title3.weight(.semibold))
                Text("等待系统浏览器返回授权码…")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("授权步骤")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                oauthStep(number: 1, text: "已在系统浏览器打开 \(oauthProviderHost)")
                oauthStep(number: 2, text: "登录账号并确认读取音乐文件权限")
                oauthStep(number: 3, text: "浏览器重定向到 \(oauthCallbackDisplay)")
                oauthStep(number: 4, text: "猿音接收回调并保存访问令牌")
            }
            .padding(18)
            .frame(maxWidth: 430, alignment: .leading)
            .background(.quaternary.opacity(0.24), in: .rect(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.quaternary, lineWidth: 0.5)
            }

            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("正在监听 URL Scheme · \(oauthBridgeDisplay)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(.quaternary.opacity(0.22), in: .capsule)

            Text("授权完成后此窗口会自动进入目录浏览器。请不要关闭系统浏览器中的回调页。")
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            Spacer(minLength: 18)
        }
        .padding(.horizontal, 34)
    }

    private func oauthStep(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: "\(number).circle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var oauthProviderHost: String {
        switch source.type {
        case .baiduPan: return "pan.baidu.com"
        case .aliyunDrive: return "open.aliyundrive.com"
        case .googleDrive: return "accounts.google.com"
        case .oneDrive: return "login.microsoftonline.com"
        case .dropbox: return "dropbox.com"
        case .pan115: return "115.com"
        case .pan123: return "123pan.com"
        default: return "授权服务"
        }
    }

    private var oauthCallbackDisplay: String {
        "\(CloudOAuthConfig.callbackScheme)://callback"
    }

    private var oauthBridgeDisplay: String {
        #if os(macOS)
        "MacOAuthBridge.shared"
        #else
        "OAuth URL Scheme"
        #endif
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
        // Baidu is currently shipped with app-owned credentials, so always prefer
        // the built-in pair over any stale per-source client_id the user may have
        // entered before built-in support existed.
        if source.type == .baiduPan,
           let builtIn = BuiltInCloudCredentials.credentials(for: source.type) {
            return .init(clientId: builtIn.clientId, clientSecret: builtIn.clientSecret)
        }

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
            plog("☁️ OAuth starting type=\(source.type.rawValue) sourceID=\(source.id) clientId=\(creds.clientId) redirect=\(config.redirectURI) scopes=\(config.scopes)")

            do {
                let tokens = try await OAuthService.shared.authorize(config: config)
                await tokenManager.saveTokens(tokens)
                guard await tokenManager.getTokens() != nil else {
                    plog("⚠️ OAuth token save verification failed type=\(source.type.rawValue) sourceID=\(source.id)")
                    throw OAuthError.tokenExchangeFailed("授权令牌保存失败")
                }

                // Refresh the connector so it picks up the new tokens
                await sourceManager.refreshConnector(for: source.id)

                // Stage 4a: identify the upstream OAuth account and
                // link this mount to a CloudAccount entity. Same
                // upstream account on every device → same account.id
                // (deterministic SHA-256 of provider:uid). Future
                // re-OAuth of the same account discovers the existing
                // record instead of duplicating; the launch migration
                // (stage 4c) reads cloudAccountID to merge legacy
                // duplicates.
                await linkMountToCloudAccount()

                withAnimation { step = .browsing }
            } catch let error as OAuthError {
                if case .userCancelled = error {
                    withAnimation { step = .readyToAuth }
                } else {
                    errorMessage = error.localizedDescription
                    withAnimation { step = .failed }
                }
            } catch {
                errorMessage = error.localizedDescription
                withAnimation { step = .failed }
            }
        }
    }

    /// Resolve `accountIdentifier()` from the freshly-OAuth-ed connector
    /// and store the resulting `(provider, accountUID)` as a
    /// `CloudAccount`. The mount's `cloudAccountID` is updated via
    /// `SourcesStore.update` (which bumps modifiedAt + triggers
    /// CloudKit push). Failure is non-fatal: the mount keeps
    /// `cloudAccountID == nil` and the next OAuth attempt re-tries.
    private func linkMountToCloudAccount() async {
        let conn = sourceManager.connector(for: source)
        guard let oauthConn = conn as? OAuthCloudSource else {
            plog("⚠️ Account link: connector for \(source.type.rawValue) doesn't implement OAuthCloudSource")
            return
        }
        do {
            let accountUID = try await oauthConn.accountIdentifier()
            let accountID = CloudAccount.deriveID(provider: source.type, accountUID: accountUID)
            // Reuse an existing record (same id since derivation is
            // deterministic) — bumping its modifiedAt via upsert means
            // the next CloudKit push refreshes the server copy.
            let existing = sourcesStore.account(provider: source.type, accountUID: accountUID)
            let account = existing ?? CloudAccount(
                id: accountID,
                provider: source.type,
                accountUID: accountUID,
                createdAt: Date()
            )
            sourcesStore.upsertAccount(account)
            sourcesStore.update(source.id) { $0.cloudAccountID = account.id }
            plog("☁️ OAuth account linked: mount=\(source.id) → account=\(accountID) provider=\(source.type.rawValue) uid=\(accountUID) reused=\(existing != nil)")
        } catch {
            plog("⚠️ Account link failed for mount=\(source.id) (\(source.type.rawValue)): \(error.localizedDescription)")
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
        case .pan115:
            return U115Source.oauthConfig(clientId: clientId, clientSecret: clientSecret)
        case .pan123:
            return Pan123Source.oauthConfig(clientId: clientId, clientSecret: clientSecret)
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
