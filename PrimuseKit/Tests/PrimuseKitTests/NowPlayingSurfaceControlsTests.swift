import Foundation
import Testing
@testable import PrimuseKit

@Suite struct NowPlayingLyricsPageControlsTests {
    typealias Controls = NowPlayingLyricsPageControls

    @Test func defaultFollowsCoverAndKeepsKaraokeAndCollapse() {
        #expect(Controls.decode("") == .default)
        #expect(Controls.decode("garbage") == .default)
        #expect(Controls.default.encoded() == "")
        #expect(!Controls.default.usesOwnButtons)
        #expect(Controls.default.headerExtra == .karaoke)
        #expect(Controls.default.collapsesControlsOnScroll)
        let cover = NowPlayingControlLayout.default.placing(.sleepTimer, in: .barLeading)
        #expect(Controls.default.resolvedLayout(cover: cover) == cover)
    }

    @Test func turningOnOwnButtonsStartsFromTheCoverButtons() {
        let cover = NowPlayingControlLayout.default
            .placing(.sleepTimer, in: .barLeading)
            .settingStatusItem(.source, visible: false)
        let controls = Controls.default.settingUsesOwnButtons(true, cover: cover)
        #expect(controls.usesOwnButtons)
        #expect(controls.ownButtons.actions == cover.actions)
        let changed = controls.placingOwnButton(.dislike, in: .header)
        let resolved = changed.resolvedLayout(cover: cover)
        #expect(resolved.action(in: .header) == .dislike)
        #expect(resolved.action(in: .barLeading) == .sleepTimer)
        // 状态行与「更多」的开关仍跟封面那份。
        #expect(!resolved.showsStatusItem(.source))
        #expect(Controls.decode(changed.encoded()) == changed)
    }

    @Test func turningOwnButtonsOffAndOnAgainKeepsWhatWasArranged() {
        let cover = NowPlayingControlLayout.default
        let arranged = Controls.default
            .settingUsesOwnButtons(true, cover: cover)
            .placingOwnButton(.equalizer, in: .barTrailing)
        let off = arranged.settingUsesOwnButtons(false, cover: cover)
        #expect(off.resolvedLayout(cover: cover) == cover)
        let backOn = off.settingUsesOwnButtons(true, cover: cover.placing(.share, in: .barLeading))
        #expect(backOn.ownButtons.action(in: .barTrailing) == .equalizer)
        #expect(backOn.ownButtons.action(in: .barLeading) == .lyrics)
    }

    @Test func headerExtraCanBeEmptiedChangedOrRestored() {
        let empty = Controls.default.settingHeaderExtra(nil)
        #expect(empty.headerExtra == nil)
        #expect(!empty.isDefault)
        #expect(Controls.decode(empty.encoded()).headerExtra == nil)
        let like = empty.settingHeaderExtra(.like)
        #expect(like.headerExtra == .like)
        #expect(like.settingHeaderExtra(.karaoke).isDefault)
        #expect(Controls.default.settingHeaderExtra(.airPlay) == .default)
        #expect(Controls.default.settingHeaderExtra(.lyrics) == .default)
    }

    @Test func collapseCanBeTurnedOff() {
        let off = Controls.default.settingCollapsesControlsOnScroll(false)
        #expect(!off.collapsesControlsOnScroll)
        #expect(Controls.decode(off.encoded()) == off)
        #expect(off.settingCollapsesControlsOnScroll(true).encoded() == "")
    }

    @Test func lyricsSurfaceCountsTheHeaderExtraAsOnThePage() {
        let layout = NowPlayingControlLayout.default.placing(nil, in: .header)
        #expect(layout.menuFallback(on: .portrait).contains(.like))
        #expect(!layout.menuFallback(on: .portraitLyrics(headerExtra: .like)).contains(.like))
        #expect(layout.menuSuppressed(on: .portraitLyrics(headerExtra: .karaoke)).contains(.karaoke))
        #expect(!layout.menuSuppressed(on: .portraitLyrics(headerExtra: nil)).contains(.karaoke))
    }
}

@Suite struct NowPlayingImmersiveLyricsControlsTests {
    typealias Controls = NowPlayingImmersiveLyricsControls

    @Test func defaultTopSlotFollowsTheHeader() {
        #expect(Controls.decode("") == .default)
        #expect(Controls.default.encoded() == "")
        #expect(Controls.default.choice(in: .topPrimary) == .followHeader)
        #expect(Controls.default.choice(in: .topSecondary) == .empty)
        #expect(Controls.default.actions(header: .like) == [.topPrimary: .like])
        // 和原来一样:歌名旁放的是歌词、全屏或隔空播放时,全屏歌词上那一格空着。
        #expect(Controls.default.actions(header: .airPlay).isEmpty)
        #expect(Controls.default.actions(header: .lyrics).isEmpty)
        #expect(Controls.default.actions(header: nil).isEmpty)
    }

    @Test func dockEdgesTakeTogglesAndRoundTrip() {
        let controls = Controls.default
            .placing(.action(.shuffle), in: .dockLeading)
            .placing(.action(.repeatMode), in: .dockTrailing)
        #expect(controls.actions(header: .like) == [
            .topPrimary: .like, .dockLeading: .shuffle, .dockTrailing: .repeatMode,
        ])
        #expect(Controls.decode(controls.encoded()) == controls)
    }

    @Test func placingAPlacedActionSwapsAndFollowingStaysOnTop() {
        let controls = Controls.default.placing(.action(.queue), in: .dockLeading)
        let swapped = controls.placing(.action(.queue), in: .topPrimary)
        #expect(swapped.choice(in: .topPrimary) == .action(.queue))
        // 「跟歌名旁」挪不到底部,那一格空出来。
        #expect(swapped.choice(in: .dockLeading) == .empty)
        #expect(!Controls.default.canPlace(.followHeader, in: .dockTrailing))
        #expect(Controls.default.placing(.followHeader, in: .dockTrailing) == .default)
        #expect(!Controls.default.canPlace(.action(.lyrics), in: .topSecondary))
        #expect(!Controls.default.canPlace(.action(.fullScreen), in: .dockLeading))
    }

    @Test func theSameButtonShowsOnlyOnce() {
        let controls = Controls.default.placing(.action(.like), in: .topSecondary)
        #expect(controls.actions(header: .like) == [.topPrimary: .like])
        #expect(controls.actions(header: .dislike) == [.topPrimary: .dislike, .topSecondary: .like])
    }

    @Test func unknownNamesSurviveEditsElsewhere() {
        let raw = #"{"slots":{"topSecondary":"futureButton"}}"#
        let controls = Controls.decode(raw).placing(.action(.shuffle), in: .dockLeading)
        #expect(controls.encoded().contains("futureButton"))
        #expect(controls.choice(in: .topSecondary) == .empty)
    }

    @Test func configuredSurfaceDrivesTheMenu() {
        let layout = NowPlayingControlLayout.default
        #expect(layout.menuFallback(on: .configuredImmersiveLyrics(visible: [])) == [.like])
        #expect(layout.menuFallback(on: .configuredImmersiveLyrics(visible: [.like])).isEmpty)
        #expect(layout.menuSuppressed(on: .configuredImmersiveLyrics(visible: [.sleepTimer])) == [.sleepTimer])
    }
}

@Suite struct NowPlayingEffectPlayerControlsTests {
    typealias Controls = NowPlayingEffectPlayerControls

    @Test func defaultKeepsTheQueueButton() {
        #expect(Controls.decode("") == .default)
        #expect(Controls.default.encoded() == "")
        #expect(Controls.default.actions == [.topTrailing: .queue])
    }

    @Test func pillEdgesAndSwapping() {
        let controls = Controls.default
            .placing(.like, in: .pillLeading)
            .placing(.queue, in: .pillTrailing)
        #expect(controls.action(in: .pillLeading) == .like)
        #expect(controls.action(in: .pillTrailing) == .queue)
        #expect(controls.action(in: .topTrailing) == nil)
        #expect(Controls.decode(controls.encoded()) == controls)
        #expect(controls.placing(.queue, in: .topTrailing).placing(nil, in: .pillLeading).isDefault)
    }

    @Test func pageChangingActionsAreRejected() {
        for action in [NowPlayingControlAction.lyrics, .fullScreen, .karaoke, .cast] {
            #expect(!Controls.allows(action))
            #expect(Controls.default.placing(action, in: .pillLeading) == .default)
        }
    }
}

@Suite struct NowPlayingRadioControlLayoutTests {
    typealias Layout = NowPlayingRadioControlLayout

    @Test func defaultShowsEverythingInTheOriginalOrder() {
        #expect(Layout.decode("") == .default)
        #expect(Layout.default.encoded() == "")
        #expect(Layout.default.visibleItems == [.airPlay, .info, .share, .history, .sleepTimer])
        #expect(Layout.default.showsVolumeBar)
    }

    @Test func itemsCanBeHiddenAndMovedButAirPlayStays() {
        let layout = Layout.default
            .settingItem(.info, shown: false)
            .settingItem(.airPlay, shown: false)
            .movingItems(fromOffsets: IndexSet(integer: 4), toOffset: 0)
        #expect(layout.visibleItems == [.sleepTimer, .airPlay, .share, .history])
        #expect(Layout.decode(layout.encoded()) == layout)
    }

    @Test func volumeBarAndMissingItems() {
        let layout = Layout.default.settingShowsVolumeBar(false)
        #expect(!Layout.decode(layout.encoded()).showsVolumeBar)
        let partial = Layout.decode(#"{"order":["history","airPlay","nope"]}"#)
        #expect(partial.order == [.history, .sleepTimer, .airPlay, .info, .share])
    }
}
