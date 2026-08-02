<p align="right"><a href="README.md">中文</a> · <strong>English</strong></p>

# Primuse

<p align="center">
  <a href="https://testflight.apple.com/join/AjbPukaF">
    <img src="https://img.shields.io/badge/TestFlight-Join_Beta-0D96F6?logo=apple&logoColor=white&style=for-the-badge" alt="Join the Primuse TestFlight beta"/>
  </a>
  <a href="https://apps.apple.com/us/app/%E7%8C%BF%E9%9F%B3/id6761675450">
    <img src="https://img.shields.io/badge/App_Store-Download-007AFF?logo=apple&logoColor=white&style=for-the-badge" alt="Download on the App Store"/>
  </a>
</p>

> **Try the latest build:** [join the TestFlight beta](https://testflight.apple.com/join/AjbPukaF)

Primuse is a native, multi-source music player for the Apple ecosystem. It brings local files, NAS devices, media servers, cloud drives, and Apple Music into one library and playback queue, with high-fidelity decoding, CUE track splitting, lyrics and metadata, cross-device sync, and system playback controls.

The stable release is available on the App Store. Search for “Primuse” or use the download button above.

## Documentation

- [中文说明](README.md) · [English README](README.en.md)
- [中文更新日志](CHANGELOG.md) · [English Changelog](CHANGELOG.en.md)
- [Screenshots](#screenshots) · [macOS Desktop App](#macos-desktop-app) · [Apple TV App](#apple-tv-app) · [Apple Watch and System Integration](#apple-watch-and-system-integration)
- [Music Sources](#music-sources) · [Playback and Formats](#playback-and-formats) · [Lyrics and Metadata](#lyrics-and-metadata) · [Library and Sync](#library-and-sync)
- [Getting Started](#getting-started) · [Custom Scraping Sources](#custom-scraping-sources) · [Project Structure](#project-structure) · [Architecture](#architecture)

## iPhone and iPad

- **Adaptive native UI** — tab-based navigation on iPhone, a split-view library and two-column landscape player on iPad, plus multiwindow scene support
- **Complete mobile library** — import songs from the Files app, connect remote sources, scan folders, and search or manage playlists across local, NAS, and cloud content
- **A full player on the go** — switch between artwork, lyrics, and the queue; inspect format details, tune speed and effects, choose an AirPlay output, and correct metadata manually
- **Background and system control** — background audio, Lock Screen and Control Center controls, headset/Bluetooth buttons, and iPhone volume synchronized with the system output level

## Screenshots

<p align="center">
  <img src="Docs/screenshots/ios/en-US/01-home.jpg" width="160" alt="Primuse Home"/>
  <img src="Docs/screenshots/ios/en-US/02-appearance.jpg" width="160" alt="Light and dark appearance"/>
  <img src="Docs/screenshots/ios/en-US/03-songs.jpg" width="160" alt="Songs library"/>
  <img src="Docs/screenshots/ios/en-US/04-albums.jpg" width="160" alt="Album browsing"/>
  <img src="Docs/screenshots/ios/en-US/05-playlists.jpg" width="160" alt="Playlists"/>
</p>
<p align="center">
  <img src="Docs/screenshots/ios/en-US/06-search.jpg" width="160" alt="Populated search results"/>
  <img src="Docs/screenshots/ios/en-US/07-now-playing.jpg" width="160" alt="Now Playing"/>
  <img src="Docs/screenshots/ios/en-US/08-lyrics.jpg" width="160" alt="Synchronized lyrics"/>
  <img src="Docs/screenshots/ios/en-US/09-sources.jpg" width="160" alt="Music source management"/>
  <img src="Docs/screenshots/ios/en-US/10-equalizer.jpg" width="160" alt="10-band equalizer"/>
</p>

## macOS Desktop App

The Mac client uses a native desktop layout and shares its library, music sources, playlists, and iCloud data with iPhone, iPad, and Apple TV.

<table>
  <tr>
    <td align="center"><img src="Docs/screenshots/macos/en-US/01-home.jpg" width="420" alt="macOS Home"/><br/>Desktop Music Command Center</td>
    <td align="center"><img src="Docs/screenshots/macos/en-US/02-sources.jpg" width="420" alt="macOS Sources"/><br/>Source Management</td>
  </tr>
  <tr>
    <td align="center"><img src="Docs/screenshots/macos/en-US/03-songs.jpg" width="420" alt="macOS Songs Library"/><br/>Complete Songs Library</td>
    <td align="center"><img src="Docs/screenshots/macos/en-US/04-now-playing.jpg" width="420" alt="macOS Now Playing"/><br/>Now Playing and Synced Lyrics</td>
  </tr>
  <tr>
    <td align="center"><img src="Docs/screenshots/macos/en-US/05-mini-player.jpg" width="420" alt="macOS Mini Player"/><br/>Mini Player</td>
    <td align="center"><img src="Docs/screenshots/macos/en-US/06-desktop-lyrics.jpg" width="420" alt="macOS Desktop Lyrics"/><br/>Standalone Desktop Lyrics</td>
  </tr>
  <tr>
    <td align="center" colspan="2"><img src="Docs/screenshots/macos/en-US/07-menu-bar.jpg" width="860" alt="macOS Menu Bar Player"/><br/>Menu Bar Player and Quick Controls</td>
  </tr>
</table>

### macOS-Specific Features

- **Native desktop UI** — a custom title bar, collapsible sidebar, bottom playback bar, and table/search views optimized for large libraries
- **Mini player and menu bar player** — move between a floating panel, menu bar popover, and the main window while keeping lyrics and the queue close at hand
- **Desktop lyrics** — a standalone floating lyrics window with two-line, single-line, vertical, locked, and click-through layouts
- **Apple Music / iTunes library import** — read accessible songs and playlists from the Music app on the Mac; readable local non-DRM files can play directly
- **Professional output control** — choose an audio output device, use application-level volume, and switch between high-fidelity and effects processing paths
- **Full library tooling** — smart playlists, duplicate cleanup, tag editing, playlist import/export, and a dedicated batch scraping window
- **Desktop widgets and multi-display playback** — Now Playing, lyrics, statistics, and other WidgetKit widgets, plus large artwork and lyrics on an external display
- **DLNA casting and system controls** — discover local renderers and cast to them, with media-key and custom keyboard-shortcut support
- **Appearance customization** — light/dark modes, themes, dynamic colors derived from artwork, and multiple alternate app icons

## Apple TV App

The Apple TV client can browse the full library, connect to multiple source types, and receive library data, credentials, and playback configuration from an iPhone over iCloud or the local network.

<table>
  <tr>
    <td align="center"><img src="Docs/screenshots/tv/en-US/01-home.jpg" width="420" alt="Apple TV Home"/><br/>Home on the Big Screen</td>
    <td align="center"><img src="Docs/screenshots/tv/en-US/02-library.jpg" width="420" alt="Apple TV Library"/><br/>Complete Library</td>
  </tr>
  <tr>
    <td align="center"><img src="Docs/screenshots/tv/en-US/03-playlists.jpg" width="420" alt="Apple TV Playlists"/><br/>Playlists</td>
    <td align="center"><img src="Docs/screenshots/tv/en-US/04-search.jpg" width="420" alt="Apple TV Search"/><br/>Search from the Sofa</td>
  </tr>
  <tr>
    <td align="center" colspan="2"><img src="Docs/screenshots/tv/en-US/05-now-playing.jpg" width="860" alt="Apple TV Now Playing"/><br/>Now Playing and Synced Lyrics</td>
  </tr>
</table>

### Apple TV-Specific Features

- **Whole-library browsing** — browse albums, artists, songs, and playlists, with Play All, Shuffle All, and Siri Remote support
- **Direct sources and relays** — WebDAV, UPnP/DLNA, cloud drives, and server libraries use their own resolvers; SMB, NFS, and FTP can read on the TV itself, while some other sources can use the optional iPhone LAN relay
- **QR-code configuration transfer** — Apple TV displays a one-time QR code so an iPhone can securely send a library snapshot, music sources, and encrypted credentials over the LAN, without requiring both devices to use the same Apple ID
- **Credential management** — use iCloud sync, LAN pairing, or credentials entered directly on the TV for supported server types
- **Synchronized lyrics** — load lyrics from the local cache, source sidecars, or a server, including line/word progress and translations
- **Top Shelf** — publish recent items and albums on the tvOS Home screen, with deep links back into their content
- **Seven-language UI** — English, Simplified and Traditional Chinese, German, French, Japanese, and Korean

> Apple TV playback paths depend on the source type, available credentials, and relay configuration. FFmpeg-based DTS/DTS-CD compatibility decoding currently targets iPhone, iPad, and Mac only.

## Apple Watch and System Integration

- **Apple Watch companion** — view artwork, track information, the current lyric, and progress; play/pause, skip, seek, and select a track from the active queue
- **Watch complications** — show the current playback state on the watch face and jump back into the Watch app
- **Home Screen widgets** — Now Playing, Quick Access, Lyrics, Listening Statistics, Music Sources, and Year in Review in multiple sizes
- **Control Center widgets** — play/pause, shuffle, previous, and next controls on iOS
- **CarPlay** — browse recents, playlists, albums, and artists, then use the car's Now Playing UI and system voice controls
- **Siri and Shortcuts** — App Intents and media intents for playback, shuffle, and track navigation
- **Spotlight** — index songs, albums, and artists so system search can open them directly
- **System playback experience** — Lock Screen and Control Center media controls, headset/Bluetooth controls, AirPlay, external displays, and media keys

## Music Sources

| Category | Currently supported |
|----------|---------------------|
| NAS | Synology DSM, QNAP |
| File protocols | SMB/CIFS, WebDAV, FTP, SFTP, NFS, S3, UPnP/DLNA |
| Music servers | Subsonic, Navidrome, Airsonic, Gonic, Feiniu Music, DaoLiYu |
| Media servers | Jellyfin, Emby, Plex |
| Cloud drives | 123 Cloud Drive, 115, Baidu Netdisk, Aliyun Drive, Google Drive, OneDrive, Dropbox |
| Apple and local | iPhone/iPad file import, local folders on Mac, Apple Music library and catalog |

- **Unified scanning and browsing** — select folders for file-based sources or scan the complete catalog exposed by a server source, with background scans, resume support, incremental updates, and metadata backfill
- **On-demand streaming and caching** — Range-capable sources stream while downloading, with configurable cache limits, queue prewarming, and automatic cleanup
- **Secure credentials** — passwords and OAuth tokens live in Keychain; source/account data and playback credentials move between platforms through iCloud or a secure LAN transfer where supported
- **Trusted connections** — explicitly trust your own NAS TLS or HTTP host without globally disabling network security
- **Read-only source protection** — Subsonic-family servers, Feiniu Music, DaoLiYu, UPnP, and Apple Music catalogs never delete remote audio; scraped data stays in the local cache
- **Writable sidecars** — supported writable sources can store artwork and LRC files next to the audio; sources without write support remain read-only

UGREEN UGOS and the legacy fnOS system-level file APIs are still waiting for stable, public vendor interfaces and are not advertised as supported NAS sources. Feiniu Music is a separate, supported music-service integration that does not depend on the fnOS file API.

## Playback and Formats

- **Dual decoding paths** — native SFBAudioEngine handles the high-fidelity path, while the FFmpeg compatibility path covers formats that native decoders do not handle reliably
- **Broad format support** — MP3, AAC/M4A, ALAC, FLAC, WAV/AIFF, APE, WavPack, OGG/Opus, WMA, TTA, TAK, Musepack, Shorten, Speex, QOA, DSF/DFF, AC-3, E-AC-3, MLP/TrueHD, and more
- **CUE track splitting** — read UTF-8, UTF-16, and GB18030 `.cue` sheets and use `INDEX 01` entries to expand a continuous album image into virtual tracks with individual titles, numbers, time boundaries, and ReplayGain values
- **DTS and DTS-CD** — iPhone, iPad, and Mac support `.dts` / DTS-HD and content-aware DTS-CD detection inside WAV containers through compatibility decoding
- **DSD** — Automatic, PCM, and DoP playback modes, selected according to device capabilities and user preference
- **Gapless and crossfade** — Gapless playback, 1–12 second crossfades, leading/trailing silence skipping, and next-track prewarming; Gapless and Crossfade are mutually exclusive settings
- **Playback tuning** — track/album ReplayGain, 0.5×–2.0× pitch-preserving speed, output sample-rate matching, a sleep timer, and configurable queue prefetching
- **Effects chain** — a 10-band equalizer, Spatial Audio and head tracking, compression/limiting, reverb, and real-time visualization
- **Music videos** — discover same-name MP4/M4V/MOV sidecars, or treat a video without a matching audio file as a standalone music video
- **Mixed-source queues** — local, NAS, cloud, server, and Apple Music tracks remain visible in one queue, with Primuse coordinating transitions across provider boundaries

## Lyrics and Metadata

- **Embedded data and sidecars** — read audio tags, embedded artwork, same-name/folder artwork, `.lrc` lyrics, and same-name music videos
- **Line- and word-synchronized lyrics** — standard LRC, enhanced word timestamps, tap-to-seek, manual browsing with automatic follow recovery, and display across iOS, macOS, tvOS, and Watch
- **Offline lyric translation** — use Apple's Translation framework and cache results locally, with configurable target languages and cache management
- **Built-in scrapers** — Apple Music/iTunes Search, MusicBrainz, and LRCLIB, each used according to its metadata, artwork, or lyrics capabilities
- **Confidence-aware ranking** — rank candidates using title, artist, album, and duration; manual scraping reports uncertainty to reduce incorrect same-name matches
- **Batch scraping feedback** — start confirmation, live progress, cancellation, completion statistics, and failure details for long-running library tasks
- **Custom scraping sources** — import JSON directly or over HTTPS, with GET/POST requests, headers, cookies, rate limits, TLS trust domains, JavaScript parsing, and word-level lyrics capability declarations

## Library and Sync

- **Unified library** — browse by song, album, artist, genre, and source; search title, artist, album, Pinyin, full lyric text, and combined criteria
- **Playlist system** — regular playlists, smart playlists, Quick Favorites, and M3U8 / Primuse JSON import/export, including automatic matching, manual correction, and unmatched-item CSV export
- **Maintenance tools** — duplicate detection, read-only source protection, Recently Deleted recovery, tag editing, and per-source rescanning
- **Listening statistics** — recents, play counts, listening-time trends, music personality, and Year in Review, also available in widgets
- **Scrobbling** — Last.fm and ListenBrainz, with retry support for failed submissions
- **CloudKit sync** — independently sync playlists, smart playlists, music sources, cloud accounts, scraper settings, play history, listening statistics, and preferences
- **Family sharing** — share regular playlists, smart playlists, and family music sources through CloudKit while keeping personal favorites private
- **Apple Music** — sync the user's library and playlists and search the Apple Music catalog; MusicKit plays subscription-backed content, while confirmed readable non-DRM local items on Mac do not require a subscription

## Requirements

| Component | Minimum requirement |
|-----------|---------------------|
| Development tools | Xcode 26.0+, Swift 6.0+, and a macOS development environment |
| iPhone / iPad | iOS / iPadOS 18.0+ |
| Mac app | macOS 26.0+ |
| Apple TV | tvOS 17.0+ |
| Apple Watch | watchOS 10.0+ |

## Getting Started

### 1. Clone and open the project

```bash
git clone git@github.com:chenqi92/primuse.git
cd primuse
open Primuse.xcodeproj
```

Xcode resolves the Swift Package Manager dependencies on first open. The FFmpeg XCFrameworks are already included in the repository.

### 2. Configure code signing

1. Select the **Primuse** project in Xcode.
2. Set your Apple Developer Team on the app and extension targets you intend to build.
3. The iOS app, widgets, activity extension, Watch app, Watch widgets, macOS app, tvOS app, and Top Shelf extension use different bundle and entitlement combinations; keeping automatic signing enabled is recommended.
4. To use the DLNA Renderer on a physical device, enable Multicast Networking for the App ID in the Apple Developer portal and make sure the provisioning profile contains `com.apple.developer.networking.multicast`.

You can also change `DEVELOPMENT_TEAM` in `project.yml` and regenerate the project with XcodeGen.

### 3. Configure local secrets (optional)

```bash
cp Config/Secrets.local.xcconfig.example Config/Secrets.local.xcconfig
```

Add cloud-drive OAuth and Last.fm values as needed. `Config/Secrets.local.xcconfig` is ignored by Git. If an integrated OAuth credential is not configured, that service may require the developer's own client configuration.

### 4. Build and test

```bash
# Generic iOS Simulator build
xcodebuild -project Primuse.xcodeproj \
  -scheme Primuse \
  -destination 'generic/platform=iOS Simulator' \
  build

# Apple TV Simulator build
xcodebuild -project Primuse.xcodeproj \
  -scheme PrimuseTV \
  -destination 'generic/platform=tvOS Simulator' \
  build

# PrimuseKit tests
swift test --package-path PrimuseKit
```

### 5. Development helper

The repository includes one local development helper for common build, install, and launch workflows:

```bash
# Pick an action interactively
scripts/primuse-dev.sh

# List available iPhones and iPads
scripts/primuse-dev.sh devices

# Overwrite-install while retaining app data
scripts/primuse-dev.sh ios-overwrite

# Clean reinstall; the script requires DELETE confirmation and erases app data
scripts/primuse-dev.sh ios-clean

# Build and launch the Mac app
scripts/primuse-dev.sh mac
```

Before a physical-device build, run `scripts/check-apple-signing.sh` to check the signing identity, private-key access, and `codesign` authorization.

## Custom Scraping Sources

Primuse can describe search, detail, artwork, and lyrics endpoints in JSON and parse responses with JavaScript. Before importing, it shows the domains, HTTP methods, capabilities, cookies, TLS trust domains, and sensitive-configuration warnings for review.

### Configuration example

```json
{
  "id": "my-source",
  "name": "My Music Source",
  "version": 1,
  "icon": "music.note",
  "color": "#FF6600",
  "rateLimit": 500,
  "headers": {
    "User-Agent": "Primuse"
  },
  "capabilities": ["metadata", "cover", "lyrics", "lyricsWordLevel"],
  "search": {
    "url": "https://api.example.com/search",
    "method": "GET",
    "params": {
      "q": "{{query}}",
      "artist": "{{artist}}",
      "album": "{{album}}",
      "limit": "{{limit}}"
    },
    "script": "return (response.results || []).map(function (item) { return { id: String(item.id), title: item.title, artist: item.artist, album: item.album, durationMs: item.durationMs, coverUrl: item.coverUrl }; });"
  },
  "detail": {
    "url": "https://api.example.com/tracks/{{id}}",
    "method": "GET",
    "script": "return response;"
  },
  "cover": {
    "url": "https://api.example.com/tracks/{{id}}/covers",
    "method": "GET",
    "script": "return response.covers || [];"
  },
  "lyrics": {
    "url": "https://api.example.com/tracks/{{id}}/lyrics",
    "method": "GET",
    "script": "return { lrcContent: response.lrc, wordLevelLrc: response.wordLevelLrc, plainText: response.text };"
  }
}
```

### Import and script contract

1. Open **Settings → Metadata Scraping → Import Scraping Source**.
2. Paste JSON or an HTTPS manifest URL.
3. Review permissions and security warnings, then confirm the import.
4. Reorder, enable, disable, edit, or configure cookies for the imported source.

Scripts can access:

- `response`: parsed JSON response
- `responseText`: raw response text
- `externalId`: current external ID for detail, artwork, and lyrics endpoints
- `log(msg)`: debug logging

Expected return values:

- `search`: `[{id, title, artist, album, year, durationMs, coverUrl, trackNumber, genres}]`
- `detail`: `{title, artist, albumArtist, album, year, trackNumber, discNumber, durationMs, genres, coverUrl}`
- `cover`: `[{coverUrl, thumbnailUrl}]`
- `lyrics`: `{lrcContent, wordLevelLrc, plainText}`

Do not import configurations from sources you do not trust. Custom scripts process remote responses; cookies, headers, TLS trust domains, and local secrets are sensitive permissions.

## Project Structure

```text
primuse/
├── Primuse/                        # Shared iOS and macOS application code
│   ├── App/                        # App entry, dependency wiring, CarPlay and external-display scenes
│   ├── Services/
│   │   ├── AppleMusic/             # MusicKit catalog, library, and mixed queues
│   │   ├── Audio/                  # Playback, native/FFmpeg decoding, caching, and effects
│   │   ├── Cloud/                  # CloudKit, family sharing, snapshots, and credential sync
│   │   ├── DLNA/                   # UPnP/AV Renderer and casting
│   │   ├── Library/                # GRDB library, scanning, Spotlight, and maintenance
│   │   ├── Metadata/               # Tags, sidecars, scrapers, and lyric translation
│   │   ├── Relay/                  # iPhone-to-Apple TV LAN relay
│   │   ├── Sources/                # NAS, protocol, server, and cloud connectors
│   │   └── Watch/                  # WatchConnectivity bridge
│   ├── Views/                      # iOS and macOS interfaces
│   └── Resources/                  # Seven localizations, assets, and privacy manifests
├── PrimuseKit/                     # Models, policies, and stream resolvers shared across iOS/macOS/tvOS
├── PrimuseTV/                      # Apple TV app
├── PrimuseTopShelf/                # tvOS Top Shelf extension
├── PrimuseWatch/                   # Apple Watch app
├── PrimuseWatchShared/             # Models shared by the Watch app and complications
├── PrimuseWatchWidgets/            # Watch complications
├── PrimuseWidgetExtension/         # iOS/macOS widgets and Control Center widgets
├── PrimuseActivityExtension/       # Live Activity layout target (not currently enabled by the main app)
├── Frameworks/FFmpeg/              # iOS/macOS FFmpeg XCFrameworks
├── Config/                         # Entitlements, xcconfig, and Info configuration
├── scripts/                        # Build, install, signing, FFmpeg, and screenshot tools
└── project.yml                     # XcodeGen project definition and unified version source
```

## Dependencies

| Package or framework | Purpose |
|----------------------|---------|
| [SFBAudioEngine](https://github.com/sbooth/SFBAudioEngine) | High-fidelity audio decoding and DSD support |
| FFmpeg 8.1 (bundled dynamic XCFrameworks) | DTS/DTS-CD, multichannel downmix, and compatibility decoding |
| [GRDB.swift](https://github.com/groue/GRDB.swift) | SQLite library persistence |
| [AMSMB2](https://github.com/amosavian/AMSMB2) | SMB/CIFS client |
| [FileProvider](https://github.com/amosavian/FileProvider) | FTP and WebDAV file operations |
| [Citadel](https://github.com/orlandos-nl/Citadel) | SSH/SFTP client |
| [NFSKit](https://github.com/alexiscn/NFSKit) | NFS client |
| [swift-crypto](https://github.com/apple/swift-crypto) | Cryptographic and signing operations |
| [swift-nio](https://github.com/apple/swift-nio) | Asynchronous networking infrastructure |

System frameworks include MusicKit, CloudKit, AVFoundation, MediaPlayer, CarPlay, WidgetKit, WatchConnectivity, App Intents, Core Spotlight, Translation, and Network.framework.

## Architecture

### Audio pipeline

```text
Local / NAS / protocol / media server / cloud drive
  → SourceManager / StreamResolver / Range Fetcher
  → CUE Segment and cache/prewarm policies
  → NativeAudioDecoder (SFBAudioEngine) or FFmpegAudioDecoder
  → AVAudioConverter
  → AVAudioEngine (Player → Mixer → EQ / Dynamics / Reverb → Output)

Apple Music
  → MusicKit ApplicationMusicPlayer
  → Primuse mixed-queue and system Now Playing coordination
```

### Metadata and lyrics

```text
Source scan
  → file tags + sidecars + CUE expansion
  → MetadataBackfillService
  → GRDB library and MetadataAssetStore

Manual / automatic / batch scrape
  → ScraperManager
  → built-in scraper or JSON + JavaScript custom scraper
  → title/artist/album/duration candidate ranking
  → local cache, or SidecarWriteService for supported writable sources
```

### Cross-device data

```text
iPhone / iPad / Mac
  ↔ CloudKit: playlists, sources, settings, history, statistics, library snapshots
  ↔ iCloud Keychain / encrypted credential bundle
  ↔ Apple TV: CloudKit sync or QR-code LAN transfer
  ↔ Apple Watch: WatchConnectivity playback state and control commands
```

### CI/CD

- **Build** — a manually dispatched GitHub Actions workflow runs branding checks, resolves Swift packages, and builds for the iOS Simulator; when the version changes, it can also produce an unsigned IPA artifact
- **Release** — manually archive, sign, and export the IPA, with an option to upload it to TestFlight

## Notes

Primuse does not provide music or cloud storage. You use your own files, servers, and third-party accounts. Availability depends on each provider, region, account permissions, and API status. Follow the terms of your content sources and all applicable laws.
