import SwiftUI
import PrimuseKit
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif

struct SourceTypeSelectionView: View {
    @Environment(\.dismiss) private var dismiss
    var onAdd: (MusicSource) -> Void

    @State private var selectedType: MusicSourceType?
    @State private var discoveryService = NetworkDiscoveryService()
    @State private var selectedDevice: DiscoveredDevice?
    #if os(macOS)
    @State private var pendingType: MusicSourceType?
    #endif
    #if os(iOS)
    @State private var showLocalImporter = false
    @State private var localImportPickerMode: LocalImportPickerMode = .folder
    @State private var localImportTask: Task<Void, Never>?
    @State private var localImportProgress: LocalImportService.CopyProgress?
    @State private var localImportAlert: LocalImportAlert?
    #endif

    var body: some View {
        content
        .sheet(item: $selectedType) { type in
            AddSourceView(sourceType: type) { source in
                onAdd(source)
                dismiss()
            }
        }
        .sheet(item: $selectedDevice) { device in
            AddSourceView(
                sourceType: device.sourceType,
                prefillDevice: device
            ) { source in
                onAdd(source)
                dismiss()
            }
        }
        .onAppear { discoveryService.startDiscovery() }
        .onDisappear { discoveryService.stopDiscovery() }
    }

    @ViewBuilder
    private var content: some View {
        #if os(macOS)
        macSheet
        #else
        NavigationStack {
            iosList
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("cancel") {
                    #if os(iOS)
                    cancelLocalImport()
                    #endif
                    dismiss()
                }
            }
        }
        #endif
    }

    // MARK: - macOS layout

    #if os(macOS)
    private var macSheet: some View {
        VStack(spacing: 0) {
            macSheetChrome

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    macDiscoverySection

                    macProtocolSection(
                        title: "Apple",
                        types: [.appleMusicLibrary]
                    )

                    ForEach(MusicSourceType.groupedByCategory, id: \.0) { category, types in
                        let filtered = types.filter { $0 != .appleMusicLibrary && $0 != .appleMusic }
                        if !filtered.isEmpty {
                            macProtocolSection(
                                title: category.displayNameFallback,
                                types: filtered
                            )
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .padding(.bottom, 80)
            }

            macSheetFooter
        }
        .frame(minWidth: 560, idealWidth: 620, minHeight: 560, idealHeight: 680)
        .background(PMColor.bg.ignoresSafeArea())
        .foregroundStyle(PMColor.text)
    }

    private var macSheetChrome: some View {
        HStack(spacing: 12) {
            PMWindowTrafficLights(closeOnly: true)
            VStack(alignment: .leading, spacing: 2) {
                Text("添加音乐源")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(PMColor.text)
                Text("选择协议或服务")
                    .font(.system(size: 11))
                    .foregroundStyle(PMColor.textFaint)
            }
            Spacer()
        }
        .frame(height: 56)
        .padding(.horizontal, 18)
        .overlay(alignment: .bottom) {
            Rectangle().fill(PMColor.divider).frame(height: 0.5)
        }
    }

    private var macDiscoverySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                macSectionLabel("discovered_devices")
                if discoveryService.isDiscovering {
                    ProgressView().controlSize(.mini)
                }
                Spacer()
                if !discoveryService.isDiscovering {
                    Button("rescan") { discoveryService.startDiscovery() }
                        .font(.system(size: 11.5))
                        .buttonStyle(.plain)
                        .foregroundStyle(PMColor.textMuted)
                }
            }

            if discoveryService.devices.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(discoveryService.isDiscovering ? "discovering_devices" : "no_files_found")
                        .font(.system(size: 12.5))
                        .foregroundStyle(PMColor.textMuted)
                    Spacer()
                }
                .padding(12)
                .pmCard(cornerRadius: 8)
            } else {
                LazyVGrid(columns: macGridColumns, alignment: .leading, spacing: 8) {
                    ForEach(discoveryService.devices) { device in
                        macDeviceTile(device)
                    }
                }
            }
        }
    }

    private func macProtocolSection(title: String, types: [MusicSourceType]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            macSectionLabelText(title)
            LazyVGrid(columns: macGridColumns, alignment: .leading, spacing: 8) {
                ForEach(types, id: \.self) { type in
                    macSourceTypeTile(type)
                }
            }
        }
    }

    private var macGridColumns: [GridItem] {
        [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
    }

    private func macSourceTypeTile(_ type: MusicSourceType) -> some View {
        Button {
            pendingType = type
        } label: {
            HStack(spacing: 10) {
                Text(String(type.rawValue.prefix(2)).uppercased())
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(PMColor.brand)
                    .frame(width: 28, height: 28)
                    .background(PMColor.brand.opacity(0.16), in: .rect(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 2) {
                    Text(type.displayName)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(PMColor.text)
                        .lineLimit(1)
                    Text(type.subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(PMColor.textFaint)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)
                if type.supports2FA {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(PMColor.warn)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(PMColor.textFaint)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tileBackground(selected: pendingType == type), in: .rect(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(pendingType == type ? PMColor.brand.opacity(0.55) : PMColor.cardBorder, lineWidth: 0.5)
            }
        }
        .buttonStyle(.plain)
        .onTapGesture(count: 2) {
            selectedType = type
        }
    }

    private func macDeviceTile(_ device: DiscoveredDevice) -> some View {
        Button {
            selectedDevice = device
        } label: {
            HStack(spacing: 10) {
                Image(systemName: device.sourceType.iconName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(PMColor.ok, in: .rect(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(PMColor.text)
                        .lineLimit(1)
                    Text("\(device.sourceType.displayName) · \(device.host)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(PMColor.textFaint)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(PMColor.ok)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .pmCard(cornerRadius: 8)
        }
        .buttonStyle(.plain)
    }

    private var macSheetFooter: some View {
        HStack(spacing: 10) {
            Spacer()
            Button("cancel") { dismiss() }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .font(.system(size: 12))
                .foregroundStyle(PMColor.text)
                .padding(.horizontal, 14)
                .frame(height: 28)
                .background(PMColor.glassBtn, in: .rect(cornerRadius: 6))
                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(PMColor.cardBorder, lineWidth: 0.5) }

            Button {
                if let pendingType {
                    selectedType = pendingType
                }
            } label: {
                Text("下一步")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 28)
                    .background((pendingType == nil ? PMColor.textFaint : PMColor.brand), in: .rect(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .disabled(pendingType == nil)
        }
        .padding(.horizontal, 18)
        .frame(height: 64)
        .background(PMColor.bg)
        .overlay(alignment: .top) {
            Rectangle().fill(PMColor.divider).frame(height: 0.5)
        }
    }

    private func macSectionLabel(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.8)
            .textCase(.uppercase)
            .foregroundStyle(PMColor.textFaint)
    }

    private func macSectionLabelText(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.8)
            .textCase(.uppercase)
            .foregroundStyle(PMColor.textFaint)
    }

    private func tileBackground(selected: Bool) -> Color {
        selected ? PMColor.brand.opacity(0.14) : PMColor.card
    }

    /// Legacy grouped form kept as a reference for iOS parity; macOS now uses
    /// the custom SRC-01 sheet above.
    private var macForm: some View {
        Form {
            Section {
                if discoveryService.devices.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(discoveryService.isDiscovering
                             ? "discovering_devices"
                             : "no_files_found")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(discoveryService.devices) { device in
                        deviceRow(device)
                    }
                }
            } header: {
                HStack(spacing: 6) {
                    Text("discovered_devices")
                    if discoveryService.isDiscovering {
                        ProgressView().controlSize(.mini)
                    }
                    Spacer()
                    if !discoveryService.isDiscovering {
                        Button("rescan") { discoveryService.startDiscovery() }
                            .buttonStyle(.borderless)
                            .font(.caption)
                    }
                }
            }

            // Apple Music / iTunes 资料库 — 单独 section 置顶,避免被埋进
            // Local 分类底部找不到。
            Section("Apple") {
                typeButton(.appleMusicLibrary)
            }

            // 其它来源按 category 分组,过滤掉已在上面单独展示的 appleMusicLibrary
            ForEach(MusicSourceType.groupedByCategory, id: \.0) { category, types in
                let filtered = types.filter { $0 != .appleMusicLibrary && $0 != .appleMusic }
                if !filtered.isEmpty {
                    Section(category.displayNameFallback) {
                        ForEach(filtered, id: \.self) { typeButton($0) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("select_source_type")
        .toolbarTitleDisplayMode(.inline)
    }

    /// macOS 行 — 横向布局,SF Symbol 走 accent color tint 不加彩块,
    /// 文字两行紧贴,跟 macOS 系统设置里 source list 的行高一致。
    private func typeButton(_ type: MusicSourceType) -> some View {
        Button {
            selectedType = type
        } label: {
            HStack(spacing: 10) {
                Image(systemName: type.iconName)
                    .font(.system(size: 15))
                    .foregroundStyle(.tint)
                    .frame(width: 22, alignment: .center)

                VStack(alignment: .leading, spacing: 1) {
                    Text(type.displayName)
                        .font(.body)
                    Text(type.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if type.supports2FA {
                    Image(systemName: "lock.shield")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func deviceRow(_ device: DiscoveredDevice) -> some View {
        Button {
            selectedDevice = device
        } label: {
            HStack(spacing: 10) {
                Image(systemName: device.sourceType.iconName)
                    .font(.system(size: 15))
                    .foregroundStyle(.green)
                    .frame(width: 22, alignment: .center)

                VStack(alignment: .leading, spacing: 1) {
                    Text(device.name)
                        .font(.body)
                    Text("\(device.sourceType.displayName) · \(device.host)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(.green)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
    #endif

    // MARK: - iOS layout (unchanged from prior)

    #if os(iOS)
    private var iosList: some View {
        List {
            iosDiscoverySection
            if let localImportProgress {
                iosLocalImportProgressSection(localImportProgress)
            }

            ForEach(MusicSourceType.groupedByCategory, id: \.0) { category, types in
                let filtered = types.filter { $0 != .local && $0 != .appleMusicLibrary }
                if category == .local {
                    iosLocalImportSection
                } else if !filtered.isEmpty {
                    Section(header: Text(category.displayNameFallback)) {
                        ForEach(filtered, id: \.self) { type in
                            Button {
                                selectedType = type
                            } label: {
                                iosSourceTypeRow(type)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .navigationTitle("select_source_type")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarTitleDisplayMode(.inline)
        // 文件/文件夹入口都走 open-in-place 安全域授权: 文件夹递归扫描;
        // 散文件拿到活的 provider URL, 交给 LocalImportService 按需触发下载/
        // materialize 后再读字节(asCopy:true 会让系统提前复制, 第三方网盘易交出占位)。
        .sheet(isPresented: $showLocalImporter) {
            IOSLocalDocumentPicker(mode: localImportPickerMode) { result in
                handleLocalImport(result)
            }
        }
        .interactiveDismissDisabled(localImportProgress != nil)
        .onDisappear {
            cancelLocalImport()
        }
        .alert(item: $localImportAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("ok")) {
                    if alert.dismissAfterOK {
                        dismiss()
                    }
                }
            )
        }
    }

    /// 本地导入入口 —— 跟随普通源类型的 Local 分组。iOS 一个选择器无法同时选文件夹和散文件,
    /// 且 .folder 模式下第三方云盘会被系统灰掉, 故拆成两个入口: 文件夹整包
    /// (本机/iCloud)、文件多选(可从百度/阿里等云盘选音频)。
    private var iosLocalImportSection: some View {
        Section {
            Button {
                localImportPickerMode = .folder
                showLocalImporter = true
            } label: {
                iosImportRow(icon: "folder.badge.plus",
                             title: "local_import_folder_title",
                             subtitle: "local_import_folder_subtitle")
            }
            .buttonStyle(.plain)
            .disabled(localImportProgress != nil)

            Button {
                localImportPickerMode = .files
                showLocalImporter = true
            } label: {
                iosImportRow(icon: "doc.badge.plus",
                             title: "local_import_files_title",
                             subtitle: "local_import_files_subtitle")
            }
            .buttonStyle(.plain)
            .disabled(localImportProgress != nil)
        } header: {
            Text(SourceCategory.local.displayNameFallback)
        } footer: {
            Text("local_import_section_footer")
        }
    }

    private func iosImportRow(icon: String, title: LocalizedStringKey, subtitle: LocalizedStringKey) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Color.accentColor)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body)
                Text(subtitle)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption).foregroundStyle(.secondary)
        }
        // 撑满整行 + 整块可点(否则 Spacer 空白区不响应, 只有图标/文字/箭头能点)。
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    private func iosLocalImportProgressSection(_ progress: LocalImportService.CopyProgress) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("local_import_progress_title")
                        .font(.body.weight(.medium))
                    Spacer()
                    Button("cancel") {
                        cancelLocalImport()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption.weight(.semibold))
                }

                if let fraction = progress.fraction {
                    ProgressView(value: fraction)
                        .tint(.accentColor)
                }

                Text(localImportProgressMessage(progress))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !progress.currentFileName.isEmpty {
                    Text(progress.currentFileName)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func handleLocalImport(_ result: Result<[URL], Error>) {
        showLocalImporter = false
        switch result {
        case .success(let urls):
            startLocalImport(urls)
        case .failure(let error):
            localImportAlert = LocalImportAlert(
                title: String(localized: "local_import_err_title"),
                message: error.localizedDescription,
                dismissAfterOK: false
            )
        }
    }

    private func startLocalImport(_ urls: [URL]) {
        cancelLocalImport()
        localImportAlert = nil
        let cleanupPickedCopies = localImportPickerMode.importsCopy
        localImportProgress = LocalImportService.CopyProgress(
            phase: .discovering,
            currentFileName: "",
            processed: 0,
            total: 0,
            copied: 0,
            skipped: 0
        )
        localImportTask = Task {
            var finalResult: LocalImportService.CopyResult?
            for await event in LocalImportService.copyEvents(urls, cleanupPickedCopies: cleanupPickedCopies) {
                guard !Task.isCancelled else { return }
                switch event {
                case .progress(let progress):
                    localImportProgress = progress
                case .finished(let result):
                    finalResult = result
                }
            }
            guard !Task.isCancelled, let outcome = finalResult else { return }
            localImportTask = nil
            localImportProgress = nil

            if outcome.cancelled { return }
            guard outcome.copied > 0 else {
                plog("📥 LocalImport: 没有可导入的音频 (选了 \(urls.count) 项)")
                localImportAlert = LocalImportAlert(
                    title: localImportFailureTitle(outcome),
                    message: localImportFailureMessage(outcome),
                    dismissAfterOK: false
                )
                return
            }

            onAdd(LocalImportService.makeSource(name: String(localized: "local_import_source_name")))
            if outcome.skipped > 0 {
                localImportAlert = LocalImportAlert(
                    title: String(localized: "local_import_partial_title"),
                    message: localImportCompletionMessage(outcome),
                    dismissAfterOK: true
                )
            } else {
                dismiss()
            }
        }
    }

    private func cancelLocalImport() {
        localImportTask?.cancel()
        localImportTask = nil
        localImportProgress = nil
    }

    private func localImportProgressMessage(_ progress: LocalImportService.CopyProgress) -> String {
        switch progress.phase {
        case .discovering:
            return String(localized: "local_import_progress_discovering")
        case .copying:
            if progress.total > 0 {
                return String(
                    format: String(localized: "local_import_progress_copying_format"),
                    progress.processed,
                    progress.total,
                    progress.copied,
                    progress.skipped
                )
            }
            return String(localized: "local_import_progress_preparing")
        case .finished:
            return String(localized: "local_import_progress_finishing")
        case .cancelled:
            return String(localized: "local_import_cancelled")
        }
    }

    private func localImportCompletionMessage(_ result: LocalImportService.CopyResult) -> String {
        var message = String(
            format: String(localized: "local_import_done_message_format"),
            result.copied,
            result.skipped
        )
        if let firstFailure = result.failures.first {
            message += "\n" + String(
                format: String(localized: "local_import_failure_reason_format"),
                localImportFailureDescription(firstFailure)
            )
            if localImportNeedsProviderHint(firstFailure.reason) {
                message += "\n" + String(localized: "local_import_provider_hint")
            }
        }
        return message
    }

    private func localImportFailureMessage(_ result: LocalImportService.CopyResult) -> String {
        let attempted = max(result.discovered, result.skipped)
        // 网盘把后端错误响应当文件内容交出来(而非占位): 用更精准的文案直接引导内置云盘源。
        if result.copied == 0,
           let errFailure = result.failures.first(where: { $0.reason == .providerReturnedError }) {
            return String(
                format: String(localized: "local_import_provider_error_message_format"),
                attempted,
                result.skipped,
                localImportFailureDescription(errFailure)
            )
        }
        if let firstFailure = result.failures.first,
           localImportIsProviderOnlyFailure(result) {
            return String(
                format: String(localized: "local_import_provider_failure_message_format"),
                attempted,
                result.skipped,
                localImportFailureDescription(firstFailure)
            )
        }

        var message = String(
            format: String(localized: "local_import_none_added_message_format"),
            attempted,
            result.skipped
        )
        guard let firstFailure = result.failures.first else {
            return message
        }
        message += "\n" + String(
            format: String(localized: "local_import_failure_reason_format"),
            localImportFailureDescription(firstFailure)
        )
        if localImportNeedsProviderHint(firstFailure.reason) {
            message += "\n" + String(localized: "local_import_provider_hint")
        }
        return message
    }

    private func localImportFailureTitle(_ result: LocalImportService.CopyResult) -> String {
        if result.copied == 0,
           result.failures.contains(where: { $0.reason == .providerReturnedError }) {
            return String(localized: "local_import_provider_error_title")
        }
        if localImportIsProviderOnlyFailure(result) {
            return String(localized: "local_import_provider_title")
        }
        return String(localized: "local_import_err_title")
    }

    private func localImportIsProviderOnlyFailure(_ result: LocalImportService.CopyResult) -> Bool {
        result.copied == 0 && result.failures.contains { localImportNeedsProviderHint($0.reason) }
    }

    private func localImportFailureDescription(_ failure: LocalImportService.CopyFailure) -> String {
        var reason = localImportReasonText(failure.reason)
        if failure.reason == .invalidAudioFile || failure.reason == .providerReturnedError,
           let detail = failure.detail,
           !detail.isEmpty {
            reason += " (\(detail))"
        }
        return String(
            format: String(localized: "local_import_failure_item_format"),
            failure.fileName,
            reason
        )
    }

    private func localImportReasonText(_ reason: LocalImportService.FailureReason) -> String {
        switch reason {
        case .unsupportedFormat:
            return String(localized: "local_import_reason_unsupported")
        case .notFound:
            return String(localized: "local_import_reason_not_found")
        case .permissionDenied:
            return String(localized: "local_import_reason_permission")
        case .notEnoughSpace:
            return String(localized: "local_import_reason_space")
        case .coordinatedReadFailed:
            return String(localized: "local_import_reason_provider")
        case .invalidAudioFile:
            return String(localized: "local_import_reason_invalid_audio")
        case .providerReturnedError:
            return String(localized: "local_import_reason_provider_error")
        case .copyFailed:
            return String(localized: "local_import_reason_copy")
        }
    }

    private func localImportNeedsProviderHint(_ reason: LocalImportService.FailureReason) -> Bool {
        switch reason {
        case .coordinatedReadFailed, .invalidAudioFile, .providerReturnedError:
            return true
        case .unsupportedFormat, .notFound, .permissionDenied, .notEnoughSpace, .copyFailed:
            return false
        }
    }

    private struct LocalImportAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let dismissAfterOK: Bool
    }

    /// 文件选择器允许的类型: `.audio` 父类型 + 常见具体类型, 再用扩展名兜底
    /// flac/ape/wv/dsf 等系统不一定声明为 audio 的格式, 让它们在选择器里可选。
    nonisolated fileprivate static var audioContentTypes: [UTType] {
        var set: Set<UTType> = [.audio, .mp3, .wav, .aiff, .mpeg4Audio]
        for ext in PrimuseConstants.supportedAudioExtensions {
            if let type = UTType(filenameExtension: ext) { set.insert(type) }
        }
        return Array(set)
    }

    @ViewBuilder
    private var iosDiscoverySection: some View {
        Section {
            if discoveryService.isDiscovering && discoveryService.devices.isEmpty {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("discovering_devices").foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            ForEach(discoveryService.devices) { device in
                Button {
                    selectedDevice = device
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: device.sourceType.iconName)
                            .font(.title3)
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(Color.green)
                            .clipShape(RoundedRectangle(cornerRadius: 8))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name).font(.body)
                            Text("\(device.sourceType.displayName) · \(device.host)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "plus.circle.fill")
                            .font(.title3).foregroundStyle(.green)
                    }
                }
                .buttonStyle(.plain)
            }

            if !discoveryService.isDiscovering && !discoveryService.devices.isEmpty {
                Button {
                    discoveryService.startDiscovery()
                } label: {
                    HStack {
                        Image(systemName: "arrow.clockwise")
                        Text("rescan")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            HStack {
                Text("discovered_devices")
                if discoveryService.isDiscovering {
                    ProgressView().controlSize(.mini).padding(.leading, 4)
                }
            }
        }
    }

    private func iosSourceTypeRow(_ type: MusicSourceType) -> some View {
        HStack(spacing: 12) {
            Image(systemName: type.iconName)
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Color.accentColor)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(type.displayName).font(.body)
                Text(type.subtitle)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if type.supports2FA {
                Image(systemName: "lock.shield.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            Image(systemName: "chevron.right")
                .font(.caption).foregroundStyle(.secondary)
        }
        // 撑满整行 + 整块可点(否则 Spacer 空白区不响应, 只有图标/文字/箭头能点)。
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
    #endif
}

extension MusicSourceType: @retroactive Identifiable {
    public var id: String { rawValue }
}

#if os(iOS)
enum LocalImportPickerMode {
    case folder
    case files

    var contentTypes: [UTType] {
        switch self {
        case .folder:
            return [.folder]
        case .files:
            return SourceTypeSelectionView.audioContentTypes
        }
    }

    // 两个入口都走 open-in-place(asCopy:false): 拿到活的 security-scoped
    // provider URL, LocalImportService 才能用 startDownloadingUbiquitousItem +
    // NSFileCoordinator(.forUploading) 驱动按需 materialize。asCopy:true 时系统
    // 在导出阶段就先复制进沙箱, 第三方网盘扩展常交出占位小文件(几十字节), 而那时
    // 已是普通本地副本(非 ubiquitous), 兜底下载逻辑全部失效, 只能拒收。
    var importsCopy: Bool {
        false
    }
}

struct IOSLocalDocumentPicker: UIViewControllerRepresentable {
    let mode: LocalImportPickerMode
    let onCompletion: (Result<[URL], Error>) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: mode.contentTypes,
            asCopy: mode.importsCopy
        )
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = true
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCompletion: onCompletion)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onCompletion: (Result<[URL], Error>) -> Void

        init(onCompletion: @escaping (Result<[URL], Error>) -> Void) {
            self.onCompletion = onCompletion
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onCompletion(.success(urls))
        }
    }
}
#endif
