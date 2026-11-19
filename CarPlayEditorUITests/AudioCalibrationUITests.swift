import XCTest

final class AudioCalibrationUITests: XCTestCase {
    @MainActor private func catalogSearch(in app: XCUIApplication) -> XCUIElement {
        let field = app.searchFields.firstMatch
        if !field.isHittable {
            let searchButton = app.toolbars.buttons["搜索"].firstMatch
            if searchButton.waitForExistence(timeout: 2), searchButton.isHittable { searchButton.tap() }
        }
        return field
    }

    @MainActor func testFadersAndExpandedParametersShareOneScrollingPage() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["PRIMUSE_EQ_UI_TESTS"] = "1"
        app.launchArguments += ["-eq.promptsOnHeadphoneChange", "YES", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
                                "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"]
        app.launch()
        defer { app.terminate() }
        let page = app.scrollViews["eq.page.scroll"]
        XCTAssertTrue(page.waitForExistence(timeout: 15))
        let fader = app.descendants(matching: .any).matching(identifier: "eq.band.4").firstMatch
        XCTAssertTrue(fader.isHittable)
        let original = fader.value as? String
        let y = fader.frame.midY
        let mid = fader.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let above = fader.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        mid.press(forDuration: 0.12, thenDragTo: above)
        XCTAssertNotEqual(fader.value as? String, original)
        XCTAssertEqual(fader.frame.midY, y, accuracy: 5)
        fader.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.83)).tap()
        let tappedGain = fader.value as? String
        XCTAssertTrue(tappedGain?.hasPrefix("-") == true)
        above.press(forDuration: 0.05, thenDragTo: above.withOffset(CGVector(dx: 0, dy: -125)))
        XCTAssertLessThan(fader.frame.midY, y - 20)
        XCTAssertEqual(fader.value as? String, tappedGain)

        let connect = app.buttons["eq.test.connect"]
        if !connect.isHittable { page.swipeDown() }
        connect.tap()
        let confirm = app.buttons["eq.calibration.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        page.swipeDown()
        app.buttons["Equalizer APO 参数"].tap()
        let preamp = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Preamp:")).firstMatch
        XCTAssertTrue(preamp.isHittable)
        XCTAssertEqual(page.scrollViews.count, 0)
        let initialY = preamp.frame.midY
        let parameter = preamp.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        parameter.press(forDuration: 0.05, thenDragTo: parameter.withOffset(CGVector(dx: 0, dy: -110)))
        XCTAssertLessThan(preamp.frame.midY, initialY - 30)
        let disconnect = app.buttons["eq.test.disconnect"]
        if !disconnect.isHittable { page.swipeDown() }
        disconnect.tap()
    }

    @MainActor func testHeadphonePresetRowSavesTwoHeadphonesAndSwitchesAfterRelaunch() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["PRIMUSE_EQ_UI_TESTS"] = "1"
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        defer { app.terminate() }
        let add = app.buttons["eq.headphones.add"]
        let scroll = app.scrollViews["eq.page.scroll"].firstMatch
        func reveal(_ element: XCUIElement) {
            for _ in 0..<4 where !element.isHittable { scroll.swipeUp() }
            XCTAssertTrue(element.isHittable)
        }
        XCTAssertTrue(scroll.waitForExistence(timeout: 15))
        reveal(add)
        add.tap()
        app.buttons["eq.headphones.saveCurrent"].tap()
        let name = app.alerts.textFields.firstMatch
        name.tap()
        name.typeText("Studio A")
        app.alerts.buttons["保存"].tap()
        let manual = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                                                      "eq.headphones.user.", "Studio A")).firstMatch
        let modelID = "autoeq.catalog.1b67e5d54423f50cae480b56"
        let extraModel = app.buttons["eq.calibration.preset.autoeq.catalog.1b0c739262215bd30fc03d71"]
        XCTAssertTrue(extraModel.waitForExistence(timeout: 5))
        extraModel.tap()
        let search = catalogSearch(in: app)
        search.tap()
        search.typeText("HD800S oratory1990")
        let model = app.buttons["eq.calibration.preset." + modelID]
        XCTAssertTrue(model.waitForExistence(timeout: 5))
        model.tap()
        XCTAssertTrue(model.isSelected)
        let done = app.buttons["eq.calibration.library.done"]
        if !done.isHittable { app.toolbars.buttons["关闭"].tap() }
        done.tap()
        let headphones = app.buttons["eq.headphones." + modelID]
        XCTAssertTrue(headphones.waitForExistence(timeout: 5))
        reveal(manual)
        XCTAssertGreaterThan(headphones.frame.minY, manual.frame.minY + 10)
        XCTAssertEqual(scroll.scrollViews.count, 0)
        manual.tap()
        XCTAssertTrue(manual.isSelected)
        headphones.tap()
        XCTAssertTrue(headphones.isSelected)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "headphone-preset-row"
        attachment.lifetime = .keepAlways
        self.add(attachment)
        app.terminate()
        app.launchEnvironment["PRIMUSE_EQ_TEST_RELAUNCH"] = "1"
        app.launch()
        XCTAssertTrue(scroll.waitForExistence(timeout: 15))
        reveal(manual)
        XCTAssertTrue(headphones.exists)
        manual.tap()
        XCTAssertTrue(manual.isSelected)
    }

    @MainActor func testUnknownUSBOutputInMinimalNavigation() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["PRIMUSE_EQ_TEST_USB_OUTPUT"] = "DTC480"
        app.launchArguments += ["-eq.enabled", "YES", "-eq.promptsOnHeadphoneChange", "YES", "-eq.presetId", "jazz",
                                "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
                                "-primuse.navigation.mode.v1", "minimal", "-primuse.hasSeenOnboarding", "YES",
                                "-primuse.iCloudSyncEnabled", "NO",
                                "-primuse.launch.consecutiveAborts", "0", "-primuse.launch.safeModeLatched", "NO"]
        app.launch()
        defer { app.terminate() }
        let choose = app.buttons["eq.calibration.change"]
        XCTAssertTrue(choose.waitForExistence(timeout: 12))
        XCTAssertTrue(app.staticTexts["DTC480"].exists)
        choose.tap()
        let search = catalogSearch(in: app)
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        let firstModel = app.buttons["eq.calibration.preset.autoeq.catalog.1b0c739262215bd30fc03d71"]
        XCTAssertTrue(firstModel.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("HD800S oratory1990")
        XCTAssertTrue(app.buttons["eq.calibration.preset.autoeq.catalog.1b67e5d54423f50cae480b56"].waitForExistence(timeout: 5))
        let done = app.buttons["eq.calibration.library.done"]
        if !done.isHittable { app.buttons["关闭"].tap() }
        XCTAssertTrue(done.isHittable)
        done.tap()
        XCTAssertTrue(search.waitForNonExistence(timeout: 3))
        XCTAssertTrue(choose.waitForNonExistence(timeout: 10))
        let cancelSearch = app.buttons["minimal.search.cancel"]
        if cancelSearch.exists { cancelSearch.tap() }
        let homeSearch = app.buttons["minimal.search"]
        XCTAssertTrue(homeSearch.waitForExistence(timeout: 10))
        homeSearch.tap()
        XCTAssertTrue(app.textFields["minimal.search.field"].waitForExistence(timeout: 3))
        cancelSearch.tap()
        XCTAssertTrue(homeSearch.waitForExistence(timeout: 5))
    }

    @MainActor func testMinimalNavigationWithEQOffSkipsCalibrationAfterRelaunch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["PRIMUSE_EQ_TEST_USB_OUTPUT"] = "DTC480"
        app.launchArguments += ["-eq.enabled", "NO", "-eq.promptsOnHeadphoneChange", "YES", "-primuse.navigation.mode.v1", "minimal",
                                "-primuse.hasSeenOnboarding", "YES", "-primuse.iCloudSyncEnabled", "NO",
                                "-primuse.launch.consecutiveAborts", "0", "-primuse.launch.safeModeLatched", "NO"]
        defer { app.terminate() }
        for _ in 0..<2 {
            app.launch()
            XCTAssertTrue(app.buttons["minimal.search"].waitForExistence(timeout: 12))
            XCTAssertFalse(app.buttons["eq.calibration.change"].exists)
            XCTAssertFalse(app.buttons["eq.calibration.confirm"].exists)
            app.terminate()
        }
    }

    @MainActor func testDecliningCalibrationInPickerSilencesReconnectAndRelaunch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["PRIMUSE_EQ_UI_TESTS"] = "1"
        app.launchArguments += ["-eq.promptsOnHeadphoneChange", "YES"]
        app.launch()
        defer { app.terminate() }
        let dac = app.buttons["eq.test.dac"]
        XCTAssertTrue(dac.waitForExistence(timeout: 15))
        dac.tap()
        let choose = app.buttons["eq.calibration.change"]
        choose.tap()
        app.buttons["eq.calibration.none"].tap()
        XCTAssertTrue(choose.waitForNonExistence(timeout: 3))
        app.buttons["eq.test.disconnect"].tap()
        dac.tap()
        XCTAssertFalse(choose.exists)
        XCTAssertFalse(app.buttons["eq.calibration.confirm"].exists)
        app.buttons["eq.test.disconnect"].tap()
        app.terminate()
        app.launchEnvironment["PRIMUSE_EQ_TEST_RELAUNCH"] = "1"
        app.launch()
        XCTAssertTrue(dac.waitForExistence(timeout: 15))
        dac.tap()
        XCTAssertFalse(choose.exists)
        XCTAssertFalse(app.buttons["eq.calibration.confirm"].exists)
        app.buttons["eq.test.disconnect"].tap()
    }

    @MainActor func testConfirmationAtAccessibilityTextSize() {
        let app = XCUIApplication()
        app.launchEnvironment["PRIMUSE_EQ_UI_TESTS"] = "1"
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
                                "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        defer { app.terminate() }
        let sony = app.buttons["eq.test.connect"]
        XCTAssertTrue(sony.waitForExistence(timeout: 30))
        let toggle = app.switches["eq.calibration.promptOnChange"]
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.tap()
        sony.tap()
        let confirm = app.buttons["eq.calibration.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        let change = app.buttons["eq.calibration.change"]
        XCTAssertTrue(change.isHittable && confirm.isHittable)
        let banner = XCTAttachment(screenshot: app.screenshot())
        banner.name = "accessibility-calibration-prompt"
        banner.lifetime = .keepAlways
        add(banner)
        confirm.tap()
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 3))
        app.buttons["eq.test.disconnect"].tap()
        XCTAssertTrue(change.waitForExistence(timeout: 3))
    }

    @MainActor func testFullCatalogSearchSelectionAndDeviceRecall() throws {
        let app = XCUIApplication()
        app.launchEnvironment["PRIMUSE_EQ_UI_TESTS"] = "1"
        app.launchArguments += ["-eq.promptsOnHeadphoneChange", "YES", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        defer { app.terminate() }
        let dac = app.buttons["eq.test.dac"]
        XCTAssertTrue(dac.waitForExistence(timeout: 30))
        dac.tap()
        app.buttons["eq.calibration.change"].tap()
        let search = catalogSearch(in: app)
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap(); search.typeText("HD800S oratory1990")
        let profile = app.buttons["eq.calibration.preset.autoeq.catalog.1b67e5d54423f50cae480b56"]
        XCTAssertTrue(profile.waitForExistence(timeout: 5))
        let catalog = XCTAttachment(screenshot: app.screenshot())
        catalog.name = "complete-catalog-search"
        catalog.lifetime = .keepAlways
        add(catalog)
        profile.tap()
        XCTAssertTrue(app.staticTexts["Sennheiser HD 800 S"].firstMatch.waitForExistence(timeout: 3))
        app.buttons["eq.test.disconnect"].tap()
        dac.tap()
        XCTAssertTrue(app.buttons["eq.calibration.confirm"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Sennheiser HD 800 S"].firstMatch.exists)
        app.buttons["eq.calibration.confirm"].tap()
        app.buttons["eq.test.disconnect"].tap()
    }

    @MainActor func testAutomaticAcceptanceAndDACImport() throws {
        let app = XCUIApplication()
        app.launchEnvironment["PRIMUSE_EQ_UI_TESTS"] = "1"
        app.launchArguments += ["-eq.promptsOnHeadphoneChange", "YES", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        defer { app.terminate() }
        let connect = app.buttons["eq.test.connect"]
        XCTAssertTrue(connect.waitForExistence(timeout: 30))
        connect.tap()
        let confirm = app.buttons["eq.calibration.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        let prompt = XCTAttachment(screenshot: app.screenshot())
        prompt.name = "automatic-calibration-prompt"
        prompt.lifetime = .keepAlways
        add(prompt)
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 9))
        XCTAssertTrue(app.staticTexts["Sony WH-1000XM5"].firstMatch.exists)
        app.buttons["eq.test.disconnect"].tap()
        app.buttons["eq.test.dac"].tap()
        app.buttons["eq.calibration.change"].tap()
        XCTAssertTrue(app.navigationBars["耳机与音响"].waitForExistence(timeout: 3))
        app.buttons["导入均衡器"].tap()
        app.buttons["粘贴文本"].tap()
        let name = app.textFields["预设名称"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        let form = XCTAttachment(screenshot: app.screenshot())
        form.name = "calibration-import-form"
        form.lifetime = .keepAlways
        add(form)
        name.tap(); name.typeText("Living room")
        let text = app.textViews["Equalizer APO 参数"]
        text.tap(); text.typeText("Preamp: -6 dB\nFilter 1: ON PK Fc 3500 Hz Gain -4 dB Q 2.5")
        app.buttons["应用"].tap()
        XCTAssertTrue(app.staticTexts["Living room"].firstMatch.waitForExistence(timeout: 3))
        app.buttons["eq.calibration.library"].tap()
        let search = catalogSearch(in: app)
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.tap(); search.typeText("EA500LM")
        let row = app.buttons["eq.calibration.preset.autoeq.simgot.audio.ea500lm.black.nozzle"]
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        let catalog = XCTAttachment(screenshot: app.screenshot())
        catalog.name = "ea500lm-catalog"
        catalog.lifetime = .keepAlways
        add(catalog)
        let alternatives = app.buttons["eq.calibration.sources.autoeq.simgot.audio.ea500lm.black.nozzle"]
        XCTAssertTrue(alternatives.exists)
        let harpo = app.buttons["eq.calibration.preset.autoeq.catalog.4797500ba88ba49ebecfa26c"]
        XCTAssertFalse(harpo.exists)
        alternatives.tap()
        XCTAssertTrue(harpo.waitForExistence(timeout: 3))
        harpo.tap()
        XCTAssertTrue(app.staticTexts["Simgot Audio EA500LM (black nozzle)"].firstMatch.waitForExistence(timeout: 3))
        app.buttons["eq.test.disconnect"].tap()
        XCTAssertFalse(app.buttons["eq.calibration.confirm"].exists)
        app.buttons["eq.test.dac"].tap()
        app.buttons["eq.calibration.change"].tap()
        let reopenedSearch = catalogSearch(in: app)
        reopenedSearch.tap(); reopenedSearch.typeText("EA500LM black")
        XCTAssertTrue(harpo.waitForExistence(timeout: 3))
        XCTAssertFalse(row.exists)
        harpo.tap()
        app.buttons["eq.test.disconnect"].tap()
    }
}
