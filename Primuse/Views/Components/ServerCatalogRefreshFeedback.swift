import PrimuseKit
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct TingReaderProgressSyncControls: View {
    let source: MusicSource

    var body: some View {
        let sync = AppServices.shared.tingReaderProgressSync
        VStack(alignment: .leading, spacing: 9) {
            Toggle(PMString("ting_reader_progress_auto_sync"), isOn: Binding(
                get: { sync.isEnabled(for: source.id) },
                set: { enabled in
                    sync.setEnabled(enabled, for: source.id)
                    if enabled { Task { await sync.refresh(sourceID: source.id) } }
                }
            ))
            .toggleStyle(.switch)
            HStack {
                Button(PMString("ting_reader_progress_sync_now")) {
                    Task { await sync.refresh(sourceID: source.id, manual: true) }
                }
                .disabled(sync.refreshingSourceIDs.contains(source.id))
                if sync.refreshingSourceIDs.contains(source.id) {
                    ProgressView().controlSize(.small)
                }
            }
            if sync.failedSourceIDs.contains(source.id) {
                Text(verbatim: PMString("ting_reader_progress_sync_failed"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
        .padding(10)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .disabled(!source.isEnabled)
    }
}

extension View {
    /// The one-line result of a refresh the person asked for — what the check
    /// found, then what the refresh it started brought in. Mounted once at the
    /// app root so it outlives the page that asked.
    func serverCatalogRefreshFeedback() -> some View {
        modifier(ServerCatalogRefreshFeedbackModifier())
    }

    /// Pull to refresh that asks every server source whether its catalogue
    /// changed, and refreshes the ones that did. `alsoRefresh` runs first for
    /// pages that already had a pull of their own. The gesture is only offered
    /// while some source can be checked; the source list is loaded before the
    /// first frame, so this does not flip during launch.
    func serverCatalogPullToRefresh(
        isEnabled: Bool = true,
        shouldRefresh: (@MainActor () -> Bool)? = nil,
        alsoRefresh: (@MainActor () async -> Void)? = nil
    ) -> some View {
        modifier(ServerCatalogPullToRefreshModifier(
            isEnabled: isEnabled,
            alsoRefresh: alsoRefresh,
            shouldRefresh: shouldRefresh
        ))
    }

    func homePullToOverview(
        state: HomePullToOverviewState,
        isEnabled: Bool,
        onReturn: @escaping @MainActor () -> Void
    ) -> some View {
        modifier(HomePullToOverviewModifier(state: state, isEnabled: isEnabled, onReturn: onReturn))
    }
}

private struct ServerCatalogPullToRefreshModifier: ViewModifier {
    let isEnabled: Bool
    let alsoRefresh: (@MainActor () async -> Void)?
    let shouldRefresh: (@MainActor () -> Bool)?

    func body(content: Content) -> some View {
        let coordinator = AppServices.shared.serverCatalogAutoRefresh
        let progressSync = AppServices.shared.tingReaderProgressSync
        if isEnabled, coordinator.hasCheckableSources || progressSync.hasSources {
            content.refreshable {
                guard await shouldRefresh?() ?? true else { return }
                await alsoRefresh?()
                await progressSync.refresh(manual: true)
                await coordinator.refreshNow()
            }
        } else if let alsoRefresh {
            content.refreshable {
                guard await shouldRefresh?() ?? true else { return }
                await alsoRefresh()
            }
        } else {
            content
        }
    }
}

@Observable @MainActor
final class HomePullToOverviewState {
    private(set) var holdStartedAt: Date?
    @ObservationIgnored private var policy = HomeOverviewPullPolicy()
    @ObservationIgnored private var holdTask: Task<Void, Never>?
    @ObservationIgnored private var pullDistance: Double = 0
    @ObservationIgnored private var isInteracting = false

    func shouldRefresh() -> Bool { !policy.suppressesRefresh }

    fileprivate func update(
        distance: Double? = nil,
        interacting: Bool? = nil,
        enabled: Bool,
        onReturn: @escaping @MainActor () -> Void
    ) {
        if let distance { pullDistance = distance }
        if let interacting { isInteracting = interacting }
        let triggered = policy.update(
            pullDistance: pullDistance,
            isInteracting: isInteracting,
            isEnabled: enabled,
            now: ProcessInfo.processInfo.systemUptime
        )
        if triggered {
            holdTask?.cancel()
            holdTask = nil
            holdStartedAt = nil
            #if os(iOS)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            #endif
            onReturn()
        } else if policy.holdStartedAt == nil {
            holdTask?.cancel()
            holdTask = nil
            holdStartedAt = nil
        } else if holdTask == nil {
            holdStartedAt = Date()
            holdTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(HomeOverviewPullPolicy.holdDuration)) }
                catch { return }
                guard let self else { return }
                self.update(enabled: enabled, onReturn: onReturn)
            }
        }
    }

    fileprivate func cancel() {
        holdTask?.cancel()
        holdTask = nil
        holdStartedAt = nil
        isInteracting = false
        policy.update(pullDistance: 0, isInteracting: false, isEnabled: false,
                      now: ProcessInfo.processInfo.systemUptime)
    }
}

private struct HomePullToOverviewModifier: ViewModifier {
    let state: HomePullToOverviewState
    let isEnabled: Bool
    let onReturn: @MainActor () -> Void

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: Double.self) { geometry in
                Double(max(0, -geometry.contentOffset.y - geometry.contentInsets.top))
            } action: { _, distance in
                state.update(distance: distance, enabled: isEnabled, onReturn: onReturn)
            }
            .onScrollPhaseChange { _, phase in
                state.update(interacting: phase == .interacting, enabled: isEnabled, onReturn: onReturn)
            }
            .overlay(alignment: .top) {
                if let startedAt = state.holdStartedAt {
                    HomeOverviewPullProgress(startedAt: startedAt)
                        .padding(.top, 10)
                        .allowsHitTesting(false)
                }
            }
            .onChange(of: isEnabled) { _, enabled in
                if !enabled { state.cancel() }
            }
            .onDisappear { state.cancel() }
    }
}

private struct HomeOverviewPullProgress: View {
    let startedAt: Date

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            let progress = min(max(timeline.date.timeIntervalSince(startedAt) / HomeOverviewPullPolicy.holdDuration, 0), 1)
            ZStack {
                Circle().stroke(.secondary.opacity(0.22), lineWidth: 2.5)
                Circle().trim(from: 0, to: progress)
                    .stroke(.primary, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 24, height: 24)
            .padding(9)
            .background(.regularMaterial, in: Circle())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("home_title"))
        .accessibilityIdentifier("home.returnOverview.progress")
    }
}

private struct ServerCatalogRefreshFeedbackModifier: ViewModifier {
    func body(content: Content) -> some View {
        let feedback = AppServices.shared.serverCatalogAutoRefresh.feedback
        content
            .overlay(alignment: .top) {
                if let feedback {
                    HStack(spacing: 8) {
                        Image(systemName: Self.symbol(for: feedback.tone))
                            .foregroundStyle(Self.tint(for: feedback.tone))
                        Text(verbatim: feedback.message)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    .font(.footnote)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: .capsule)
                    .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.16), radius: 10, y: 3)
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .id(feedback.id)
                    .pmSlideTransition(edge: .top)
                    .allowsHitTesting(false)
                }
            }
            .pmAnimation(.list, value: feedback)
            .onChange(of: feedback?.id) { _, _ in
                guard let feedback else { return }
                Self.announce(feedback.message)
            }
    }

    private static func symbol(
        for tone: ServerCatalogAutoRefreshCoordinator.Feedback.Tone
    ) -> String {
        switch tone {
        case .success: "checkmark.circle.fill"
        case .info: "arrow.triangle.2.circlepath"
        case .warning: "exclamationmark.triangle.fill"
        }
    }

    private static func tint(
        for tone: ServerCatalogAutoRefreshCoordinator.Feedback.Tone
    ) -> Color {
        switch tone {
        case .success: .green
        case .info: .accentColor
        case .warning: .orange
        }
    }

    private static func announce(_ message: String) {
        #if os(iOS)
        UIAccessibility.post(notification: .announcement, argument: message)
        #elseif os(macOS)
        guard let application = NSApp else { return }
        NSAccessibility.post(
            element: application,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
        #endif
    }
}
