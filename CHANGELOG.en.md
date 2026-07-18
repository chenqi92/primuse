<p align="right"><a href="CHANGELOG.md">中文</a> · <strong>English</strong></p>

# Changelog

---

## [1.7.0] (build 20) - 2026-07-18

This release starts at commit `4a8937f9` and focuses on large-library performance, the Home and Library experience, and cross-platform polish for iPhone, Mac, and Apple TV.

### Added

- **Customizable Home sections** — show, hide, and reorder Continue Listening, Quick Favorites, For You, My Playlists, Top Artists, Recently Added, and listening statistics
- **Quick Favorites and search** — pin albums, artists, or playlists; search while editing; and keep selected items together for faster removal
- **First-install feature tour** — introduces cloud drives, NAS, Apple Music, metadata scraping, cross-device playback, app icons, and Home customization
- **Complete release notes** — update prompts can expand and collapse long notes
- **GitHub feedback links** — open the repository or Issues from About for faster reporting and follow-up

### Changed

- **123 Cloud Drive OAuth callback** — replaced the HTTPS relay with the registered app deep link and added strict scheme, host, path, and state validation
- **Home and Library layout** — introduced clearer card hierarchies and redesigned Quick Favorites plus the Songs, Albums, Artists, and Playlists entry points
- **Music video playback** — videos are larger in portrait, automatically enter landscape fullscreen on iPhone, and restore the previous orientation on exit
- **Apple Music playlist visibility** — read-only mirror playlists are hidden while Apple Music sync or its source is disabled and return when re-enabled
- **macOS and tvOS adaptation** — improved localization, branding, Mac settings, Apple TV navigation, and remote playback controls

### Fixed

- **Song titles** — scanning and metadata backfill now prefer embedded titles instead of always showing filenames
- **Spotlight stability** — artwork thumbnails now use ImageIO off the main thread, fixing a UIKit rendering crash and reducing peak memory use
- **tvOS navigation and playback controls** — fixed filter focus, returning to the tab bar, global play/pause, and remote-command main-thread handling

### Performance

- **Scanning and tag reading** — batch library mutations, publish progress and checkpoints less often, and move large JSON encoding off the main thread
- **Home and source list** — cache Home snapshots, artwork tints, source-song groups, and remaining-backfill counts to avoid repeated work while scrolling
- **Large-library indexing** — batch artwork invalidations and checkpoint writes to reduce main-thread overhead during continuous 10K-track scans

---

## [1.6.4] (build 19) - 2026-07-14

### Added

- Added guest connections without an account and stronger port validation for SMB, S3, WebDAV, and other sources
- Added independent music-video formats with parsed and persisted MV duration
- Added server base paths, server-side metadata refresh, and scraped metadata write-back for Jellyfin, Emby, and Plex
- Added four app-icon themes

### Changed

- Improved scraper imports and cloud-storage connection flows
- Improved Chinese title repair and media-server scan matching

### Fixed

- Fixed Jellyfin and Emby authentication, scanning, and direct audio playback
- Fixed default ports after SSL changes, trusted-device token synchronization, and other connection issues

---

## [1.6.3] (build 18) - 2026-07-08

### Added

- Music sources without a direct playback URL can now stream MVs through progressive download
- MV streaming now supports on-demand caching, range requests, and playback fallback

### Fixed

- Fixed MV fullscreen state, cache cleanup, audio fallback, and cache-write race conditions
- Unified the macOS app product name to avoid duplicate names during builds and installation

---

## [1.6.2] (build 17) - 2026-06-15

### Added

- Added whole-folder local imports with duplicate-import and post-reinstall recovery handling
- Added third-party OAuth for 123 Cloud Drive with cover and lyrics write-back
- Added MV sidecar discovery, a dedicated playback mode, fullscreen controls, and local caching
- Added playlist shuffle and improved the UGREEN NAS API integration

### Changed

- Reworked source soft deletion, cache cleanup, and failed metadata-backfill retries
- Hardened cloud error-response detection, local scanning, token refresh, and cross-device deletion sync

### Fixed

- Fixed CarPlay crashes and stalls, audio-route crashes, and tab-limit crashes
- Fixed resume scans clearing playlists, incorrect scrobbles, previous-track crashes in shuffle, and crossfade deadlocks
- Fixed Plex/Subsonic scan interruptions, Synology metadata loss after rescans, Baidu token encoding, and cache filename collisions
- Fixed deleted sources being recreated by older cross-device snapshots

---

## [1.6.1] (build 15/16) - 2026-06-13

### Added

- Completed Apple TV source management, direct playback, on-device metadata scanning, search, lyrics, and localized UI
- Added scraped cover and lyrics write-back for OneDrive, Dropbox, Google Drive, Baidu Netdisk, and Aliyun Drive
- Added whole-source offline caching, custom equalizer presets, and a cellular-backfill prompt
- Added Traditional Chinese and completed German, French, Japanese, and Korean localization

### Changed

- Moved every platform and extension to one shared version source
- Added local credential entry, connection tests, whole-library playback, live progress, and fuller Siri Remote interaction on Apple TV
- Reworked word-level lyrics scrolling, line transitions, and highlighting

### Fixed

- Fixed OneDrive large-file interruptions, HTTP/3 throttling, and playback failures caused by extensionless cache files
- Fixed Apple TV library snapshot download, decompression, persistence, credential sync, and foreground timing
- Hardened TLS certificate pinning, SFTP host-key validation, log redaction, and OAuth-source deduplication
- Fixed crossfade truncation, decoder loops, sparse-cache loss, and Follow System Output failures
- Fixed issues across Widgets, Live Activities, Watch, tvOS, CarPlay, and large lists

---

## [1.6.0] (build 12-14) - 2026-06-06

### Added

- Formally added the Apple TV app with the real library, artwork, queue, search, and source management
- Added Apple TV playback for Synology, S3, Navidrome/Subsonic, Jellyfin, Emby, Plex, major cloud drives, and iPhone-relayed sources
- Added Push to Apple TV, local-network relay, and QR-based source setup
- Added Top Shelf, a full-bleed parallax icon, and Universal Purchase configuration
- Added Navidrome/Subsonic, 115 Cloud, and 123 Cloud Drive sources

### Changed

- Library snapshots, sources, and encrypted credentials now sync between iPhone, Mac, and Apple TV through iCloud
- Disabled sources no longer contribute songs to Library, statistics, or playback results

### Fixed

- Fixed Apple TV focus clipping, empty states, system-keyboard search, format detection, and self-signed NAS playback
- Replaced unreliable tvOS CKAsset snapshot downloads

---

## [1.5.0] (build 11/12) - 2026-05-23

> `1.5.0` began as a development anchor, then had its build aligned again during the macOS and tvOS merges.

### Added

- Added a full DLNA Controller with device discovery, casting, and background session retention
- Added the complete iCloud Family Sharing flow with invitations, acceptance, and shared-database routing
- Redesigned the Library landing page with playlist artwork, playlist reordering, and a pinned Liked Songs entry
- Redesigned the native macOS experience with themes, brand colors, app icons, desktop widgets, and dedicated player surfaces

### Changed

- Brought Apple Music, DLNA casting, Family Sharing, and playback shortcuts to macOS
- Indexed playlist and recent-play queries to avoid repeated large-library scans

### Fixed

- Fixed partial-cache gapless loading loops and tracks advancing before playback ended
- Fixed duplicate scanning stalls, lost cleanup progress, and playlist hangs
- Fixed macOS CloudKit launch loops, desktop-widget loading, and Spatial Audio permission issues

---

## [1.4.0] (build 11) - 2026-05-23

### Added

- Fully integrated Apple Music with library browsing, subscription playback, a dedicated Now Playing experience, and the system Liked Songs playlist
- Made artist-page songs directly playable and changed album grids to adaptive columns

### Changed

- Rebuilt DLNA SSDP discovery for more reliable local-device detection

### Fixed

- Prevented invalid playback attempts when Apple Music subscription access is unavailable

---

## [1.3.2] (build 10) - 2026-05-22

### Added

- Added playback speed, Hi-Res quality badges, and Spatial Audio
- Added pinyin and lyrics search with matching snippets
- Added Last.fm similar tracks, song radio, and discovery recommendations
- Added offline audio downloads, persistent ReplayGain tags, and guarded gapless playback
- Added grouped smart-playlist rules

### Fixed

- Fixed legacy Chinese metadata encoding, delayed scraped artwork refresh, and main-thread lyrics search
- Improved DLNA/UPnP compatibility, mute-volume state, and gapless/crossfade race handling

---

## [1.3.1] (build 10) - 2026-05-18

### Added

- Added Siri Shortcuts, Watch complications, Lock Screen widgets, and Control Center widgets
- Added Dynamic Island actions, Spotlight search, iPad landscape Now Playing, and external-display playback
- Added the tag editor, first-launch onboarding, VoiceOver, and wide iPad layouts
- Added cross-device Handoff with full queue context
- Added Apple Music search and a DLNA MediaRenderer receiver mode
- Added spectrum visualization, DLNA volume sync, event subscriptions, and protocol diagnostics
- Added Japanese, Korean, German, and French localization

### Fixed

- Moved FFT processing off the real-time audio thread
- Fixed remote-stream duration probing, media-server direct playback, LRCLIB casts, and OAuth refresh encoding
- Hardened QNAP, S3, UGREEN NAS, Last.fm, and DLNA protocol handling

---

## [1.3.0] (build 9) - 2026-05-10

### Added

- Added the Apple Watch companion app with library browsing and Now Playing controls
- Added smart playlists, the annual listening report, and a listening-stats Home summary
- Added For You, Top Artists, Today's Pick, and Home-section visibility controls
- Added App Store update prompts, manual update checks, and reusable illustrated empty states

### Performance

- Reduced main-thread stalls during large-library scans, metadata backfill, and batch deletion
- Accelerated Baidu Netdisk tag reading with background continuation and completion notifications

### Fixed

- Fixed stale scraped artwork, player deadlocks, queue reordering overlap, and deleted-source sync

---

## [1.2.0] (build 8) - 2026-05-05

### Added

- Added range streaming across NAS, SMB, SFTP, FTP, NFS, and cloud drives
- Added metadata backfill, multi-candidate lyrics caching, and offline lyrics translation
- Added Last.fm / ListenBrainz scrobbling, listening statistics, and duplicate detection
- Added M3U8 / Primuse JSON playlist import and export plus a CarPlay Playlists tab
- Added word-level lyrics sweep, smooth line transitions, and explicit manual-scrape overwrite behavior

### Changed

- Moved caches to on-demand growth under LRU management, with separate prewarm, active-download, and physical-size reporting

### Fixed

- Switched Last.fm to the desktop auth flow to fix 403 responses
- Fixed sparse caches, partial-cache finalization, lyrics-cache downgrades, and the blank state after a single track ended

---

## [1.1.1] (build 6) - 2026-05-03

### Added

- Added the CloudKit foundation for synchronizing sources, playlists, and library state
- Added album and artist details plus cached artwork components

### Fixed

- Fixed cached CloudKit system fields to avoid conflicts while updating existing records
- Fixed OAuth callback and sync-model compatibility

---

## [1.1.0] (build 5) - 2026-05-01

### Added

- Added Baidu Netdisk, Dropbox, Aliyun Drive, WebDAV, and FTP sources
- Added importable custom scraper configurations and management UI
- Added app-icon switching, lyrics font sizing, and cloud-token management
- Improved Home Screen widgets and their cloud Now Playing state

### Changed

- Refactored playback services and dependency injection for cloud playback and queue management

---

## [1.0.2] (build 4) - 2026-04-14

### Added

- Added a reusable cloud-drive OAuth authorization and token-refresh flow
- Added built-in cloud credential configuration and cloud connection UI
- Redesigned Now Playing and Quick Access widgets

### Fixed

- Improved cloud credential loading and playback-state synchronization

---

## [1.0.1] (build 3) - 2026-04-13

### Added

- Added equalizer and audio-effects settings

### Changed

- Refactored SSL trust management and removed hard-coded domain configuration
- Completed project entitlements, signing, and build configuration

---

## [1.0.0] (build 1/2) - 2026-03-28

The first iPhone and iPad release.

### Added

- A multi-source library for local files, Synology, SMB, SFTP, NFS, S3, WebDAV, and media servers
- An SFBAudioEngine-based playback engine, queue, and album/artist browsing
- Regular playlists, metadata scraping, and artwork/lyrics caching
- Home with recently played tracks and album recommendations
- CarPlay, remote controls, network discovery, and basic localization

---

## Early standalone macOS releases

### [1.1.0] (build 2) - 2026-05

A stability and experience update after the initial macOS 1.0.0 release, bringing over important iOS fixes and polishing Mac-specific windows and layout.

#### Added

- **Source authentication feedback** — background connection failures now show an error and let users re-enter credentials
- **Negative cache for failed lyrics translation** — deterministic unsupported-language errors are cached for 24 hours instead of retried on every playback
- **Content-addressed artwork storage** — `MetadataAssets/content/<sha>.jpg` lets tracks from the same album share one physical JPEG
- **Automatic content eviction** — background garbage collection removes orphaned content and evicts oldest files beyond 500 MB
- **Desktop lyrics and menu-bar controls** — continued refinement of the macOS-specific playback surfaces introduced in 1.0

#### Changed

- **Library tools moved out of Settings** — rescan, re-scrape, and cache controls now live with the Library
- **Scrape sheets default to full height** — automatic and manual scrape actions no longer appear missing below a medium sheet
- **Native scraping window** — macOS scraping now opens in an `NSWindow` with standard traffic-light controls

#### Fixed

- **Apply changes stall and crash** — closes the scraping window first, then applies library and sidecar changes in a background task
- **Synology login storms and DSM blocking** — concurrent requests for one source now share a single in-flight login
- **SFTP `try!` crash risk** — authentication is resolved before capture instead of force-throwing inside a callback
- **Lost partial translations** — completed responses are retained when a later translation batch throws
- **Legacy local-reference precedence** — corrected an unused but invalid `&&` / `||` expression
- **Broken word-level lyrics rendering** — fixed discontinuous masks on macOS
- **Lyrics not refreshing after scraping** — successful scraping now reloads the active lyrics view

#### Performance

- **Artwork storage reduced by about 98%** — typical same-album artwork drops from many duplicate JPEGs to one shared file plus tiny redirect records
- **Single Synology login** — concurrent playback and prefetch requests reuse one authentication task
- **Removed duplicate post-scrape refreshes** — the shared song-replacement notification is now the only refresh path

---

### [1.0.0] (build 1) - 2026-04

The first standalone macOS release.

#### Added

- Cross-platform playback, scraping, sidecar write-back, and library management
- Floating desktop lyrics
- Menu-bar playback controls
- A three-column Mac interface with a sidebar, detail area, and bottom player
- A floating mini player
- Fullscreen macOS Now Playing
- OAuth callbacks through the `primuse://` URL scheme
