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
            List {
                // MARK: - Auto-discovered devices
                discoverySection

                // MARK: - Manual source type selection
                ForEach(MusicSourceType.groupedByCategory, id: \.0) { category, types in
                    #if os(iOS)
                    let filteredTypes = types.filter { $0 != .local }
                    #else
                    let filteredTypes = types
                    #endif
                    if !filteredTypes.isEmpty {
                        Section(header: Text(category.displayNameFallback)) {
                            ForEach(filteredTypes, id: \.self) { type in
                                Button {
                                    selectedType = type
                                } label: {
                                    sourceTypeRow(type)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            #if os(macOS)
            .listStyle(.inset)
            .navigationTitle("select_source_type")
            #else
            .navigationTitle("select_source_type")
            .navigationBarTitleDisplayMode(.inline)
            #endif
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
            .onAppear {
                discoveryService.startDiscovery()
            }
            .onDisappear {
                discoveryService.stopDiscovery()
            }
        }
    }

    // MARK: - Discovery Section

    @ViewBuilder
    private var discoverySection: some View {
        Section {
            if discoveryService.isDiscovering && discoveryService.devices.isEmpty {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("discovering_devices")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            ForEach(discoveryService.devices) { device in
                Button {
                    selectedDevice = device
                } label: {
                    HStack(spacing: 12) {
                        sourceIcon(systemName: device.sourceType.iconName, tint: .green)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name)
                                .font(.body)
                                .foregroundStyle(.primary)

                            Text("\(device.sourceType.displayName) · \(device.host)")
                                .font(.caption)
                                .foregroundStyle(Color.secondary)
                        }

                        Spacer()

                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.green)
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
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        } header: {
            HStack {
                Text("discovered_devices")
                if discoveryService.isDiscovering {
                    ProgressView()
                        .controlSize(.mini)
                        .padding(.leading, 4)
                }
            }
        }
    }

    // MARK: - Source type row

    private func sourceTypeRow(_ type: MusicSourceType) -> some View {
        HStack(spacing: 12) {
            sourceIcon(systemName: type.iconName, tint: .accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(type.displayName)
                    .font(.body)
                    .foregroundStyle(.primary)

                Text(type.subtitle)
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            }

            Spacer()

            if type.supports2FA {
                Image(systemName: "lock.shield.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// 跨平台 Icon: iOS 维持原本"白图标 + 彩色圆角方块"的填充观感;
    /// macOS 用 SF Symbol + tinted 前景色的小图标,贴近 macOS Settings /
    /// Music 的视觉密度,不再像移动端那样占一大块面积。
    @ViewBuilder
    private func sourceIcon(systemName: String, tint: Color) -> some View {
        #if os(macOS)
        Image(systemName: systemName)
            .font(.body)
            .foregroundStyle(tint)
            .frame(width: 24, height: 24)
        #else
        Image(systemName: systemName)
            .font(.title3)
            .foregroundStyle(.white)
            .frame(width: 36, height: 36)
            .background(tint)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        #endif
    }
}

extension MusicSourceType: @retroactive Identifiable {
    public var id: String { rawValue }
}


