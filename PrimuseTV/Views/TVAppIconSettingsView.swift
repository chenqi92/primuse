#if os(tvOS)
import SwiftUI

struct TVAppIconSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedID: String?
    @State private var showsError = false
    private let service = AppIconService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 36) {
            HStack {
                Text("app_icon")
                    .tvFont(size: 44, weight: .bold, relativeTo: .title)
                Spacer()
                Button("done") { dismiss() }
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 40), count: 3), spacing: 36) {
                ForEach(service.options) { option in
                    iconButton(option)
                }
            }
        }
        .padding(64)
        .frame(maxWidth: 1500)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TVColor.bg.ignoresSafeArea())
        .foregroundStyle(TVColor.text)
        .onAppear { focusedID = service.currentIconID }
        .onExitCommand { dismiss() }
        .alert(Text("app_icon"), isPresented: $showsError) {
            Button("ok", role: .cancel) { }
        } message: {
            Text(service.lastError ?? "")
        }
    }

    private func iconButton(_ option: AppIconService.IconOption) -> some View {
        let selected = service.currentIconID == option.id
        let focused = focusedID == option.id
        let name = option.id.isEmpty ? "AppIcon" : option.id
        return Button {
            Task {
                if !(await service.setIcon(option)), service.lastError != nil {
                    showsError = true
                }
            }
        } label: {
            VStack(spacing: 16) {
                Image(name + "TVPreview")
                    .resizable()
                    .aspectRatio(5.0 / 3.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                HStack {
                    Text(option.displayName)
                        .tvFont(.body, weight: selected ? .bold : .medium)
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .opacity(selected ? 1 : 0)
                }
            }
            .padding(18)
            .background(TVColor.card, in: RoundedRectangle(cornerRadius: 24))
            .overlay {
                RoundedRectangle(cornerRadius: 24)
                    .strokeBorder(selected ? TVColor.brand : TVColor.cardBorder, lineWidth: selected ? 3 : 1)
            }
            .tvFocusRing(focused, radius: 24, accent: TVColor.brand, scale: 1.04, lift: 4)
        }
        .buttonStyle(TVBareButtonStyle())
        .focused($focusedID, equals: option.id)
        .focusEffectDisabled()
        .disabled(!service.supportsAlternateIcons)
        .accessibilityLabel(option.displayName)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
#endif
