import XCTest

@MainActor
final class HomeTopSwitchingUITests: XCTestCase {
    func testUnderline() { verifyStyle("underline") }
    func testSegmented() { verifyStyle("segmented") }
    func testIcons() { verifyStyle("icons") }
    func testKinetic() { verifyStyle("kinetic") }
    func testTuner() { verifyStyle("tuner") }
    func testSleeves() { verifyStyle("sleeves") }
    func testClassic() { verifyStyle("classic") }

    private func configuredApp() -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.welape.yuanyin")
        app.launchEnvironment["PRIMUSE_DIAGNOSTIC_LOGGING"] = "off"
        app.launchEnvironment["PRIMUSE_NO_NOTIFICATION_PROMPT"] = "1"
        app.launchArguments = [
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
            "-primuse.hasSeenOnboarding", "YES", "-primuse.iCloudSyncEnabled", "NO",
            "-primuse.notifyLongTasks", "NO", "-primuse.launch.consecutiveAborts", "0",
            "-primuse.launch.safeModeLatched", "NO"
        ]
        return app
    }

    func testIconsWithSavedTextOnlyPreference() {
        continueAfterFailure = false
        let app = configuredApp()
        app.launchArguments += [
            "-primuse.navigation.mode.v1", "standard", "-primuse.navigation.selectedTab.v1", "0",
            "-primuse.home.filter", "music", "-primuse.home.filterBar.v1",
            #"{"order":["music","radio","spokenWord","podcast"],"hidden":[],"labelStyle":"titleOnly","appearance":"icons"}"#
        ]
        defer { app.terminate() }
        app.launch()
        let music = app.buttons["home.spaceFilter.music"]
        XCTAssertTrue(music.waitForExistence(timeout: 30))
        XCTAssertGreaterThan(music.frame.height, 60, "The icon row must remain above its caption with a saved text-only preference")
        attach(app, "icons-saved-text-only")
    }

    func testSleevesInDarkAppearance() {
        continueAfterFailure = false
        let app = configuredApp()
        app.launchArguments += [
            "-primuse.navigation.mode.v1", "standard", "-primuse.navigation.selectedTab.v1", "0",
            "-primuse.appearance", "dark", "-primuse.home.filterBar.v1",
            #"{"order":["music","radio","spokenWord","podcast"],"hidden":[],"labelStyle":"titleOnly","appearance":"sleeves"}"#
        ]
        defer { app.terminate() }
        app.launch()
        let music = app.buttons["home.spaceFilter.music"]
        XCTAssertTrue(music.waitForExistence(timeout: 30))
        if !music.isSelected { music.tap() }
        attach(app, "sleeves-dark")
        app.buttons["home.spaceFilter.radio"].tap()
        XCTAssertTrue(app.buttons["home.spaceFilter.radio"].isSelected)
        attach(app, "sleeves-dark-radio")
    }

    private func verifyStyle(_ style: String) {
        continueAfterFailure = false
        let app = configuredApp()
        defer { app.terminate() }

        app.launchEnvironment["PRIMUSE_OPEN_SETTINGS"] = "home.order"
        app.launch()
        let editor = app.buttons["home.edit.filterBar"]
        XCTAssertTrue(editor.waitForExistence(timeout: 30))
        editor.tap()
        let appearance = app.buttons["home.filterBar.appearance"]
        XCTAssertTrue(appearance.waitForExistence(timeout: 5))
        appearance.tap()
        let choice = app.buttons["home.filterBar.style.\(style)"]
        for _ in 0..<8 where !choice.isHittable { app.swipeUp() }
        XCTAssertTrue(choice.isHittable)
        choice.tap()
        XCTAssertTrue(choice.isSelected)
        attach(app, "settings-\(style)")
        app.terminate()

        app.launchEnvironment.removeValue(forKey: "PRIMUSE_OPEN_SETTINGS")
        app.launch()
        let home = app.tabBars.buttons["首页"]
        XCTAssertTrue(home.waitForExistence(timeout: 10))
        home.tap()
        let music = app.buttons["home.spaceFilter.music"]
        XCTAssertTrue(music.waitForExistence(timeout: 30))
        let bar = app.descendants(matching: .any)["home.spaceFilter"].firstMatch
        XCTAssertEqual(bar.value as? String, style)
        if !music.isSelected { music.tap() }
        XCTAssertTrue(music.isSelected)
        attach(app, "home-\(style)")
        if style == "kinetic" {
            let title = app.navigationBars.staticTexts["首页"].firstMatch
            XCTAssertTrue(title.exists)
            XCTAssertLessThan(title.frame.minX, 50)
            XCTAssertGreaterThan(title.frame.height, 30)
        }
        let radio = app.buttons["home.spaceFilter.radio"]
        XCTAssertTrue(radio.isHittable)
        radio.tap()
        XCTAssertTrue(radio.isSelected)
        if style == "tuner" {
            let nextID = app.buttons["home.spaceFilter.spokenWord"].exists ? "spokenWord" : "podcast"
            let next = app.buttons["home.spaceFilter.\(nextID)"]
            let wallHeader = app.buttons["home.radioWall.streamInfo"]
            let y = wallHeader.exists ? wallHeader.frame.midY : min(bar.frame.maxY + 380, app.frame.height - 180)
            attach(app, "radio-before-swipe")
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let right = origin.withOffset(CGVector(dx: app.frame.width * 0.85, dy: y))
            let left = origin.withOffset(CGVector(dx: app.frame.width * 0.15, dy: y))
            right.press(forDuration: 0.05, thenDragTo: left)
            let selected = NSPredicate(format: "isSelected == true")
            expectation(for: selected, evaluatedWith: next)
            waitForExpectations(timeout: 5)
            attach(app, "swipe-forward")
            left.press(forDuration: 0.05, thenDragTo: right)
            expectation(for: selected, evaluatedWith: radio)
            waitForExpectations(timeout: 5)
            attach(app, "swipe-back")

            let rulerY = bar.frame.minY + 28
            let needle = origin.withOffset(CGVector(dx: radio.frame.midX, dy: rulerY))
            let nextMark = origin.withOffset(CGVector(dx: next.frame.midX, dy: rulerY))
            needle.press(forDuration: 0.05, thenDragTo: nextMark)
            expectation(for: selected, evaluatedWith: next)
            waitForExpectations(timeout: 5)
            attach(app, "tuner-drag")
            radio.tap()
            XCTAssertTrue(radio.isSelected)
        }
        radio.tap()
        XCTAssertFalse(radio.isSelected, "Tapping the selected category returns to the overview")
        app.terminate()
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        Thread.sleep(forTimeInterval: 0.8)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
