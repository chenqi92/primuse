import XCTest

@MainActor
final class SettingsInfoButtonUITests: XCTestCase {
    func testPartialRadioSharingKeepsAvailableItemsAcrossOfflineAndOnlineModes() {
        continueAfterFailure = false
        let app = sharingFixtureApp()
        app.launchEnvironment["PRIMUSE_SHARE_TEST_BATCH"] = "1"
        app.launch()
        XCTAssertTrue(app.buttons["sharing.test.open"].waitForExistence(timeout: 30))
        app.buttons["sharing.test.open"].tap()
        XCTAssertTrue(app.buttons["sharing.copyCode"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["2 电台"].exists)
        let skipped = app.buttons["sharing.skippedItems"]
        if !skipped.isHittable { app.swipeUp() }
        XCTAssertTrue(skipped.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(skipped.label.contains("1"), skipped.label)
        skipped.tap()
        XCTAssertTrue(app.staticTexts["异常电台"].waitForExistence(timeout: 5))
        attach(app, "radio-sharing-partial-offline")
        let method = app.segmentedControls["sharing.method"]
        if !method.isHittable { app.swipeDown() }
        method.buttons["联网分享码"].tap()
        XCTAssertTrue(app.buttons["sharing.createOnlineCode"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["1 电台"].exists)
        if !skipped.isHittable { app.swipeUp() }
        XCTAssertTrue(skipped.label.contains("2"), skipped.label)
        app.swipeUp()
        if !app.staticTexts["内网电台"].exists {
            skipped.tap()
            app.swipeUp()
        }
        attach(app, "radio-sharing-partial-online")
        XCTAssertTrue(app.staticTexts["内网电台"].waitForExistence(timeout: 5), app.debugDescription)
        if !method.isHittable { app.swipeDown() }
        method.buttons["离线导入码"].tap()
        XCTAssertTrue(app.buttons["sharing.copyCode"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["2 电台"].exists)
        app.buttons["完成"].firstMatch.tap()
        XCTAssertTrue(app.buttons["sharing.test.open"].waitForExistence(timeout: 5))
    }

    func testWeChatAcceptsSharedLinkWithoutSending() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires WeChat on a test phone")
        #else
        continueAfterFailure = false
        let app = sharingFixtureApp()
        app.launch()
        XCTAssertTrue(app.buttons["sharing.test.open"].waitForExistence(timeout: 30))
        app.buttons["sharing.test.open"].tap()
        let share = app.buttons["sharing.shareLink"]
        XCTAssertTrue(share.waitForExistence(timeout: 10))
        share.tap()
        let wechatActivity = app.buttons.matching(NSPredicate(format: "label == '微信' OR label == 'WeChat'")).firstMatch
        XCTAssertTrue(wechatActivity.waitForExistence(timeout: 10), app.debugDescription)
        wechatActivity.tap()
        let wechat = XCUIApplication(bundleIdentifier: "com.tencent.xin")
        let forwardLabels = NSPredicate(format: "label == '转发给朋友' OR label == 'Send to Chat'")
        let forward = app.descendants(matching: .any).matching(forwardLabels).firstMatch
        XCTAssertTrue(forward.waitForExistence(timeout: 10), app.debugDescription)
        forward.tap()
        let titles = NSPredicate(format: "label == '选择一个聊天' OR label == '选择聊天' OR label == 'Select a Chat' OR label == 'Select Chat'")
        let picker = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.navigationBars.matching(titles).firstMatch.exists
                || app.staticTexts.matching(titles).firstMatch.exists
                || wechat.navigationBars.matching(titles).firstMatch.exists
                || wechat.staticTexts.matching(titles).firstMatch.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [picker], timeout: 15), .completed)
        let cancels = NSPredicate(format: "label == '关闭' OR label == 'Close' OR label == '取消' OR label == 'Cancel'")
        let cancel = app.buttons.matching(cancels).firstMatch
        if cancel.exists { cancel.tap() }
        else { wechat.buttons.matching(cancels).firstMatch.tap() }
        app.activate()
        let returned = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.state == .runningForeground && share.isHittable
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [returned], timeout: 10), .completed)
        #endif
    }

    func testCameraImportLinkOpensPrimuseWithoutTypingCode() {
        continueAfterFailure = false
        let app = sharingFixtureApp()
        app.launch()
        XCTAssertTrue(app.buttons["sharing.test.open"].waitForExistence(timeout: 30))
        let origin = Data("https://share.example.invalid".utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        let link = URL(string: "primuse://import-code?code=PMN1." + origin + ".123456." + String(repeating: "A", count: 43))!
        app.open(link)
        XCTAssertTrue(app.navigationBars["导入分享内容"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["share.example.invalid"].exists)
        XCTAssertFalse(app.textViews["sharing.code.input"].exists)
        app.buttons["取消"].firstMatch.tap()
        XCTAssertTrue(app.buttons["sharing.test.open"].waitForExistence(timeout: 5))
    }

    private func sharingFixtureApp() -> XCUIApplication {
        let app = settingsApp("about.version")
        app.launchEnvironment.removeValue(forKey: "PRIMUSE_OPEN_SETTINGS")
        app.launchEnvironment["PRIMUSE_VISUAL_EVIDENCE"] = "listeningShare"
        addTeardownBlock { @MainActor in
            app.terminate()
            app.launchEnvironment.removeValue(forKey: "PRIMUSE_VISUAL_EVIDENCE")
            app.launchEnvironment.removeValue(forKey: "PRIMUSE_SHARE_TEST_BATCH")
            app.launchArguments += ["-primuse.navigation.mode.v1", "standard", "-primuse.navigation.selectedTab.v1", "0"]
            app.launch()
            let home = app.tabBars.buttons["首页"]
            if home.waitForExistence(timeout: 20) { home.tap() }
            XCTAssertTrue(app.buttons["home.spaceFilter.music"].waitForExistence(timeout: 15))
            XCUIDevice.shared.press(.home)
            app.terminate()
        }
        return app
    }

    func testSettingsToolbarExportsImportsAndShares() {
        checkSettingsSharingMenu(navigationMode: "standard")
    }

    func testMinimalSettingsToolbarExportsImportsAndShares() {
        checkSettingsSharingMenu(navigationMode: "minimal")
    }

    private func checkSettingsSharingMenu(navigationMode: String) {
        continueAfterFailure = false
        let app = settingsApp("about.version")
        app.launchArguments += ["-primuse.navigation.mode.v1", navigationMode, "-primuse.navigation.hiddenTabs.v1", "[]"]
        addTeardownBlock { @MainActor in
            app.terminate()
            app.launchEnvironment.removeValue(forKey: "PRIMUSE_OPEN_SETTINGS")
            app.launchArguments += ["-primuse.navigation.mode.v1", "standard", "-primuse.navigation.selectedTab.v1", "0"]
            app.launch()
            let home = app.tabBars.buttons["首页"]
            if home.waitForExistence(timeout: 20) { home.tap() }
            XCTAssertTrue(app.buttons["home.spaceFilter.music"].waitForExistence(timeout: 15))
            XCUIDevice.shared.press(.home)
            app.terminate()
        }
        app.launch()
        let menu = app.buttons["sharing.menu.settings"]
        XCTAssertTrue(menu.waitForExistence(timeout: 25), app.debugDescription)
        menu.tap()
        let export = app.buttons["settings.backup.export"]
        XCTAssertTrue(export.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.buttons["分享我的电台"].exists)
        XCTAssertFalse(app.buttons["分享我的播客"].exists)
        attach(app, "settings-toolbar-menu-\(navigationMode)")
        export.tap()
        let cancel = app.buttons["取消"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 20), app.debugDescription)
        cancel.tap()
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.tap()
        app.buttons["settings.backup.import"].tap()
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), app.debugDescription)
        cancel.tap()
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.tap()
        app.buttons["分享我的设置"].tap()
        XCTAssertTrue(app.buttons["分享文件"].waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertFalse(app.switches["附带我的设置"].exists)
        attach(app, "settings-share-sheet-\(navigationMode)")
        app.buttons["完成"].firstMatch.tap()
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.tap()
        app.buttons["我分享的链接"].tap()
        XCTAssertTrue(app.navigationBars["我分享的链接"].waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["完成"].firstMatch.tap()
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }

    func testSharingCodesDefaultToOfflineAndPasteIntoPreview() {
        continueAfterFailure = false
        let app = settingsApp("about.version")
        app.launchEnvironment.removeValue(forKey: "PRIMUSE_OPEN_SETTINGS")
        app.launchArguments += ["-primuse.navigation.mode.v1", "standard", "-primuse.navigation.hiddenTabs.v1", "[]"]
        addTeardownBlock { @MainActor in
            app.terminate()
            app.launchEnvironment.removeValue(forKey: "PRIMUSE_OPEN_SETTINGS")
            app.launchArguments += ["-primuse.navigation.selectedTab.v1", "0"]
            app.launch()
            let home = app.tabBars.buttons["首页"]
            if home.waitForExistence(timeout: 20) { home.tap() }
            XCTAssertTrue(app.buttons["home.spaceFilter.music"].waitForExistence(timeout: 15))
            XCUIDevice.shared.press(.home)
            app.terminate()
        }
        app.launch()
        let settingsTab = app.tabBars.buttons["设置"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 25))
        settingsTab.tap()
        let menu = app.buttons["sharing.menu.settings"]
        XCTAssertTrue(menu.waitForExistence(timeout: 25))
        menu.tap()
        app.buttons["分享我的设置"].tap()
        let copy = app.buttons["sharing.copyCode"]
        XCTAssertTrue(copy.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(app.buttons["sharing.exportJSON"].exists)
        XCTAssertFalse(app.buttons["sharing.createOnlineCode"].exists)
        copy.tap()
        XCTAssertEqual(copy.label, "已复制")
        attach(app, "offline-sharing-code")
        app.buttons["联网分享码"].tap()
        XCTAssertTrue(app.buttons["sharing.createOnlineCode"].waitForExistence(timeout: 5))
        XCTAssertFalse(copy.exists)
        attach(app, "online-sharing-code-options")
        app.buttons["离线导入码"].tap()
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        app.buttons["完成"].firstMatch.tap()
        menu.tap()
        app.buttons["sharing.importCode"].tap()
        let paste = app.buttons["sharing.code.paste"]
        XCTAssertTrue(paste.waitForExistence(timeout: 5))
        paste.tap()
        app.buttons["sharing.code.preview"].tap()
        XCTAssertTrue(app.navigationBars["导入预览"].waitForExistence(timeout: 15), app.debugDescription)
        let settings = app.switches["应用附带的设置"]
        XCTAssertTrue(settings.exists, app.debugDescription)
        XCTAssertEqual(settings.value as? String, "0")
        attach(app, "offline-code-import-preview")
        app.buttons["完成"].firstMatch.tap()
        app.buttons["取消"].firstMatch.tap()
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.tap()
        app.buttons["sharing.importCode"].tap()
        let editor = app.textViews["sharing.code.input"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText("PM1.invalid")
        app.buttons["sharing.code.preview"].tap()
        XCTAssertTrue(app.staticTexts["导入码或 JSON 文件无效或不完整。"].waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["取消"].firstMatch.tap()
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
    }

    func testLibraryPagesKeepShareImportAndReceiveAvailable() {
        continueAfterFailure = false
        let app = settingsApp("about.version")
        app.launchEnvironment.removeValue(forKey: "PRIMUSE_OPEN_SETTINGS")
        app.launchArguments += ["-primuse.navigation.mode.v1", "standard", "-primuse.navigation.hiddenTabs.v1", "[]"]
        addTeardownBlock { @MainActor in
            app.terminate()
            app.launchEnvironment.removeValue(forKey: "PRIMUSE_OPEN_PAGE")
            app.launchArguments += ["-primuse.navigation.selectedTab.v1", "0"]
            app.launch()
            let home = app.tabBars.buttons["首页"]
            if home.waitForExistence(timeout: 20) { home.tap() }
            XCTAssertTrue(app.buttons["home.spaceFilter.music"].waitForExistence(timeout: 15))
            XCUIDevice.shared.press(.home)
            app.terminate()
        }
        for (page, scope) in [("radio", "stations"), ("podcasts", "podcasts"), ("spokenWord", "audiobooks")] {
            app.launchEnvironment["PRIMUSE_OPEN_PAGE"] = "section:" + page
            app.launch()
            let menu = app.buttons["sharing.menu." + scope]
            XCTAssertTrue(menu.waitForExistence(timeout: 80), app.debugDescription)
            menu.tap()
            XCTAssertTrue(app.buttons["导入分享文件"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["接收附近分享"].exists)
            XCTAssertTrue(app.buttons["sharing.importCode"].exists)
            XCTAssertFalse(app.buttons["settings.backup.export"].exists)
            attach(app, "sharing-menu-" + scope)
            app.buttons["导入分享文件"].tap()
            let cancel = app.buttons["取消"].firstMatch
            XCTAssertTrue(cancel.waitForExistence(timeout: 10), app.debugDescription)
            cancel.tap()
            XCTAssertTrue(menu.waitForExistence(timeout: 5))
            if scope == "audiobooks" {
                menu.tap()
                app.buttons["分享有声书链接"].tap()
                XCTAssertTrue(app.textFields["名称"].waitForExistence(timeout: 5))
                app.buttons["完成"].firstMatch.tap()
                XCTAssertTrue(menu.waitForExistence(timeout: 5))
            }
            XCUIDevice.shared.press(.home)
            app.terminate()
        }
    }

    func testOfflineSettingsBackupFilePickersWorkWithoutICloud() {
        continueAfterFailure = false
        let app = settingsApp("cloud.offlineBackup")
        app.launchArguments += ["-primuse.navigation.mode.v1", "standard", "-primuse.navigation.hiddenTabs.v1", "[]"]
        addTeardownBlock { @MainActor in
            app.terminate()
            app.launchEnvironment.removeValue(forKey: "PRIMUSE_OPEN_SETTINGS")
            app.launch()
            let home = app.tabBars.buttons["首页"]
            if home.waitForExistence(timeout: 20) { home.tap() }
            XCTAssertTrue(app.buttons["home.spaceFilter.music"].waitForExistence(timeout: 15))
            app.terminate()
        }
        app.launch()
        let entry = app.buttons["settings.cloud.offlineBackup"]
        XCTAssertTrue(entry.waitForExistence(timeout: 25), app.debugDescription)
        entry.tap()
        let export = app.buttons["settings.backup.export"]
        let importButton = app.buttons["settings.backup.import"]
        XCTAssertTrue(export.waitForExistence(timeout: 5))
        attach(app, "settings-backup")
        export.tap()
        let cancel = app.buttons["取消"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 20), app.debugDescription)
        attach(app, "settings-backup-export-picker")
        cancel.tap()
        XCTAssertTrue(importButton.waitForExistence(timeout: 5))
        importButton.tap()
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), app.debugDescription)
        attach(app, "settings-backup-import-picker")
        cancel.tap()
        XCTAssertTrue(export.waitForExistence(timeout: 5))
        XCTAssertFalse(app.alerts.firstMatch.exists)
        app.buttons["完成"].firstMatch.tap()
    }

    func testMusicMoreMenuOpensInCoverEditor() {
        continueAfterFailure = false
        let app = settingsApp("appearance.playerControls")
        app.launchEnvironment["PRIMUSE_DEBUG_PLAYER_CONTROLS"] = "music.cover"
        addTeardownBlock { @MainActor in
            app.terminate()
            app.launchEnvironment.removeValue(forKey: "PRIMUSE_DEBUG_PLAYER_CONTROLS")
            app.launchEnvironment.removeValue(forKey: "PRIMUSE_OPEN_SETTINGS")
            app.launch()
            let home = app.tabBars.buttons["首页"]
            if home.waitForExistence(timeout: 20) { home.tap() }
            XCTAssertTrue(app.buttons["home.spaceFilter.music"].waitForExistence(timeout: 15))
            app.terminate()
        }
        app.launch()
        let menu = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "「更多」菜单")).firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 25))
        XCTAssertTrue(menu.isEnabled)
        menu.tap()
        XCTAssertTrue(app.switches.firstMatch.waitForExistence(timeout: 5))
        attach(app, "music-more-menu-opened")
        XCTAssertTrue(app.navigationBars["「更多」菜单"].waitForExistence(timeout: 5), app.debugDescription)
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
    }

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
            "-primuse.launch.safeModeLatched", "NO",
            "-primuse.launch.backgroundLaunchRepairDone", "NO"
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
