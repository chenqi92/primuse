import Foundation
import Testing
@testable import PrimuseKit

@Suite("Log redaction policy")
struct LogRedactionPolicyTests {
    @Test("Subsonic credentials are redacted in every NSError URL")
    func redactsSubsonicErrorURLs() {
        let url = "https://nas.invalid/rest/ping.view?u=listener&t=secret-token&s=random-salt&p=enc%3A736563726574&v=1.16.1&c=Primuse&f=json"
        let message = "NSErrorFailingURLStringKey=\(url), NSErrorFailingURLKey=\(url)"
        let redacted = LogRedactionPolicy.redact(message)
        for value in ["listener", "secret-token", "random-salt", "enc%3A736563726574"] {
            #expect(!redacted.contains(value))
        }
        #expect(redacted.components(separatedBy: "u=<redacted>").count == 3)
        #expect(redacted.contains("&v=1.16.1&c=Primuse&f=json"))
        #expect(LogRedactionPolicy.redact(redacted) == redacted)
        #expect(LogRedactionPolicy.redact("position t=3 duration s=60") == "position t=3 duration s=60")
    }

    @Test("URL query credentials keep their key and lose the value")
    func redactsQueryParameters() {
        // 非凭证参数放在前面: 裸 key=value 规则(规则 5)的值字符类不排除 &,
        // 所以最后一个凭证之后的同行内容会被一并吃掉 —— 这是既有行为。
        let redacted = LogRedactionPolicy.redact(
            "GET https://host/api?page=3&token=abcd1234&code=xyz&state=s1&password=hunter2"
        )
        #expect(redacted.contains("token=<redacted>"))
        #expect(redacted.contains("code=<redacted>"))
        #expect(redacted.contains("state=<redacted>"))
        #expect(redacted.contains("password=<redacted>"))
        #expect(redacted.contains("page=3"))
        #expect(!redacted.contains("abcd1234"))
        #expect(!redacted.contains("hunter2"))
    }

    @Test("Authorization and Cookie headers are redacted")
    func redactsHeaders() {
        let authorization = LogRedactionPolicy.redact("Authorization: Basic dXNlcjpwYXNz")
        #expect(authorization == "Authorization=<redacted>")

        let cookie = LogRedactionPolicy.redact("Cookie: id=abc; sid=def")
        #expect(cookie.hasPrefix("Cookie=<redacted>"))
        #expect(!cookie.contains("def"))
    }

    @Test("Bearer tokens keep the scheme only")
    func redactsBearerTokens() {
        let redacted = LogRedactionPolicy.redact("header Bearer eyJhbGciOiJIUzI1NiJ9.payload.sig tail")
        #expect(redacted == "header Bearer <redacted> tail")
    }

    @Test("JSON body credential keys are redacted")
    func redactsJSONBody() {
        let redacted = LogRedactionPolicy.redact(
            #"{"access_token":"AAA","refresh_token":"BBB","expires_in":3600}"#
        )
        #expect(redacted.contains(#""access_token":"<redacted>""#))
        #expect(redacted.contains(#""refresh_token":"<redacted>""#))
        #expect(redacted.contains(#""expires_in":3600"#))
        #expect(!redacted.contains("AAA"))
        #expect(!redacted.contains("BBB"))
    }

    @Test("Bare credential assignments are redacted")
    func redactsBareAssignments() {
        #expect(LogRedactionPolicy.redact("access_token=AAA") == "access_token=<redacted>")
        #expect(LogRedactionPolicy.redact("client_secret: shhh") == "client_secret=<redacted>")
        #expect(LogRedactionPolicy.redact("api_key = K123") == "api_key=<redacted>")
        // 普通日志里的 state / code 不能被裸规则误伤。
        #expect(LogRedactionPolicy.redact("state: playing") == "state: playing")
        #expect(LogRedactionPolicy.redact("scan code: 42") == "scan code: 42")
    }

    @Test("Messages without credentials are returned unchanged")
    func leavesCleanMessagesAlone() {
        let message = "🎵 Scanned 128 songs from source-1 in 2.4s (album: Blue, artist: Joni)"
        #expect(LogRedactionPolicy.redact(message) == message)
    }

    // MARK: - 身份:地址、账号、邮箱

    @Test("URL hosts become tags while scheme, port and path stay readable")
    func redactsURLHosts() {
        let redacted = LogRedactionPolicy.redact(
            "Playback URL resolution error url=https://nas.example.com:5001/webapi/auth.cgi"
        )
        #expect(!redacted.contains("nas.example.com"))
        #expect(redacted.contains("https://<host:"))
        #expect(redacted.contains(":5001/webapi/auth.cgi"))
    }

    @Test("URL user info is dropped entirely")
    func dropsURLUserInfo() {
        let redacted = LogRedactionPolicy.redact("smb://listener:hunter2@nas.example.com/music")
        #expect(!redacted.contains("listener"))
        #expect(!redacted.contains("hunter2"))
        #expect(!redacted.contains("nas.example.com"))
        #expect(redacted.hasSuffix("/music"))
    }

    /// 标记的全部价值在于"同一个地址前后能对上":跨会话、跨设备都折出同一个值,
    /// 否则日志里就看不出「这两条说的是同一台」。
    @Test("The same host always folds into the same tag")
    func hostTagsAreStableAndDistinct() {
        #expect(LogRedactionPolicy.hostTag("nas.example.com") == LogRedactionPolicy.hostTag("NAS.Example.com"))
        #expect(LogRedactionPolicy.hostTag("nas.example.com") != LogRedactionPolicy.hostTag("other.example.com"))
        #expect(LogRedactionPolicy.digest("192.168.1.20") == LogRedactionPolicy.digest("192.168.1.20"))
        #expect(LogRedactionPolicy.digest("192.168.1.20").count == 6)
    }

    @Test("Private addresses are folded, loopback stays readable")
    func redactsBareAddresses() {
        let redacted = LogRedactionPolicy.redact(
            "Source route network failure host=192.168.1.20:5001 error=-1001"
        )
        #expect(!redacted.contains("192.168.1.20"))
        #expect(redacted.contains("<ip:"))
        // 端口不在捕获里,排查要看的那一半留着。
        #expect(redacted.contains(":5001 error=-1001"))
        #expect(LogRedactionPolicy.redact("bound to 127.0.0.1:8080") == "bound to <loopback>:8080")
    }

    /// 自家 scheme 的"主机"是源 id,折了就与同一行的 `source=` 前 8 位对不上,
    /// 而它本身不是个人信息。
    @Test("App internal schemes keep their identifiers")
    func keepsAppInternalSchemes() {
        let message = "▶️ URL: primuse-stream://A1B2C3D4-0000-4000-8000-000000000001/songs/track.flac"
        #expect(LogRedactionPolicy.redact(message) == message)
    }

    @Test("Home directory user names and container ids are replaced")
    func redactsPathIdentities() {
        #expect(
            LogRedactionPolicy.redact("/Users/someone/Music/track.flac")
                == "/Users/<user>/Music/track.flac"
        )
        #expect(
            LogRedactionPolicy.redact("/Users/Shared/Music/track.flac")
                == "/Users/Shared/Music/track.flac"
        )
        let container = "/var/mobile/Containers/Data/Application/"
            + "A1B2C3D4-0000-4000-8000-000000000002/Library/Caches/primuse_audio_cache/a.dts"
        #expect(
            LogRedactionPolicy.redact(container)
                == "/var/mobile/Containers/Data/Application/<app>/Library/Caches/primuse_audio_cache/a.dts"
        )
    }

    /// 账号不折成标记,直接丢掉:用户要求账号密码一律不记录,连"同一个账号"
    /// 这种关联性都不必留。
    @Test("Accounts are dropped and mail addresses are folded")
    func redactsAccountsAndMail() {
        let account = LogRedactionPolicy.redact("Synology login account=listener otpSet=false")
        #expect(!account.contains("listener"))
        #expect(account.contains("account=<redacted>"))
        #expect(account.hasSuffix(" otpSet=false"))
        // 明确表示"没有"的值折出来只会让人以为真有一个账号。
        #expect(LogRedactionPolicy.redact("account=nil") == "account=nil")
        #expect(!LogRedactionPolicy.redact("owner someone@example.com wrote").contains("someone@example.com"))
        // 云盘账号的 uid 也是身份。
        #expect(!LogRedactionPolicy.redact("mount=A → account=b uid=4098371122").contains("4098371122"))
    }

    /// 口令类字段:`accountSet=true` / `passwordSet=true` 这种"有没有"要留着,
    /// 值一律不留。
    @Test("Every credential keyword loses its value")
    func redactsEveryCredentialKeyword() {
        for pair in ["password=hunter2", "pwd=hunter2", "passwd=hunter2", "passphrase=hunter2",
                     "secret=hunter2", "otp=123456", "otpCode=123456"] {
            let redacted = LogRedactionPolicy.redact("login \(pair) done")
            #expect(!redacted.contains("hunter2"), "\(pair) → \(redacted)")
            #expect(!redacted.contains("123456"), "\(pair) → \(redacted)")
            #expect(redacted.contains("<redacted>"), "\(pair) → \(redacted)")
        }
        let shape = "accountSet=true passwordSet=true otpSet=false userLen=6"
        #expect(LogRedactionPolicy.redact(shape) == shape)
    }

    /// 钥匙串条目的键是源 id 或供应商名,不是账号:它要留着可读,否则和别处的
    /// `source=A1B2C3D4` 对不上。`musicKit://` 的"主机"同理,是个字面量。
    @Test("Local identifiers stay readable")
    func keepsLocalIdentifiers() {
        let keychain = "🔑 Keychain getPassword HIT (memory) item=A1B2C3D4…"
        #expect(LogRedactionPolicy.redact(keychain) == keychain)
        let artwork = "🎵 first='musicKit://artwork/library/A1B2C3D4-0000-4000-8000-000000000003'"
        #expect(LogRedactionPolicy.redact(artwork) == artwork)
    }

    /// `Error Domain=` 不是主机。这条曾经被 `domain` 那个键名误伤,而错误域是
    /// 排查时最要看的字段之一。
    @Test("Error domains are not mistaken for hosts")
    func keepsErrorDomains() {
        let message = "Error Domain=NSURLErrorDomain Code=-1001 \"请求超时。\""
        #expect(LogRedactionPolicy.redact(message) == message)
        #expect(LogRedactionPolicy.redact("Error Domain=kCFErrorDomainCFNetwork Code=310")
            == "Error Domain=kCFErrorDomainCFNetwork Code=310")
        // 真的是主机的那个 domain= 仍然要折。
        #expect(!LogRedactionPolicy.redact("🔐 Certificate trust prompt requested domain=nas.example.com")
            .contains("nas.example.com"))
    }

    /// 真实设备日志里的一行:除了地址,其它字段必须原样留着,否则日志就白记了。
    @Test("A real log line keeps everything except the address")
    func keepsDiagnosticFieldsOfARealLine() {
        let redacted = LogRedactionPolicy.redact(
            "☁️ Synology login start host=192.168.1.20 port=5001 ssl=true accountSet=true "
                + "passwordSet=true otpSet=false deviceNameSet=true deviceIdSet=true"
        )
        #expect(redacted.contains("port=5001 ssl=true accountSet=true"))
        #expect(redacted.contains("otpSet=false deviceNameSet=true deviceIdSet=true"))
        #expect(!redacted.contains("192.168"))
    }

    @Test("Repeated redaction is idempotent")
    func isIdempotent() {
        let message = """
        GET https://host/api?access_token=AAA&page=2 \
        Authorization: Bearer eyJhbGciOi.J9 \
        {"refresh_token":"BBB"} client_secret: CCC
        """
        let once = LogRedactionPolicy.redact(message)
        var repeated = once
        for _ in 0..<5 {
            repeated = LogRedactionPolicy.redact(repeated)
        }
        #expect(repeated == once)
    }
}
