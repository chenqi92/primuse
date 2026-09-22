import Foundation
import Testing
@testable import PrimuseKit

// 样例正文取自 2026-09-17 对公共演示服务器的只读探测,不是编出来的。

/// `https://demo.jellyfin.org/stable/System/Info/Public` → 200,
/// `content-type: application/json; charset=utf-8`。
private let jellyfinPublicInfoBody = """
{"LocalAddress":"http://172.17.0.2:8096/stable","ServerName":"Stable Demo","Version":"12.1.0",\
"ProductName":"Jellyfin Server","OperatingSystem":"","Id":"f0b3381645f04afb9a0e392e74b6a1b0",\
"StartupWizardCompleted":true}
"""

/// `https://demo.navidrome.org/rest/ping.view?f=json&v=1.16.1&c=Primuse` → 200。
/// 不带凭据,所以 status 是 failed —— 但信封在。
private let navidromePingBody = """
{"subsonic-response":{"status":"failed","version":"1.16.1","type":"navidrome",\
"serverVersion":"0.63.2 (be10f89c)","openSubsonic":true,\
"error":{"code":10,"message":"missing parameter: 'u'"}}}
"""

/// `demo.emby.media` 今天是一台 nginx 静态站(证书名还对不上),`/System/Info/Public`
/// 回 404 的 HTML 页。「有响应」绝不等于「是这个服务」,这条用例就是为它留的。
private let nginxNotFoundBody = """
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">
<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en" lang="en"><head>
    <title>404 &mdash; Not Found</title>
"""

// MARK: - 探测请求

@Test func fingerprintRequestsAreCredentialFreeEndpoints() {
    #expect(SourceServiceFingerprint.probeRequest(for: .emby)?.path == "/System/Info/Public")
    #expect(SourceServiceFingerprint.probeRequest(for: .jellyfin)?.path == "/System/Info/Public")
    #expect(SourceServiceFingerprint.probeRequest(for: .plex)?.path == "/identity")
    #expect(SourceServiceFingerprint.probeRequest(for: .navidrome)?.path == "/rest/ping.view")
    #expect(SourceServiceFingerprint.probeRequest(for: .synology)?.path == "/webapi/query.cgi")
    #expect(SourceServiceFingerprint.probeRequest(for: .webdav)?.method == "OPTIONS")
    #expect(SourceServiceFingerprint.probeRequest(for: .qnap)?.path == "/")
    // 非 HTTP 类型没有指纹可言。
    #expect(SourceServiceFingerprint.probeRequest(for: .smb) == nil)
    #expect(SourceServiceFingerprint.probeRequest(for: .sftp) == nil)
}

@Test func subsonicProbeCarriesTheProtocolHandshakeParameters() {
    guard let request = SourceServiceFingerprint.probeRequest(for: .navidrome) else {
        Issue.record("no probe request for navidrome")
        return
    }
    let values = Dictionary(uniqueKeysWithValues: request.queryItems.map { ($0.name, $0.value) })
    #expect(values["f"] == "json")
    #expect(values["v"] == "1.16.1")
    #expect(values["c"] == "Primuse")
    #expect(values.keys.contains("u") == false)
    #expect(values.keys.contains("p") == false)
    #expect(values.keys.contains("t") == false)

    // Airsonic 停在 1.15.0,和 SubsonicStreamResolver 的选择保持一致。
    let airsonic = SourceServiceFingerprint.probeRequest(for: .airsonic)
    #expect(airsonic?.queryItems.first { $0.name == "v" }?.value == "1.15.0")
}

@Test func synologyProbeAsksOnlyForTheAuthAPIDescriptor() {
    guard let request = SourceServiceFingerprint.probeRequest(for: .synology) else {
        Issue.record("no probe request for synology")
        return
    }
    let values = Dictionary(uniqueKeysWithValues: request.queryItems.map { ($0.name, $0.value) })
    #expect(values["api"] == "SYNO.API.Info")
    #expect(values["method"] == "query")
    #expect(values["query"] == "SYNO.API.Auth")
}

// MARK: - 判定

@Test func fingerprintConfirmsJellyfinFromItsPublicSystemInfo() {
    let response = SourceServiceFingerprint.ProbeResponse(
        statusCode: 200,
        headerFields: ["Content-Type": "application/json; charset=utf-8", "Server": "Kestrel"],
        bodyPrefix: jellyfinPublicInfoBody
    )
    #expect(SourceServiceFingerprint.evaluate(response, sourceType: .jellyfin) == .confirmed)
    // Emby 与 Jellyfin 同源,字段一致,所以互认 —— 用户把服务类型选错时仍能定下端口。
    #expect(SourceServiceFingerprint.evaluate(response, sourceType: .emby) == .confirmed)
}

@Test func fingerprintRejectsAStaticSiteThatMerelyAnswers() {
    let response = SourceServiceFingerprint.ProbeResponse(
        statusCode: 404,
        headerFields: ["Server": "nginx", "Content-Type": "text/html"],
        bodyPrefix: nginxNotFoundBody
    )
    #expect(SourceServiceFingerprint.evaluate(response, sourceType: .emby) == .responded(statusCode: 404))
}

@Test func fingerprintConfirmsSubsonicFromTheEnvelopeEvenWhenTheCallFails() {
    let response = SourceServiceFingerprint.ProbeResponse(
        statusCode: 200,
        headerFields: ["Content-Type": "application/json"],
        bodyPrefix: navidromePingBody
    )
    #expect(SourceServiceFingerprint.evaluate(response, sourceType: .navidrome) == .confirmed)
    #expect(SourceServiceFingerprint.evaluate(response, sourceType: .subsonic) == .confirmed)
    #expect(SourceServiceFingerprint.evaluate(response, sourceType: .gonic) == .confirmed)
}

@Test func fingerprintDoesNotConfuseNavidromeWithWebDAV() {
    // 实测 `OPTIONS https://demo.navidrome.org/` → 405 + `allow: GET`,没有 DAV 头。
    let response = SourceServiceFingerprint.ProbeResponse(
        statusCode: 405,
        headerFields: ["Allow": "GET", "Content-Length": "0"]
    )
    #expect(SourceServiceFingerprint.evaluate(response, sourceType: .webdav) == .responded(statusCode: 405))
}

@Test func fingerprintConfirmsWebDAVFromTheDAVHeaderWhateverItsCase() {
    let response = SourceServiceFingerprint.ProbeResponse(
        statusCode: 200,
        headerFields: ["dav": "1,2,3", "Allow": "OPTIONS, GET, PROPFIND"]
    )
    #expect(SourceServiceFingerprint.evaluate(response, sourceType: .webdav) == .confirmed)

    // 实测 `OPTIONS http://test.webdav.org/` → 403 Apache,没有 DAV 头:端口通,
    // 但不能算认出来。
    let forbidden = SourceServiceFingerprint.ProbeResponse(
        statusCode: 403,
        headerFields: ["Server": "Apache", "Content-Type": "text/html; charset=iso-8859-1"]
    )
    #expect(SourceServiceFingerprint.evaluate(forbidden, sourceType: .webdav) == .responded(statusCode: 403))
}

@Test func fingerprintConfirmsPlexFromItsMachineIdentifier() {
    let xml = SourceServiceFingerprint.ProbeResponse(
        statusCode: 200,
        headerFields: ["Content-Type": "text/xml;charset=utf-8"],
        bodyPrefix: "<MediaContainer size=\"1\" claimed=\"1\" machineIdentifier=\"abc123\" version=\"1.41.0\"/>"
    )
    #expect(SourceServiceFingerprint.evaluate(xml, sourceType: .plex) == .confirmed)

    let json = SourceServiceFingerprint.ProbeResponse(
        statusCode: 200,
        headerFields: ["Content-Type": "application/json"],
        bodyPrefix: "{\"MediaContainer\":{\"size\":1,\"machineIdentifier\":\"abc123\"}}"
    )
    #expect(SourceServiceFingerprint.evaluate(json, sourceType: .plex) == .confirmed)
}

@Test func fingerprintConfirmsSynologyFromTheAPIDescriptor() {
    let response = SourceServiceFingerprint.ProbeResponse(
        statusCode: 200,
        headerFields: ["Content-Type": "application/json"],
        bodyPrefix: "{\"data\":{\"SYNO.API.Auth\":{\"maxVersion\":7,\"minVersion\":1,\"path\":\"entry.cgi\"}},\"success\":true}"
    )
    #expect(SourceServiceFingerprint.evaluate(response, sourceType: .synology) == .confirmed)
}

@Test func fingerprintTreatsCleartextOnATLSPortAsUnreachable() {
    let nginx = SourceServiceFingerprint.ProbeResponse(
        statusCode: 400,
        headerFields: ["Server": "nginx"],
        bodyPrefix: "<html><head><title>400 The plain HTTP request was sent to HTTPS port</title></head>"
    )
    #expect(SourceServiceFingerprint.evaluate(nginx, sourceType: .emby) == .unreachable(.cleartextOnTLSPort))

    let goServer = SourceServiceFingerprint.ProbeResponse(
        statusCode: 400,
        bodyPrefix: "Client sent an HTTP request to an HTTPS server.\n"
    )
    #expect(SourceServiceFingerprint.evaluate(goServer, sourceType: .navidrome) == .unreachable(.cleartextOnTLSPort))

    let caddy = SourceServiceFingerprint.ProbeResponse(
        statusCode: 400,
        bodyPrefix: "Client sent an HTTP request to an HTTPS server."
    )
    #expect(SourceServiceFingerprint.evaluate(caddy, sourceType: .webdav) == .unreachable(.cleartextOnTLSPort))

    // 普通的 400 仍然只是「有人应答」。
    let ordinary = SourceServiceFingerprint.ProbeResponse(statusCode: 400, bodyPrefix: "Bad Request")
    #expect(SourceServiceFingerprint.evaluate(ordinary, sourceType: .emby) == .responded(statusCode: 400))
}

@Test func fingerprintFallsBackToRespondedForTypesWithoutAHandshake() {
    let response = SourceServiceFingerprint.ProbeResponse(
        statusCode: 401,
        headerFields: ["WWW-Authenticate": "Basic realm=\"QTS\""]
    )
    #expect(SourceServiceFingerprint.evaluate(response, sourceType: .qnap) == .responded(statusCode: 401))
    #expect(SourceServiceFingerprint.evaluate(response, sourceType: .songloft) == .responded(statusCode: 401))
}

@Test func identityConfirmationListMatchesWhatTheEvaluatorCanConfirm() {
    // 一份把所有类型的认证标记都塞进去的响应:能认出身份的类型对它必然给
    // confirmed,认不出的永远只到 responded。两边清单漂了,探测的提前收尾就会
    // 对某个类型要么干等、要么把只会跳转的端口当成终点。
    let everyMarker = SourceServiceFingerprint.ProbeResponse(
        statusCode: 200,
        headerFields: ["DAV": "1, 2"],
        bodyPrefix: "{\"ServerName\":\"x\",\"Version\":\"1\",\"Id\":\"1\"} machineIdentifier "
            + "subsonic-response SYNO.API.Auth SYNO.AudioStation.Info"
    )
    for sourceType in MusicSourceType.allCases {
        let confirmed = SourceServiceFingerprint.probeRequest(for: sourceType) != nil
            && SourceServiceFingerprint.evaluate(everyMarker, sourceType: sourceType).isConfirmed
        #expect(
            SourceServiceFingerprint.canConfirmIdentity(of: sourceType) == confirmed,
            "\(sourceType.rawValue)"
        )
    }
}

@Test func probeResponseHeaderLookupIgnoresCase() {
    let response = SourceServiceFingerprint.ProbeResponse(
        statusCode: 200,
        headerFields: ["Content-Type": "application/json"]
    )
    #expect(response.headerValue("content-type") == "application/json")
    #expect(response.headerValue("CONTENT-TYPE") == "application/json")
    #expect(response.headerValue("DAV") == nil)
}
