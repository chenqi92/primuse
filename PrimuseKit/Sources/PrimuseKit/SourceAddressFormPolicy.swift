import Foundation

/// 「添加音乐源」表单里那几行地址怎么归位、怎么解读、什么时候需要重新探测。
///
/// 以前表单常驻两个区块(内网 / 公网),各有地址、端口、SSL、路径前缀,用户得
/// 自己判断手上这个地址该填哪个框 —— 而这个判断本来就是 App 自己能做的。现在
/// 表单只剩一串地址,归位规则集中在这里:`localEndpoint` / `publicEndpoint` /
/// `vendorIdentifier` 这三个存储位置**一点没变**,变的只是谁来决定往哪存。
///
/// 规则放在 kit 里还有一个原因:iOS 与 macOS 是两套布局,归位与解读一旦各写一遍
/// 就会慢慢长歪。两边都只调这里。
///
/// 纯函数、不访问网络;真正的探测在 `SourceEndpointResolver`。
public enum SourceAddressFormPolicy {

    /// 地址框最多几行。数据模型只有 `localEndpoint` / `publicEndpoint` 两个端点
    /// 槽,再多的地址无处可存;厂商标识不占槽,所以"两行"够表达
    /// 「内网 + 公网」和「内网 + QuickConnect」这两种真实配置。
    public static let maximumAddressCount = 2

    // MARK: - 槽位

    /// 一行地址最终存到哪。槽位只是存储位置的名字,不是对路由的限制 ——
    /// 两个槽都会被 `MusicSource.connectionCandidates` 排成候选。
    public enum Slot: String, Sendable, Equatable, CaseIterable {
        case local
        case publicAddress
        /// 厂商远程接入标识。不占端点槽,走 `vendorIdentifier`。
        case vendor
    }

    /// 界面上的一行地址输入,连同它自己那组高级选项。
    public struct AddressDraft: Sendable, Equatable {
        public var address: String
        /// 手填的端口。**nil 表示自动** —— 端口框留空就是让 App 去试,
        /// 而不是像旧表单那样预填一个真实值然后永远赢。
        public var manualPort: Int?
        /// 手选的协议。nil 表示自动。
        public var manualUseSsl: Bool?
        /// 不带点的单词按内网主机名理解,而不是厂商 ID。
        public var treatDotlessTokenAsHostname: Bool

        public init(
            address: String = "",
            manualPort: Int? = nil,
            manualUseSsl: Bool? = nil,
            treatDotlessTokenAsHostname: Bool = false
        ) {
            self.address = address
            self.manualPort = manualPort
            self.manualUseSsl = manualUseSsl
            self.treatDotlessTokenAsHostname = treatDotlessTokenAsHostname
        }

        public var trimmedAddress: String {
            address.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        public var isEmpty: Bool { trimmedAddress.isEmpty }

        /// 只有这几项会改变「该连到哪里」。判断编辑已有源要不要重新探测时
        /// 只比它 —— 改个名字、换个密码不该触发一轮联网。
        public var probeSignature: String {
            [
                trimmedAddress,
                manualPort.map(String.init) ?? "",
                manualUseSsl.map { $0 ? "ssl" : "plain" } ?? "",
                treatDotlessTokenAsHostname ? "hostname" : "vendor"
            ].joined(separator: "\u{1}")
        }
    }

    /// 每一行分到了哪个槽。
    public struct Placement: Sendable, Equatable {
        /// 与输入等长。没填、写错、或者没有槽位可放时为 nil。
        public var slots: [Slot?]
        public var localIndex: Int?
        public var publicIndex: Int?
        public var vendorIndex: Int?
        /// 地址本身是有效的,却没有槽位可放。界面要明说,不能悄悄丢掉。
        public var unusedIndices: [Int]

        public init(
            slots: [Slot?] = [],
            localIndex: Int? = nil,
            publicIndex: Int? = nil,
            vendorIndex: Int? = nil,
            unusedIndices: [Int] = []
        ) {
            self.slots = slots
            self.localIndex = localIndex
            self.publicIndex = publicIndex
            self.vendorIndex = vendorIndex
            self.unusedIndices = unusedIndices
        }

        /// 厂商标识在场时配置要切成 vendor 模式,否则是直连。
        public var usesVendorRemoteAccess: Bool { vendorIndex != nil }

        /// 至少有一条能用的路由。
        public var hasAnyRoute: Bool {
            localIndex != nil || publicIndex != nil || vendorIndex != nil
        }
    }

    // MARK: - 解读

    /// 一行地址读出来是什么。界面负责翻成人话。
    public enum Reading: Sendable, Equatable {
        case empty
        case vendor(VendorReading)
        case endpoint(EndpointReading)
        case invalid(SourceAddressInputPolicy.InvalidReason)
    }

    public struct VendorReading: Sendable, Equatable {
        public var kind: SourceAddressInputPolicy.VendorIdentifierKind
        public var id: String
        /// 前面已经填过一个厂商标识了,这一行用不上。
        public var isRedundant: Bool

        public init(
            kind: SourceAddressInputPolicy.VendorIdentifierKind,
            id: String,
            isRedundant: Bool
        ) {
            self.kind = kind
            self.id = id
            self.isRedundant = isRedundant
        }
    }

    public struct EndpointReading: Sendable, Equatable {
        public var input: SourceAddressInputPolicy.ParsedEndpointInput
        /// 会存进哪个槽;没有槽位可放时为 nil。
        public var slot: Slot?
        /// 按优先级排好的候选。第一条就是「保存时先试的那个」。
        public var candidates: [SourceConnectionCandidatePlanner.Candidate]
        /// 展示用的首选地址,不带端口:`https://emby.example.com/music`。
        /// 端口单独给,界面才能把「(443)」和「(默认)」分开说。
        public var displayAddress: String

        public init(
            input: SourceAddressInputPolicy.ParsedEndpointInput,
            slot: Slot?,
            candidates: [SourceConnectionCandidatePlanner.Candidate],
            displayAddress: String
        ) {
            self.input = input
            self.slot = slot
            self.candidates = candidates
            self.displayAddress = displayAddress
        }

        public var preferred: SourceConnectionCandidatePlanner.Candidate? { candidates.first }

        /// 端口和协议里至少有一样是我们替他猜的,保存时要真的去试一遍。
        public var isAutomatic: Bool { candidates.count > 1 }

        /// 解读行里标出来的那个位置,与归位用的是同一个判断。
        public var hostClass: SourceAddressInputPolicy.HostClass {
            SourceAddressFormPolicy.hostClass(of: input)
        }
    }

    /// 整张表单读一遍的结果。界面每次按键都调它,所以里面不做任何 I/O。
    public struct FormReading: Sendable, Equatable {
        public var interpretations: [SourceAddressInputPolicy.Interpretation]
        public var rows: [Reading]
        public var placement: Placement

        public init(
            interpretations: [SourceAddressInputPolicy.Interpretation] = [],
            rows: [Reading] = [],
            placement: Placement = Placement()
        ) {
            self.interpretations = interpretations
            self.rows = rows
            self.placement = placement
        }

        /// 有没有哪一行写坏了。写坏了就不该让用户提交。
        public var hasInvalidRow: Bool {
            rows.contains { if case .invalid = $0 { return true } else { return false } }
        }

        public var isSubmittable: Bool { hasInvalidRow == false && placement.hasAnyRoute }
    }

    public static func read(
        _ drafts: [AddressDraft],
        sourceType: MusicSourceType
    ) -> FormReading {
        let interpretations = drafts.map { draft in
            SourceAddressInputPolicy.interpret(
                draft.address,
                sourceType: sourceType,
                treatDotlessTokenAsHostname: draft.treatDotlessTokenAsHostname
            )
        }
        let placement = place(interpretations)
        let rows = interpretations.enumerated().map { index, interpretation -> Reading in
            reading(
                of: interpretation,
                draft: drafts[index],
                slot: placement.slots[index],
                isUnused: placement.unusedIndices.contains(index),
                sourceType: sourceType
            )
        }
        return FormReading(interpretations: interpretations, rows: rows, placement: placement)
    }

    // MARK: - 归位

    /// 地址按主机位置归位:内网 / 回环进 local,公网进 public,覆盖网优先 public。
    ///
    /// 两条地址想进同一个槽而另一个槽空着时,后来的那条放进空槽 —— 槽只是标签,
    /// 两条都会成为候选,顺序由 `SourceConnectionRuntime` 按当前网络决定。
    public static func place(
        _ interpretations: [SourceAddressInputPolicy.Interpretation]
    ) -> Placement {
        var slots = [Slot?](repeating: nil, count: interpretations.count)
        var unused: [Int] = []
        var vendorIndex: Int?
        var localIndex: Int?
        var publicIndex: Int?

        // 厂商标识先定:它不占端点槽,但它在不在场会改变端点的归位。
        for (index, interpretation) in interpretations.enumerated() {
            guard case .vendorIdentifier = interpretation else { continue }
            if vendorIndex == nil {
                vendorIndex = index
                slots[index] = .vendor
            } else {
                // 一个源只有一个厂商入口,第二个填了也用不上。
                unused.append(index)
            }
        }

        let endpoints: [(index: Int, preferred: Slot)] = interpretations.enumerated()
            .compactMap { index, interpretation in
                guard case let .endpoint(input) = interpretation else { return nil }
                return (
                    index,
                    preferredSlot(for: hostClass(of: input), vendorIsPresent: vendorIndex != nil)
                )
            }

        func claim(_ slot: Slot, at index: Int) -> Bool {
            switch slot {
            case .local:
                guard localIndex == nil else { return false }
                localIndex = index
            case .publicAddress:
                guard publicIndex == nil else { return false }
                publicIndex = index
            case .vendor:
                return false
            }
            slots[index] = slot
            return true
        }

        for endpoint in endpoints {
            _ = claim(endpoint.preferred, at: endpoint.index)
        }
        for endpoint in endpoints where slots[endpoint.index] == nil {
            // 首选槽被占了就退到另一个槽。带厂商标识时 public 槽是死的
            // (见 preferredSlot 的说明),所以这里不会把它当退路。
            let alternative: Slot = endpoint.preferred == .local ? .publicAddress : .local
            let isDeadSlot = vendorIndex != nil && alternative == .publicAddress
            if isDeadSlot || claim(alternative, at: endpoint.index) == false {
                unused.append(endpoint.index)
            }
        }

        return Placement(
            slots: slots,
            localIndex: localIndex,
            publicIndex: publicIndex,
            vendorIndex: vendorIndex,
            unusedIndices: unused.sorted()
        )
    }

    /// 单标签主机名(`mynas`、`nas`)在公网上不可能存在 —— 没有哪个顶级域叫这个,
    /// 它只能来自局域网的搜索域或 NetBIOS 名。
    ///
    /// `SourceAddressInputPolicy.hostClass` 仍然把它算成公网,那是刻意的:同一份
    /// 主机分类还兜着明文 HTTP 的信任策略(`InsecureHTTPHostPolicy`),在那里放宽
    /// 单标签主机等于给任意这样的名字免掉信任框。所以只在「放哪个槽、标什么」
    /// 这件事上重新判一次,探测超时与候选顺序照旧用原来的分类。
    public static func hostClass(
        of input: SourceAddressInputPolicy.ParsedEndpointInput
    ) -> SourceAddressInputPolicy.HostClass {
        promoted(input.hostClass, host: input.host, isIPLiteral: input.isIPLiteral)
    }

    /// 同一条规则,给只拿得到主机字符串的调用方(连接失败页)。
    public static func hostClass(ofHost rawHost: String) -> SourceAddressInputPolicy.HostClass {
        let host = NetworkHostAuthority.canonicalHost(rawHost)
        return promoted(
            SourceAddressInputPolicy.hostClass(of: host),
            host: host,
            isIPLiteral: NetworkHostAuthority.addressFamily(of: host) != .name
        )
    }

    private static func promoted(
        _ hostClass: SourceAddressInputPolicy.HostClass,
        host: String,
        isIPLiteral: Bool
    ) -> SourceAddressInputPolicy.HostClass {
        guard hostClass == .public,
              isIPLiteral == false,
              host.contains(".") == false,
              host.isEmpty == false else {
            return hostClass
        }
        return .lan
    }

    /// 一个不带点、不带斜杠、不带冒号的词:既可能是 QuickConnect ID / FN ID,
    /// 也可能是内网主机名。只有用户知道,所以界面要给一个切换。
    ///
    /// 「当成厂商标识也说得通」才算歧义 —— 太短的词本来就不是合法的 FN ID,
    /// 给它一个切换等于让用户点一个什么都不会变的按钮。
    public static func isAmbiguousDotlessToken(
        _ rawValue: String,
        sourceType: MusicSourceType
    ) -> Bool {
        guard sourceType.supportsVendorRemoteAccess else { return false }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.isEmpty == false,
              value.contains(".") == false,
              value.contains("/") == false,
              value.contains(":") == false else {
            return false
        }
        guard case .vendorIdentifier = SourceAddressInputPolicy.interpret(
            value,
            sourceType: sourceType,
            treatDotlessTokenAsHostname: false
        ) else {
            return false
        }
        return true
    }

    // MARK: - 连接失败时的针对性提示

    /// 连不上时除了原始错误,还能补一句「多半是这里错了」。判断只看这次实际用的
    /// 那个端点长什么样 —— 失败页拿不到探测结果,但地址本身就已经很能说明问题。
    public enum FailureHint: String, Sendable, Equatable, CaseIterable {
        case none
        /// 用域名访问,端口却是服务自己的端口。反代后面那台机器最常见的错法:
        /// 域名走的是 443,服务端口只在内网开着。
        case domainOnServicePort
        /// 公网主机走明文。
        case cleartextOnPublicHost
        /// 连的是内网地址,而这条路只有在同一个网里才通。
        case privateAddressFromOutside
        /// 走的是厂商中转,问题多半不在地址上。
        case vendorRelay
    }

    public static func failureHint(
        host: String,
        port: Int,
        useSsl: Bool,
        sourceType: MusicSourceType,
        usesVendorRemoteAccess: Bool
    ) -> FailureHint {
        if usesVendorRemoteAccess { return .vendorRelay }
        let canonical = NetworkHostAuthority.canonicalHost(host)
        guard canonical.isEmpty == false else { return .none }

        switch hostClass(ofHost: canonical) {
        case .loopback, .lan:
            return .privateAddressFromOutside
        case .overlay:
            return .none
        case .public:
            break
        }

        guard sourceType.usesHTTPTransport else { return .none }
        let isIPLiteral = NetworkHostAuthority.addressFamily(of: canonical) != .name
        // 裸 IP 直连本来就常用非标准端口,那不是错;域名后面站着反代才是。
        if isIPLiteral == false, port != 443, port != 80 { return .domainOnServicePort }
        if useSsl == false { return .cleartextOnPublicHost }
        return .none
    }

    /// 带厂商标识时公网槽是**死的**:`MusicSource.connectionCandidates` 在
    /// `remoteAccessMode == .vendor` 下只取 `vendorIdentifier`,`publicEndpoint`
    /// 连读都不读。所以此时公网地址要放进 local 槽才留得住 —— 槽名不准确,
    /// 但那条路由是真的能走;放进公网槽才是真的把它丢了。
    static func preferredSlot(
        for hostClass: SourceAddressInputPolicy.HostClass,
        vendorIsPresent: Bool
    ) -> Slot {
        if vendorIsPresent { return .local }
        switch hostClass {
        case .loopback, .lan: return .local
        // 覆盖网(Tailscale 之类)从外面也够得着,当远程路由用更合适;
        // 公网槽被占了会在上面退回 local。
        case .overlay, .public: return .publicAddress
        }
    }

    // MARK: - 是否需要重新探测

    /// 编辑已有源时,地址文本、手填端口、手选协议都没动过就别探测。
    ///
    /// 离线改个名字、换个密码不该因为服务器此刻不在线而失败 —— 已存的端口与
    /// 协议本来就是明确的,原样留着就行。
    public static func requiresProbe(
        drafts: [AddressDraft],
        baseline: [AddressDraft]?
    ) -> Bool {
        guard let baseline else { return true }
        guard baseline.count == drafts.count else { return true }
        for (draft, original) in zip(drafts, baseline)
        where draft.probeSignature != original.probeSignature {
            return true
        }
        return false
    }

    // MARK: - 回显

    /// 把已存的配置铺回地址框。顺序固定成「内网、公网/厂商」,这样打开编辑页
    /// 看到的顺序每次都一样。
    public static func drafts(
        for configuration: SourceConnectionConfiguration,
        sourceType: MusicSourceType
    ) -> [AddressDraft] {
        var drafts: [AddressDraft] = []
        if let endpoint = configuration.localEndpoint, endpoint.isUsable {
            drafts.append(draft(for: endpoint, sourceType: sourceType))
        }
        if configuration.remoteAccessMode == .vendor,
           sourceType.supportsVendorRemoteAccess,
           let identifier = configuration.vendorIdentifier?
               .trimmingCharacters(in: .whitespacesAndNewlines),
           identifier.isEmpty == false {
            drafts.append(AddressDraft(address: identifier))
        } else if let endpoint = configuration.publicEndpoint, endpoint.isUsable {
            drafts.append(draft(for: endpoint, sourceType: sourceType))
        }
        return drafts
    }

    /// 端口与协议都写进地址串里,所以高级选项回显成「自动」—— 地址串本身
    /// 已经是硬约束了,再在高级选项里重复一遍只会让用户以为改了两个地方。
    ///
    /// 「按主机名理解」也不用回显:`renderedAddress` 一定带协议,带了协议的串
    /// 本来就不可能被当成厂商标识。
    private static func draft(
        for endpoint: SourceConnectionEndpoint,
        sourceType: MusicSourceType
    ) -> AddressDraft {
        AddressDraft(
            address: SourceAddressInputPolicy.renderedAddress(
                for: endpoint,
                sourceType: sourceType
            )
        )
    }

    // MARK: - 私有

    private static func reading(
        of interpretation: SourceAddressInputPolicy.Interpretation,
        draft: AddressDraft,
        slot: Slot?,
        isUnused: Bool,
        sourceType: MusicSourceType
    ) -> Reading {
        switch interpretation {
        case .empty:
            return .empty
        case let .invalid(reason):
            return .invalid(reason)
        case let .vendorIdentifier(kind, id):
            return .vendor(VendorReading(kind: kind, id: id, isRedundant: isUnused))
        case let .endpoint(input):
            let candidates = SourceConnectionCandidatePlanner.candidates(
                for: input,
                sourceType: sourceType,
                manualPort: draft.manualPort,
                manualUseSsl: draft.manualUseSsl
            )
            return .endpoint(
                EndpointReading(
                    input: input,
                    slot: slot,
                    candidates: candidates,
                    displayAddress: displayAddress(
                        for: input,
                        candidate: candidates.first,
                        sourceType: sourceType
                    )
                )
            )
        }
    }

    /// 一个完全写死的地址:协议与端口都写出来,读回去只剩一个候选。
    ///
    /// 局域网发现预填用它 —— 那个端口是实测到的,没有再去猜的理由。
    public static func exactAddress(
        host: String,
        port: Int,
        useSsl: Bool,
        sourceType: MusicSourceType
    ) -> String {
        let scheme = scheme(forUseSsl: useSsl, sourceType: sourceType)
        return "\(scheme)://\(NetworkHostAuthority.urlHost(host)):\(port)"
    }

    public static func scheme(forUseSsl useSsl: Bool, sourceType: MusicSourceType) -> String {
        if sourceType.usesHTTPTransport { return useSsl ? "https" : "http" }
        if sourceType == .ftp { return useSsl ? "ftps" : "ftp" }
        return SourceAddressInputPolicy.acceptedSchemes(for: sourceType).first ?? "http"
    }

    /// 不带端口 —— 端口由界面单独说,因为「没写端口」和「写了 443」要给出
    /// 不一样的解释。
    static func displayAddress(
        for input: SourceAddressInputPolicy.ParsedEndpointInput,
        candidate: SourceConnectionCandidatePlanner.Candidate?,
        sourceType: MusicSourceType
    ) -> String {
        let scheme = displayScheme(for: candidate, sourceType: sourceType)
        let host = NetworkHostAuthority.urlHost(input.host)
        return "\(scheme)://\(host)\(input.pathPrefix ?? "")"
    }

    private static func displayScheme(
        for candidate: SourceConnectionCandidatePlanner.Candidate?,
        sourceType: MusicSourceType
    ) -> String {
        scheme(forUseSsl: candidate?.useSsl ?? sourceType.defaultSSL, sourceType: sourceType)
    }
}
