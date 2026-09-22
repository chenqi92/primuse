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
/// 3. **有优先级意识的提前结束。** 低优先级候选先确认时,只再给更高优先级的候选
///    一小段偏好窗口,不傻等全部 —— 内网 http 口 20 毫秒就回来了,没理由为它
///    多等一个公网候选的整段耐心。但**一个结论都还没有时要耐心等**:见 `Timeouts`。
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

    /// 每一类主机两段预算,外加整轮上限。
    ///
    /// 以前只有一段:内网 2 秒、覆盖网 3 秒、公网 4 秒,而且是**整条 HTTP 请求**
    /// 的上限 —— 建连、TLS、服务端处理全算在里面。NAS 硬盘休眠后第一次查接口、
    /// 服务冷启动、手机 Wi-Fi 刚醒,都能让一台正常的内网 NAS 两秒内一个字节都回
    /// 不来,于是所有候选一起超时,表单说「这些地址都没有回应」;再点一次(NAS
    /// 已经醒了)就过了。而同一个地址真正连接时,内网握手等 8 秒、公网 20 秒
    /// (`SourceConnectionHandshakePolicy`),单路由的源根本不设上限 —— 探测比它
    /// 把关的那次连接还苛刻,是反过来的。
    public struct Timeouts: Sendable, Equatable {

        public struct Budget: Sendable, Equatable {
            /// 还没有任何候选给出结论时,一个候选最多等多久。
            public var patience: TimeInterval
            /// 已有候选给出结论之后,还肯为排在它前面、仍没回话的候选再等多久
            /// (从第一个结论到手时算起)。
            public var preference: TimeInterval

            public init(patience: TimeInterval, preference: TimeInterval) {
                self.patience = patience
                self.preference = preference
            }
        }

        public var privateHost: Budget
        public var overlayHost: Budget
        public var publicHost: Budget
        /// 整轮探测的硬上限。只是兜底:候选是并发发出的,正常情况下每个候选
        /// 自己的 `patience` 先到。
        public var overall: TimeInterval

        /// 耐心与该地址存进去之后那条路由的握手预算对齐:内网地址进 local 槽,
        /// 8 秒;覆盖网与公网地址进公网槽,20 秒。偏好窗口沿用原来的 2 / 3 / 4
        /// 秒 —— 地址对了的时候用户等的时间和以前一样,只有一个结论都还没有时
        /// 才会多等。写成字面量而不是引用 `SourceConnectionHandshakePolicy`,
        /// 是为了让整条探测链路保持 Foundation-only、能在无 `Network` 的环境里
        /// 跑测试。
        public init(
            privateHost: Budget = Budget(patience: 8, preference: 2),
            overlayHost: Budget = Budget(patience: 20, preference: 3),
            publicHost: Budget = Budget(patience: 20, preference: 4),
            overall: TimeInterval = 24
        ) {
            self.privateHost = privateHost
            self.overlayHost = overlayHost
            self.publicHost = publicHost
            self.overall = overall
        }

        public static let `default` = Timeouts()

        public func budget(for hostClass: SourceAddressInputPolicy.HostClass) -> Budget {
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

        let budget = timeouts.budget(for: input.hostClass)
        let plans: [(candidate: SourceConnectionCandidatePlanner.Candidate, probe: Probe?)] =
            candidates.map { candidate in
                let url = Self.probeURL(for: candidate, input: input, request: request)
                return (candidate, url.map {
                    Probe(
                        url: $0,
                        method: request.method,
                        timeout: budget.patience,
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
            await runProbes(
                plans: plans,
                pending: &pending,
                verdicts: &verdicts,
                sourceType: sourceType,
                budget: budget
            )
        }
        try Task.checkCancellation()

        let selected = Self.selectedIndex(from: verdicts)
        let attempts = plans.enumerated().map { index, plan in
            Attempt(
                candidate: plan.candidate,
                url: plan.probe?.url.absoluteString ?? "",
                verdict: verdicts[index] ?? Self.abandonedVerdict(index: index, selected: selected)
            )
        }
        guard let selected else {
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

    /// 这条判定是不是已经是这个类型能拿到的最好结论。认得出身份的类型要
    /// confirmed;认不出的(威联通、绿联、S3 之类)有人应答就到头了,不必再为
    /// 别的候选干等。
    static func isDecisive(
        _ verdict: SourceServiceFingerprint.Verdict,
        sourceType: MusicSourceType
    ) -> Bool {
        if verdict.isConfirmed { return true }
        return verdict.isResponded && SourceServiceFingerprint.canConfirmIdentity(of: sourceType) == false
    }

    /// 还值不值得继续等。有了像样的结论之后,只有排在它前面的候选还有意义,
    /// 而且只在偏好窗口内有意义;一个结论都没有时,等到所有候选各自出结果。
    static func canFinish(
        verdicts: [Int: SourceServiceFingerprint.Verdict],
        pending: Set<Int>,
        sourceType: MusicSourceType,
        preferenceWindowClosed: Bool = false
    ) -> Bool {
        guard pending.isEmpty == false else { return true }
        guard let best = verdicts.filter({ isDecisive($0.value, sourceType: sourceType) }).keys.min() else {
            return false
        }
        if preferenceWindowClosed { return true }
        return pending.contains { $0 < best } == false
    }

    /// 收尾时还悬着的候选。排在选中项前面的是被等过、没等到回音的 —— 超时;
    /// 排在后面的是有了结论就不必再等的。一个都没选中时只可能是撞上了整轮上限,
    /// 它们同样发出去了、没回音,记成超时而不是「没再试」,失败清单才说得对。
    static func abandonedVerdict(index: Int, selected: Int?) -> SourceServiceFingerprint.Verdict {
        guard let selected, index > selected else { return .unreachable(.timedOut) }
        return .unreachable(.notAttempted)
    }

    // MARK: - 执行

    private enum GroupOutcome: Sendable {
        case probe(index: Int, verdict: SourceServiceFingerprint.Verdict)
        case preferenceWindowClosed
        case deadline
        case ignored
    }

    private func runProbes(
        plans: [(candidate: SourceConnectionCandidatePlanner.Candidate, probe: Probe?)],
        pending: inout Set<Int>,
        verdicts: inout [Int: SourceServiceFingerprint.Verdict],
        sourceType: MusicSourceType,
        budget: Timeouts.Budget
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
            group.addTask { await Self.timer(overall, firing: .deadline) }

            var preferenceWindowOpened = false
            var preferenceWindowClosed = false
            collecting: while let outcome = await group.next() {
                switch outcome {
                case .ignored:
                    continue collecting
                case .deadline:
                    break collecting
                case .preferenceWindowClosed:
                    preferenceWindowClosed = true
                case let .probe(index, verdict):
                    collected[index] = verdict
                    remaining.remove(index)
                    // 偏好窗口从第一个像样的结论到手时才开始计:服务端慢的时候
                    // 各个端口是一起慢的,从开探算起会让排在前面、只晚一点点的
                    // 那个候选输给后面的(比如 http 口输给要弹证书框的 https 口)。
                    if preferenceWindowOpened == false, Self.isDecisive(verdict, sourceType: sourceType) {
                        preferenceWindowOpened = true
                        let preference = budget.preference
                        group.addTask { await Self.timer(preference, firing: .preferenceWindowClosed) }
                    }
                }
                if Self.canFinish(
                    verdicts: collected,
                    pending: remaining,
                    sourceType: sourceType,
                    preferenceWindowClosed: preferenceWindowClosed
                ) {
                    break collecting
                }
            }
            group.cancelAll()
        }

        verdicts = collected
        pending = remaining
    }

    private static func timer(_ seconds: TimeInterval, firing outcome: GroupOutcome) async -> GroupOutcome {
        guard (try? await Task.sleep(nanoseconds: nanoseconds(seconds))) != nil else {
            return .ignored
        }
        return outcome
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
