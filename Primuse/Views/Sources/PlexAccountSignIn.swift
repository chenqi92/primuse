import PrimuseKit
import SwiftUI
#if os(iOS)
import AuthenticationServices
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// 「使用 Plex 账号登录」这一块的状态：建 PIN → 打开授权页 → 轮询 → 列服务器。
///
/// 授权页只负责让用户点「允许」，结果靠轮询 PIN 拿：iPhone 上授权页是系统的网页登录面板，
/// Mac 上交给默认浏览器（沙盒下的网页登录面板经常不显示，见 `OAuthService`）。
@MainActor
@Observable
final class PlexAccountSignInModel {
    enum Phase: Equatable {
        case idle
        case waitingForAuthorization
        case loadingServers
        case servers([PlexResource])
        case failed(String)
    }

    private struct AuthorizationPageDismissed: Error {}

    /// 轮询途中网络抖一下不该让整次登录失败，连续失败这么多次才放弃。
    private static let maximumConsecutivePollFailures = 5
    #if os(iOS)
    private static let callbackScheme = "primuse"
    private static let forwardURL = URL(string: "primuse://plex-auth")
    #else
    private static let forwardURL: URL? = nil
    #endif

    private(set) var phase: Phase = .idle
    @ObservationIgnored private var accountToken: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var authorizationPageClosed = false
    /// 用到时才建：表单每次重建视图结构体都会求一次 `@State` 的初值。
    @ObservationIgnored private var client: PlexAccountClient?
    #if os(iOS)
    @ObservationIgnored private var webSession: ASWebAuthenticationSession?
    @ObservationIgnored private let anchorProvider = PlexAuthorizationAnchorProvider()
    #endif

    init(client: PlexAccountClient? = nil) {
        self.client = client
        #if DEBUG
        // 截图用：PRIMUSE_DEBUG_PLEX=servers 直接显示演示服务器清单，不连 plex.tv。
        if ProcessInfo.processInfo.environment["PRIMUSE_DEBUG_PLEX"] == "servers" {
            accountToken = "debug-account-token"
            phase = .servers(PlexResourceList.debugFixtureServers)
        }
        #endif
    }

    private func accountClient() -> PlexAccountClient {
        if let client { return client }
        let created = PlexAccountClient.standard()
        client = created
        return created
    }

    var isBusy: Bool {
        phase == .waitingForAuthorization || phase == .loadingServers
    }

    var hasRelayOnlyServer: Bool {
        guard case let .servers(servers) = phase else { return false }
        return servers.contains { PlexServerConnectionPlanner.routes(for: $0).reachesOnlyThroughRelay }
    }

    func signIn() {
        cancel()
        authorizationPageClosed = false
        accountToken = nil
        phase = .waitingForAuthorization
        task = Task { [weak self] in
            await self?.runSignIn()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        closeAuthorizationPage()
        if isBusy { phase = .idle }
    }

    func selection(for resource: PlexResource) -> PlexServerSelection? {
        guard let accountToken else { return nil }
        return PlexServerSelection(resource: resource, accountToken: accountToken)
    }

    private func runSignIn() async {
        let client = accountClient()
        do {
            let pin = try await client.createPin(strong: true)
            try Task.checkCancellation()
            openAuthorizationPage(PlexAccountAPI.authorizationPageURL(
                clientIdentifier: client.clientIdentifier,
                code: pin.code,
                forwardURL: Self.forwardURL
            ))
            let token = try await waitForToken(pinID: pin.id, client: client)
            closeAuthorizationPage()
            accountToken = token
            plog("🎞️ Plex sign-in authorized")
            phase = .loadingServers
            let servers = try await client.servers(accountToken: token)
            try Task.checkCancellation()
            plog("🎞️ Plex servers listed count=\(servers.count) shared=\(servers.filter { !$0.isOwned }.count)")
            phase = .servers(servers)
        } catch is CancellationError {
            closeAuthorizationPage()
        } catch is AuthorizationPageDismissed {
            plog("🎞️ Plex sign-in page closed before authorizing")
            phase = .idle
        } catch {
            closeAuthorizationPage()
            guard !Task.isCancelled else { return }
            plog("⚠️ Plex sign-in failed: \(error)")
            phase = .failed(Self.message(for: error))
        }
    }

    private func waitForToken(pinID: Int, client: PlexAccountClient) async throws -> String {
        var consecutiveFailures = 0
        while true {
            try await Task.sleep(for: PlexAccountAPI.pollInterval)
            // 授权页关掉之后再查最后一次：用户可能是点完「允许」才关的。
            let pageWasClosed = authorizationPageClosed
            do {
                let pin = try await client.checkPin(id: pinID)
                consecutiveFailures = 0
                if let token = pin.authToken { return token }
            } catch let error as PlexAccountError where error == .pinExpired || error == .unauthorized {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                consecutiveFailures += 1
                if consecutiveFailures >= Self.maximumConsecutivePollFailures { throw error }
            }
            if pageWasClosed { throw AuthorizationPageDismissed() }
        }
    }

    private func openAuthorizationPage(_ url: URL) {
        #if os(iOS)
        let session = ASWebAuthenticationSession(
            url: url,
            callbackURLScheme: Self.callbackScheme
        ) { @Sendable [weak self] _, _ in
            // 授权页的回调在系统的 XPC 队列上，回主线程再动状态。
            Task { @MainActor in self?.authorizationPageDidClose() }
        }
        session.presentationContextProvider = anchorProvider
        // 沿用 Safari 里已登录的 Plex 账号，省得再输一遍密码。
        session.prefersEphemeralWebBrowserSession = false
        webSession = session
        if !session.start() {
            authorizationPageDidClose()
        }
        #elseif os(macOS)
        if !NSWorkspace.shared.open(url) {
            authorizationPageDidClose()
        }
        #endif
    }

    private func closeAuthorizationPage() {
        #if os(iOS)
        let session = webSession
        webSession = nil
        session?.cancel()
        #endif
    }

    private func authorizationPageDidClose() {
        #if os(iOS)
        webSession = nil
        #endif
        authorizationPageClosed = true
    }

    private static func message(for error: Error) -> String {
        switch error as? PlexAccountError {
        case .pinExpired?:
            return String(localized: "plex_signin_error_expired")
        case .unauthorized?:
            return String(localized: "plex_signin_error_unauthorized")
        default:
            return String(localized: "plex_signin_error_network")
        }
    }
}

#if os(iOS)
private final class PlexAuthorizationAnchorProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes
            let windowScene = scenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
            return windowScene?.windows.first(where: \.isKeyWindow) ?? ASPresentationAnchor()
        }
    }
}
#endif

// MARK: - 界面

/// 添加 / 编辑 Plex 源时地址区块上面那一块。
struct PlexAccountSignInPanel: View {
    enum Style {
        /// iPhone / iPad 的 `Form` 分区。
        case form
        /// Mac 表单的卡片行。
        case card
    }

    let model: PlexAccountSignInModel
    let style: Style
    /// 这个源已经是用账号绑定的服务器。
    let isLinked: Bool
    let onPick: @MainActor (PlexServerSelection) -> Void

    var body: some View {
        switch model.phase {
        case .idle:
            row {
                Button {
                    model.signIn()
                } label: {
                    // 两个分支各自写成文案键：三元表达式里的字面量会被推断成 String，不做本地化。
                    Label(
                        isLinked
                            ? LocalizedStringKey("plex_signin_again")
                            : LocalizedStringKey("plex_signin_button"),
                        systemImage: "person.crop.circle.badge.checkmark"
                    )
                }
                .accessibilityIdentifier("plex-sign-in")
            }
        case .waitingForAuthorization:
            progressRow("plex_signin_waiting")
        case .loadingServers:
            progressRow("plex_signin_loading_servers")
        case let .servers(servers):
            if servers.isEmpty {
                row { secondaryText("plex_signin_no_servers") }
            } else {
                ForEach(servers) { server in
                    serverRow(server)
                }
            }
            row {
                Button("plex_signin_switch_account") { model.signIn() }
            }
        case let .failed(message):
            row { secondaryMessage(message) }
            row {
                Button("plex_signin_retry") { model.signIn() }
            }
        }
    }

    /// 分区脚注：有只能走中转的服务器时说一句速度受限，其余情况说明登录能做什么。
    static func footerKey(model: PlexAccountSignInModel, isLinked: Bool) -> LocalizedStringKey {
        if model.hasRelayOnlyServer { return "plex_relay_footer" }
        return isLinked ? "plex_signin_linked_footer" : "plex_signin_footer"
    }

    private func serverRow(_ server: PlexResource) -> some View {
        let routes = PlexServerConnectionPlanner.routes(for: server)
        let selection = model.selection(for: server)
        return row {
            Button {
                if let selection { onPick(selection) }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: server.isOwned ? "server.rack" : "person.2.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.tint)
                        .frame(width: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(server.name)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(Self.detail(for: server, routes: routes))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    if selection != nil {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(selection == nil)
            .accessibilityIdentifier("plex-server-\(server.clientIdentifier)")
        }
    }

    static func detail(for server: PlexResource, routes: PlexServerRoutes) -> String {
        var parts: [String] = []
        if server.isOwned {
            parts.append(String(localized: "plex_server_owned"))
        } else if let owner = server.ownerName {
            parts.append(String(localized: "plex_server_shared_by \(owner)"))
        } else {
            parts.append(String(localized: "plex_server_home"))
        }
        if !server.isOnline {
            parts.append(String(localized: "plex_server_offline"))
        }
        if routes.isEmpty {
            parts.append(String(localized: "plex_server_unreachable"))
        } else if routes.reachesOnlyThroughRelay {
            parts.append(String(localized: "plex_server_relay_only"))
        }
        return parts.joined(separator: " · ")
    }

    private func progressRow(_ key: LocalizedStringKey) -> some View {
        row {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(key)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Button("cancel") { model.cancel() }
                    .buttonStyle(.borderless)
            }
        }
    }

    private func secondaryText(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func secondaryMessage(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func row<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        switch style {
        case .form:
            content()
        case .card:
            #if os(macOS)
            content()
                .font(.system(size: 12.5))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
                .overlay(alignment: .top) {
                    Rectangle().fill(PMColor.divider).frame(height: 0.5)
                }
            #else
            content()
            #endif
        }
    }
}
