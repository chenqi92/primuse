import Foundation
import PrimuseKit

// 扫码直传(iPhone / Mac → Apple TV)里的设置。Apple TV 登录的常常是另一个 Apple ID,
// iCloud 键值同步、CloudKit 与 iCloud 钥匙串都到不了它;这里把电视用得上的那部分设置
// 连同它们用到的秘密,随音乐源那一段一起带过去。放行哪些由 `LANSettingsTransferPolicy` 决定。

#if !os(tvOS)
/// 发送端:从本机收集设置。读不到的项跳过、只记日志,不拦住音乐源的发送。
enum LANSettingsExporter {
    static func makeBundle() async -> LANSettingsBundle {
        #if DEBUG
        assertPolicyKeysMatchApp()
        #endif
        let defaults = UserDefaults.standard
        var bundle = LANSettingsBundle()
        var secrets: [String: String] = [:]

        for key in LANSettingsTransferPolicy.allowedValueKeys.sorted() {
            switch key {
            case LANSettingsTransferPolicy.scraperSettingsKey:
                // 本机 blob 落盘时已抹掉 Cookie;旧 blob 里没搬走的也在这里抹掉,Cookie 走钥匙串那一份。
                guard let data = defaults.data(forKey: key),
                      let settings = try? JSONDecoder().decode(ScraperSettings.self, from: data) else { continue }
                for row in settings.sources where row.type.supportsCookie {
                    if let cookie = ScraperSourceCookieStore.cookie(for: row) {
                        secrets[row.cookieKeychainAccount] = cookie
                    }
                }
                var stripped = settings
                for index in stripped.sources.indices { stripped.sources[index].cookie = nil }
                if let encoded = try? JSONEncoder().encode(stripped) {
                    bundle.values[key] = LANSettingsBundle.encodeValue(encoded)
                }
            case LANSettingsTransferPolicy.lyricsAPIServersKey:
                guard defaults.object(forKey: key) != nil else { continue }
                let settings = LyricsAPIServerSettings.load(defaults: defaults)
                for server in settings.hydratingCredentials().servers {
                    guard let authorization = server.authorization, !authorization.isEmpty else { continue }
                    secrets[LyricsAPIServerCredentialStore.account(for: server.id)] = authorization
                }
                if let encoded = try? JSONEncoder().encode(settings.strippingCredentials()) {
                    bundle.values[key] = LANSettingsBundle.encodeValue(encoded)
                }
            default:
                guard let value = defaults.object(forKey: key) else { continue }
                bundle.values[key] = LANSettingsBundle.encodeValue(value)
            }
        }

        for (account, apiKey) in await aiAPIKeys(defaults: defaults) {
            secrets[account] = apiKey
        }

        // 已删除的配置也带上(它自己带着删除标记):电视上从前直传过去的那份跟着删掉,
        // 否则电视载入刮削设置时会给它补回一行。
        let configStore = ScraperConfigStore.shared
        let encoder = JSONEncoder()
        for config in configStore.allConfigsIncludingDeleted {
            guard let json = try? encoder.encode(config) else { continue }
            bundle.scraperConfigs.append(LANScraperConfigEntry(
                id: config.id,
                json: json,
                secrets: config.isDeleted == true ? nil : configStore.sideFileSecrets(for: config.id)
            ))
        }

        bundle.secrets = secrets
        return LANSettingsTransferPolicy.sanitized(bundle)
    }

    /// 只解出服务商配置,用来算钥匙串账户;不建设置 store —— 新建的 store 会抢走 KVS 登记。
    private struct AISettingsProbe: Decodable {
        var providerSet: AIRemoteProviderSet?
        var configuration: AIRemoteProviderConfiguration?
    }

    private struct TranscriptionSettingsProbe: Decodable {
        var configuration: AIRemoteProviderConfiguration?
        var legacyCredentialConfiguration: AIRemoteProviderConfiguration?
    }

    /// 智能功能与歌词转写各服务商的密钥,按接收端读取用的账户名(`scopedAccount`)存放。
    private static func aiAPIKeys(defaults: UserDefaults) async -> [String: String] {
        var configurations: [AIRemoteProviderConfiguration] = []
        if let data = defaults.data(forKey: LANSettingsTransferPolicy.aiSettingsKey),
           let probe = try? JSONDecoder().decode(AISettingsProbe.self, from: data) {
            configurations += probe.providerSet?.providers ?? []
            if let configuration = probe.configuration { configurations.append(configuration) }
        }
        if let data = defaults.data(forKey: LANSettingsTransferPolicy.lyricsTranscriptionKey),
           let probe = try? JSONDecoder().decode(TranscriptionSettingsProbe.self, from: data) {
            configurations += [probe.configuration, probe.legacyCredentialConfiguration].compactMap { $0 }
        }
        let credentialStore = AICredentialStore()
        var keys: [String: String] = [:]
        for configuration in configurations {
            guard let account = try? AICredentialStoragePolicy.scopedAccount(configuration: configuration),
                  keys[account] == nil else { continue }
            if case .ready(let apiKey) = await credentialStore.lookupAPIKey(configuration: configuration) {
                keys[account] = apiKey
            }
        }
        return keys
    }

    #if DEBUG
    /// PrimuseKit 里的放行表把 App 层的键写成了字面值,这里核对它们没有走样。
    private static func assertPolicyKeysMatchApp() {
        assert(LANSettingsTransferPolicy.scraperSettingsKey == ScraperSettings.defaultsKey)
        assert(LANSettingsTransferPolicy.lyricsAPIServersKey == LyricsAPIServerSettings.defaultsKey)
        assert(LANSettingsTransferPolicy.aiSettingsKey == AISettingsStore.storageKey)
        assert(LANSettingsTransferPolicy.lyricsTranscriptionKey == LyricsTranscriptionSettingsStore.storageKey)
        assert(LANSettingsTransferPolicy.playerEffectKey == FullscreenPlayerEffect.storageKey)
    }
    #endif
}
#endif

#if os(tvOS)
/// 接收端:在 Apple TV 上落地。音乐源已经落盘之后才调用;哪一项装不上只记日志。
@MainActor
enum LANSettingsInstaller {
    /// 返回真正装上的设置分类,供二维码卡片显示。
    static func install(_ incoming: LANSettingsBundle) -> [LANSettingsCategory] {
        let bundle = LANSettingsTransferPolicy.sanitized(incoming)
        let dropped = incoming.values.count + incoming.scraperConfigs.count + incoming.secrets.count
            - bundle.values.count - bundle.scraperConfigs.count - bundle.secrets.count
        var installed = Set<LANSettingsCategory>()
        var failures = 0

        // 1. 秘密先进钥匙串:随后重新载入的刮削设置要据此认出哪些源有 Cookie,歌词 API 服务
        //    与智能功能重新载入时也要读得到凭据。
        for (account, secret) in bundle.secrets.sorted(by: { $0.key < $1.key }) {
            guard let category = LANSettingsTransferPolicy.category(forSecretAccount: account) else { continue }
            if KeychainService.storeTransferredSecret(secret, for: account) {
                installed.insert(category)
            } else {
                failures += 1
            }
        }

        // 2. 自定义刮削配置排在刮削设置之前:刮削设置载入时会删掉找不到配置的自定义源行。
        let decoder = JSONDecoder()
        for entry in bundle.scraperConfigs {
            guard let config = try? decoder.decode(ScraperConfig.self, from: entry.json),
                  config.id == entry.id,
                  ScraperConfigStore.shared.applyTransferredConfig(config, secrets: entry.secrets) else {
                failures += 1
                continue
            }
            installed.insert(.scraping)
        }

        // 3. 设置值,刮削设置最先。经 CloudKVSSync 写入:这台电视自己的 iCloud 旧值盖不回来,
        //    也不会被推进电视登录的账号;已经载入的 store 按外部变更重新载入。
        for key in LANSettingsTransferPolicy.applicationOrder(of: bundle.values.keys) {
            guard let category = LANSettingsTransferPolicy.category(forValueKey: key),
                  let data = bundle.values[key],
                  let value = LANSettingsBundle.decodeValue(data) else {
                failures += 1
                continue
            }
            CloudKVSSync.shared.applyTransferred(key: key, value: value)
            installed.insert(category)
        }

        plog("📺 LAN settings installed values=\(bundle.values.count) configs=\(bundle.scraperConfigs.count) secrets=\(bundle.secrets.count) failures=\(failures) dropped=\(dropped)")
        return installed.sorted()
    }
}
#endif
