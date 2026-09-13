import Foundation

/// Phase 3:经 iPhone 局域网中继播放不可直连的源(本地文件 / SMB / SFTP / NFS / WebDAV / UPnP)。
///
/// 中继端点(host / port / token)由 iOS 中继服务写入凭据包同步过来,经 TVCredentialStore
/// 放进 `credential.extra`。中继服务支持 Range、token query 鉴权 → AVPlayer 直连。
public struct RelayStreamResolver: StreamResolver {
    /// 需要经 iPhone 中继的源类型。WebDAV / UPnP 已改 tvOS 直连(纯 HTTP),移出此表;
    /// SMB / NFS / FTP / SFTP 电视端已有直连读取器,中继作未接通时的兜底。
    ///
    /// Apple Music 不在此列:它是 DRM 流,没有可按字节转发的文件,iPhone 中继服务
    /// 也从未处理过这种源。留在表里只会让电视先显示「可播放」,真按下去才失败。
    public static let relayTypes: Set<MusicSourceType> = [
        .smb, .sftp, .nfs, .ftp, .local,
    ]

    public init() {}

    public func streamURL(for song: Song,
                          source: MusicSource,
                          credential: SourceCredential?) async throws -> URL {
        guard let host = credential?.extra["relay_host"], !host.isEmpty,
              let portStr = credential?.extra["relay_port"], let port = Int(portStr),
              let token = credential?.extra["relay_token"], !token.isEmpty else {
            throw StreamResolveError.relayUnavailable
        }
        guard let url = Self.relayURL(host: host, port: port, token: token,
                                      sourceID: source.id, path: song.filePath) else {
            throw StreamResolveError.cannotBuildURL
        }
        return url
    }

    static func relayURL(host: String, port: Int, token: String, sourceID: String, path: String) -> URL? {
        guard var comp = URLComponents(string: "http://\(host):\(port)/stream") else { return nil }
        comp.queryItems = [
            URLQueryItem(name: "source", value: sourceID),
            URLQueryItem(name: "path", value: path),
            URLQueryItem(name: "token", value: token),
        ]
        return FormSafeQueryURLBuilder.url(from: comp)
    }
}
