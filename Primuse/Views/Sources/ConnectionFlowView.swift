import SwiftUI
import PrimuseKit

// MARK: - Connection Flow

struct ConnectionFlowView: View {
    let source: MusicSource
    @Binding var selectedDirectories: [String]
    var onDeviceTrustSaved: ((Bool, String?) -> Void)?
    var onSessionReady: ((SynologyAPI) -> Void)?
    var onPasswordWillChange: (() -> Bool)?
    var onPasswordSaveUncertain: (() -> Void)?
    var onPasswordSaved: (() async -> Bool)?
    /// 失败页「修改地址」的出口。这个视图不知道自己是怎么被呈现的 —— 关掉当前
    /// sheet、再打开该源的编辑表单全由宿主负责。宿主没有可回去的表单时传 nil,
    /// 按钮就不出现。
    var onEditAddress: (() -> Void)?
    /// Audio Station 登录并确认权限之后调用:它没有目录可选,宿主在这里开始整库扫描,
    /// 这个视图随后自行关闭。
    var onAudioStationReady: (() -> Void)?
    var requestsPassword = false
    var initialPassword: String?
    var onAuthenticated: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.pmHeightClass) private var heightClass

    @State private var step: FlowStep = .connecting
    @State private var otpCode = ""
    @State private var passwordInput = ""
    /// A replacement entered after DSM rejects the saved password. Keep it in
    /// memory until login, optional 2FA, SSL trust, and the first authenticated
    /// directory request have all succeeded. The last known-good Keychain item
    /// must remain untouched while any of those checks are still pending.
    @State private var pendingPasswordCandidate: String?
    @State private var errorMessage = ""
    @State private var rememberDevice = true
    @State private var synologyAPI: SynologyAPI?
    @State private var activeSynologySource: MusicSource?
    @State private var activeSynologyCandidateKind: SourceConnectionCandidateKind?
    @State private var rootItems: [SynologyAPI.FileItem] = []
    @State private var connectionTask: Task<Void, Never>?
    @State private var hasStarted = false
    @FocusState private var otpFocused: Bool
    @FocusState private var passwordFocused: Bool

    enum FlowStep { case connecting, otp, password, browsing, failed }

    /// 这次失败值不值得去改地址。只有"根本没连上"才算 —— 钥匙串读不出密码、
    /// 或者服务器已经应答并回了业务错误码, 改地址都解决不了。密码错 / 验证码错
    /// 走的是 .password / .otp, 压根到不了失败页。
    private enum FailureCause { case address, other }
    @State private var failureCause: FailureCause = .other

    var body: some View {
        Group {
            #if os(macOS)
            // macOS 浏览步骤换成设计稿的树形浏览器 (自带标题区 + 返回/完成
            // 底栏), 不再套 NavigationStack —— 否则会和它的窗头叠两层。
            if step == .browsing {
                synologyMacBrowser
            } else {
                authFlow
            }
            #else
            authFlow
            #endif
        }
        .interactiveDismissDisabled(step == .connecting)
        .onAppear {
            guard !hasStarted else { return }
            hasStarted = true
            if requestsPassword, initialPassword == nil {
                rememberDevice = source.rememberDevice
                step = .password
            } else {
                startConnection(overridePassword: initialPassword)
            }
        }
        .onDisappear {
            connectionTask?.cancel()
            connectionTask = nil
        }
        .transportTrustAlerts()
    }

    /// 连接 / 二步验证 / 选目录(iOS) 的主体验证流程。
    @ViewBuilder
    private var authFlow: some View {
        #if os(macOS)
        macAuthFlow
        #else
        NavigationStack {
            Group {
                switch step {
                case .connecting: connectingView
                case .otp: otpView
                case .password: passwordView
                case .browsing:
                    RealDirectoryBrowserView(
                        synologyAPI: synologyAPI,
                        initialItems: rootItems,
                        selectedDirectories: $selectedDirectories
                    )
                case .failed: failedView
                }
            }
            .navigationTitle(stepTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("cancel") { dismiss() }
                }
                if step == .browsing {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("done") { dismiss() }.fontWeight(.semibold)
                    }
                }
            }
        }
        #endif
    }

    #if os(macOS)
    private var macAuthFlow: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(stepTitle)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(PMColor.text)
                    Text(macConnectionIdentity)
                        .font(.system(size: 11.5))
                        .foregroundStyle(PMColor.textMuted)
                        .lineLimit(1)
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 24)
                        .background(PMColor.glassBtn, in: .circle)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel(Text("cancel"))
            }
            .padding(.horizontal, 24)
            .frame(height: 68)

            Rectangle().fill(PMColor.divider).frame(height: 0.5)

            Group {
                switch step {
                case .connecting:
                    connectingView
                case .otp:
                    macOTPView
                case .password:
                    passwordView
                case .browsing:
                    EmptyView()
                case .failed:
                    failedView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if step == .otp {
                Rectangle().fill(PMColor.divider).frame(height: 0.5)

                HStack(spacing: 10) {
                    Spacer()
                    Button("cancel") { dismiss() }
                    Button("verify") { verifyOTP() }
                        .buttonStyle(.borderedProminent)
                        .tint(PMColor.brand)
                        .keyboardShortcut(.defaultAction)
                        .disabled(otpCode.count != 6)
                }
                .controlSize(.regular)
                .padding(.horizontal, 24)
                .frame(height: 58)
            }
        }
        .background(PMColor.bg)
    }

    private var macConnectionIdentity: String {
        let host = activeSynologySource?.host ?? source.host ?? ""
        return host.isEmpty ? source.name : "\(source.name) · \(host)"
    }
    #endif

    #if os(macOS)
    /// Synology 的树形浏览器 —— 复用通用 `MacDirTreeBrowser`, 把 Synology 的
    /// FileItem 映射成 RemoteFileItem; 根目录用已拿到的共享文件夹列表。
    private var synologyMacBrowser: some View {
        MacDirTreeBrowser(
            title: String(
                format: String(localized: "browse_source_format"),
                source.type.displayName,
                source.name
            ),
            subtitle: synologyConnectionString,
            rootTitle: source.name,
            selectedDirectories: $selectedDirectories,
            load: { path in
                if path == "/" {
                    return rootItems.map(Self.mapSynologyItem)
                }
                guard let api = synologyAPI else { return [] }
                let items = try await api.listDirectory(path: path)
                return items.map(Self.mapSynologyItem)
            }
        )
    }

    private var synologyConnectionString: String {
        let host = source.host ?? ""
        return host.isEmpty ? source.type.displayName.lowercased() : "synology://\(host)"
    }

    private static func mapSynologyItem(_ item: SynologyAPI.FileItem) -> RemoteFileItem {
        RemoteFileItem(
            name: item.name,
            path: item.path,
            isDirectory: item.isDirectory,
            size: item.size,
            modifiedDate: nil
        )
    }
    #endif

    /// 只有**真的新拿到一次证书授权**才值得原地重连。
    ///
    /// `SSLTrustStore.requestTrust` 对已经信任过的域名直接返回 true 且不弹框
    /// (`SSLTrustStore.swift` 里那句 "Already trusted — no need to ask")。三处
    /// 调用点拿到 true 就用**同一条 candidate、同一份 `attemptedKinds`** 重连,
    /// 于是域名早就信任过、却仍然持续回 TLS 失败时,连接页会永远停在转圈:
    /// 每轮等一次登录超时,再原封不动来一遍,没有次数上限也没有退避。
    ///
    /// 外网撞上别人网段里占着同一个私网地址的设备就是这种情形 —— 它接了 TCP
    /// 却不讲 DSM 的 TLS。这时缺的不是信任,该老老实实去换路由、进失败页。
    private func promptSSLTrust(domain: String) async -> Bool {
        guard SSLTrustStore.shared.isTrusted(domain: domain) == false else {
            plog(
                "🔐 Connection flow: TLS failed on an already-trusted domain; not retrying "
                    + "source=\(source.id.prefix(8))… domain=\(domain)"
            )
            return false
        }
        return await SSLTrustStore.shared.requestTrust(domain: domain)
    }

    private func promptInsecureHTTPTrust(host: String) async -> Bool {
        await SSLTrustStore.shared.requestInsecureHTTPTrust(domain: host)
    }

    private var stepTitle: String {
        switch step {
        case .connecting: return String(localized: "connecting_title")
        case .otp: return String(localized: "two_factor_auth")
        case .password: return String(localized: "password_required_title")
        case .browsing: return String(localized: "select_directories")
        case .failed: return String(localized: "connection_failed")
        }
    }

    // MARK: - Connecting

    private var connectingView: some View {
        VStack(spacing: 24) {
            Spacer()
            ProgressView().scaleEffect(1.5)
            VStack(spacing: 6) {
                Text("connecting_to").font(.headline)
                Text(activeSynologySource?.host ?? source.host ?? "")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    // MARK: - OTP View (fixed: keyboard-aware layout)

    private var otpView: some View {
        ScrollView {
            VStack(spacing: 24) {
                // 手机横屏这两段留白白吃 100pt，正好是验证码格子该在的位置。
                Spacer().frame(height: heightClass.value(40, compact: 0))

                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.orange.gradient)

                VStack(spacing: 6) {
                    Text("enter_otp").font(.title3).fontWeight(.bold)
                    Text("otp_hint")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).padding(.horizontal, 40)
                }

                // OTP digit boxes
                HStack(spacing: 10) {
                    ForEach(0..<6, id: \.self) { i in
                        OTPDigitBox(
                            digit: i < otpCode.count
                                ? String(otpCode[otpCode.index(otpCode.startIndex, offsetBy: i)]) : "",
                            isCurrent: i == otpCode.count && otpFocused
                        )
                    }
                }
                .padding(.horizontal, 30)
                .onTapGesture { otpFocused = true }

                // Hidden input
                TextField("", text: $otpCode)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .focused($otpFocused)
                    .frame(height: 1).opacity(0.01)
                    .onChange(of: otpCode) { _, val in
                        otpCode = String(val.prefix(6).filter(\.isNumber))
                        if otpCode.count == 6 { verifyOTP() }
                    }

                // Error message
                if !errorMessage.isEmpty {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.subheadline).foregroundStyle(.red)
                        .padding(.horizontal, 30)
                }

                // Remember device toggle
                Toggle(isOn: $rememberDevice) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("remember_device_otp")
                            .font(.subheadline)
                        Text("remember_device_desc")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)

                Spacer().frame(height: heightClass.value(60, compact: 0))
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .floatingInputPanelClearance()
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { otpFocused = true }
        }
    }

    #if os(macOS)
    private var macOTPView: some View {
        VStack {
            Spacer(minLength: 28)

            VStack(spacing: 0) {
                VStack(spacing: 24) {
                    VStack(spacing: 14) {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 27, weight: .semibold))
                            .foregroundStyle(PMColor.brand)
                            .frame(width: 58, height: 58)
                            .background(PMColor.brand.opacity(0.13), in: .rect(cornerRadius: 16))
                            .overlay {
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .strokeBorder(PMColor.brand.opacity(0.28), lineWidth: 0.5)
                            }

                        VStack(spacing: 6) {
                            Text("enter_otp")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(PMColor.text)
                            Text("otp_hint")
                                .font(.system(size: 13))
                                .foregroundStyle(PMColor.textMuted)
                                .multilineTextAlignment(.center)
                        }
                    }

                    ZStack {
                        HStack(spacing: 10) {
                            ForEach(0..<6, id: \.self) { index in
                                OTPDigitBox(
                                    digit: index < otpCode.count
                                        ? String(otpCode[otpCode.index(otpCode.startIndex, offsetBy: index)])
                                        : "",
                                    isCurrent: index == otpCode.count && otpFocused
                                )
                            }
                        }

                        TextField("", text: $otpCode)
                            .textFieldStyle(.plain)
                            .focused($otpFocused)
                            .frame(width: 1, height: 1)
                            .opacity(0.001)
                            .onSubmit {
                                if otpCode.count == 6 { verifyOTP() }
                            }
                            .onChange(of: otpCode) { _, value in
                                let normalized = String(value.filter(\.isNumber).prefix(6))
                                if normalized != value {
                                    otpCode = normalized
                                }
                                if !normalized.isEmpty {
                                    errorMessage = ""
                                }
                            }
                            .accessibilityLabel(Text("enter_otp"))
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { otpFocused = true }

                    if !errorMessage.isEmpty {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12.5))
                            .foregroundStyle(PMColor.bad)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(PMColor.bad.opacity(0.10), in: .rect(cornerRadius: 8))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(PMColor.bad.opacity(0.22), lineWidth: 0.5)
                            }
                    }
                }
                .padding(.horizontal, 32)
                .padding(.top, 30)
                .padding(.bottom, 26)

                Rectangle().fill(PMColor.divider).frame(height: 0.5)

                Toggle(isOn: $rememberDevice) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("remember_device_otp")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(PMColor.text)
                        Text("remember_device_desc")
                            .font(.system(size: 11.5))
                            .foregroundStyle(PMColor.textMuted)
                    }
                }
                .toggleStyle(.checkbox)
                .padding(.horizontal, 24)
                .frame(height: 66)
            }
            .frame(width: 500)
            .background(PMColor.bgElev, in: .rect(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.16), radius: 18, y: 8)

            Spacer(minLength: 28)
        }
        .padding(.horizontal, 36)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { otpFocused = true }
        }
    }
    #endif

    // MARK: - Password prompt
    //
    // 新密码先贯穿登录/2FA/SSL 重试，确认授权请求成功后才写回 Keychain。
    private var passwordView: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "key.fill")
                    .font(.system(size: 40))
                    // 跟随应用强调色。写死蓝色会让它成为整屏里唯一一处
                    // 与主题无关的颜色，和下方的连接按钮对不上。
                    .foregroundStyle(.tint)
                    .padding(.top, 4)

                // 标题由导航栏承担，这里只回答「在给谁输密码」——
                // 两处都写「需要密码」会让人以为自己看重了。
                Text("\(source.username ?? "") @ \(activeSynologySource?.host ?? source.host ?? "")")
                    .font(.callout)
                    .monospaced()
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)

                VStack(alignment: .leading, spacing: 8) {
                    SecureField(String(localized: "password"), text: $passwordInput)
                        .textFieldStyle(.plain)
                        .focused($passwordFocused)
                        .onSubmit { submitPassword() }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        // 深色下的 roundedBorder 近乎全黑，输入框和背景糊在一起。
                        // 给它一块看得见的底，出错时再补一圈红描边。
                        .background(
                            .quaternary,
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(
                                    errorMessage.isEmpty ? Color.clear : Color.red.opacity(0.65),
                                    lineWidth: 1
                                )
                        }

                    if !errorMessage.isEmpty {
                        // 错误紧贴输入框，指向出问题的那个控件。
                        Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Button {
                    submitPassword()
                } label: {
                    Text("connect").fontWeight(.semibold).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(passwordInput.isEmpty)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 28)
            // 不限宽的话，这一小组控件在 iPad 与桌面窗口里会被拉得很散。
            .frame(maxWidth: 420)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { passwordFocused = true }
        }
    }

    private func submitPassword() {
        let pwd = passwordInput
        guard !pwd.isEmpty else { return }
        pendingPasswordCandidate = pwd
        plog("🔐 Synology credential replacement validation started source=\(source.id.prefix(8))…")
        errorMessage = ""
        pmWithAnimation(.pageSwitch) { step = .connecting }
        connectionTask?.cancel()
        connectionTask = Task { @MainActor in
            await connectCurrentSource(otpCode: nil, overridePassword: pwd)
        }
    }

    // MARK: - Failed

    private var failedView: some View {
        let content = VStack(spacing: 20) {
            Spacer()
            Image(systemName: "xmark.circle").font(.system(size: 52)).foregroundStyle(.red)
            Text("connection_failed").font(.headline)
            failureDetails
            VStack(spacing: 12) {
                Button {
                    // Credential recovery must not silently retry the old
                    // saved password after a network or certificate failure.
                    let candidate = passwordInput.isEmpty ? initialPassword : passwordInput
                    startConnection(overridePassword: requestsPassword ? candidate : nil)
                } label: {
                    Label("retry", systemImage: "arrow.clockwise").fontWeight(.medium)
                }
                .buttonStyle(.borderedProminent)

                // 地址填错了光重试没用。给一条回编辑表单的路,省得关掉整个流程
                // 再去列表里找这个源。
                SourceConnectionEditAddressButton(
                    report: failureReport,
                    onEditAddress: onEditAddress
                )
            }
            Spacer()
        }

        #if os(macOS)
        return content
        #else
        // 失败详情是多行的完整地址加一句针对性提示,手机横屏下会把重试按钮挤没。
        // 撑到视口高度是为了装得下时首尾 Spacer 照样居中,竖屏观感不变。
        return GeometryReader { proxy in
            ScrollView {
                content
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        #endif
    }

    /// 失败页以前只有一句"连接失败"加原始错误 —— 连试的是哪台机器、哪个端口都
    /// 不说。这里补上这次真正用过的完整地址,再按地址本身的形态给一句针对性提示。
    private var failureDetails: some View {
        SourceConnectionFailureDetails(report: failureReport, errorText: errorMessage)
            .padding(.horizontal, 40)
    }

    /// 这次实际连接的那个端点,已经是候选选择之后的结果。不含任何凭据。
    private var attemptedConnectionSource: MusicSource { activeSynologySource ?? source }

    private var attemptedUsesVendorRemote: Bool {
        activeSynologyCandidateKind == .vendorRemote
            || attemptedConnectionSource.effectiveSynologyConnectionMode == .quickConnect
    }

    /// 候选已经由这个流程自己选好了,所以直接把结果交给共用的取值逻辑,
    /// 不必再去问路由记忆。
    private var failureReport: SourceConnectionFailureReport {
        SourceConnectionFailureReport.make(
            forAttempted: attemptedConnectionSource,
            usesVendorRemoteAccess: attemptedUsesVendorRemote,
            suggestsAddressEdit: failureCause == .address
        )
    }

    // MARK: - Logic

    private func startConnection(overridePassword: String? = nil) {
        // 离开转圈态的每一步都带动画, 进来时也得带 —— 否则从失败页点重试是硬跳。
        pmWithAnimation(.pageSwitch) { step = .connecting }
        errorMessage = ""
        otpCode = ""
        passwordInput = overridePassword ?? ""
        pendingPasswordCandidate = overridePassword
        activeSynologySource = nil
        activeSynologyCandidateKind = nil
        rememberDevice = source.rememberDevice
        connectionTask?.cancel()
        connectionTask = Task { @MainActor in
            await connectCurrentSource(otpCode: nil, overridePassword: overridePassword)
        }
    }

    /// 验证码、改密码与换路由之后的重试都回到这个源自己的登录流程。
    private func connectCurrentSource(
        otpCode: String?,
        overridePassword: String? = nil,
        candidate: SourceConnectionCandidate? = nil,
        attemptedKinds: Set<SourceConnectionCandidateKind> = []
    ) async {
        if source.type == .synologyAudioStation {
            await connectAudioStation(
                otpCode: otpCode,
                overridePassword: overridePassword,
                candidate: candidate,
                attemptedKinds: attemptedKinds
            )
        } else {
            await connectSynology(
                otpCode: otpCode,
                overridePassword: overridePassword,
                candidate: candidate,
                attemptedKinds: attemptedKinds
            )
        }
    }

    private func connectSynology(
        otpCode: String?,
        overridePassword: String? = nil,
        candidate explicitCandidate: SourceConnectionCandidate? = nil,
        attemptedKinds: Set<SourceConnectionCandidateKind> = []
    ) async {
        guard !Task.isCancelled else { return }
        let candidate: SourceConnectionCandidate?
        if let explicitCandidate {
            candidate = explicitCandidate
        } else if source.connectionConfiguration != nil {
            let ordered = await SourceConnectionRuntime.shared.orderedCandidates(for: source)
            if (otpCode != nil || overridePassword != nil),
               let activeSynologyCandidateKind,
               let active = ordered.first(where: { $0.kind == activeSynologyCandidateKind }) {
                candidate = active
            } else {
                candidate = ordered.first(where: { attemptedKinds.contains($0.kind) == false })
            }
        } else {
            candidate = nil
        }

        if source.connectionConfiguration != nil, candidate == nil {
            pendingPasswordCandidate = nil
            errorMessage = String(localized: "source_connection_no_route")
            failureCause = .address
            pmWithAnimation(.pageSwitch) { step = .failed }
            return
        }

        let connectionSource = candidate.map(source.applyingConnectionCandidate) ?? source
        activeSynologySource = connectionSource
        activeSynologyCandidateKind = candidate?.kind
        let api = SynologyAPI(
            host: connectionSource.host ?? "",
            port: connectionSource.port ?? 5001,
            useSsl: connectionSource.useSsl,
            connectionMode: connectionSource.effectiveSynologyConnectionMode,
            alternateTLSValidationHostname: connectionSource.alternateTLSValidationHostname
        )
        synologyAPI = api

        let baseURL: URL
        do {
            baseURL = try await api.resolveBaseURL()
        } catch {
            guard !Task.isCancelled else { return }
            await handleSynologyRouteFailure(
                error,
                candidate: candidate,
                attemptedKinds: attemptedKinds,
                otpCode: otpCode,
                overridePassword: overridePassword
            )
            return
        }
        if
           TrustedHTTPTransport.requiresPlainSocket(for: baseURL),
           let trustTarget = TrustedHTTPTransport.trustTarget(for: baseURL),
           !SSLTrustStore.shared.allowsInsecureHTTP(domain: trustTarget) {
            let approved = await promptInsecureHTTPTrust(host: trustTarget)
            guard !Task.isCancelled else { return }
            guard approved else {
                pendingPasswordCandidate = nil
                errorMessage = String(
                    format: String(localized: "insecure_http_permission_required %@"),
                    trustTarget
                )
                // 用户拒绝了明文连接: 换成 https 的地址就是正当出路。
                failureCause = .address
                pmWithAnimation(.pageSwitch) { step = .failed }
                return
            }
        }

        // overridePassword 不为空时直接用刚输入的明文,绕开 keychain
        // 读写中任何潜在的字节损失;否则才回落到 keychain 里上次保存的值。
        let password: String
        if let overridePassword {
            password = overridePassword
        } else {
            switch KeychainService.passwordLookup(for: source.id) {
            case .found(let savedPassword):
                password = savedPassword
            case .notFound:
                errorMessage = String(localized: "password_required_title")
                pmWithAnimation(.pageSwitch) { step = .password }
                return
            case .temporarilyUnavailable(let status):
                plog("⏳ Synology connection deferred: credential temporarily unavailable status=\(status)")
                errorMessage = String(localized: "credential_temporarily_unavailable")
                failureCause = .other
                pmWithAnimation(.pageSwitch) { step = .failed }
                return
            case .failed(let status):
                plog("⛔ Synology connection stopped: credential read failed status=\(status)")
                errorMessage = String(localized: "credential_read_failed")
                failureCause = .other
                pmWithAnimation(.pageSwitch) { step = .failed }
                return
            }
        }

        // If we have a saved deviceId, try login with it (skip OTP)
        let result = await api.login(
            account: source.username ?? "",
            password: password,
            otpCode: otpCode,
            deviceName: rememberDevice ? AppConstants.trustedDeviceName : nil,
            deviceId: rememberDevice ? source.deviceId : nil
        )
        guard !Task.isCancelled else { return }

        if result.success {
            do {
                let shares = try await api.listSharedFolders()
                guard !Task.isCancelled else { return }

                if let validatedPassword = NetworkCredentialPolicy.validatedReplacement(
                    candidate: overridePassword,
                    loginSucceeded: true,
                    browserReady: true
                ) {
                    guard onPasswordWillChange?() != false else {
                        pendingPasswordCandidate = nil
                        errorMessage = String(localized: "synology_password_update_save_failed")
                        pmWithAnimation(.pageSwitch) { step = .password }
                        return
                    }
                    guard KeychainService.setPassword(validatedPassword, for: source.id) else {
                        onPasswordSaveUncertain?()
                        plog("⚠️ Synology credential replacement could not be conclusively persisted; prepared scope remains blocked source=\(source.id.prefix(8))…")
                        pendingPasswordCandidate = nil
                        errorMessage = String(localized: "synology_password_update_save_failed")
                        pmWithAnimation(.pageSwitch) { step = .password }
                        return
                    }

                    // SourceManager connectors may still hold the rejected
                    // credential. Refresh only after the validated replacement
                    // has been persisted successfully.
                    guard await onPasswordSaved?() != false else {
                        pendingPasswordCandidate = nil
                        errorMessage = String(localized: "synology_password_update_save_failed")
                        pmWithAnimation(.pageSwitch) { step = .password }
                        return
                    }
                    plog("✅ Synology credential replacement persisted after login and browse validation source=\(source.id.prefix(8))…")
                    pendingPasswordCandidate = nil
                    passwordInput = ""
                }

                onDeviceTrustSaved?(rememberDevice, result.deviceId)
                rootItems = shares
                onSessionReady?(api)
                if let candidate {
                    await SourceConnectionRuntime.shared.record(candidate.kind, for: source.id)
                }
                SourceAuthAlert.clear(sourceID: source.id)
                if let onAuthenticated {
                    onAuthenticated()
                    dismiss()
                    return
                }
                pmWithAnimation(.pageSwitch) { step = .browsing }
            } catch {
                guard !Task.isCancelled else { return }
                if let domain = SSLTrustStore.sslErrorDomain(from: error) {
                    let trusted = await promptSSLTrust(domain: domain)
                    guard !Task.isCancelled else { return }
                    if trusted {
                        await connectSynology(
                            otpCode: otpCode,
                            overridePassword: overridePassword,
                            candidate: candidate,
                            attemptedKinds: attemptedKinds
                        )
                        return
                    }
                }
                await handleSynologyRouteFailure(
                    error,
                    candidate: candidate,
                    attemptedKinds: attemptedKinds,
                    otpCode: otpCode,
                    overridePassword: overridePassword
                )
            }
        } else if result.needs2FA {
            if let candidate {
                await SourceConnectionRuntime.shared.record(candidate.kind, for: source.id)
            }
            // If OTP was provided and failed, show error but stay on OTP screen
            if let msg = result.errorMessage, otpCode != nil {
                errorMessage = msg
                self.otpCode = "" // clear for retry
            }
            pmWithAnimation(.pageSwitch) { step = .otp }
        } else {
            // Check if login error is SSL-related and prompt trust
            if let error = result.underlyingError,
               let domain = SSLTrustStore.sslErrorDomain(from: error) {
                let trusted = await promptSSLTrust(domain: domain)
                guard !Task.isCancelled else { return }
                if trusted {
                    await connectSynology(
                        otpCode: otpCode,
                        overridePassword: overridePassword,
                        candidate: candidate,
                        attemptedKinds: attemptedKinds
                    )
                    return
                }
            }

            // 只有 400（账号不存在或密码错误）能通过重新输入解决。DSM 的
            // 408/409/410 要求先在 DSM 修改密码，锁定/网络问题也应保留真实失败态。
            if result.requiresCredentialPrompt {
                await MainActor.run {
                    pendingPasswordCandidate = nil
                    errorMessage = result.errorMessage ?? String(localized: "password_wrong_hint")
                    pmWithAnimation(.pageSwitch) { step = .password }
                }
                return
            }

            if result.errorCode == nil {
                await handleSynologyRouteFailure(
                    result.underlyingError ?? SourceError.connectionFailed(
                        result.errorMessage ?? String(localized: "connection_failed")
                    ),
                    candidate: candidate,
                    attemptedKinds: attemptedKinds,
                    otpCode: otpCode,
                    overridePassword: overridePassword
                )
                return
            }

            pendingPasswordCandidate = nil
            errorMessage = result.errorMessage ?? String(localized: "unknown_error")
            // DSM 已经应答并给了错误码 —— 地址是对的, 问题在账号那边。
            failureCause = .other
            pmWithAnimation(.pageSwitch) { step = .failed }
        }
    }

    private func handleSynologyRouteFailure(
        _ error: Error,
        candidate: SourceConnectionCandidate?,
        attemptedKinds: Set<SourceConnectionCandidateKind>,
        otpCode: String?,
        overridePassword: String?
    ) async {
        guard !Task.isCancelled else { return }
        guard let candidate, source.connectionConfiguration != nil else {
            pendingPasswordCandidate = nil
            errorMessage = error.localizedDescription
            failureCause = .address
            pmWithAnimation(.pageSwitch) { step = .failed }
            return
        }

        var attempted = attemptedKinds
        attempted.insert(candidate.kind)
        await SourceConnectionRuntime.shared.invalidate(sourceID: source.id)
        let ordered = source.connectionCandidates
        if let next = ordered.first(where: { attempted.contains($0.kind) == false }) {
            await connectCurrentSource(
                otpCode: otpCode,
                overridePassword: overridePassword,
                candidate: next,
                attemptedKinds: attempted
            )
            return
        }

        pendingPasswordCandidate = nil
        errorMessage = error.localizedDescription
        // 所有候选路由都试过了还是连不上, 地址本身最可疑。
        failureCause = .address
        pmWithAnimation(.pageSwitch) { step = .failed }
    }

    private func verifyOTP() {
        errorMessage = ""
        pmWithAnimation(.pageSwitch) { step = .connecting }
        let candidate = pendingPasswordCandidate
        connectionTask?.cancel()
        connectionTask = Task { @MainActor in
            await connectCurrentSource(otpCode: otpCode, overridePassword: candidate)
        }
    }

    // MARK: - Audio Station

    /// Audio Station 版的登录:两步验证、受信设备、改密码、证书与明文信任、换路由
    /// 都和群晖直连共用这一套界面。登录后确认账号有 Audio Station 权限,不进
    /// 目录浏览 —— 交给宿主去扫描整库。
    private func connectAudioStation(
        otpCode: String?,
        overridePassword: String? = nil,
        candidate explicitCandidate: SourceConnectionCandidate? = nil,
        attemptedKinds: Set<SourceConnectionCandidateKind> = []
    ) async {
        guard !Task.isCancelled else { return }
        let candidate: SourceConnectionCandidate?
        if let explicitCandidate {
            candidate = explicitCandidate
        } else if source.connectionConfiguration != nil {
            let ordered = await SourceConnectionRuntime.shared.orderedCandidates(for: source)
            if (otpCode != nil || overridePassword != nil),
               let activeSynologyCandidateKind,
               let active = ordered.first(where: { $0.kind == activeSynologyCandidateKind }) {
                candidate = active
            } else {
                candidate = ordered.first(where: { attemptedKinds.contains($0.kind) == false })
            }
        } else {
            candidate = nil
        }

        if source.connectionConfiguration != nil, candidate == nil {
            pendingPasswordCandidate = nil
            errorMessage = String(localized: "source_connection_no_route")
            failureCause = .address
            pmWithAnimation(.pageSwitch) { step = .failed }
            return
        }

        let connectionSource = candidate.map(source.applyingConnectionCandidate) ?? source
        activeSynologySource = connectionSource
        activeSynologyCandidateKind = candidate?.kind

        let password: String
        if let overridePassword {
            password = overridePassword
        } else {
            switch KeychainService.passwordLookup(for: source.id) {
            case .found(let savedPassword):
                password = savedPassword
            case .notFound:
                errorMessage = String(localized: "password_required_title")
                pmWithAnimation(.pageSwitch) { step = .password }
                return
            case .temporarilyUnavailable(let status):
                plog("⏳ Audio Station connection deferred: credential temporarily unavailable status=\(status)")
                errorMessage = String(localized: "credential_temporarily_unavailable")
                failureCause = .other
                pmWithAnimation(.pageSwitch) { step = .failed }
                return
            case .failed(let status):
                plog("⛔ Audio Station connection stopped: credential read failed status=\(status)")
                errorMessage = String(localized: "credential_read_failed")
                failureCause = .other
                pmWithAnimation(.pageSwitch) { step = .failed }
                return
            }
        }

        // 连接器自己的传输:证书交给 SmartSSLDelegate 当场询问,公网明文交给
        // TrustedHTTPTransport 询问,拒绝时以错误回来。
        let connector = SynologyAudioStationSource(
            source: connectionSource,
            password: password,
            deviceName: rememberDevice ? AppConstants.trustedDeviceName : nil
        )
        let deviceID: String?
        do {
            deviceID = try await connector.signIn(otp: otpCode)
        } catch {
            await connector.disconnect()
            guard !Task.isCancelled else { return }
            await handleAudioStationFailure(
                error,
                candidate: candidate,
                attemptedKinds: attemptedKinds,
                otpCode: otpCode,
                overridePassword: overridePassword
            )
            return
        }
        await connector.disconnect()
        guard !Task.isCancelled else { return }

        if let validatedPassword = NetworkCredentialPolicy.validatedReplacement(
            candidate: overridePassword,
            loginSucceeded: true,
            browserReady: true
        ) {
            guard onPasswordWillChange?() != false else {
                pendingPasswordCandidate = nil
                errorMessage = String(localized: "synology_password_update_save_failed")
                pmWithAnimation(.pageSwitch) { step = .password }
                return
            }
            guard KeychainService.setPassword(validatedPassword, for: source.id) else {
                onPasswordSaveUncertain?()
                plog("⚠️ Audio Station credential replacement could not be conclusively persisted; prepared scope remains blocked source=\(source.id.prefix(8))…")
                pendingPasswordCandidate = nil
                errorMessage = String(localized: "synology_password_update_save_failed")
                pmWithAnimation(.pageSwitch) { step = .password }
                return
            }
            guard await onPasswordSaved?() != false else {
                pendingPasswordCandidate = nil
                errorMessage = String(localized: "synology_password_update_save_failed")
                pmWithAnimation(.pageSwitch) { step = .password }
                return
            }
            plog("✅ Audio Station credential replacement persisted after sign-in validation source=\(source.id.prefix(8))…")
            pendingPasswordCandidate = nil
            passwordInput = ""
        }

        onDeviceTrustSaved?(rememberDevice, deviceID)
        if let candidate {
            await SourceConnectionRuntime.shared.record(candidate.kind, for: source.id)
        }
        SourceAuthAlert.clear(sourceID: source.id)
        if let onAuthenticated {
            onAuthenticated()
        } else {
            onAudioStationReady?()
        }
        dismiss()
    }

    private func handleAudioStationFailure(
        _ error: Error,
        candidate: SourceConnectionCandidate?,
        attemptedKinds: Set<SourceConnectionCandidateKind>,
        otpCode: String?,
        overridePassword: String?
    ) async {
        if let domain = SSLTrustStore.sslErrorDomain(from: error) {
            let trusted = await promptSSLTrust(domain: domain)
            guard !Task.isCancelled else { return }
            if trusted {
                await connectAudioStation(
                    otpCode: otpCode,
                    overridePassword: overridePassword,
                    candidate: candidate,
                    attemptedKinds: attemptedKinds
                )
                return
            }
        }

        if let failure = error as? SynologyAudioStationError {
            switch failure {
            case .twoFactorRequired, .invalidOneTimePassword:
                if let candidate {
                    await SourceConnectionRuntime.shared.record(candidate.kind, for: source.id)
                }
                // 第一次撞上两步验证不算出错;输过验证码仍被拒才提示。
                if otpCode != nil {
                    errorMessage = failure.localizedDescription
                    self.otpCode = ""
                } else {
                    // 扫描与播放都由后台连接器重新登录,拿不到受信设备令牌就会
                    // 每次卡在验证码上。默认勾上「记住此设备」,用户仍可取消。
                    rememberDevice = true
                }
                pmWithAnimation(.pageSwitch) { step = .otp }
                return
            case .invalidCredentials, .missingCredential:
                // 只有账号密码能靠重新输入解决。
                pendingPasswordCandidate = nil
                errorMessage = failure.localizedDescription
                pmWithAnimation(.pageSwitch) { step = .password }
                return
            case .invalidURL, .invalidResponse, .badServerResponse:
                // 对面不是一台能用的 DSM(端口、前缀或反代不对),换下一条路由再说。
                break
            default:
                // DSM 已经应答并给了原因(没有权限、账号停用、没装 Audio Station…),
                // 地址是对的,换路由也没用。
                pendingPasswordCandidate = nil
                errorMessage = failure.localizedDescription
                failureCause = .other
                pmWithAnimation(.pageSwitch) { step = .failed }
                return
            }
        }

        if error is TrustedHTTPTransportError {
            // 用户拒绝了明文连接: 换成 https 的地址就是正当出路。
            pendingPasswordCandidate = nil
            errorMessage = error.localizedDescription
            failureCause = .address
            pmWithAnimation(.pageSwitch) { step = .failed }
            return
        }

        await handleSynologyRouteFailure(
            error,
            candidate: candidate,
            attemptedKinds: attemptedKinds,
            otpCode: otpCode,
            overridePassword: overridePassword
        )
    }
}

// MARK: - Credential Recovery

struct SynologyCredentialRecoveryView: View {
    let source: MusicSource
    var initialPassword: String?
    var onAuthenticated: (MusicSource) -> Void

    @Environment(SourceManager.self) private var sourceManager
    @State private var validatedDeviceTrust: (remember: Bool, deviceID: String?)?

    var body: some View {
        ConnectionFlowView(
            source: source,
            selectedDirectories: .constant(source.scannedDirectories),
            onDeviceTrustSaved: { remember, deviceID in
                validatedDeviceTrust = (remember, deviceID)
            },
            onPasswordWillChange: {
                do {
                    try sourceManager.credentialsWillChange(for: source.id)
                    return true
                } catch {
                    return false
                }
            },
            onPasswordSaveUncertain: {
                sourceManager.credentialsChangeOutcomeUncertain(for: source.id)
            },
            onPasswordSaved: {
                do {
                    try sourceManager.credentialsDidChange(for: source.id)
                    return true
                } catch {
                    sourceManager.credentialsChangeOutcomeUncertain(for: source.id)
                    return false
                }
            },
            requestsPassword: true,
            initialPassword: initialPassword,
            onAuthenticated: {
                var updated = source
                if let trust = validatedDeviceTrust {
                    updated.rememberDevice = trust.remember
                    updated.deviceId = trust.remember ? (trust.deviceID ?? source.deviceId) : nil
                }
                onAuthenticated(updated)
            }
        )
        #if os(macOS)
        .frame(minWidth: 440, idealWidth: 520, minHeight: 420)
        #endif
    }
}

// MARK: - OTP Digit Box

struct OTPDigitBox: View {
    let digit: String
    let isCurrent: Bool

    var body: some View {
        #if os(macOS)
        Text(digit)
            .font(.system(size: 23, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(PMColor.text)
            .frame(width: 50, height: 56)
            .background(PMColor.bgDeep.opacity(0.72), in: .rect(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        isCurrent ? PMColor.brand : PMColor.cardBorder,
                        lineWidth: isCurrent ? 1.5 : 0.5
                    )
            }
            .shadow(color: isCurrent ? PMColor.brand.opacity(0.20) : .clear, radius: 5)
            .pmAnimation(.hover, value: isCurrent)
        #else
        Text(digit)
            .font(.title2).fontWeight(.bold)
            .frame(maxWidth: .infinity).frame(height: 56)
            .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .stroke(isCurrent ? Color.accentColor : .clear, lineWidth: 2))
        #endif
    }
}

// MARK: - Directory Browser

struct RealDirectoryBrowserView: View {
    let synologyAPI: SynologyAPI?
    let initialItems: [SynologyAPI.FileItem]
    @Binding var selectedDirectories: [String]

    @State private var currentPath = "/"
    @State private var pathStack: [String] = ["/"]
    @State private var items: [SynologyAPI.FileItem] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            breadcrumbBar
            Divider()
            if isLoading {
                Spacer()
                ProgressView()
                Text("loading_directories").font(.caption).foregroundStyle(.secondary).padding(.top, 8)
                Spacer()
            } else if let err = errorMessage {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle").font(.title).foregroundStyle(.orange)
                    Text(err).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("retry") { loadDirectory() }.buttonStyle(.bordered)
                }
                .padding(.horizontal, 40)
                Spacer()
            } else {
                directoryList
            }
            // macOS 把"已选择 N 个 / 清除全部"放进上方 toolbar(见
            // ConnectionFlowView 的 toolbar item),不再叠一条全宽底栏 ——
            // 那个浮动条是 iOS 的视觉模式,macOS 上挤掉一整行目录看起来也不清爽。
            #if os(iOS)
            bottomBar
            #endif
        }
        #if os(macOS)
        .toolbar {
            ToolbarItem(placement: .principal) {
                if !selectedDirectories.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.tint)
                        Text("\(selectedDirectories.count) \(String(localized: "directories_selected"))")
                            .font(.subheadline).fontWeight(.medium)
                        Button {
                            pmWithAnimation(.list) { selectedDirectories.removeAll() }
                        } label: {
                            Label("clear_all", systemImage: "xmark.circle")
                                .labelStyle(.iconOnly)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help(Text("clear_all"))
                    }
                }
            }
        }
        #endif
        .onAppear {
            if currentPath == "/" { items = initialItems }
        }
    }

    private var breadcrumbBar: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(pathStack.enumerated()), id: \.offset) { index, segment in
                        if index > 0 {
                            Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                        }
                        Button { navigateTo(index: index) } label: {
                            Text(segment == "/" ? String(localized: "shared_folders") : (segment as NSString).lastPathComponent)
                                .font(.caption)
                                .fontWeight(index == pathStack.count - 1 ? .semibold : .regular)
                                .foregroundStyle(index == pathStack.count - 1 ? Color.primary : Color.accentColor)
                                .padding(.horizontal, 6).padding(.vertical, 4)
                        }
                        .id(index)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 6)
            }
            .onChange(of: pathStack.count) { _, _ in
                pmWithAnimation(.list) { proxy.scrollTo(pathStack.count - 1, anchor: .trailing) }
            }
        }
        .background(.bar)
    }

    private var directoryList: some View {
        let dirs = items.filter(\.isDirectory)
        return List {
            if dirs.isEmpty {
                ContentUnavailableView("no_subdirectories", systemImage: "folder",
                                       description: Text("no_subdirectories_desc"))
            } else {
                if currentPath != "/" {
                    currentDirRow()
                }
                ForEach(Array(dirs.enumerated()), id: \.offset) { _, item in
                    directoryRow(item: item)
                }
            }
        }
        #if os(macOS)
        .listStyle(.inset)
        #else
        .listStyle(.plain)
        #endif
    }

    private func directoryRow(item: SynologyAPI.FileItem) -> some View {
        DirectoryCheckRow(
            name: item.name, subtitle: nil, path: item.path,
            icon: "folder.fill", iconColor: .blue,
            isNavigable: true,
            selectedDirectories: $selectedDirectories,
            onNavigate: { enterDirectory(item) }
        )
    }

    private func currentDirRow() -> some View {
        DirectoryCheckRow(
            name: String(localized: "current_directory"),
            subtitle: currentPath, path: currentPath,
            icon: "folder.fill", iconColor: .orange,
            isNavigable: false,
            selectedDirectories: $selectedDirectories
        )
    }

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                if selectedDirectories.isEmpty {
                    Label("no_dirs_selected", systemImage: "folder.badge.questionmark")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else {
                    Label("\(selectedDirectories.count) \(String(localized: "directories_selected"))",
                          systemImage: "checkmark.circle.fill")
                        .font(.subheadline).fontWeight(.medium)
                        .foregroundStyle(Color.accentColor)
                    Spacer()
                    Button(role: .destructive) {
                        pmWithAnimation(.list) { selectedDirectories.removeAll() }
                    } label: {
                        Label("clear_all", systemImage: "xmark.circle")
                            .font(.caption).fontWeight(.medium)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .background(.bar)
    }

    private func enterDirectory(_ item: SynologyAPI.FileItem) {
        currentPath = item.path; pathStack.append(item.path); loadDirectory()
    }

    private func navigateTo(index: Int) {
        guard index < pathStack.count else { return }
        currentPath = pathStack[index]; pathStack = Array(pathStack.prefix(index + 1))
        if index == 0 { items = initialItems; errorMessage = nil } else { loadDirectory() }
    }

    private func toggleSelection(_ path: String) {
        withAnimation(.easeInOut(duration: 0.2)) {
            if selectedDirectories.contains(path) { selectedDirectories.removeAll { $0 == path } }
            else { selectedDirectories.append(path) }
        }
    }

    private func loadDirectory() {
        guard let api = synologyAPI else { return }
        isLoading = true; errorMessage = nil
        Task {
            do {
                items = try await api.listDirectory(path: currentPath)
                isLoading = false
            } catch {
                errorMessage = error.localizedDescription; isLoading = false
            }
        }
    }
}

// MARK: - Directory Check Row (separate View for proper @Binding reactivity)

struct DirectoryCheckRow: View {
    let name: String
    let subtitle: String?
    let path: String
    let icon: String
    let iconColor: Color
    let isNavigable: Bool
    @Binding var selectedDirectories: [String]
    var onNavigate: (() -> Void)?

    private var isSelected: Bool { selectedDirectories.contains(path) }

    private var selectionBinding: Binding<Bool> {
        Binding(
            get: { selectedDirectories.contains(path) },
            set: { newValue in
                if newValue != selectedDirectories.contains(path) {
                    selectedDirectories = SourceDirectorySelectionPolicy.toggledSelection(
                        selectedDirectories,
                        path: path
                    )
                }
            }
        )
    }

    var body: some View {
        #if os(macOS)
        macOSBody
        #else
        iOSBody
        #endif
    }

    #if os(macOS)
    @State private var isHovering = false

    private var macOSBody: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: selectionBinding)
                .toggleStyle(.checkbox)
                .labelsHidden()

            Image(systemName: icon).foregroundStyle(iconColor)

            VStack(alignment: .leading, spacing: 1) {
                Text(name).fontWeight(isNavigable ? .regular : .medium)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }

            Spacer()

            if isNavigable {
                Button { onNavigate?() } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isHovering ? Color.secondary : Color.gray.opacity(0.45))
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.plain)
                .help(String(localized: "open_folder"))
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            // Finder 风格:双击进入目录;非可导航行双击当作选中。
            if isNavigable, let onNavigate {
                onNavigate()
            } else {
                toggle()
            }
        }
        .onTapGesture { toggle() }
        .onHover { isHovering = $0 }
        .listRowBackground(rowBackground)
        .pmAnimation(.hover, value: rowHighlight)
    }

    /// 选中与悬停共用同一块底色, 用一个小的可比较值代表它当前停在哪一档,
    /// 免得把两个 Bool 凑成不可比较的元组。
    private var rowHighlight: Int {
        if isSelected { return 2 }
        return isHovering ? 1 : 0
    }

    @ViewBuilder
    private var rowBackground: some View {
        if isSelected {
            Color.accentColor.opacity(0.12)
        } else if isHovering {
            Color.primary.opacity(0.05)
        } else {
            Color.clear
        }
    }
    #endif

    #if os(iOS)
    private var iOSBody: some View {
        HStack(spacing: 10) {
            Button { toggle() } label: {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.gray.opacity(0.4))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)

            if isNavigable {
                Button { onNavigate?() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: icon).foregroundStyle(iconColor)
                        Text(name).foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.quaternary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: icon).foregroundStyle(iconColor)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(name).fontWeight(.medium)
                        if let subtitle {
                            Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture { toggle() }
            }
        }
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
        .pmAnimation(.hover, value: isSelected)
    }
    #endif

    private func toggle() {
        selectedDirectories = SourceDirectorySelectionPolicy.toggledSelection(
            selectedDirectories,
            path: path
        )
    }
}
