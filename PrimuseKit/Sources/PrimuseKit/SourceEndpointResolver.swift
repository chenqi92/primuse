import Foundation

/// 把候选端口逐个探一遍,挑出真正是这个服务的那一个,并把每一条的结果留给界面。
///
/// 三点是刻意的:
/// 1. **不走 `TrustedHTTPTransport`。** 那条路在公网明文 / 自签证书时会弹信任框
///    并等用户决定,而那个等待挂在一个 SwiftUI alert 上 —— 被 sheet 吞掉过一次,
///    整条请求就永远悬着(NAS 一直转圈那次)。探测必须无人值守,所以请求加载器
///    是注入进来的闭包,生产实现用一个独立的 ephemeral 会话。
/// 2. **探测不带任何凭据。** 指纹请求全部是免登录接口,请求里没有秘密,拿回来的
///    东西只用来决定连哪个端口。正因为如此,生产加载器可以在 TLS 校验失败时
///    只为本次探测接受对方证书:没有可被中间人窃取的内容,也不写入任何信任记录。
///    真正的登录仍走原有传输层,该弹的信任框届时照常弹、照常由用户决定。
/// 3. **有优先级意识的提前结束。** 低优先级候选先确认时,只再等更高优先级的候选
///    走完各自的超时,不傻等全部 —— 内网 http 口 20 毫秒就回来了,没理由为它
///    多等一个公网候选的四秒。
///
/// 全 Foundation:加载器用自己的值类型收发,选择逻辑与指纹判定因此能在 Linux 上
/// 被真实测试覆盖(见 `SourceEndpointProbeSession` 里那份生产加载器)。
public struct SourceEndpointResolver: Sendable {

    /// 交给加载器执行的一次请求。
    public struct Probe: Sendable, Equatable {
        public var url: URL
        public var method: String
        public var timeout: TimeInterval
        public var maximumBodyBytes: Int

        public init(url: URL, method: String, timeout: TimeInterval, maximumBodyBytes: Int) {
            self.url = url
            self.method = method
            self.timeout = timeout
            self.maximumBodyBytes = maximumBodyBytes
        }
    }

    /// 失败时抛 `SourceServiceProbeFailure`;取消时抛 `CancellationError`。
    public typealias Loader = @Sendable (Probe) async throws -> SourceServiceFingerprint.ProbeResponse

    /// 单个候选的预算与整体上限。内网一次握手是几毫秒,公网要先解析再跨网,
    /// 量级跟着 `SourceRoutePathCondition` 的同类超时走。
    public struct Timeouts: Sendable, Equatable {
        public var privateHost: TimeInterval
        public var overlayHost: TimeInterval
        public var publicHost: TimeInterval
        /// 整轮探测的硬上限:候选再多,用户也不该等到这之后。
        public var overall: TimeInterval

        /// 默认值与 `SourceRoutePathCondition` 的同类超时同一量级:LAN 2 秒、
        /// 隧道 3 秒、公网 4 秒。这里写成字面量而不是引用那个类型,是为了让整个
        /// 探测链路保持 Foundation-only、能在无 `Network` 的环境里跑测试。
        public init(
            privateHost: TimeInterval = 2,
            overlayHost: TimeInterval = 3,
            publicHost: TimeInterval = 4,
            overall: TimeInterval = 12
        ) {
            self.privateHost = privateHost
            self.overlayHost = overlayHost
            self.publicHost = publicHost
            self.overall = overall
        }

        public static let `default` = Timeouts()

        public func timeout(for hostClass: SourceAddressInputPolicy.HostClass) -> TimeInterval {
            switch hostClass {
            case .loopback, .lan: return privateHost
            case .overlay: return overlayHost
            case .public: return publicHost
            }
        }
    }

    /// 一个候选试下来的完整结果。界面把这张清单原样展示给用户 —— 以前失败页
    /// 连"试了哪个地址"都不说。
    public struct Attempt: Sendable, Equatable, Identifiable {
        public var candidate: SourceConnectionCandidatePlanner.Candidate
        /// 实际请求过的完整 URL。端口等于协议默认端口时不写出来,和浏览器一致
        /// (有些虚拟主机只匹配不带端口的 Host)。
        public var url: String
        public var verdict: SourceServiceFingerprint.Verdict

        public init(
            candidate: SourceConnectionCandidatePlanner.Candidate,
            url: String,
            verdict: SourceServiceFingerprint.Verdict
        ) {
            self.candidate = candidate
            self.url = url
            self.verdict = verdict
        }

        public var id: String { candidate.id }
    }

    public struct Resolution: Sendable, Equatable {
        /// 选中的候选;一个都没应答时为 nil。
        public var selected: SourceConnectionCandidatePlanner.Candidate?
        /// 选中候选的判定。非 HTTP 类型没有探测过,为 nil。
        public var verdict: SourceServiceFingerprint.Verdict?
        public var attempts: [Attempt]

        public init(
            selected: SourceConnectionCandidatePlanner.Candidate? = nil,
            verdict: SourceServiceFingerprint.Verdict? = nil,
            attempts: [Attempt] = []
        ) {
            self.selected = selected
            self.verdict = verdict
            self.attempts = attempts
        }

        public var isResolved: Bool { selected != nil }

        /// 选中的候选确实被认成了这个服务,而不只是"有人应答"。
        public var isServiceConfirmed: Bool { verdict?.isConfirmed == true }

        /// 存进源记录的端点。
        public func endpoint(
            for input: SourceAddressInputPolicy.ParsedEndpointInput
        ) -> SourceConnectionEndpoint? {
            guard let selected else { return nil }
            return SourceConnectionCandidatePlanner.endpoint(for: input, candidate: selected)
        }
    }

    private let load: Loader
    private let timeouts: Timeouts

    public init(load: @escaping Loader, timeouts: Timeouts = .default) {
        self.load = load
        self.timeouts = timeouts
    }

    public func resolve(
        for input: SourceAddressInputPolicy.ParsedEndpointInput,
        sourceType: MusicSourceType,
        candidates: [SourceConnectionCandidatePlanner.Candidate]
    ) async throws -> Resolution {
        try Task.checkCancellation()
        guard candidates.isEmpty == false else { return Resolution() }
        guard let request = SourceServiceFingerprint.probeRequest(for: sourceType) else {
            // 非 HTTP 类型没有免登录指纹,候选也只有一条:直接定下来,不发请求。
            return Resolution(selected: candidates.first)
        }

        let timeout = timeouts.timeout(for: input.hostClass)
        let plans: [(candidate: SourceConnectionCandidatePlanner.Candidate, probe: Probe?)] =
            candidates.map { candidate in
                let url = Self.probeURL(for: candidate, input: input, request: request)
                return (candidate, url.map {
                    Probe(
                        url: $0,
                        method: request.method,
                        timeout: timeout,
                        maximumBodyBytes: SourceServiceFingerprint.maximumInspectedBodyBytes
                    )
                })
            }

        var verdicts: [Int: SourceServiceFingerprint.Verdict] = [:]
        var pending = Set<Int>()
        for (index, plan) in plans.enumerated() {
            if plan.probe == nil {
                verdicts[index] = .unreachable(.connectionFailed)
            } else {
                pending.insert(index)
            }
        }

        if pending.isEmpty == false {
            await runProbes(plans: plans, pending: &pending, verdicts: &verdicts, sourceType: sourceType)
        }
        try Task.checkCancellation()

        let attempts = plans.enumerated().map { index, plan in
            Attempt(
                candidate: plan.candidate,
                url: plan.probe?.url.absoluteString ?? "",
                verdict: verdicts[index] ?? .unreachable(.notAttempted)
            )
        }
        guard let selected = Self.selectedIndex(from: verdicts) else {
            return Resolution(attempts: attempts)
        }
        return Resolution(
            selected: plans[selected].candidate,
            verdict: verdicts[selected],
            attempts: attempts
        )
    }

    // MARK: - 选择规则(纯函数)

    /// 优先级最高的 confirmed 胜出;一个 confirmed 都没有就退回优先级最高的
    /// responded —— 有人应答至少说明端口开着,总比让用户自己猜强。
    static func selectedIndex(from verdicts: [Int: SourceServiceFingerprint.Verdict]) -> Int? {
        if let confirmed = verdicts.filter({ $0.value.isConfirmed }).keys.min() { return confirmed }
        return verdicts.filter { $0.value.isResponded }.keys.min()
    }

    /// 还值不值得继续等。已经有 confirmed 时,只有排在它前面的候选还有意义。
    static func canFinish(
        verdicts: [Int: SourceServiceFingerprint.Verdict],
        pending: Set<Int>
    ) -> Bool {
        guard let bestConfirmed = verdicts.filter({ $0.value.isConfirmed }).keys.min() else {
            return pending.isEmpty
        }
        return pending.contains { $0 < bestConfirmed } == false
    }

    // MARK: - 执行

    private enum GroupOutcome: Sendable {
        case probe(index: Int, verdict: SourceServiceFingerprint.Verdict)
        case deadline
        case ignored
    }

    private func runProbes(
        plans: [(candidate: SourceConnectionCandidatePlanner.Candidate, probe: Probe?)],
        pending: inout Set<Int>,
        verdicts: inout [Int: SourceServiceFingerprint.Verdict],
        sourceType: MusicSourceType
    ) async {
        let started = pending
        var remaining = pending
        var collected = verdicts

        await withTaskGroup(of: GroupOutcome.self) { group in
            for index in started.sorted() {
                guard let probe = plans[index].probe else { continue }
                let load = self.load
                group.addTask {
                    .probe(index: index, verdict: await Self.runProbe(probe, sourceType: sourceType, load: load))
                }
            }
            let overall = timeouts.overall
            group.addTask {
                guard (try? await Task.sleep(nanoseconds: Self.nanoseconds(overall))) != nil else {
                    return .ignored
                }
                return .deadline
            }

            collecting: for await outcome in group {
                switch outcome {
                case .ignored:
                    continue
                case .deadline:
                    break collecting
                case let .probe(index, verdict):
                    collected[index] = verdict
                    remaining.remove(index)
                    if Self.canFinish(verdicts: collected, pending: remaining) { break collecting }
                }
            }
            group.cancelAll()
        }

        verdicts = collected
        pending = remaining
    }

    private static func runProbe(
        _ probe: Probe,
        sourceType: MusicSourceType,
        load: @escaping Loader
    ) async -> SourceServiceFingerprint.Verdict {
        await withTaskGroup(of: SourceServiceFingerprint.Verdict?.self) { group in
            group.addTask {
                do {
                    let response = try await load(probe)
                    return SourceServiceFingerprint.evaluate(response, sourceType: sourceType)
                } catch is CancellationError {
                    return .unreachable(.cancelled)
                } catch let failure as SourceServiceProbeFailure {
                    return .unreachable(failure.reason)
                } catch {
                    return .unreachable(.connectionFailed)
                }
            }
            // 加载器自己也带超时,但那是平台的请求超时;这一层保证无论加载器
            // 怎么实现,单个候选都不会拖住整轮。
            group.addTask {
                guard (try? await Task.sleep(nanoseconds: nanoseconds(probe.timeout))) != nil else {
                    return nil
                }
                return .unreachable(.timedOut)
            }
            for await value in group {
                guard let value else { continue }
                group.cancelAll()
                return value
            }
            return .unreachable(.connectionFailed)
        }
    }

    private static func nanoseconds(_ seconds: TimeInterval) -> UInt64 {
        UInt64(max(0, seconds) * 1_000_000_000)
    }

    // MARK: - URL 拼装

    static func probeURL(
        for candidate: SourceConnectionCandidatePlanner.Candidate,
        input: SourceAddressInputPolicy.ParsedEndpointInput,
        request: SourceServiceFingerprint.ProbeRequest
    ) -> URL? {
        // 端口等于协议默认端口时省掉:`Host: example.com:443` 会让一部分只按
        // 裸域名配置的虚拟主机落到默认站点上,而那正是我们要区分的东西。
        let impliedPort = candidate.useSsl ? 443 : 80
        guard let authority = NetworkHostAuthority.authority(
            host: input.host,
            port: candidate.port == impliedPort ? nil : candidate.port
        // 根路径写成 `/`:`ProxyPrefixedBasePathPolicy.appending` 只改
        // percentEncodedPath,基址没有路径时它接不上东西,探测就会打到空路径上。
        ), let root = URL(string: "\(candidate.httpScheme)://\(authority)/") else {
            return nil
        }

        // 反代前缀要逐字带上 —— 服务根就在前缀后面。
        let base = ProxyPrefixedBasePathPolicy.appending(input.pathPrefix, to: root)
        let withPath = ProxyPrefixedBasePathPolicy.appending(request.path, to: base)
        guard request.queryItems.isEmpty == false else { return withPath }
        guard var components = URLComponents(url: withPath, resolvingAgainstBaseURL: false) else {
            return withPath
        }
        components.queryItems = request.queryItems
        return components.url ?? withPath
    }
}
