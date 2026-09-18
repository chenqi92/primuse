import SwiftUI
import PrimuseKit

// MARK: - 一行地址的界面状态

/// 协议三态。「自动」不是一个取值,而是"不要写死" —— 交给候选规划去逐个试,
/// 这正是旧表单做不到的事:那里的 SSL 开关永远有一个确定答案。
enum SourceAddressTransportChoice: String, CaseIterable, Identifiable {
    case automatic
    case cleartext
    case secure

    var id: String { rawValue }

    var manualUseSsl: Bool? {
        switch self {
        case .automatic: return nil
        case .cleartext: return false
        case .secure: return true
        }
    }

    static func choice(forUseSsl useSsl: Bool?) -> SourceAddressTransportChoice {
        guard let useSsl else { return .automatic }
        return useSsl ? .secure : .cleartext
    }
}

/// 表单里的一行地址。地址串本身是主输入,端口与协议是它的高级选项。
struct SourceAddressRow: Identifiable, Equatable {
    let id = UUID()
    var address: String = ""
    /// 空字符串 = 自动。**绝不预填真实端口**:预填出来的值会在用户填了域名之后
    /// 继续生效,把 `https://emby.example.com` 连成 `:8096`。
    var portText: String = ""
    var transport: SourceAddressTransportChoice = .automatic
    var showsAdvancedOptions = false
    var treatDotlessTokenAsHostname = false

    var manualPort: Int? {
        let trimmed = portText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed), (1...65_535).contains(value) else { return nil }
        return value
    }

    /// 端口框里写了东西却不是个能用的端口。留空是合法的(自动),写错不是。
    var hasInvalidManualPort: Bool {
        portText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            && manualPort == nil
    }

    var isEmpty: Bool {
        address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var draft: SourceAddressFormPolicy.AddressDraft {
        SourceAddressFormPolicy.AddressDraft(
            address: address,
            manualPort: manualPort,
            manualUseSsl: transport.manualUseSsl,
            treatDotlessTokenAsHostname: treatDotlessTokenAsHostname
        )
    }

    /// 从一个已存的端点/标识回显。高级选项留在「自动」—— 端口与协议已经写进
    /// 地址串里了,再在下面重复一遍会让用户以为有两个地方要改。
    init(draft: SourceAddressFormPolicy.AddressDraft) {
        address = draft.address
        portText = draft.manualPort.map(String.init) ?? ""
        transport = .choice(forUseSsl: draft.manualUseSsl)
        treatDotlessTokenAsHostname = draft.treatDotlessTokenAsHostname
    }

    init(address: String = "") {
        self.address = address
    }
}

// MARK: - 探测

/// 提交时把候选端口真的试一遍。界面只关心三件事:在不在跑、每条试了什么、
/// 选中的那条到底认没认出是这个服务。
@MainActor
@Observable
final class SourceAddressProbeController {

    enum Phase: Equatable {
        case idle
        case probing
        /// 有地址一个候选都没应答。清单留在界面上,用户可以继续改,也可以坚持保存。
        case unresolved
    }

    struct Outcome {
        var selected: [UUID: SourceConnectionCandidatePlanner.Candidate] = [:]
        var unresolvedRowIDs: [UUID] = []
        var isCancelled = false
    }

    private(set) var phase: Phase = .idle
    private(set) var attempts: [UUID: [SourceEndpointResolver.Attempt]] = [:]
    private(set) var verdicts: [UUID: SourceServiceFingerprint.Verdict] = [:]

    /// 会话活到控制器被释放为止:一次提交可能要发四五个请求,每次都新建会话
    /// 等于每次都重建连接池。
    private let session = SourceEndpointProbeSession()

    var isProbing: Bool { phase == .probing }

    /// 地址一改就把上一轮的结论清掉 —— 留着会让用户以为新地址也试过了。
    func invalidate() {
        guard phase != .idle || attempts.isEmpty == false else { return }
        phase = .idle
        attempts = [:]
        verdicts = [:]
    }

    func probe(
        rows: [SourceAddressRow],
        reading: SourceAddressFormPolicy.FormReading,
        sourceType: MusicSourceType
    ) async -> Outcome {
        let plans = Self.plans(rows: rows, reading: reading)
        guard plans.isEmpty == false else { return Outcome() }

        phase = .probing
        attempts = [:]
        verdicts = [:]

        let resolver = SourceEndpointResolver(load: session.loader())
        var resolutions: [UUID: SourceEndpointResolver.Resolution] = [:]
        await withTaskGroup(of: (UUID, SourceEndpointResolver.Resolution?).self) { group in
            // 两行地址并发探,而不是一行等完再探下一行:每一轮本身就有十几秒的
            // 上限,串起来用户要等一倍。捕获的都是单个 Sendable 值,不带整个计划
            // 结构进任务里。
            for plan in plans {
                let id = plan.id
                let input = plan.input
                let candidates = plan.candidates
                group.addTask {
                    let resolution = try? await resolver.resolve(
                        for: input,
                        sourceType: sourceType,
                        candidates: candidates
                    )
                    return (id, resolution)
                }
            }
            for await (id, resolution) in group {
                resolutions[id] = resolution
            }
        }

        guard Task.isCancelled == false else {
            phase = .idle
            return Outcome(isCancelled: true)
        }

        var outcome = Outcome()
        var collectedAttempts: [UUID: [SourceEndpointResolver.Attempt]] = [:]
        var collectedVerdicts: [UUID: SourceServiceFingerprint.Verdict] = [:]
        // 按表单里的顺序收集,任务组的完成顺序不该泄漏到界面上。
        for plan in plans {
            guard let resolution = resolutions[plan.id], let candidate = resolution.selected else {
                // 尝试清单只在这一行一个候选都没应答时才有意义 —— 定下来的那行
                // 再列一遍"试过什么"只会让人以为它也没成。
                collectedAttempts[plan.id] = resolutions[plan.id]?.attempts ?? []
                outcome.unresolvedRowIDs.append(plan.id)
                continue
            }
            outcome.selected[plan.id] = candidate
            collectedVerdicts[plan.id] = resolution.verdict
        }

        attempts = collectedAttempts
        verdicts = collectedVerdicts
        phase = outcome.unresolvedRowIDs.isEmpty ? .idle : .unresolved
        return outcome
    }

    private struct Plan {
        var id: UUID
        var input: SourceAddressInputPolicy.ParsedEndpointInput
        var candidates: [SourceConnectionCandidatePlanner.Candidate]
    }

    /// 只探要真正存下来的端点行。厂商标识不用探(它不是一个地址),没抢到槽位的
    /// 那一行也不用探(存不进去)。
    private static func plans(
        rows: [SourceAddressRow],
        reading: SourceAddressFormPolicy.FormReading
    ) -> [Plan] {
        var plans: [Plan] = []
        for (index, row) in rows.enumerated() where index < reading.rows.count {
            guard case let .endpoint(endpoint) = reading.rows[index],
                  endpoint.slot != nil else {
                continue
            }
            plans.append(Plan(id: row.id, input: endpoint.input, candidates: endpoint.candidates))
        }
        return plans
    }
}

// MARK: - 解读行的文案

/// 结构化的解读结果翻成人话。两套布局共用这一份,免得 iOS 与 macOS 慢慢说成
/// 两种话。返回的都是已经本地化好的字符串,调用方直接 `Text(...)`。
enum SourceAddressReadingText {

    /// 地址框下面那一行。nil 表示这一行还没什么可说的(空输入)。
    static func line(
        for reading: SourceAddressFormPolicy.Reading,
        sourceType: MusicSourceType
    ) -> String? {
        switch reading {
        case .empty:
            return nil
        case let .invalid(reason):
            return invalidText(reason)
        case let .vendor(vendor):
            if vendor.isRedundant {
                return String(localized: "source_address_reading_vendor_redundant")
            }
            return vendorText(vendor.kind)
        case let .endpoint(endpoint):
            return endpointText(endpoint, sourceType: sourceType)
        }
    }

    /// 解读行该不该按「出错了」来显示。
    static func isProblem(_ reading: SourceAddressFormPolicy.Reading) -> Bool {
        switch reading {
        case .invalid:
            return true
        case let .vendor(vendor):
            return vendor.isRedundant
        case let .endpoint(endpoint):
            return endpoint.slot == nil
        case .empty:
            return false
        }
    }

    static func hostClassText(_ hostClass: SourceAddressInputPolicy.HostClass) -> String {
        switch hostClass {
        case .loopback: return String(localized: "source_address_class_loopback")
        // 沿用音乐源卡片上已有的那一个词,同一个概念不该在两处叫两个名字。
        case .lan: return String(localized: "source_connection_local")
        case .overlay: return String(localized: "source_address_class_overlay")
        case .public: return String(localized: "source_address_class_public")
        }
    }

    /// 尝试清单里那一条为什么不通。清单只在"一个候选都没应答"时出现,所以里面
    /// 只会有不可达的结论;真选中了的那条不走这里。
    static func attemptReasonText(_ attempt: SourceEndpointResolver.Attempt) -> String? {
        guard case let .unreachable(reason) = attempt.verdict else { return nil }
        return unreachableText(reason)
    }

    /// 选中的候选只是「有人应答」而不是「确认是这个服务」时的那句实话。
    static func unconfirmedNote(
        _ verdict: SourceServiceFingerprint.Verdict?,
        sourceType: MusicSourceType
    ) -> String? {
        guard let verdict, verdict.isResponded else { return nil }
        return String(
            format: String(localized: "source_address_probe_unconfirmed %@"),
            sourceType.displayName
        )
    }

    // MARK: - 私有

    private static func endpointText(
        _ endpoint: SourceAddressFormPolicy.EndpointReading,
        sourceType: MusicSourceType
    ) -> String {
        guard let candidate = endpoint.preferred else {
            return String(localized: "source_address_reading_unused")
        }
        let format = endpoint.isAutomatic
            ? String(localized: "source_address_reading_auto %@ %@")
            : String(localized: "source_address_reading %@ %@")
        let body = String(format: format, endpoint.displayAddress, String(candidate.port))
        guard endpoint.slot != nil else {
            return "\(body)\n\(String(localized: "source_address_reading_unused"))"
        }
        return "\(hostClassText(endpoint.hostClass)) · \(body)"
    }

    private static func vendorText(
        _ kind: SourceAddressInputPolicy.VendorIdentifierKind
    ) -> String {
        switch kind {
        case .synologyQuickConnect:
            return String(localized: "source_address_reading_quickconnect")
        case .fnConnect:
            return String(localized: "source_address_reading_fnid")
        }
    }

    private static func invalidText(
        _ reason: SourceAddressInputPolicy.InvalidReason
    ) -> String {
        switch reason {
        case .missingHost: return String(localized: "source_address_invalid_missing_host")
        case .schemeMismatch: return String(localized: "source_address_invalid_scheme")
        case .invalidPort: return String(localized: "source_address_invalid_port")
        case .invalidHost: return String(localized: "source_address_invalid_host")
        case .credentialsInAddress: return String(localized: "source_address_invalid_credentials")
        }
    }

    private static func unreachableText(
        _ reason: SourceServiceFingerprint.UnreachableReason
    ) -> String {
        switch reason {
        case .timedOut: return String(localized: "source_address_probe_timed_out")
        case .hostNotFound: return String(localized: "source_address_probe_host_not_found")
        case .tlsFailure: return String(localized: "source_address_probe_tls_failure")
        case .cleartextOnTLSPort: return String(localized: "source_address_probe_cleartext")
        case .connectionFailed: return String(localized: "source_address_probe_refused")
        case .cancelled: return String(localized: "source_address_probe_cancelled")
        case .notAttempted: return String(localized: "source_address_probe_not_attempted")
        }
    }
}

// MARK: - 连接失败页的针对性提示

enum SourceConnectionFailureHintText {
    static func text(
        for hint: SourceAddressFormPolicy.FailureHint,
        sourceType: MusicSourceType
    ) -> String? {
        switch hint {
        case .none:
            return nil
        case .domainOnServicePort:
            return String(localized: "connection_failed_hint_domain_port")
        case .cleartextOnPublicHost:
            return String(localized: "connection_failed_hint_cleartext_public")
        case .privateAddressFromOutside:
            return String(localized: "connection_failed_hint_private_address")
        case .vendorRelay:
            return String(localized: "connection_failed_hint_vendor_relay")
        }
    }
}

// MARK: - 连接失败时的地址说明

/// 一次连接失败该说清楚的两件事:这次连的到底是哪个地址,以及按地址形态给的
/// 那一句针对性提示。群晖的连接页与各个目录浏览器共用这一份取值 —— 同一个
/// 概念不该在两处慢慢说成两种话。
///
/// 地址只由协议 / 主机 / 端口 / 路径拼出来,**不含任何凭据**。
struct SourceConnectionFailureReport: Equatable, Sendable {
    /// 这次实际用过的完整地址。没有「服务器地址」这个概念的源(云盘、本机、
    /// UPnP 这种发现出来的设备)为 nil。
    var address: String?
    /// 针对性提示。判断不出来就没有。
    var hint: String?
    /// 这次失败值不值得去改地址。服务器已经应答并拒绝了(密码错、目录不存在)
    /// 时改地址解决不了问题,按钮就不该出现。
    var suggestsAddressEdit = true

    var isEmpty: Bool { address == nil && hint == nil }

    /// 从「这次实际用来连接的那个源」直接取值:候选路由必须已经应用过 ——
    /// 调用方比这里更清楚自己走的是哪一条。
    static func make(
        forAttempted source: MusicSource,
        usesVendorRemoteAccess: Bool,
        suggestsAddressEdit: Bool = true
    ) -> SourceConnectionFailureReport {
        SourceConnectionFailureReport(
            address: address(for: source, usesVendorRemoteAccess: usesVendorRemoteAccess),
            hint: hint(for: source, usesVendorRemoteAccess: usesVendorRemoteAccess),
            suggestsAddressEdit: suggestsAddressEdit
        )
    }

    /// 目录浏览器用的入口。浏览器只拿得到一个 connector,不知道它最后走的是哪条
    /// 路由,所以这里自己去问一遍路由记忆,把那条候选投影到源上再取值。
    ///
    /// 连接失败会把活动路由作废,所以多数情况下问到的是 nil —— 那就退回首选
    /// 候选,它正是下一次重试会用的那一条。
    ///
    /// 错误在调用方那边就分好类:`any Error` 不是 Sendable,不该跨过这道
    /// await 的隔离边界。
    static func resolve(
        for source: MusicSource,
        suggestsAddressEdit suggestsEdit: Bool
    ) async -> SourceConnectionFailureReport {
        guard source.type.requiresHost else { return SourceConnectionFailureReport() }

        guard source.effectiveConnectionConfiguration != nil else {
            return make(
                forAttempted: source,
                usesVendorRemoteAccess: usesVendorRemoteAccess(source, candidateKind: nil),
                suggestsAddressEdit: suggestsEdit
            )
        }

        let runtime = SourceConnectionRuntime.shared
        let ordered = await runtime.orderedCandidates(for: source)
        let activeKind = await runtime.activeKind(for: source.id)
        let candidate = ordered.first { $0.kind == activeKind } ?? ordered.first
        let attempted = candidate.map(source.applyingConnectionCandidate) ?? source
        return make(
            forAttempted: attempted,
            usesVendorRemoteAccess: usesVendorRemoteAccess(
                attempted,
                candidateKind: candidate?.kind
            ),
            suggestsAddressEdit: suggestsEdit
        )
    }

    /// 这次失败值不值得去改地址。目录浏览器不像群晖连接页那样自己分过类,所以
    /// 只按它们本来就会抛出的那几种错误来判断,**不另立一套错误分类**。
    /// 认不出来的一律给按钮:少一个出口比多一个按钮更糟。
    static func errorSuggestsAddressEdit(_ error: Error) -> Bool {
        // 用户拒了明文连接 —— 换成 https 的地址就是正当出路。
        if error is TrustedHTTPTransportError { return true }
        // 某条路由已经连上服务并被业务拒绝了。
        if error is SourceConnectionTerminalError { return false }
        if let sourceError = error as? SourceError {
            switch sourceError {
            case .connectionFailed, .timeout:
                return true
            case .authenticationFailed, .pathNotFound, .fileNotFound, .credentialUnavailable:
                return false
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .userAuthenticationRequired, .noPermissionsToReadFile, .badServerResponse:
                return false
            default:
                return true
            }
        }
        return true
    }

    // MARK: - 私有

    private static func address(
        for source: MusicSource,
        usesVendorRemoteAccess: Bool
    ) -> String? {
        guard let rawHost = source.host?.trimmingCharacters(in: .whitespacesAndNewlines),
              rawHost.isEmpty == false else {
            return nil
        }
        // QuickConnect / FN Connect 的"地址"就是那个标识本身。
        if usesVendorRemoteAccess { return rawHost }
        // 反代前缀的源把整个地址塞进了 host 字段,原样显示就是最准确的。
        if rawHost.contains("://") { return rawHost }
        let endpoint = SourceConnectionEndpoint(
            host: rawHost,
            port: source.port ?? source.type.defaultPort(useSsl: source.useSsl),
            useSsl: source.useSsl,
            pathPrefix: source.type.supportsEndpointSpecificPath ? source.basePath : nil
        )
        let rendered = SourceAddressInputPolicy.renderedAddress(
            for: endpoint,
            sourceType: source.type
        )
        guard rendered.isEmpty == false else { return nil }
        guard let share = shareComponent(of: source) else { return rendered }
        return rendered + share
    }

    /// 文件共享协议里只说到哪台机器还差一半:共享名 / 导出路径也是地址的一部分,
    /// 而它们不在端点里,`renderedAddress` 管不着。
    private static func shareComponent(of source: MusicSource) -> String? {
        let raw: String?
        switch source.type {
        case .smb: raw = source.shareName
        case .nfs: raw = source.exportPath
        default: return nil
        }
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.isEmpty == false else {
            return nil
        }
        return value.hasPrefix("/") ? value : "/\(value)"
    }

    private static func hint(
        for source: MusicSource,
        usesVendorRemoteAccess: Bool
    ) -> String? {
        guard let rawHost = source.host?.trimmingCharacters(in: .whitespacesAndNewlines),
              rawHost.isEmpty == false else {
            return nil
        }
        let host = rawHost.contains("://")
            ? (URL(string: rawHost)?.host ?? rawHost)
            : rawHost
        let hint = SourceAddressFormPolicy.failureHint(
            host: host,
            port: source.port ?? source.type.defaultPort(useSsl: source.useSsl),
            useSsl: source.useSsl,
            sourceType: source.type,
            usesVendorRemoteAccess: usesVendorRemoteAccess
        )
        return SourceConnectionFailureHintText.text(for: hint, sourceType: source.type)
    }

    private static func usesVendorRemoteAccess(
        _ source: MusicSource,
        candidateKind: SourceConnectionCandidateKind?
    ) -> Bool {
        if candidateKind == .vendorRemote { return true }
        switch source.type {
        case .synology, .synologyAudioStation: return source.effectiveSynologyConnectionMode == .quickConnect
        case .fnMusic: return source.effectiveFnMusicConnectionMode == .fnConnect
        default: return false
        }
    }
}

/// 失败态那几行说明的排版:地址在错误上面,提示在错误下面。群晖连接页与各个
/// 目录浏览器用的是同一棵子树,免得两边的顺序和措辞各走各的。
struct SourceConnectionFailureDetails: View {
    /// 字号跟着承载它的那一屏走:群晖连接页是整屏的失败态,目录浏览器里是
    /// 列表中间的一小块。
    enum Emphasis: Equatable { case page, inline }

    let report: SourceConnectionFailureReport
    let errorText: String
    var emphasis: Emphasis = .page

    var body: some View {
        VStack(spacing: emphasis == .page ? 10 : 8) {
            if let address = report.address {
                Text(String(format: String(localized: "connection_failed_address %@"), address))
                    .font(bodyFont)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
            }
            if errorText.isEmpty == false {
                Text(verbatim: errorText)
                    .font(bodyFont)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if let hint = report.hint {
                Label(hint, systemImage: "lightbulb")
                    .font(hintFont)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
        }
    }

    private var bodyFont: Font { emphasis == .page ? .subheadline : .caption }
    private var hintFont: Font { emphasis == .page ? .footnote : .caption2 }
}

/// 失败态里的「修改地址」。宿主没有可回去的编辑表单(新建源的事务里就没有),
/// 或者这次失败跟地址无关时,按钮不出现。
struct SourceConnectionEditAddressButton: View {
    let report: SourceConnectionFailureReport
    var onEditAddress: (() -> Void)?

    @ViewBuilder
    var body: some View {
        if let onEditAddress, report.suggestsAddressEdit {
            Button { onEditAddress() } label: {
                Label("connection_failed_edit_address", systemImage: "pencil")
            }
            .buttonStyle(.bordered)
        }
    }
}

// MARK: - 表单行视图

/// 一行地址在 iOS 表单里的样子:地址框 + 解读行 + 折叠起来的高级选项。
///
/// 不加 `#if os(iOS)`:承载它的 `AddSourceView.formSections` 本身在两个平台上
/// 都要编译(Mac 只是不用它),而 `keyboardType` / `textInputAutocapitalization`
/// 在 macOS 上有 `PlatformShims` 里的空实现。Mac 的实际布局是下面那个。
struct SourceAddressRowView: View {
    @Binding var row: SourceAddressRow
    let reading: SourceAddressFormPolicy.Reading
    let sourceType: MusicSourceType
    let attempts: [SourceEndpointResolver.Attempt]
    let canRemove: Bool
    var onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            addressField
            readingLine
            dotlessToggle
            advancedOptions
            attemptList
        }
        .padding(.vertical, 2)
    }

    private var addressField: some View {
        HStack(spacing: 10) {
            TextField("source_address_placeholder", text: $row.address)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.next)
            if canRemove {
                Button(role: .destructive, action: onRemove) {
                    Image(systemName: "minus.circle.fill")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text("source_address_remove"))
            }
        }
    }

    @ViewBuilder
    private var readingLine: some View {
        if let text = SourceAddressReadingText.line(for: reading, sourceType: sourceType) {
            Text(text)
                .font(.caption)
                // 两个分支都写成 Color:`.red` 与 `.secondary` 不是同一个类型,
                // 三元里混用编不过。
                .foregroundStyle(
                    SourceAddressReadingText.isProblem(reading) ? Color.red : Color.secondary
                )
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 不带点的单词既可能是厂商标识也可能是内网主机名,只有用户知道。
    @ViewBuilder
    private var dotlessToggle: some View {
        if SourceAddressFormPolicy.isAmbiguousDotlessToken(row.address, sourceType: sourceType) {
            Button {
                row.treatDotlessTokenAsHostname.toggle()
            } label: {
                // 分成两个分支而不是三元:`Text(条件 ? "a" : "b")` 会被推断成
                // `Text(String)`,那个初始化器不做本地化。
                if row.treatDotlessTokenAsHostname {
                    Text("source_address_treat_as_vendor").font(.caption)
                } else {
                    Text("source_address_treat_as_hostname").font(.caption)
                }
            }
            .buttonStyle(.borderless)
        }
    }

    @ViewBuilder
    private var advancedOptions: some View {
        if sourceType.requiresHost {
            DisclosureGroup(isExpanded: $row.showsAdvancedOptions) {
                VStack(alignment: .leading, spacing: 10) {
                    portField
                    if sourceType.usesHTTPTransport {
                        transportPicker
                    }
                }
                .padding(.top, 6)
            } label: {
                Text("source_address_advanced").font(.caption)
            }
        }
    }

    private var portField: some View {
        HStack {
            Text("port").font(.callout)
            Spacer(minLength: 12)
            TextField(portPlaceholder, text: $row.portText)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 120)
        }
        .foregroundStyle(row.hasInvalidManualPort ? Color.red : Color.primary)
    }

    /// placeholder 写默认端口,框里**留空**:看得见默认值,又不会把它当成用户的
    /// 选择带进 URL。
    private var portPlaceholder: String {
        String(sourceType.defaultPort(useSsl: row.transport.manualUseSsl ?? sourceType.defaultSSL))
    }

    private var transportPicker: some View {
        Picker("source_address_transport", selection: $row.transport) {
            Text("source_address_transport_automatic")
                .tag(SourceAddressTransportChoice.automatic)
            Text(verbatim: "HTTP").tag(SourceAddressTransportChoice.cleartext)
            Text(verbatim: "HTTPS").tag(SourceAddressTransportChoice.secure)
        }
        .pickerStyle(.segmented)
    }

    @ViewBuilder
    private var attemptList: some View {
        if attempts.isEmpty == false {
            VStack(alignment: .leading, spacing: 4) {
                Text("source_address_probe_unresolved")
                    .font(.caption)
                    .foregroundStyle(.red)
                ForEach(attempts) { attempt in
                    attemptRow(attempt)
                }
            }
            .pmFadeTransition(motion: .contentAppear)
        }
    }

    /// 试过的完整地址一行,不通的原因一行。地址给等宽字体并允许选中,方便直接
    /// 贴到浏览器里对一遍。
    private func attemptRow(_ attempt: SourceEndpointResolver.Attempt) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(attempt.url)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let reason = SourceAddressReadingText.attemptReasonText(attempt) {
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - macOS 行视图

#if os(macOS)
/// 与 iOS 同一套内容,换成 Mac 表单的卡片行。
struct MacSourceAddressRowView: View {
    @Binding var row: SourceAddressRow
    let reading: SourceAddressFormPolicy.Reading
    let sourceType: MusicSourceType
    let attempts: [SourceEndpointResolver.Attempt]
    let canRemove: Bool
    var onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            addressField
            readingLine
            dotlessToggle
            advancedOptions
            attemptList
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) {
            Rectangle().fill(PMColor.divider).frame(height: 0.5)
        }
    }

    private var addressField: some View {
        HStack(spacing: 10) {
            TextField("source_address_placeholder", text: $row.address)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
            if canRemove {
                Button(action: onRemove) {
                    Image(systemName: "minus.circle")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(PMColor.textFaint)
                .accessibilityLabel(Text("source_address_remove"))
            }
        }
    }

    @ViewBuilder
    private var readingLine: some View {
        if let text = SourceAddressReadingText.line(for: reading, sourceType: sourceType) {
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(
                    SourceAddressReadingText.isProblem(reading) ? Color.red : PMColor.textFaint
                )
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var dotlessToggle: some View {
        if SourceAddressFormPolicy.isAmbiguousDotlessToken(row.address, sourceType: sourceType) {
            Button {
                row.treatDotlessTokenAsHostname.toggle()
            } label: {
                // 同 iOS:三元会让 `Text` 落到不做本地化的 String 初始化器上。
                if row.treatDotlessTokenAsHostname {
                    Text("source_address_treat_as_vendor").font(.system(size: 11.5))
                } else {
                    Text("source_address_treat_as_hostname").font(.system(size: 11.5))
                }
            }
            .buttonStyle(.link)
        }
    }

    @ViewBuilder
    private var advancedOptions: some View {
        if sourceType.requiresHost {
            DisclosureGroup(isExpanded: $row.showsAdvancedOptions) {
                VStack(alignment: .leading, spacing: 8) {
                    portField
                    if sourceType.usesHTTPTransport {
                        transportPicker
                    }
                }
                .padding(.top, 6)
            } label: {
                Text("source_address_advanced")
                    .font(.system(size: 11.5))
                    .foregroundStyle(PMColor.textMuted)
            }
        }
    }

    private var portField: some View {
        HStack(spacing: 12) {
            Text("port")
                .font(.system(size: 12))
                .foregroundStyle(PMColor.text)
            Spacer(minLength: 12)
            TextField(portPlaceholder, text: $row.portText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .multilineTextAlignment(.trailing)
                .frame(width: 110)
                .foregroundStyle(row.hasInvalidManualPort ? Color.red : PMColor.text)
        }
    }

    private var portPlaceholder: String {
        String(sourceType.defaultPort(useSsl: row.transport.manualUseSsl ?? sourceType.defaultSSL))
    }

    private var transportPicker: some View {
        Picker("", selection: $row.transport) {
            Text("source_address_transport_automatic")
                .tag(SourceAddressTransportChoice.automatic)
            Text(verbatim: "HTTP").tag(SourceAddressTransportChoice.cleartext)
            Text(verbatim: "HTTPS").tag(SourceAddressTransportChoice.secure)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 260)
    }

    @ViewBuilder
    private var attemptList: some View {
        if attempts.isEmpty == false {
            VStack(alignment: .leading, spacing: 4) {
                Text("source_address_probe_unresolved")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.red)
                ForEach(attempts) { attempt in
                    attemptRow(attempt)
                }
            }
            .pmFadeTransition(motion: .contentAppear)
        }
    }

    private func attemptRow(_ attempt: SourceEndpointResolver.Attempt) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(attempt.url)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(PMColor.textFaint)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let reason = SourceAddressReadingText.attemptReasonText(attempt) {
                Text(reason)
                    .font(.system(size: 11))
                    .foregroundStyle(PMColor.textFaint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif
