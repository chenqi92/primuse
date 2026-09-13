#if os(iOS)
import SwiftUI

/// 图标选择网格。由「设置页」直接平铺，也可作为独立页面打开。
struct AppIconPickerGrid: View {
    private let service = AppIconService.shared

    private let columns = [
        GridItem(.adaptive(minimum: 96), spacing: 16)
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 20) {
            ForEach(service.options) { option in
                iconCell(option)
            }
        }
        .settingsAnchor("appearance.appIcon")
        .padding(.vertical, 8)
    }

    private func iconCell(_ option: AppIconService.IconOption) -> some View {
        let isSelected = service.currentIconID == option.id

        return Button {
            Task {
                await service.setIcon(option)
            }
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
        .iconAppearanceAccessibilityHint(option.supportsAppearance)
    }
}

private extension View {
    @ViewBuilder
    func iconAppearanceAccessibilityHint(_ isSupported: Bool) -> some View {
        if isSupported {
            accessibilityHint(Text("icon_appearance_hint"))
        } else {
            self
        }
    }
}

/// 独立页面外壳。设置搜索命中 App 图标条目时仍会推这一页。
struct AppIconSettingsView: View {
    var body: some View {
        ScrollView {
            AppIconPickerGrid()
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
        }
        .navigationTitle("app_icon")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(uiColor: .systemGroupedBackground))
    }
}

#endif
