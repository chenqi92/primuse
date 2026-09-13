#if os(tvOS)
import Foundation
import PrimuseKit

/// 电视端构造云盘连接器。
///
/// iOS / macOS 的云盘连接器从 `CloudTokenManager` 的钥匙串取 token;电视端的凭据
/// 来自 `TVCredentialStore`(本地登录 / CloudKit 凭据包 / 可同步钥匙串三条链合并)。
/// 两边其实是同一个钥匙串命名空间(`CloudCredentialStorageKeyPolicy`),只是电视端
/// 的凭据可能只到过凭据包、还没落钥匙串。这里在构造连接器前补齐那一步,
/// 连接器就能原样复用,不必为电视端再写一套列目录。
enum TVCloudConnectorFactory {
    /// 只在钥匙串里确实没有 token 时才写入,避免把连接器自己刷新出来的新 token
    /// 覆盖成凭据包里那个旧的。
    static func seedKeychainIfNeeded(
        sourceID: String,
        type: MusicSourceType,
        credential: SourceCredential?
    ) async {
        let manager = CloudTokenManager(sourceID: sourceID)
        let accessToken = credential?.token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let refreshToken = credential?.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if await manager.getTokens() == nil, !accessToken.isEmpty || !refreshToken.isEmpty {
            await manager.saveTokens(
                CloudTokenManager.Tokens(
                    accessToken: accessToken,
                    refreshToken: refreshToken.isEmpty ? nil : refreshToken,
                    expiresAt: nil,
                    tokenType: nil,
                    extra: (credential?.extra.isEmpty ?? true) ? nil : credential?.extra
                )
            )
        }
        guard await manager.getAppCredentials() == nil else { return }
        // 取值顺序与 iPhone 端一致:应用级内置密钥优先,其次才是随凭据包同步
        // 过来的。手机上用内置密钥授权时不一定往每个源写过 client 记录,少了这层
        // 兜底,token 过期后电视端就刷新不回来了。
        if let builtIn = BuiltInCloudCredentials.credentials(for: type) {
            await manager.saveAppCredentials(
                CloudTokenManager.AppCredentials(
                    clientId: builtIn.clientId,
                    clientSecret: builtIn.clientSecret
                )
            )
            return
        }
        let clientID = credential?.clientID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !clientID.isEmpty else { return }
        await manager.saveAppCredentials(
            CloudTokenManager.AppCredentials(
                clientId: clientID,
                clientSecret: credential?.clientSecret
            )
        )
    }

    /// 授权成功后把 token 落进连接器和播放解析器共用的那一份钥匙串。
    static func persist(sourceID: String, result: CloudDeviceAuthResult) async {
        let manager = CloudTokenManager(sourceID: sourceID)
        await manager.saveTokens(
            CloudTokenManager.Tokens(
                accessToken: result.credential.token ?? "",
                refreshToken: result.credential.refreshToken,
                expiresAt: result.expiresAt,
                tokenType: result.tokenType,
                extra: result.credential.extra.isEmpty ? nil : result.credential.extra
            )
        )
        if let clientID = result.credential.clientID, !clientID.isEmpty {
            await manager.saveAppCredentials(
                CloudTokenManager.AppCredentials(
                    clientId: clientID,
                    clientSecret: result.credential.clientSecret
                )
            )
        }
    }

    /// 保存云盘来源前,把用户填的 API token / client 凭据写进连接器与扫码流程
    /// 共用的那份钥匙串,并返回本次真正要用的 client_id / client_secret。
    ///
    /// 取值顺序与 iPhone 端一致:内置凭据优先(百度、123 这类应用级密钥必须用
    /// 我们自己的),其次才是用户在电视上填的。返回 nil 表示该类型不需要
    /// client 凭据(Drime 用 API token)或确实一个都没有。
    @discardableResult
    static func stageCredentials(
        sourceID: String,
        type: MusicSourceType,
        apiToken: String,
        clientID: String,
        clientSecret: String
    ) async -> (id: String, secret: String?)? {
        let manager = CloudTokenManager(sourceID: sourceID)
        if type == .drime {
            let token = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty {
                await manager.saveTokens(CloudTokenManager.Tokens(accessToken: token))
            }
            return nil
        }
        let resolved: (id: String, secret: String?)?
        if let builtIn = BuiltInCloudCredentials.credentials(for: type) {
            resolved = (builtIn.clientId, builtIn.clientSecret)
        } else {
            let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
            let secret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
            resolved = id.isEmpty ? nil : (id, secret.isEmpty ? nil : secret)
        }
        guard let resolved else { return nil }
        await manager.saveAppCredentials(
            CloudTokenManager.AppCredentials(clientId: resolved.id, clientSecret: resolved.secret)
        )
        return resolved
    }

    /// 按类型造连接器。返回 nil 表示该类型不是电视端能自建库的云盘。
    /// 注意构造本身不碰钥匙串 —— 补种要在首次列举前由 `seedKeychainIfNeeded` 完成。
    static func makeConnector(source: MusicSource) -> (any MusicSourceConnector)? {
        guard source.type.isCloudDrive else { return nil }
        switch source.type {
        case .oneDrive: return OneDriveSource(sourceID: source.id)
        case .dropbox: return DropboxSource(sourceID: source.id)
        case .aliyunDrive: return AliyunDriveSource(sourceID: source.id)
        case .googleDrive: return GoogleDriveSource(sourceID: source.id)
        case .baiduPan: return BaiduPanSource(sourceID: source.id)
        case .pan115: return U115Source(sourceID: source.id)
        case .pan123: return Pan123Source(sourceID: source.id)
        case .drime: return DrimeSource(sourceID: source.id)
        default: return nil
        }
    }

    /// 电视端已接通的云盘 —— 目前与 `MusicSourceType.isCloudDrive` 全等。
    /// 单列一份是为了让扫描器的分派条件只认「确实造得出连接器」的类型:
    /// 以后新增云盘类型时,先在 `makeConnector` 补分支,再加进这里。
    static let supportedTypes: Set<MusicSourceType> = [
        .oneDrive, .dropbox, .aliyunDrive, .googleDrive,
        .baiduPan, .pan115, .pan123, .drime,
    ]
}
#endif
