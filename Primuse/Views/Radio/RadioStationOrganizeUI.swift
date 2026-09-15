import SwiftUI
import PrimuseKit

/// 建/改文件夹和标签都只需要一个名字，所以四种情形共用一个输入弹框。
enum RadioNamePrompt: Identifiable, Hashable {
    /// 新建文件夹，顺带把这些电台放进去(为空就只是建一个空文件夹)。
    case createFolder(assigning: [String])
    case renameFolder(String)
    /// 新建标签并贴到这些电台上。
    case createTag(assigning: [String])
    case renameTag(String)

    var id: String {
        switch self {
        case .createFolder: return "createFolder"
        case .renameFolder(let name): return "renameFolder:\(name)"
        case .createTag: return "createTag"
        case .renameTag(let name): return "renameTag:\(name)"
        }
    }

    var title: String {
        switch self {
        case .createFolder: return String(localized: "radio_folder_new")
        case .renameFolder: return String(localized: "radio_folder_rename")
        case .createTag: return String(localized: "radio_tag_new")
        case .renameTag: return String(localized: "radio_tag_rename")
        }
    }

    var fieldTitle: String {
        switch self {
        case .createFolder, .renameFolder: return String(localized: "radio_folder_name")
        case .createTag, .renameTag: return String(localized: "radio_tag_name")
        }
    }

    /// 重命名时把原名填进去 —— 用户多半只想改一两个字。
    var initialText: String {
        switch self {
        case .createFolder, .createTag: return ""
        case .renameFolder(let name), .renameTag(let name): return name
        }
    }
}

/// 电台列表的两种版式。封面版把台标放大成方格，适合台标齐全、靠图认台；
/// 列表版一行一个台，名字、正在播的曲目和地址都看得全。
enum RadioStationLayoutMode: String, CaseIterable, Identifiable {
    case cover
    case list

    var id: String { rawValue }

    var titleKey: String.LocalizationValue {
        switch self {
        case .cover: return "radio_layout_cover"
        case .list: return "radio_layout_list"
        }
    }

    var icon: String {
        switch self {
        case .cover: return "square.grid.2x2"
        case .list: return "list.bullet"
        }
    }

    /// 存进 `@AppStorage` 的键。iPhone 和 Mac 各记各的 —— 同一个人在手机上
    /// 想要封面墙，在桌面上想要信息密度高的列表，这很正常。
    static let storageKey = "radio.layoutMode"
}

/// 标签配色。颜色由标签名算出来(见 `RadioStationOrganization.paletteIndex`)，
/// 不落库也不让用户选 —— 同一个标签在每台设备上都是同一个颜色。
/// 用的是系统语义色，明暗两套外观各自有合适的对比度。
enum RadioTagPalette {
    static let colors: [Color] = [
        .blue, .purple, .pink, .orange, .teal, .indigo, .green, .brown,
    ]

    static func color(for tagName: String) -> Color {
        colors[RadioStationOrganization.paletteIndex(forTag: tagName, paletteSize: colors.count)]
    }
}

/// 筛选条上的一颗胶囊。选中态用 tint 填充，未选中态是一层淡底。
struct RadioFilterChip: View {
    let title: String
    let systemImage: String
    var count: Int? = nil
    let isSelected: Bool
    var tint: Color = .accentColor
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                if let count {
                    Text(verbatim: "\(count)")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .opacity(0.7)
                }
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                isSelected ? tint : Color.secondary.opacity(0.12),
                in: Capsule(style: .continuous)
            )
            .overlay {
                Capsule(style: .continuous)
                    .stroke(isSelected ? .clear : Color.secondary.opacity(0.18), lineWidth: 0.7)
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// 电台行/卡片上那一行「文件夹 + 标签」。都没有就整行不占位。
struct RadioStationOrganizeLabels: View {
    let station: RadioStation
    var maximumTags = 2

    private var folderName: String? { station.assignedFolderName }
    private var tagNames: [String] { station.assignedTagNames }

    var body: some View {
        if folderName != nil || !tagNames.isEmpty {
            HStack(spacing: 5) {
                if let folderName {
                    Label(folderName, systemImage: "folder.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                ForEach(tagNames.prefix(maximumTags), id: \.self) { tag in
                    Text(tag)
                        .font(.system(size: 10, weight: .semibold))
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RadioTagPalette.color(for: tag).opacity(0.16),
                            in: Capsule(style: .continuous)
                        )
                        .foregroundStyle(RadioTagPalette.color(for: tag))
                }

                if tagNames.count > maximumTags {
                    Text(verbatim: "+\(tagNames.count - maximumTags)")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}
