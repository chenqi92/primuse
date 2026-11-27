import Testing
@testable import PrimuseKit

@Suite("SFTP transport compatibility policy")
struct SFTPTransportCompatibilityPolicyTests {
    @Test("Dropbear CTR-only transport needs the compatibility cipher")
    func dropbearNeedsAES128CTR() {
        let nioDefaultCiphers: Set<String> = [
            "aes256-gcm@openssh.com",
            "aes128-gcm@openssh.com",
        ]
        let dropbearCiphers: Set<String> = [
            "chacha20-poly1305@openssh.com",
            "aes128-ctr",
            "aes256-ctr",
        ]

        #expect(
            !SFTPTransportCompatibilityPolicy.hasCipherOverlap(
                client: nioDefaultCiphers,
                server: dropbearCiphers
            )
        )
        #expect(SFTPTransportCompatibilityPolicy.connectionProfile == .aes128CTR)
        #expect(
            SFTPTransportCompatibilityPolicy.hasCipherOverlap(
                client: nioDefaultCiphers.union(["aes128-ctr"]),
                server: dropbearCiphers
            )
        )
    }
}
