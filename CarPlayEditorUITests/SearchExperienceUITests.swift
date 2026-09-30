import XCTest

@MainActor
final class SearchExperienceUITests: XCTestCase {
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
