<p align="right"><a href="README.md">中文</a> · <strong>English</strong></p>

# Primuse

Primuse brings music from local files, NAS devices, media servers, cloud drives, and Apple Music into one library. Listen to albums, follow word-timed lyrics, or sing along on iPhone, iPad, Mac, and Apple TV. Podcasts, audiobooks, and internet radio each have their own listening views.

**[Palveni Knowledge Base · Primuse user guides](https://palveni.com/en/knowledge?product=primuse)**

Start with [connecting a source and playing your first track](https://palveni.com/en/knowledge/primuse-kb-end-to-end-workflow-zh-hans). For a specific task, see [connecting a cloud drive](https://palveni.com/en/knowledge/primuse-kb-connect-cloud-drives-zh-hans), [matching lyrics and artwork](https://palveni.com/en/knowledge/primuse-kb-metadata-artwork-scraping-zh-hans), [offline downloads](https://palveni.com/en/knowledge/primuse-offline), or [troubleshooting playback](https://palveni.com/en/knowledge/primuse-kb-troubleshoot-playback-zh-hans).

<p align="center">
  <a href="https://testflight.apple.com/join/AjbPukaF">
    <img src="https://img.shields.io/badge/TestFlight-Join_Beta-0D96F6?logo=apple&logoColor=white&style=for-the-badge" alt="Join the Primuse TestFlight beta"/>
  </a>
  <a href="https://apps.apple.com/us/app/%E7%8C%BF%E9%9F%B3/id6761675450">
    <img src="https://img.shields.io/badge/App_Store-Download-007AFF?logo=apple&logoColor=white&style=for-the-badge" alt="Download on the App Store"/>
  </a>
</p>

## Documentation

- [iPhone and iPad](#iphone-and-ipad) · [Community and icon contest](#community)
- [English changelog](Docs/CHANGELOG.en.md) · [Chinese changelog](Docs/CHANGELOG.md)
- [Screenshots](#screenshots) · [macOS Desktop App](#macos-desktop-app) · [Apple TV App](#apple-tv-app) · [Apple Watch and System Integration](#apple-watch-and-system-integration)
- [Music Sources](#music-sources) · [Podcasts, Audiobooks, and Karaoke](#podcasts-audiobooks-and-karaoke) · [Radio, Discovery, and Personalization](#radio-discovery-and-personalization) · [Playback and Formats](#playback-and-formats) · [Lyrics and Metadata](#lyrics-and-metadata) · [Library and Sync](#library-and-sync)
- [Getting Started](#getting-started) · [Custom Scraping Sources](#custom-scraping-sources) · [Project Structure](#project-structure) · [Architecture](#architecture) · [License](#license)

## iPhone and iPad

- **Adaptive native UI** — tab-based navigation on iPhone with compact layouts for landscape, split-screen, and foldable cover displays; iPad adds a split-view library, two-column player, and multiwindow scenes
- **Complete mobile library** — import songs from the Files app, connect remote sources, scan folders, and search or manage playlists and saved stations across local, NAS, server, and cloud content
- **A full player on the go** — switch between artwork, lyrics, the queue, and multiple immersive scenes; inspect the actual audio quality, tune speed and effects, choose an AirPlay output, and correct metadata manually
- **Background and system control** — background audio, Lock Screen and Control Center controls, and headset/Bluetooth buttons; the volume slider changes Primuse's own level without changing system output volume

## Screenshots

<p align="center">
  <img src="Docs/screenshots/ios/en-US/01-home.jpg" width="160" alt="Primuse across Apple devices"/>
  <img src="Docs/screenshots/ios/en-US/02-appearance.jpg" width="160" alt="Local, NAS, and cloud sources"/>
  <img src="Docs/screenshots/ios/en-US/03-songs.jpg" width="160" alt="Radio folders and tags"/>
  <img src="Docs/screenshots/ios/en-US/04-albums.jpg" width="160" alt="CarPlay, Apple Watch, and Siri"/>
  <img src="Docs/screenshots/ios/en-US/05-playlists.jpg" width="160" alt="Immersive landscape player"/>
</p>
<p align="center">
  <img src="Docs/screenshots/ios/en-US/06-search.jpg" width="160" alt="Lyric and tag editing"/>
  <img src="Docs/screenshots/ios/en-US/07-now-playing.jpg" width="160" alt="Device transfer and iCloud sync"/>
  <img src="Docs/screenshots/ios/en-US/08-lyrics.jpg" width="160" alt="Lyric poster sharing"/>
  <img src="Docs/screenshots/ios/en-US/09-sources.jpg" width="160" alt="Smart recommendations and scene-based discovery"/>
  <img src="Docs/screenshots/ios/en-US/10-equalizer.jpg" width="160" alt="Equalizer and audio effects"/>
</p>

## macOS Desktop App

The Mac client uses a native desktop layout and shares its library, music sources, playlists, and iCloud data with iPhone, iPad, and Apple TV.

<table>
  <tr>
    <td align="center"><img src="Docs/screenshots/macos/en-US/01-home.jpg" width="420" alt="macOS library"/><br/>Desktop Library and Playback</td>
    <td align="center"><img src="Docs/screenshots/macos/en-US/02-sources.jpg" width="420" alt="macOS Sources"/><br/>Source Management</td>
  </tr>
  <tr>
    <td align="center"><img src="Docs/screenshots/macos/en-US/03-songs.jpg" width="420" alt="macOS radio library"/><br/>Radio Folders and Tags</td>
    <td align="center"><img src="Docs/screenshots/macos/en-US/04-now-playing.jpg" width="420" alt="macOS desktop playback tools"/><br/>Mini Player, Menu Bar, and Desktop Lyrics</td>
  </tr>
  <tr>
    <td align="center"><img src="Docs/screenshots/macos/en-US/05-mini-player.jpg" width="420" alt="macOS immersive player"/><br/>Full-Screen Artwork, Lyrics, and Immersive Scenes</td>
    <td align="center"><img src="Docs/screenshots/macos/en-US/06-desktop-lyrics.jpg" width="420" alt="macOS lyric editor"/><br/>Lyric Editing and Word Timing</td>
  </tr>
  <tr>
    <td align="center" colspan="2"><img src="Docs/screenshots/macos/en-US/07-menu-bar.jpg" width="860" alt="macOS device transfer and iCloud sync"/><br/>Device Transfer and iCloud Sync</td>
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
    <td align="center"><img src="Docs/screenshots/tv/en-US/01-home.jpg" width="420" alt="Apple TV Home"/><br/>Your Music on Apple TV</td>
    <td align="center"><img src="Docs/screenshots/tv/en-US/02-library.jpg" width="420" alt="Apple TV music sources"/><br/>Direct Sources and QR Transfer</td>
  </tr>
  <tr>
    <td align="center"><img src="Docs/screenshots/tv/en-US/03-playlists.jpg" width="420" alt="Apple TV radio"/><br/>Saved Radio Stations</td>
    <td align="center"><img src="Docs/screenshots/tv/en-US/04-search.jpg" width="420" alt="Apple TV synchronized lyrics"/><br/>Artwork and Synchronized Lyrics</td>
  </tr>
  <tr>
    <td align="center" colspan="2"><img src="Docs/screenshots/tv/en-US/05-now-playing.jpg" width="860" alt="Apple TV immersive player"/><br/>Full-Screen Artwork and Immersive Scenes</td>
  </tr>
</table>

### Apple TV-Specific Features

- **Whole-library browsing** — browse albums, artists, songs, playlists, and radio, with Play All, Shuffle All, and Siri Remote support
- **Direct sources and relays** — WebDAV, UPnP/DLNA, cloud drives, and server libraries use their own resolvers; SMB, NFS, and FTP can read on the TV itself, while some other sources can use the optional iPhone LAN relay
- **QR-code configuration transfer** — Apple TV displays a one-time QR code so an iPhone can securely send a library snapshot, music sources, and encrypted credentials over the LAN, without requiring both devices to use the same Apple ID
- **Credential management** — use iCloud sync, LAN pairing, or credentials entered directly on the TV for supported server types
- **Synchronized lyrics** — load lyrics from the local cache, source sidecars, or a server, including line/word progress and translations
- **Podcasts, books, and karaoke** — select an episode, resume a book, or open the karaoke stage from the full-screen player and pair an iPhone microphone.
- **Top Shelf** — publish recent items and albums on the tvOS Home screen, with deep links back into their content
- **Multilingual interface** — 16 languages, including English, Simplified Chinese, and Traditional Chinese

> Apple TV playback paths depend on the source type, available credentials, and relay configuration. tvOS now includes the FFmpeg compatibility path for formats such as WMA, DTS, and TrueHD that the system decoder does not support natively.

## Apple Watch and System Integration

- **Apple Watch** — control playback on iPhone, select a track, or seek from your wrist. Transfer selected songs for offline playback when your iPhone is out of reach.
- **Watch complications** — show the current playback state on the watch face and jump back into the Watch app
- **Home Screen widgets** — Now Playing, Quick Access, Lyrics, Listening Statistics, Music Sources, and Year in Review in multiple sizes
- **Control Center widgets** — play/pause, shuffle, previous, and next controls on iOS
- **CarPlay** — browse recents, playlists, albums, and audiobooks on the dashboard. Resume listening and use playback controls, speed settings, or Siri.
- **Siri and Shortcuts** — App Intents and media intents for playback, shuffle, and track navigation
- **Spotlight** — index songs, albums, and artists so system search can open them directly
- **System playback experience** — Lock Screen and Control Center media controls, headset/Bluetooth controls, AirPlay, external displays, and media keys

## Radio, Discovery, and Personalization

- **Internet radio library** — add stations manually, import M3U/PLS lists in bulk, or subscribe to a playlist URL, then organize stations with folders, tags, and custom ordering
- **Logos and live metadata** — discover station logos and live program metadata automatically or provide an image URL; SVG logos and server-synced stations are supported
- **Discovery** — browse music, radio, and spoken-word content from Home. Find something to play with scene-based picks, listening charts, and recent listening history.
- **Optional AI services** — enable semantic music search, playlist assistance, lyric translation, or spoken-word transcription. Generate editable chapters for a podcast or audiobook that already has a transcript.
- **Editable layouts** — rearrange sections, item counts, and layouts directly on the home screen, in search results, and in CarPlay, then save custom presets
- **Personal appearance** — light and dark modes, artwork-derived colors, themes, multiple adaptive app icons, and a consistent motion system

## Music Sources

| Category | Sources |
|----------|---------|
| Local and Apple Music | Files imported on iPhone or iPad, local folders and the Music library on Mac, the Apple Music library and catalog |
| NAS and file protocols | Synology DSM, QNAP, SMB/CIFS, WebDAV, FTP/FTPS, SFTP, NFS, S3, UPnP/DLNA |
| Music servers | Subsonic / OpenSubsonic, Navidrome, Airsonic, Gonic, ZSpace Music, Feiniu Music, DaoLiYu, Songloft, Synology Audio Station |
| Media and spoken-word servers | Jellyfin, Emby, Plex, Audiobookshelf, Ting Reader |
| Cloud drives | 115, 123 Cloud Drive, Baidu Netdisk, Aliyun Drive, Guangya Cloud, Google Drive, OneDrive, Dropbox, Drime, InfiniCLOUD, pCloud |

Scan selected folders on a file source or browse the catalog on a music server. Choose the music-service connector for ZSpace Music, Feiniu Music, or Synology Audio Station. Choose SMB or WebDAV to browse shared folders on the same NAS. Enable sources and configure sync per device to give your phone and TV different libraries. [Guide to source types and connections](https://palveni.com/en/knowledge/primuse-supported-source-types)

Synology QuickConnect IDs and Feiniu FN IDs can be entered directly. For sources with multiple addresses, configure local and remote routes, then choose automatic routing or pin one route. Supported servers offer a separate transcoding quality for cellular playback. Passwords and OAuth credentials are stored in Keychain.

**Streaming, caching, and offline downloads.** Primuse clears playback cache according to the size limit you set. Choose an offline download to keep a track for a trip, even after clearing the playback cache. Writable file sources can store lyrics and artwork alongside the audio. The system player handles Apple Music subscription tracks. [Offline downloads and caching](https://palveni.com/en/knowledge/primuse-offline)

## Podcasts, Audiobooks, and Karaoke

- **Podcasts** support RSS subscriptions, OPML import and export, and offline episode downloads. Search a timed transcript to jump to a passage. To generate a transcript, choose an available on-device recognizer or an online service. Online transcription asks for confirmation before uploading audio.
- **Audiobooks** can come from files, Audiobookshelf, or Ting Reader. The bookshelf groups chapters by book and supports M4B, resume across chapters, bookmarks, variable speed, and a sleep timer.
- **Karaoke** can reduce vocals, play accompaniment, change key, or loop a line for practice. Enable a microphone for scoring and recording. An iPhone can serve as the microphone for Apple TV. Optional on-device AI vocal separation requires compatible hardware, OS version 26.4 or later, and a separate model download. Karaoke is unavailable for Apple Music subscription tracks handled by the system player.

## Playback and Formats

- **Dual decoding paths** — a native high-fidelity engine handles common formats, while the FFmpeg compatibility path on iPhone, iPad, Mac, and Apple TV covers formats that system decoders do not handle reliably
- **Broad format support** — MP3, AAC/M4A, ALAC, FLAC, WAV/AIFF, APE, WavPack, OGG/Opus, WMA, TTA, TAK, Musepack, Shorten, Speex, QOA, DSF/DFF, AC-3, E-AC-3, MLP/TrueHD, and more
- **Full-album files and disc images** — play individual CUE tracks with their titles, boundaries, and ReplayGain. Primuse also reads SACD ISO, DVD-Audio images, and audio files inside data ISOs.
- **DTS and DTS-CD** — iPhone, iPad, Mac, and Apple TV support `.dts` / DTS-HD and content-aware DTS-CD detection inside WAV containers through compatibility decoding
- **DSD** — Automatic, PCM, and DoP playback modes, selected according to device capabilities and user preference
- **Gapless and crossfade** — Gapless playback, 1–12 second crossfades, leading/trailing silence skipping, and next-track prewarming; when fading is enabled, manual track changes also use a short transition
- **Playback controls** — adjust ReplayGain, playback speed, sample-rate matching, and the sleep timer. Use A–B repeat to revisit a passage or medley mode to sample excerpts from several tracks.
- **Equalizer and headphone calibration** — adjust the EQ, apply an AutoEQ headphone profile, and select presets by output device. Compression, limiting, and reverb are also available. [Audio effects and output guide](https://palveni.com/en/knowledge/primuse-kb-audio-effects-and-output-zh-hans)
- **Music videos** — discover same-name MP4/M4V/MOV sidecars, or treat a video without a matching audio file as a standalone music video
- **Mixed-source queues** — local, NAS, cloud, server, and Apple Music tracks remain visible in one queue, with Primuse coordinating transitions across provider boundaries

## Lyrics and Metadata

- **Embedded data and sidecars** — read audio tags, embedded artwork, same-name/folder artwork, ID3 SYLT synchronized lyrics, `.lrc` / `.elrc` / `.lys` / `.yrc` / `.qrc` / `.vtt` / `.srt` lyrics, and same-name music videos
- **Line- and word-synchronized lyrics** — standard LRC, enhanced word timing, `offset`, duets, harmony lines, translations, and romanization, with tap to seek, automatic follow after manual browsing, and synchronized display across iOS, macOS, tvOS, and Watch
- **Lyric translation** — use system translation or download an offline model and cache results by language. Lyrics that already contain a translation can be displayed directly.
- **Lyric editing and sharing** — time lines or words, shift the timeline, and save to a lyric file or supported audio tags. Select lines to create a poster, video, or Live Photo.
- **Lyrics and artwork matching** — built-in sources include iTunes Search, MusicBrainz, LRCLIB, and the AMLL word-timed lyrics database. Set animated artwork for a song or album and choose which lyrics to use when several versions are available.
- **Confidence-aware ranking** — rank candidates using title, artist, album, and duration; manual scraping reports uncertainty to reduce incorrect same-name matches
- **Batch scraping feedback** — start confirmation, live progress, cancellation, completion statistics, and failure details for long-running library tasks
- **Custom sources** — import declarative JSON rules from a file or URL to add tags, lyrics, or artwork to existing songs. [Configuration example](#custom-scraping-sources)

## Library and Sync

- **Unified library** — browse by song, album, artist, genre, folder, and source, with multi-disc albums, ratings and reviews, Pinyin, full-text lyric, and compound-condition search
- **Playlists** — create regular or smart playlists, import and export M3U8 and Primuse JSON, or paste a supported service's playlist link. The importer matches titles and artists to your library and lets you resolve missing matches manually.
- **Queue bookmarks and library backups** — save the current queue and resume with its track order and playback position. A library backup can restore ratings, comments, liked tracks, and playlists after a rebuild or a move to another device.
- **Maintenance tools** — duplicate detection, read-only source protection, Recently Deleted recovery, tag editing, and per-source rescanning
- **History and listening statistics** — see recent tracks, play counts, listening-time trends, and your year in review. Listening history also lets you reopen an album, playlist, or spoken-word item.
- **Scrobbling** — Last.fm and ListenBrainz, with retry support for failed submissions
- **CloudKit sync** — independently sync playlists, smart playlists, music sources, cloud accounts, scraper settings, play history, listening statistics, and preferences
- **LAN transfer and web management** — send selected tracks or offline cache between nearby devices and manage transfer files in a browser; Apple TV configuration uses chunked QR-code transfers with visible progress
- **Family sharing** — share regular playlists, smart playlists, and family music sources through CloudKit while keeping personal favorites private
- **Apple Music** — sync the user's library and playlists, add tracks through the system picker, and search the Apple Music catalog; show actual Lossless, Hi-Res Lossless, and Dolby Atmos availability, and rematch tracks when the storefront changes. MusicKit plays subscription-backed content, while confirmed readable non-DRM local items on Mac do not require a subscription

## Community

[Join our Telegram group](https://t.me/+YrgCCwzHfXNlOWZl) to share your experience, report issues, and suggest improvements.

[Submit an icon or vote in the Primuse icon contest](https://palveni.com/en/funbox/primuse-icon-vote)

## Requirements

| Component | System or toolchain |
|-----------|---------------------|
| Development tools | Xcode on macOS with Swift 6. Version 1.13.1 (137) was archived with Xcode 27.2 |
| iPhone / iPad | iOS / iPadOS 18.0+ |
| Mac app | macOS 15.0+ |
| Apple TV | tvOS 17.0+ |
| Apple Watch | watchOS 10.0+ |

## Getting Started

Use these steps to build from source on a Mac. For a ready-to-use installation, follow the App Store link at the top.

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

# Install on an iOS simulator or Apple TV
scripts/primuse-dev.sh sim
scripts/primuse-dev.sh tv

# Build and launch the Mac app
scripts/primuse-dev.sh mac
```

Before a physical-device build, run `scripts/check-apple-signing.sh` to check the signing identity, private-key access, and `codesign` authorization.

## Custom Scraping Sources

A scraping source supplies tags, lyrics, or still and animated artwork for tracks in your library. Open **Import Scraping Source** in Settings. Select a UTF-8 JSON file, paste JSON, or enter an HTTPS manifest URL. Review the domains, request methods, and permissions before importing. URL imports can opt in to automatic updates. Updates that add capabilities or change request origins require review.

This example maps a metadata service that returns a `results` array. Replace the example domain with your service and adjust the paths to match its response.

```json
{
  "id": "my-catalog",
  "name": "My Catalog",
  "version": 1,
  "capabilities": ["metadata"],
  "search": {
    "url": "https://catalog.example.org/search",
    "method": "GET",
    "params": { "q": "{{query}}", "limit": "{{limit}}" },
    "rule": {
      "format": "json",
      "path": "results",
      "array": true,
      "fields": {
        "id": { "path": "track_id" },
        "title": { "path": "name" },
        "artist": { "path": "artist" }
      }
    }
  }
}
```

Primuse supplies `{{query}}` and `{{limit}}`. The `rule.path` selects the result array. The `fields` map each record to the `id`, `title`, and `artist` that Primuse displays. The importer uses declarative rules. It can migrate recognized legacy patterns. Other JavaScript parsers must be rewritten as data rules. [Rule definitions](PrimuseKit/Sources/PrimuseKit/ScraperJSONRule.swift)

## Project Structure

```text
primuse/
├── Primuse/                        # Shared iOS and macOS application code
│   ├── App/                        # App entry, dependency wiring, CarPlay and external-display scenes
│   ├── Services/
│   │   ├── AI/                     # Optional intelligence providers, semantic search, and transcription
│   │   ├── AppleMusic/             # MusicKit catalog, library, and mixed queues
│   │   ├── Audio/                  # Playback, native/FFmpeg decoding, caching, and effects
│   │   ├── Cloud/                  # CloudKit, family sharing, snapshots, and credential sync
│   │   ├── DLNA/                   # UPnP/AV Renderer and casting
│   │   ├── Library/                # GRDB library, scanning, Spotlight, and maintenance
│   │   ├── Metadata/               # Tags, sidecars, scrapers, and lyric translation
│   │   ├── Podcast/                # Subscriptions, episodes, and offline downloads
│   │   ├── Playlist/               # Playlist import, matching, and server sync
│   │   ├── Radio/                  # Internet radio, subscriptions, logos, and live metadata
│   │   ├── Relay/                  # iPhone-to-Apple TV LAN relay
│   │   ├── Sources/                # NAS, protocol, server, and cloud connectors
│   │   ├── Transfer/               # LAN device transfer and browser file management
│   │   └── Watch/                  # WatchConnectivity bridge
│   ├── Views/                      # iOS and macOS interfaces
│   └── Resources/                  # 16 localizations, assets, and privacy manifests
├── PrimuseKaraokeModelDownloader/  # System extension for on-demand model downloads
├── PrimuseKit/                     # Models, policies, and stream resolvers shared across iOS/macOS/tvOS
├── PrimuseTV/                      # Apple TV app
├── PrimuseTopShelf/                # tvOS Top Shelf extension
├── PrimuseWatch/                   # Apple Watch app
├── PrimuseWatchShared/             # Models shared by the Watch app and complications
├── PrimuseWatchWidgets/            # Watch complications
├── PrimuseWidgetExtension/         # iOS/macOS widgets and Control Center widgets
├── Frameworks/FFmpeg/              # iOS/macOS/tvOS FFmpeg XCFrameworks
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
| [Citadel](https://github.com/orlandos-nl/Citadel) | SSH/SFTP client |
| [libnfs](https://github.com/sahlberg/libnfs) 8.0.0 (vendored source, `Vendor/LibNFS`) | NFS client |
| [swift-crypto](https://github.com/apple/swift-crypto) | Cryptographic and signing operations |
| [swift-nio](https://github.com/apple/swift-nio) | Asynchronous networking infrastructure |
| [SwiftDraw](https://github.com/swhitty/SwiftDraw) | SVG station-logo and vector-image rendering |

The FTP/FTPS and WebDAV clients are built into the project and do not depend on third-party packages.

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
  → built-in scraper or declarative JSON rules
  → title/artist/album/duration candidate ranking
  → local cache, or SidecarWriteService for supported writable sources
```

### Cross-device data

```text
iPhone / iPad / Mac
  ↔ CloudKit: playlists, sources, settings, history, statistics, library snapshots
  ↔ iCloud Keychain / encrypted credential bundle
  ↔ Apple TV: CloudKit sync or QR-code LAN transfer
  ↔ Apple Watch: WatchConnectivity playback controls and offline file transfers
```

### CI/CD

A change to the version or build number in `project.yml`, or a manual run, triggers the GitHub Actions release workflow. It prepares the Chinese and English changelogs and can create or update the GitHub Release. [Release workflow](.github/workflows/release.yml)

## Notes

Primuse does not provide music or cloud storage. You use your own files, servers, and third-party accounts. Availability depends on each provider, region, account permissions, and API status. Follow the terms of your content sources and all applicable laws.

## License

Copyright (c) 2026 Welape

Except where a separate license notice applies, Primuse is licensed under the **GNU Affero General Public License, version 3 only (`AGPL-3.0-only`)**. See [LICENSE](LICENSE) for the full terms. This software comes without any warranty, including the implied warranties of merchantability or fitness for a particular purpose.

Third-party dependencies and assets with separate license notices remain under their respective licenses. Code previously released under MIT retains its original license; the historical notice below does not grant MIT licensing for subsequent additions or modifications.

<details>
<summary>Historical MIT copyright and permission notice</summary>

```text
MIT License

Copyright (c) 2026 Welape

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

</details>
