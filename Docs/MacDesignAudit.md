# Primuse macOS Design Audit

Source of truth: `design/猿音/main.jsx` and `design/猿音/scenes/*.jsx`.
Scope: macOS only. tvOS artboards are intentionally out of scope for now.

## Main Window

| Design artboard | Implementation | Status | Notes |
| --- | --- | --- | --- |
| `home` / HOME-01..11 | `Primuse/Views/Mac/MacHomeView.swift` | Implemented | Dashboard sections, source health, pipeline, recent content use PM colors. |
| `library-songs` / LIB-01 | `Primuse/Views/Library/SongListView.swift` | Implemented | macOS table-style list exists; keep checking header/table spacing during visual QA. |
| `library-albums` / LIB-02 | `Primuse/Views/Library/AlbumGridView.swift`, `AlbumDetailView.swift` | Implemented | Grid and detail use macOS header/cards. |
| `library-artists` / LIB-03 | `Primuse/Views/Library/ArtistListView.swift`, `ArtistDetailView.swift` | Implemented | Artist list/detail use PM surfaces. |
| `library-playlist` / LIB-04/05 | `PlaylistListView.swift`, `PlaylistDetailView.swift`, `SmartPlaylistDetailView.swift`, `SmartPlaylistEditorView.swift` | Implemented | Smart playlist editor and reorder sheet now use PM-style macOS panels. |
| `search` / S-01..05 | `Primuse/Views/Search/SearchView.swift` | Implemented | macOS search route and grouped results use the PM shell/search field. |
| App shell / titlebar/sidebar/bottom bar | `MacContentView.swift`, `PMTitleBar.swift`, `MacSidebar.swift`, `MacBottomBar.swift` | Implemented | Titlebar, route reset, sidebar, bottom controls are custom; continue visual pass for top spacing. |

## Now Playing

| Design artboard | Implementation | Status | Notes |
| --- | --- | --- | --- |
| NP-Bar | `MacBottomBar.swift` | Implemented | Bottom transport, scrubber, queue, output, cast, mini/fullscreen buttons. |
| `np-now` | `MacNowPlayingView.swift` | Implemented | Main-window slide-in player with large lyrics. |
| `np-fullscreen` | `PrimuseApp.swift` + `MacNowPlayingView.swift` | Implemented | Fullscreen command expands Now Playing. |
| `np-external` | `ExternalDisplayNowPlayingView.swift` | Implemented | Second-screen label, large cover, ambient background, and large lyric stack match `fullscreen.jsx`. |

## Floating Windows

| Design artboard | Implementation | Status | Notes |
| --- | --- | --- | --- |
| `mp-collapsed` | `MiniPlayerWindowController.swift`, `MacMiniPlayerView.swift` | Implemented | NSPanel mini player exists. |
| `mp-lyrics` | `MacMiniPlayerView.swift` | Implemented | Expanded lyric tab exists. |
| `mp-queue` | `MacMiniPlayerView.swift` | Implemented | Expanded queue tab exists. |
| `menubar` | `MacMenuBarController.swift`, `MenuBarPlayerView.swift` | Implemented | Menu bar popover exists. |
| `dl-double` | `DesktopLyricsWindowController.swift`, `DesktopLyricsView.swift` | Implemented | Double-line desktop lyrics exists. |
| `dl-single` | `DesktopLyricsView.swift` | Implemented | Single-line mode exists. |
| `dl-vertical` | `DesktopLyricsView.swift` | Implemented | Vertical mode exists. |
| `dl-locked` | `DesktopLyricsView.swift`, app commands | Implemented | Lock/unlock and click-through path exists. |

## Sources

| Design artboard | Implementation | Status | Notes |
| --- | --- | --- | --- |
| `sources-main` / SRC-23/24/25/28 | `MacSourcesView.swift` | Implemented | Source overview uses PM cards. |
| `sources-add` / SRC-01 | `SourceTypeSelectionView.swift`, `AddSourceView.swift` | Implemented | Add-source sheet has macOS styling. |
| `sources-browse` / SRC-21 | `BrowserChrome.swift`, source browser views | Implemented | Browser chrome present; protocol-specific rows need spot checks. |
| `sources-oauth` / SRC-16/22 | `MacOAuthBridge`, `AddSourceView.swift` | Implemented | macOS OAuth returns through URL scheme. |

## Settings

| Design artboard | Implementation | Status | Notes |
| --- | --- | --- | --- |
| `set-playback` / ST-01 | `MacSettingsView.swift` / `MacSTPlaybackView` | Implemented | Custom Settings scene, no system Form. |
| `set-eq` / ST-02 | `MacSTEqualizerView` | Implemented | 10-band EQ and preset chips. |
| `set-fx` / ST-03 | `MacSTEffectsView` | Implemented | Effects chain rows. |
| `set-scrape` / ST-04 | `MacSTScrapingView` | Implemented | Real scraper config, order, import, batch actions. |
| `set-lyrics` / ST-05 | `MacSTLyricsView` | Implemented | Translation and display rows. |
| `set-apple` / ST-06 | `MacSTAppleMusicView` | Implemented | Account and library sync rows. |
| `set-widget` / ST-07 | `MacSTWidgetView` | Implemented | Widget catalog and preview rows. |
| `set-cloud` / ST-08 | `MacSTCloudView` | Implemented | Real CloudKit state and family sharing actions. |
| `set-theme` / ST-12 | `MacSTThemeView` | Implemented | Appearance, accent, icon, material controls. |
| `set-deleted` / ST-09 | `MacSTDeletedView` | Implemented | Recently deleted PM rows. |
| `set-ssl` / ST-10 | `MacSTSSLView` | Implemented | Trusted domains add/remove sheet. |
| `set-about` / ST-11 | `MacSTAboutView` | Implemented | About, version, licenses. |

## Stats

| Design artboard | Implementation | Status | Notes |
| --- | --- | --- | --- |
| `stats-main` | `ListeningStatsView.swift` | Implemented | macOS cards, range chips, heatmap, ranking. |
| `yearly` | `YearlyReportView.swift` | Implemented | macOS uses the wide Wrapped story strip from `yearly.jsx`; iOS story pager remains separate. |

## Utilities

| Design artboard | Implementation | Status | Notes |
| --- | --- | --- | --- |
| `scrape` / META-07 | `ScrapeWindowController.swift`, `ScrapeOptionsView.swift` | Implemented | Independent macOS window exists; nested advanced forms need spot checks. |
| `queue-panel` / P-11/13 | `MacQueuePanel.swift` | Implemented | Side panel custom UI exists. |
| `more-menu` | `PlayerMoreMenu.swift` | Implemented | Custom PM popover now includes tag editor, similar songs, sleep timer, album/artist deep links, scrobble route, and playback settings. |
| `add-playlist` / P-27 | `NowPlayingView.swift` / `AddToPlaylistSheet` | Implemented | macOS-specific sheet exists. |
| `output-picker` / P-21 | `AudioOutputPickerView.swift` | Implemented | Custom popover exists. |
| `dlna-cast` / CAST-01 | `NowPlayingView.swift` / `CastDevicePickerSheet` | Implemented | macOS now uses a CAST-01 PM panel instead of List/NavigationStack. |
| `sleep-timer` / P-14 | `PlayerMoreMenu.swift`, `NowPlayingView.swift` | Implemented | macOS More Menu now uses a PM popover instead of confirmation dialog. |
| `song-info` / P-29 | `NowPlayingView.swift` / `SongInfoSheet` | Implemented | macOS-specific info sheet exists. |
| `tag-editor` / LIB-08 | `TagEditorView.swift` | Implemented | macOS editor panel exists. |
| `playlist-import` / PL-06 | `PlaylistImportView.swift` | Implemented | macOS import panel exists. |
| `scrobble` / SCROB-* | `ScrobbleSettingsView.swift` | Implemented | macOS panel exists. |
| Playlist reorder | `PlaylistDetailView.swift` / `PlaylistReorderSheet` | Implemented | Active macOS utility now uses a PM panel with explicit move controls. |

## Widgets

| Design artboard | Implementation | Status | Notes |
| --- | --- | --- | --- |
| `widget-gallery` | `MacSettingsView.swift` / `MacSTWidgetView`, Widget extension | Implemented | ST-07 now renders true-size small/medium/large gallery previews inside settings; extension-backed Now Playing/QuickAccess remain the real WidgetKit surfaces. |
| `widget-desktop` | `MacSettingsView.swift` / `MacSTWidgetView`, Widget extension | Implemented | Desktop-widget context is represented through true-size previews and WidgetKit sync controls. |

## Onboarding

| Design artboard | Implementation | Status | Notes |
| --- | --- | --- | --- |
| `onb-1` | `OnboardingView.swift` | Implemented | macOS now uses the dark glass welcome page from `onboarding.jsx`. |
| `onb-2` | `OnboardingView.swift` | Implemented | Protocol overview uses the two-column PM glass card layout. |
| `onb-3` | `OnboardingView.swift`, `AddSourceView.swift` | Implemented | First-source preview and completion handoff are macOS-specific. |

## Current Fix Queue

1. Visual QA with fresh light/dark screenshots after the current build, focusing on titlebar/sidebar/bottom color continuity.
2. Keep WidgetKit extension scope explicit: ST-07 previews all design variants, while the shipped extension currently exposes Now Playing and QuickAccess widgets.
