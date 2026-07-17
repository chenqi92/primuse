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
                    Text(String(localized: "cloud_oauth_browser_subtitle"))
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
            Text(String(localized: "cloud_oauth_checking"))
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

                if source.type == .pan115 {
                    pendingApprovalBanner
                }

                Image(systemName: "key.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.orange.gradient)

                VStack(spacing: 8) {
                    Text(String(localized: "cloud_setup_needs_creds_title"))
                        .font(.title3).fontWeight(.bold)
                    Text(String(localized: "cloud_setup_needs_creds_desc"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }

                VStack(alignment: .leading, spacing: 12) {
                    guideStep(number: 1, text: platformGuideText)
                    guideStep(number: 2, text: String(localized: "cloud_setup_step_create_app"))
                    guideStep(number: 3, text: String(localized: "cloud_setup_step_back_to_app"))
                    guideStep(number: 4, text: String(localized: "cloud_setup_step_connect"))
                }
                .padding(.horizontal, 30)

                Spacer().frame(height: 40)
            }
        }
    }

    /// 115 暂未对普通用户开放的说明横幅:告知正在申请官方接入资质。
    private var pendingApprovalBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "clock.badge.exclamationmark")
                .font(.system(size: 20))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(String(format: String(localized: "cloud_pending_unavailable_format"), source.type.displayName))
                    .font(.subheadline).fontWeight(.semibold)
                    .foregroundStyle(.primary)
                Text(String(format: String(localized: "cloud_pending_desc_format"), source.type.displayName))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: .rect(cornerRadius: 12))
        .padding(.horizontal, 24)
    }

    private var platformGuideText: String {
        switch source.type {
        case .baiduPan: return String(localized: "cloud_guide_baidu")
        case .aliyunDrive: return String(localized: "cloud_guide_aliyun")
        case .googleDrive: return String(localized: "cloud_guide_google")
        case .oneDrive: return String(localized: "cloud_guide_onedrive")
        case .dropbox: return String(localized: "cloud_guide_dropbox")
        case .pan115: return String(localized: "cloud_guide_pan115")
        case .pan123: return String(localized: "cloud_guide_pan123")
        default: return String(localized: "cloud_guide_default")
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
                Text(String(format: String(localized: "cloud_auth_connect_format"), source.type.displayName))
                    .font(.title3).fontWeight(.semibold)
                Text(String(localized: "cloud_auth_prompt_mac"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 36)
            }

            Button {
                startOAuth()
            } label: {
                Label(String(localized: "cloud_auth_button"), systemImage: "link.badge.plus")
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
                Text(String(format: String(localized: "cloud_auth_connect_format"), source.type.displayName))
                    .font(.title3).fontWeight(.bold)
                Text(String(localized: "cloud_auth_prompt_ios"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 36)
            }

            Button {
                startOAuth()
            } label: {
                Label(String(localized: "cloud_auth_button"), systemImage: "link.badge.plus")
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
                Text(String(format: String(localized: "cloud_authorizing_title_format"), source.type.displayName))
                    .font(.title3.weight(.semibold))
                Text(String(localized: "cloud_authorizing_waiting"))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 12) {
                Text(String(localized: "cloud_authorizing_steps"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                oauthStep(number: 1, text: String(format: String(localized: "cloud_authorizing_step1_format"), oauthProviderHost))
                oauthStep(number: 2, text: String(localized: "cloud_authorizing_step2"))
                oauthStep(number: 3, text: String(format: String(localized: "cloud_authorizing_step3_format"), oauthCallbackDisplay))
                oauthStep(number: 4, text: String(localized: "cloud_authorizing_step4"))
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
                Text(String(format: String(localized: "cloud_authorizing_listening_format"), oauthBridgeDisplay))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(.quaternary.opacity(0.22), in: .capsule)

            Text(String(localized: "cloud_authorizing_hint"))
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
        default: return String(localized: "cloud_host_default")
        }
    }

    private var oauthCallbackDisplay: String {
        source.type == .pan123
            ? Pan123Source.redirectURI
            : "\(CloudOAuthConfig.callbackScheme)://callback"
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
            Text(String(localized: "cloud_failed_title"))
                .font(.headline)
            Text(errorMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            HStack(spacing: 16) {
                Button { startOAuth() } label: {
                    Label(String(localized: "cloud_retry_auth"), systemImage: "arrow.clockwise")
                        .fontWeight(.medium)
                }
                .buttonStyle(.borderedProminent)

                Button { checkStatus() } label: {
                    Label(String(localized: "cloud_recheck"), systemImage: "arrow.triangle.2.circlepath")
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
        // App-owned credentials must win over stale per-source values entered
        // before built-in support existed. This applies to both Baidu and 123.
        if source.type == .baiduPan || source.type == .pan123,
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
                errorMessage = String(localized: "cloud_err_no_client_id")
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
                    throw OAuthError.tokenExchangeFailed(String(localized: "cloud_err_token_save_failed"))
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
