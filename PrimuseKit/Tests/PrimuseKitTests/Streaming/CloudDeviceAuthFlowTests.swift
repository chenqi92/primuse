import Foundation
import Testing
@testable import PrimuseKit

@Suite("Cloud device authorization links")
struct CloudDeviceAuthFlowTests {
    @Test("115 barcode content must not fall back to the polling handle")
    func pan115RequiresQRCodeContent() throws {
        let incomplete = Data(#"{"state":1,"data":{"uid":"polling-handle","time":123,"sign":"signature"}}"#.utf8)
        #expect(CloudDeviceAuthParsing.parsePan115QRStart(incomplete) == nil)

        let complete = Data(#"{"state":1,"data":{"uid":"polling-handle","time":123,"sign":"signature","qrcode":"https://115.com/scan/authorization"}}"#.utf8)
        let start = try #require(CloudDeviceAuthParsing.parsePan115QRStart(complete))
        #expect(start.qrPayload == "https://115.com/scan/authorization")
        #expect(start.uid == "polling-handle")
    }

    @Test("Baidu QR opens the authorization page with the user code")
    func baiduImageURLIsNotEncodedAgain() throws {
        let response = Data(#"{"device_code":"private-device-handle","user_code":"ab12cd34","verification_url":"https://openapi.baidu.com/device","qrcode_url":"https://openapi.baidu.com/device/qrcode/image/ab12cd34","interval":5,"expires_in":300}"#.utf8)
        let start = try #require(CloudDeviceAuthParsing.parseDeviceCodeStart(response))
        let payload = try #require(CloudDeviceAuthRequests.deviceAuthorizationURL(for: .baiduPan, start: start))
        let url = try #require(URLComponents(string: payload))

        #expect(url.host == "openapi.baidu.com")
        #expect(url.path == "/device")
        #expect(url.queryItems?.first(where: { $0.name == "code" })?.value == "ab12cd34")
        #expect(url.queryItems?.first(where: { $0.name == "display" })?.value == "mobile")
        #expect(payload != start.qrCodeURL)
        #expect(!payload.contains(start.deviceCode))
    }

    @Test("A provider-supplied complete verification URI takes precedence")
    func preservesCompleteVerificationURL() throws {
        let complete = "https://auth.example.com/device?code=A%2BB&session=provider-session"
        let response = try JSONSerialization.data(withJSONObject: [
            "device_code": "private-device-handle",
            "user_code": "A+B",
            "verification_uri": "https://auth.example.com/device",
            "verification_uri_complete": complete,
        ])
        let start = try #require(CloudDeviceAuthParsing.parseDeviceCodeStart(response))

        #expect(start.verificationURL == "https://auth.example.com/device")
        #expect(CloudDeviceAuthRequests.deviceAuthorizationURL(for: .oneDrive, start: start) == complete)
    }

    @Test("Generic device URLs are not modified with guessed query parameters", arguments: [
        (MusicSourceType.oneDrive, "https://microsoft.com/devicelogin"),
        (MusicSourceType.googleDrive, "https://www.google.com/device"),
    ])
    func preservesProviderVerificationURL(provider: MusicSourceType, verification: String) throws {
        let response = try JSONSerialization.data(withJSONObject: [
            "device_code": "private-device-handle",
            "user_code": "ABCD-EFGH",
            "verification_uri": verification,
        ])
        let start = try #require(CloudDeviceAuthParsing.parseDeviceCodeStart(response))

        #expect(CloudDeviceAuthRequests.deviceAuthorizationURL(for: provider, start: start) == verification)
    }

    @Test("An image URL alone is not an authorization link")
    func rejectsImageOnlyResponse() throws {
        let response = Data(#"{"device_code":"handle","qrcode_url":"https://openapi.baidu.com/device/qrcode/image/code"}"#.utf8)
        let start = try #require(CloudDeviceAuthParsing.parseDeviceCodeStart(response))

        #expect(CloudDeviceAuthRequests.deviceAuthorizationURL(for: .baiduPan, start: start) == nil)
    }
}
