#if os(tvOS)
import SwiftUI
import PrimuseKit

/// tvOS app 入口 — 注入跟 iOS/macOS 共享的核心服务 (PrimuseKit 的 AppServices.shared),
/// 然后渲染 TVRoot。后端 (DB / scan / sync) 跟 iOS 共用; UI 是 tvOS 专属。
@main
struct PrimuseTVApp: App {
    @State private var playerService = AppServices.shared.playerService
    @State private var musicLibrary = AppServices.shared.musicLibrary
    @State private var sourcesStore = AppServices.shared.sourcesStore
    @State private var sourceManager = AppServices.shared.sourceManager
    @State private var themeService = AppServices.shared.themeService
    @State private var scanService = AppServices.shared.scanService
    @State private var metadataBackfill = AppServices.shared.metadataBackfill
    @State private var appleMusic = AppServices.shared.appleMusic
    @State private var appleMusicLibrary = AppServices.shared.appleMusicLibrary
    @State private var dlnaRenderer = AppServices.shared.dlnaRenderer

    var body: some Scene {
        WindowGroup {
            TVRoot()
                .environment(playerService)
                .environment(playerService.audioEngine)
                .environment(musicLibrary)
                .environment(sourcesStore)
                .environment(sourceManager)
                .environment(themeService)
                .environment(scanService)
                .environment(metadataBackfill)
                .environment(appleMusic)
                .environment(appleMusicLibrary)
                .environment(dlnaRenderer)
                .preferredColorScheme(.dark)
                .tint(TVColor.brand)
        }
    }
}
#endif
