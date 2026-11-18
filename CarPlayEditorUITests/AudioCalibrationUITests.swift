import XCTest

final class AudioCalibrationUITests: XCTestCase {
    @MainActor func testConfirmationAtAccessibilityTextSize() {
        let app = XCUIApplication()
        app.launchEnvironment["PRIMUSE_EQ_UI_TESTS"] = "1"
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
                                "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        defer { app.terminate() }
        let sony = app.buttons["eq.test.connect"]
        XCTAssertTrue(sony.waitForExistence(timeout: 30))
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
    }

    @MainActor func testFullCatalogSearchSelectionAndDeviceRecall() throws {
        let app = XCUIApplication()
        app.launchEnvironment["PRIMUSE_EQ_UI_TESTS"] = "1"
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        defer { app.terminate() }
        let dac = app.buttons["eq.test.dac"]
        XCTAssertTrue(dac.waitForExistence(timeout: 30))
        dac.tap()
        app.buttons["eq.calibration.change"].tap()
        let search = app.searchFields.firstMatch
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
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
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
        let search = app.searchFields.firstMatch
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
        let reopenedSearch = app.searchFields.firstMatch
        reopenedSearch.tap(); reopenedSearch.typeText("EA500LM black")
        XCTAssertTrue(harpo.waitForExistence(timeout: 3))
        XCTAssertFalse(row.exists)
        harpo.tap()
        app.buttons["eq.test.disconnect"].tap()
    }
}
