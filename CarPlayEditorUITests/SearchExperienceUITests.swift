import XCTest

@MainActor
final class SearchExperienceUITests: XCTestCase {
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

    func testMinimalSearchSubmissionCollapsesFieldAndCanResumeEditing() {
        continueAfterFailure = false
        let app = searchApp(navigationMode: "minimal")
        app.launch()
        let field = app.textFields["minimal.search"]
        XCTAssertTrue(field.waitForExistence(timeout: 25))
        field.tap()
        field.typeText("夜曲\n")
        let collapsed = app.buttons["minimal.search.collapsed"]
        XCTAssertTrue(collapsed.waitForExistence(timeout: 5))
        XCTAssertTrue(collapsed.label.contains("夜曲"))
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertFalse(field.exists)
        attach(app, "search-minimal-submitted")
        collapsed.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "夜曲")
        attach(app, "search-minimal-reopened")
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
