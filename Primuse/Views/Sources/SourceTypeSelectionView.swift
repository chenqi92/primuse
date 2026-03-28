import SwiftUI
import PrimuseKit

struct SourceTypeSelectionView: View {
    @Environment(\.dismiss) private var dismiss
    var onAdd: (MusicSource) -> Void
    @State private var selectedType: MusicSourceType?

    var body: some View {
        NavigationStack {
            List {
                ForEach(MusicSourceType.groupedByCategory, id: \.0) { category, types in
                    Section(header: Text(category.displayNameFallback)) {
                        ForEach(types, id: \.self) { type in
                            Button {
                                selectedType = type
                            } label: {
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
        }
    }
}

extension MusicSourceType: @retroactive Identifiable {
    public var id: String { rawValue }
}
