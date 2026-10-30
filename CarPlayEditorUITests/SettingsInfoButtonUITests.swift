import XCTest

@MainActor
final class SettingsInfoButtonUITests: XCTestCase {
    func testHiddenIconPickerOnlyOpensFromRepeatedVersionTaps() {
        continueAfterFailure = false
        let app = settingsApp("about.version")
        addTeardownBlock { @MainActor () async throws -> Void in
            app.terminate()
            app.launchEnvironment.removeValue(forKey: "PRIMUSE_OPEN_SETTINGS")
            app.launch()
            let home = app.tabBars.buttons["首页"]
            if home.waitForExistence(timeout: 20) { home.tap() }
            XCTAssertTrue(app.buttons["home.spaceFilter.music"].waitForExistence(timeout: 15))
            app.terminate()
        }
        app.launchArguments += ["-primuse.navigation.mode.v1", "standard"]
        app.launch()
        let version = app.descendants(matching: .any)["settings.about.version"].firstMatch
        XCTAssertTrue(version.waitForExistence(timeout: 25))
        let hidden = app.buttons["appIcon.AppIconGroove"]
        XCTAssertFalse(hidden.exists)
        version.tap(withNumberOfTaps: 6, numberOfTouches: 1)
        XCTAssertFalse(hidden.exists)
        version.tap()
        XCTAssertTrue(hidden.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["appIcon.default"].exists)
        attach(app, "hidden-app-icon-picker")
        app.navigationBars.buttons["完成"].tap()
        XCTAssertTrue(hidden.waitForNonExistence(timeout: 5))
        app.terminate()
        app.launchEnvironment["PRIMUSE_OPEN_SETTINGS"] = "appearance.appIcon"
        app.launch()
        XCTAssertTrue(app.buttons["appIcon.default"].waitForExistence(timeout: 25))
        XCTAssertFalse(hidden.exists)
    }

    func testOfflineDownloadEditingOwnsBottomBarInStandardNavigation() throws {
        try checkOfflineDownloadEditing(navigationMode: "standard")
    }

    func testOfflineDownloadEditingOwnsBottomBarInMinimalNavigation() throws {
        try checkOfflineDownloadEditing(navigationMode: "minimal")
    }

    private func checkOfflineDownloadEditing(navigationMode: String) throws {
        continueAfterFailure = false
        let app = settingsApp("storage.offlineDownloads")
        app.launchArguments += ["-primuse.navigation.mode.v1", navigationMode]
        app.launch()
        defer { app.terminate() }

        let downloads = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '离线下载'"))
            .firstMatch
        XCTAssertTrue(downloads.waitForExistence(timeout: 25))
        app.swipeUp()
        for _ in 0..<4 where !downloads.isHittable { app.swipeUp() }
        downloads.tap()
        let edit = app.navigationBars.buttons["编辑"]
        guard edit.waitForExistence(timeout: 5) else {
            throw XCTSkip("Requires at least one offline download in the test library")
        }
        let player = app.buttons["播放"]
        let hadPlayer = player.waitForExistence(timeout: 3)
        guard hadPlayer || navigationMode == "minimal" else {
            throw XCTSkip("Requires a paused playback session to verify player overlap")
        }

        edit.tap()
        let removeAll = app.buttons["全部移除"]
        XCTAssertTrue(removeAll.waitForExistence(timeout: 5))
        attach(app, "offline-enter-editing-\(navigationMode)")
        XCTAssertTrue(player.waitForNonExistence(timeout: 5), "Editing must release the player's bottom area")
        XCTAssertFalse(app.tabBars.firstMatch.isHittable)
        let removeSelected = app.buttons["移除所选（0）"]
        XCTAssertTrue(removeSelected.exists)
        XCTAssertFalse(removeSelected.isEnabled)
        let songRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'offline.download.'")).firstMatch
        XCTAssertTrue(songRow.waitForExistence(timeout: 3))
        songRow.tap()
        let selectedAction = app.buttons["移除所选（1）"]
        XCTAssertTrue(selectedAction.waitForExistence(timeout: 3))
        XCTAssertTrue(selectedAction.isEnabled)
        XCTAssertGreaterThan(removeAll.frame.width, 40)
        XCTAssertGreaterThan(selectedAction.frame.width, 40)
        XCTAssertTrue(app.frame.contains(removeAll.frame))
        XCTAssertTrue(app.frame.contains(selectedAction.frame))
        XCTAssertFalse(removeAll.frame.intersects(selectedAction.frame))
        attach(app, "offline-editing-\(navigationMode)")

        selectedAction.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let confirm = app.buttons["移除"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        attach(app, "offline-confirm-selected-\(navigationMode)")
        dismissRemovalConfirmation(app)
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 3))
        removeAll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        attach(app, "offline-confirm-all-\(navigationMode)")
        dismissRemovalConfirmation(app)
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 3))
        app.navigationBars.buttons["完成"].tap()
        XCTAssertTrue(removeAll.waitForNonExistence(timeout: 3))
        if hadPlayer { XCTAssertTrue(player.waitForExistence(timeout: 5)) }

        edit.tap()
        XCTAssertTrue(player.waitForNonExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(downloads.waitForExistence(timeout: 5))
        XCTAssertTrue(player.waitForExistence(timeout: 5), "Returning to storage must restore the player")
        attach(app, "offline-exit-editing-\(navigationMode)")
    }

    private func dismissRemovalConfirmation(_ app: XCUIApplication) {
        let cancel = app.buttons["取消"]
        if cancel.exists {
            cancel.tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        }
    }

    func testSectionHeaderInfoOpensBubble() {
        continueAfterFailure = false
        let app = settingsApp("storage.offlineDownloads")
        app.launch()
        defer { app.terminate() }
        let infos = infoButtons(app)
        XCTAssertTrue(infos.firstMatch.waitForExistence(timeout: 25))
        attach(app, "storage-page")
        let header = app.staticTexts.matching(NSPredicate(format: "label == '离线下载'"))
            .allElementsBoundByIndex
        let button = infos.allElementsBoundByIndex.first { info in
            header.contains { abs($0.frame.midY - info.frame.midY) < 14 }
        }
        XCTAssertNotNil(button)
        button?.tap()
        let bubble = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '离线下载单独存放'")).firstMatch
        XCTAssertTrue(bubble.waitForExistence(timeout: 5))
        attach(app, "storage-offline-bubble")
        dismissBubble(app)
        XCTAssertTrue(bubble.waitForNonExistence(timeout: 5))
    }

    func testToggleLabelInfoDoesNotFlipSwitch() {
        continueAfterFailure = false
        let app = settingsApp("playback.crossfade")
        app.launch()
        defer { app.terminate() }
        let toggle = app.switches.matching(NSPredicate(format: "label BEGINSWITH '淡入淡出'")).firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 25))
        attach(app, "playback-page")
        let before = toggle.value as? String
        let info = infoButtons(app).allElementsBoundByIndex.first {
            abs($0.frame.midY - toggle.frame.midY) < 14
        }
        XCTAssertNotNil(info, "info button inside the toggle row is not exposed")
        info?.tap()
        let bubble = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '歌曲自然播完时'")).firstMatch
        XCTAssertTrue(bubble.waitForExistence(timeout: 5))
        attach(app, "playback-crossfade-bubble")
        XCTAssertEqual(toggle.value as? String, before)
        dismissBubble(app)
        XCTAssertTrue(bubble.waitForNonExistence(timeout: 5))
        // 开关本身照常能拨。
        toggle.switches.firstMatch.exists ? toggle.switches.firstMatch.tap() : toggle.tap()
        XCTAssertNotEqual(toggle.value as? String, before)
        attach(app, "playback-crossfade-toggled")
        toggle.switches.firstMatch.exists ? toggle.switches.firstMatch.tap() : toggle.tap()
        XCTAssertEqual(toggle.value as? String, before)
    }

    func testPickerLabelInfoOpensBubbleNotMenu() {
        continueAfterFailure = false
        let app = settingsApp("appearance.audioInfo")
        app.launch()
        defer { app.terminate() }
        let title = app.staticTexts["播放页显示音频信息"]
        XCTAssertTrue(title.waitForExistence(timeout: 25))
        let info = infoButtons(app).allElementsBoundByIndex.first {
            abs($0.frame.midY - title.frame.midY) < 14
        }
        XCTAssertNotNil(info, "info button inside the picker label is not exposed")
        info?.tap()
        let bubble = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '显示在进度条下方'")).firstMatch
        XCTAssertTrue(bubble.waitForExistence(timeout: 5))
        attach(app, "player-audio-info-bubble")
        dismissBubble(app)
        XCTAssertTrue(bubble.waitForNonExistence(timeout: 5))
        // 点值那一侧仍是选择菜单。
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '播放页显示音频信息'")).firstMatch
        if row.exists {
            row.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
            attach(app, "player-audio-info-menu")
        }
    }

    func testButtonRowInfoOpensBubbleNotAction() {
        continueAfterFailure = false
        let app = settingsApp("scraping.tidyLibrary")
        app.launch()
        defer { app.terminate() }
        let action = app.buttons["整理曲名、艺人和专辑"]
        XCTAssertTrue(action.waitForExistence(timeout: 25))
        for _ in 0..<6 where !action.isHittable { app.swipeUp() }
        let info = infoButtons(app).allElementsBoundByIndex.first {
            abs($0.frame.midY - action.frame.midY) < 14
        }
        XCTAssertNotNil(info)
        info?.tap()
        let bubble = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '找出乱码'")).firstMatch
        XCTAssertTrue(bubble.waitForExistence(timeout: 5))
        attach(app, "scraping-tidy-bubble")
        dismissBubble(app)
        XCTAssertTrue(bubble.waitForNonExistence(timeout: 5))
        // 点按钮本身照常打开整理页。
        let barsBefore = app.navigationBars.count
        action.tap()
        let opened = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in app.navigationBars.count > barsBefore },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [opened], timeout: 5), .completed)
        attach(app, "scraping-tidy-action")
    }

    /// 资料库页整页处于编辑状态(拖动排序),行里的圈问号也要点得开。
    func testToggleInfoInsideEditModeList() {
        continueAfterFailure = false
        let app = settingsApp("library.minimalStartListening")
        app.launch()
        defer { app.terminate() }
        let toggle = app.switches.matching(NSPredicate(format: "label BEGINSWITH '在「歌曲」页顶部'")).firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 25))
        for _ in 0..<6 where !toggle.isHittable { app.swipeUp() }
        attach(app, "library-page")
        let before = toggle.value as? String
        let info = infoButtons(app).allElementsBoundByIndex.first {
            abs($0.frame.midY - toggle.frame.midY) < 14
        }
        XCTAssertNotNil(info, "info button inside the edit-mode toggle row is not exposed")
        info?.tap()
        let bubble = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '极简导航没有首页'")).firstMatch
        XCTAssertTrue(bubble.waitForExistence(timeout: 5))
        attach(app, "library-info-bubble")
        XCTAssertEqual(toggle.value as? String, before)
    }

    private func dismissBubble(_ app: XCUIApplication) {
        let region = app.otherElements["PopoverDismissRegion"]
        if region.exists {
            region.tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap()
        }
    }

    private func infoButtons(_ app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "label == '说明'"))
    }

    private func settingsApp(_ settingID: String) -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.welape.yuanyin")
        app.launchEnvironment["PRIMUSE_OPEN_SETTINGS"] = settingID
        app.launchEnvironment["PRIMUSE_DIAGNOSTIC_LOGGING"] = "off"
        app.launchEnvironment["PRIMUSE_NO_NOTIFICATION_PROMPT"] = "1"
        app.launchArguments = [
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
            "-primuse.hasSeenOnboarding", "YES",
            "-primuse.iCloudSyncEnabled", "NO",
            "-primuse.notifyLongTasks", "NO",
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
