import AppKit
import SwiftUI
import PrimuseKit

// Compile the production view with in-memory services so this regression check
// never launches the app, loads personal history, or acquires desktop input.
@MainActor @Observable final class SourcesStore {
    var sources: [MusicSource] = []
}
struct ServerListeningStatsView: View {
    let source: MusicSource
    var sourceSelection: AnyView?
    var body: some View { EmptyView() }
}
extension View {
    func settingsAnchor(_ value: String) -> some View { self }
}
func plog(_ value: String) {}
enum PMColor {
    static let bg = Color.gray.opacity(0.1)
    static let bgElev = Color.white
    static let brand = Color.orange
    static let text = Color.primary
    static let textMuted = Color.secondary
    static let textFaint = Color.gray
    static let card = Color.white
    static let cardBorder = Color.gray.opacity(0.1)
    static let glassBtn = Color.gray.opacity(0.1)
    static let divider = Color.gray.opacity(0.1)
}

@MainActor @Observable final class PlayHistoryStore {
    static let shared = PlayHistoryStore()
    var entries: [Entry] = []
    var revision = 0
    func clearAll() { entries = []; revision += 1 }
    struct Entry: Sendable {
        let songID: String
        let songTitle: String
        let artistName: String
        let albumTitle: String
        let playedAt: Date
        let listenedSec: Double
    }
    enum Range: String, CaseIterable, Identifiable, Sendable {
        case week, month, year, all
        var id: String { rawValue }
        var localizationKey: String { "stats_range_\(rawValue)" }
        func statisticsStartDate(now: Date, calendar: Calendar) -> Date {
            if self == .all { return .distantPast }
            let component: Calendar.Component = self == .year ? .year : self == .month ? .month : .weekOfYear
            return calendar.dateInterval(of: component, for: now)!.start
        }
    }
    struct Summary: Sendable {
        let totalPlays: Int
        let totalSec: Double
        let activeDays: Int
        let uniqueSongs: Int
    }
    struct RankedItem: Sendable, Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let playCount: Int
        let totalSec: Double
    }
    nonisolated static func summary(for entries: [Entry], calendar: Calendar) -> Summary {
        Summary(totalPlays: entries.count, totalSec: Double(entries.count * 180),
                activeDays: Set(entries.map { calendar.startOfDay(for: $0.playedAt) }).count,
                uniqueSongs: Set(entries.map(\.songID)).count)
    }
    nonisolated static func rankedItems(from entries: [Entry], category: HomeListeningCategory, limit: Int) -> [RankedItem] {
        (0..<limit).map { .init(id: "\($0)", title: "歌曲 \($0)", subtitle: "歌手", playCount: 20 - $0, totalSec: 180) }
    }
}
extension Notification.Name {
    static let primuseListeningStatsDidChange = Notification.Name("primuse.listeningStatsDidChange")
}

@main struct ListeningStatsRenderingSmoke {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let calendar = ListeningCalendar.current
        let now = Date()
        let entries: [PlayHistoryStore.Entry] = (0..<5000).map { i in
            .init(songID: "\(i % 1000)", songTitle: "歌曲 \(i)", artistName: "歌手", albumTitle: "专辑",
                  playedAt: now.addingTimeInterval(-Double(i * 3600)), listenedSec: 180)
        }
        PlayHistoryStore.shared.entries = entries
        checkInitialPresentation()
        let snapshot = ListeningStatsView.makeStatsSnapshot(entries: entries, range: .year, displayYear: nil, now: now, calendar: calendar)
        checkHeatmap(snapshot: snapshot)
        let request = ListeningStatsView.StatsSnapshotRequest(
            presentation: .init(range: .year, displayYear: nil, day: calendar.startOfDay(for: now),
                                localeIdentifier: calendar.locale?.identifier ?? Locale.current.identifier,
                                timeZoneIdentifier: calendar.timeZone.identifier), historyRevision: 0)
        checkFirstPublication(snapshot: snapshot, request: request)
        for iteration in 0..<4 {
            let model = ListeningStatsView.Model()
            if iteration > 0 {
                model.request = request
                model.snapshot = snapshot
            }
            let start = CFAbsoluteTimeGetCurrent()
            let host = NSHostingView(rootView: ListeningStatsView(model: model).environment(SourcesStore()))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            let layout = CFAbsoluteTimeGetCurrent() - start
            var longestStep: Double = 0
            for _ in 0..<30 {
                let tick = CFAbsoluteTimeGetCurrent()
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
                host.layoutSubtreeIfNeeded()
                longestStep = max(longestStep, CFAbsoluteTimeGetCurrent() - tick)
            }
            precondition(!window.isVisible && !window.isKeyWindow)
            precondition(model.snapshot != nil, "First load did not complete")
            print("iteration=\(iteration) cached=\(iteration > 0) initial_layout_ms=\(Int(layout * 1000)) longest_followup_ms=\(Int(longestStep * 1000))")
            precondition(layout < 0.5 && longestStep < 0.5, "Opening cached statistics blocked the main thread")
            for width in [640.0, 1440.0, 1000.0] {
                let tick = CFAbsoluteTimeGetCurrent()
                window.setContentSize(CGSize(width: width, height: 800))
                host.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
                host.layoutSubtreeIfNeeded()
                let elapsed = CFAbsoluteTimeGetCurrent() - tick
                print("resize_width=\(Int(width)) layout_ms=\(Int(elapsed * 1000))")
                precondition(elapsed < 0.5, "Resizing statistics blocked the main thread")
            }
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            var paintedSamples = 0
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 10) {
                for x in stride(from: 0, to: bitmap.pixelsWide, by: 10) {
                    if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                       color.redComponent > 0.8, color.greenComponent > 0.8, color.blueComponent > 0.8 {
                        paintedSamples += 1
                    }
                }
            }
            precondition(paintedSamples > 1000, "Offscreen content was not painted; timing a blank view is invalid")
            if CommandLine.arguments.count > 1 {
                let path = CommandLine.arguments[1] + ".\(iteration).png"
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            window.close()
        }
        print("Listening statistics rendering checks passed")
    }

    @MainActor private static func checkInitialPresentation() {
        let suiteName = "ListeningStatsRenderingSmoke.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let sources = SourcesStore()
        sources.sources = [MusicSource(id: "server", name: "Server", type: .navidrome)]
        defaults.set("server", forKey: "stats.selectedServerSourceID")

        for initialRange: PlayHistoryStore.Range? in [nil, .week, .month, .all] {
            let model = ListeningStatsView.Model()
            let host = NSHostingView(rootView: ListeningStatsView(
                initialRange: initialRange, initiallyShowsLocalHistory: true, model: model
            ).environment(sources).defaultAppStorage(defaults))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.close() }
            host.layoutSubtreeIfNeeded()
            let deadline = Date().addingTimeInterval(3)
            while model.snapshot == nil && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
                host.layoutSubtreeIfNeeded()
            }
            precondition(model.snapshot != nil, "Explicit local history must override the saved server source")
            precondition(model.request?.presentation.range == (initialRange ?? .year),
                         "The mounted statistics page must retain its requested initial range")
            precondition(defaults.string(forKey: "stats.selectedServerSourceID") == "server",
                         "A local-history link must preserve the user's saved server preference")
        }
        print("Statistics initial range and local-history override checks passed")
    }

    @MainActor private static func checkFirstPublication(
        snapshot: ListeningStatsView.StatsSnapshot, request: ListeningStatsView.StatsSnapshotRequest
    ) {
        let model = ListeningStatsView.Model()
        let changed = DispatchSemaphore(value: 0)
        withObservationTracking {
            precondition(model.visibleSnapshot(for: request.presentation) == nil)
        } onChange: {
            changed.signal()
        }
        model.request = request
        model.snapshot = snapshot
        precondition(changed.wait(timeout: .now()) == .success, "Publishing the first snapshot must invalidate the loading view")
        precondition(model.visibleSnapshot(for: request.presentation)?.summary.totalPlays == snapshot.summary.totalPlays)
        let otherRange = ListeningStatsView.StatsPresentationKey(
            range: .month, displayYear: nil, day: request.presentation.day,
            localeIdentifier: request.presentation.localeIdentifier, timeZoneIdentifier: request.presentation.timeZoneIdentifier)
        precondition(model.visibleSnapshot(for: otherRange) == nil, "A range change must not show the previous range's statistics")
    }

    @MainActor private static func checkHeatmap(snapshot: ListeningStatsView.StatsSnapshot) {
        let heatmap = snapshot.heatmap
        precondition(heatmap.cells.map(\.date) == snapshot.timeline.calendarDays.map(\.date))
        precondition(heatmap.cells.map(\.count) == snapshot.timeline.calendarDays.map(\.count))
        precondition(heatmap.monthLabels.compactMap { $0 }.count == 12)
        precondition(heatmap.weekdaySymbols.count == 7)
        precondition(heatmap.cells.filter(\.isFuture).allSatisfy { $0.tooltip.hasSuffix("\n—") })
        precondition(heatmap.cells.filter { !$0.isFuture }.allSatisfy { !$0.tooltip.hasSuffix("\n—") })
        for width in [540.0, 1000.0, 1440.0] {
            let geometry = ListeningStatsView.MacHeatmapGeometry(width: width, weekCount: heatmap.weekCount)
            precondition(geometry.cellIndex(at: .zero) == nil)
            precondition(geometry.cellIndex(at: CGPoint(x: width + 1, y: geometry.height + 1)) == nil)
            for index in heatmap.cells.indices {
                let rect = geometry.cellRect(at: index)
                precondition(geometry.cellIndex(at: CGPoint(x: rect.midX, y: rect.midY)) == index)
                precondition(geometry.cellIndex(at: CGPoint(x: rect.maxX + 1, y: rect.midY)) == nil)
                precondition(geometry.cellIndex(at: CGPoint(x: rect.midX, y: rect.maxY + 1)) == nil)
                precondition(rect.maxY <= geometry.height + 0.01 && rect.maxX <= width + 0.01)
            }
        }
    }
}
