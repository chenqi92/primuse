import SwiftUI
import PrimuseKit
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

extension HomeFilterBarAppearance {
    var supportsLabelStyle: Bool {
        self == .classic || self == .underline || self == .segmented
    }

    var titleKey: LocalizedStringKey {
        switch self {
        case .classic: "home_filter_style_classic"
        case .underline: "home_filter_style_underline"
        case .segmented: "home_filter_style_segmented"
        case .icons: "home_filter_style_icons"
        case .kinetic: "home_filter_style_kinetic"
        case .tuner: "home_filter_style_tuner"
        case .sleeves: "home_filter_style_sleeves"
        }
    }
}

/// 只有顶部控件观察拖动进度，避免每一帧重算整个首页。
@Observable @MainActor
final class HomeFilterSwipeMotion {
    var target: ListeningSpace?
    var progress: CGFloat = 0
}

struct HomeSpaceFilterBar: View {
    let spaces: [ListeningSpace]
    let selection: ListeningSpace?
    var labelStyle: HomeFilterBarLabelStyle = .automatic
    var appearance: HomeFilterBarAppearance = .classic
    var motion: HomeFilterSwipeMotion?
    let onSelect: (ListeningSpace) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.colorScheme) private var colorScheme
    @Environment(ThemeService.self) private var theme
    @ScaledMetric(relativeTo: .body) private var typeScale = 1.0
    @State private var viewportWidth: CGFloat = 390
    @State private var tuningIndex: CGFloat?

    private var progress: CGFloat { reduceMotion ? 0 : (motion?.progress ?? 0) }
    private var transitionTarget: ListeningSpace? { motion?.target }
    private var showsTitle: Bool { !appearance.supportsLabelStyle || labelStyle != .iconOnly }
    private var automaticInlineIcons: Bool {
        guard appearance == .segmented, labelStyle == .automatic else { return false }
        let widest = spaces.map { textWidth($0, size: 16) }.max() ?? 0
        return (widest + 26 * typeScale + 24) * CGFloat(spaces.count) <= viewportWidth - 32
    }
    private var accent: Color { selection?.tint ?? .accentColor }
    private var selectedIndex: CGFloat? {
        if let tuningIndex { return tuningIndex }
        guard let selection, let index = spaces.firstIndex(of: selection) else { return nil }
        let target = transitionTarget.flatMap { spaces.firstIndex(of: $0) } ?? index
        return CGFloat(index) + CGFloat(target - index) * progress
    }

    private func emphasis(_ space: ListeningSpace) -> CGFloat {
        if space == selection { return 1 - progress }
        return space == transitionTarget ? progress : 0
    }

    private func textWidth(_ space: ListeningSpace, size: CGFloat) -> CGFloat {
        #if os(iOS)
        let font = UIFont.systemFont(ofSize: size * typeScale, weight: .semibold)
        #else
        let font = NSFont.systemFont(ofSize: size * typeScale, weight: .semibold)
        #endif
        return ceil((space.title as NSString).size(withAttributes: [.font: font]).width)
    }

    private var cellWidth: CGFloat {
        let text = showsTitle ? spaces.map { textWidth($0, size: 16) }.max() ?? 0 : 0
        let icon: CGFloat = appearance.supportsLabelStyle && (labelStyle == .iconAndTitle || automaticInlineIcons) ? 26 * typeScale : 0
        return max(52, text + icon + 24)
    }

    private var width: CGFloat {
        max(viewportWidth - 32 - (appearance == .segmented ? 6 : 0), CGFloat(spaces.count) * cellWidth)
    }

    var body: some View {
        Group {
            if appearance == .classic {
                ClassicHomeSpaceFilterBar(spaces: spaces, selection: selection,
                                          labelStyle: labelStyle, onSelect: onSelect)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        styledContent
                            .padding(.vertical, appearance == .sleeves ? 8 : 2)
                    }
                    .contentMargins(.horizontal, 16, for: .scrollContent)
                    .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                    .scrollClipDisabled(appearance == .kinetic || appearance == .tuner || appearance == .sleeves)
                    .onChange(of: selection) { _, value in
                        guard let value else { return }
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
                            proxy.scrollTo(value, anchor: .center)
                        }
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewportWidth = $0 }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.spaceFilter")
        .accessibilityValue(appearance.rawValue)
    }

    @ViewBuilder private var styledContent: some View {
        switch appearance {
        case .classic: EmptyView()
        case .underline: underline
        case .segmented: segmented
        case .icons: icons
        case .kinetic: kinetic
        case .tuner: tuner
        case .sleeves: sleeves
        }
    }

    private func item<Content: View>(_ space: ListeningSpace, @ViewBuilder content: () -> Content) -> some View {
        Button { onSelect(space) } label: {
            content().contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(space)
        .accessibilityLabel(Text(space.titleKey))
        .accessibilityAddTraits(selection == space ? .isSelected : [])
        .accessibilityHint(selection == space ? String(localized: "home_filter_clear_hint") : "")
        .accessibilityIdentifier("home.spaceFilter.\(space.rawValue)")
    }

    private func inlineLabel(_ space: ListeningSpace, size: CGFloat = 16) -> some View {
        HStack(spacing: 5) {
            if labelStyle == .iconOnly || labelStyle == .iconAndTitle || automaticInlineIcons {
                Image(systemName: space.systemImage).font(.system(size: size * typeScale))
            }
            if showsTitle {
                Text(space.titleKey).font(.system(size: size * typeScale, weight: .semibold))
                    .fixedSize()
            }
        }
    }

    private func physicalPosition(_ index: CGFloat, in total: CGFloat) -> CGFloat {
        let x = (index + 0.5) * total / CGFloat(max(spaces.count, 1))
        return layoutDirection == .rightToLeft ? total - x : x
    }

    private var underline: some View {
        HStack(spacing: 0) {
            ForEach(spaces, id: \.self) { space in
                item(space) {
                    inlineLabel(space, size: 17)
                        .foregroundStyle(selection == space ? Color.primary : Color.secondary)
                        .frame(width: width / CGFloat(spaces.count), height: 48 * typeScale)
                }
            }
        }
        .overlay {
            if let selectedIndex {
                GeometryReader { geometry in
                    Capsule().fill(accent)
                        .frame(width: 26 * typeScale, height: 3)
                        .position(x: physicalPosition(selectedIndex, in: width), y: geometry.size.height - 1.5)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }

    private var segmented: some View {
        HStack(spacing: 0) {
            ForEach(spaces, id: \.self) { space in
                item(space) {
                    inlineLabel(space, size: 15)
                        .foregroundStyle(selection == space ? AnyShapeStyle(.text(on: space.tint)) : AnyShapeStyle(.primary))
                        .frame(width: width / CGFloat(spaces.count), height: 44 * typeScale)
                }
            }
        }
        .background {
            if let selectedIndex {
                GeometryReader { geometry in
                    Capsule().fill(accent.gradient)
                        .frame(width: width / CGFloat(spaces.count), height: 44 * typeScale)
                        .position(x: physicalPosition(selectedIndex, in: width), y: geometry.size.height / 2)
                }
            }
        }
        .padding(3)
        .background(.quaternary.opacity(0.55), in: Capsule())
    }

    private func designTitle(_ space: ListeningSpace) -> LocalizedStringKey {
        space == .spokenWord ? "minimal_tab_spoken" : space.titleKey
    }

    private func designIcon(_ space: ListeningSpace) -> String {
        switch space {
        case .music: "music.note"
        case .radio: "dot.radiowaves.left.and.right"
        case .spokenWord: "book"
        case .podcast: "mic"
        }
    }

    private var icons: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(spaces, id: \.self) { space in
                let amount = emphasis(space)
                item(space) {
                    VStack(spacing: 7) {
                        Image(systemName: designIcon(space))
                            .font(.system(size: 23 * typeScale, weight: .regular))
                            .foregroundStyle(amount > 0.5 ? AnyShapeStyle(.text(on: space.tint)) : AnyShapeStyle(Color.primary.opacity(0.66)))
                            .frame(width: 49 * typeScale, height: 49 * typeScale)
                            .background {
                                Circle().fill(.quaternary.opacity(0.55))
                                Circle().fill(space.tint.gradient).opacity(amount)
                            }
                            .accessibilityIdentifier("home.filterIcon.\(space.rawValue)")
                        Text(designTitle(space))
                            .font(.system(size: 14 * typeScale, weight: .medium))
                            .foregroundStyle(amount > 0.5 ? space.tint : .primary.opacity(0.76))
                            .fixedSize()
                    }
                    .frame(width: width / CGFloat(spaces.count), alignment: .top)
                    .padding(.bottom, 4)
                }
            }
        }
    }

    private var kinetic: some View {
        HStack(alignment: .firstTextBaseline, spacing: 19 * typeScale) {
            ForEach(spaces, id: \.self) { space in
                let amount = emphasis(space)
                item(space) {
                    Text(designTitle(space))
                        .font(.system(size: (22 + 46 * amount) * typeScale,
                                      weight: amount > 0.5 ? .black : .regular))
                        .tracking(-2 * amount)
                        .foregroundStyle(amount > 0.5
                            ? AnyShapeStyle(LinearGradient(stops: [
                                .init(color: .primary, location: 0.55),
                                .init(color: theme.uiAccentColor, location: 1)
                            ], startPoint: .top, endPoint: .bottom))
                            : AnyShapeStyle(Color.secondary))
                        .fixedSize()
                        .rotationEffect(.degrees(-2 * Double(amount)), anchor: .bottomLeading)
                        .frame(minHeight: 44, alignment: .bottom)
                }
            }
        }
        .frame(minWidth: viewportWidth - 32, alignment: .leading)
        .frame(height: 108 * typeScale, alignment: .center)
        .background(alignment: .topLeading) {
            theme.uiAccentColor
                .mask {
                    Image("HomeFilterSilk")
                        .resizable()
                        .scaledToFill()
                        // 先合成到白底，避免反相把原图的透明区域变成可见遮罩。
                        .background(.white)
                        .compositingGroup()
                        .colorInvert()
                        .luminanceToAlpha()
                }
                .frame(width: viewportWidth, height: 172 * typeScale)
                .opacity(colorScheme == .dark ? 0.70 : 0.82)
                .mask {
                    LinearGradient(stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .white, location: 0.23),
                        .init(color: .white, location: 1)
                    ], startPoint: .top, endPoint: .bottom)
                }
                .offset(x: -16, y: -42 * typeScale)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private var tuner: some View {
        VStack(spacing: 0) {
            Canvas { context, size in
                let count = max(spaces.count * 8, 8)
                for tick in 1..<count {
                    let x = CGFloat(tick) * size.width / CGFloat(count)
                    let major = tick % 8 == 4
                    let medium = tick % 4 == 0
                    let path = Path { line in
                        line.move(to: CGPoint(x: x, y: (major ? 5 : medium ? 12 : 16) * typeScale))
                        line.addLine(to: CGPoint(x: x, y: (major ? 34 : 27) * typeScale))
                    }
                    context.stroke(path, with: .color(.primary.opacity(major ? 0.65 : 0.55)), lineWidth: major ? 1.2 : 0.55)
                }
            }
            .frame(width: width, height: 43 * typeScale)
            .overlay {
                if let selectedIndex {
                    GeometryReader { _ in
                        HomeFilterMaterialImage("HomeFilterNeedle", crop: CGRect(x: 221.0 / 803, y: 145.0 / 1959, width: 360.0 / 803, height: 1745.0 / 1959))
                            .frame(width: 10 * typeScale, height: 43 * typeScale)
                            .shadow(color: .red.opacity(0.3), radius: 9, y: 1)
                            .position(x: physicalPosition(selectedIndex, in: width), y: 21.5 * typeScale)
                    }
                    .allowsHitTesting(false)
                }
            }
            .accessibilityHidden(true)
            HStack(spacing: 0) {
                ForEach(spaces, id: \.self) { space in
                    item(space) {
                        Text(designTitle(space))
                            .font(.system(size: 16 * typeScale, weight: selection == space ? .semibold : .medium))
                            .foregroundStyle(selection == space ? Color.primary : .secondary)
                            .fixedSize()
                            .frame(width: width / CGFloat(spaces.count), height: 34 * typeScale)
                    }
                }
            }
        }
        .padding(.top, 12 * typeScale)
        .padding(.bottom, 5 * typeScale)
        .background {
            HomeFilterMaterialImage("HomeFilterTunerPanel", crop: CGRect(x: 31.0 / 2126, y: 141.0 / 740, width: 2064.0 / 2126, height: 410.0 / 740))
                .colorMultiply(colorScheme == .dark ? Color(red: 0.24, green: 0.23, blue: 0.22) : .white)
                .clipShape(Capsule())
                .overlay { Capsule().strokeBorder(.white.opacity(colorScheme == .dark ? 0.15 : 0.8), lineWidth: 1) }
                .shadow(color: .brown.opacity(colorScheme == .dark ? 0.07 : 0.14), radius: 10, y: 7)
        }
        .gesture(DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) * 1.6 else { return }
                let x = layoutDirection == .rightToLeft ? width - value.location.x : value.location.x
                tuningIndex = min(max(x / width * CGFloat(spaces.count) - 0.5, 0), CGFloat(spaces.count - 1))
            }
            .onEnded { _ in
                guard let tuningIndex else { return }
                let index = Int(tuningIndex.rounded())
                self.tuningIndex = nil
                if spaces.indices.contains(index), spaces[index] != selection { onSelect(spaces[index]) }
            })
    }

    private func paperTint(_ space: ListeningSpace) -> Color {
        switch space {
        case .music, .radio: .white
        case .spokenWord: Color(red: 1, green: 0.95, blue: 0.84)
        case .podcast: Color(red: 0.97, green: 0.89, blue: 0.93)
        }
    }

    private var sleeves: some View {
        let expansion = selection == nil ? 0 : min((viewportWidth - 32) * 0.30, 150) * typeScale
        let shelfWidth = max(viewportWidth - 38, CGFloat(spaces.count) * 58 * typeScale + expansion)
        let base = (shelfWidth - expansion) / CGFloat(max(spaces.count, 1))
        let height = min(max((viewportWidth - 32) * 0.31, 108), 150) * typeScale
        return HStack(alignment: .bottom, spacing: 0) {
            ForEach(spaces, id: \.self) { space in
                let amount = emphasis(space)
                let cardWidth = base + expansion * amount
                item(space) {
                    ZStack(alignment: .trailing) {
                        HomeFilterMaterialImage("HomeFilterPaper")
                            .colorMultiply(paperTint(space))
                            .brightness(colorScheme == .dark ? -0.55 : 0)
                            .clipShape(RoundedRectangle(cornerRadius: 2))
                            .overlay { RoundedRectangle(cornerRadius: 2).strokeBorder(.white.opacity(0.7), lineWidth: 1) }
                            .shadow(color: .black.opacity(0.28), radius: 1, x: 1, y: 1)
                            .opacity(1 - amount)
                        Image("HomeFilterVinyl")
                            .resizable()
                            .scaledToFit()
                            .frame(width: height * 0.90, height: height * 0.90)
                            .rotationEffect(.degrees(reduceMotion ? 0 : -18 * Double(amount)))
                            .offset(x: height * 0.17 * (layoutDirection == .rightToLeft ? -1 : 1))
                            .shadow(color: .black.opacity(0.3), radius: 2, x: 2, y: 1)
                            .opacity(amount)
                            .frame(width: cardWidth, height: height, alignment: .trailing)
                        HomeFilterMaterialImage("HomeFilterSleeve", crop: CGRect(x: 40.0 / 1536, y: 49.0 / 1024, width: 1455.0 / 1536, height: 928.0 / 1024))
                            .scaleEffect(x: layoutDirection == .rightToLeft ? -1 : 1)
                            .shadow(color: .black.opacity(0.2), radius: 2, x: 1, y: 2)
                            .opacity(amount)
                        VStack(spacing: 11 * typeScale) {
                            Image(systemName: designIcon(space))
                                .font(.system(size: 23 * typeScale, weight: .regular))
                            Text(designTitle(space))
                                .font(.system(size: 16 * typeScale, weight: .medium))
                                .fixedSize()
                        }
                        .foregroundStyle(colorScheme == .dark ? .white.opacity(0.85) : Color(red: 0.34, green: 0.29, blue: 0.26))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .opacity(1 - amount)
                        Text(designTitle(space))
                            .font(.system(size: 34 * typeScale, weight: .medium))
                            .foregroundStyle(.white.opacity(0.93))
                            .fixedSize()
                            .padding(.leading, 17 * typeScale)
                            .padding(.top, 18 * typeScale)
                            .frame(width: cardWidth, height: height, alignment: .topLeading)
                            .opacity(amount)
                    }
                    .frame(width: cardWidth, height: height)
                    .offset(y: -3 * amount)
                }
                .zIndex(Double(amount))
            }
        }
        .padding(.horizontal, 3)
        .padding(.top, 3)
        .background {
            HomeFilterMaterialImage("HomeFilterPaper")
                .brightness(-0.12)
                .shadow(color: .black.opacity(0.22), radius: 10, y: 8)
        }
        .overlay(alignment: .bottom) {
            HomeFilterMaterialImage("HomeFilterPaper")
                .brightness(-0.20)
                .frame(height: 6)
                .overlay(alignment: .top) { Color.white.opacity(0.8).frame(height: 1) }
                .offset(y: 4)
                .allowsHitTesting(false)
        }
    }

}

private struct HomeFilterMaterialImage: View {
    let name: String
    let crop: CGRect

    init(_ name: String, crop: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) {
        self.name = name
        self.crop = crop
    }

    var body: some View {
        GeometryReader { geometry in
            Image(name)
                .resizable()
                .interpolation(.high)
                .frame(width: geometry.size.width / crop.width, height: geometry.size.height / crop.height)
                .offset(x: -geometry.size.width * crop.minX / crop.width,
                        y: -geometry.size.height * crop.minY / crop.height)
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

#if os(iOS)
struct HomeFilterBarStylePicker: View {
    @Binding var selection: HomeFilterBarAppearance

    var body: some View {
        List {
            ForEach(HomeFilterBarAppearance.allCases, id: \.self) { style in
                Button {
                    selection = style
                } label: {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(style.titleKey).font(.subheadline.weight(.semibold))
                            Spacer()
                            if selection == style {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                            }
                        }
                        HomeSpaceFilterBar(spaces: HomeFilterBarConfiguration.defaultOrder,
                                           selection: .music, appearance: style) { _ in }
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                            .padding(.horizontal, -16)
                    }
                    .foregroundStyle(.primary)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == style ? .isSelected : [])
                .accessibilityIdentifier("home.filterBar.style.\(style.rawValue)")
            }
        }
        .environment(\.editMode, .constant(.inactive))
        .navigationTitle("home_filter_bar_appearance")
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif

private struct ClassicHomeSpaceFilterBar: View {
    let spaces: [ListeningSpace]
    let selection: ListeningSpace?
    var labelStyle: HomeFilterBarLabelStyle = .automatic
    let onSelect: (ListeningSpace) -> Void

    /// 两侧留白与胶囊间距。
    private static let inset: CGFloat = 16
    private static let spacing: CGFloat = 8

    /// 这一排能用的宽度(已扣掉两侧留白)。
    @State private var availableWidth: CGFloat?
    /// 每颗胶囊各写法、选中与否时不折行的宽度。
    @State private var chipWidths: [ChipMeasureKey: CGFloat] = [:]

    private struct ChipMeasureKey: Hashable {
        let space: ListeningSpace
        let content: HomeFilterBarChipContent
        let isSelected: Bool
    }

    private var contents: [ListeningSpace: HomeFilterBarChipContent] {
        let widths = chipWidths
        return HomeFilterBarFitPolicy.contents(
            spaces: spaces,
            selection: selection,
            labelStyle: labelStyle,
            availableWidth: availableWidth.map { Double($0) },
            spacing: Double(Self.spacing)
        ) { space, content, isSelected in
            widths[ChipMeasureKey(space: space, content: content, isSelected: isSelected)].map { Double($0) }
        }
    }

    var body: some View {
        let contents = contents
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: Self.spacing) {
                    ForEach(spaces, id: \.self) { space in
                        chip(space, content: contents[space] ?? .iconAndTitle)
                            .id(space)
                    }
                }
            }
            .contentMargins(.horizontal, Self.inset, for: .scrollContent)
            .scrollIndicators(.hidden)
            // 放得下时不让这一排被拖得来回弹。
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .onGeometryChange(for: CGFloat.self) { geometry in
                geometry.size.width
            } action: { width in
                availableWidth = max(width - Self.inset * 2, 0)
            }
            .onChange(of: selection) { _, selection in
                // 一排挤不下在滚动时,选中后变宽的那颗整个露出来(✕ 不落在屏幕外)。
                guard let selection else { return }
                pmWithAnimation(.selection) {
                    proxy.scrollTo(selection)
                }
            }
        }
        .padding(.top, 2)
        .background {
            if labelStyle == .automatic {
                measurements
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// 不显示的一层:每颗胶囊各写法、选中与否时不折行的宽度。
    private var measurements: some View {
        ZStack {
            ForEach(spaces, id: \.self) { space in
                ForEach(HomeFilterBarChipContent.allCases, id: \.self) { content in
                    ForEach([false, true], id: \.self) { isSelected in
                        chipFace(space, content: content, isSelected: isSelected)
                            .fixedSize()
                            .onGeometryChange(for: CGFloat.self) { geometry in
                                geometry.size.width
                            } action: { width in
                                chipWidths[ChipMeasureKey(space: space, content: content, isSelected: isSelected)] = width
                            }
                    }
                }
            }
        }
        .hidden()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func chip(_ space: ListeningSpace, content: HomeFilterBarChipContent) -> some View {
        let isSelected = space == selection
        return Button {
            onSelect(space)
        } label: {
            chipFace(space, content: content, isSelected: isSelected)
        }
        .buttonStyle(HomeSpaceChipButtonStyle())
        // 只留图标时旁白照样念出名字。
        .accessibilityLabel(Text(space.titleKey))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(isSelected ? String(localized: "home_filter_clear_hint") : "")
        .accessibilityIdentifier("home.spaceFilter.\(space.rawValue)")
    }

    private func chipFace(
        _ space: ListeningSpace,
        content: HomeFilterBarChipContent,
        isSelected: Bool
    ) -> some View {
        HStack(spacing: 0) {
            if content.showsIcon {
                Image(systemName: space.systemImage)
                    .symbolVariant(isSelected ? .fill : .none)
                    .font(.footnote.weight(.semibold))
                    .transition(.scale.combined(with: .opacity))
            }
            if content.showsTitle {
                Text(space.titleKey)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.leading, content.showsIcon ? 6 : 0)
                    .transition(.opacity)
            }
            if isSelected {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .padding(.leading, 5)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .font(.subheadline.weight(isSelected ? .semibold : .medium))
        .foregroundStyle(isSelected ? AnyShapeStyle(.text(on: space.tint)) : AnyShapeStyle(.primary))
        .padding(.horizontal, 14)
        .frame(minHeight: 36)
        .background {
            Capsule()
                .fill(isSelected ? AnyShapeStyle(space.tint.gradient) : AnyShapeStyle(.quaternary.opacity(0.7)))
        }
        .contentShape(Capsule())
    }
}

private struct HomeSpaceChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.58 : 1)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(PMMotion.press.animation, value: configuration.isPressed)
    }
}
