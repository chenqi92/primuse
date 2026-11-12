import Vision
import XCTest

@MainActor
final class LibraryLaunchPerformanceUITests: XCTestCase {
    func testInstalledLibraryShowsPlaybackAndSpaceControlsDuringLaunch() throws {
        guard ProcessInfo.processInfo.environment["PRIMUSE_INSTALLED_LIBRARY_AUDIT"] == "1" else {
            throw XCTSkip("Requires a selected device with an existing library")
        }
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.welape.yuanyin")
        app.launchEnvironment["PRIMUSE_DIAGNOSTIC_LOGGING"] = "off"
        app.launchEnvironment["PRIMUSE_NO_NOTIFICATION_PROMPT"] = "1"
        app.launchEnvironment["PRIMUSE_OPEN_PAGE"] = "home"
        app.launchArguments = [
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
            "-primuse.navigation.mode.v1", "standard", "-primuse.navigation.selectedTab.v1", "0",
            "-primuse.navigation.sidebarItem.v1", "home", "-primuse.home.filter", "music"
        ]
        addTeardownBlock { @MainActor in app.terminate() }
        let started = ProcessInfo.processInfo.systemUptime
        app.launch()
        let play = app.buttons.matching(NSPredicate(
            format: "identifier == %@ OR label == %@", "library.startup.playAll", "全部播放"
        )).firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        let playAt = ProcessInfo.processInfo.systemUptime - started
        let books = app.buttons["home.spaceFilter.spokenWord"]
        XCTAssertTrue(books.waitForExistence(timeout: 5))
        print(String(format: "LOAD_MATRIX launch-controls play=%.3fs books=%.3fs", playAt,
                     ProcessInfo.processInfo.systemUptime - started))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "large-library-launch-controls"
        attachment.lifetime = .keepAlways
        add(attachment)
        let radio = app.buttons["home.spaceFilter.radio"]
        XCTAssertTrue(radio.exists)
        radio.tap()
        XCTAssertTrue(app.descendants(matching: .any)["home.page.radio"].firstMatch.waitForExistence(timeout: 5))
    }
}

@MainActor
final class HomeTopSwitchingUITests: XCTestCase {
    func testMusicSectionSwipesFollowVisibleTabsInBothDirections() {
        verifyMusicSectionSwipes(mode: "minimal", tabPrefix: "minimal.section")
    }

    func testStandardLibrarySectionTabsFollowPageSwipes() {
        verifyMusicSectionSwipes(mode: "standard", tabPrefix: "library.sectionTab")
    }

    func testMinimalPagingCanBeDisabledWithoutDisablingTabButtons() {
        continueAfterFailure = false
        let app = configuredHomeRegressionApp()
        restoreHomeAfterTest(app, arguments: app.launchArguments)
        app.launchArguments += [
            "-primuse.navigation.mode.v1", "minimal", "-primuse.navigation.selectedTab.v1", "1",
            "-primuse.library.sectionSwipe.v1", "NO", "-primuse.minimal.librarySection.v1", "favorites",
            "-primuse.library.hiddenSections.v1",
            stringDefaultArgument(#"["songs","artists","albums","folders","releaseDate","statistics","recommendations"]"#)
        ]
        app.launch()
        let favorites = app.buttons["minimal.section.favorites"]
        let genres = app.buttons["minimal.section.genres"]
        XCTAssertTrue(favorites.waitForExistence(timeout: 45))
        favorites.tap()
        assertSelected(favorites)
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.65))
        start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.65)))
        XCTAssertTrue(favorites.isSelected)
        genres.tap()
        assertSelected(genres)
    }

    func testStandardSongRowsKeepQueueSwipesAndVerticalScrolling() throws {
        try verifyInstalledSongRowGestures(mode: "standard", tabPrefix: "library.sectionTab")
    }

    func testMinimalSongRowsKeepQueueSwipesAndVerticalScrolling() throws {
        try verifyInstalledSongRowGestures(mode: "minimal", tabPrefix: "minimal.section")
    }

    private func verifyInstalledSongRowGestures(mode: String, tabPrefix: String) throws {
        continueAfterFailure = false
        let app = configuredHomeRegressionApp()
        restoreHomeAfterTest(app, arguments: app.launchArguments)
        app.launchArguments += [
            "-primuse.navigation.mode.v1", mode, "-primuse.navigation.selectedTab.v1", "1",
            "-primuse.navigation.libraryPage.v1", "section:songs", "-primuse.minimal.librarySection.v1", "songs",
            "-primuse.home.showsLibrarySections.v1", "YES", "-primuse.library.sectionSwipe.v1", "YES",
            "-primuse.library.hiddenSections.v1", stringDefaultArgument("[]"),
            "-songListAppearance", "list", "-library.songBrowseMode", "flat", "-library.songFilter.v1", "all"
        ]
        app.launch()
        let songs = app.buttons["\(tabPrefix).songs"]
        XCTAssertTrue(songs.waitForExistence(timeout: 60))
        songs.tap()
        assertSelected(songs)
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "songRow."))
        let preview = app.descendants(matching: .any)["library.startup.songs"].firstMatch
        if preview.waitForExistence(timeout: 5) {
            XCTAssertTrue(preview.waitForNonExistence(timeout: 180), "The installed library must finish loading before testing row actions")
        }
        try XCTSkipUnless(rows.firstMatch.waitForExistence(timeout: 30), "Requires an installed music library with song rows")
        let screen = app.frame
        var visibleRows: [XCUIElement] = []
        for index in 0..<min(18, rows.count) {
            let row = rows.element(boundBy: index)
            let frame = row.frame
            if frame.width > screen.width / 2, frame.minY > screen.height * 0.24,
               frame.maxY < screen.height * 0.79, row.isHittable {
                visibleRows.append(rows.matching(identifier: row.identifier).firstMatch)
                if visibleRows.count == 2 { break }
            }
        }
        try XCTSkipUnless(visibleRows.count == 2, "Requires two visible playable song rows")
        let more = app.buttons["songList.more"]
        if more.isHittable {
            more.tap()
        } else {
            visibleRows[1].press(forDuration: 1)
        }
        let select = app.buttons["选择"].firstMatch
        XCTAssertTrue(select.waitForExistence(timeout: 5))
        select.tap()
        let cancel = app.buttons["batchSelection.cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        let right = app.coordinate(withNormalizedOffset: CGVector(dx: 0.78, dy: 0.57))
        right.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.22, dy: 0.57)))
        XCTAssertTrue(cancel.isHittable, "A swipe while selecting songs must keep selection mode active")
        cancel.tap()
        assertSelected(songs)
        for (row, distance, title) in [(visibleRows[0], CGFloat(105), "下一首播放"), (visibleRows[1], CGFloat(-105), "加入播放队列")] {
            let frame = row.frame
            let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: screen.midX, dy: frame.midY))
            start.press(forDuration: 0.04, thenDragTo: start.withOffset(CGVector(dx: distance, dy: 0)), withVelocity: .slow, thenHoldForDuration: 0)
            XCTAssertTrue(songs.isSelected, "Swiping a song must keep the current category")
            let actionWidth = min(115, frame.width)
            let actionFrame = CGRect(x: distance > 0 ? frame.minX : frame.maxX - actionWidth,
                                     y: frame.minY, width: actionWidth, height: frame.height)
            try assertRevealedAction(title, in: actionFrame, app: app)
        }
        let anchor = visibleRows[1]
        let oldY = anchor.frame.midY
        let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: screen.midX, dy: oldY))
        start.press(forDuration: 0.04, thenDragTo: start.withOffset(CGVector(dx: 8, dy: -145)))
        XCTAssertTrue(songs.isSelected)
        XCTAssertTrue(!anchor.exists || !anchor.isHittable || anchor.frame.midY < oldY - 25, "A vertical drag from a song must scroll the list")
    }

    private func assertRevealedAction(_ title: String, in frame: CGRect, app: XCUIApplication) throws {
        if app.buttons[title].firstMatch.isHittable { return }
        // The song row can combine its accessibility children, hiding the rendered action from XCTest.
        let shot = try XCTUnwrap(app.screenshot().image.cgImage)
        let scale = CGFloat(shot.width) / app.frame.width
        let crop = try XCTUnwrap(shot.cropping(to: frame.applying(.init(scaleX: scale, y: scale))))
        let proof = XCTAttachment(image: UIImage(cgImage: crop))
        proof.name = title
        add(proof)
        let request = VNRecognizeTextRequest()
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        try VNImageRequestHandler(cgImage: crop).perform([request])
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            .joined().replacingOccurrences(of: " ", with: "")
        XCTAssertTrue(text.contains(title), "The row did not reveal \(title)")
    }

    private func verifyMusicSectionSwipes(mode: String, tabPrefix: String) {
        continueAfterFailure = false
        let app = configuredHomeRegressionApp()
        restoreHomeAfterTest(app, arguments: app.launchArguments)
        addTeardownBlock { @MainActor in
            if self.testRun?.hasSucceeded == false {
                self.attach(app, "library-section-swipe-\(mode)")
            }
        }
        app.launchArguments += [
            "-primuse.navigation.mode.v1", mode, "-primuse.navigation.selectedTab.v1", "1",
            "-primuse.minimal.librarySection.v1", "favorites",
            "-primuse.navigation.libraryPage.v1", "section:favorites",
            "-primuse.home.showsLibrarySections.v1", "YES",
            "-primuse.library.sectionSwipe.v1", "YES",
            "-primuse.library.sectionOrder.v1", "",
            "-primuse.library.hiddenSections.v1",
            stringDefaultArgument(#"["songs","artists","albums","folders","releaseDate","statistics","recommendations"]"#)
        ]
        app.launch()
        let favorites = app.buttons["\(tabPrefix).favorites"]
        let genres = app.buttons["\(tabPrefix).genres"]
        XCTAssertTrue(favorites.waitForExistence(timeout: 30))
        favorites.tap()
        assertSelected(favorites)
        let left = app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.65))
        let right = app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.65))
        let trailing = app.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.65))
            .withOffset(CGVector(dx: -36, dy: 0))
        trailing.press(forDuration: 0.05, thenDragTo: left)
        XCTAssertTrue(favorites.isSelected, "A drag starting in the alphabet index area must keep the current page")
        right.press(forDuration: 0.05, thenDragTo: left)
        assertSelected(genres)
        left.press(forDuration: 0.05, thenDragTo: right)
        assertSelected(favorites)
        left.press(forDuration: 0.05, thenDragTo: right)
        XCTAssertTrue(favorites.isSelected)
        if mode == "standard" {
            let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.65))
            edge.press(forDuration: 0.05, thenDragTo: right)
            XCTAssertTrue(app.descendants(matching: .any)["library.hub"].firstMatch.waitForExistence(timeout: 5))
        }
    }

    func testCircularPagingAndInterruptedSwipesStayCentered() {
        continueAfterFailure = false
        let app = configuredHomeRegressionApp()
        let baseArguments = app.launchArguments
        app.launchArguments += [
            "-primuse.navigation.mode.v1", "standard", "-primuse.navigation.selectedTab.v1", "0",
            "-primuse.navigation.sidebarItem.v1", "home",
            "-primuse.home.filterBar.v1",
            stringDefaultArgument(#"{"order":["radio","podcast","music","spokenWord"],"hidden":["podcast","spokenWord"],"appearance":"segmented"}"#)
        ]
        restoreHomeAfterTest(app, arguments: baseArguments)
        app.launch()

        let radio = app.buttons["home.spaceFilter.radio"]
        let music = app.buttons["home.spaceFilter.music"]
        XCTAssertTrue(radio.waitForExistence(timeout: 30))
        if !radio.isSelected { radio.tap() }
        XCTAssertTrue(radio.isSelected)
        XCTAssertFalse(app.buttons["home.spaceFilter.podcast"].exists)
        XCTAssertFalse(app.buttons["home.spaceFilter.spokenWord"].exists)
        let radioPage = homePage(app, "radio")
        XCTAssertTrue(radioPage.waitForExistence(timeout: 5))
        let expectedMidX = radioPage.frame.midX

        // The custom order starts at radio and ends at music; hidden categories must be skipped.
        swipeHomePage(app, forward: false)
        assertSelected(music)
        assertPageCentered(homePage(app, "music"), midX: expectedMidX)
        swipeHomePage(app, forward: true)
        assertSelected(radio)
        assertPageCentered(radioPage, midX: expectedMidX)

        let y = homeSwipeY(app)
        let contentFrame = homeContentFrame(app)
        let start = homeCoordinate(app, x: contentFrame.minX + contentFrame.width * 0.45, y: y)
        let shortEnd = start.withOffset(CGVector(dx: 35, dy: 0))
        start.press(forDuration: 0.05, thenDragTo: shortEnd, withVelocity: .slow, thenHoldForDuration: 0.1)
        assertSelected(radio)
        assertPageCentered(radioPage, midX: expectedMidX)

        for _ in 0..<6 {
            music.tap()
            radio.tap()
        }
        assertSelected(radio)
        assertPageCentered(radioPage, midX: expectedMidX)
        radio.tap()
        for _ in 0..<3 {
            music.doubleTap()
            radio.doubleTap()
        }
        XCTAssertFalse(music.isSelected)
        // A double-tap gesture may deliver one button activation. In either case
        // the selected filter and the visible page must agree after the burst.
        let overview = homePage(app, "overview")
        if radio.isSelected {
            assertPageCentered(radioPage, midX: expectedMidX)
            radio.tap()
        }
        assertPageCentered(overview, midX: expectedMidX)

        music.tap()
        assertSelected(music)
        music.tap()
        XCTAssertFalse(music.isSelected)
        assertPageCentered(overview, midX: expectedMidX)
        radio.tap()
        assertSelected(radio)
        assertPageCentered(radioPage, midX: expectedMidX)
        attach(app, "home-rapid-switching-centered")

        swipeHomePage(app, forward: false)
        assertSelected(music)
        assertPageCentered(homePage(app, "music"), midX: expectedMidX)
        music.tap()
        XCTAssertFalse(music.isSelected)
        XCTAssertTrue(homePage(app, "overview").waitForExistence(timeout: 5))
    }

    func testPullHoldReturnsToOverviewWithoutShortPullExit() {
        continueAfterFailure = false
        let app = configuredHomeRegressionApp()
        let baseArguments = app.launchArguments
        app.launchArguments += [
            "-primuse.navigation.mode.v1", "standard", "-primuse.navigation.selectedTab.v1", "0",
            "-primuse.navigation.sidebarItem.v1", "home",
            "-primuse.home.filterBar.v1",
            stringDefaultArgument(#"{"order":["music","radio","spokenWord","podcast"],"hidden":[],"appearance":"segmented"}"#),
            "-primuse.home.subtabs.pullDown.v1", "NO"
        ]
        restoreHomeAfterTest(app, arguments: baseArguments)
        app.launch()
        let radio = app.buttons["home.spaceFilter.radio"]
        XCTAssertTrue(radio.waitForExistence(timeout: 30))
        if !radio.isSelected { radio.tap() }
        XCTAssertTrue(radio.isSelected)

        pullHomePage(app, holdDuration: 0.15)
        assertSelected(radio)
        XCTAssertFalse(homePage(app, "overview").exists)
        attach(app, "home-short-pull-keeps-category")

        pullHomePage(app, holdDuration: 1.5)
        let overview = homePage(app, "overview")
        XCTAssertTrue(overview.waitForExistence(timeout: 5))
        for space in ["music", "radio", "spokenWord", "podcast"] {
            let button = app.buttons["home.spaceFilter.\(space)"]
            if button.exists { XCTAssertFalse(button.isSelected) }
        }
        XCTAssertTrue(app.descendants(matching: .any)["home.returnOverview.progress"].firstMatch.waitForNonExistence(timeout: 5))
        attach(app, "home-long-pull-returns-overview")
        radio.tap()
        assertSelected(radio)
        XCTAssertTrue(homePage(app, "radio").waitForExistence(timeout: 5))
    }

    func testMonochromePreferencePersists() {
        continueAfterFailure = false
        let app = configuredHomeRegressionApp()
        let baseArguments = app.launchArguments
        restoreHomeAfterTest(app, arguments: baseArguments)
        app.launchArguments += [
            "-primuse.navigation.mode.v1", "standard"
        ]
        app.launchEnvironment["PRIMUSE_OPEN_SETTINGS"] = "home.order"
        app.launch()
        openFilterEditor(app)
        let monochrome = app.switches["home.filterBar.monochrome"]
        XCTAssertTrue(monochrome.waitForExistence(timeout: 5))
        let originalValue = monochrome.value as? String
        XCTAssertTrue(["0", "1"].contains(originalValue ?? ""))
        let persistedValue = originalValue == "1" ? "0" : "1"
        addTeardownBlock { @MainActor in
            self.continueAfterFailure = true
            app.terminate()
            app.launchArguments = baseArguments + [
                "-primuse.navigation.mode.v1", "standard"
            ]
            app.launchEnvironment["PRIMUSE_OPEN_SETTINGS"] = "home.order"
            app.launch()
            self.openFilterEditor(app)
            if monochrome.waitForExistence(timeout: 5), let originalValue {
                self.setSwitchValue(monochrome, to: originalValue)
            }
        }
        setSwitchValue(monochrome, to: persistedValue)
        app.terminate()
        app.launch()
        openFilterEditor(app)
        XCTAssertTrue(monochrome.waitForExistence(timeout: 5))
        XCTAssertEqual(monochrome.value as? String, persistedValue, "The changed setting must survive a fresh app process")
        attach(app, "home-monochrome-setting-persisted")
        setSwitchValue(monochrome, to: "1")

        app.terminate()
        app.launchEnvironment.removeValue(forKey: "PRIMUSE_OPEN_SETTINGS")
        for appearance in ["light", "dark"] {
            app.launchArguments = baseArguments + [
                "-primuse.navigation.mode.v1", "standard",
                "-primuse.appearance", appearance
            ]
            app.launch()
            openHome(app)
            attach(app, "home-monochrome-\(appearance)")
            app.terminate()
        }
    }

    func testHomeSubtabsVisibilityAndGestures() {
        continueAfterFailure = false
        let app = configuredApp()
        let base = app.launchArguments + [
            "-primuse.navigation.mode.v1", "standard", "-primuse.navigation.selectedTab.v1", "0",
            "-primuse.home.showsLibrarySections.v1", "YES"
        ]
        addTeardownBlock { @MainActor in
            app.terminate()
            app.launchArguments = base + [
                "-primuse.home.subtabs.pullDown.v1", "NO", "-primuse.home.subtabs.doubleTap.v1", "NO"
            ]
            app.launch()
            XCTAssertTrue(app.buttons["home.spaceFilter.music"].waitForExistence(timeout: 15))
            if !app.buttons["home.spaceFilter.music"].isSelected {
                app.buttons["home.spaceFilter.music"].tap()
            }
            app.terminate()
        }
        let categories = app.buttons["library.sectionTab.songs"]
        let music = app.buttons["home.spaceFilter.music"]
        let home = app.tabBars.buttons["首页"]

        app.launchArguments = base + [
            "-primuse.home.subtabs.pullDown.v1", "NO", "-primuse.home.subtabs.doubleTap.v1", "NO"
        ]
        app.launch()
        XCTAssertTrue(music.waitForExistence(timeout: 20))
        if !music.isSelected { music.tap() }
        XCTAssertTrue(categories.waitForExistence(timeout: 20))
        app.terminate()

        app.launchArguments = base + [
            "-primuse.home.subtabs.pullDown.v1", "YES", "-primuse.home.subtabs.doubleTap.v1", "NO"
        ]
        app.launch()
        XCTAssertTrue(music.waitForExistence(timeout: 20))
        if !music.isSelected { music.tap() }
        XCTAssertFalse(categories.exists)
        let start = music.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 70)))
        XCTAssertTrue(categories.waitForExistence(timeout: 5))
        attach(app, "home-subtabs-pull-down")
        let up = music.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        up.press(forDuration: 0.05, thenDragTo: up.withOffset(CGVector(dx: 0, dy: -45)))
        XCTAssertTrue(categories.waitForNonExistence(timeout: 5))
        home.doubleTap()
        XCTAssertFalse(categories.exists)
        app.terminate()

        app.launchArguments = base + [
            "-primuse.home.subtabs.pullDown.v1", "NO", "-primuse.home.subtabs.doubleTap.v1", "YES"
        ]
        app.launch()
        XCTAssertTrue(music.waitForExistence(timeout: 20))
        if !music.isSelected { music.tap() }
        XCTAssertFalse(categories.exists)
        home.tap()
        XCTAssertFalse(categories.exists)
        home.doubleTap()
        XCTAssertTrue(categories.waitForExistence(timeout: 5))
        app.buttons["home.spaceFilter.radio"].tap()
        XCTAssertTrue(app.buttons["home.spaceFilter.radio"].isSelected)
        let allRadio = app.buttons["home.radio.filter.all"]
        XCTAssertFalse(allRadio.exists)
        home.doubleTap()
        XCTAssertTrue(allRadio.waitForExistence(timeout: 5))
        attach(app, "home-subtabs-radio")
        home.doubleTap()
        XCTAssertTrue(allRadio.waitForNonExistence(timeout: 5))
        music.tap()
        XCTAssertTrue(categories.waitForExistence(timeout: 5))
    }

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

    private func configuredHomeRegressionApp() -> XCUIApplication {
        let app = configuredApp()
        // XCTest terminates processes before the eight-second launch sentinel settles.
        app.launchArguments += ["-primuse.launch.backgroundLaunchRepairDone", "NO"]
        return app
    }

    private func stringDefaultArgument(_ value: String) -> String {
        // NSArgumentDomain parses a property-list string, not a raw JSON object.
        String(decoding: try! JSONEncoder().encode(value), as: UTF8.self)
    }

    private func homePage(_ app: XCUIApplication, _ space: String) -> XCUIElement {
        app.descendants(matching: .any)["home.page.\(space)"].firstMatch
    }

    private func assertSelected(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let selected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isSelected == true"), object: element
        )
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed, file: file, line: line)
    }

    private func assertPageCentered(_ page: XCUIElement, midX: CGFloat, file: StaticString = #filePath, line: UInt = #line) {
        let centered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            page.exists && !page.frame.isEmpty && abs(page.frame.midX - midX) <= 2
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [centered], timeout: 5), .completed, "The active page must settle at its original horizontal position", file: file, line: line)
    }

    private func homeSwipeY(_ app: XCUIApplication) -> CGFloat {
        for identifier in ["home.radioWall.streamInfo", "home.allFavorites", "home.startListening.all", "home.recentAlbums.viewAll"] {
            let header = app.buttons[identifier]
            if header.exists, header.isHittable { return header.frame.midY }
        }
        for title in ["还没有电台", "欢迎使用 Primuse"] {
            let label = app.staticTexts[title]
            if label.exists, label.isHittable { return label.frame.midY }
        }
        let bar = app.descendants(matching: .any)["home.spaceFilter"].firstMatch
        return min(bar.frame.maxY + 380, app.frame.maxY - 180)
    }

    private func homeContentFrame(_ app: XCUIApplication) -> CGRect {
        let spaces = ["music", "radio", "spokenWord", "podcast"]
        let selected = spaces.first { space in
            let button = app.buttons["home.spaceFilter.\(space)"]
            return button.exists && button.isSelected
        }
        let frame = homePage(app, selected ?? "overview").frame.intersection(app.frame)
        XCTAssertFalse(frame.isNull)
        XCTAssertGreaterThan(frame.width, 100)
        return frame
    }

    private func homeCoordinate(_ app: XCUIApplication, x: CGFloat, y: CGFloat) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: x - app.frame.minX, dy: y - app.frame.minY))
    }

    private func swipeHomePage(_ app: XCUIApplication, forward: Bool) {
        let y = homeSwipeY(app)
        let frame = homeContentFrame(app)
        let right = homeCoordinate(app, x: frame.minX + frame.width * 0.9, y: y)
        let left = homeCoordinate(app, x: frame.minX + frame.width * 0.1, y: y)
        let start = forward ? right : left
        let end = forward ? left : right
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    private func pullHomePage(_ app: XCUIApplication, holdDuration: TimeInterval) {
        let bar = app.descendants(matching: .any)["home.spaceFilter"].firstMatch
        let start = homeCoordinate(app, x: homeContentFrame(app).midX, y: bar.frame.maxY + 70)
        let end = start.withOffset(CGVector(dx: 0, dy: 150))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: holdDuration)
    }

    private func setSwitchValue(_ control: XCUIElement, to value: String, file: StaticString = #filePath, line: UInt = #line) {
        if control.value as? String != value {
            // The edit-mode List exposes the whole row as a switch; tap its actual control.
            control.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        }
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            control.value as? String == value
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed, file: file, line: line)
    }

    private func openFilterEditor(_ app: XCUIApplication) {
        let editor = app.buttons["home.edit.filterBar"]
        XCTAssertTrue(editor.waitForExistence(timeout: 30))
        editor.tap()
        XCTAssertTrue(app.buttons["home.filterBar.appearance"].waitForExistence(timeout: 5))
    }

    private func openHome(_ app: XCUIApplication) {
        let homeIsVisible = NSPredicate { _, _ in
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", "home.page.")).firstMatch.exists
                && !app.buttons["interfaceEditor.home.restore"].exists
        }
        if homeIsVisible.evaluate(with: nil) { return }

        let destinations = [
            app.tabBars.buttons["首页"],
            app.cells.containing(.staticText, identifier: "首页").firstMatch,
            app.buttons.matching(identifier: "首页").firstMatch
        ]
        var timeout: TimeInterval = 30
        if let destination = destinations.first(where: { $0.exists && $0.isHittable }) {
            destination.tap()
        } else {
            // A collapsed iPad sidebar has no hittable destination; use the existing debug route.
            app.terminate()
            app.launchEnvironment["PRIMUSE_OPEN_PAGE"] = "home"
            app.launch()
            app.launchEnvironment.removeValue(forKey: "PRIMUSE_OPEN_PAGE")
            timeout = 90
        }
        let opened = XCTNSPredicateExpectation(predicate: homeIsVisible, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [opened], timeout: timeout), .completed)
    }

    private func restoreHomeAfterTest(_ app: XCUIApplication, arguments: [String]) {
        addTeardownBlock { @MainActor in
            self.continueAfterFailure = true
            self.restoreHome(app, arguments: arguments)
        }
    }

    private func restoreHome(_ app: XCUIApplication, arguments: [String]) {
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "PRIMUSE_OPEN_SETTINGS")
        app.launchArguments = arguments + [
            "-primuse.navigation.mode.v1", "standard"
        ]
        app.launch()
        openHome(app)
        for space in ["music", "radio", "spokenWord", "podcast"] {
            let button = app.buttons["home.spaceFilter.\(space)"]
            if button.exists, button.isSelected { button.tap() }
        }
        XCTAssertTrue(homePage(app, "overview").waitForExistence(timeout: 5))
        app.terminate()
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
