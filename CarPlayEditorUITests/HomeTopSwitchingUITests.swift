import XCTest

@MainActor
final class HomeTopSwitchingUITests: XCTestCase {
    func testRecommendationDetailPresentation() {
        continueAfterFailure = false
        let app = configuredApp()
        let baseArguments = app.launchArguments
        addTeardownBlock { @MainActor () async throws -> Void in
            self.continueAfterFailure = true
            app.terminate()
            app.launchArguments = baseArguments
            app.launch()
            let home = app.tabBars.buttons["首页"]
            if home.waitForExistence(timeout: 10) { home.tap() }
            XCTAssertTrue(app.buttons["home.spaceFilter.music"].waitForExistence(timeout: 15))
            app.terminate()
        }
        var regularTitleHeight: CGFloat = 0
        for appearance in ["light", "dark", "large-text"] {
            app.launchArguments = baseArguments + [
                "-primuse.navigation.mode.v1", "standard", "-primuse.navigation.selectedTab.v1", "0",
                "-primuse.home.showHero", "YES", "-primuse.home.filter", "music",
                "-primuse.home.heroStyle.v1", "featured", "-primuse.home.heroContent.v1", "songs",
                "-primuse.appearance", appearance == "dark" ? "dark" : "light"
            ]
            if appearance == "large-text" {
                app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityM"]
            }
            app.launch()
            let home = app.tabBars.buttons["首页"]
            XCTAssertTrue(home.waitForExistence(timeout: 15))
            home.tap()
            let theme = app.buttons["home.hero.recommendation.songs.catalogRewind"]
            XCTAssertTrue(theme.waitForExistence(timeout: 20))
            app.scrollViews["home.hero.featured.cards"].swipeLeft()
            theme.tap()
            let refresh = app.buttons["home.hero.recommendation.refresh"]
            let play = app.buttons["home.hero.recommendation.playAll"]
            let title = app.staticTexts["home.hero.recommendation.title"]
            XCTAssertTrue(refresh.waitForExistence(timeout: 10))
            XCTAssertEqual(title.label, "年代回顾")
            XCTAssertFalse(app.buttons["home.edit.heroStyle"].exists)
            if appearance == "large-text" {
                XCTAssertGreaterThan(title.frame.height, regularTitleHeight)
                XCTAssertGreaterThan(refresh.frame.minY, play.frame.maxY)
            } else {
                XCTAssertEqual(refresh.frame.minY, play.frame.minY, accuracy: 2)
                XCTAssertGreaterThan(play.frame.width, app.frame.width * 0.35)
                if appearance == "light" { regularTitleHeight = title.frame.height }
                let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "home.hero.recommendation.song."))
                XCTAssertGreaterThan(rows.count, 0)
                XCTAssertLessThan(rows.firstMatch.frame.minY, app.frame.height * 0.45)
                if appearance == "light" {
                    let firstID = rows.firstMatch.identifier
                    refresh.tap()
                    let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                        rows.count > 0 && rows.firstMatch.identifier != firstID && refresh.isEnabled
                    }, object: nil)
                    XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 15), .completed)
                }
            }
            attach(app, "recommendation-detail-\(appearance)")
            let detail = app.scrollViews["home.hero.recommendation.detail"]
            for _ in 0..<7 { detail.swipeUp() }
            attach(app, "recommendation-detail-\(appearance)-bottom")
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(app.scrollViews["home.hero.featured.cards"].waitForExistence(timeout: 5))
            app.terminate()
        }
    }

    func testFeaturedHeroSwitchPersistsAndScrolls() {
        continueAfterFailure = false
        let app = configuredApp()
        addTeardownBlock { @MainActor () async throws -> Void in app.terminate() }
        app.launchArguments += [
            "-primuse.navigation.mode.v1", "standard",
            "-primuse.home.showHero", "YES", "-primuse.home.filter", "music",
            "-primuse.launch.backgroundLaunchRepairDone", "NO"
        ]
        app.launchEnvironment["PRIMUSE_OPEN_SETTINGS"] = "home.order"
        app.launch()
        let settings = app.buttons["home.edit.heroStyle"]
        XCTAssertTrue(settings.waitForExistence(timeout: 20))
        settings.tap()
        let large = app.buttons["home.hero.style.featured"]
        XCTAssertTrue(large.waitForExistence(timeout: 5))
        let originalStyle = ["featured", "carousel", "medium"].first { app.buttons["home.hero.style.\($0)"].isSelected } ?? "carousel"
        large.tap()
        let originalContent = ["albums", "songs"].first { app.buttons["home.hero.content.\($0)"].isSelected } ?? "albums"
        addTeardownBlock { @MainActor () async throws -> Void in
            self.continueAfterFailure = true
            app.terminate()
            app.launchEnvironment["PRIMUSE_OPEN_SETTINGS"] = "home.order"
            app.launch()
            if settings.waitForExistence(timeout: 20) {
                settings.tap()
                if large.waitForExistence(timeout: 5) {
                    large.tap()
                    app.buttons["home.hero.content.\(originalContent)"].tap()
                    app.buttons["home.hero.style.\(originalStyle)"].tap()
                    app.buttons["home.hero.settings.done"].tap()
                }
            }
            app.terminate()
            app.launchEnvironment.removeValue(forKey: "PRIMUSE_OPEN_SETTINGS")
            app.launch()
            let home = app.tabBars.buttons["首页"]
            if home.waitForExistence(timeout: 15) { home.tap() }
            XCTAssertTrue(app.buttons["home.spaceFilter.music"].waitForExistence(timeout: 15))
            XCTAssertFalse(app.buttons["home.edit.heroStyle"].exists)
            app.terminate()
        }
        app.buttons["home.hero.content.songs"].tap()
        attach(app, "hero-settings-large-songs")
        app.buttons["home.hero.settings.done"].tap()
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "PRIMUSE_OPEN_SETTINGS")
        app.launch()
        let home = app.tabBars.buttons["首页"]
        XCTAssertTrue(home.waitForExistence(timeout: 15))
        home.tap()
        let collection = app.buttons["home.hero.recommendation.songs.daily"]
        XCTAssertTrue(collection.waitForExistence(timeout: 20))
        XCTAssertFalse(settings.exists, "Home must not expose layout settings")
        let cards = app.scrollViews["home.hero.featured.cards"]
        let rewind = app.buttons["home.hero.recommendation.songs.catalogRewind"]
        XCTAssertTrue(rewind.waitForExistence(timeout: 10))
        XCTAssertLessThan(rewind.frame.minX, app.frame.maxX - 20, "The next themed card must be visible on the right")
        attach(app, "hero-daily-large")
        cards.swipeLeft()
        XCTAssertTrue(rewind.isHittable)
        attach(app, "hero-rewind-large")
        rewind.tap()
        XCTAssertTrue(app.buttons["home.hero.recommendation.refresh"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["home.hero.recommendation.title"].label, "年代回顾")
        XCTAssertFalse(settings.exists, "Recommendation details must not expose layout settings")
        let themeSongs = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "home.hero.recommendation.song."))
        XCTAssertGreaterThan(themeSongs.count, 0)
        attach(app, "hero-rewind-detail")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(cards.waitForExistence(timeout: 5))
        cards.swipeLeft()
        let recent = app.buttons["home.hero.recommendation.songs.recentCatalog"]
        XCTAssertTrue(recent.waitForExistence(timeout: 5))
        XCTAssertTrue(recent.isHittable)
        attach(app, "hero-recent-large")
        recent.tap()
        XCTAssertTrue(app.buttons["home.hero.recommendation.refresh"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["home.hero.recommendation.title"].label, "近年作品")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        cards.swipeRight()
        cards.swipeRight()
        XCTAssertTrue(collection.isHittable)
        collection.tap()
        let refresh = app.buttons["home.hero.recommendation.refresh"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 5))
        XCTAssertTrue(refresh.isEnabled)
        let songs = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "home.hero.recommendation.song."))
        XCTAssertGreaterThan(songs.count, 0)
        let firstSongID = songs.element(boundBy: 0).identifier
        refresh.tap()
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            songs.count > 0 && songs.element(boundBy: 0).identifier != firstSongID && refresh.isEnabled
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 15), .completed, "Refreshing the visible detail must replace the songs")
        attach(app, "hero-daily-detail")
        XCTAssertFalse(settings.exists)
        app.terminate()
        app.launchEnvironment["PRIMUSE_OPEN_SETTINGS"] = "home.order"
        app.launch()
        XCTAssertTrue(settings.waitForExistence(timeout: 20))
        settings.tap()
        app.buttons["home.hero.style.medium"].tap()
        app.buttons["home.hero.content.albums"].tap()
        attach(app, "hero-settings-medium-albums")
        app.buttons["home.hero.settings.done"].tap()
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "PRIMUSE_OPEN_SETTINGS")
        app.launch()
        XCTAssertTrue(home.waitForExistence(timeout: 15))
        home.tap()
        XCTAssertTrue(cards.waitForExistence(timeout: 20))
        XCTAssertFalse(settings.exists)
        attach(app, "hero-daily-medium-albums")
        let albumCard = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "home.hero.recommendation.album.")).firstMatch
        albumCard.tap()
        let album = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "home.hero.recommendation.albumDetail.")).firstMatch
        XCTAssertTrue(album.waitForExistence(timeout: 10))
        XCTAssertFalse(settings.exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        cards.swipeLeft()
        attach(app, "hero-daily-medium-scrolled")
        app.terminate()
        app.launchEnvironment["PRIMUSE_OPEN_SETTINGS"] = "home.order"
        app.launch()
        XCTAssertTrue(settings.waitForExistence(timeout: 20))
        settings.tap()
        app.buttons["home.hero.style.carousel"].tap()
        app.buttons["home.hero.settings.done"].tap()
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "PRIMUSE_OPEN_SETTINGS")
        app.launch()
        XCTAssertTrue(home.waitForExistence(timeout: 15))
        home.tap()
        XCTAssertTrue(app.buttons["home.spaceFilter.music"].waitForExistence(timeout: 15))
        XCTAssertFalse(settings.exists, "The carousel must not expose layout settings either")
        XCTAssertFalse(cards.exists)
        attach(app, "hero-carousel")
    }

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
