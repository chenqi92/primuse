import Foundation
import PrimuseKit

/// 把诊断报告传到 Palveni(palveni.com,作者的网站和后台),iPhone、iPad、Mac 与 Apple TV 共用。
///
/// 请求、上传位和编号与 primuse-ai 中转那条路完全一样(`DiagnosticReportUploader` 照旧打包、
/// PUT、确认),只是认证换成构建里带的上传密钥加一个匿名安装 ID,不做设备注册,也不需要
/// App Attest。构建里没带密钥(`configured()` 为 nil)时诊断仍走 primuse-ai。
nonisolated struct PalveniDiagnosticsClient: Sendable {
    let uploadKey: String
    let installationID: String
    var baseURL = PalveniDiagnosticUpload.baseURL

    /// 只为诊断上传生成的随机 ID,存在这台设备上 App 自己的偏好里:不跟 Apple 账号、不进
    /// iCloud 同步、删掉 App 就没了。Palveni 用它数每台设备每天传了几次。
    private static let installationIDKey = "PalveniDiagnosticsInstallationID"

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    /// 构建里配了 Palveni 的上传密钥(Config/Secrets.local.xcconfig 的 `PALVENI_UPLOAD_KEY`)才有。
    static func configured(bundle: Bundle = .main, defaults: UserDefaults = .standard) -> PalveniDiagnosticsClient? {
        guard let key = PalveniDiagnosticUpload.uploadKey(
            fromInfoValue: bundle.object(forInfoDictionaryKey: PalveniDiagnosticUpload.infoPlistKey)
        ) else { return nil }
        let installation = PalveniDiagnosticUpload.installationID(stored: defaults.string(forKey: installationIDKey))
        if installation.isNew {
            defaults.set(installation.id, forKey: installationIDKey)
        }
        return PalveniDiagnosticsClient(uploadKey: key, installationID: installation.id)
    }

    /// Palveni 收不收诊断;连不上时为 nil(下次再问),密钥被停用时为 false(改走邮件)。
    func availability() async -> Bool? {
        do {
            let body = try await send(PalveniDiagnosticUpload.configPath, method: "GET", body: nil)
            return PalveniDiagnosticUpload.isAvailable(configResponse: body)
        } catch DiagnosticUpload.Failure.network {
            return nil
        } catch {
            return false
        }
    }

    /// 要一个上传位,和中转那条路一样占当天的一次名额。
    func requestUpload(_ request: DiagnosticUpload.Request, channel: AppDistributionChannel) async throws -> DiagnosticUpload.Slot {
        let payload = PalveniDiagnosticUpload.UploadBody(
            request: request,
            channel: channel,
            locale: PalveniDiagnosticUpload.locale(preferredLanguages: Locale.preferredLanguages)
        )
        let body = try await send(PalveniDiagnosticUpload.uploadsPath, method: "POST", body: JSONEncoder().encode(payload))
        guard let slot = PalveniDiagnosticUpload.slot(fromUploadResponse: body, byteCount: request.byteCount) else {
            throw DiagnosticUpload.Failure.other(code: "invalid_upload_slot")
        }
        return slot
    }

    /// 告诉 Palveni 包已经 PUT 上去了,拿回给人看的编号(PM-XXXXXX)。
    func complete(id: String) async throws -> String {
        let input = try JSONSerialization.data(withJSONObject: ["upload_id": id])
        let body = try await send(PalveniDiagnosticUpload.completePath, method: "POST", body: input)
        guard let code = PalveniDiagnosticUpload.code(fromCompleteResponse: body) else {
            throw DiagnosticUpload.Failure.other(code: "invalid_response")
        }
        return code
    }

    /// 发一个请求,2xx 返回回复体;其余按 `DiagnosticUpload.Failure` 抛出,取消抛 `CancellationError`。
    private func send(_ path: String, method: String, body: Data?) async throws -> Data {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw DiagnosticUpload.Failure.other(code: "invalid_url")
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(uploadKey)", forHTTPHeaderField: "Authorization")
        request.setValue(installationID, forHTTPHeaderField: "X-Installation-Id")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let languages = Locale.preferredLanguages.prefix(10).joined(separator: ", ")
        if !languages.isEmpty {
            request.setValue(languages, forHTTPHeaderField: "Accept-Language")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw DiagnosticUpload.Failure.network
        }
        guard let http = response as? HTTPURLResponse else {
            throw DiagnosticUpload.Failure.other(code: "invalid_response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let failure = PalveniDiagnosticUpload.failure(
                statusCode: http.statusCode,
                body: data,
                retryAfterHeader: http.value(forHTTPHeaderField: "Retry-After")
            )
            plog("Palveni diagnostics \(method) \(path) failed status=\(http.statusCode) failure=\(failure)")
            throw failure
        }
        return data
    }
}
