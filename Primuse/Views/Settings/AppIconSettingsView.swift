import SwiftUI

struct AppIconSettingsView: View {
    private let service = AppIconService.shared

    private let columns = [
        GridItem(.adaptive(minimum: 96), spacing: 16)
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(service.options) { option in
                    iconCell(option)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
        }
        .navigationTitle("app_icon")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private func iconCell(_ option: AppIconService.IconOption) -> some View {
        let isSelected = service.currentIconID == option.id

        return Button {
            Task { await service.setIcon(option) }
        } label: {
            VStack(spacing: 8) {
                ZStack(alignment: .topTrailing) {
                    Image(option.previewAsset)
                        .resizable()
                        .aspectRatio(1, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(
                                    isSelected ? Color.accentColor : Color.black.opacity(0.08),
                                    lineWidth: isSelected ? 3 : 1
                                )
                        )

                    if option.supportsAppearance {
                        Image(systemName: "circle.lefthalf.filled")
                            .font(.caption2)
                            .foregroundStyle(.white)
                            .padding(5)
                            .background(.black.opacity(0.55), in: Circle())
                            .padding(6)
                    }
                }

                Text(option.displayName)
                    .font(.caption)
                    .foregroundStyle(isSelected ? Color.accentColor : .primary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .disabled(!service.supportsAlternateIcons)
    }
}
