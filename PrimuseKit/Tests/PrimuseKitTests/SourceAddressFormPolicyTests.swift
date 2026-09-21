import Foundation
import Testing
@testable import PrimuseKit

/// 表单归位与解读的规则测试。界面那边只剩「把这些结构翻成人话」,所以这里
/// 覆盖到位就等于覆盖了两套布局共同的行为。
struct SourceAddressFormPolicyTests {

    private func draft(_ address: String) -> SourceAddressFormPolicy.AddressDraft {
        SourceAddressFormPolicy.AddressDraft(address: address)
    }

    // MARK: - 归位

    @Test func lanAddressTakesTheLocalSlot() {
        let reading = SourceAddressFormPolicy.read([draft("192.168.1.20")], sourceType: .emby)
        #expect(reading.placement.slots == [.local])
        #expect(reading.placement.localIndex == 0)
        #expect(reading.placement.publicIndex == nil)
    }

    @Test func publicNameTakesThePublicSlot() {
        let reading = SourceAddressFormPolicy.read(
            [draft("https://emby.example.com")],
            sourceType: .emby
        )
        #expect(reading.placement.slots == [.publicAddress])
        #expect(reading.placement.publicIndex == 0)
    }

    @Test func loopbackIsLocalAndOverlayIsRemote() {
        let reading = SourceAddressFormPolicy.read(
            [draft("localhost"), draft("100.101.102.103")],
            sourceType: .navidrome
        )
        #expect(SourceAddressInputPolicy.hostClass(of: "100.101.102.103") == .overlay)
        #expect(reading.placement.slots == [.local, .publicAddress])
    }

    @Test func twoAddressesOfTheSameClassShareTheTwoSlots() {
        // 两条都是内网,槽只是标签:第二条放进空着的那个槽,两条都成为候选。
        let reading = SourceAddressFormPolicy.read(
            [draft("192.168.1.20"), draft("10.0.0.7")],
            sourceType: .jellyfin
        )
        #expect(reading.placement.slots == [.local, .publicAddress])
        #expect(reading.placement.unusedIndices.isEmpty)
    }

    @Test func twoPublicAddressesAlsoBothSurvive() {
        let reading = SourceAddressFormPolicy.read(
            [draft("https://a.example.com"), draft("https://b.example.com")],
            sourceType: .webdav
        )
        #expect(reading.placement.slots == [.publicAddress, .local])
        #expect(reading.placement.unusedIndices.isEmpty)
    }

    @Test func vendorIdentifierDoesNotConsumeAnEndpointSlot() {
        let reading = SourceAddressFormPolicy.read(
            [draft("192.168.1.30"), draft("mynas")],
            sourceType: .synology
        )
        #expect(reading.placement.slots == [.local, .vendor])
        #expect(reading.placement.usesVendorRemoteAccess)
        #expect(reading.placement.localIndex == 0)
        #expect(reading.placement.publicIndex == nil)
    }

    /// vendor 模式下 `connectionCandidates` 根本不读 publicEndpoint,所以公网
    /// 地址必须落进 local 槽才留得住 —— 这条是整个归位里最反直觉的一步。
    @Test func publicAddressMovesToTheLocalSlotWhenAVendorIDIsPresent() {
        let reading = SourceAddressFormPolicy.read(
            [draft("https://nas.example.com"), draft("mynas")],
            sourceType: .synology
        )
        #expect(reading.placement.slots == [.local, .vendor])
        #expect(reading.placement.unusedIndices.isEmpty)
    }

    @Test func aSecondVendorIdentifierIsReportedAsRedundant() {
        let reading = SourceAddressFormPolicy.read(
            [draft("mynas"), draft("othernas")],
            sourceType: .synology
        )
        #expect(reading.placement.slots == [.vendor, nil])
        #expect(reading.placement.unusedIndices == [1])
        guard case let .vendor(second) = reading.rows[1] else {
            Issue.record("第二行应当仍然被认成厂商标识")
            return
        }
        #expect(second.isRedundant)
    }

    @Test func aThirdEndpointHasNowhereToGoAndSaysSo() {
        let reading = SourceAddressFormPolicy.read(
            [draft("192.168.1.20"), draft("10.0.0.7"), draft("172.16.0.3")],
            sourceType: .emby
        )
        #expect(reading.placement.unusedIndices == [2])
        #expect(reading.placement.slots[2] == nil)
    }

    // MARK: - 解读

    @Test func aBareDomainReadsAsAutomaticPortOnFourFourThree() {
        let reading = SourceAddressFormPolicy.read(
            [draft("https://emby.example.com")],
            sourceType: .emby
        )
        guard case let .endpoint(row) = reading.rows[0] else {
            Issue.record("应当读成端点")
            return
        }
        #expect(row.displayAddress == "https://emby.example.com")
        // 写了协议没写端口:先试该协议的默认端口,再退回服务自己的端口。
        #expect(row.preferred?.port == 443)
        #expect(row.preferred?.useSsl == true)
        #expect(row.isAutomatic)
        #expect(row.candidates.map(\.port) == [443, 8920])
    }

    @Test func anExplicitPortIsAHardConstraintWithNoAlternatives() {
        let reading = SourceAddressFormPolicy.read(
            [draft("http://192.168.1.20:8096")],
            sourceType: .emby
        )
        guard case let .endpoint(row) = reading.rows[0] else {
            Issue.record("应当读成端点")
            return
        }
        #expect(row.candidates.count == 1)
        #expect(row.isAutomatic == false)
        #expect(row.preferred?.origin == .explicitAddress)
    }

    @Test func aManualPortOverridesTheServiceDefault() {
        let manual = SourceAddressFormPolicy.AddressDraft(
            address: "nas.example.com",
            manualPort: 9443,
            manualUseSsl: true
        )
        let reading = SourceAddressFormPolicy.read([manual], sourceType: .jellyfin)
        guard case let .endpoint(row) = reading.rows[0] else {
            Issue.record("应当读成端点")
            return
        }
        #expect(row.candidates == [
            SourceConnectionCandidatePlanner.Candidate(
                useSsl: true,
                port: 9443,
                origin: .manualOverride
            )
        ])
    }

    @Test func aReverseProxyPrefixIsEchoedBackInTheReadingLine() {
        let reading = SourceAddressFormPolicy.read(
            [draft("https://proxy.example.com/music")],
            sourceType: .navidrome
        )
        guard case let .endpoint(row) = reading.rows[0] else {
            Issue.record("应当读成端点")
            return
        }
        #expect(row.displayAddress == "https://proxy.example.com/music")
        #expect(row.input.pathPrefix == "/music")
    }

    @Test func nonHTTPTypesGetExactlyOneCandidateAndTheirOwnScheme() {
        let reading = SourceAddressFormPolicy.read([draft("nas.local")], sourceType: .smb)
        guard case let .endpoint(row) = reading.rows[0] else {
            Issue.record("应当读成端点")
            return
        }
        #expect(row.candidates.count == 1)
        #expect(row.isAutomatic == false)
        #expect(row.displayAddress == "smb://nas.local")
        #expect(row.preferred?.port == MusicSourceType.smb.defaultPort)
    }

    @Test func credentialsInTheAddressAreReportedAsInvalid() {
        let reading = SourceAddressFormPolicy.read(
            [draft("https://user:pass@nas.example.com")],
            sourceType: .webdav
        )
        #expect(reading.rows[0] == .invalid(.credentialsInAddress))
        #expect(reading.hasInvalidRow)
        #expect(reading.isSubmittable == false)
    }

    @Test func anEmptyFormIsNotSubmittable() {
        let reading = SourceAddressFormPolicy.read([draft("")], sourceType: .emby)
        #expect(reading.rows == [.empty])
        #expect(reading.placement.hasAnyRoute == false)
        #expect(reading.isSubmittable == false)
    }

    @Test func aDotlessTokenCanBeForcedToMeanAHostname() {
        let asVendor = SourceAddressFormPolicy.read([draft("mynas")], sourceType: .synology)
        #expect(asVendor.placement.slots == [.vendor])

        let asHostname = SourceAddressFormPolicy.read(
            [SourceAddressFormPolicy.AddressDraft(
                address: "mynas",
                treatDotlessTokenAsHostname: true
            )],
            sourceType: .synology
        )
        #expect(asHostname.placement.slots == [.local])
        guard case let .endpoint(row) = asHostname.rows[0] else {
            Issue.record("按主机名理解之后应当读成端点")
            return
        }
        // 单标签主机名在公网上不存在,解读行要标「内网」而不是「公网」。
        #expect(row.hostClass == .lan)
        #expect(row.input.hostClass == .public)
    }

    // MARK: - 是否需要重新探测

    @Test func anUntouchedEditDoesNotProbe() {
        let drafts = [draft("https://nas.example.com:5001")]
        #expect(SourceAddressFormPolicy.requiresProbe(drafts: drafts, baseline: drafts) == false)
    }

    @Test func aNewSourceAlwaysProbes() {
        #expect(SourceAddressFormPolicy.requiresProbe(drafts: [draft("nas")], baseline: nil))
    }

    @Test func onlyWhitespaceChangesDoNotCountAsAnEdit() {
        let baseline = [draft("https://nas.example.com:5001")]
        let padded = [draft("  https://nas.example.com:5001  ")]
        #expect(SourceAddressFormPolicy.requiresProbe(drafts: padded, baseline: baseline) == false)
    }

    @Test func changingTheManualPortProbesAgain() {
        let baseline = [draft("nas.example.com")]
        let edited = [SourceAddressFormPolicy.AddressDraft(
            address: "nas.example.com",
            manualPort: 8443
        )]
        #expect(SourceAddressFormPolicy.requiresProbe(drafts: edited, baseline: baseline))
    }

    @Test func addingASecondAddressProbesAgain() {
        let baseline = [draft("nas.example.com")]
        let edited = [draft("nas.example.com"), draft("192.168.1.9")]
        #expect(SourceAddressFormPolicy.requiresProbe(drafts: edited, baseline: baseline))
    }

    // MARK: - 哪几行需要重新探测

    /// 在外网给源补一条备用地址:动过的那一行要探,没动过的内网地址不跟着探。
    /// 它在外网必然探不通,而那一轮既让用户白等,又会让整次保存失败。
    @Test func onlyTheEditedRowIsProbed() {
        let baseline = [draft("https://192.168.1.9:5001"), draft("https://old.example.com:5001")]
        let edited = [draft("https://192.168.1.9:5001"), draft("https://nas.example.com")]
        #expect(
            SourceAddressFormPolicy.rowsRequiringProbe(drafts: edited, baseline: baseline)
                == [false, true]
        )
    }

    @Test func aNewSourceProbesEveryRow() {
        let drafts = [draft("192.168.1.9"), draft("nas.example.com")]
        #expect(
            SourceAddressFormPolicy.rowsRequiringProbe(drafts: drafts, baseline: nil)
                == [true, true]
        )
    }

    /// 按签名配对而不是按下标:加一行、删一行、换顺序都不该让别的行变成「动过」。
    @Test func rowIdentityFollowsTheAddressNotThePosition() {
        let baseline = [draft("https://192.168.1.9:5001"), draft("https://nas.example.com:443")]
        let appended = [
            draft("https://192.168.1.9:5001"),
            draft("https://nas.example.com:443"),
            draft("mynas.example.com")
        ]
        #expect(
            SourceAddressFormPolicy.rowsRequiringProbe(drafts: appended, baseline: baseline)
                == [false, false, true]
        )

        let removed = [draft("https://nas.example.com:443")]
        #expect(
            SourceAddressFormPolicy.rowsRequiringProbe(drafts: removed, baseline: baseline)
                == [false]
        )

        let reordered = [draft("https://nas.example.com:443"), draft("https://192.168.1.9:5001")]
        #expect(
            SourceAddressFormPolicy.rowsRequiringProbe(drafts: reordered, baseline: baseline)
                == [false, false]
        )
    }

    /// 两行写成同一个地址时只有一行算「没动过」—— 另一行确实是新填的。
    @Test func aDuplicateRowStillCountsAsEdited() {
        let baseline = [draft("https://nas.example.com:443")]
        let duplicated = [draft("https://nas.example.com:443"), draft("https://nas.example.com:443")]
        #expect(
            SourceAddressFormPolicy.rowsRequiringProbe(drafts: duplicated, baseline: baseline)
                == [false, true]
        )
    }

    // MARK: - 回显

    @Test func storedEndpointsRenderBackIntoAddressRowsWithoutLoss() {
        let configuration = SourceConnectionConfiguration(
            localEndpoint: SourceConnectionEndpoint(
                host: "192.168.1.20",
                port: 8096,
                useSsl: false
            ),
            publicEndpoint: SourceConnectionEndpoint(
                host: "emby.example.com",
                port: 443,
                useSsl: true,
                pathPrefix: "/emby"
            )
        )
        let drafts = SourceAddressFormPolicy.drafts(for: configuration, sourceType: .emby)
        #expect(drafts.map(\.address) == [
            "http://192.168.1.20:8096",
            "https://emby.example.com/emby"
        ])

        // 回显出来的地址再读一遍必须回到同一组端点,否则「打开编辑页再保存」
        // 会悄悄换掉用户的端口。
        let reading = SourceAddressFormPolicy.read(drafts, sourceType: .emby)
        guard case let .endpoint(local) = reading.rows[0],
              case let .endpoint(remote) = reading.rows[1],
              let localCandidate = local.preferred,
              let remoteCandidate = remote.preferred else {
            Issue.record("回显出来的两行都应当是端点")
            return
        }
        #expect(
            SourceConnectionCandidatePlanner.endpoint(for: local.input, candidate: localCandidate)
                == configuration.localEndpoint
        )
        #expect(
            SourceConnectionCandidatePlanner.endpoint(for: remote.input, candidate: remoteCandidate)
                == configuration.publicEndpoint
        )
        #expect(reading.placement.slots == [.local, .publicAddress])
    }

    @Test func aStoredVendorIdentifierRendersBackAsItsOwnRow() {
        let configuration = SourceConnectionConfiguration(
            localEndpoint: SourceConnectionEndpoint(host: "192.168.1.30", port: 5000, useSsl: false),
            remoteAccessMode: .vendor,
            vendorIdentifier: "mynas"
        )
        let drafts = SourceAddressFormPolicy.drafts(for: configuration, sourceType: .synology)
        #expect(drafts.map(\.address) == ["http://192.168.1.30:5000", "mynas"])

        let reading = SourceAddressFormPolicy.read(drafts, sourceType: .synology)
        #expect(reading.placement.slots == [.local, .vendor])
        #expect(SourceAddressFormPolicy.requiresProbe(drafts: drafts, baseline: drafts) == false)
    }

    /// 只有公网端点的旧源:回显成一行,再存回去仍然落在公网槽。
    @Test func aPublicOnlySourceStaysPublicAfterARoundTrip() {
        let configuration = SourceConnectionConfiguration(
            publicEndpoint: SourceConnectionEndpoint(
                host: "music.example.com",
                port: 4533,
                useSsl: true
            )
        )
        let drafts = SourceAddressFormPolicy.drafts(for: configuration, sourceType: .navidrome)
        #expect(drafts.map(\.address) == ["https://music.example.com:4533"])
        let reading = SourceAddressFormPolicy.read(drafts, sourceType: .navidrome)
        #expect(reading.placement.slots == [.publicAddress])
        guard case let .endpoint(row) = reading.rows[0], let candidate = row.preferred else {
            Issue.record("应当读成端点")
            return
        }
        #expect(
            SourceConnectionCandidatePlanner.endpoint(for: row.input, candidate: candidate)
                == configuration.publicEndpoint
        )
    }

    // MARK: - 发现预填

    @Test func aDiscoveredDeviceBecomesASingleCandidateAddress() {
        let address = SourceAddressFormPolicy.exactAddress(
            host: "192.168.1.44",
            port: 8096,
            useSsl: false,
            sourceType: .emby
        )
        #expect(address == "http://192.168.1.44:8096")
        let reading = SourceAddressFormPolicy.read([draft(address)], sourceType: .emby)
        guard case let .endpoint(row) = reading.rows[0] else {
            Issue.record("应当读成端点")
            return
        }
        #expect(row.candidates.count == 1)
        #expect(row.isAutomatic == false)
    }

    @Test func aDiscoveredIPv6DeviceKeepsItsBrackets() {
        let address = SourceAddressFormPolicy.exactAddress(
            host: "fe80::1",
            port: 5000,
            useSsl: false,
            sourceType: .synology
        )
        #expect(address == "http://[fe80::1]:5000")
        let reading = SourceAddressFormPolicy.read([draft(address)], sourceType: .synology)
        guard case let .endpoint(row) = reading.rows[0] else {
            Issue.record("应当读成端点")
            return
        }
        #expect(row.input.host == "fe80::1")
        #expect(row.candidates.count == 1)
    }

    @Test func aDiscoveredSMBDeviceGetsTheSMBScheme() {
        #expect(
            SourceAddressFormPolicy.exactAddress(
                host: "nas.local",
                port: 445,
                useSsl: false,
                sourceType: .smb
            ) == "smb://nas.local:445"
        )
    }

    // MARK: - 连接失败的提示

    @Test func aDomainOnTheServicePortSuggestsTheProxyPort() {
        #expect(
            SourceAddressFormPolicy.failureHint(
                host: "emby.example.com",
                port: 8096,
                useSsl: false,
                sourceType: .emby,
                usesVendorRemoteAccess: false
            ) == .domainOnServicePort
        )
    }

    @Test func aPublicIPOnItsServicePortIsNotFlaggedAsAPortMistake() {
        #expect(
            SourceAddressFormPolicy.failureHint(
                host: "203.0.113.9",
                port: 8096,
                useSsl: false,
                sourceType: .emby,
                usesVendorRemoteAccess: false
            ) == .cleartextOnPublicHost
        )
    }

    @Test func aLanAddressSuggestsBeingOffThatNetwork() {
        #expect(
            SourceAddressFormPolicy.failureHint(
                host: "192.168.1.20",
                port: 8096,
                useSsl: false,
                sourceType: .emby,
                usesVendorRemoteAccess: false
            ) == .privateAddressFromOutside
        )
    }

    @Test func aVendorRelayGetsItsOwnHint() {
        #expect(
            SourceAddressFormPolicy.failureHint(
                host: "mynas",
                port: 5001,
                useSsl: true,
                sourceType: .synology,
                usesVendorRemoteAccess: true
            ) == .vendorRelay
        )
    }

    @Test func aProperlyProxiedDomainGetsNoHint() {
        #expect(
            SourceAddressFormPolicy.failureHint(
                host: "emby.example.com",
                port: 443,
                useSsl: true,
                sourceType: .emby,
                usesVendorRemoteAccess: false
            ) == .none
        )
    }

    @Test func nonHTTPTypesGetNoPortHint() {
        #expect(
            SourceAddressFormPolicy.failureHint(
                host: "files.example.com",
                port: 2222,
                useSsl: false,
                sourceType: .sftp,
                usesVendorRemoteAccess: false
            ) == .none
        )
    }

    // MARK: - 歧义切换

    @Test func onlyVendorCapableTypesOfferTheDotlessSwitch() {
        #expect(SourceAddressFormPolicy.isAmbiguousDotlessToken("mynas", sourceType: .synology))
        #expect(SourceAddressFormPolicy.isAmbiguousDotlessToken("myhomenas", sourceType: .fnMusic))
        #expect(SourceAddressFormPolicy.isAmbiguousDotlessToken("mynas", sourceType: .emby) == false)
        // 飞牛 FN ID 至少 6 位,`mynas` 根本不可能是一个 FN ID,不给切换。
        #expect(SourceAddressFormPolicy.isAmbiguousDotlessToken("mynas", sourceType: .fnMusic) == false)
        #expect(SourceAddressFormPolicy.isAmbiguousDotlessToken("mynas", sourceType: .synology))
        #expect(
            SourceAddressFormPolicy.isAmbiguousDotlessToken("nas.local", sourceType: .synology) == false
        )
        #expect(
            SourceAddressFormPolicy.isAmbiguousDotlessToken("mynas:5000", sourceType: .synology) == false
        )
    }

    /// 不带点的内网主机名回显之后不能被重新认成 QuickConnect ID —— 渲染出来的
    /// 地址一定带协议,带协议的串不可能是厂商标识。
    @Test func aDotlessLocalHostnameStaysAHostnameOnReload() {
        let configuration = SourceConnectionConfiguration(
            localEndpoint: SourceConnectionEndpoint(host: "mynas", port: 5000, useSsl: false)
        )
        let drafts = SourceAddressFormPolicy.drafts(for: configuration, sourceType: .synology)
        #expect(drafts.map(\.address) == ["http://mynas:5000"])
        let reading = SourceAddressFormPolicy.read(drafts, sourceType: .synology)
        #expect(reading.placement.slots == [.local])
        #expect(reading.placement.usesVendorRemoteAccess == false)
        #expect(SourceAddressFormPolicy.requiresProbe(drafts: drafts, baseline: drafts) == false)
    }
}
