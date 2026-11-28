import Foundation
import SwiftUI

@MainActor
enum SearchHistoryStore {
    static let key = CloudKVSKey.recentSearches
    static let didChangeNotification = Notification.Name("primuse.searchHistory.didChange")
    private static let limit = 12

    static func load() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func record(_ query: String) {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return }

        var queries = load()
        queries.removeAll { $0.caseInsensitiveCompare(trimmedQuery) == .orderedSame }
        queries.insert(trimmedQuery, at: 0)
        save(Array(queries.prefix(limit)))
    }

    static func save(_ queries: [String]) {
        UserDefaults.standard.set(queries, forKey: key)
        CloudKVSSync.shared.markChanged(key: key)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
}

#if os(macOS)
struct MacSearchFlowLayout: Layout {
    var spacing: CGFloat = 8
    var rowSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 480
        let rows = rows(in: maxWidth, subviews: subviews)
        return CGSize(width: maxWidth, height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + rowSpacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }

    private func rows(in maxWidth: CGFloat, subviews: Subviews) -> (height: CGFloat, count: Int) {
        guard subviews.isEmpty == false else { return (0, 0) }

        var x: CGFloat = 0
        var height: CGFloat = 0
        var lineHeight: CGFloat = 0
        var count = 1

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                height += lineHeight + rowSpacing
                x = 0
                lineHeight = 0
                count += 1
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }

        height += lineHeight
        return (height, count)
    }
}
#endif
