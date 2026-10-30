import XCTest

@MainActor
final class SearchExperienceUITests: XCTestCase {
    func testCategoryTabsFilterResultsAndKeepSavedOrder() {
        continueAfterFailure = false
        let app = searchApp(navigationMode: "standard")
        app.launchArguments += [
            "-primuse.search.displayMode.v1", "tabs",
            "-primuse.search.sectionOrder.v1", #""[\"metadata\",\"albums\",\"artists\"]""#,
            "-primuse.search.hiddenSections.v1", #""[]""#
        ]
        app.launch()
        defer { app.terminate() }
        submitSearch(in: app)
        let songs = app.buttons["search.tab.metadata"]
        let albums = app.buttons["search.tab.albums"]
        XCTAssertTrue(songs.waitForExistence(timeout: 15))
        XCTAssertTrue(albums.exists)
        XCTAssertEqual(songs.label, "歌曲")
        XCTAssertLessThan(songs.frame.minX, albums.frame.minX)
        songs.tap()
        XCTAssertTrue(songs.isSelected)
        let songMenu = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'song.actions.' AND label == '更多操作'")).firstMatch
        XCTAssertTrue(songMenu.waitForExistence(timeout: 5))
        let albumMenu = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'search.album.more.'")).firstMatch
        XCTAssertFalse(albumMenu.exists)
        XCTAssertFalse(app.staticTexts["标题 / 艺术家 / 专辑"].exists)
        attach(app, "search-tabs-songs")
        albums.tap()
        XCTAssertTrue(albums.isSelected)
        XCTAssertTrue(albumMenu.waitForExistence(timeout: 5))
        XCTAssertFalse(songMenu.exists)
        attach(app, "search-tabs-albums")
        app.buttons["search.tab.all"].tap()
        XCTAssertTrue(albumMenu.waitForExistence(timeout: 5))
        XCTAssertTrue(songMenu.waitForExistence(timeout: 5))
        attach(app, "search-tabs-all")
    }

    func testDisplayModeSwitchPersistsAcrossLaunches() {
        continueAfterFailure = false
        let app = searchApp(navigationMode: "standard")
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["search.layout.button"].waitForExistence(timeout: 25))
        app.buttons["search.layout.button"].tap()
        let continuous = app.buttons["连续滚动"]
        let tabs = app.buttons["分类标签"]
        XCTAssertTrue(continuous.waitForExistence(timeout: 5))
        let originallyTabbed = tabs.isSelected
        continuous.tap()
        app.buttons["完成"].tap()
        submitSearch(in: app)
        XCTAssertFalse(app.buttons["search.tab.all"].exists)
        app.buttons["search.layout.button"].tap()
        tabs.tap()
        attach(app, "search-display-mode-settings")
        app.buttons["完成"].tap()
        XCTAssertTrue(app.buttons["search.tab.all"].waitForExistence(timeout: 10))
        app.terminate()
        app.launch()
        submitSearch(in: app)
        XCTAssertTrue(app.buttons["search.tab.all"].waitForExistence(timeout: 15))
        app.buttons["search.layout.button"].tap()
        XCTAssertTrue(tabs.waitForExistence(timeout: 5))
        XCTAssertTrue(tabs.isSelected)
        if !originallyTabbed { continuous.tap() }
        app.buttons["完成"].tap()
    }

    private func submitSearch(in app: XCUIApplication) {
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 25))
        field.tap()
        let query = ProcessInfo.processInfo.environment["PRIMUSE_SEARCH_TEST_QUERY"] ?? "大鱼"
        field.typeText(query + "\n")
        XCTAssertTrue(app.buttons["search.reopen"].waitForExistence(timeout: 10))
    }

    func testAlbumMoreIncludesPlayAllAndSongMoreKeepsFullMenu() throws {
        continueAfterFailure = false
        let app = searchApp(navigationMode: "standard")
        app.launch()
        defer { app.terminate() }
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 25))
        field.tap()
        let query = ProcessInfo.processInfo.environment["PRIMUSE_SEARCH_TEST_QUERY"] ?? "大鱼"
        field.typeText(query + "\n")
        let albumMenu = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'search.album.more.'")).firstMatch
        guard albumMenu.waitForExistence(timeout: 10) else {
            throw XCTSkip("Import an album and song matching PRIMUSE_SEARCH_TEST_QUERY to run the menu regression")
        }
        albumMenu.tap()
        XCTAssertTrue(app.buttons["全部播放"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["编辑"].exists)
        attach(app, "search-album-full-actions")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.15)).tap()

        let songMenu = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'song.actions.' AND label == '更多操作'")).firstMatch
        for _ in 0..<5 where !songMenu.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(songMenu.isHittable)
        songMenu.tap()
        attach(app, "search-song-original-actions")
        XCTAssertTrue(app.buttons["编辑"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["分享"].exists)
        XCTAssertTrue(app.buttons["歌曲信息"].exists)
        app.buttons["编辑"].tap()
        attach(app, "search-song-original-edit-actions")
        XCTAssertTrue(app.buttons["编辑标签"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["编辑歌词"].exists)
    }

    func testSettingsSearchIsVisibleAboveListAndFindsSettings() {
        continueAfterFailure = false
        let app = searchApp(navigationMode: "standard")
        app.launchEnvironment["PRIMUSE_OPEN_PAGE"] = "settings"
        app.launch()
        defer { app.terminate() }
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 25))
        XCTAssertGreaterThan(field.frame.width, app.frame.width * 0.7)
        attach(app, "settings-search-above-list")
        field.tap()
        field.typeText("锁屏没歌词")
        let result = app.buttons["settings.result.lyrics.lockScreen"]
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        attach(app, "settings-search-results")
    }

    func testStandardSearchSubmissionKeepsQueryAndCanResumeEditing() {
        continueAfterFailure = false
        let app = searchApp(navigationMode: "standard")
        app.launch()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 25))
        field.tap()
        field.typeText("夜曲\n")
        let collapsed = app.buttons["search.reopen"]
        XCTAssertTrue(collapsed.waitForExistence(timeout: 5))
        XCTAssertTrue(collapsed.label.contains("夜曲"))
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertFalse(field.exists)
        attach(app, "search-standard-submitted")
        collapsed.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "夜曲")
        attach(app, "search-standard-reopened")
    }

    func testMinimalSearchSubmissionKeepsQueryAndCanResumeEditing() {
        continueAfterFailure = false
        let app = searchApp(navigationMode: "minimal")
        app.launch()
        // 极简顶栏点搜索后换成输入框；提交只收起键盘，输入框和查询都留在顶栏上。
        let field = app.textFields["minimal.search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 25))
        field.tap()
        field.typeText("夜曲\n")
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "夜曲")
        attach(app, "search-minimal-submitted")
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "夜曲")
        attach(app, "search-minimal-reopened")
        app.buttons["minimal.search.cancel"].tap()
        XCTAssertTrue(app.buttons["minimal.search"].waitForExistence(timeout: 5))
    }

    private func searchApp(navigationMode: String) -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.welape.yuanyin")
        app.launchEnvironment["PRIMUSE_OPEN_PAGE"] = "search"
        app.launchEnvironment["PRIMUSE_DIAGNOSTIC_LOGGING"] = "off"
        app.launchArguments = [
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
            "-primuse.navigation.mode.v1", navigationMode,
            "-primuse.hasSeenOnboarding", "YES",
            "-primuse.launch.consecutiveAborts", "0",
            "-primuse.launch.safeModeLatched", "NO"
        ]
        return app
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

@MainActor
final class SongLocationUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testLargeSongListLocatesPausedSongAndRepeatsAfterScrollingAway() {
        let app = launch("songs")
        defer { app.terminate() }
        locateAndVerify(app)
        app.scrollViews.firstMatch.swipeDown(velocity: .fast)
        app.scrollViews.firstMatch.swipeDown(velocity: .fast)
        locateAndVerify(app)
        attach(app, "song-location-large-library")
    }

    func testPlaylistFilterRequiresConfirmationAndPreservesItOnCancel() {
        let app = launch("playlist")
        defer { app.terminate() }
        let find = app.buttons["playlistDetail.find"]
        XCTAssertTrue(find.waitForExistence(timeout: 30))
        find.tap()
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("Track 0001\n")
        let locate = app.buttons["songList.locateCurrent"]
        locate.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        app.alerts.buttons["取消"].tap()
        XCTAssertEqual(field.value as? String, "Track 0001")
        locate.tap()
        app.alerts.buttons["清除筛选并定位"].tap()
        XCTAssertTrue(targetRow(app).waitForExistence(timeout: 12))
        assertTargetVisible(app)
        XCTAssertFalse(field.exists)
        attach(app, "song-location-playlist-filter-cleared")
    }

    func testAlbumLocatesDistantTrack() {
        let app = launch("album")
        defer { app.terminate() }
        locateAndVerify(app)
        attach(app, "song-location-album")
    }

    func testSmartPlaylistLocatesDistantTrack() {
        let app = launch("smart")
        defer { app.terminate() }
        locateAndVerify(app)
        attach(app, "song-location-smart-playlist")
    }

    func testArtistLocatesSongOutsidePopularPreview() {
        let app = launch("artist")
        defer { app.terminate() }
        locateAndVerify(app)
        attach(app, "song-location-artist-all-songs")
    }

    func testMiniPlayerMenuRevealsSongInLibrary() {
        let app = launch("playlist")
        defer { app.terminate() }
        let mini = app.buttons.matching(identifier: "locationFixture.miniPlayer")
            .matching(NSPredicate(format: "label BEGINSWITH %@", "正在播放:")).firstMatch
        XCTAssertTrue(mini.waitForExistence(timeout: 30))
        mini.press(forDuration: 1)
        let reveal = app.buttons["在资料库中显示"]
        XCTAssertTrue(reveal.waitForExistence(timeout: 5))
        reveal.tap()
        XCTAssertTrue(targetRow(app).waitForExistence(timeout: 12))
        assertTargetVisible(app)
        attach(app, "song-location-mini-player-menu")
    }

    func testFullPlayerMenuRevealsSongInLibrary() {
        let app = launch("playlist")
        defer { app.terminate() }
        let mini = app.buttons.matching(identifier: "locationFixture.miniPlayer")
            .matching(NSPredicate(format: "label BEGINSWITH %@", "正在播放:")).firstMatch
        XCTAssertTrue(mini.waitForExistence(timeout: 30))
        mini.tap()
        let more = app.buttons["nowPlaying.more"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        more.tap()
        let reveal = app.buttons["在资料库中显示"]
        XCTAssertTrue(reveal.waitForExistence(timeout: 5))
        reveal.tap()
        XCTAssertTrue(targetRow(app).waitForExistence(timeout: 12))
        assertTargetVisible(app)
        attach(app, "song-location-full-player-menu")
    }

    private func launch(_ page: String) -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.welape.yuanyin")
        app.launchEnvironment["PRIMUSE_VISUAL_EVIDENCE"] = "songLocation"
        app.launchEnvironment["PRIMUSE_LOCATION_PAGE"] = page
        app.launchEnvironment["PRIMUSE_DIAGNOSTIC_LOGGING"] = "off"
        app.launchArguments = [
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
            "-library.songBrowseMode", "flat",
            "-library.songFilter.v1", "all",
            "-primuse.navigation.mode.v1", "standard",
            "-primuse.hasSeenOnboarding", "YES",
            "-primuse.launch.consecutiveAborts", "0",
            "-primuse.launch.safeModeLatched", "NO"
        ]
        app.launch()
        return app
    }

    private func targetRow(_ app: XCUIApplication) -> XCUIElement {
        app.scrollViews.staticTexts["Track 3990"].firstMatch
    }

    private func locateAndVerify(_ app: XCUIApplication) {
        let locate = app.buttons["songList.locateCurrent"].firstMatch
        XCTAssertTrue(locate.waitForExistence(timeout: 30))
        locate.tap()
        XCTAssertTrue(targetRow(app).waitForExistence(timeout: 15))
        assertTargetVisible(app)
    }

    private func assertTargetVisible(_ app: XCUIApplication) {
        let target = targetRow(app)
        let visibleExpectation = expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: target)
        wait(for: [visibleExpectation], timeout: 15)
        let labels = app.scrollViews.staticTexts.matching(identifier: "Track 3990")
        let visible = labels.allElementsBoundByIndex.contains { label in
            label.isHittable && label.frame.midY > app.frame.minY + 100
                && label.frame.midY < app.frame.maxY - 130
        }
        XCTAssertTrue(visible, "The playing track must be visible in the song list, above the mini player")
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
