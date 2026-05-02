import SwiftUI
import PrimuseKit

// MARK: - Connection Flow

struct ConnectionFlowView: View {
    let source: MusicSource
    @Binding var selectedDirectories: [String]
    var onDeviceIdSaved: ((String) -> Void)?
    var onSessionReady: ((SynologyAPI) -> Void)?
    @Environment(\.dismiss) private var dismiss

    @State private var step: FlowStep = .connecting
    @State private var otpCode = ""
    @State private var passwordInput = ""
    @State private var errorMessage = ""
    @State private var rememberDevice = true
    @State private var synologyAPI: SynologyAPI?
    @State private var rootItems: [SynologyAPI.FileItem] = []
    @FocusState private var otpFocused: Bool
    @FocusState private var passwordFocused: Bool
    @State private var sslTrustDomain: String?
    @State private var sslTrustContinuation: CheckedContinuation<Bool, Never>?

    enum FlowStep { case connecting, otp, password, browsing, failed }

    var body: some View {
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
        .interactiveDismissDisabled(step == .connecting)
        .onAppear { startConnection() }
        .alert(
            String(localized: "ssl_trust_title"),
            isPresented: Binding(
                get: { sslTrustDomain != nil },
                set: { if !$0 { resolveSSLTrust(approved: false) } }
            )
        ) {
            Button(String(localized: "trust_domain"), role: .destructive) {
                resolveSSLTrust(approved: true)
            }
            Button(String(localized: "dont_trust"), role: .cancel) {
                resolveSSLTrust(approved: false)
            }
        } message: {
            if let domain = sslTrustDomain {
                Text("ssl_trust_message \(domain)")
            }
        }
    }

    private func resolveSSLTrust(approved: Bool) {
        if approved, let domain = sslTrustDomain {
            SSLTrustStore.shared.trust(domain: domain)
        }
        let continuation = sslTrustContinuation
        sslTrustDomain = nil
        sslTrustContinuation = nil
        continuation?.resume(returning: approved)
    }

    private func promptSSLTrust(domain: String) async -> Bool {
        // Already trusted
        if SSLTrustStore.shared.isTrusted(domain: domain) { return true }
        return await withCheckedContinuation { continuation in
            sslTrustDomain = domain
            sslTrustContinuation = continuation
        }
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
                Text(source.host ?? "").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    // MARK: - OTP View (fixed: keyboard-aware layout)

    private var otpView: some View {
        ScrollView {
            VStack(spacing: 24) {
                Spacer().frame(height: 40)

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

                Spacer().frame(height: 60)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { otpFocused = true }
        }
    }

    // MARK: - Password prompt
    //
    // 仅在 DSM 真正返回 code=400(账号或密码错误)时才出现。用户输入的
    // 密码写回本机 Keychain,下次连接自动复用。
    private var passwordView: some View {
        ScrollView {
            VStack(spacing: 20) {
                Spacer().frame(height: 30)

                Image(systemName: "key.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.blue.gradient)

                VStack(spacing: 6) {
                    Text("password_required_title").font(.title3).fontWeight(.semibold)
                    Text("\(source.username ?? "") @ \(source.host ?? "")")
                        .font(.caption).foregroundStyle(.secondary)
                        .monospaced()
                }

                SecureField(String(localized: "password"), text: $passwordInput)
                    .textFieldStyle(.roundedBorder)
                    .focused($passwordFocused)
                    .onSubmit { submitPassword() }
                    .padding(.horizontal, 30)

                if !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(.caption).foregroundStyle(.red)
                        .padding(.horizontal, 30)
                        .multilineTextAlignment(.center)
                }

                Button {
                    submitPassword()
                } label: {
                    Text("connect").fontWeight(.semibold).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(passwordInput.isEmpty)
                .padding(.horizontal, 30)

                Spacer().frame(height: 30)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { passwordFocused = true }
        }
    }

    private func submitPassword() {
        let pwd = passwordInput
        guard !pwd.isEmpty else { return }
        // 顺手写一份到 Keychain (下次免输);但 connectSynology 这一次
        // 直接用 overridePassword,不依赖 keychain 读回去——否则 keychain
        // 写失败时密码就丢了。
        KeychainService.setPassword(pwd, for: source.id)
        errorMessage = ""
        passwordInput = ""
        step = .connecting
        Task { await connectSynology(otpCode: nil, overridePassword: pwd) }
    }

    // MARK: - Failed

    private var failedView: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "xmark.circle").font(.system(size: 52)).foregroundStyle(.red)
            Text("connection_failed").font(.headline)
            Text(errorMessage)
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 40)
            Button { startConnection() } label: {
                Label("retry", systemImage: "arrow.clockwise").fontWeight(.medium)
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
    }

    // MARK: - Logic

    private func startConnection() {
        step = .connecting
        errorMessage = ""
        otpCode = ""
        rememberDevice = source.rememberDevice
        Task {
            switch source.type {
            case .synology: await connectSynology(otpCode: nil)
            default: withAnimation { step = .browsing }
            }
        }
    }

    private func connectSynology(otpCode: String?, overridePassword: String? = nil) async {
        let api = SynologyAPI(
            host: source.host ?? "",
            port: source.port ?? 5001,
            useSsl: source.useSsl
        )
        synologyAPI = api

        // overridePassword 不为空时直接用刚输入的明文,绕开 keychain
        // 读写中任何潜在的字节损失;否则才回落到 keychain 里上次保存的值。
        let password = overridePassword ?? KeychainService.getPassword(for: source.id) ?? ""

        // If we have a saved deviceId, try login with it (skip OTP)
        let result = await api.login(
            account: source.username ?? "",
            password: password,
            otpCode: otpCode,
            deviceName: rememberDevice ? AppConstants.trustedDeviceName : nil,
            deviceId: source.deviceId
        )

        if result.success {
            if let did = result.deviceId {
                onDeviceIdSaved?(did)
            }
            do {
                let shares = try await api.listSharedFolders()
                rootItems = shares
                onSessionReady?(api)
                withAnimation { step = .browsing }
            } catch {
                if let domain = SSLTrustStore.sslErrorDomain(from: error) {
                    let trusted = await promptSSLTrust(domain: domain)
                    if trusted {
                        await connectSynology(otpCode: otpCode)
                        return
                    }
                }
                errorMessage = error.localizedDescription
                withAnimation { step = .failed }
            }
        } else if result.needs2FA {
            // If OTP was provided and failed, show error but stay on OTP screen
            if let msg = result.errorMessage, otpCode != nil {
                errorMessage = msg
                self.otpCode = "" // clear for retry
            }
            withAnimation { step = .otp }
        } else {
            // Check if login error is SSL-related and prompt trust
            if let error = result.underlyingError,
               let domain = SSLTrustStore.sslErrorDomain(from: error) {
                let trusted = await promptSSLTrust(domain: domain)
                if trusted {
                    await connectSynology(otpCode: otpCode)
                    return
                }
            }

            // 凭据错误（DSM 错误码 400)→ 弹密码输入框让用户重输,而不是
            // 直接进 failed 页。SynologyAPI 把错误码翻译成中文消息,这里
            // 用消息内容反查;其他错误(IP 封禁/账号停用/2FA 等）走 failed
            // 页让用户看到具体原因。
            if (result.errorMessage ?? "").contains("用户名或密码错误") {
                await MainActor.run {
                    errorMessage = String(localized: "password_wrong_hint")
                    withAnimation { step = .password }
                }
                return
            }

            errorMessage = result.errorMessage ?? "Unknown error"
            withAnimation { step = .failed }
        }
    }

    private func verifyOTP() {
        errorMessage = ""
        step = .connecting
        Task { await connectSynology(otpCode: otpCode) }
    }
}

// MARK: - OTP Digit Box

struct OTPDigitBox: View {
    let digit: String
    let isCurrent: Bool

    var body: some View {
        Text(digit)
            .font(.title2).fontWeight(.bold)
            .frame(maxWidth: .infinity).frame(height: 56)
            .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .stroke(isCurrent ? Color.accentColor : .clear, lineWidth: 2))
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
                            withAnimation { selectedDirectories.removeAll() }
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
                withAnimation { proxy.scrollTo(pathStack.count - 1, anchor: .trailing) }
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
                        withAnimation { selectedDirectories.removeAll() }
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

    var body: some View {
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
        .animation(.easeInOut(duration: 0.15), value: isSelected)
    }

    private func toggle() {
        if selectedDirectories.contains(path) {
            selectedDirectories.removeAll { $0 == path }
        } else {
            selectedDirectories.append(path)
        }
    }
}
