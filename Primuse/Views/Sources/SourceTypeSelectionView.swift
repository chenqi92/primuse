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
                    let filteredTypes = types.filter { $0 != .local }
                    if !filteredTypes.isEmpty {
                        Section(header: Text(category.displayNameFallback)) {
                            ForEach(filteredTypes, id: \.self) { type in
                                Button {
                                    selectedType = type
                                } label: {
                                    sourceTypeRow(type)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("select_source_type")
            .navigationBarTitleDisplayMode(.inline)
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
                        Image(systemName: device.sourceType.iconName)
                            .font(.title3)
                            .foregroundStyle(.green)
                            .frame(width: 36, height: 36)
                            .background(Color.green.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 8))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name)
                                .font(.body)
                                .foregroundStyle(.primary)

                            Text("\(device.sourceType.displayName) · \(device.host)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.green)
                    }
                }
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
            Image(systemName: type.iconName)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(type.displayName)
                    .font(.body)
                    .foregroundStyle(.primary)

                Text(type.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if type.supports2FA {
                Image(systemName: "lock.shield.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

extension MusicSourceType: @retroactive Identifiable {
    public var id: String { rawValue }
}


