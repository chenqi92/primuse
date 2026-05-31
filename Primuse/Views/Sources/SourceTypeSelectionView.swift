import SwiftUI
import PrimuseKit

struct SourceTypeSelectionView: View {
    @Environment(\.dismiss) private var dismiss
    var onAdd: (MusicSource) -> Void

    @State private var selectedType: MusicSourceType?
    @State private var discoveryService = NetworkDiscoveryService()
    @State private var selectedDevice: DiscoveredDevice?
    #if os(macOS)
    @State private var pendingType: MusicSourceType?
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
                Button("cancel") { dismiss() }
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
                        let filtered = types.filter { $0 != .appleMusicLibrary }
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
                let filtered = types.filter { $0 != .appleMusicLibrary }
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

            ForEach(MusicSourceType.groupedByCategory, id: \.0) { category, types in
                let filtered = types.filter { $0 != .local && $0 != .appleMusicLibrary }
                if !filtered.isEmpty {
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
    }
    #endif
}

extension MusicSourceType: @retroactive Identifiable {
    public var id: String { rawValue }
}
