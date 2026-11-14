import XCTest

@MainActor
private func dismissStoredSourceAuthenticationAlerts(in app: XCUIApplication) {
    let alert = app.alerts["音乐源登录失败"]
    guard alert.waitForExistence(timeout: 8) else { return }
    for _ in 0..<8 where alert.exists {
        alert.buttons["稍后"].tap()
    }
}

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
        let field = app.textFields["settings.search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 25))
        XCTAssertGreaterThan(field.frame.width, app.frame.width * 0.7)
        attach(app, "settings-search-above-list")
        field.tap()
        field.typeText("锁屏没歌词")
        let result = app.buttons["settings.result.lyrics.lockScreen"]
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        attach(app, "settings-search-results")
    }

    func testSettingsSearchReturnsToStableRoot() {
        verifySettingsSearchReturn(navigationMode: "standard")
    }

    func testMinimalSettingsSearchReturnsToStableRoot() {
        verifySettingsSearchReturn(navigationMode: "minimal")
    }

    private func verifySettingsSearchReturn(navigationMode: String) {
        continueAfterFailure = false
        let app = searchApp(navigationMode: navigationMode)
        app.launchEnvironment["PRIMUSE_OPEN_PAGE"] = "settings"
        addTeardownBlock { @MainActor in
            app.terminate()
            app.launchEnvironment.removeValue(forKey: "PRIMUSE_OPEN_PAGE")
            app.launchArguments += ["-primuse.navigation.mode.v1", "standard", "-primuse.navigation.selectedTab.v1", "0"]
            app.launch()
            let home = app.tabBars.buttons["首页"]
            if home.waitForExistence(timeout: 20) { home.tap() }
            XCTAssertTrue(app.buttons["home.spaceFilter.music"].waitForExistence(timeout: 15))
            app.terminate()
        }
        app.launch()
        let field = app.textFields["settings.search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 90))
        let rootFieldFrame = field.frame
        let results = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'settings.result.'"))

        for (index, query) in ["封面", "歌词"].enumerated() {
            field.tap()
            field.typeText(query)
            let result = results.firstMatch
            XCTAssertTrue(result.waitForExistence(timeout: 5))
            result.tap()
            XCTAssertTrue(field.waitForNonExistence(timeout: 5))
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
            attach(app, "settings-\(navigationMode)-search-detail-\(index)")

            if index == 0 {
                app.navigationBars.buttons.element(boundBy: 0).tap()
            } else {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
                    .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
            }

            XCTAssertTrue(field.waitForExistence(timeout: 5))
            XCTAssertEqual(results.count, 0)
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3))
            XCTAssertNotEqual(field.value as? String, query)
            XCTAssertEqual(field.frame.minY, rootFieldFrame.minY, accuracy: 1)
            XCTAssertEqual(field.frame.height, rootFieldFrame.height, accuracy: 1)
            attach(app, "settings-\(navigationMode)-search-return-\(index)")
        }
    }

    func testStandardSearchSubmissionKeepsQueryAndCanResumeEditing() {
        continueAfterFailure = false
        let app = searchApp(navigationMode: "standard")
        app.launch()
        dismissStoredSourceAuthenticationAlerts(in: app)
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

    func testArtistAlbumsExpandInlineAndStayExpandedAfterOpeningAlbum() {
        assertArtistAlbumsExpandInline(collection: "releases")
    }

    func testArtistAppearsOnAlbumsExpandInlineAndStayExpandedAfterOpeningAlbum() {
        assertArtistAlbumsExpandInline(collection: "appearsOn")
    }

    private func assertArtistAlbumsExpandInline(collection: String) {
        continueAfterFailure = false
        let app = searchApp(navigationMode: "standard")
        let artist = ProcessInfo.processInfo.environment["PRIMUSE_ARTIST_TEST_NAME"] ?? "王菲"
        app.launchEnvironment["PRIMUSE_OPEN_PAGE"] = "artist:\(artist)"
        app.launch()
        defer { app.terminate() }
        dismissStoredSourceAuthenticationAlerts(in: app)
        let launchAlert = app.alerts["上次启动没有完成"]
        if launchAlert.exists {
            launchAlert.buttons["关闭"].tap()
            XCTAssertTrue(launchAlert.waitForNonExistence(timeout: 5))
        }
        let artistMenu = app.buttons["artistDetail.more"]
        XCTAssertTrue(artistMenu.waitForExistence(timeout: 30))
        let seeAll = app.buttons["artist.albums.\(collection).seeAll"]
        let collapse = app.buttons["artist.albums.\(collection).collapse"]
        for _ in 0..<8 where !seeAll.isHittable { app.swipeUp() }
        XCTAssertTrue(seeAll.isHittable)
        let navigationButtons = app.navigationBars.buttons.allElementsBoundByIndex.map(\.identifier)
        seeAll.tap()
        XCTAssertTrue(seeAll.waitForNonExistence(timeout: 5))
        XCTAssertTrue(collapse.waitForExistence(timeout: 5))
        XCTAssertEqual(collapse.label, "收起")
        XCTAssertTrue(artistMenu.exists, "Expanding albums must keep the artist page open")
        XCTAssertEqual(app.navigationBars.buttons.allElementsBoundByIndex.map(\.identifier), navigationButtons)
        let albums = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "artist.album."))
        XCTAssertTrue(albums.firstMatch.waitForExistence(timeout: 5))
        attach(app, "artist-albums-\(collection)-expanded-inline")

        let firstAlbum = albums.firstMatch
        for _ in 0..<4 where !firstAlbum.isHittable { app.swipeUp() }
        XCTAssertTrue(firstAlbum.isHittable)
        XCTAssertLessThan(firstAlbum.frame.width, 150, "Expanded album cards should remain compact")
        if collection == "releases" {
            let thirdAlbum = albums.element(boundBy: 2)
            XCTAssertTrue(thirdAlbum.exists)
            XCTAssertEqual(firstAlbum.frame.minY, thirdAlbum.frame.minY, accuracy: 1,
                           "A standard iPhone should fit three album cards per row")
        }
        firstAlbum.tap()
        XCTAssertTrue(artistMenu.waitForNonExistence(timeout: 5))
        let back = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        XCTAssertTrue(artistMenu.waitForExistence(timeout: 5))
        XCTAssertFalse(seeAll.exists)
        XCTAssertTrue(collapse.exists)
        XCTAssertTrue(albums.firstMatch.exists)
        for _ in 0..<8 where !collapse.isHittable { app.swipeDown() }
        XCTAssertTrue(collapse.isHittable)
        collapse.tap()
        XCTAssertTrue(seeAll.waitForExistence(timeout: 5))
        XCTAssertTrue(collapse.waitForNonExistence(timeout: 5))
        XCTAssertTrue(albums.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertTrue(artistMenu.exists)
        attach(app, "artist-albums-\(collection)-collapsed")
        seeAll.tap()
        XCTAssertTrue(collapse.waitForExistence(timeout: 5))
        XCTAssertTrue(albums.firstMatch.waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(artistMenu.waitForNonExistence(timeout: 5))
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

    func testFolderModeOpensContainingDirectoryAndLocatesAgain() {
        let app = launch("songs", folders: true)
        defer { app.terminate() }
        locateAndVerify(app)
        XCTAssertTrue(app.navigationBars["Album"].exists)
        app.scrollViews.firstMatch.swipeDown(velocity: .fast)
        locateAndVerify(app)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "libraryFolderNode.source.")).firstMatch.waitForExistence(timeout: 5))
    }

    func testHomeFolderLocationOpensFullListBeyondPreview() {
        let app = launch("folders", folders: true)
        defer { app.terminate() }
        locateAndVerify(app)
        XCTAssertTrue(app.navigationBars["Album"].exists)
        app.scrollViews.firstMatch.swipeDown(velocity: .fast)
        locateAndVerify(app)
    }

    func testHomeFolderLocationLeavesAnotherDirectory() {
        let app = launch("otherFolder", folders: true, target: "100")
        defer { app.terminate() }
        XCTAssertTrue(app.navigationBars["Other"].waitForExistence(timeout: 20))
        let locate = app.buttons["songList.locateCurrent"].firstMatch
        XCTAssertTrue(locate.waitForExistence(timeout: 10))
        locate.tap()
        let target = app.buttons["song.actions.location-100"].firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 15))
        let visible = expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: target)
        wait(for: [visible], timeout: 10)
        XCTAssertTrue(app.navigationBars["Album"].exists)
    }

    func testMiniPlayerRevealPreservesFolderMode() {
        let app = launch("playlist", folders: true)
        defer { app.terminate() }
        let mini = app.buttons.matching(identifier: "locationFixture.miniPlayer")
            .matching(NSPredicate(format: "label BEGINSWITH %@", "正在播放:")).firstMatch
        XCTAssertTrue(mini.waitForExistence(timeout: 30))
        mini.press(forDuration: 1)
        let reveal = app.buttons["在资料库中显示"]
        XCTAssertTrue(reveal.waitForExistence(timeout: 5))
        reveal.tap()
        XCTAssertTrue(targetRow(app).waitForExistence(timeout: 15))
        assertTargetVisible(app)
        XCTAssertTrue(app.navigationBars["Album"].exists)
    }

    func testLargeSongListLocatesPausedSongAndRepeatsAfterScrollingAway() {
        let app = launch("songs")
        defer { app.terminate() }
        dismissStoredSourceAuthenticationAlerts(in: app)
        locateAndVerify(app)
        app.scrollViews.firstMatch.swipeDown(velocity: .fast)
        app.scrollViews.firstMatch.swipeDown(velocity: .fast)
        locateAndVerify(app)
        attach(app, "song-location-large-library")
    }

    func testTileGridLocatesDistantSongAndOpensLongPressActions() {
        assertDecorativeAppearance("tiles")
    }

    func testFocusCardsLocateDistantSongAndOpenLongPressActions() {
        assertDecorativeAppearance("focus")
    }

    func testLocationEmphasisRepeatsWithoutMovingVisibleSongsInEveryStyle() {
        for (appearance, colorScheme) in [("list", "dark"), ("tiles", "dark"), ("tiles", "light"),
                                          ("focus", "dark"), ("focus", "light")] {
            let app = launch("songs", appearance: appearance, colorScheme: colorScheme)
            defer { app.terminate() }
            let locate = app.buttons["songList.locateCurrent"].firstMatch
            XCTAssertTrue(locate.waitForExistence(timeout: 30))
            locate.tap()
            let row = app.buttons["songRow.location-3990"].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 15))
            let visible = expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: row)
            wait(for: [visible], timeout: 15)
            let originalFrame = row.frame
            locate.tap()
            attach(app, "location-emphasis-\(appearance)-\(colorScheme)")
            XCTAssertEqual(row.frame.midY, originalFrame.midY, accuracy: 1,
                "Repeating location should emphasize the visible song without scrolling it")
            XCTAssertEqual(row.frame.height, originalFrame.height, accuracy: 1)
            app.terminate()
        }
    }

    func testTilesAndFocusScrollInLightAndDarkAppearance() {
        for (appearance, colorScheme) in [("tiles", "light"), ("tiles", "dark"), ("focus", "light"), ("focus", "dark")] {
            let app = launch("songs", appearance: appearance, colorScheme: colorScheme)
            defer { app.terminate() }
            let locate = app.buttons["songList.locateCurrent"].firstMatch
            XCTAssertTrue(locate.waitForExistence(timeout: 30))
            locate.tap()
            let row = app.buttons["songRow.location-3990"].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 15))
            let visible = expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: row)
            wait(for: [visible], timeout: 15)
            let initialHeight = row.frame.height
            attach(app, "\(appearance)-\(colorScheme)-center")
            let scroll = app.scrollViews.firstMatch
            let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.68))
            let end = start.withOffset(CGVector(dx: 0, dy: -160))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.4)
            XCTAssertTrue(row.isHittable)
            XCTAssertEqual(row.frame.height, initialHeight, accuracy: 1, "Scroll effects must not change the scroll target height")
            attach(app, "\(appearance)-\(colorScheme)-upper")
            row.press(forDuration: 1)
            let select = app.buttons["选择"].firstMatch
            XCTAssertTrue(select.waitForExistence(timeout: 5))
            select.tap()
            XCTAssertEqual(row.value as? String, "已选择", "A moving card must still open its own song menu")
            app.buttons["取消"].firstMatch.tap()
            app.terminate()
        }
    }

    func testAppearancePickerSwitchesLayoutFromTheMoreMenu() {
        // 不带启动参数：参数域里的值会盖住菜单写进去的选择。
        let app = launch("songs", appearance: nil)
        defer {
            chooseAppearance("列表", in: app)
            app.terminate()
        }
        let locate = app.buttons["songList.locateCurrent"].firstMatch
        XCTAssertTrue(locate.waitForExistence(timeout: 30))
        chooseAppearance("列表", in: app)
        locate.tap()
        let row = app.buttons["songRow.location-3990"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["song.actions.location-3990"].waitForExistence(timeout: 5))

        chooseAppearance("方块", in: app)
        locate.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        let visible = expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: row)
        wait(for: [visible], timeout: 15)
        XCTAssertFalse(app.buttons["song.actions.location-3990"].exists, "Tiles keep single-song actions in the long-press menu")
        let neighbour = app.buttons["songRow.location-3991"].firstMatch
        XCTAssertTrue(neighbour.waitForExistence(timeout: 5))
        XCTAssertEqual(neighbour.frame.midY, row.frame.midY, accuracy: 1, "Two tiles share a row on a portrait phone")
        XCTAssertLessThan(row.frame.width, app.frame.width * 0.6)
        XCTAssertEqual(row.frame.width, row.frame.height, accuracy: 1)
        attach(app, "appearance-picker-tiles")
        row.press(forDuration: 1)
        XCTAssertTrue(app.buttons["加入播放队列"].firstMatch.waitForExistence(timeout: 5),
                      "Without swipe actions the menu offers adding to the queue")
        app.buttons["选择"].firstMatch.tap()
        XCTAssertEqual(row.value as? String, "已选择")
        app.buttons["取消"].firstMatch.tap()

        chooseAppearance("聚焦", in: app)
        locate.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["song.actions.location-3990"].waitForExistence(timeout: 5))
        XCTAssertGreaterThan(row.frame.width, app.frame.width * 0.75)
        attach(app, "appearance-picker-focus")
    }

    private func chooseAppearance(_ title: String, in app: XCUIApplication) {
        let more = app.buttons["songList.more"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        more.tap()
        let picker = app.buttons["列表样式"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "The appearance picker lives in the more menu")
        picker.tap()
        let option = app.buttons[title].firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5))
        option.tap()
    }

    private func assertDecorativeAppearance(_ appearance: String) {
        let app = launch("songs", appearance: appearance)
        defer { app.terminate() }
        let locate = app.buttons["songList.locateCurrent"].firstMatch
        XCTAssertTrue(locate.waitForExistence(timeout: 30))
        locate.tap()
        let row = app.buttons["songRow.location-3990"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        let visible = expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: row)
        wait(for: [visible], timeout: 15)
        XCTAssertEqual(app.buttons["song.actions.location-3990"].exists, appearance == "focus")
        XCTAssertLessThan(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "songRow.")).count, 100,
                          "A 4,000-song list must not materialize every row")
        attach(app, "song-list-\(appearance)")
        row.press(forDuration: 1)
        let select = app.buttons["选择"].firstMatch
        XCTAssertTrue(select.waitForExistence(timeout: 5))
        select.tap()
        let cancel = app.buttons["取消"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let selectedValue = row.value as? String
        row.tap()
        XCTAssertNotEqual(row.value as? String, selectedValue, "Tapping a card in selection mode toggles its own song")
        row.tap()
        XCTAssertEqual(row.value as? String, selectedValue)
        cancel.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.press(forDuration: 1)
        XCTAssertTrue(app.buttons["选择"].firstMatch.waitForExistence(timeout: 5))
    }

    func testPlaylistLocatesDistantSongAndRepeatsAfterScrollingAway() {
        assertPlaylistLocation("playlist")
    }

    func testLikedSongsLocatesDistantSongAndRepeatsAfterScrollingAway() {
        assertPlaylistLocation("liked")
    }

    func testPlaylistCoverWallDoesNotCaptureSongLocation() {
        assertPlaylistLocation("playlist", coverWall: true)
    }

    func testLikedSongsCoverWallDoesNotCaptureSongLocation() {
        assertPlaylistLocation("liked", coverWall: true)
    }

    private func assertPlaylistLocation(_ page: String, coverWall: Bool = false) {
        let app = launch(page, coverWall: coverWall)
        defer { app.terminate() }
        dismissStoredSourceAuthenticationAlerts(in: app)
        locateAndVerify(app)
        let originalFrame = targetRow(app).frame
        locateAndVerify(app)
        XCTAssertEqual(targetRow(app).frame.midY, originalFrame.midY, accuracy: 1,
                       "Locating a visible song must not move the list")
        app.scrollViews.firstMatch.swipeDown(velocity: .fast)
        app.scrollViews.firstMatch.swipeDown(velocity: .fast)
        locateAndVerify(app)
        attach(app, "song-location-\(page)")
    }

    func testPlaylistFilterRequiresConfirmationAndPreservesItOnCancel() {
        let app = launch("playlist", coverWall: true)
        defer { app.terminate() }
        dismissStoredSourceAuthenticationAlerts(in: app)
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
        dismissStoredSourceAuthenticationAlerts(in: app)
        locateAndVerify(app)
        attach(app, "song-location-smart-playlist")
    }

    func testArtistLocatesSongOutsidePopularPreview() {
        let app = launch("artist")
        defer { app.terminate() }
        locateAndVerify(app)
        attach(app, "song-location-artist-all-songs")
    }

    func testArtistOfflineFailureHintKeepsCurrentSongUntilTitleIsTapped() {
        let app = launch("artistOfflineFailure")
        defer { app.terminate() }
        let mini = app.buttons["locationFixture.miniPlayer"].firstMatch
        XCTAssertTrue(mini.waitForExistence(timeout: 30))
        XCTAssertTrue(mini.label.contains("Track 3990"), mini.label)

        let warning = app.buttons["离线下载失败"].firstMatch
        for _ in 0..<3 where !warning.isHittable || warning.frame.maxY >= mini.frame.minY - 16 {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
            start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -240)),
                        withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        XCTAssertTrue(warning.isHittable)
        warning.tap()
        let reason = app.staticTexts["连接超时。"]
        XCTAssertTrue(reason.waitForExistence(timeout: 5))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.15)).tap()
        XCTAssertTrue(reason.waitForNonExistence(timeout: 5))
        XCTAssertTrue(mini.label.contains("Track 3990"), mini.label)

        app.scrollViews.staticTexts["Track 0000"].firstMatch.tap()
        let changed = expectation(for: NSPredicate(format: "label CONTAINS %@", "Track 0000"),
                                  evaluatedWith: mini)
        wait(for: [changed], timeout: 8)
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

    func testPlayerControlsIgnoreSwipesAndAcceptTheNextTap() {
        let app = launch("playlist", playerGestures: true)
        defer { app.terminate() }
        let mini = app.buttons.matching(identifier: "locationFixture.miniPlayer")
            .matching(NSPredicate(format: "label BEGINSWITH %@", "正在播放:")).firstMatch
        XCTAssertTrue(mini.waitForExistence(timeout: 30))
        mini.tap()
        let shuffle = app.buttons["随机播放"].firstMatch
        XCTAssertTrue(shuffle.waitForExistence(timeout: 10))
        let original = shuffle.value as? String
        let start = shuffle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 3, dy: 48)))
        XCTAssertEqual(shuffle.value as? String, original)
        shuffle.tap()
        XCTAssertNotEqual(shuffle.value as? String, original)
        shuffle.tap()
        XCTAssertEqual(shuffle.value as? String, original)

        let volume = app.descendants(matching: .any).matching(identifier: "音量").firstMatch
        XCTAssertTrue(volume.isHittable)
        let originalVolume = volume.value as? String
        XCTAssertNotNil(originalVolume)
        let volumeStart = volume.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        volumeStart.press(forDuration: 0.05, thenDragTo: volumeStart.withOffset(CGVector(dx: 2, dy: 32)))
        XCTAssertEqual(volume.value as? String, originalVolume)
        let volumeValue = Double((originalVolume ?? "100%").replacingOccurrences(of: "%", with: "")) ?? 100
        let adjustment: CGFloat = volumeValue > 50 ? -36 : 36
        volumeStart.press(forDuration: 0.05, thenDragTo: volumeStart.withOffset(CGVector(dx: adjustment, dy: 0)))
        XCTAssertNotEqual(volume.value as? String, originalVolume)
        volumeStart.press(forDuration: 0.05, thenDragTo: volumeStart.withOffset(CGVector(dx: -adjustment, dy: 0)))

        let queue = app.buttons["播放队列"].firstMatch
        XCTAssertTrue(queue.isHittable)
        let queueStart = queue.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        queueStart.press(forDuration: 0.05, thenDragTo: queueStart.withOffset(CGVector(dx: 2, dy: 40)))
        XCTAssertTrue(shuffle.isHittable, "Swiping a bottom button must not open its panel")
        queue.tap()
        XCTAssertFalse(shuffle.isHittable, "A separate tap must still open the queue")
        attach(app, "player-controls-tap-after-swipe")
    }

    func testProgressSliderKeepsPositionDuringDownwardSwipesAndMovingLayout() {
        let app = launch("progressGestures")
        defer { app.terminate() }
        let slider = app.descendants(matching: .any).matching(identifier: "progressFixture.slider").firstMatch
        let result = app.staticTexts["progressFixture.result"]
        XCTAssertTrue(slider.waitForExistence(timeout: 30))
        XCTAssertEqual(result.label, "0:120:idle")

        let leading = slider.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5))
        leading.tap()
        XCTAssertEqual(result.label, "0:120:idle")
        leading.press(forDuration: 0.05, thenDragTo: leading.withOffset(CGVector(dx: 3, dy: 80)))
        XCTAssertEqual(result.label, "0:120:idle")

        let start = slider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 56, dy: 0)))
        let fields = result.label.split(separator: ":")
        XCTAssertEqual(fields.first, "1")
        XCTAssertEqual(Double(fields.dropFirst().first ?? "") ?? -1, 140, accuracy: 3)
        XCTAssertEqual(fields.last, "idle")
        let afterSeek = result.label

        for _ in 0..<2 {
            let nextStart = slider.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5))
            nextStart.press(forDuration: 0.05, thenDragTo: nextStart.withOffset(CGVector(dx: 2, dy: 70)))
            XCTAssertEqual(result.label, afterSeek)
        }
        let next = slider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        next.press(forDuration: 0.05, thenDragTo: next.withOffset(CGVector(dx: -28, dy: 0)))
        let finalFields = result.label.split(separator: ":")
        XCTAssertEqual(finalFields.first, "2")
        XCTAssertEqual(Double(finalFields.dropFirst().first ?? "") ?? -1, 80, accuracy: 3)
        XCTAssertEqual(finalFields.last, "idle")
    }

    private func launch(_ page: String, appearance: String? = "list", colorScheme: String = "dark",
                        coverWall: Bool = false, folders: Bool = false, target: String? = nil,
                        playerGestures: Bool = false) -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.welape.yuanyin")
        app.launchEnvironment["PRIMUSE_VISUAL_EVIDENCE"] = "songLocation"
        app.launchEnvironment["PRIMUSE_LOCATION_PAGE"] = page
        if folders { app.launchEnvironment["PRIMUSE_LOCATION_FOLDERS"] = "1" }
        if let target { app.launchEnvironment["PRIMUSE_LOCATION_TARGET"] = target }
        if coverWall {
            app.launchEnvironment["PRIMUSE_LOCATION_COVER_WALL"] = "1"
            app.launchEnvironment["PRIMUSE_LOCATION_TARGET"] = "1990"
        }
        app.launchEnvironment["PRIMUSE_DIAGNOSTIC_LOGGING"] = "off"
        app.launchArguments = [
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
            "-library.songBrowseMode", folders ? "folder" : "flat",
            "-library.songFilter.v1", "all",
            "-primuse.library.playlistCoverWall.v1", coverWall ? "YES" : "NO",
            "-primuse.navigation.mode.v1", "standard",
            "-primuse.hasSeenOnboarding", "YES",
            "-primuse.launch.consecutiveAborts", "0",
            "-primuse.launch.safeModeLatched", "NO"
        ]
        if let appearance {
            app.launchArguments += ["-songListAppearance", appearance]
        }
        if appearance != "list" {
            app.launchEnvironment["PRIMUSE_LOCATION_REFERENCE_ARTWORK"] = "1"
        }
        app.launchArguments += ["-primuse.appearance", colorScheme]
        if playerGestures {
            app.launchArguments += ["-primuse.player.showsVolumeBar", "YES", "-primuse.player.controls.music.v1", "{}"]
        }
        app.launch()
        return app
    }

    private func targetRow(_ app: XCUIApplication) -> XCUIElement {
        let index = app.launchEnvironment["PRIMUSE_LOCATION_TARGET"] ?? "3990"
        return app.scrollViews.staticTexts["Track \(index)"].firstMatch
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
        let index = app.launchEnvironment["PRIMUSE_LOCATION_TARGET"] ?? "3990"
        let labels = app.scrollViews.staticTexts.matching(identifier: "Track \(index)")
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
