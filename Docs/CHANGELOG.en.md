<p align="right"><a href="CHANGELOG.md">中文</a> · <strong>English</strong></p>

# Changelog

---

## [1.13.1] (build 132-133) - 2026-11-13

This release includes 67 changes.

### Highlights

- The Primuse app icon contest is open. [Submit your design or vote for your favorites.](https://palveni.com/zh-hans/funbox/primuse-icon-vote)
- Fixed a crash during podcast sync when an episode artwork URL was invalid

### Added

- Adjust lyric timing for an individual song from the player.
- Choose whether Primuse sends playback history to your music server.
- Tap the yellow warning beside a track to see why its offline download failed.
- Batch rename song titles and preserve other tag edits when saving a single track
- Swipe left or right on the iPhone Library to switch between visible categories

### Changed

- Read back artist and album biographies from compatible servers such as Navidrome.
- Rectangular artwork fills more of the square preview.
- The player dial header fits on one line, and the dial follows the speed of your swipe when you lift your finger.
- Lyric color options display their corresponding colors.
- Show or hide the Music category from the switcher at the top of Home.
- Apple TV animates page changes and the opening and closing of sheets.
- Fullscreen effect previews show a placeholder before fading in individually.
- Split genres by slash, comma, or vertical bar (`|`)
- Lyrics fetched mid-playback are now pushed to Apple Watch as well
- Library Audiobooks now shows book count and total chapter count
- Combine Search with other tabs in the bottom tab bar
- Choose Tile or Spotlight card layouts for song lists
- Reorganized the player dial into four faces: Tuning, Discover, Up Next, and Stage
- Reclaim cache storage faster after deleting or disabling a music source
- Split ID3 genre tags (such as MP3) by slash so multiple genres are indexed completely
- Swipe left or right to switch music categories in minimal navigation
- Use videos as animated artwork for songs and albums
- Display animated artwork on the Lock Screen
- Added tactile press feedback on song rows and a particle burst animation when liking a track
- Unified the bottom toast banner and added visual confirmation on the mini player when swiping to queue
- Slide large player artwork in and out following the track change direction
- Expand album pages smoothly from the hero banner, recommendations, and artist latest release cards
- Staggered entrance animations for Home sections on cold launch and springy empty-state icons
- Continuous mini-player progress bar movement and animated transitions for playback mode, counters, and completed downloads
- Open Audiobooks directly to the last viewed bookshelf on launch
- Separate white noise, rain, and other ambient sounds from music automatically
- Loop ambient sounds seamlessly by default with a dedicated ambient player layout
- Added a setting to disable automatic separation of ambient sounds
- Tightened player dial layouts and prioritized vertical scrolling when swiping across the EQ curve
- Refined tilt angles for Tile and Spotlight song list styles and allowed two-line titles on Spotlight cards
- Assign sound-matched icons and colors to ambient tracks without artwork, and fit the sleep timer row on narrow screens
- Display the library preparation status inline with the Audiobooks shelf header on launch
- Cover the previous artwork cleanly during track transitions instead of blending two semi-transparent covers
- Count audiobook chapters in the Library using embedded file chapters
- Use ambient-specific quick timer presets on the ambient player sleep timer sheet
- Keep the mini player from floating above lists when the keyboard appears
- Match cold-launch Home placeholders to the actual layout so the hero section no longer jumps when content loads
- Open new category pages immediately in minimal navigation without a brief blank state on the Songs page
- Allow opening Music from Home even when the Music category is hidden in the tab bar
- Configure Keep Screen Awake and dim delay per device during playback
- Wait for iCloud files to finish downloading before backfilling missing audiobook chapter counts
- Keep the Home play button position stable on cold launch when the library has fewer than four covers
- Read repeated ID3 genre tags completely and refresh genre indexes across libraries
- Save full-length album and artist biographies without truncation
- Hide the navigation bar background on the Apple Watch playback progress screen
- Respect the minimal paging toggle when swiping horizontally in the iPhone Library while avoiding the alphabet index
- Allow switching Library categories horizontally while the iPhone library is still loading
- Added standalone visibility toggles for items in the player More menu
- Seamlessly tile the four covers on the Home welcome card
- Sort mixed Pinyin and English titles consistently across the library, playlists, and folders

### Fixed

- Cancel bulk artwork and lyric downloads more promptly in large libraries.
- Restoring a shuffled queue on cold launch no longer activates the system playback session unexpectedly.
- Fixed widget artwork refresh compatibility on earlier macOS versions
- Fixed unresponsive Confirm Import and Done buttons in Apple TV scraping settings
- Fixed an occasional blank white screen on launch
- Fixed Mac widget artwork occasionally not updating
- Fixed mini lyrics not appearing on the minimal player bar on earlier OS versions
- Fixed lyrics remaining white even when artwork color matching was selected
- Fixed scrolling stutter on the Mac Home page on macOS 15
- Fixed Previous and Next buttons not responding on the first press after restoring an Apple Music queue

---

## [1.13.0] (build 125-131) - 2026-11-11

This release includes 104 changes.

### Added

- Word-by-word timing alignment for existing lyrics
- Added a 256 kbps option for online and offline audio quality
- Improved SACD support on all three platforms and added DVD-Audio and data ISO support
- Added playback history and smoother switching between statistics views
- Choose your own GIF as an animated cover; streamlined the lyrics menu entry
- Customize which tabs appear in the bottom bar, with the Settings entry always kept
- Preview albums are hidden from Recently Added by default, with a toggle to show them
- CarPlay lyrics position and dynamic audio format settings
- CarPlay Recently Added can be shown by album
- Lyrics source shows online and embedded candidates, and you can switch between them
- Apple Music artist photos are preferred, and you can fetch them again manually
- More repeat modes, a combined playback mode button and A–B repeat
- Lyrics color can now be taken from the album cover
- Bios can be fetched from MusicBrainz; Apple Music bios are used only for Apple Music albums and artists
- Apple TV can add songs and albums to your own playlists
- Multiple genres can be selected in the tag editor

### Changed

- Improved CarPlay layout editing and fixed the bottom of the bookshelf
- Completed automatic loudness leveling and ReplayGain settings on all three platforms
- Offline downloads are now separate from the playback cache
- More transcoding format options for online and offline playback
- ReplayGain status is shown in the audio quality info
- Added loudness analysis status and a separate badge toggle
- Existing album artwork is kept; updated to 1.13.0 (125)
- Lower overhead when cleaning cache for deleted music sources
- Improved cache reclamation for deleted sources while protecting shared artwork
- Library entry appears earlier, and metadata reading progress is restored
- Shows the time of the last Apple Music library sync
- Cached lyrics update promptly in the mini player and Picture in Picture
- Simplified the TV settings layout while keeping helper text
- Improved media import, share codes and offline settings backup
- Improved audiobook titles and chapter switching on the Lock Screen
- Streamlined artist release cards and scraping save actions
- Unified the background color of the TV search page
- Skips invalid items when sharing radio stations, podcasts and audiobooks
- Generic Subsonic playback and lyrics prefer token authentication
- Word-by-word lyrics rise and stretch continuously by glyph
- Improved offline artwork caching, 115 integration and desktop menu languages
- Less duplicate grouping and widget artwork processing while listening to audiobooks
- Long notes in lyrics now lift the whole word, and normal word animation is restored
- Interlude cue points take exclusive lyrics focus
- Apple Music tracks can be scraped for artwork and full metadata
- Less blocking when opening lyrics settings for the first time and while scrolling
- CarPlay main-title lyrics line breaks are published promptly
- Better vocal quality during speed-up playback
- Auto refresh is off by default, and library scans write to disk less
- Restored the transparent album case style in Apple TV home scenes
- CarPlay main-title lyrics are published ahead of time, on cue for the next line
- Song comments on the Apple TV Now Playing screen can scroll on a single line
- CD cases in Apple TV home scenes now hold the scene song's artwork
- Podcasts and audiobooks are no longer reported to music scrobbling services
- Improved artist bio fetching and lyrics settings descriptions
- Removed built-in radio search and popular recommendations
- Improved lyrics comments, playback interactions and music metadata
- Duet lyrics no longer get the stronger long-note lift and stretch
- Lyrics scrolling no longer resets when the same lyrics are received again for the same song
- Fewer disk writes during full-library walks of server sources
- Less overhead from repeatedly recalculating Start Listening and recommended albums in large libraries
- The 115 cloud drive connection page now matches the style of other cloud drives
- Go to Album from Now Playing now opens full screen, like Go to Artist
- Artist photos are used only for artists with Apple Music songs and are no longer saved to disk
- Reads ReplayGain values recorded in CUE sheets
- Song comments on the Apple TV Now Playing screen always scroll on a single line
- Tags can be bulk-edited directly from the menu on album and artist pages
- While the library loads, the last albums and artists are shown first, with skeleton placeholders on other pages

### Fixed

- Fixed Baidu cache download and playback stability
- Fixed sudden volume drops during playback; loudness is now analyzed in advance
- Fixed built-in scraping search and resuming batch scraping
- Fixed server source scans getting stuck, and background scan resumption
- Fixed accidental taps on top buttons when swiping down on the lyrics page
- Fixed pinned playlist order reverting after iCloud sync
- Fixed the audio quality badge being wrongly hidden after changing songs
- Fixed the TV top bar background and overflowing playback options
- Fixed system compatibility of listening rankings
- Fixed a stack overflow when opening Settings on Apple TV
- Fixed top menu jitter when returning from Settings search
- Corrected the transcoded audio quality display in full-screen playback
- Fixed lag when rotating the lyrics screen, and Home artwork is now reused in rotation
- Fixed the Download All Artwork and Lyrics entry on Mac
- Fixed the missing orientation toggle button in non-native full-screen effects
- Fixed consecutive song skipping after Navidrome transcoding fails
- Fixed Apple TV playlist pages replaying stale focus requests
- Fixed reading ISO album version tags and external CUE information
- Fixed concurrent access in Apple Music sync and artwork loading
- Fixed the Apple TV back module and updated Home scene cards
- Fixed a crash from a missing dependency in AirPlay external display full-screen effects
- Fixed recognizing and accepting Family Sharing invitations
- Fixed a crash when playing offline music on Apple Watch
- Fixed download progress flashing on the audiobook details page, and the playback speed is now shown in full
- Fixed audiobook cross-device resume staying on an old chapter
- Fixed freezes and crashes caused by Apple Music sync blocking
- Fixed date comparison compatibility on older systems for audiobook progress sync
- Fixed rectangular artwork display and accidental pull-down in the player
- Fixed the progress bar jumping to the start when pulled down
- Fixed lyrics flickering when artwork changes, and accidental taps on hidden lyrics
- Fixed the TV playlist page and Apple Music song lookup blocking the main thread
- Fixed blank space at the bottom after changing the audiobook layout, and returning to the bookshelf not working
- Fixed playback not resuming after a call ends on Bluetooth car systems
- Fixed tapping the artist on an album page opened from Now Playing doing nothing

### Performance

- Lower karaoke separation memory use, and fixed the library launch screen
- Optimized loading, import and playback performance for large libraries
- Improved large-library performance and refined animated artwork and ranking displays
- Missing metadata is now completed manually, with performance improvements
- Optimized ReplayGain analysis and cache performance
- Less jank when scrolling the Mac home screen on macOS 15

---

## [1.12.3] (build 120-124) - 2026-11-04

Adds themed recommendations, Last.fm bios, file renaming, Apple Intelligence and word-by-word lyrics discovery, and improves scanning and resume.

### Added

- **Themed recommendation cards** — Home adds recommendation cards across several themes, with richer recommendation details
- **Last.fm bios** — fetch artist and album bios from Last.fm, with an AI fill-in option if fetching fails
- **File renaming and flat browsing** — rename music files and browse artists and albums in a flat view
- **Locate current song** — jump to the playing song in song lists
- **Search category tabs** — search adds category tabs and a leaner song grouping
- **Custom CarPlay play buttons** — customize CarPlay playback buttons and show audio quality
- **Album page display** — hide per-song artwork on album pages, and show content rating and copyright
- **Vinyl and CD** — the immersive record view can switch between vinyl and CD
- **Lyrics and bar thickness** — adjust lyrics font weight and the thickness of the progress and volume bars
- **AI chapters** — generate editable AI chapters for podcasts and audiobooks
- **New app icon** — one more optional app icon
- **Apple TV** — edit album and artist bios manually, and use the Flowing Colors player background
- **Apple Intelligence** — use Apple Intelligence, and resume AI chapter generation after an interruption
- **Simulated word-by-word lyrics** — an optional simulated word-by-word lyrics display
- **Task status** — task progress appears in the status line at the bottom of the player, and you can drag to reorder it
- **Merge collaboration albums** — merge same-title collaboration albums by shared artist
- **Paged browsing at launch** — browse the library page by page at launch, with larger Navidrome song pages

### Changed

- **Sleep timer** — improved layout and custom actions
- **Favorites order** — sorted by date added, newest first, by default
- **Single-song scraping** — remembers scraped content and lets you choose replacements individually
- **Playlist artwork** — choose playlist artwork separately from the animated background
- **Track numbers and playlist tidying** — improved number display and playlist organizing actions
- **Artist page** — fixed artwork color sampling, with a separate background setting
- **Diagnostic data** — diagnostic data is cleaned up automatically once uploaded or after seven days
- **Apple TV top bar** — smoother page transitions
- **Word-by-word lyrics discovery** — automatically looks for word-synced lyrics during playback and shows task progress
- **Spotlight and Siri** — search short song titles in Spotlight and play them directly, with complete localization of Siri song parameters
- **Apple Music errors** — playback session authentication failures are now reported separately from system player start failures
- **Baidu Netdisk** — less tag backfill overhead, and a corrected retry delay after scraping failures
- **Easter egg icon** — renamed

### Fixed

- **STRM playback** — fixed Subsonic cloud STRM playback skipping songs and multi-hop STRM redirects failing on other sources
- **Resume** — fixed playback not resuming after an interruption or a remote buffering interruption, and Dynamic Island replay issues
- **WebDAV seeking** — fixed playback failing after seeking
- **Apple TV rapid skipping** — fixed playback failing after quickly changing songs
- **Leftover Dynamic Island notice** — fixed a scan-failure notice staying on the Dynamic Island
- **Lyrics** — fixed lyrics blur stopping after changing songs or returning to the app, and cascading lyrics jumping up and back on line changes
- **Listening stats** — audiobooks and podcasts are no longer included
- **Audiobooks** — fixed the See All entry in the listening list
- **Video podcasts** — fixed being unable to switch to video after pausing
- **Artwork and cache** — fixed artwork sharpness and mixed-up caches during scan refreshes
- **Player corners** — fixed the corner transition when pulling down and collapsing
- **Scanning** — fixed scan cancellation, lowered memory use when indexing large libraries, and fixed cloud drive rescans re-reading old song tags
- **Locate** — fixed locating a song in Favorites and playlists jumping to the top
- **Lock Screen artwork** — fixed artwork for local songs not being resent and stale cached images
- **Podcasts** — fixed saving podcasts and starting playback on weak networks, and improved playback service compatibility
- **Home Screen icon** — fixed a misaligned transparent glass outline and icon layering
- **Artist photos** — fixed artist detail photo sharpness, the blurred bottom transition, and rectangular photo fill and background cropping
- **Apple TV top bar** — fixed highlight trails when switching
- **Launch** — fixed Home briefly showing the song list at launch

### Performance

- **Faster scanning** — faster incremental library scans, cloud drive refreshes and remote library scans, fewer repeated artwork reads, scan progress kept after interruptions, and less stutter with large libraries
- **Mac Home** — smoother scrolling, with less artwork cache work while scrolling

---

## [1.12.2] (build 116-119) - 2026-10-29

Updates across builds 116–117: video podcasts, Home layouts, album artwork and disc images, plus improvements to playback and music sources.

### Added

- Watch video podcasts or switch to audio-only playback.
- Choose a new style for the tabs at the top of Home and browse Home sections horizontally.
- Tap an artist's name on an album page to open their details.
- Choose album artwork from images in the album folder. Disc subfolders can use artwork from the parent album folder, and album discs and full-screen vinyl can use the folder's disc image.
- Export lyrics and transcripts as LRC, SRT or plain text, and export AI-separated vocals and instrumentals individually.
- Audiobooks and podcasts can rewind automatically when playback resumes, with a longer rewind after a longer pause.
- Add For You, Start Listening and Recently Played to CarPlay Home.
- Set storage limits for artwork and lyrics, and download all artwork and lyrics at once.
- Group diagnostic reports by category and clear reports and older logs.

### Changed

- Choose artwork sizes separately for each Home section. Start Listening supports one to four columns on iPhone and keeps its tiles in place when playback pauses.
- Use a consistent set of app icon options across iPhone, Mac and Apple TV, with icon switching on Apple TV and a brighter Fresh Note icon.
- Enlarge Apple Watch artwork and keep the volume ring inside the screen.
- Sign in to Last.fm directly on Mac and find scrobbling preferences in Settings. Apple TV also supports Last.fm and ListenBrainz.
- Show the lyrics source above the lyrics, with an option to hide it.
- Keep shared player settings in a Global section. Softer play buttons and clearer glass effects refine audiobook and podcast cards on Home.
- Add light haptic feedback to Play, Pause, Previous and Next. Match the rounded ends of volume and progress bars, and give the bottom row of player buttons more space and larger hit areas.
- Keep the status bar visible when the player is always dark. Contents, show notes and Up Next panels follow the app's appearance setting.
- Give audiobook controls more room in taller layouts and remove the extra label above the chapter name.
- Use a two-column radio player in landscape, with an option for the station artwork to fill its area. Lock the app to portrait or landscape in Settings.
- Keep neighboring tracks from an album together when shuffling.
- Combine the same song from different music sources into one listening-chart entry.
- Like Apple Music tracks opened from search or an album on Apple TV. Search playback on Mac and CarPlay also supports likes and adding tracks to playlists.
- On Apple TV, choose whether to remove tracks deleted from the server immediately, and see why retained tracks remain in the library.
- Explain why the folder view is unavailable while filtering songs or showing downloaded tracks, and offer a direct switch to it.
- Simplify music-source messages and hide status notices for background work that resolves automatically.

### Fixed

- Refresh changed folder artwork on rescan. Wait for newly scanned cloud-drive and NAS tracks to finish reading tags before matching artwork online.
- Stop repeatedly warning about unidentified files after refreshing Baidu Netdisk, and avoid incorrect file-change warnings when writing tags, artwork or lyrics after a rescan.
- Keep the empty part of the volume slider visible and use consistent rounded corners.
- Avoid large black or white areas around the player when rotating the screen.
- Preserve small accent colors on white or pale artwork instead of reducing them to grey.
- Avoid cellular-access prompts when the app is denied network access, while continuing to read local-folder track details.
- Check Spotlight progress against the system index and restore missing entries.
- Keep interrupted Apple Music playback from skipping to the next track.
- Play larger Songloft tracks on Apple TV and load artwork supplied by music-server playlists.
- Keep remote playback from getting stuck when storage is full.
- Prevent Apple TV's iCloud library sync from restoring server-deleted tracks from older device records.

### Performance

- Reduce repeated full-file writes and snapshot uploads for radio lists.
- Avoid rereading the same tracks repeatedly during tag completion, and share a single tag read across tracks in a full-album CUE sheet.
- Reduce stutter from shadows during podcast and audiobook artwork animations.

---

## [1.12.1] (build 109-115) - 2026-10-25

Dynamic lyrics and library backups join improvements to playback, music sources, transcripts and sync.

### Added

- Dynamic Lyrics adds song-specific scenes and camera motion, beat-responsive backgrounds, onset-driven highlighting for line-timed lyrics, and a scrolling vertical layout. Lyrics can also use a cascading spring transition.
- Export and restore ratings, likes and personal playlists. Recover saved marks and playlist tracks after re-adding a source or renaming files.
- Search the full library in Spotlight with artwork. Play a song directly or open an album, artist or playlist; interrupted indexing can resume.
- Redeem promotional AI credit codes. Prompt-based AI playlists and more varied song-radio and similar-track recommendations improve discovery.
- Upload diagnostic reports directly to the developer and receive a report ID for feedback.

### Changed

- iPhone, iPad and Mac gain a simple player preset, larger borderless controls, matching volume/progress styles, and lyric/transcript font selection and import. Apple TV offers fonts installed on the device.
- Choose whether Previous restarts the current track, hide album names below song titles, and customize player controls and backgrounds. Music pitch can shift by up to six semitones in either direction.
- Shuffle can favor familiar or less-played songs and artists. Move tracks to the top of playlists on phone and Mac; rename and sort playlists, with date-added sorting based on when each track joined the playlist.
- Apple TV adds playlist creation and renaming, minimum-star rating playlists, and improvements to search, artwork backgrounds, full-screen exits and playback focus.
- Refine home artwork cards, widget artwork refresh, iPhone Duo layouts and audiobook controls in narrow windows.
- Translate transcripts on demand or as complete sentences, select sentence-wide highlighting, and choose transcription methods from a menu. Improve Japanese lyric recognition and AMLL version matching.

### Fixed

- Improve resuming and seeking audiobooks from cloud drives and NAS, and fix crashes with chunked public HTTP responses.
- Repair GBK/Big5 lyric decoding in tags, custom lyric services and incorrectly decoded server text. Improve Plex artist detection and album grouping for collaborations and featured artists.
- Play Fn Music playlist and favorite tracks that are not yet imported. Improve missing server-playlist entries, cross-device local-track playlist sync, and rate-limit handling for Drime and 123 cloud uploads.
- Correct Play Next, crossfade and mixed Apple Music queue behavior. Show Apple Music artwork in Now Playing and improve catalog-track likes and playlist additions.
- Retain ListenBrainz and Last.fm scrobbles when credentials are rejected, retry after recovery, and improve AI authentication recovery.
- Pause selected automatic requests when offline or when the app is denied network access, reducing repeated system network prompts.

### Performance

- Reuse the player after its first expansion and reduce repeated layout and synchronous checks when opening lyrics or advancing long transcripts.
- Reduce repeated library, playlist and iCloud writes and background refreshes; improve Spotlight indexing recovery and artwork checks.

Upgrading from 1.10.2: library changes reduce memory use with very large libraries. Background processing after updating may temporarily affect responsiveness.

---

## [1.12.0] (build 107) - 2026-10-18

Adds fullscreen motion intensity, transcript generation, romanization and adding to more server playlists.

### Added

- **Motion intensity** — fullscreen effects gain four intensity levels: Subtle, Standard, Strong and Max
- **Glowing progress bar** — the Now Playing progress bar can glow
- **Generate transcripts** — podcast episodes and audiobook chapters without transcripts can get one, using on-device offline recognition or your own Alibaba Cloud Model Studio API key, with progress shown in Now Playing
- **Bilingual and offset transcripts** — fullscreen transcripts can show bilingual or translation only, the whole transcript can be shifted earlier or later to match the audio, and translation size can be set separately
- **Automatic romanization** — lyrics without romanization can get it generated (on device, via smart features, or Google Cloud)
- **Baidu Translate** — lyrics translation can use Baidu Translate with your own key from the Baidu Translate Open Platform
- **Add to server playlists** — playlists on Emby, Jellyfin, Plex, Songloft, Synology Audio Station and Feiniu Music accept songs from "Add to Playlist", and Daolifish playlists now sync
- **Player style preview** — Player Style & Buttons shows a live, true-to-scale preview at the top, with a switcher for music, audiobooks, podcasts and radio
- **Upload diagnostics directly** — diagnostic reports can be uploaded to the developer directly, with no email attachment size limit
- **Classic Now Playing widget** — the square-artwork widget with a gradient background returns and shows the current lyric line
- **Lyrics lines under artwork** — set how many lines and what size lyrics appear under the artwork

### Changed

- **Background caching** — caching a whole source or batch downloads continue after you leave the app and wait for the network to return
- **SMB caching** — caching uses a separate connection so it doesn't interfere with playback, and playback resumes after the device sleeps or the app is suspended
- **Online lyrics** — the most finely timed version is chosen
- **Interlude dots** — the three dots appear only when an interlude starts and bounce twice before singing resumes
- **Fullscreen effect slowdowns explained** — when an effect pauses or drops quality, the reason is shown on screen
- **Apple Music scrobbling and stats** — Apple Music songs are scrobbled to Last.fm and ListenBrainz and count toward listening stats
- **Fill artwork** — podcast and radio players can also fill the artwork, with the bottom edge color extending downward
- **123 Cloud traffic limit** — when the monthly download allowance runs out, Now Playing explains why and skips the source after a 5-second countdown
- **Home editing** — Restore Default Layout also brings back hidden sections, and playlists come before albums and artists in Favorites
- **Dark audiobook player** — buttons and progress bar are dimmed consistently, and the progress bar can follow the player style

### Fixed

- **Apple Music in the queue** — moving from local songs to Apple Music no longer stalls, unplayable songs skip to the next, and Apple Music continues to local songs on the Lock Screen
- **Garbled transcripts** — Ting Reader and Audiobookshelf transcripts no longer appear garbled
- **Widget cropping** — the classic medium widget is no longer cropped

### Performance

- **Scanning and tag reading** — pre-import processing moves to the background, and song lists no longer redraw every few seconds
- **Large playlists** — playlists with tens of thousands of songs open and scroll smoothly, and the first Downloaded status no longer stalls
- **Long transcripts** — transcripts with thousands of lines no longer slow down Now Playing
- **Player animation** — expanding, collapsing and pulling down are smoother, and the Mac main window no longer redraws along with it

---

## [1.11.5] (build 106) - 2026-10-17

Adds the AMLL word-by-word lyrics source, a Sound Pulse background and auto-rotating fullscreen effects.

### Added

- **AMLL TTML DB lyrics source** — community hand-timed word-by-word lyrics, often with translations; on by default and turned on after the update
- **Sound Pulse background** — a new player background that moves with the music over a color taken from the artwork
- **Auto-rotating fullscreen effects** — change effect every song or every 1, 2, 5 or 10 minutes
- **Fill artwork** — set Now Playing artwork to fill, spanning the full width from the top of the screen in portrait on iPhone
- **Always dark player** — Now Playing can stay dark at all times
- **Play alongside other apps** — iPhone and iPad can play at the same time as other apps
- **Large artwork in native fullscreen** — native fullscreen can switch to large artwork
- **Hide built-in translations** — translations included with lyrics can be hidden separately
- **Mark a whole album as audiobook or podcast** — the album's More menu can mark it as audiobook, podcast or music; subfolders of an audiobook folder can be switched back to music individually
- **Actions for Apple Music search results** — Play Next, Add to Queue, favorite and add to playlist for Apple Music songs in search
- **Select all** — Select All and Deselect All appear at the top right when multi-selecting albums, playlists, artists, genres and search results
- **Simple category icons** — library category icons can use a simple style
- **Cover-only audiobook shelf** — a new shelf layout showing covers only
- **Arrange podcast sections** — reorder and hide Podcasts page sections from "…" > Arrange Sections
- **Podcast chapters** — chapters written in MP3 files are read, and Apple TV also shows chapters from the feed
- **Ting Reader intro and outro skipping** — skip settings set for a book in Ting Reader take effect

### Changed

- **Tag sync across devices** — iPhone, iPad and Mac on the same account share tags already read; hand-edited tags, replaced artwork, ratings and reviews sync between devices
- **Rescans keep tags** — rescanning a folder keeps tags already read and only rereads changed files
- **Shared folder protection** — if an SMB or other shared folder scan suddenly misses many songs, they're kept until a full scan confirms
- **Fullscreen word-by-word lyrics** — a wave style where the word being sung lights up, lifts and glows
- **Mashups** — each song plays its full chorus, with fades placed around it
- **Mini player animation** — Now Playing grows out of and shrinks back into the mini player capsule with a springy animation
- **Follow artwork color** — radio, audiobooks and podcasts each follow the artwork of their own most recent item
- **Settings name** — "Immersive Text Motion" is renamed "Lyric Line Transition"
- **Audiobooks** — "Continue Listening"/"Start Listening" buttons become "Continue"/"Start"; Always Keep Offline explains what it's waiting for and keeps downloading during foreground playback
- **Audiobook search** — each matching chapter gets its own row and plays from that chapter
- **Source cache progress** — the Cache progress bar matches actual downloads, and caching can be stopped with a tap
- **Fullscreen transcripts** — appearance can follow the system, and paragraph and sentence highlighting keeps up with narration
- **Mac and Apple TV** — the music note at the top left of the sidebar and top bar becomes the app icon; the Mac queue panel opens at the current song

### Fixed

- **Native fullscreen crash** — tapping the fullscreen button in Now Playing no longer crashes
- **Smart recommendations crash** — fixed a crash when the list disappeared during refresh
- **Favorites arriving first** — favorites and playlists synced from another device light up once the songs are scanned
- **Audiobook state** — speed, archive, favorites and shelf order survive a book's identifier changing after tags are read, and progress on later chapters from other devices is picked up
- **Mac window** — the window no longer stretches off screen when opening Home right after launch
- **Apple TV light lyrics** — no more gray blocks behind sung lyrics

### Performance

- **Smoother during scans and tag reading** — results are written after scrolling stops, and background library work no longer interrupts scrolling
- **Artwork-heavy pages** — off-screen artwork no longer replays placeholder fades

---

## [1.11.4] (build 104) - 2026-10-15

Adds InfiniCLOUD, consistent rate-limit wait notices, and smoother Apple TV and Mac.

### Added

- **InfiniCLOUD music source** — adds InfiniCLOUD as a cloud music source
- **Lyrics translation on Apple TV** — Apple TV lyrics can use smart translation, with a translate button in Now Playing; on Mac, More in Now Playing lets you choose Off, System Translation or Smart Translation
- **Languages not to translate** — choose languages whose lyrics stay in the original
- **Keep a whole book offline** — turn on Always Keep Offline for an entire audiobook from its menu or details page
- **Player background for audiobooks** — turn on "Also for Audiobooks" to use the chosen background on the audiobook player
- **Colors for radio, audiobooks and podcasts** — choose Default, Follow Accent Color and more in Colors & Icons
- **Audiobook and podcast player buttons** — swap buttons by position
- **More in storage management** — lists music source file caches, music video caches and caches from old accounts, each clearable
- **Ting Reader progress sync** — automatic and manual listening progress sync
- **Track numbers on albums** — album details show the track number before each title

### Changed

- **Rate-limit notices** — rate limits consistently show "Too many requests" and how long to wait; cloud drives, NAS, media servers, Plex sign-in, Last.fm, ListenBrainz and playlist import honor server cooldowns with capped retries
- **Resume scans after rate limits** — cloud drive and NAS scans pause at the current folder; tap Continue Scanning to resume
- **Expired session notices** — on Apple TV, an expired cloud drive or NAS session asks you to sign in again, and cloud authorization failures show the provider's reason again
- **Apple Music songs outside your library** — can go to their album, album pages list tracks not in your library, and on Apple TV songs played from search are followed by similar songs
- **Playlist import** — Apple Music and YouTube playlists keep the tracks already read if a later page fails, and explain what happened
- **Home layout** — on iPad, landscape, iPhone Duo and Mac, the first Start Listening card is large; the top artwork carousel also appears in landscape
- **Audiobook player** — the play button and progress bar default to white in dark mode; fullscreen transcripts let you change speed directly, and a side swipe reveals the controls
- **Radio player** — station name and play button sit next to the logo, and bottom buttons are spread evenly
- **Folder artwork** — an image with the same name as the folder is used as its artwork
- **Built-in AI consent** — the content each feature sends is expanded by default
- **Offline translation packs** — the size is confirmed before downloading, and missing packs and progress stay visible on the lyrics page
- **Local AI services** — self-hosted Ollama and similar services on your device or LAN turn off thinking by default and allow longer waits
- **ReplayGain** — ReplayGain in M4A files now applies, including from Subsonic servers
- **Mac sidebar** — keeps only Home, Library, Playlists and Music Sources, switches faster with an entrance animation, and smart recommendations move to a right-side panel
- **NFS music source** — uses an updated NFS component
- **Apple TV scanning** — rescans remove songs deleted from cloud drives

### Fixed

- **Compressor and reverb** — no more clicks when toggling, switching presets or dragging parameters
- **Opening Now Playing** — with blurred artwork, a custom image or Flowing Colors, the player opens with that background immediately
- **Closing Now Playing** — pulling down from lyrics no longer enlarges the artwork at the same time
- **Order of newly scanned songs** — kept after reopening the app
- **Apple TV playback** — rate limits are no longer reported as byte-range errors, Apple Music library songs that fail to start fall back to the catalog version, and pausing no longer freezes
- **Apple Music queues** — queues containing Apple Music songs outside your library are restored after reopening the app
- **Widgets** — tapping outside the play button opens the matching page, and the progress bar and play button follow the artwork color when the accent color does
- **macOS title bar** — fixed the title bar and window buttons flickering when switching pages

### Performance

- **Less stutter** — playlist lists, the Mac sidebar, search results, the duplicates page, disabling or restoring sources and merging listening history no longer freeze
- **Artwork decoding** — Apple TV and Mac Home decode artwork at display size for smoother scrolling
- **Apple TV fullscreen effects** — Sand, Firefly, Stardust, Aurora, Cover Flow, Ring Spectrum, Neural Resonance and others run more smoothly; long Apple Music lists start faster
- **Scanning and prefetch** — rescans reuse unchanged CUE files, and FTP sources read ahead and prefetch the start of the next song

---

## [1.11.3] (build 97) - 2026-10-06

Customizable player buttons, Ting Reader, new fullscreen effects and audiobook improvements.

### Added

- **Customizable player buttons** — rearrange buttons on the music, audiobook and podcast players, with separate layouts for lyrics, fullscreen lyrics, fullscreen effects and radio; unused items in the More menu can be turned off
- **Flowing Colors background** — a new player background turns the artwork's colors into soft glows; you can also adjust background intensity, change the progress bar style and use monochrome controls
- **Lyrics under the title** — Now Playing can show the current and next lyric line below the song title; turn it on in settings
- **New fullscreen effects** — adds Chladni Sand, Firefly Sync, Fruit Fly and Cover Flow; Cover Flow follows the queue and lets you drag or tap to change songs; sand and fireflies react to song sections and beats; choose the frame rate, up to 120 fps on ProMotion iPhones
- **Ting Reader audiobook source** — listening progress syncs both ways, book lists sync as read-only playlists, favorites sync both ways, and chapters can be downloaded for offline use
- **Dislike and play time ranges** — mark songs as disliked, and set a play time range for a song
- **Archive and favorite audiobooks** — archive audiobooks, add them to Favorites and the Home Favorites row, and add a whole book to a playlist; replaying a finished book remembers your position
- **Fullscreen transcript reading** — read audiobook and podcast transcripts fullscreen with adjustable font, size, line spacing and reading theme, plus search and sentence highlighting; while paused, tap a line to play from there
- **Podcast episode favorites and local podcasts** — favorite episodes with the heart; podcasts you downloaded into your library can be marked as podcasts, grouped by show, sorted by date and filtered by unplayed
- **Widgets** — new Cover Play and Listening Station widgets that can show podcasts, radio, music or audiobooks; play, skip and seek directly even when Primuse isn't running
- **System Continue Listening** — albums, playlists and stations you played can appear in the system's Continue Listening suggestions
- **Skip forward and back in Shortcuts** — Shortcuts can skip forward and back
- **Batch-fill bios** — fill in missing bios in bulk from album and artist pages
- **Find in playlist** — search for songs within a playlist
- **Lyrics sources** — the lyrics editor adds Lyrics Source, listing every lyrics file next to the song so you can choose which one to use
- **White accent color** — a new White accent: pure white in dark appearance, near black in light appearance
- **Long-press actions** — long-press a song for its menu; long-press the mini player to favorite, dislike, go to album or artist, or set a sleep timer; hold Previous or Next in Now Playing to rewind or fast-forward
- **Apply album artwork to songs** — when changing album artwork, you can also use it for the album's songs
- **Images in diagnostics** — attach images to diagnostic feedback emails
- **FTP connection modes** — FTP sources can use passive (PASV / EPSV) or active (PORT) data connections
- **Songs deleted on the server** — server sources can remove songs deleted on the server after a second confirmation or immediately

### Changed

- **Portrait Now Playing** — larger artwork that moves up with the title; source, output device and sleep timer are grouped and centered at the bottom; pulling down on lyrics no longer opens fullscreen lyrics
- **Lyrics** — drag to go fullscreen, duets split left and right, jump straight into karaoke, and interlude dots light up with progress; a lyrics file next to the song takes priority, and the most finely timed file is used when there are several
- **Home** — the large covers change on every visit, Shuffle now shuffles the whole library, your last choice of music, radio, audiobooks or podcasts is remembered, the top switcher can be reordered, and layout settings sync via iCloud
- **Minimal mode redesign** — segmented destinations at the top, actions back in page headers, a docked player bar, and Search opens the keyboard immediately
- **Audiobook organization** — editions of the same book in different folders stay separate, chapters follow numbers in their titles, compound numbers stay intact, audiobook covers are square, and Mac can mark songs as audiobooks from the context menu
- **Multiple genres** — all genres in a file are kept, and songs and albums appear under each genre
- **Quality detection** — M4A, WMA, WavPack, CAF and MKA/WebM are classified lossless or lossy by actual codec; server-transcoded playback shows the quality of the stream actually received
- **Built-in AI** — now used only after you agree, and smart feature settings show the remaining built-in AI quota
- **Settings sync** — player appearance settings and favorites order sync via iCloud
- **Wi-Fi transfer** — send several files at once, bypassing the system proxy, with live transfer speed
- **Heart haptics** — favoriting gives a light haptic tap on iPhone
- **Album and playlist headers** — the album page header uses a blurred enlargement of the artwork, and playlist headers become a rotating artwork wall
- **Apple TV** — home scenes become a row of clear CD cases, the remote can reach karaoke controls on the right, and the immersive style picker opens smoothly
- **No downloads for local files** — songs on local sources and external drives no longer offer Download or Always Download
- **Write-back to read-only sources** — after a read-only remote source refuses a write, it isn't retried and manual edits stay in Primuse
- **Rate limits** — lyrics, artwork, scraping, podcast, radio directory, WebDAV and custom AI requests back off consistently when rate limited, and wait times show in days, hours and minutes
- **Apple Music** — songs played from search are followed by similar Apple Music songs, and album pages show the whole album
- **App size** — the iPhone app is about 18 MB smaller

### Fixed

- **Scanning** — fixed empty libraries after scanning Backblaze B2, S3 and Backblaze folders with "+" in their names not scanning, WebDAV and S3 failing under rate limits, and WebDAV recycle-bin copies being added
- **FTPS and FTP** — browsing while playing or long sessions no longer fail with 522 read errors, and canceled reads no longer block later ones
- **Jellyfin** — supports token handling in Jellyfin 12 while staying compatible with 10.6 and earlier
- **Favorites on Apple TV** — fixed favorites being reverted on Jellyfin, Plex and Songloft, and Emby favorites landing under another user
- **Audiobook progress** — fixed starting from an old position when another client had listened further, and audiobook marks reverting to music after syncing
- **Wi-Fi transfer freeze** — fixed freezing at around the fourth received file
- **Equalizer** — keeps working after changing output devices or resuming, lowers overall volume when boosting bands, and no longer clips while switching
- **Crashes** — fixed occasional crashes on file read errors, very long audio files, slow SMB/NFS servers, CarPlay refreshes, switching karaoke lyrics, changing output devices on Mac, and loading Apple Music artwork
- **Word-by-word lyrics** — fixed sung words drifting out of place in some lines
- **Widgets** — fixed progress and paused state being out of sync at cold launch, and widgets showing empty

### Performance

- **Remote track changes** — the next remote song opens early so it starts faster, and remote FLAC resumes directly from the seek position
- **Resampling** — higher-quality resampling when the song and output device sample rates differ
- **Artwork memory** — artwork decodes at screen scale and display size, and off-screen artwork releases memory
- **Cloud drive scanning** — lists up to 4 folders at a time and enters subfolders in their original order
- **Returning to the app** — libraries with many rated songs no longer stall on launch or return

---

## [1.11.2] (build 94-95) - 2026-10-05

Adds offline quality options, per-feature AI models, exclusive output and a yearly music report.

### Added

- **Offline cache quality** — choose the quality for offline caching; lossless songs from cloud drives and other sources can be converted to AAC on device
- **Choose a model per feature** — smart feature settings are split into Features and Services, and each feature can use a specific model from a specific service
- **Exclusive output on Mac** — the Mac app can take exclusive control of an external DAC, with device bit depth following the song
- **Sample rate matching on Apple TV** — Apple TV can request the output sample rate per song; on iPhone, Match Output Sample Rate moves to the audio output settings
- **Quick EQ toggle** — turn the equalizer on or off and switch presets from More in Now Playing and from the Mac menu bar panel; in hi-fi passthrough it explains why and offers a one-tap switch to effects output
- **Lyrics recognition with built-in AI** — songs are converted on device to a small audio file before upload, with no Google key needed; if your plan doesn't include it, the entry is hidden and settings explain why
- **Yearly music report** — listening stats become a single-page yearly music report you can open anytime; the Home listening chart brings back the podium and rankings
- **Home Screen quick actions** — long-press the app icon to resume, shuffle all, shuffle favorites or search
- **New default icon** — the default app icon is now Primuse, with the previous music-note icon kept as an option

### Changed

- **Separate offline downloads** — offline downloads no longer count toward the cache limit, can be viewed and removed one by one in storage management, and a playlist can remove all its downloads at once; when the cache is full, interrupted partial files go first, then the least recently played songs
- **Unlimited favorites** — tap the heart to favorite albums, artists, playlists and folders, with library page buttons consolidated at the top right
- **Home artwork carousel** — the top of Home becomes a looping carousel of large covers (up to 48 per loop); pick one to start shuffling
- **Start Listening cards** — two-tone backgrounds with symbol watermarks, and the first card becomes a full-width card with artwork
- **Continue Listening on Mac** — merged into the main cards with one each for audiobooks, podcasts and radio, hidden when there's nothing to continue
- **Now Playing info** — quality and source become tags below the progress bar (tap for full audio info); the device name shows when using headphones, Bluetooth or casting, and the remaining time shows when a sleep timer is on
- **Expanding bios** — tap More to expand album and artist bios in place and collapse them again
- **Smart scenario picks** — regenerate on the refresh schedule, every 6 hours by default with the built-in AI
- **Built-in AI quota notice** — when this month's usage is used up, it says so and when it resets instead of reporting too many requests
- **Settings explanations** — long explanations move behind a question-mark icon next to the title or toggle
- **Confirmation dialogs** — confirmations pop up from the button or menu that triggered them
- **Karaoke** — with the microphone off, Finish still shows the song's score
- **Listening stats** — compilation credits such as "Various Artists" no longer count as one artist, and recreated music sources are matched back to the original by address, account or songs
- **Apple TV long lists** — radio, genres, podcast episodes and audiobook chapters are paginated; album bios scroll automatically and Now Playing shows animated bars

### Fixed

- **Feiniu Music sync** — fixed playlists and favorites not syncing with newer servers
- **Plex sign-in** — fixed signing in with a Plex account on iPhone redirecting away from the authorization page
- **Playlist sync errors** — a failing song is skipped instead of failing the sync
- **Batch caching** — caching playlists, albums or a multi-selection skips Apple Music songs
- **Lyrics recognition** — requests using your own Google key are no longer rejected because of an attached word list
- **Karaoke vocal separation** — fixed separation always failing because the downloaded model wasn't found
- **Single-file CUE albums** — completing album info and matching lyrics no longer splits them apart
- **Crash at launch** — fixed a possible crash when collecting diagnostics at launch on newer systems

### Performance

- **Gapless across sample rates** — the next song is prepared early and the output sample rate switches in the silence at the end of the previous song
- **Long lists** — playlists or Favorites with thousands of songs no longer freeze on Mac, and thousands of search results or radio import entries no longer stall the interface

---

## [1.11.1] (build 92) - 2026-10-03

Adds podcasts and Audiobookshelf, plus Start Listening, album and artist bios, and more smart recommendations.

### Added

- **Podcasts** — search the Apple Podcasts directory or subscribe by RSS, stream episodes without downloading, and follow along with transcripts when an episode has them; podcasts have their own player with Up Next and previous/next episode across shows. Hidden by default; turn it on in Library and Home settings
- **Audiobookshelf music source** — audiobooks and podcasts are grouped by book on the audiobook shelf, listening progress syncs both ways with the server, and chapters come from the server
- **Start Listening** — start playback from Home by style, decade or current mood, with "For You" intents built from your folders, favorite artists and albums and audio quality preferences; when AI is available it organizes them, and card order adapts to the time of day and your habits
- **Scenario picks and new music beyond your library** — Home recommends whole albums by time of day, weekday, holiday and recent listening; "Recommended for You" uses smart recommendations and can include albums; AI can also suggest songs you don't have yet
- **Album and artist bios** — have AI write a bio and style tags, or write your own; they sync with your library to other devices, can be written back to album.nfo, artist.nfo and Jellyfin, Emby and Plex, and existing ones are read back
- **EQ presets** — save multiple named presets that switch automatically for headphones, Bluetooth or an external DAC
- **Player backgrounds** — choose blurred artwork, the album back cover or your own image, on Apple TV too
- **Keep playing similar songs** — similar songs play automatically when the queue ends
- **Smart tag cleanup** — use the built-in AI to fix garbled or inconsistent titles, artists and albums in bulk
- **Desktop lyrics in the notch on Mac** — desktop lyrics can tuck into the notch at the top of the screen and expand to playback controls on hover; menu bar lyrics can be toggled from the menu bar panel
- **Plex account sign-in** — sign in with a Plex account to pick a server, including servers shared by friends
- **Favorite albums and artists** — favorite albums and artists individually, in sync with server favorites; Navidrome album ratings sync with the server, and Synology Audio Station ratings are read back
- **Per-library types** — media servers and Navidrome let you set each library to Music, Audiobooks or Don't Sync, and cloud drive folders can be marked as audiobooks
- **Restore file tags** — restore albums and songs to the tags in the audio files with one tap (including Apple TV)
- **Rescan a single folder** — rescan individual folders in the library (including Apple TV)
- **Browse by release date** — a new Release Date page browses albums by decade, and the Artists page can list album artists only
- **Album sorting** — sort albums on iPhone and iPad by artist, title, year or recently added; the Apple TV album wall sorts by artist, title or year with an initial-letter index
- **Audio specs** — Now Playing shows quality and format in the source row at the bottom; tap to see the actual output sample rate
- **Lyrics size** — adjust lyrics size in iPhone settings, with four sizes on Apple TV
- **Merge on playlist import** — imported playlists can be merged into an existing playlist with the same name
- **Apple TV Home scenes** — the top shelf can show Recently Played, Radio and Albums; Home adds home scenes (Guests, Relax, Late Night, Focus, Party), with configurable row order and visibility
- **CarPlay Podcasts tab** — a Podcasts tab can be added to CarPlay

### Changed

- **Siri** — ask for a station, song or playlist by name and the best match plays, with same-named items offered under suggestions; Siri can also resume audiobooks, play podcasts and set a sleep timer; Siri access can be allowed in Apple TV settings
- **Always Keep Offline** — keeps already cached songs when turned on; updates after a rescan when the server file changes while keeping the old version playable until the new one downloads; no longer redownloads after you change the WAN address
- **AI lyrics translation** — starts from the line being sung, saves line by line and pre-translates the next song; repeated choruses are translated once with consistent wording; the second half of long lyrics no longer switches to system translation; finished lines are kept if translation fails midway
- **Offline lyrics translation** — adds Chinese, Japanese and Korean offline packs with English as a pivot
- **Song order** — songs in folders and albums default to track order, album sorting follows disc and track numbers, and songs in Home folders can be re-sorted
- **Playlist sync** — playlists from Feiniu Music, Navidrome, Jellyfin, Emby, Plex, Synology Audio Station and Songloft appear one by one as they load, and a malformed entry no longer fails the whole sync
- **Metadata scraping** — only selected fields are written and CUE track info is no longer overwritten; scraped info persists after relaunch; Chinese tags misread as garbled Korean are corrected from the file name; artwork can be embedded in the audio file or saved separately
- **Lyrics encodings** — LRC lyrics in GBK, Big5, Japanese encodings and UTF-16 display correctly
- **Bio layout** — album and artist bios sit at the top of the page and expand to full text; the artist page uses a portrait poster across the upper half
- **Fullscreen effects** — Starry Night and Aurora Curtain merge into "Starry Aurora"; Artwork Shimmer, Mirror Stage and Title Wall are removed, and anyone using them is moved to the closest effect
- **Audiobook player** — whole-book progress becomes a small ring before the chapter position, with ink-black and warm-white layouts for dark and light appearance
- **Karaoke** — AI vocal separation retries once on failure and explains why; the stage footer no longer jumps, and long lyrics fit more neatly
- **CarPlay artwork wall** — covers fill the full width of the car display, and the layout setting is described in columns
- **Google Drive** — the source settings note that the connection method may change in the future; on Apple TV, Google Drive is added by scanning a code and signing in on iPhone or iPad
- **Large libraries to Apple TV** — when the library is too large, only the music sources are sent and Apple TV builds its own library by scanning
- **Mac interface** — the sidebar adds Playlists, playlists and songs reorder by dragging, Home sections can be reordered in settings, rating and two-factor dialogs match other panels, and the Podcasts page is redesigned
- **Apple TV focus and navigation** — focus is more visible, Menu returns to where you entered Now Playing, and the Songs page sorts by title with a letter index
- **Settings name** — "Settings Page" under Appearance is renamed "Colors & Icons"
- **Built-in smart service** — the built-in AI is on by default and suggests switching to your own AI service; new devices allow sending content to the smart service by default
- **Resume source setup** — a half-finished music source setup can be continued after the system closes the app

### Fixed

- **Navidrome scanning** — waits for a server-side scan to finish instead of failing, resumes past stale temporary data, and reads back ratings changed in other clients
- **Media server scanning** — Emby, Jellyfin and Plex scans no longer stop at the server-reported total
- **Streaming** — fixed AAC decoding failing midway, WebDAV servers without range requests failing to play, and OneDrive playback stalling
- **iCloud push** — fixed the Mac not receiving iCloud change notifications
- **Address changes keep data** — changing only a source's address or name no longer empties the folder page or loses ratings and offline cache
- **Audiobook marking** — "Mark as Music" on a single song inside an audiobook folder now takes effect
- **M4A tag writing** — renaming an album no longer drops other tags and fails to save
- **Apple TV** — fixed an occasional crash when skipping past a failed song, and Plex now follows server address changes
- **Artwork and lyrics transition** — artwork scales fully without cropping or ghosting
- **Other** — fixed white-on-white tag and bio editors, button text wrapping on small iPhones, the Mac Home page stuck on loading placeholders, and audiobook stutter every 15 seconds

### Performance

- **Libraries of hundreds of thousands of songs** — shuffle and folder browsing no longer freeze, memory and CPU use are lower, and loading and rechecks are faster
- **Faster track changes** — the next song is prepared early, and WebDAV, Synology, UPnP, media servers and Apple TV prefetch its beginning; local folders switch tracks smoothly after cold launch
- **Scanning and sync** — the library and Home no longer reload repeatedly during scans, iCloud full sync no longer stutters, and Apple TV shows content sooner at launch

---

## [1.10.2] (build 88) - 2026-09-29

Lower memory use for large libraries, plus Apple TV metadata scraping and better lyrics gestures.

### Added

- **Menu bar lyrics on Mac** — the Mac menu bar can show the line being sung; turn it on in Lyrics settings
- **Lyrics scrub line** — press and drag the lyrics to show a guide line and start playback from that line; the guide can be turned on or off in settings (off by default)
- **English–Persian lyrics translation** — translate between English and Persian on device after downloading the offline translation model
- **Metadata scraping on Apple TV** — Apple TV can match track info, complete whole albums, fetch online lyrics automatically, and import custom scraping sources directly
- **Customizable Apple TV top bar** — choose the order and visibility of top bar pages in settings
- **Quick switching on the Apple TV player** — jump straight to the album, artist or genre from Now Playing
- **Add to Subsonic playlists** — playlists on Navidrome and other Subsonic servers can receive songs from "Add to Playlist"
- **Automatic new-song discovery** — server music sources check for updates when you open the app, return to it, or pull to refresh
- **More settings via QR transfer** — sending to Apple TV by QR code can also carry scraping, lyrics API and smart feature settings
- **Lyrics and audio details for imported Apple Music songs** — songs you imported into your Apple Music library show embedded lyrics, and their format, bit rate and sample rate reflect the actual file

### Changed

- **Windowed queue for large libraries** — on iPhone, Mac and Apple TV, Play All loads 1,000 songs at a time and tops up automatically near the end
- **Embedded SYLT lyrics** — synced embedded lyrics now display line by line, bilingual lyrics pair the original with its translation, word-by-word lyrics keep their spaces, and lyrics previously read as one line are re-read after the update
- **Lyrics taps** — tapping empty space in the lyrics returns to the artwork, and dragging the lyrics no longer jumps back to it by accident
- **Traditional/Simplified display** — Traditional Chinese lyrics display in Simplified Chinese in a Simplified interface, and smart recommendation text follows the interface language and script
- **Cloud drive album grouping** — Google Drive, OneDrive and other cloud drives group same-named albums by the folder the songs are in
- **CUE track lyrics** — tracks split from a single-file CUE load their own lyrics files, and editing one track's lyrics no longer affects the others
- **Choosing scan folders** — subfolders of a selected parent show as "Included", and newly added folders can be selected again
- **iPhone Duo layout** — the side column adds the audiobook, listening stats, folder and smart recommendation pages; player buttons avoid the camera when the outer screen is held sideways; fold and unfold transitions are smoother
- **Liquid Glass mini player** — the mini player on iPad and in minimal navigation uses the glass style on iOS 26
- **Mac sidebar order** — library items in the sidebar follow the order and toggles in Appearance settings, and can be reordered by dragging
- **Apple TV browsing** — selecting an album cover expands its track list first, the long-press menu is trimmed to five items, and the Radio page uses the same sizing as Music and Audiobooks
- **Opening Now Playing** — the player slides in already tinted with the artwork color, and the progress time no longer appears early
- **Mashup start** — mashups from Synology and other streaming sources start right at the segment

### Fixed

- **Crashes with very large libraries** — fixed libraries of 200,000+ songs being terminated for exceeding memory while opening, scrolling or playing in the background
- **Songs removed by mistake** — fixed sources with both LAN and WAN addresses removing songs when the server changed during a scan
- **Sign-ins kicking each other out** — fixed Jellyfin and Emby sign-ins invalidating each other across devices and features
- **Playlist sync** — fixed Emby playlist sync timing out and some Feiniu Music playlists going missing
- **Apple TV playback and scanning** — fixed lost or duplicated resume queues, Synology single-file CUE scans failing, shuffle picking songs from folders marked as audiobooks, and CUE lyrics missing after a rescan
- **Duplicates and false changes** — fixed duplicate Feiniu and Synology songs, and Navidrome and other server sources being treated as changed on every launch
- **Mac crashes and layout** — fixed crashes when opening Lyrics settings or using the accessibility "scroll to bottom" action, MV video overflowing the artwork, large playlist numbers wrapping, and sidebar spacing
- **Artwork display** — fixed some web images turning into a solid color when chosen as artist artwork, default artwork and garbled artist names, and artwork flicker at cold launch
- **iCloud sync turned off** — iCloud sync no longer switches itself off after a brief sign-out event
- **Baidu Netdisk write-back** — scraping or editing lyrics on Baidu Netdisk no longer reports a false write-back failure
- **Self-signed NAS** — fixed NAS servers with self-signed certificates not returning audio details and artwork

### Performance

- **Memory use** — the launch cache no longer stores the whole library twice, and recommendations use a compact index
- **Launch** — large libraries get ready faster, and Home, Now Playing and the music source page no longer stutter the first time they open
- **Apple TV scanning** — rescans skip unchanged songs, remote sources scan faster with less heat, and the end of a scan no longer stalls
- **Cache cleanup on refresh** — clearing caches in bulk during a server refresh no longer freezes the interface

---

## [1.10.1] (build 82-85) - 2026-09-26

This release adds karaoke, audiobooks, and music medleys, expands audio/video formats and playlist import, adapts the whole app to iPhone Duo, and improves Home, Apple TV, and playback reliability.

### Added

- **Karaoke mode** — lower the vocals, shift the key, split duet parts, and score and record yourself with the microphone; AI vocal separation downloads its model when you turn it on and removes the original vocals more cleanly; guide vocals step in when you stop singing; practice mode loops single lines and slows down without changing pitch; instrumental versions in your library are found automatically and reuse the original lyrics
- **Karaoke on Apple TV** — sing on the TV with an iPhone scanned in as the microphone for scoring, use AI vocals separated on iPhone, shift the key, and split duet parts
- **Audiobooks** — a bookshelf grouped by work and a dedicated player with chapters, bookmarks, speed, and sleep timer on all three platforms; a scrubber jumps through long chapter lists and books can be reordered by dragging; CarPlay and widgets support audiobooks, with a new Continue Listening widget; Apple TV adds chapter markers and speed control for every format
- **Music medleys** — start one in a single step from the player menu; the next segment is prepared before the transition and unplayable songs are skipped; starting on cellular warns about data use, and the reminder can be re-enabled in Settings
- **Playlist import** — import playlist links from NetEase Cloud Music, QQ Music, Kuwo, Kugou, Migu, Bodian, Soda Music, Apple Music, Spotify, Deezer, bilibili, and YouTube, as well as text lists, CSV, and Apple Music txt/xml, pls, xspf, and wpl files; songs not yet in your library stay greyed out and light up once they arrive
- **More audio and video formats** — MKA, WebM, MP2, Wave64, RF64, RealAudio, and tracker modules such as MOD, XM, IT, and S3M; music videos in MKV, WebM, AVI, FLV, WMV, TS, MPG, and RMVB are converted and cached on first play, with progress and failure reasons
- **Tag suggestions and batch editing** — the tag editor suggests fixes, can check the whole library at once, and can edit several songs together; smart tips appear during playback when relevant
- **AI service presets** — added SenseNova and Agnes AI, including Agnes AI (China)

### Changed

- **Home** — filter Home by Music, Radio, or Spoken Word; Home editing now covers Continue Listening, radio, books in progress, and audiobooks, including which stations and books appear and in what order; the Mac bookshelf can also be shown on Home
- **iPhone Duo** — inner and outer displays, landscape grip, tabletop half-fold, and the system side bar are fully supported: two-column Home and detail pages, a split player, controls and Up Next on the lower half when half-folded, and elements that glide to their new place when folding or rotating
- **Spoken word kept separate** — audiobooks and music no longer bleed into each other, spoken-word chapters found in search play on their own, and listening positions are saved immediately, including when the Mac app quits
- **Mac desktop lyrics** — first opens just above the Dock; with the backing panel hidden, hovering the lyrics still reveals the toolbar
- **Full-screen playback** — stage text fades out in rest mode instead of overlapping the clock and lyrics; lyric translations appear without leaving and re-entering
- **Bilingual lyrics** — lines with only phonetic guides or other languages are still translated, and romaji, pinyin, and romanized Korean are no longer treated as translations
- **Feiniu Music** — lyrics prefer parseable candidates and keep the server's calibrated offset on iPhone, Mac, and Apple TV; tag write-back can rename albums, creates new genres, and uploads artwork; playlist indexes are read in one pass
- **ReplayGain** — volume no longer jumps when combined with crossfade, gapless playback, pause fades, or the equalizer
- **Plain-HTTP radio** — stations on hosts not yet allowed ask whether to trust them, then play right away once allowed
- **Source scanning** — Emby/Jellyfin and other server sources no longer fail when songs are added or removed mid-scan; checked sources use a reachable route when picking folders; the folder picker is redesigned and folders can be tagged as Spoken Word
- **System notifications** — sent only when a task you started finishes while you are outside the app

### Fixed

- **Playback** — fixed a pause before sound when shuffling or playing all, and the Control Center and Lock Screen play button taking about ten seconds to update after pausing
- **Karaoke** — fixed a possible crash when changing songs, crashes when dragging the vocal slider or shifting the key, leftover vocals after seeking, and recordings stopping immediately when started while paused
- **Remote connections** — brief network drops when reaching a NAS from outside no longer interrupt playback or mark the whole source unavailable
- **Tags** — fixed unreadable track and disc numbers in m4a files, write-back overwriting unchanged fields, and a downloader's "(1)" suffix turning song titles into artist names
- **Interface** — fixed Home occasionally stuck on its loading placeholder after a cold launch, Home being widened by the listening chart in narrow iPad layouts, crashes when the system refuses a rotation request, and confirmation dialogs and adjustment panels being cut off on short screens
- **Update check** — new versions are detected again, and a manual check opens the update card directly
- **Apple TV** — fixed Synology verification not persisting, book artwork failing to load, and sluggish focus navigation in large libraries
- **Wording** — the Chinese Back and Next buttons no longer read as Previous and Next Image, and the radio management hints match the actual controls

### Performance

- **Player** — opening and swiping away the player no longer stutters, and the More menu and smart tips no longer expand the whole queue
- **Home and library** — Home scrolls smoothly after a cold launch, and the library loads faster

---

## [1.9.8] (build 78-82) - 2026-09-21

This release redesigns key search and immersive-player interactions, adds spoken-word content and radio management on Apple TV, expands Apple Music, music-source connection, iCloud sync, and startup diagnostics, and fixes Mac full-screen playback, desktop lyrics, and several playback issues.

### Added

- **Editable search results** — reorder or hide song, album, artist, and other result sections; Mac lays sections out side by side, and opening Search focuses the field immediately
- **Apple Music system picker** — add songs through the system picker, open the subscription flow when needed, and rematch tracks automatically after a storefront change
- **Apple Music quality details** — show actual Lossless, Hi-Res Lossless, and Dolby Atmos availability instead of labeling every track AAC
- **Startup recovery and diagnostics** — report the stage where startup stopped and enter safe mode after repeated failures; diagnostic reports now include system-exit reasons and connection candidates
- **Dynamic detail backgrounds** — album, artist, and genre detail screens use a full-page tint derived from their artwork
- **Spoken word** — audiobooks, crosstalk, and other spoken-word content are supported, and m4b audiobook files play directly
- **Radio management on Apple TV** — add, delete, reorder, and rename stations and browse the library on the TV; stations appear on the Top Shelf, and logos support SVG and music-source stations
- **Custom lyrics servers** — scraping can use a lyrics API server you provide and fetch lyrics online automatically when none are found
- **Keep screen on** — the player can keep the display awake, with the switch in Player settings
- **Source health check** — shows progress item by item and checks every connection route
- **NonoEnd icon** — a new bass-clef alternate icon; the default icon is now Soft Note

### Changed

- **Music source addresses** — enter a Synology QuickConnect ID or Feiniu FN ID directly; Primuse resolves the port, TLS mode, and usable path, and an editable public source can be saved whenever its fallback address works
- **Server playlist sync** — newly created server playlists sync automatically without waiting for a manual scan
- **Tag reading schedule** — new tracks receive tags before full-library rechecks, WebDAV and NAS reads are faster, and desktop platforms use the fastest level supported by the device
- **Immersive effect drawer** — tap outside the drawer to close it on iPhone; Mac now uses a right-side preview drawer with more reliable full-screen transitions and window restoration
- **Desktop lyric interaction** — when the backing panel is hidden or locked, areas outside the lyrics pass clicks to the window behind, and the panel adapts to the display size
- **Remote routing** — stalled or failed LAN handshakes fall back to the public address instead of waiting out the full timeout; server sources re-confirm their route after a network change, and the health check no longer counts a proxy handshake as reachable
- **iCloud sync** — three-way playlist merging, deleted stations no longer come back, and very large playlists sync; turning on settings sync no longer overwrites other devices, device-specific hardware and storage options stay local, and device-only credentials are no longer migrated to iCloud Keychain
- **Apple TV library snapshots** — recorded per uploading device and merged by song; libraries sent over the local network are not overwritten by older cloud copies, and station edits made on the TV are preserved
- **Full-screen effects** — removed Light Rhythm and Live Waveform; the radial spectrum is centred on landscape and wide canvases
- **CarPlay Up Next** — shows artwork and follows the actual playback order
- **Siri song requests** — song titles are recognised more reliably, and Siri explains why when nothing is found
- **Feedback entries** — About now offers separate "Report a Problem" and "Feature Request" links that open a form with the version, device model, and OS already filled in and editable; only the description is required

### Fixed

- **Apple Music system state** — fixed Lock Screen and CarPlay retaining the previous track after an automatic change, along with recovery, retry, and storefront-change issues
- **Mac full-screen playback** — fixed a disabled effect panel, top controls moving out of bounds or shaking, windows returning off-screen, and the player not tracking its container size
- **Mac search and app icons** — fixed stale counts after clearing search, the old Dock icon flashing at launch, and the default icon not being restored
- **Album grouping** — tracks from one album are no longer split by track artist, and multi-disc albums keep disc and track order
- **Connection and startup feedback** — connections no longer spin forever on failure, startup and source setup report actionable causes, and server addresses and paths are redacted from logs
- **Lyric editing** — write-permission checks no longer stall, and editing an M4A with grouping metadata preserves its embedded lyrics
- **Memory pressure** — artwork caches are released first when memory is tight, reducing the chance of system termination
- **Safe mode false alarms** — launches the system starts in the background (scan resume, silent push) are no longer counted as aborted launches and can no longer lock the app into safe mode; a wrongly latched safe mode is cleared after updating
- **Feiniu playlist and favorite sync** — empty server lists no longer fail with “not valid Feiniu Music JSON”, and unpaged playlist indexes are read correctly
- **Playback** — fixed radio not playing on Apple TV, playback stopping after one song with crossfade on, and a few songs without a readable duration being re-read endlessly and slowing the interface
- **Lyric highlighting** — fixed the original line not highlighting in mixed-language lyrics such as Korean with English
- **Music sources** — fixed connection failures from a protocol option out of sync with the address, Synology password editing and re-authentication, songs remaining after a folder is unchecked, and 123 Cloud tag write-back reporting failure while the server is still merging
- **Interface** — fixed a crash from Home folders "See All", the old two-column player in landscape on Plus and Pro Max models, and stutter while scanning or editing a music source

### Performance

- **Sources and Home** — faster WebDAV/NAS tag reading, smoother large radio libraries, and more responsive switching between Music and Radio on the Home screen
- **Diagnostic privacy** — connection candidates and failure stages remain useful for troubleshooting while server addresses, paths, and other sensitive values are replaced by stable markers

---

## [1.9.7] (build 73-77) - 2026-09-19

This release adds Guangya Cloud, Synology Audio Station, full radio organization, and more lyric formats, brings Apple Music into the unified music source list, and overhauls landscape layouts, Apple TV decoding, server synchronization, and cross-device transfer.

### Added

- **Guangya Cloud music source** — add Guangya Cloud as a music source, with scanning and playback working like any other source
- **Lyric poster sharing** — turn selected lyrics into a shareable poster image, with adjustable layout and colors
- **Cloud drive folder browsing** — the cloud drive folder hierarchy is rebuilt and music sources gained a folder entry, so you can browse by the original directory structure
- **Manual playlist ordering** — press and hold a track in a playlist to drag it into a new position
- **Shuffle shortcut** — a shuffle button is now available at the top of the song list and the playback queue
- **Radio folders, tags, and subscriptions** — organize stations with folders and tags, import grouped playlists, subscribe to playlist URLs, provide image URLs, and display SVG logos
- **Synology Audio Station** — add Synology Audio Station on iPhone, iPad, Mac, and Apple TV, with songs, playlists, favorites, and SHOUTcast stations synchronized
- **More synchronized lyric formats** — ID3 SYLT, `.elrc`, `.lys`, `.yrc`, `.qrc`, `.vtt`, and `.srt`, preserving `offset`, duet, harmony, translation, and romanization data
- **Embed lyrics in audio** — save edited synchronized lyrics only inside the audio file or alongside a sidecar, with a file-write warning before enabling it
- **Network-adaptive quality** — Subsonic, Emby, and Jellyfin can use transcoded quality on mobile networks and support reverse-proxy path prefixes
- **New icons and interface motion** — added adaptive icon themes and a consistent motion system across navigation, cards, lists, artwork, and playback controls

### Changed

- **Apple Music in the music source list** — authorization, library sync, and removal all happen in the music source list, so Apple Music can be added and removed like any other source; once removed, its content no longer appears in search
- **Scanning continues after leaving the app** — a scan keeps running after you leave the app and resumes where it left off when you return
- **Server-side deletion sync** — tracks deleted on the server are removed locally, and sources that do not support deletion now only drop the local record
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

- **Embedded artwork** — fixed embedded artwork that could not be read for some tracks after a bulk import and could never be recovered afterwards
- **External and remote connections** — fixed external music source connections failing and crashing the app, along with fnOS remote connections and their error handling
- **IPv6 addresses** — fixed IPv6 music source addresses failing to connect and directories failing to load
- **Playback queue reordering** — fixed a crash while dragging to reorder; with shuffle on, automatic track changes now match Play Next after reordering
- **Lyric poster layout** — fixed blank poster previews and clipped layouts
- **Quick favorites editing** — fixed slow opening and laggy input when editing quick favorites
- **Playback speed** — fixed the playback speed control failing to open
- **macOS window buttons** — fixed the window buttons in the top-left flickering while scrolling
- **Playback stability** — fixed occasional crashes when starting playback, stale audio after resume or track changes, replaying a remote track waiting for a full download, and manual skips missing the configured fade
- **Music source recovery** — fixed public sources being marked offline, reverse-proxied WebDAV folders failing to load, SMB timeouts crashing, and deleted then reimported local or remote tracks being unable to return
- **Artwork and posters** — artwork can be rebuilt after clearing its cache; lyric posters save to Photos again, with motion effects available in every poster style
- **Apple TV and iCloud** — fixed overlapping intelligent-settings screens, iCloud failing to refresh more than once or still exchanging data after being disabled, and missing sync failure details

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

- **Wireless output** — fixed silence and noise after the wireless output configuration changes, and corrected audio focus when AirPlay returns to the device
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
- **Delete from the playback queue** — remove tracks directly in the queue, with stronger drag feedback
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
- Unified the macOS app name to prevent duplicate icons after installation

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
