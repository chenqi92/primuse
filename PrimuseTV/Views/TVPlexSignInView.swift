#if os(tvOS)
import PrimuseKit
import SwiftUI

/// Apple TV 上的 Plex 账号登录。
///
/// 电视没有浏览器，所以同时给两条路：二维码里是网页授权地址（手机扫了直接到 Plex 的授权页），
/// 旁边是 plex.tv/link 用的 4 位代码（在任意浏览器里输）。两枚 PIN 一起轮询，哪个先授权用哪个；
/// 拿到账号后列出自己的和好友分享的服务器让用户挑。
struct TVPlexSignInView: View {
    @Environment(\.dismiss) private var dismiss

    /// 选中的服务器。调用方在全屏页收起之后再用它保存。
    let onPick: @MainActor (PlexServerSelection) -> Void

    @State private var phase: Phase = .starting
    @State private var linkCode: String?
    @State private var authorizationURL: String?
    @State private var accountToken: String?
    @State private var task: Task<Void, Never>?

    private enum Phase: Equatable {
        case starting
        case waiting
        case loadingServers
        case servers([PlexResource])
        case failed(String)
    }

    /// 轮询途中网络抖一下不该让整次登录失败，连续失败这么多次才放弃。
    private static let maximumConsecutivePollFailures = 5

    var body: some View {
        ZStack {
            TVAmbientBackdrop(tint: TVColor.brand, tint2: TVColor.brandSecondary, strength: 0.45)
            TVColor.bg.opacity(0.38).ignoresSafeArea()

            VStack(spacing: 28) {
                header
                content
                footer
            }
            .frame(maxWidth: 1100)
            .padding(48)
            .tvPanel(radius: 28)
            .padding(.horizontal, 120)
        }
        .onAppear(perform: start)
        .onDisappear { task?.cancel() }
        .onExitCommand { dismiss() }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: MusicSourceType.plex.iconName)
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(TVColor.brand)
            Text(String(localized: "plex_tv_signin_title"))
                .tvFont(.pageTitle).foregroundStyle(TVColor.text)
            Text(subtitle)
                .tvFont(.caption).foregroundStyle(TVColor.textFaint)
                .multilineTextAlignment(.center)
        }
    }

    private var subtitle: String {
        switch phase {
        case .servers(let servers):
            if servers.contains(where: { PlexServerConnectionPlanner.routes(for: $0).reachesOnlyThroughRelay }) {
                return String(localized: "plex_relay_footer")
            }
            return String(localized: "plex_tv_signin_choose")
        default:
            return String(localized: "plex_tv_signin_subtitle")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .starting, .loadingServers:
            VStack(spacing: 16) {
                ProgressView().tint(TVColor.brand)
                if phase == .loadingServers {
                    Text(String(localized: "plex_signin_loading_servers"))
                        .tvFont(.meta).foregroundStyle(TVColor.textFaint)
                }
            }
            .frame(height: 300)
        case .failed(let text):
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 40)).foregroundStyle(TVColor.warn)
                Text(text).tvFont(.caption).foregroundStyle(TVColor.textMuted)
                    .multilineTextAlignment(.center).lineSpacing(4)
            }
            .frame(height: 300)
        case .waiting:
            HStack(alignment: .center, spacing: 44) {
                if let authorizationURL {
                    TVQRCode(content: authorizationURL, size: 300)
                }
                VStack(alignment: .leading, spacing: 18) {
                    if let linkCode {
                        VStack(alignment: .leading, spacing: 6) {
                            TVEyebrow(text: String(localized: "plex_tv_signin_code"))
                            Text(linkCode)
                                .tvFont(.heroTitle, weight: .bold, design: .monospaced)
                                .foregroundStyle(TVColor.text)
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        TVEyebrow(text: String(localized: "plex_tv_signin_link"))
                        Text(PlexAccountAPI.linkPageURL.absoluteString)
                            .tvFont(.body).foregroundStyle(TVColor.textMuted)
                    }
                    HStack(spacing: 10) {
                        ProgressView().tint(TVColor.brand)
                        Text(String(localized: "plex_tv_signin_waiting"))
                            .tvFont(.meta).foregroundStyle(TVColor.textFaint)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 300)
        case .servers(let servers):
            if servers.isEmpty {
                Text(String(localized: "plex_signin_no_servers"))
                    .tvFont(.caption).foregroundStyle(TVColor.textMuted)
                    .frame(height: 300)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 14) {
                        ForEach(servers) { server in
                            serverRow(server)
                        }
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, 8)
                }
                .frame(maxHeight: 460)
            }
        }
    }

    private func serverRow(_ server: PlexResource) -> some View {
        let selection = accountToken.flatMap { PlexServerSelection(resource: server, accountToken: $0) }
        let routes = PlexServerConnectionPlanner.routes(for: server)
        return TVFocusButton(radius: 18, scale: 1.03, lift: 0, action: {
            guard let selection else { return }
            onPick(selection)
            dismiss()
        }) { focused in
            HStack(spacing: 22) {
                Image(systemName: server.isOwned ? "server.rack" : "person.2.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(TVColor.brand)
                    .frame(width: 48)
                VStack(alignment: .leading, spacing: 6) {
                    Text(server.name)
                        .tvFont(.rowTitle, weight: .semibold)
                        .foregroundStyle(TVColor.text)
                        .lineLimit(1)
                    Text(Self.detail(for: server, routes: routes))
                        .tvFont(.meta)
                        .foregroundStyle(TVColor.textFaint)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                focused ? TVColor.surfaceStrong : TVColor.surface,
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .opacity(selection == nil ? 0.5 : 1)
        }
        .disabled(selection == nil)
    }

    /// 与 iPhone / Mac 的服务器清单同一套说明：谁的服务器、在不在线、是不是只能走中转。
    private static func detail(for server: PlexResource, routes: PlexServerRoutes) -> String {
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

    private var footer: some View {
        HStack(spacing: 14) {
            TVFocusButton(radius: 14, scale: 1.04, lift: 0, action: start) { focused in
                Text(restartTitle)
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

    private var restartTitle: String {
        if case .servers = phase { return String(localized: "plex_signin_switch_account") }
        return String(localized: "plex_tv_signin_refresh")
    }

    // MARK: - 流程

    private func start() {
        task?.cancel()
        phase = .starting
        linkCode = nil
        authorizationURL = nil
        accountToken = nil
        task = Task { @MainActor in
            await run()
        }
    }

    private func run() async {
        let client = PlexAccountClient.standard()
        do {
            async let linkPin = client.createPin(strong: false)
            async let webPin = client.createPin(strong: true)
            let (link, web) = try await (linkPin, webPin)
            try Task.checkCancellation()
            linkCode = link.code.uppercased()
            authorizationURL = PlexAccountAPI.authorizationPageURL(
                clientIdentifier: client.clientIdentifier,
                code: web.code
            ).absoluteString
            phase = .waiting

            let token = try await waitForToken(client: client, pinIDs: [link.id, web.id])
            accountToken = token
            plog("🎞️ TV Plex sign-in authorized")
            phase = .loadingServers
            let servers = try await client.servers(accountToken: token)
            try Task.checkCancellation()
            plog("🎞️ TV Plex servers listed count=\(servers.count) shared=\(servers.filter { !$0.isOwned }.count)")
            phase = .servers(servers)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            plog("⚠️ TV Plex sign-in failed: \(error)")
            phase = .failed(Self.message(for: error))
        }
    }

    private func waitForToken(client: PlexAccountClient, pinIDs: [Int]) async throws -> String {
        var consecutiveFailures = 0
        while true {
            try await Task.sleep(for: PlexAccountAPI.pollInterval)
            do {
                for id in pinIDs {
                    if let token = try await client.checkPin(id: id).authToken { return token }
                }
                consecutiveFailures = 0
            } catch let error as PlexAccountError where error == .pinExpired || error == .unauthorized {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                consecutiveFailures += 1
                if consecutiveFailures >= Self.maximumConsecutivePollFailures { throw error }
            }
        }
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
#endif
