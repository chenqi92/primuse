import Foundation
import Testing
@testable import PrimuseKit

struct MusicSourceSecurityScopeFingerprintTests {
    @Test func credentialRevisionChangesSecurityScopeWithoutCredentialMaterial() {
        let source = makeSource()

        let first = MusicSourceSecurityScopeFingerprint.make(
            for: source,
            revision: 41
        )
        let repeated = MusicSourceSecurityScopeFingerprint.make(
            for: source,
            revision: 41
        )
        let rotated = MusicSourceSecurityScopeFingerprint.make(
            for: source,
            revision: 42
        )

        #expect(first == repeated)
        #expect(first != rotated)
        #expect(first.count == 64)
        #expect(first == "87a60ac7fb36c8fe135bf731c75f7a81da47515974b63eea1e3f47cb6e28eb95")
    }

    @Test func displayAndScanStateDoNotInvalidateSecurityScope() {
        let source = makeSource()
        var presentationUpdate = source
        presentationUpdate.name = "Renamed source"
        presentationUpdate.songCount = 9_999
        presentationUpdate.lastScannedAt = Date(timeIntervalSince1970: 2_000)
        presentationUpdate.modifiedAt = Date(timeIntervalSince1970: 3_000)

        #expect(
            MusicSourceSecurityScopeFingerprint.make(for: source, revision: 7)
                == MusicSourceSecurityScopeFingerprint.make(
                    for: presentationUpdate,
                    revision: 7
                )
        )
    }

    @Test func sourceAccountEndpointAndFailClosedEpochChangeSecurityScope() {
        let source = makeSource()
        let original = MusicSourceSecurityScopeFingerprint.make(
            for: source,
            revision: 7
        )
        var moved = source
        moved.host = "replacement.example.com"
        var differentAccount = source
        differentAccount.username = "another-user"
        var differentSource = source
        differentSource.id = "replacement-source"

        #expect(original != MusicSourceSecurityScopeFingerprint.make(for: moved, revision: 7))
        #expect(
            original != MusicSourceSecurityScopeFingerprint.make(
                for: differentAccount,
                revision: 7
            )
        )
        #expect(
            original != MusicSourceSecurityScopeFingerprint.make(
                for: differentSource,
                revision: 7
            )
        )
        #expect(
            MusicSourceSecurityScopeFingerprint.make(
                for: source,
                revisionIdentity: "unavailable-process-a"
            ) != MusicSourceSecurityScopeFingerprint.make(
                for: source,
                revisionIdentity: "unavailable-process-b"
            )
        )
    }

    @Test func addingAnAlternateAddressKeepsTheCredentialScope() {
        let source = makeSynologySource()
        var withPublicAddress = source
        withPublicAddress.connectionConfiguration = SourceConnectionConfiguration(
            localEndpoint: SourceConnectionEndpoint(
                host: "192.168.0.50",
                port: 5_001,
                useSsl: true,
                pathPrefix: "/music"
            ),
            publicEndpoint: SourceConnectionEndpoint(
                host: "nas.example.cn",
                port: 5_001,
                useSsl: true,
                pathPrefix: "/music"
            )
        )

        // The full scope still moves: the connector must be rebuilt.
        #expect(
            MusicSourceSecurityScopeFingerprint.make(for: source, revision: 3)
                != MusicSourceSecurityScopeFingerprint.make(
                    for: withPublicAddress,
                    revision: 3
                )
        )
        // The credential scope does not: the cached bytes stay trusted.
        #expect(
            MusicSourceSecurityScopeFingerprint.credentialScoped(
                for: source,
                revisionIdentity: "3"
            ) == MusicSourceSecurityScopeFingerprint.credentialScoped(
                for: withPublicAddress,
                revisionIdentity: "3"
            )
        )
    }

    @Test func credentialScopeStillTracksAccountContentRootAndEpoch() {
        let source = makeSynologySource()
        let original = MusicSourceSecurityScopeFingerprint.credentialScoped(
            for: source,
            revisionIdentity: "3"
        )

        var rotatedCredential = source
        rotatedCredential.username = "another-user"
        let webDAV = makeWebDAVSource()
        var movedContentRoot = webDAV
        movedContentRoot.basePath = "/other-music"

        #expect(original != MusicSourceSecurityScopeFingerprint.credentialScoped(
            for: rotatedCredential,
            revisionIdentity: "3"
        ))
        #expect(MusicSourceSecurityScopeFingerprint.credentialScoped(
            for: webDAV,
            revisionIdentity: "3"
        ) != MusicSourceSecurityScopeFingerprint.credentialScoped(
            for: movedContentRoot,
            revisionIdentity: "3"
        ))
        #expect(original != MusicSourceSecurityScopeFingerprint.credentialScoped(
            for: source,
            revisionIdentity: "4"
        ))
    }

    @Test func credentialScopeRejectsAnAlternateAddressServingAnotherContentRoot() {
        // WebDAV 的路径就是目录：换了前缀就是换了一份内容。
        let source = makeWebDAVSource()
        var repointed = source
        repointed.connectionConfiguration = SourceConnectionConfiguration(
            localEndpoint: SourceConnectionEndpoint(
                host: "192.168.0.50",
                port: 5_006,
                useSsl: true,
                pathPrefix: "/archive"
            ),
            publicEndpoint: SourceConnectionEndpoint(
                host: "nas.example.cn",
                port: 5_006,
                useSsl: true,
                pathPrefix: "/archive"
            )
        )

        #expect(
            MusicSourceSecurityScopeFingerprint.credentialScoped(
                for: source,
                revisionIdentity: "3"
            ) != MusicSourceSecurityScopeFingerprint.credentialScoped(
                for: repointed,
                revisionIdentity: "3"
            )
        )
    }

    @Test func serverAPIPathPrefixIsARouteNotAContentRoot() {
        // 群晖：从带反向代理前缀的地址换成只用 QuickConnect ID，还是同一个账号。
        let proxied = MusicSource(
            id: "synology-source",
            name: "NAS",
            type: .synology,
            connectionConfiguration: SourceConnectionConfiguration(
                publicEndpoint: SourceConnectionEndpoint(
                    host: "nas.example.cn",
                    port: 443,
                    useSsl: true,
                    pathPrefix: "/nas"
                )
            ),
            username: "listener"
        )
        var quickConnectOnly = proxied
        quickConnectOnly.connectionConfiguration = SourceConnectionConfiguration(
            remoteAccessMode: .vendor,
            vendorIdentifier: "my-nas"
        )
        var withLAN = proxied
        withLAN.connectionConfiguration = SourceConnectionConfiguration(
            localEndpoint: SourceConnectionEndpoint(host: "192.168.0.50", port: 5_001, useSsl: true),
            publicEndpoint: proxied.connectionConfiguration?.publicEndpoint
        )
        for edited in [quickConnectOnly, withLAN] {
            #expect(
                MusicSourceScopeFingerprint.credentialScope(for: proxied)
                    == MusicSourceScopeFingerprint.credentialScope(for: edited)
            )
            #expect(SourceScanContentScopePolicy.contentUnchanged(previous: proxied, current: edited))
        }

        // Navidrome：反向代理的子路径改了也只是换线路。
        let navidrome = MusicSource(
            id: "navidrome-source",
            name: "Navidrome",
            type: .navidrome,
            host: "music.example.com",
            port: 443,
            useSsl: true,
            username: "listener",
            basePath: "/navidrome"
        )
        var movedProxyPath = navidrome
        movedProxyPath.basePath = "/music"
        #expect(
            MusicSourceScopeFingerprint.credentialScope(for: navidrome)
                == MusicSourceScopeFingerprint.credentialScope(for: movedProxyPath)
        )
        #expect(SourceScanContentScopePolicy.contentUnchanged(previous: navidrome, current: movedProxyPath))
    }

    @Test func routeAndNameEditsKeepTheScannedContent() {
        let source = makeSynologySource()
        var withPublicAddress = source
        withPublicAddress.name = "NAS (anywhere)"
        withPublicAddress.connectionConfiguration = SourceConnectionConfiguration(
            localEndpoint: SourceConnectionEndpoint(
                host: "192.168.0.50",
                port: 5_001,
                useSsl: true,
                pathPrefix: "/music"
            ),
            publicEndpoint: SourceConnectionEndpoint(
                host: "nas.example.cn",
                port: 5_001,
                useSsl: true,
                pathPrefix: "/music"
            )
        )
        withPublicAddress.modifiedAt = source.modifiedAt.addingTimeInterval(60)
        withPublicAddress.songCount = 4_375
        #expect(SourceScanContentScopePolicy.contentUnchanged(
            previous: source,
            current: withPublicAddress
        ))

        var movedHost = source
        movedHost.host = "192.168.0.51"
        movedHost.port = 5_000
        movedHost.useSsl = false
        #expect(SourceScanContentScopePolicy.contentUnchanged(previous: source, current: movedHost))
    }

    @Test func contentEditsStillInvalidateTheScannedContent() {
        let source = makeSynologySource()
        var otherAccount = source
        otherAccount.username = "another-listener"
        var otherRoot = makeWebDAVSource()
        otherRoot.basePath = "/video"
        var otherDirectories = source
        otherDirectories.extraConfig = MusicSource.encodeScannedDirectories(
            ["/music/Other"],
            into: source.extraConfig,
            type: source.type
        )
        var disabled = source
        disabled.isEnabled = false
        var newDevice = source
        newDevice.deviceId = "trusted-device"
        var deleted = source
        deleted.isDeleted = true
        var otherSource = source
        otherSource.id = "another-source"

        for edited in [otherAccount, otherDirectories, disabled, newDevice, deleted, otherSource] {
            #expect(!SourceScanContentScopePolicy.contentUnchanged(previous: source, current: edited))
        }
        #expect(!SourceScanContentScopePolicy.contentUnchanged(
            previous: makeWebDAVSource(),
            current: otherRoot
        ))
    }

    private func makeWebDAVSource() -> MusicSource {
        MusicSource(
            id: "webdav-source",
            name: "WebDAV",
            type: .webdav,
            host: "192.168.0.50",
            port: 5_006,
            useSsl: true,
            username: "listener",
            basePath: "/music"
        )
    }

    private func makeSynologySource() -> MusicSource {
        MusicSource(
            id: "synology-source",
            name: "NAS",
            type: .synology,
            host: "192.168.0.50",
            port: 5_001,
            useSsl: true,
            username: "listener",
            basePath: "/music"
        )
    }

    private func makeSource() -> MusicSource {
        MusicSource(
            id: "security-source",
            name: "Navidrome",
            type: .navidrome,
            host: "music.example.com",
            port: 4_533,
            useSsl: true,
            username: "listener",
            basePath: "/music"
        )
    }
}
