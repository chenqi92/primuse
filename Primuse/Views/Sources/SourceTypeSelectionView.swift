import SwiftUI
import PrimuseKit

struct SourceTypeSelectionView: View {
    @Environment(\.dismiss) private var dismiss
    var onAdd: (MusicSource) -> Void

    @State private var selectedType: MusicSourceType?
    @State private var discoveryService = NetworkDiscoveryService()
    @State private var selectedDevice: DiscoveredDevice?

    var body: some View {
        NavigationStack {
            #if os(macOS)
            macForm
            #else
            iosList
            #endif
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("cancel") { dismiss() }
            }
        }
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

    // MARK: - macOS layout

    #if os(macOS)
    /// 用 Form + .formStyle(.grouped) 更贴近 macOS 26 设置面板观感:
    /// 行紧凑、图标小色而无彩块、section 大写小标题。比 List(.inset)
    /// 移动端味道的大圆角卡片更协调。
    private var macForm: some View {
        Form {
            // 自动发现的设备
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
