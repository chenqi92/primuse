<p align="right"><a href="CHANGELOG.md">中文</a> · <strong>English</strong></p>

# Changelog

---

## [1.9.8] (build 78) - 2026-09-21

This release redesigns key search and immersive-player interactions, expands Apple Music, music-source connection, and startup diagnostics, and fixes Mac full-screen playback, desktop lyrics, and several playback issues.

### Added

- **Editable search results** — reorder or hide song, album, artist, and other result sections; Mac lays sections out side by side, and opening Search focuses the field immediately (#145)
- **Apple Music system picker** — add songs through the system picker, open the subscription flow when needed, and rematch tracks automatically after a storefront change
- **Apple Music quality details** — show actual Lossless, Hi-Res Lossless, and Dolby Atmos availability instead of labeling every track AAC
- **Startup recovery and diagnostics** — report the stage where startup stopped and enter safe mode after repeated failures; diagnostic reports now include system-exit reasons and connection candidates
- **Dynamic detail backgrounds** — album, artist, and genre detail screens use a full-page tint derived from their artwork

### Changed

- **Music source addresses** — enter a Synology QuickConnect ID or Feiniu FN ID directly; Primuse resolves the port, TLS mode, and usable path, and an editable public source can be saved whenever its fallback address works
- **Server playlist sync** — newly created server playlists sync automatically without waiting for a manual scan (#142)
- **Tag reading schedule** — new tracks receive tags before full-library rechecks, WebDAV and NAS reads are faster, and desktop platforms use the fastest level supported by the device
- **Immersive effect drawer** — tap outside the drawer to close it on iPhone; Mac now uses a right-side preview drawer with more reliable full-screen transitions and window restoration
- **Desktop lyric interaction** — when the backing panel is hidden or locked, areas outside the lyrics pass clicks to the window behind, and the panel adapts to the display size (#149)
- **Feedback entries** — About now offers separate "Report a Problem" and "Feature Request" links that open a form with the version, device model, and OS already filled in and editable; only the description is required

### Fixed

- **Apple Music system state** — fixed Lock Screen and CarPlay retaining the previous track after an automatic change, along with recovery, retry, and storefront-change issues
- **Mac full-screen playback** — fixed a disabled effect panel, top controls moving out of bounds or shaking, windows returning off-screen, and the player not tracking its container size
- **Mac search and app icons** — fixed stale counts after clearing search, the old Dock icon flashing at launch, and the default icon not being restored (#145 #146)
- **Album grouping** — tracks from one album are no longer split by track artist, and multi-disc albums keep disc and track order
- **Connection and startup feedback** — connections no longer spin forever on failure, startup and source setup report actionable causes, and server addresses and paths are redacted from logs
- **Lyric editing** — write-permission checks no longer stall, and editing an M4A with grouping metadata preserves its embedded lyrics
- **Memory pressure** — artwork caches are released first when memory is tight, reducing the chance of system termination

### Performance

- **Sources and Home** — faster WebDAV/NAS tag reading, smoother large radio libraries, and more responsive switching between Music and Radio on the Home screen
- **Diagnostic privacy** — connection candidates and failure stages remain useful for troubleshooting while server addresses, paths, and other sensitive values are replaced by stable markers

---

## [1.9.7] (build 73-77) - 2026-09-19

This release adds Guangya Cloud, Synology Audio Station, full radio organization, and more lyric formats, brings Apple Music into the unified music source list, and overhauls landscape layouts, Apple TV decoding, server synchronization, and cross-device transfer.

### Added

- **Guangya Cloud music source** — add Guangya Cloud as a music source, with scanning and playback working like any other source
- **Lyric poster sharing** — turn selected lyrics into a shareable poster image, with adjustable layout and colors
- **Cloud drive folder browsing** — the cloud drive folder hierarchy is rebuilt and music sources gained a folder entry, so you can browse by the original directory structure (#109)
- **Manual playlist ordering** — press and hold a track in a playlist to drag it into a new position
- **Shuffle shortcut** — a shuffle button is now available at the top of the song list and the playback queue (#115)
- **Diagnostic log export** — TestFlight builds can export runtime logs from Storage Management
- **Radio folders, tags, and subscriptions** — organize stations with folders and tags, import grouped playlists, subscribe to playlist URLs, provide image URLs, and display SVG logos (#118 #119)
- **Synology Audio Station** — add Synology Audio Station on iPhone, iPad, Mac, and Apple TV, with songs, playlists, favorites, and SHOUTcast stations synchronized
- **More synchronized lyric formats** — ID3 SYLT, `.elrc`, `.lys`, `.yrc`, `.qrc`, `.vtt`, and `.srt`, preserving `offset`, duet, harmony, translation, and romanization data (#125 #128 #129 #130 #131)
- **Embed lyrics in audio** — save edited synchronized lyrics only inside the audio file or alongside a sidecar, with a file-write warning before enabling it
- **Network-adaptive quality** — Subsonic, Emby, and Jellyfin can use transcoded quality on mobile networks and support reverse-proxy path prefixes (#126 #135)
- **New icons and interface motion** — added adaptive icon themes and a consistent motion system across navigation, cards, lists, artwork, and playback controls

### Changed

- **Apple Music in the music source list** — authorization, library sync, and removal all happen in the music source list, so Apple Music can be added and removed like any other source; once removed, its content no longer appears in search (#112)
- **Scanning continues after leaving the app** — a scan keeps running after you leave the app and resumes where it left off when you return (#99)
- **Server-side deletion sync** — tracks deleted on the server are removed locally, and sources that do not support deletion now only drop the local record (#107 #103 #95)
- **Tag reading backs off** — tag reading slows down automatically when a server returns 5xx, and WebDAV requests and responses are recorded for troubleshooting
- **Music source icon colors** — each music source icon now uses its own brand color
- **Device transfer layout** — the primary action moved to the navigation bar, leaving more room for the list
- **Lyric annotations and translations** — annotations and translations are laid out together with the original line, and foreign-language lines in mixed-language songs are highlighted again
- **iPhone landscape layouts** — Home, Now Playing, lyrics, detail pages, grids, and settings panels adapt to landscape height while rotation and foldable transitions preserve the current page
- **Apple TV compatibility decoding** — tvOS gained the FFmpeg path for WMA, DTS, TrueHD, and other formats unsupported by native decoders
- **Incremental server synchronization** — media servers and Subsonic-family sources stream large catalogs into the library, resume after interruption, and synchronize server tags, artwork, ratings, and deletions
- **Complete offline cache** — offline downloads include server lyrics and artwork, while cached tracks remain playable when their source is temporarily unreachable
- **Chunked Apple TV transfer** — large library snapshots transfer in stages with visible progress, reducing attached artwork automatically when a payload would exceed the receiver limit
- **More efficient iCloud sync** — large playlist and library batches no longer rewrite entire records one by one, and upgrades or restored backups avoid unnecessary full reuploads

### Fixed

- **Embedded artwork** — fixed embedded artwork that could not be read for some tracks after a bulk import and could never be recovered afterwards (#116)
- **External and remote connections** — fixed external music source connections failing and crashing the app, along with fnOS remote connections and their error handling
- **IPv6 addresses** — fixed IPv6 music source addresses failing to connect and directories failing to load
- **Playback queue reordering** — fixed a crash while dragging to reorder; with shuffle on, automatic track changes now match Play Next after reordering (#108)
- **Lyric poster layout** — fixed blank poster previews and clipped layouts
- **Quick favorites editing** — fixed slow opening and laggy input when editing quick favorites
- **Playback speed** — fixed the playback speed control failing to open
- **macOS window buttons** — fixed the window buttons in the top-left flickering while scrolling
- **Playback stability** — fixed occasional crashes when starting playback, stale audio after resume or track changes, replaying a remote track waiting for a full download, and manual skips missing the configured fade
- **Music source recovery** — fixed public sources being marked offline, reverse-proxied WebDAV folders failing to load, SMB timeouts crashing, and deleted then reimported local or remote tracks being unable to return (#111 #134)
- **Artwork and posters** — artwork can be rebuilt after clearing its cache; lyric posters save to Photos again, with motion effects available in every poster style
- **Apple TV and iCloud** — fixed overlapping intelligent-settings screens, iCloud failing to refresh more than once or still exchanging data after being disabled, and missing sync failure details (#123)

### Performance

- **Large server catalogs** — media servers and Plex use paged staging and resumable scans so large libraries no longer slow down as the scan progresses
- **Radio and library** — optimized large station collections and Home switching while reducing repeated view recomputation
- **App size and runtime memory** — reduced Year in Review and icon-preview assets, shared the database layer between the app and widgets, and avoided repeated full-library saves during startup, playback, and metadata backfill

---

## [1.9.6] (build 68-72) - 2026-09-13

This release lets Apple TV add nearly every kind of music source and play Apple Music directly, brings in-place visual editing to the home screen and CarPlay, overhauls the immersive visuals, and systematically addresses large-library scanning, tag-reading heat, and several concurrency problems.

### Added

- **Music sources on Apple TV** — add and scan Synology, QNAP, UGREEN, WebDAV, FTP, SFTP, NFS, S3 object storage, UPnP, and every cloud drive directly on Apple TV (cloud drives now sign in by QR code), along with Jellyfin, Emby, Plex, and Subsonic-family servers, complete with error reporting, two-factor verification, and self-signed certificate trust
- **Apple Music on Apple TV** — play Apple Music directly, search the catalog, albums, and artists, see Apple Music playlists in the playlist tab, and authorize from the search or settings screen
- **In-place interface editing** — lay out the interface on the real screen: rearrange each home screen section and adjust item and row counts, with appearance settings grouped by screen
- **CarPlay layout editing** — edit the CarPlay layout visually and save custom presets, customize the main menu, and use the rebuilt settings grouping and drag editing
- **Immersive visuals overhaul** — the immersive styles were rebuilt with five new scenes, and the spectrum returns in high-fidelity passthrough
- **Ratings and reviews** — rate and review from the library, with improvements to listening charts
- **Station logos and live metadata** — station logo sources are resolved automatically with live metadata during playback, logos appear when adding stations in bulk, and can also be fetched by hand
- **Server playlist and favorite sync** — fnOS, Songloft, Jellyfin, and Plex gained server-side playlist and favorite synchronization
- **VPN and Tailscale routing** — network routing accounts for VPN and Tailscale, with corrected IPv6 address handling; adding a public address to a source leaves existing playback and offline cache intact
- **STRM redirects** — support for media server STRM redirects, with better remote cache retries
- **Whole-song lyric alignment** — lyric timing can be aligned across the whole song, with time conflicts flagged
- **Sleep timer** — the radio player gained a sleep timer
- **Tag reading gears** — reading gears stay in effect after the device heats up, and a pause gear was added
- **Tag check details** — the detail screen was redesigned with consistent cards and a status distribution bar
- **Email a diagnostic report** — send a diagnostic report to the developer straight from the report screen
- **WebDAV restricted deletion** — when the server does not permit deletion, only the local track is removed

### Changed

- **Product name** — the product name is now Primuse everywhere, with 猿音 kept as an alias you can still invoke
- **Tag reading pace** — full-speed reading shows a prominent risk warning first, one extra read slot is granted during playback, and measured throughput is logged along with the limits in effect; background time reclaimed by the system is no longer reported as a read failure; re-reading all tags now runs directly, with per-source re-reads moved to a long-press menu
- **Large library startup and scanning** — faster startup and genre index loading, fewer checkpoint disk writes while scanning, and scan state loading, backfill reconciliation, and the streaming write lock no longer occupy the main thread
- **Playback pipeline** — buffer scheduling moved off the main thread so scrolling no longer follows the decode rhythm; the player queue and audio routing were rebuilt; in high-fidelity passthrough the volume bar defers to the output device's hardware volume
- **Duplicate cleanup** — no longer deletes WebDAV source files, and same-name tracks with incomplete tags are no longer cleaned up by mistake
- **macOS song list** — the top area stays fixed while scrolling, the header is pinned, and sorting and column layout improved
- **Settings cleanup** — groups were reordered with lyrics as their own category, scattered menus merged, and theme colors and app icons laid out as tiles
- **Apple TV interface** — the credential screen dropped its outer frame and explains that passwords can sync from the phone, text scales with the system size, and charts, folders, artists, transfer receiving, and scan folder selection render page by page
- **Detail transitions** — album, playlist, and artist detail screens now expand from their card
- **Lyric spacing** — a line and its translation sit closer together, with more space between lines
- **Sources not yet offered** — fnOS and UGREEN are no longer listed when adding a source; both are waiting on a public vendor API
- **Other** — improved the iPad capsule player layout, home screen cache reuse, music source scroll bars, and the on-state backing for the shuffle and repeat buttons; artist images fall back to track artwork, automatically fetched station logos no longer overwrite manual ones, albums in one folder are no longer split by track artist, and a failed source is no longer probed repeatedly

### Fixed

- **Garbled tags** — fixed garbled and truncated album tags and artist fields bleeding into each other, along with parts of metadata backfill
- **Large library scanning** — fixed scanning not resuming after returning to the foreground, fnOS large-library scans hanging and rebuilding repeatedly, scans not recovering after a backoff, tracks being lost and retried endlessly when a folder errors, tracks being removed when a shared folder becomes unreachable, and WebDAV rescans deleting tracks
- **Concurrency** — fixed library index rebuilds being dropped, backfill patches overwriting each other, and persistence starvation, plus conflicts between background metadata recovery and the streaming cache and races in source background task registration and cache cleanup
- **Endless loading on internal HTTPS** — fixed the certificate confirmation prompt never appearing, which left internal HTTPS sources stuck loading forever
- **Interruptions and track changes** — fixed Apple Music skipping tracks in a row and not advancing at the end of a track, the current track going silent seconds after toggling shuffle, and the player staying stuck on loading after a remote stream stalls
- **Queue dragging** — fixed a crash while dragging the queue; the drag handle was removed in favor of a long press on the row
- **Listening stats** — fixed inflated play counts and durations; actual listening now accumulates from real playback increments
- **DLNA** — fixed a listener restart storm and log backlog that crashed the app, and isolated the retry task lifecycle
- **Duplicate detection** — fixed same-name tracks from different albums being treated as duplicates, along with source file deletion and permission recovery
- **Blank settings screens** — fixed returning from a sub-item to a blank page and the Apple TV entry opening blank, made theme colors and app icons reachable again, and restored the page after leaving settings search
- **CarPlay artwork** — fixed artwork missing from lists and flickering between placeholder and real artwork
- **macOS widgets** — fixed artwork breaking the layout, and the label now reads paused while paused
- **Lyric highlighting** — fixed the highlight landing on the translation when word-level source text and a whole-line translation share a timeline, and wrapped lines no longer highlight both rows at once
- **Apple TV** — fixed shuffle, two-factor verification state and NFS folder reads while scanning, cloud drive QR authorization, whole-library playback and network probing on the home screen, the remote becoming unresponsive in long lists, missing reasons after a failed verification, and a NAS certificate trust loop
- **Energy use and foldables** — fixed log write amplification and a cache cleanup loop, lowering playback energy use, and adapted the layout for foldable screens
- **Other** — fixed a blank top artists section on the home screen, folder classification and a crash when opening a folder, FN Connect access code handling and reconnection failures, custom artwork occasionally disappearing on refresh, users being asked to rate again after rating, and Apple Music sync after a store region change

### Performance

- **DTS playback** — the decoder aggregates output buffers at native granularity, removing scrolling stalls during DTS playback
- **Lists and statistics** — fixed main-thread stalls while playing and scrolling the song list, and stalls when switching listening stats and rendering the macOS calendar

---

## [1.9.5] (build 65-67) - 2026-09-06

This release adds local network device transfers with web-based management, makes local music available in the Files app, introduces the Songloft music source and nine new languages, and greatly speeds up tag reading.

### Added

- **Device transfers** — move music between devices on the local network, picking tracks from the library or managing them from a web page; an iPhone can also send its cached audio to a nearby device
- **Files app access** — local music can be reached directly in the Files app
- **Songloft music source** — support for Songloft, including playlist and radio sync
- **Nine new languages** — nine more interface languages, with localization completed across platforms
- **Live lyrics activity** — live lyrics on the Lock Screen and in the Dynamic Island
- **Listening stats** — the macOS listening calendar gained duration trends and time-of-day breakdowns, and song details show the server-side play count
- **Search scope switching** — search can switch scope and context, with a dedicated button
- **Artist image completion** — missing artist images are filled in automatically
- **macOS folder browsing** — macOS gained a folder browser and folder detail views
- **Quick access artwork style** — the artwork style of the quick access section can be configured
- **Bulk tag re-read on Apple TV** — tags can be re-read in bulk on Apple TV

### Changed

- **Faster tag reading** — SMB tag reading is substantially faster and keeps running in the background, the speed can be adjusted, and full-speed mode gained protection, cooldown, and task recovery, with clearer error reporting
- **Transfer experience** — track selection moved to a tree view, scrolling and loading hold up in large libraries, receiving reports progress and results, transfers can no longer be dismissed by accident, and the switch bar and controls share one style
- **Library browsing** — unified search and detail layouts, improved album results and browse switching, a tighter artist header with consistent album detail cards, and refinements to artist details and genre browsing
- **WebDAV tag backfill** — tags are backfilled on demand while a WebDAV track plays
- **Lyrics compatibility** — support for bracket-style word-by-word lyrics, and older lyric caches are restored
- **Removing local sources** — refined the file cleanup rules when a local music source is removed
- **Network playback overhead** — fewer repeated downloads and less background indexing work
- **macOS interface** — improved player navigation and progress interaction, tool entries and default artwork, the waterfall layout of music source cards, and the server listening stats layout

### Fixed

- **Remote playback** — fixed interruptions, wrongly skipped tracks, and the position jumping backwards
- **Apple Music launch hang** — fixed the app hanging at launch while loading artwork
- **WebDAV disconnects** — fixed a crash caused by continuing to read after a disconnect
- **Cloud drive folder browsing** — fixed folders being unbrowsable right after authorization
- **Internal/external switching** — fixed business errors being confused when a music source switches between internal and external networks, along with network detection and bulk re-reads
- **Album artist detection** — fixed album artist detection and improved browsing of recently added albums
- **Volume snapping back** — fixed the volume snapping back when adjusted while paused
- **Minimal mode** — fixed page spacing and the player covering content
- **Tag reading failures** — isolated read failures and lowered the detail screen's overhead, and corrected the speed shown after switching gears
- **Apple TV** — fixed library scanning, syncing, and playback
- **macOS folder navigation** — fixed folder navigation and improved the player's information display

### Performance

- **Tag reading scheduling** — the high-performance read entry moved to the music source and adapts to device capability, with improvements to the Apple TV queue

---

## [1.9.4] (build 59-64) - 2026-09-03

This release adds end-to-end encrypted music sharing, Smart Mix beat-matched transitions, and streaming smart playlists, connects to China Telecom Cloud, and fixes wireless output and lost player state.

### Added

- **Music sharing** — any readable source can produce a secure playback link, with short codes, permanent links, guess-resistant protection, and end-to-end encryption; use the built-in service or host your own, with Cloudflare relay and dual-mode deployment
- **Smart Mix** — analyzes beats and blends tracks with segmented transitions
- **Streaming smart playlists** — smart playlists fill in as they generate, the recommendation queue updates with the stream, and already-generated results survive a source switch
- **China Telecom Cloud** — support for China Telecom Cloud, including protocol integration and security validation
- **Local network cache sync** — sync audio cache to a chosen device on the local network
- **Refresh lyrics from the source** — pull lyrics again from the music source, with translation fields and safe editing
- **Widget lyrics** — widgets display long lyrics and stay in sync with playback
- **Swipe for queue actions** — swipe in the song list to act on the playback queue
- **macOS search filters** — filter search results by song, album, artist, or lyrics
- **Standalone playback on external devices** — external devices can play audio on their own
- **Multichannel M4A** — system audio playback supports multichannel M4A
- **Navidrome scan at launch** — scans at startup, and playlists keep an offline copy automatically

### Changed

- **Minimal mode** — rebuilt the top navigation and floating player, with adjustments to the home screen, search, and settings, and smoother detail transitions
- **Music source fingerprints** — security fingerprint checks are consistent across platforms
- **DLNA** — speaker discovery and the receive switch are now independent
- **System Now Playing** — line-by-line lyrics are enabled by default
- **Apple Music interruptions** — added an audio session interruption policy with better handling and recovery
- **Apple TV immersive playback** — the screen stays awake during immersive playback
- **Deleting large sources** — improved cache reclamation when removing a large music source
- **Local scanning and backfill** — improved local scanning and metadata backfill, with fewer redundant writes of source sync state
- **Siri guidance** — refined the example phrases and added guidance for requesting a specific song

### Fixed

- **Wireless output** — fixed silence and noise after the wireless output configuration changes, and corrected audio focus when AirPlay returns to the device (#80)
- **Lost player state** — fixed the player being cleared after a long spell of background playback, and state being lost on an automatic track change
- **Playback clock crash** — fixed a crash in the playback clock after an audio interruption
- **Navidrome track changes** — fixed consecutive track changes getting stuck loading
- **Cache deadlock** — fixed a concurrency deadlock in the remote streaming cache
- **Folder selection hangs** — fixed hangs during multi-protocol folder selection and when deleting a recent music source
- **Cache cleared on upgrade** — fixed the audio cache being wiped during an upgrade
- **Player interaction** — fixed a progress bar that could not be dragged and a stall when first expanding the player
- **Batch action bar** — fixed the batch action bar being covered by the tab bar
- **Lock Screen lyrics** — fixed lyrics occasionally missing on the Lock Screen and in widgets
- **Recommendation queue** — fixed playback stopping at the end of the recommendation queue
- **DLNA discovery** — fixed devices not being found when several network interfaces are present
- **Remote lyric writeback** — fixed read-back validation after writing lyrics
- **Disabled music sources** — fixed the queue still trying to play from a disabled source
- **Guest credentials** — fixed scan state becoming incompatible after switching credentials on a guest source
- **macOS window notifications** — fixed a concurrency crash in window notifications
- **Apple TV** — fixed focus jumps in the top tabs, playback recovery, and Subsonic lyric loading
- **Other** — fixed media server library folder classification, home screen radio artwork loading, Daoliyu playback not preserving the original audio, and internal source identifiers leaking into scraper search results

### Performance

- **WebDAV scanning** — lower scanning load, with a faster tag detail screen

---

## [1.9.3] (build 53-58) - 2026-08-31

This release expands intelligent services with multi-vendor support and cross-device sync, adds server-side listening stats and audio transcription, and polishes word-by-word lyric display and alignment.

### Added

- **Multi-vendor intelligent services** — support for several protocols and vendors, with model lists fetched online, automatic fallback when a service is unavailable, and settings synced across devices
- **Built-in intelligent service** — a built-in service protected by device verification, usable without configuring your own key
- **Smart recommendations** — the library generates recommendations by scenario, themes can be reviewed and deleted, and the home and recommendation areas show loading skeletons
- **Audio transcription** — transcribe a track's audio and use it to improve recommendations
- **Server-side listening stats** — read listening statistics from supported music services, falling back to a cached snapshot when offline
- **Custom lyric colors** — lyric colors can be customized, including gradients
- **Artist artwork** — artist artwork is detected automatically and can also be set by hand
- **Multi-artist parsing** — split multiple artists by rule, with protection for names that should stay intact
- **Dynamic album artwork** — support for animated album artwork provided by a source
- **Radio with Siri** — search for and play stations with Siri
- **Bulk clear recently deleted** — safely empty recently deleted items in bulk
- **Navidrome auto-refresh** — refreshes when the app returns to the foreground, and playlists always keep an offline copy

### Changed

- **Intelligent service settings** — the settings screen was rebuilt with a consistent look on every platform, further simplified on phones, with clearer wording, separate test and production environments, and an explicit note that an OpenAI API key is not a ChatGPT subscription
- **Request scheduling** — improved quota feedback and request scheduling, with background recommendation refreshes limited
- **Multi-format tag reading** — more file formats are supported, with diagnostics for failed reads
- **Background tag completion** — each pass is bounded so it no longer runs long
- **Lyrics and immersive visuals** — rebuilt the full-screen lyric layers and multi-layer text field, refined the immersive text animation and exit flow, and smoothed the flowing lyrics on the title wall
- **Tag check details** — redesigned the mobile layout, simplified the information hierarchy, and distinguished the "not fully checked" state
- **Playlist import** — moved into the library actions
- **Search** — keyword path search and intelligent results now coexist
- **macOS interface** — the app name no longer appears in the title bar, and long song lists scroll more smoothly

### Fixed

- **Word-by-word lyrics** — fixed word truncation and layout for right-to-left languages, highlight jitter in Persian, the first line highlighting early during an intro, delayed highlighting across ELRC silent gaps, interrupted highlighting on overlapping vocal parts, and the next track's lyric progress during a crossfade
- **Lyric language and translation** — fixed misdetected languages causing the translation prompt to block repeatedly, and lyrics without a language tag now lay out in the right direction
- **Intelligent service connections** — fixed built-in service authentication and device verification, DeepSeek endpoint authentication and unresponsive structured generation, and added connection diagnostics
- **Tag reading** — fixed backfill not starting after a cloud drive scan, local read failures reporting nothing, cloud re-reads marking valid audio as invalid, and overheating caused by background reads
- **Startup crash** — fixed a crash at launch when the library contains duplicate artists, along with stalls and a toolbar crash on the artist detail screen
- **Background indexing** — fixed the library background index running under sustained high load
- **Apple Music startup sync** — fixed stalls caused by syncing at launch
- **Remote sources** — fixed paths with special characters and form encoding, plus DTS duration detection and migration of historical data
- **Playback position** — fixed seeking having no effect while paused
- **macOS** — fixed a misplaced and disappearing title bar, stalls when scrolling and loading long lists, wrapped track numbers in the song list, a regression in native widget configuration, and widget play buttons that could not be tapped directly
- **Apple TV** — fixed focus and remote interaction, and improved music source and library responsiveness

---

## [1.9.2] (build 42-52) - 2026-08-26

This release brings word-by-word lyric timing and a unified immersive player across platforms, adds intelligent services with semantic search and direct local file references, and resolves HTTPS certificate handling, large-library stalls, and invalid music sources being saved.

### Added

- **Word-by-word lyric timing** — adjust the timeline word by word, with a scrolling policy for long instrumental gaps, plus Lock Screen lyrics and native favorite actions
- **Immersive playback** — a unified immersive full-screen player on iPhone, Mac, and Apple TV, with a redesigned real-time waveform, a queue-driven title wall, and customizable visual effects
- **Intelligent services and semantic search** — extensible intelligent services backing a non-blocking semantic library search, with results ordered by best match
- **Direct local file references** — reference local files and folders directly with persistent authorization, and referenced folders sync automatically
- **Custom album and playlist artwork** — replace album and playlist artwork with your own
- **Theme color from artwork** — the theme color follows the current artwork on all three platforms
- **Server radio sync** — sync stations from the server, including Subsonic station artwork
- **Two-way favorite sync** — favorites sync both ways with Emby and Navidrome, rolling back on failure
- **Google Drive folder selection** — authorize through the Google Drive Picker and choose folders
- **Baidu Netdisk snapshot sync** — snapshot synchronization for Baidu Netdisk sources
- **WebDAV tag writeback** — audio tags and artwork can be written back to WebDAV sources
- **Song list sorting and alphabet index** — sort the list and jump with an alphabet index
- **Delete from the playback queue** — remove tracks directly in the queue, with stronger drag feedback (#40)
- **macOS library navigation** — detail views open inline, the playlist grid adapts to the window, and playlists can be managed from the sidebar
- **SMB scan folders** — pick an SMB leaf folder or the share root as the scan target
- **Volume slider visibility** — choose whether the volume slider is shown

### Changed

- **Boundaries for intelligent services** — device-specific credentials no longer sync to the cloud, API keys are isolated per service address, plaintext connections are limited to private addresses, requests have timeout and response size limits, and stale results are dropped when the store region changes
- **Recently deleted** — the retention period is now 30 days everywhere
- **Consistent player appearance** — themes and immersive playback look the same across platforms, with adjusted radio colors and a tvOS dual theme
- **Lyrics display** — improved alignment and blur, with depth of field on non-current lines
- **Audio cache** — refined the cache size limit and shutdown behavior
- **Bluetooth and CarPlay** — better Bluetooth playback, with improved CarPlay playback and interface management
- **Insecure connection warnings** — completed the localized warnings for plaintext HTTP
- **macOS and iPad interaction** — improved macOS back navigation and batch actions, restored the iPad player's track-change gesture, and shrank the control icons on the expanded mini player

### Fixed

- **HTTPS certificates** — fixed the certificate prompt blocking playback from internal sources, falling back to the public endpoint after a certificate renewal, self-signed WebDAV certificates that could not be confirmed, and trusted sources stalling after a certificate change
- **Invalid music sources being saved** — a source is no longer created when SMB verification fails, a Jellyfin configuration is invalid, or media server authentication fails; cancelling a new WebDAV source leaves nothing behind, and deleted sources no longer come back
- **Audio interruption recovery** — fixed wrongly skipping tracks and auto-playing after an interruption, playback now resumes after a long interruption, and the playback session is no longer lost at startup
- **Remote playback downloads** — the first track after a cold launch no longer waits for a full download, seeking no longer stalls on a complete download, and a single track download is no longer shown as caching the whole source
- **Lyrics compatibility** — fixed right-to-left lyrics, plain-text lyrics disappearing after a rescan, and recognition and encoding of embedded lyrics in ALAC/M4A files
- **Artwork recognition** — valid embedded artwork is no longer rejected as incompatible, compilations group by album artist, a missing album cover falls back to the track cover, and playlist artwork resolves the same way on every platform
- **Baidu Netdisk** — fixed library identity and refresh safety after a file is moved, reconciliation when a file is replaced in place, and successful writebacks being reported as failures
- **Google Drive** — hardened sidecar writes, and fixed multi-format lyric writeback and scan folder authorization
- **Navidrome over the public network** — fixed authenticated playback of tracks that are not cached, and interrupted incremental refreshes with missing folders
- **Apple TV** — fixed a cold-launch crash caused by the dynamic theme color, slow appearance switching, storage capacity checks, and focus styling for the play button and search
- **macOS windows** — restored the native window control buttons and the title bar button container, and made the sidebar resizable again
- **Full-screen player** — fixed the exit interaction and touch input after rotation, along with the effect picker size and progress bar position in landscape
- **Background maintenance** — fixed maintenance tasks waking repeatedly, and isolated them from local source sync
- **Other** — fixed a write-permission precheck that never finished, selection and delete protection during duplicate cleanup, an incorrect high-fidelity output sample rate, tag backfill not retrying after a source recovers, and the iPad player covering content while the artwork picker closed immediately

### Performance

- **Large libraries** — shorter cold launches, less contention while resolving metadata, and fewer stalls in the foreground and when switching between foreground and background
- **Long lists and large queues** — improved rendering of large song lists and alphabet index jumps, and fixed high CPU use from a failing source in a large queue
- **Incremental merging** — lower memory use when merging library changes, and faster playlist artwork generation

---

## [1.9.1] (build 37-41) - 2026-08-14

This release adds server playlist sync and folder browsing, brings batch actions to the song list, and introduces smart transitions with silence skipping.

### Added

- **Server playlist sync** — playlists from Jellyfin, Emby, and Plex are mirrored locally and kept in sync
- **Folder browsing** — browse songs by the folder hierarchy of their source, including cloud storage directory structures
- **Batch actions** — select multiple songs in the list and act on them together
- **Smart transitions and silence skipping** — smooth transitions between tracks, with leading and trailing silence skipped automatically
- **Swipe the mini player** — swipe left or right on the mini player to change tracks
- **Apple Music playlist hierarchy** — the Apple Music library is presented by playlist
- **WebDAV media redirects** — playback can follow a redirect to a CDN, easing load on the origin server
- **Lyrics format conversion** — convert between lyrics formats, with better detection of the format in use
- **Media server lyrics** — stronger lyrics support across several media servers
- **Radio visibility on the home screen** — choose whether the radio section appears on the home screen
- **macOS keyboard shortcuts** — shortcuts can be customized

### Changed

- **Large queue rendering** — improved rendering of very long queues, and added a folder playback entry
- **Large library sorting** — sorting now reports progress
- **Player controls** — unified button sizes and layout on the player screen
- **Apple Music caching** — improved the playback cache strategy and search focus handling in the title bar

### Fixed

- **Garbled file names** — fixed recovery of garbled names for cloud drive tracks, so song details no longer misjudge their state
- **Deleted playlists coming back** — a deleted playlist is no longer restored by server sync
- **WebDAV reverse proxies** — fixed directory reads and media redirects behind a reverse proxy
- **MP3 duration** — fixed MP3 duration calculation and its retry logic
- **Batch action boundaries** — hardened batch actions and deletion boundaries, and improved folder multi-selection
- **Large library sorting and selection** — improved sorting and multi-selection in large libraries, with an adjusted batch action bar
- **Saving re-timed lyrics** — fixed scraped lyrics failing to save after being re-timed
- **Cloud drive scanning** — hardened cloud drive scanning and metadata backfill
- **Playback intent and interruption recovery** — unified playback intent and the state restored after an interruption
- **macOS Now Playing** — fixed a crash on the Now Playing screen, and restored the spacebar playback shortcut

---

## [1.9.0] (build 30-36) - 2026-08-10

This release adds a localized interface and Siri voice requests, makes the theme color customizable, and gives the home screen separate music and radio modes.

### Added

- **Localized interface** — in-app text is localized and follows the system language
- **Siri requests for local music** — ask Siri to play tracks from your local library
- **Custom theme color** — pick a theme color, or pin it so it no longer follows the artwork
- **Home screen modes** — switch the home screen between music and radio, with the radio wall adapting to screen orientation
- **Adaptive connections** — a music source can hold several endpoints and picks whichever one works on the current network
- **Favorite from the Lock Screen** — mark a track as a favorite straight from the Lock Screen widget
- **Drag to reorder the queue** — reorder the playback queue by dragging
- **Full-screen lyrics editing** — edit lyrics in full screen, including multi-language lyrics
- **Remote WAV playback** — improved playback support for remote WAV files

### Changed

- **Simpler music source setup** — connection preferences were removed; adaptive connections decide how to reach a source
- **Lyrics editor** — the editing interface and its playback sync were rebuilt
- **Buffering and album scraping** — improved buffer management, and album detail pages can trigger scraping directly
- **Scan progress** — scan progress is clearer, and cloud sync errors are reported honestly
- **Rating prompt** — adjusted when the App Store rating prompt appears, with improvements to backups

### Fixed

- **Cloud music sources after upgrade** — fixed some cloud music sources not being restored after an upgrade
- **Offline cache and Navidrome scanning** — fixed the offline cache and sped up Navidrome scans
- **Public HTTP and endpoint trust** — improved compatibility for public HTTP connections and endpoint trust
- **Radio management** — stations can be managed directly from the list
- **Song sorting** — smoother interaction while sorting
- **Repeated tag reads** — server libraries no longer read the same track's tags repeatedly

---

## [1.8.3] (build 28-29) - 2026-08-06

This release brings internet radio to iPhone, Mac, and Apple TV, and adds incremental sync and STRM support to the library.

### Added

- **Internet radio** — listen to internet radio across Apple platforms, with prioritized station browsing that makes stations easier to find
- **Incremental sync and STRM** — the library supports incremental sync and recognizes STRM files

### Fixed

- **Synology scanning** — fixed scanning with two-factor verification and over public HTTP
- **Scan error reporting** — a failed music source scan now shows the real reason instead of a generic error
- **Player screen** — improved interaction and startup speed on the player screen
- **Car display artwork** — artwork shown in the car now matches the current track

---

## [1.8.2] (build 27) - 2026-08-04

This release adds immersive lyrics, lyrics editing, and the Drime cloud drive, plus Synology QuickConnect and fnOS FN Connect remote connections.

### Added

- **Immersive lyrics** — a landscape full-screen lyrics mode with its own playback controls, and full-screen music videos
- **Lyrics editing** — edit lyrics directly and write them back to the source
- **Drime cloud drive** — connect to and play from Drime, including writes, deletions, and permission handling
- **Synology QuickConnect** — QuickConnect picks the best way to reach the server
- **fnOS FN Connect** — connect remotely through FN Connect

### Changed

- **App icon** — the icon system and its theme configuration were rebuilt

### Fixed

- **Plain-text lyrics** — fixed highlighting and tap behavior for plain-text lyrics
- **ELRC lyrics** — improved ELRC synchronization and auto-follow
- **Remote playback** — fixed silent remote playback, and a dropped stream skipping the whole track
- **Playback session recovery** — the playback session is restored and the system playback state stays in sync
- **Now Playing artwork** — cached artwork refreshes properly, and switching between lyrics and artwork works again
- **Home screen on launch** — improved the launch home screen and library artwork presentation

---

## [1.8.1] (build 26) - 2026-08-02

This release adds the Daoliyu and fnOS Music sources, improves how scraping candidates are ranked and reported, and fixes a range of Synology playback, credential, and cross-device sync issues.

### Added

- **Daoliyu music source** — Daoliyu can now be added as a music source
- **fnOS Music source** — support for fnOS Music, including a direct connection to the standalone app, with improved credential handling
- **Apple TV transfer** — a more complete transfer flow to Apple TV, with clearer error reporting

### Changed

- **Playback buffering** — the buffer is now bounded by both duration and item count, with matching work on the playback service and decoder
- **Scraping candidate ranking** — manual scraping candidates are ranked by duration and match quality, with an accuracy hint
- **Remote tag reading** — remote tags are parsed in memory, cutting disk writes and repeated downloads
- **NFS connections** — the NFS client and its connection management were rewritten

### Fixed

- **Synology playback** — fixed DTS failing to recover after an interruption, next-track pre-caching not working, and incorrect DTS durations, along with metadata and queue advancement
- **Gapless playback** — fixed track duration being lost during a gapless transition
- **Mixed queue continuation** — a failing source no longer stops the whole mixed queue
- **Playback progress** — fixed the playback position being displayed incorrectly
- **Remote artwork** — fixed the system Now Playing view failing to load artwork for cloud drive tracks
- **Credential storage** — fixed credentials failing to save, and corrected the background on an external display
- **Public HTTP connections** — trusted NAS devices can connect over public HTTP
- **Subsonic compatibility** — improved authentication and response parsing for compatible forks
- **Scraping writeback** — read-only sources are no longer asked to write scraping results back
- **NAS metadata refresh** — NAS metadata is refreshed and the outcome reported honestly
- **Automatic scraping matches** — fixed matching for structured file names
- **Lyrics position** — fixed the current lyric line after scraping finishes
- **Large tags** — fixed reads failing on very large ID3 tags and on files with a trailing moov atom
- **Apple Music imported library** — imported library content now plays correctly
- **Playlist batch scraping** — batch scraping now reports progress and results
- **Duplicate cleanup** — fixed how read-only files are handled during cleanup
- **macOS title bar** — fixed dragging and double-click zoom on the title bar
- **macOS search and lyrics** — the search field is centered and the lyrics player can be collapsed
- **iOS volume bar** — fixed the volume bar layout, and cellular data notices no longer repeat
- **Player appearance** — fixed artwork-based theming and light/dark switching
- **tvOS artwork fallback** — smoother fallback between placeholder and real artwork
- **Apple TV snapshots** — fixed a failed snapshot being reported as successful
- **Large library loading** — improved responsiveness when loading large libraries and translating lyrics

---

## [1.8.0] (build 25) - 2026-07-28

This release brings CUE sheet and DTS playback on a high-fidelity decoding pipeline, along with a round of fixes for playback queues, lyrics, CarPlay, and Apple Music.

### Added

- **CUE and DTS playback** — play CUE-split albums and DTS audio through the high-fidelity FFmpeg decoding pipeline
- **Delete playlists on iPhone** — playlists can now be deleted directly on iPhone

### Changed

- **Audio decoder rework** — the decoder can start from a given time and applies backpressure flow control, making seeking in long tracks more reliable
- **Now Playing scraping and lyrics** — metadata scraping is now a single entry point, with matching adjustments to the lyrics display
- **Quick favorites** — quick favorites can be reordered, and turned off entirely

### Fixed

- **Duplicate track-end handling** — fixed a track's end triggering the next-track logic more than once
- **Shuffled and mixed queues** — fixed shuffled and mixed-source queues stopping partway through
- **Apple Music queues** — fixed queues failing to advance, preserved mixed queues and manual scraping results, and kept official artwork while scraping lyrics
- **Lyrics display** — added a fallback when lyrics cannot be fetched, and stopped the lyrics view from jumping around
- **CarPlay** — fixed duplicate Now Playing templates, and artwork the server returns in an incompatible form is now converted first
- **Subsonic lyrics** — the lyrics endpoint is chosen by server capability, so compatible forks no longer come back empty
- **Concurrent playlist edits** — playlists edited on several devices at once no longer overwrite each other
- **macOS song actions** — fixed the context menu acting on the wrong track, and restored local folder scanning
- **Volume sync** — playback volume on iPhone now follows the system output
- **High-fidelity mixer** — fixed mixer conflicts and metadata reads in high-fidelity audio graph mode
- **Tab bar** — the tab bar no longer disappears when nothing is playing
- **Placeholder scraper endpoints** — scraper endpoints with no real content are skipped, cutting down pointless requests
- **Search index** — cancelling indexing normally no longer reports an error

---

## [1.7.3] (build 24) - 2026-07-26

This release consolidates changes made after 1.7.0 that had not yet been documented, with a focus on very large libraries, real multi-source deletion, Apple Music, Baidu Netdisk, search playback, CarPlay, and cross-device sync.

### Added

- **Real deletion across music sources** — duplicate cleanup can call each source's deletion capability instead of only removing local records, with batching, progress recovery, and retry support
- **Mixed-source playback queues** — one queue can continuously play local, NAS, cloud-drive, Subsonic, and media-server tracks
- **Persistent search index** — indexes titles, artists, albums, Pinyin, and lyrics for faster large-library search and lyric hits
- **Airsonic compatibility mode** — handles the Subsonic API differences in both classic and Advanced releases across scanning, artwork, lyrics, and Range playback
- **Remote notification support** — adds the app-level registration and handling foundation for remote notifications
- **CarPlay search entry** — adds an always-visible Search row to songs, albums, artists, playlists, and recent items, with recent phone search terms and matching results available in-car

### Changed

- **Apple Music library sync** — rebuilt synchronization, identity mapping, and play-history association to reduce duplicates and stay aligned with the system library
- **Apple Music lyric scraping** — service-owned work now continues after the player collapses and stores lyrics against the canonical song identity
- **Source scanning** — added directory-selection sessions, batched scan mutations and checkpoints, and improved FTP continuity and remote metadata parsing
- **Source counts** — source cards are reconciled against the device's actual library instead of displaying stale cloud snapshots or historical scan totals
- **iCloud lyric snapshots** — oversized inline payloads progressively shrink to the newest subset that fits instead of dropping the whole lyric snapshot
- **App icons and cloud sync** — refreshed the icon system and reduced unnecessary synchronization and view updates

### Fixed

- **Baidu smart duplicate cleanup** — validates every per-file batch result so partial failures are not reported as success or written as false local deletions
- **Baidu large-directory scans** — retries transient read failures and rate limits with backoff instead of abandoning the selected directory
- **Search-result playback crash** — keeps the tab and bottom-player view structure stable while the system search controller is dismissed
- **CloudKit and SMB crashes** — disables sync safely when CloudKit entitlements are unavailable and serializes SMB session lifecycles to prevent scrape-write/disconnect races
- **Batch-scrape accuracy** — uses stable remote identity seeds and confidence-based matching, keeps duplicate copies consistent, rejects overlapping batches, and stops repeated writes to read-only or unauthorized sources
- **Large-library stalls** — fixed cold-launch, song-list refresh, background scraping, and bulk-cleanup paths that could freeze the UI or trigger the scene watchdog
- **Duplicate cleanup** — fixed stale results, interrupted batches that could not resume, and missing real deletion for Baidu sources
- **Local-file recovery** — safely rebases old sandbox paths into the current container and stops custom local sources from being redirected to the managed import folder
- **Local playback caching** — local files no longer enter the remote offline-cache pipeline, preventing duplicate storage and misleading warnings
- **MV pause behavior** — pausing video also cancels the full-file background download while retaining its partial file for later use
- **Scraping and translation logs** — empty titles no longer query online providers, and lyrics already in the target language no longer create no-op translation failures
- **Simulator credentials** — uses local Keychain items when synchronizable Keychain attributes are unavailable, preserving credentials across app restarts
- **Audio session startup** — cold launch no longer interrupts audio already playing in another app
- **Local source platform labels** — adding a local source on macOS no longer shows “iPhone Storage” or an iPhone icon; it now uses “Mac Storage” and a computer icon, and tvOS uses Apple TV chrome if a local source is present
- **Malformed media and playback menus** — hardened invalid inputs, Now Playing menu updates, and lyric-scrolling edge cases

### Performance

- **Library lookup** — replaces repeated full scans with caching and a persistent search index, reducing CPU while typing in very large libraries
- **Scanning and cleanup** — batches song mutations and lowers checkpoint and UI publication frequency instead of persisting once per track
- **Foreground batch work** — requests the finite iOS background-execution window only after the app actually backgrounds, eliminating long foreground-scrape warnings
- **Lyrics and Now Playing** — reduces view recomputation from lyric scrolling and playback progress while keeping menus stable during high-frequency updates

---

## [1.7.2] (build 22-23) - 2026-07-25

This release adds mixed-source queues, real deletion across music sources, and a persistent search index, while improving large-library startup, list refreshes, and background batch work.

### Added

- **Mixed-source queues** — local, NAS, cloud-drive, Subsonic, and media-server tracks can play continuously in one queue
- **Real cross-source deletion** — duplicate cleanup deletes original files according to source capabilities, with batching, recovery, and retry support
- **Persistent search index** — indexes titles, artists, albums, Pinyin, and lyrics for faster large-library lookup
- **Remote notification foundation** — adds app registration and message-handling support for remote notifications

### Changed

- **App icons and cloud sync** — refreshed the icon system and reduced unnecessary synchronization and view updates
- **Large-library work** — song-list refreshes, bulk cleanup, and background scraping now process changes in batches to reduce foreground stalls

### Fixed

- **Baidu Netdisk cleanup** — validates each batch deletion result and retries transient failures instead of reporting partial failures as success
- **Malformed media and playback menus** — hardened damaged inputs and Now Playing menu state updates
- **Audio session startup** — cold launch no longer interrupts audio already playing in another app

---

## [1.7.1] (build 21) - 2026-07-21

This release reorganizes music-source management and folder selection, focusing on lower scanning-write and interface-refresh overhead.

### Changed

- **Music source management** — optimized source-state handling and remote metadata parsing, with folder selection moved into a dedicated session before scanning starts
- **Batched scanning** — groups song mutations, checkpoint writes, and interface publication instead of persisting every item independently

### Fixed

- **FTP scan continuity** — transient read failures no longer abandon the entire folder scan, and remaining items continue after recovery

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

- **NAS support status** — UGREEN UGOS and Feiniu fnOS now show as unavailable while awaiting vendor-supported public APIs and can’t enter the new-source setup flow
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
- Added playlist shuffle and refined experimental UGREEN NAS API scaffolding (not a supported integration)

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
- Hardened QNAP, S3, Last.fm, and DLNA protocol handling and refined experimental UGREEN NAS API scaffolding

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
