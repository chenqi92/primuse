import SwiftUI

// MARK: - 通用目录浏览器外壳
//
// ConnectorDirectoryBrowserView / NFSBrowserView / UPnPBrowserView /
// MediaServerBrowserView 共用的 sheet chrome——breadcrumb、底部 bar、
// list 样式、frame 限制、toolbar 快捷键。各自的业务差异(path 解析、
// connector 类型)留在原 view 里;这里只统一视觉。

extension View {
    /// 目录浏览器统一的 list 样式:macOS inset(交替行背景),iOS plain。
    func directoryBrowserListStyle() -> some View {
        #if os(macOS)
        self.listStyle(.inset(alternatesRowBackgrounds: true))
        #else
        self.listStyle(.plain)
        #endif
    }

    /// macOS 上给目录浏览器 sheet 加合理最小尺寸 + Done/Cancel 键盘快捷键。
    /// iOS 不需要 frame,toolbar 已由 caller 定义,这里就只在 macOS 加一层。
    func directoryBrowserSheetFrame() -> some View {
        #if os(macOS)
        self.frame(minWidth: 560, idealWidth: 640, minHeight: 480, idealHeight: 600)
        #else
        self
        #endif
    }
}

// MARK: - Breadcrumb

struct DirectoryBreadcrumb: View {
    struct Segment {
        let path: String
        let title: String
    }

    let segments: [Segment]
    let onSelect: (Int) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.tertiary)
                        }

                        let isCurrent = index == segments.count - 1
                        Button { onSelect(index) } label: {
                            Text(segment.title)
                                #if os(macOS)
                                .font(.system(size: 12))
                                .fontWeight(isCurrent ? .semibold : .regular)
                                .foregroundStyle(isCurrent ? Color.primary : Color.secondary)
                                #else
                                .font(.caption)
                                .fontWeight(isCurrent ? .semibold : .regular)
                                .foregroundStyle(isCurrent ? Color.primary : Color.accentColor)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 4)
                                #endif
                        }
                        .buttonStyle(.plain)
                        .disabled(isCurrent)
                        .id(index)
                    }
                    Spacer(minLength: 0)
                }
                #if os(macOS)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                #else
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                #endif
            }
            .onChange(of: segments.count) { _, _ in
                withAnimation { proxy.scrollTo(segments.count - 1, anchor: .trailing) }
            }
        }
        #if os(macOS)
        .background(.regularMaterial)
        #else
        .background(.bar)
        #endif
    }
}

// MARK: - Bottom bar

struct BrowserBottomBar: View {
    let selectedCount: Int
    let idleIcon: String
    let onClearAll: () -> Void

    init(
        selectedCount: Int,
        idleIcon: String = "folder.badge.questionmark",
        onClearAll: @escaping () -> Void
    ) {
        self.selectedCount = selectedCount
        self.idleIcon = idleIcon
        self.onClearAll = onClearAll
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                if selectedCount == 0 {
                    #if os(macOS)
                    Image(systemName: idleIcon).foregroundStyle(.secondary)
                    Text("no_dirs_selected")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    #else
                    Label("no_dirs_selected", systemImage: idleIcon)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    #endif
                } else {
                    #if os(macOS)
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                    Text("\(selectedCount) \(String(localized: "directories_selected"))")
                        .font(.system(size: 12))
                        .foregroundStyle(.primary)
                    Spacer()
                    Button("clear_all", action: onClearAll)
                        .controlSize(.small)
                    #else
                    Label(
                        "\(selectedCount) \(String(localized: "directories_selected"))",
                        systemImage: "checkmark.circle.fill"
                    )
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(Color.accentColor)
                    Spacer()
                    Button("clear_all", action: onClearAll)
                        .font(.caption)
                    #endif
                }
                Spacer()
            }
            #if os(macOS)
            .padding(.horizontal, 16).padding(.vertical, 8)
            #else
            .padding(.horizontal, 16).padding(.vertical, 10)
            #endif
        }
        #if os(macOS)
        .background(.regularMaterial)
        #else
        .background(.bar)
        #endif
    }
}

// MARK: - Toolbar

/// 目录浏览器顶端 cancel/done toolbar item。macOS 上自动绑 Esc/Return。
struct DirectoryBrowserToolbar: ToolbarContent {
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("done", action: onConfirm)
                .fontWeight(.semibold)
                .keyboardShortcut(.defaultAction)
        }
    }
}
