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
        alsoRefresh: (@MainActor () async -> Void)? = nil
    ) -> some View {
        modifier(ServerCatalogPullToRefreshModifier(
            isEnabled: isEnabled,
            alsoRefresh: alsoRefresh
        ))
    }
}

private struct ServerCatalogPullToRefreshModifier: ViewModifier {
    let isEnabled: Bool
    let alsoRefresh: (@MainActor () async -> Void)?

    func body(content: Content) -> some View {
        let coordinator = AppServices.shared.serverCatalogAutoRefresh
        let progressSync = AppServices.shared.tingReaderProgressSync
        if isEnabled, coordinator.hasCheckableSources || progressSync.hasSources {
            content.refreshable {
                await alsoRefresh?()
                await progressSync.refresh(manual: true)
                await coordinator.refreshNow()
            }
        } else if let alsoRefresh {
            content.refreshable {
                await alsoRefresh()
            }
        } else {
            content
        }
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
