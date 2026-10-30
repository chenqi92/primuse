#if os(iOS)
import SwiftUI

/// 图标选择网格。由「设置页」直接平铺，也可作为独立页面打开。
struct AppIconPickerGrid: View {
    private let service = AppIconService.shared
    @State private var showsError = false

    var options: [AppIconService.IconOption] = AppIconService.shared.options
    var columns = [
        GridItem(.adaptive(minimum: 96), spacing: 16)
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 20) {
            ForEach(options) { option in
                iconCell(option)
            }
        }
        .settingsAnchor("appearance.appIcon")
        .padding(.vertical, 8)
        .alert(Text("app_icon"), isPresented: $showsError) {
            Button("ok", role: .cancel) { }
        } message: {
            Text(service.lastError ?? "")
        }
    }

    private func iconCell(_ option: AppIconService.IconOption) -> some View {
        let isSelected = service.currentIconID == option.id

        return Button {
            Task {
                if !(await service.setIcon(option)), service.lastError != nil {
                    showsError = true
                }
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 挂在单个格子上：选中描边与文字颜色只跟这一格的选中态走。
        .pmAnimation(.selection, value: isSelected)
        .disabled(!service.supportsAlternateIcons || service.isChangingIcon)
        .accessibilityIdentifier("appIcon.\(option.id.isEmpty ? "default" : option.id)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .iconAppearanceAccessibilityHint(option.supportsAppearance)
    }
}

struct HiddenAppIconSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                AppIconPickerGrid(
                    options: AppIconService.shared.hiddenOptions + [AppIconService.shared.options[0]],
                    columns: Array(repeating: GridItem(.flexible(), spacing: 24), count: 2)
                )
                .frame(maxWidth: 340)
                .padding(24)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("app_icon")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
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
