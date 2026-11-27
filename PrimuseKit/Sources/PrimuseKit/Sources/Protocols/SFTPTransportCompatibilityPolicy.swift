import Foundation

/// NIOSSH advertises only AES-GCM transport ciphers by default. Some NAS SSH
/// servers (including Dropbear builds) advertise CTR ciphers instead, so SFTP
/// must add the narrow compatibility cipher before key exchange begins.
public enum SFTPTransportCompatibilityPolicy {
    public enum Profile: Equatable, Sendable {
        case libraryDefaults
        case aes128CTR
    }

    public static let connectionProfile: Profile = .aes128CTR

    public static func hasCipherOverlap(
        client: Set<String>,
        server: Set<String>
    ) -> Bool {
        !client.isDisjoint(with: server)
    }
}
