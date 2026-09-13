#if os(tvOS)
import Foundation
import PrimuseKit

/// 电视端构造 SFTP 连接器。
///
/// 与 iOS / macOS 用同一份 `SFTPSource`(Citadel + NIOSSH),参数映射也保持一致:
/// 密码认证传密码,密钥认证传私钥文本 —— 两者在电视端都落在凭据的 `password` 位上。
enum TVSFTPConnectorFactory {
    static func make(source: MusicSource, credential: SourceCredential?) -> SFTPSource? {
        let host = (source.host ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return nil }
        let secret = credential?.password ?? ""
        // 密码 / 私钥认证都必须有 secret;`authType == .none` 的 SFTP 不成立,
        // 没有 secret 就直接失败,免得建一个连不上的空源。
        guard !secret.isEmpty else { return nil }
        return SFTPSource(
            sourceID: source.id,
            host: host,
            port: source.port,
            basePath: source.basePath,
            username: credential?.username ?? source.username ?? "",
            secret: secret,
            authType: source.authType
        )
    }
}
#endif
