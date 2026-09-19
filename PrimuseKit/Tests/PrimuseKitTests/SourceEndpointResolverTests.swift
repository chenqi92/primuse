import Foundation
import Testing
@testable import PrimuseKit

// MARK: - 替身

/// 按 URL 编排的假加载器。生产实现在 `SourceEndpointProbeSession`,那份代码依赖
/// URLSession,只能在 Apple 端验;选择规则与指纹判定在这里被真实执行。
private struct ScriptedProbes: Sendable {
    enum Step: Sendable {
        case respond(SourceServiceFingerprint.ProbeResponse, after: TimeInterval)
        case fail(SourceServiceFingerprint.UnreachableReason, after: TimeInterval)
        case hang
    }

    var steps: [String: Step]
    /// 脚本里没写到的 URL 怎么办。默认当成连不上。
    var fallback: Step = .fail(.connectionFailed, after: 0)

    func loader() -> SourceEndpointResolver.Loader {
        let steps = self.steps
        let fallback = self.fallback
        return { probe in
            let step = steps[probe.url.absoluteString] ?? fallback
            switch step {
            case let .respond(response, delay):
                if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                return response
            case let .fail(reason, delay):
                if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                throw SourceServiceProbeFailure(reason)
            case .hang:
                try await Task.sleep(nanoseconds: 60_000_000_000)
                throw SourceServiceProbeFailure(.connectionFailed)
            }
        }
    }
}

private let embyInfo = SourceServiceFingerprint.ProbeResponse(
    statusCode: 200,
    headerFields: ["Content-Type": "application/json"],
    bodyPrefix: "{\"ServerName\":\"Attic\",\"Version\":\"4.9.0.42\",\"Id\":\"ab12\"}"
)

private let plainOK = SourceServiceFingerprint.ProbeResponse(
    statusCode: 200,
    headerFields: ["Server": "nginx"],
    bodyPrefix: "<html>hello</html>"
)

private let synologyAuthInfo = SourceServiceFingerprint.ProbeResponse(
    statusCode: 200,
    headerFields: ["Content-Type": "application/json"],
    bodyPrefix: "{\"data\":{\"SYNO.API.Auth\":{\"maxVersion\":7,\"minVersion\":1,\"path\":\"entry.cgi\"}},\"success\":true}"
)

private let synologyQuery = "/webapi/query.cgi?api=SYNO.API.Info&version=1&method=query&query=SYNO.API.Auth"

private func uniformTimeouts(
    patience: TimeInterval,
    preference: TimeInterval,
    overall: TimeInterval
) -> SourceEndpointResolver.Timeouts {
    let budget = SourceEndpointResolver.Timeouts.Budget(patience: patience, preference: preference)
    return SourceEndpointResolver.Timeouts(
        privateHost: budget,
        overlayHost: budget,
        publicHost: budget,
        overall: overall
    )
}

private let fastTimeouts = uniformTimeouts(patience: 0.4, preference: 0.4, overall: 3)

private func parsed(_ address: String, _ sourceType: MusicSourceType) -> SourceAddressInputPolicy.ParsedEndpointInput {
    guard case let .endpoint(input) = SourceAddressInputPolicy.interpret(address, sourceType: sourceType) else {
        fatalError("\(address) is not an endpoint")
    }
    return input
}

// MARK: - URL 拼装

@Test func probeURLAppendsTheFingerprintPathAfterAReverseProxyPrefix() {
    let input = parsed("https://demo.jellyfin.org/stable", .jellyfin)
    let candidates = SourceConnectionCandidatePlanner.candidates(for: input, sourceType: .jellyfin)
    guard let request = SourceServiceFingerprint.probeRequest(for: .jellyfin),
          let first = candidates.first,
          let url = SourceEndpointResolver.probeURL(for: first, input: input, request: request) else {
        Issue.record("could not build a probe URL")
        return
    }
    #expect(url.absoluteString == "https://demo.jellyfin.org/stable/System/Info/Public")
}

@Test func probeURLOmitsTheSchemeDefaultPortAndKeepsEveryOther() {
    let input = parsed("emby.example.com", .emby)
    guard let request = SourceServiceFingerprint.probeRequest(for: .emby) else {
        Issue.record("no probe request")
        return
    }
    let onDefault = SourceConnectionCandidatePlanner.Candidate(useSsl: true, port: 443, origin: .schemeDefaultPort)
    let onService = SourceConnectionCandidatePlanner.Candidate(useSsl: true, port: 8920, origin: .serviceDefaultPort)
    #expect(
        SourceEndpointResolver.probeURL(for: onDefault, input: input, request: request)?.absoluteString
            == "https://emby.example.com/System/Info/Public"
    )
    #expect(
        SourceEndpointResolver.probeURL(for: onService, input: input, request: request)?.absoluteString
            == "https://emby.example.com:8920/System/Info/Public"
    )
}

@Test func probeURLPutsTheWebDAVOptionsOnTheConfiguredPrefix() {
    // DAV 头挂在那个集合上,站点根目录未必开了 DAV。
    let input = parsed("https://dav.example.com/remote.php/dav", .webdav)
    guard let request = SourceServiceFingerprint.probeRequest(for: .webdav),
          let candidate = SourceConnectionCandidatePlanner.candidates(for: input, sourceType: .webdav).first,
          let url = SourceEndpointResolver.probeURL(for: candidate, input: input, request: request) else {
        Issue.record("could not build a probe URL")
        return
    }
    #expect(request.method == "OPTIONS")
    #expect(url.absoluteString == "https://dav.example.com/remote.php/dav")
}

@Test func probeURLBracketsIPv6AndCarriesQueryItems() {
    let input = parsed("[fd00::1]", .navidrome)
    guard let request = SourceServiceFingerprint.probeRequest(for: .navidrome) else {
        Issue.record("no probe request")
        return
    }
    let candidate = SourceConnectionCandidatePlanner.Candidate(useSsl: false, port: 4533, origin: .serviceDefaultPort)
    let url = SourceEndpointResolver.probeURL(for: candidate, input: input, request: request)
    #expect(
        url?.absoluteString == "http://[fd00::1]:4533/rest/ping.view?f=json&v=1.16.1&c=Primuse"
    )
}

// MARK: - 选择规则(纯函数)

@Test func selectionPrefersTheHighestPriorityConfirmation() {
    let verdicts: [Int: SourceServiceFingerprint.Verdict] = [
        0: .responded(statusCode: 200),
        1: .confirmed,
        2: .confirmed
    ]
    #expect(SourceEndpointResolver.selectedIndex(from: verdicts) == 1)
}

@Test func selectionFallsBackToTheHighestPriorityResponder() {
    let verdicts: [Int: SourceServiceFingerprint.Verdict] = [
        0: .unreachable(.timedOut),
        1: .responded(statusCode: 401),
        2: .responded(statusCode: 200)
    ]
    #expect(SourceEndpointResolver.selectedIndex(from: verdicts) == 1)
}

@Test func selectionYieldsNothingWhenEveryCandidateIsUnreachable() {
    let verdicts: [Int: SourceServiceFingerprint.Verdict] = [
        0: .unreachable(.timedOut),
        1: .unreachable(.tlsFailure)
    ]
    #expect(SourceEndpointResolver.selectedIndex(from: verdicts) == nil)
}

@Test func earlyFinishWaitsOnlyForHigherPriorityCandidates() {
    let confirmedSecond: [Int: SourceServiceFingerprint.Verdict] = [1: .confirmed]
    // 0 号还没回来,它优先级更高,必须等。
    #expect(SourceEndpointResolver.canFinish(verdicts: confirmedSecond, pending: [0, 2], sourceType: .emby) == false)
    // 只剩优先级更低的 2 号,不必等。
    #expect(SourceEndpointResolver.canFinish(verdicts: confirmedSecond, pending: [2], sourceType: .emby))
    // 偏好窗口过了,排在前面的也不再等。
    #expect(SourceEndpointResolver.canFinish(
        verdicts: confirmedSecond,
        pending: [0, 2],
        sourceType: .emby,
        preferenceWindowClosed: true
    ))

    // 认得出身份的类型一个 confirmed 都没有时,必须等完 —— 窗口关没关都一样。
    let onlyResponded: [Int: SourceServiceFingerprint.Verdict] = [0: .responded(statusCode: 200)]
    #expect(SourceEndpointResolver.canFinish(verdicts: onlyResponded, pending: [1], sourceType: .emby) == false)
    #expect(SourceEndpointResolver.canFinish(
        verdicts: onlyResponded,
        pending: [1],
        sourceType: .emby,
        preferenceWindowClosed: true
    ) == false)
    #expect(SourceEndpointResolver.canFinish(verdicts: onlyResponded, pending: [], sourceType: .emby))
}

@Test func aResponderIsDecisiveOnlyForTypesThatCannotBeConfirmed() {
    let onlyResponded: [Int: SourceServiceFingerprint.Verdict] = [0: .responded(statusCode: 200)]
    // 威联通没有免登录指纹,有人应答就是能拿到的最好结论,不必再等排在后面的。
    #expect(SourceEndpointResolver.canFinish(verdicts: onlyResponded, pending: [1, 2], sourceType: .qnap))
    #expect(SourceEndpointResolver.isDecisive(.responded(statusCode: 401), sourceType: .qnap))
    // 群晖 80 口只会 301 到 https 时也是「有人应答」,不能因此停下 —— 真正的服务在后面。
    #expect(SourceEndpointResolver.isDecisive(.responded(statusCode: 301), sourceType: .synology) == false)
    #expect(SourceEndpointResolver.isDecisive(.unreachable(.timedOut), sourceType: .qnap) == false)
}

@Test func abandonedCandidatesAreTimedOutUnlessTheyRankBelowTheSelection() {
    #expect(SourceEndpointResolver.abandonedVerdict(index: 0, selected: 2) == .unreachable(.timedOut))
    #expect(SourceEndpointResolver.abandonedVerdict(index: 3, selected: 2) == .unreachable(.notAttempted))
    #expect(SourceEndpointResolver.abandonedVerdict(index: 1, selected: nil) == .unreachable(.timedOut))
}

// MARK: - 端到端

@Test func resolverSelectsTheConfirmedCandidateOverAnEarlierResponder() async throws {
    let input = parsed("emby.example.com", .emby)
    let candidates = SourceConnectionCandidatePlanner.candidates(for: input, sourceType: .emby)
    // 优先级 0 是 https:443 —— 反代的默认站点答得飞快,但不是 Emby。
    let script = ScriptedProbes(steps: [
        "https://emby.example.com/System/Info/Public": .respond(plainOK, after: 0),
        "https://emby.example.com:8920/System/Info/Public": .respond(embyInfo, after: 0.05),
        "http://emby.example.com:8096/System/Info/Public": .fail(.connectionFailed, after: 0),
        "http://emby.example.com/System/Info/Public": .fail(.connectionFailed, after: 0)
    ])
    let resolver = SourceEndpointResolver(load: script.loader(), timeouts: fastTimeouts)
    let resolution = try await resolver.resolve(for: input, sourceType: .emby, candidates: candidates)

    #expect(resolution.selected?.id == "ssl:8920")
    #expect(resolution.isServiceConfirmed)
    #expect(resolution.endpoint(for: input) == SourceConnectionEndpoint(host: "emby.example.com", port: 8920, useSsl: true))
    #expect(resolution.attempts.count == candidates.count)
    #expect(resolution.attempts.first?.verdict == .responded(statusCode: 200))
}

@Test func resolverStillWaitsForAHigherPriorityConfirmation() async throws {
    let input = parsed("emby.example.com", .emby)
    let candidates = SourceConnectionCandidatePlanner.candidates(for: input, sourceType: .emby)
    let script = ScriptedProbes(steps: [
        // 优先级更高的 443 慢一点,但它也是 Emby —— 不能因为 8920 先回来就选它。
        "https://emby.example.com/System/Info/Public": .respond(embyInfo, after: 0.08),
        "https://emby.example.com:8920/System/Info/Public": .respond(embyInfo, after: 0),
        "http://emby.example.com:8096/System/Info/Public": .hang,
        "http://emby.example.com/System/Info/Public": .hang
    ])
    let resolver = SourceEndpointResolver(load: script.loader(), timeouts: fastTimeouts)
    let started = Date()
    let resolution = try await resolver.resolve(for: input, sourceType: .emby, candidates: candidates)
    let elapsed = Date().timeIntervalSince(started)

    #expect(resolution.selected?.id == "ssl:443")
    // 优先级更低的两条挂着不回,但没人等它们。
    #expect(elapsed < 1)
    #expect(resolution.attempts.last?.verdict == .unreachable(.notAttempted))
}

@Test func resolverFallsBackToTheHighestPriorityResponder() async throws {
    let input = parsed("192.168.1.10", .qnap)
    let candidates = SourceConnectionCandidatePlanner.candidates(for: input, sourceType: .qnap)
    let script = ScriptedProbes(steps: [
        "http://192.168.1.10:8080/": .respond(plainOK, after: 0),
        "https://192.168.1.10/": .respond(plainOK, after: 0),
        "https://192.168.1.10:443/": .respond(plainOK, after: 0),
        "http://192.168.1.10/": .respond(plainOK, after: 0)
    ])
    let resolver = SourceEndpointResolver(load: script.loader(), timeouts: fastTimeouts)
    let resolution = try await resolver.resolve(for: input, sourceType: .qnap, candidates: candidates)

    // QNAP 没有免登录握手,四条都只能算「有人应答」,于是按优先级取第一条。
    #expect(resolution.selected?.id == candidates.first?.id)
    #expect(resolution.isServiceConfirmed == false)
    #expect(resolution.verdict == .responded(statusCode: 200))
}

@Test func resolverReportsEveryFailureWhenNothingAnswers() async throws {
    let input = parsed("192.168.1.10", .emby)
    let candidates = SourceConnectionCandidatePlanner.candidates(for: input, sourceType: .emby)
    let script = ScriptedProbes(steps: [
        "http://192.168.1.10:8096/System/Info/Public": .fail(.connectionFailed, after: 0),
        "https://192.168.1.10:8920/System/Info/Public": .fail(.tlsFailure, after: 0),
        "https://192.168.1.10/System/Info/Public": .fail(.tlsFailure, after: 0),
        "http://192.168.1.10/System/Info/Public": .fail(.connectionFailed, after: 0)
    ])
    let resolver = SourceEndpointResolver(load: script.loader(), timeouts: fastTimeouts)
    let resolution = try await resolver.resolve(for: input, sourceType: .emby, candidates: candidates)

    #expect(resolution.isResolved == false)
    #expect(resolution.attempts.count == 4)
    #expect(resolution.attempts.allSatisfy { $0.verdict == .unreachable(.connectionFailed) || $0.verdict == .unreachable(.tlsFailure) })
    // 每一条都带着试过的完整地址,好让失败页说清楚试了什么。
    #expect(resolution.attempts.allSatisfy { $0.url.isEmpty == false })
}

@Test func resolverTimesOutASilentCandidate() async throws {
    let input = parsed("192.168.1.10", .emby)
    let candidates = SourceConnectionCandidatePlanner.candidates(for: input, sourceType: .emby)
    let script = ScriptedProbes(steps: [
        "http://192.168.1.10:8096/System/Info/Public": .hang,
        "https://192.168.1.10:8920/System/Info/Public": .respond(embyInfo, after: 0),
        "https://192.168.1.10/System/Info/Public": .hang,
        "http://192.168.1.10/System/Info/Public": .hang
    ])
    let resolver = SourceEndpointResolver(load: script.loader(), timeouts: fastTimeouts)
    let started = Date()
    let resolution = try await resolver.resolve(for: input, sourceType: .emby, candidates: candidates)
    let elapsed = Date().timeIntervalSince(started)

    #expect(resolution.selected?.id == "ssl:8920")
    #expect(resolution.attempts.first?.verdict == .unreachable(.timedOut))
    // 只为 0 号那条等了它自己的超时,不是四条串起来等。
    #expect(elapsed < 1.5)
}

@Test func resolverStopsAtTheOverallDeadline() async throws {
    let input = parsed("emby.example.com", .emby)
    let candidates = SourceConnectionCandidatePlanner.candidates(for: input, sourceType: .emby)
    let slow = uniformTimeouts(patience: 30, preference: 30, overall: 0.3)
    let hanging = ScriptedProbes(steps: [:], fallback: .hang)
    let resolver = SourceEndpointResolver(load: hanging.loader(), timeouts: slow)
    let started = Date()
    let resolution = try await resolver.resolve(for: input, sourceType: .emby, candidates: candidates)
    let elapsed = Date().timeIntervalSince(started)

    #expect(resolution.isResolved == false)
    #expect(elapsed < 2)
    // 它们都发出去了,只是没等到回音 —— 失败清单该说「超时」而不是「没有再试」。
    #expect(resolution.attempts.allSatisfy { $0.verdict == .unreachable(.timedOut) })
}

@Test func resolverWaitsForASlowServerWhenNothingHasAnsweredYet() async throws {
    // 硬盘休眠刚醒的群晖:两个 DSM 口都要将近一秒才回话,80/443 没开。
    // 旧的单段预算(这里对应偏好窗口 0.2 秒)会把它判成「这些地址都没有回应」。
    let input = parsed("192.168.1.10", .synology)
    let candidates = SourceConnectionCandidatePlanner.candidates(for: input, sourceType: .synology)
    let script = ScriptedProbes(steps: [
        "http://192.168.1.10:5000\(synologyQuery)": .respond(synologyAuthInfo, after: 0.6),
        "https://192.168.1.10:5001\(synologyQuery)": .respond(synologyAuthInfo, after: 0.6)
    ])
    let resolver = SourceEndpointResolver(
        load: script.loader(),
        timeouts: uniformTimeouts(patience: 2, preference: 0.2, overall: 3)
    )
    let resolution = try await resolver.resolve(for: input, sourceType: .synology, candidates: candidates)

    #expect(candidates.first?.id == "plain:5000")
    #expect(resolution.selected?.id == "plain:5000")
    #expect(resolution.isServiceConfirmed)
}

@Test func resolverKeepsTheHigherPriorityPortWhenItAnswersSoonAfterTheFirst() async throws {
    // 服务端慢的时候各个端口是一起慢的。https 口先回来一点点,不能因此把
    // 排在前面的 http 口判输 —— 偏好窗口从第一个结论到手时才开始计。
    let input = parsed("192.168.1.10", .synology)
    let candidates = SourceConnectionCandidatePlanner.candidates(for: input, sourceType: .synology)
    let script = ScriptedProbes(steps: [
        "http://192.168.1.10:5000\(synologyQuery)": .respond(synologyAuthInfo, after: 0.8),
        "https://192.168.1.10:5001\(synologyQuery)": .respond(synologyAuthInfo, after: 0.6)
    ])
    let resolver = SourceEndpointResolver(
        load: script.loader(),
        timeouts: uniformTimeouts(patience: 3, preference: 0.5, overall: 4)
    )
    let resolution = try await resolver.resolve(for: input, sourceType: .synology, candidates: candidates)

    #expect(resolution.selected?.id == "plain:5000")
}

@Test func resolverGivesHigherPriorityCandidatesOnlyThePreferenceWindowOnceConfirmed() async throws {
    // 只转发了 8096 的公网 Emby:443、8920 被防火墙静默丢包。确认之后只再等
    // 一小段,不为它们耗完整段耐心。
    let input = parsed("emby.example.com", .emby)
    let candidates = SourceConnectionCandidatePlanner.candidates(for: input, sourceType: .emby)
    let script = ScriptedProbes(steps: [
        "https://emby.example.com/System/Info/Public": .hang,
        "https://emby.example.com:8920/System/Info/Public": .hang,
        "http://emby.example.com:8096/System/Info/Public": .respond(embyInfo, after: 0),
        "http://emby.example.com/System/Info/Public": .hang
    ])
    let resolver = SourceEndpointResolver(
        load: script.loader(),
        timeouts: uniformTimeouts(patience: 10, preference: 0.3, overall: 12)
    )
    let started = Date()
    let resolution = try await resolver.resolve(for: input, sourceType: .emby, candidates: candidates)
    let elapsed = Date().timeIntervalSince(started)

    #expect(resolution.selected?.id == "plain:8096")
    #expect(elapsed < 2)
    #expect(resolution.attempts.first?.verdict == .unreachable(.timedOut))
    #expect(resolution.attempts.last?.verdict == .unreachable(.notAttempted))
}

@Test func resolverSettlesOnTheFirstResponderForTypesWithoutAFingerprint() async throws {
    let input = parsed("192.168.1.10", .qnap)
    let candidates = SourceConnectionCandidatePlanner.candidates(for: input, sourceType: .qnap)
    guard let first = candidates.first,
          let request = SourceServiceFingerprint.probeRequest(for: .qnap),
          let firstURL = SourceEndpointResolver.probeURL(for: first, input: input, request: request) else {
        Issue.record("could not build the first probe URL")
        return
    }
    let script = ScriptedProbes(
        steps: [firstURL.absoluteString: .respond(plainOK, after: 0)],
        fallback: .hang
    )
    let resolver = SourceEndpointResolver(
        load: script.loader(),
        timeouts: uniformTimeouts(patience: 10, preference: 0.3, overall: 12)
    )
    let started = Date()
    let resolution = try await resolver.resolve(for: input, sourceType: .qnap, candidates: candidates)
    let elapsed = Date().timeIntervalSince(started)

    // 有人应答已经是威联通能拿到的最好结论,排在后面挂着的那几条不用等。
    #expect(resolution.selected?.id == first.id)
    #expect(elapsed < 1)
}

@Test func defaultPatienceMatchesTheHandshakeBudgetOfTheSlotTheAddressLandsIn() {
    let timeouts = SourceEndpointResolver.Timeouts.default
    // 内网地址进 local 槽,真正连接时握手等 8 秒;覆盖网与公网进公网槽,20 秒。
    #expect(timeouts.budget(for: .lan).patience == 8)
    #expect(timeouts.budget(for: .loopback).patience == 8)
    #expect(timeouts.budget(for: .overlay).patience == 20)
    #expect(timeouts.budget(for: .public).patience == 20)
    // 地址对了时的等待与以前一样。
    #expect(timeouts.budget(for: .lan).preference == 2)
    #expect(timeouts.budget(for: .overlay).preference == 3)
    #expect(timeouts.budget(for: .public).preference == 4)
    // 整轮上限只是兜底,不能比单个候选的耐心还短。
    #expect(timeouts.overall > timeouts.budget(for: .public).patience)
}

@Test func resolverPropagatesCancellation() async throws {
    let input = parsed("emby.example.com", .emby)
    let candidates = SourceConnectionCandidatePlanner.candidates(for: input, sourceType: .emby)
    let hanging = ScriptedProbes(steps: [:], fallback: .hang)
    let resolver = SourceEndpointResolver(
        load: hanging.loader(),
        timeouts: uniformTimeouts(patience: 30, preference: 30, overall: 30)
    )

    let task = Task { () -> SourceEndpointResolver.Resolution in
        try await resolver.resolve(for: input, sourceType: .emby, candidates: candidates)
    }
    task.cancel()

    do {
        _ = try await task.value
        Issue.record("expected the resolve to be cancelled")
    } catch is CancellationError {
        // 正常。
    }
}

@Test func resolverSkipsProbingForTypesWithoutAFingerprint() async throws {
    let input = parsed("nas.local", .smb)
    let candidates = SourceConnectionCandidatePlanner.candidates(for: input, sourceType: .smb)
    let script = ScriptedProbes(steps: [:])
    let resolver = SourceEndpointResolver(load: script.loader(), timeouts: fastTimeouts)
    let resolution = try await resolver.resolve(for: input, sourceType: .smb, candidates: candidates)

    #expect(resolution.selected?.port == 445)
    #expect(resolution.verdict == nil)
    #expect(resolution.attempts.isEmpty)
    #expect(resolution.endpoint(for: input) == SourceConnectionEndpoint(host: "nas.local", port: 445, useSsl: false))
}
