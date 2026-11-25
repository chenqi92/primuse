import Foundation
import Testing
@testable import PrimuseKit

@Suite("Lyrics fonts by language")
struct LyricsLanguageFontTests {
    @Test func mixedScriptsKeepEveryCharacter() {
        let text = "你好 Hello, café! 한국어 👨‍👩‍👧‍👦"
        let runs = LyricsFontLanguage.runs(in: text)
        #expect(runs.map(\.text).joined() == text)
        #expect(runs.map(\.language) == [.korean, .latin, .korean])
        #expect(LyricsFontLanguage.runs(in: "你好 Hello").map(\.language) == [.chinese, .latin])
    }

    @Test func japaneseKanjiUsesWholeLineContext() {
        let context = LyricsFontLanguage.cjkLanguage(in: "世界のどこかで Hello")
        #expect(context == .japanese)
        #expect(LyricsFontLanguage.runs(in: "世界", cjkLanguage: context).first?.language == .japanese)
        #expect(LyricsFontLanguage.runs(in: "Hello", cjkLanguage: context).first?.language == .latin)
        #expect(LyricsFontLanguage.cjkLanguage(in: "世界 ﾊﾛｰ") == .japanese)
        #expect(LyricsFontLanguage.runs(in: "時々ハロー").map(\.language) == [.japanese])
    }

    @Test func chineseVariantsAndExtendedLatin() {
        #expect(LyricsFontLanguage.runs(in: "简体 繁體 𠮷").map(\.language) == [.chinese])
        #expect(LyricsFontLanguage.runs(in: "café Tiếng Việt e\u{301}").map(\.language) == [.latin])
        #expect(LyricsFontLanguage.runs(in: "한글 한").map(\.language) == [.korean])
    }

    @Test func unsupportedScriptsAndEmptyTextUseDefault() {
        #expect(LyricsFontLanguage.runs(in: "").isEmpty)
        #expect(LyricsFontLanguage.runs(in: "مرحبا Привет ไทย").allSatisfy { $0.language == nil })
        #expect(LyricsFontLanguage.runs(in: "123 🎵").first?.language == nil)
    }

    @Test func preferencesRoundTripAndResetIndependently() {
        var preferences = LyricsLanguageFontPreferences()
        #expect(LyricsFontLanguage.allCases.allSatisfy { preferences[$0] == nil })
        preferences[.chinese] = "kaiti"
        preferences[.latin] = "georgia"
        preferences[.japanese] = "imported:MyJapaneseFont"
        let restored = LyricsLanguageFontPreferences(rawValue: preferences.rawValue)
        #expect(restored == preferences)
        preferences[.chinese] = nil
        #expect(preferences[.chinese] == nil)
        #expect(preferences[.latin] == "georgia")
        #expect(preferences[.japanese] == "imported:MyJapaneseFont")
    }

    @Test func malformedPreferencesAndRemovedImports() {
        #expect(LyricsLanguageFontPreferences(rawValue: "broken")[.chinese] == nil)
        var preferences = LyricsLanguageFontPreferences(rawValue: #"{"chinese":"imported:","latin":"georgia","japanese":"imported:Removed","korean":"imported:Kept"}"#)
        #expect(preferences[.chinese] == nil)
        preferences.removeImportedFonts(named: ["Removed"])
        #expect(preferences[.japanese] == nil)
        #expect(preferences[.korean] == "imported:Kept")
        #expect(preferences[.latin] == "georgia")
    }

    @Test func overriddenLanguagesFollowFixedOrderAndClearTogether() {
        var preferences = LyricsLanguageFontPreferences()
        #expect(preferences.overriddenLanguages.isEmpty)
        preferences[.korean] = "nanumPen"
        preferences[.chinese] = "kaiti"
        #expect(preferences.overriddenLanguages == [.chinese, .korean])
        preferences.removeAllLanguageFonts()
        #expect(preferences.overriddenLanguages.isEmpty)
        #expect(LyricsLanguageFontPreferences(rawValue: preferences.rawValue) == LyricsLanguageFontPreferences())
    }
}

@Suite("Lyrics font fallback across devices")
struct LyricsFontFallbackPolicyTests {
    /// 这台设备上有的:内置的几种,和这台导入过的一种。
    private static let onThisDevice: Set<String> = ["kaiti", "georgia", "system", "imported:LocalFont"]
    private static func available(_ selection: String) -> Bool { onThisDevice.contains(selection) }

    @Test("A language font this device can draw keeps drawing it")
    func availableLanguageFontsAreDrawn() {
        var preferences = LyricsLanguageFontPreferences()
        preferences[.chinese] = "kaiti"
        preferences[.latin] = "imported:LocalFont"
        let drawable = LyricsFontFallbackPolicy.drawableLanguageFonts(in: preferences, isAvailable: Self.available)
        #expect(drawable == [.chinese: "kaiti", .latin: "imported:LocalFont"])
    }

    @Test("A font imported on another device follows the default font instead of locking that script to the system font")
    func missingImportFollowsDefault() {
        var preferences = LyricsLanguageFontPreferences()
        preferences[.chinese] = "imported:PhoneOnlyFont"
        preferences[.latin] = "georgia"
        let drawable = LyricsFontFallbackPolicy.drawableLanguageFonts(in: preferences, isAvailable: Self.available)
        #expect(drawable[.chinese] == nil)
        #expect(drawable[.latin] == "georgia")
    }

    @Test("Fonts still downloading, or added by a newer version, follow the default until they can be drawn")
    func notYetDrawableFollowsDefault() {
        var preferences = LyricsLanguageFontPreferences()
        preferences[.japanese] = "klee"
        preferences[.korean] = "fontFromNewerVersion"
        #expect(LyricsFontFallbackPolicy.drawableLanguageFonts(in: preferences, isAvailable: Self.available).isEmpty)
        let afterDownload = LyricsFontFallbackPolicy.drawableLanguageFonts(in: preferences) { $0 == "klee" }
        #expect(afterDownload == [.japanese: "klee"])
    }

    @Test("Choosing the system font for one script is an explicit choice, not a fallback")
    func explicitSystemFontIsKept() {
        var preferences = LyricsLanguageFontPreferences()
        preferences[.chinese] = "system"
        #expect(LyricsFontFallbackPolicy.drawableLanguageFonts(in: preferences, isAvailable: Self.available) == [.chinese: "system"])
    }

    @Test("Settings list every script with its own font, in a fixed order, with whether this device can draw it")
    func languageFontsForTheSettingsNote() {
        var preferences = LyricsLanguageFontPreferences()
        preferences[.korean] = "imported:PhoneOnlyFont"
        preferences[.chinese] = "kaiti"
        let listed = LyricsFontFallbackPolicy.languageFonts(in: preferences, isAvailable: Self.available)
        #expect(listed == [
            .init(language: .chinese, selection: "kaiti", isAvailable: true),
            .init(language: .korean, selection: "imported:PhoneOnlyFont", isAvailable: false),
        ])
        #expect(LyricsFontFallbackPolicy.languageFonts(in: LyricsLanguageFontPreferences(), isAvailable: Self.available).isEmpty)
    }
}

@Suite("Player text font selection")
struct PlayerTextFontSelectionTests {
    @Test("Built-in names stored before imports existed still parse as built-in fonts")
    func legacyBuiltinValues() {
        for name in ["system", "pingFang", "songti", "georgia", "iowan"] {
            let selection = PlayerTextFontSelection(rawValue: name)
            #expect(selection == .builtin(name))
            #expect(selection?.rawValue == name)
        }
    }

    @Test("Imported fonts round-trip through the stored value")
    func importedRoundTrip() {
        let selection = PlayerTextFontSelection(rawValue: "imported:LXGWWenKai-Regular")
        #expect(selection == .imported(postScriptName: "LXGWWenKai-Regular"))
        #expect(selection?.rawValue == "imported:LXGWWenKai-Regular")
        let encoded = PlayerTextFontSelection.imported(postScriptName: "Foo-Bold").rawValue
        #expect(PlayerTextFontSelection(rawValue: encoded) == .imported(postScriptName: "Foo-Bold"))
    }

    @Test("Empty or damaged values are rejected so callers fall back to the system font")
    func rejectsDamagedValues() {
        #expect(PlayerTextFontSelection(rawValue: "") == nil)
        #expect(PlayerTextFontSelection(rawValue: "imported:") == nil)
        #expect(PlayerTextFontSelection(rawValue: "imported:Foo\nBar") == nil)
        #expect(PlayerTextFontSelection(rawValue: "imported:Foo\u{0007}") == nil)
    }

    @Test("A built-in name that merely contains the prefix text is not mistaken for an import")
    func prefixMustLead() {
        #expect(PlayerTextFontSelection(rawValue: "notimported:Foo") == .builtin("notimported:Foo"))
    }

    @Test("Sample text prefers Han, then kana, then Hangul, then Latin")
    func sampleScriptPriority() {
        #expect(PlayerTextFontSampleScript.preferred(coversHan: true, coversKana: true, coversHangul: true) == .han)
        #expect(PlayerTextFontSampleScript.preferred(coversHan: false, coversKana: true, coversHangul: true) == .kana)
        #expect(PlayerTextFontSampleScript.preferred(coversHan: false, coversKana: false, coversHangul: true) == .hangul)
        #expect(PlayerTextFontSampleScript.preferred(coversHan: false, coversKana: false, coversHangul: false) == .latin)
        #expect(PlayerTextFontSampleScript.han.sample == "\u{5B57}")
        #expect(PlayerTextFontSampleScript.latin.sample == "Aa")
    }
}

@Suite("Imported font catalog policy")
struct ImportedFontCatalogPolicyTests {
    private static let start = Date(timeIntervalSince1970: 1_800_000_000)

    private static func face(
        _ postScriptName: String,
        family: String,
        localizedFamily: String? = nil,
        weight: Double = 0,
        italic: Bool = false,
        script: PlayerTextFontSampleScript = .latin,
        file: String,
        minute: Double = 0
    ) -> ImportedFontFace {
        ImportedFontFace(
            postScriptName: postScriptName,
            familyName: family,
            localizedFamilyName: localizedFamily,
            localizedDisplayName: nil,
            weight: weight,
            isItalic: italic,
            sampleScript: script,
            fileName: file,
            importedAt: start.addingTimeInterval(minute * 60)
        )
    }

    @Test("Importing the same file again adds nothing")
    func duplicateFileAddsNothing() {
        let faces = [Self.face("Foo-Regular", family: "Foo", file: "Foo.ttf")]
        let added = ImportedFontCatalogPolicy.addedFaces(faces, existingPostScriptNames: ["Foo-Regular"])
        #expect(added.isEmpty)
    }

    @Test("Only the faces that are new are added, and repeats inside one file count once")
    func partialOverlap() {
        let faces = [
            Self.face("Foo-Regular", family: "Foo", file: "Foo.ttc"),
            Self.face("Foo-Bold", family: "Foo", weight: 0.4, file: "Foo.ttc"),
            Self.face("Foo-Bold", family: "Foo", weight: 0.4, file: "Foo.ttc"),
        ]
        let added = ImportedFontCatalogPolicy.addedFaces(faces, existingPostScriptNames: ["Foo-Regular"])
        #expect(added.map(\.postScriptName) == ["Foo-Bold"])
    }

    @Test("Weights imported as separate files collapse into one entry represented by the upright regular")
    func familyCollapsesAcrossFiles() {
        let faces = [
            Self.face("Wen-Bold", family: "Wen", localizedFamily: "\u{6587}", weight: 0.4, script: .han, file: "Wen-Bold.ttf"),
            Self.face("Wen-Italic", family: "Wen", italic: true, file: "Wen-Italic.ttf", minute: 1),
            Self.face("Wen-Regular", family: "Wen", localizedFamily: "\u{6587}", script: .han, file: "Wen-Regular.ttf", minute: 2),
        ]
        let entries = ImportedFontCatalogPolicy.entries(from: faces)
        #expect(entries.count == 1)
        #expect(entries.first?.postScriptName == "Wen-Regular")
        #expect(entries.first?.title == "\u{6587}")
        #expect(entries.first?.sampleScript == .han)
        #expect(entries.first?.memberPostScriptNames == ["Wen-Bold", "Wen-Italic", "Wen-Regular"])
        #expect(entries.first?.fileNames == ["Wen-Bold.ttf", "Wen-Italic.ttf", "Wen-Regular.ttf"])
        #expect(entries.first?.contains(postScriptName: "Wen-Bold") == true)
    }

    @Test("A family with only a bold face is still listed, represented by that face")
    func boldOnlyFamily() {
        let entries = ImportedFontCatalogPolicy.entries(from: [
            Self.face("Brush-Heavy", family: "Brush", weight: 0.62, file: "Brush.otf"),
        ])
        #expect(entries.map(\.postScriptName) == ["Brush-Heavy"])
        #expect(entries.first?.title == "Brush")
    }

    @Test("A collection with two families lists both, sharing the file for removal")
    func collectionWithTwoFamilies() {
        let entries = ImportedFontCatalogPolicy.entries(from: [
            Self.face("Sans-Regular", family: "Sans", file: "Pair.ttc"),
            Self.face("Mono-Regular", family: "Mono", file: "Pair.ttc"),
        ])
        #expect(entries.map(\.title) == ["Sans", "Mono"])
        #expect(entries.allSatisfy { $0.fileNames == ["Pair.ttc"] })
    }

    @Test("Entries keep import order so the newest sits next to the import button")
    func importOrder() {
        let entries = ImportedFontCatalogPolicy.entries(from: [
            Self.face("Zed-Regular", family: "Zed", file: "Zed.ttf", minute: 0),
            Self.face("Alpha-Regular", family: "Alpha", file: "Alpha.ttf", minute: 5),
        ])
        #expect(entries.map(\.title) == ["Zed", "Alpha"])
    }

    @Test("The same PostScript name in two files is listed once, but both files go when it is removed")
    func duplicatePostScriptAcrossFiles() {
        let entries = ImportedFontCatalogPolicy.entries(from: [
            Self.face("Foo-Regular", family: "Foo", file: "Foo.ttf", minute: 0),
            Self.face("Foo-Regular", family: "Foo", file: "Foo 2.ttf", minute: 1),
        ])
        #expect(entries.count == 1)
        #expect(entries.first?.memberPostScriptNames == ["Foo-Regular"])
        #expect(entries.first?.fileNames == ["Foo.ttf", "Foo 2.ttf"])
    }

    @Test("Two different families with the same visible name are told apart by PostScript name")
    func clashingTitles() {
        let entries = ImportedFontCatalogPolicy.entries(from: [
            Self.face("FooA-Regular", family: "Foo A", localizedFamily: "Foo", file: "a.ttf"),
            Self.face("FooB-Regular", family: "Foo B", localizedFamily: "foo", file: "b.ttf", minute: 1),
        ])
        #expect(entries.map(\.title) == ["Foo \u{00B7} FooA-Regular", "foo \u{00B7} FooB-Regular"])
    }

    @Test("Title falls back from the localized family name to the PostScript name")
    func titleFallbacks() {
        var face = Self.face("X-Regular", family: "  ", localizedFamily: nil, file: "x.ttf")
        face.localizedDisplayName = "X Display"
        #expect(ImportedFontCatalogPolicy.title(for: face) == "X Display")
        face.localizedDisplayName = nil
        #expect(ImportedFontCatalogPolicy.title(for: face) == "X-Regular")
        face.familyName = "Family"
        #expect(ImportedFontCatalogPolicy.title(for: face) == "Family")
        face.localizedFamilyName = "\u{5BB6}\u{65CF}"
        #expect(ImportedFontCatalogPolicy.title(for: face) == "\u{5BB6}\u{65CF}")
    }

    @Test("A family with an empty name is grouped by its PostScript name alone")
    func emptyFamilyName() {
        let entries = ImportedFontCatalogPolicy.entries(from: [
            Self.face("A-Regular", family: "", file: "a.ttf"),
            Self.face("B-Regular", family: "", file: "b.ttf", minute: 1),
        ])
        #expect(entries.map(\.postScriptName) == ["A-Regular", "B-Regular"])
    }

    @Test("Stored file names keep the original name and number clashes case-insensitively")
    func storedFileNames() {
        #expect(ImportedFontCatalogPolicy.storedFileName(for: "Foo.ttf", existing: []) == "Foo.ttf")
        #expect(ImportedFontCatalogPolicy.storedFileName(for: "Foo.ttf", existing: ["foo.TTF"]) == "Foo 2.ttf")
        #expect(ImportedFontCatalogPolicy.storedFileName(for: "Foo.ttf", existing: ["Foo.ttf", "Foo 2.ttf"]) == "Foo 3.ttf")
        #expect(ImportedFontCatalogPolicy.storedFileName(for: "dir/sub/Bar.otf", existing: []) == "Bar.otf")
        #expect(ImportedFontCatalogPolicy.storedFileName(for: "NoExtension", existing: ["NoExtension"]) == "NoExtension 2")
        #expect(ImportedFontCatalogPolicy.storedFileName(for: ".ttf", existing: []) == "font.ttf")
        #expect(ImportedFontCatalogPolicy.storedFileName(for: "", existing: []) == "font")
    }

    @Test("CoreText timestamp-synthesized PostScript names are detected accurately")
    func syntheticPostScriptNames() {
        #expect(PlayerTextFontSelection.isSyntheticCoreTextPostScriptName("font0000000030b6595a"))
        #expect(PlayerTextFontSelection.isSyntheticCoreTextPostScriptName("font0000000030B6595A"))
        #expect(!PlayerTextFontSelection.isSyntheticCoreTextPostScriptName("AlibabaPuHuiTi-Regular"))
        #expect(!PlayerTextFontSelection.isSyntheticCoreTextPostScriptName("font1234"))
        #expect(!PlayerTextFontSelection.isSyntheticCoreTextPostScriptName("font0000000030b6595g"))
    }

    @Test("Private dot-prefixed clones in a collection are skipped only when regular faces exist")
    func visibleFaceIndices() {
        #expect(
            ImportedFontCatalogPolicy.selectVisibleFaceIndices(postScriptNames: [
                "PingFangSC-Regular", ".PingFangSC-Regular", "PingFangSC-Bold", ".PingFangSC-Bold",
            ]) == [0, 2]
        )
        #expect(
            ImportedFontCatalogPolicy.selectVisibleFaceIndices(postScriptNames: [
                ".PingFangSC-Regular", ".PingFangSC-Bold",
            ]) == [0, 1]
        )
        #expect(
            ImportedFontCatalogPolicy.selectVisibleFaceIndices(postScriptNames: [
                "PingFangHK-Regular", "PingFangTC-Regular", "PingFangSC-Regular", ".PingFangSC-Regular",
            ]) == [2, 0, 1]
        )
    }

    @Test("Fallback weight inference recovers weight tokens when modded fonts leave OS/2 weight at 0")
    func fallbackWeightInference() {
        #expect(ImportedFontCatalogPolicy.resolvedWeight(coreTextWeight: 0, rawPostScriptName: "PingFangSC-Ultralight") == -0.8)
        #expect(ImportedFontCatalogPolicy.resolvedWeight(coreTextWeight: 0, rawPostScriptName: "PingFangSC-Light") == -0.4)
        #expect(ImportedFontCatalogPolicy.resolvedWeight(coreTextWeight: 0, rawPostScriptName: "PingFangSC-Regular") == 0.0)
        #expect(ImportedFontCatalogPolicy.resolvedWeight(coreTextWeight: 0, rawPostScriptName: "PingFangSC-Medium") == 0.23)
        #expect(ImportedFontCatalogPolicy.resolvedWeight(coreTextWeight: 0, rawPostScriptName: "PingFangSC-Semibold") == 0.3)
        #expect(ImportedFontCatalogPolicy.resolvedWeight(coreTextWeight: 0, rawPostScriptName: "PingFangSC-Bold") == 0.4)
        #expect(ImportedFontCatalogPolicy.resolvedWeight(coreTextWeight: 0.4, rawPostScriptName: "PingFangSC-Light") == 0.4)
    }

    @Test("Face identity preserves normal PostScript names and stabilizes synthetic or system-masked fonts")
    func resolveFaceIdentityCases() {
        let clean = ImportedFontCatalogPolicy.resolveFaceIdentity(
            rawPostScriptName: "AlibabaPuHuiTi-Regular",
            rawFamilyName: "Alibaba PuHuiTi",
            localizedFamilyName: "阿里巴巴普惠体",
            localizedDisplayName: "阿里巴巴普惠体 Regular",
            fileName: "AlibabaPuHuiTi-Regular.ttf",
            contentHashHex: "aaaaaaaaaaaaaaaa1111111111111111",
            faceIndex: 0
        )
        #expect(clean == .init(
            postScriptName: "AlibabaPuHuiTi-Regular",
            familyName: "Alibaba PuHuiTi",
            localizedFamilyName: "阿里巴巴普惠体",
            localizedDisplayName: "阿里巴巴普惠体 Regular"
        ))

        let synthA = ImportedFontCatalogPolicy.resolveFaceIdentity(
            rawPostScriptName: "font0000000030b6595a",
            rawFamilyName: "经典繁角隶",
            localizedFamilyName: "经典繁角隶",
            localizedDisplayName: nil,
            fileName: "经典繁角隶.ttf",
            contentHashHex: "1234567890abcdef0000",
            faceIndex: 0
        )
        let synthB = ImportedFontCatalogPolicy.resolveFaceIdentity(
            rawPostScriptName: "font0000000030b65999",
            rawFamilyName: "经典繁角隶",
            localizedFamilyName: "经典繁角隶",
            localizedDisplayName: nil,
            fileName: "经典繁角隶.ttf",
            contentHashHex: "1234567890abcdef0000",
            faceIndex: 0
        )
        #expect(synthA == synthB)
        #expect(synthA?.postScriptName == "file-1234567890abcdef-0")
        #expect(synthA?.familyName == "经典繁角隶")

        let unnamedSynth = ImportedFontCatalogPolicy.resolveFaceIdentity(
            rawPostScriptName: nil,
            rawFamilyName: "",
            localizedFamilyName: nil,
            localizedDisplayName: nil,
            fileName: "角隶.ttf",
            contentHashHex: "fedcba98765432100000",
            faceIndex: 0
        )
        #expect(unnamedSynth?.postScriptName == "file-fedcba9876543210-0")
        #expect(unnamedSynth?.localizedFamilyName == "角隶")

        let maskedOne = ImportedFontCatalogPolicy.resolveFaceIdentity(
            rawPostScriptName: "PingFangSC-Regular",
            rawFamilyName: "PingFang SC",
            localizedFamilyName: "苹方-简",
            localizedDisplayName: "苹方-简 常规体",
            fileName: "超级花伦丸.ttf",
            contentHashHex: "1111111111111111aaaa",
            faceIndex: 0
        )
        let maskedOneBold = ImportedFontCatalogPolicy.resolveFaceIdentity(
            rawPostScriptName: "PingFangSC-Bold",
            rawFamilyName: "PingFang SC",
            localizedFamilyName: "苹方-简",
            localizedDisplayName: "苹方-简 粗体",
            fileName: "超级花伦丸.ttf",
            contentHashHex: "1111111111111111aaaa",
            faceIndex: 1
        )
        let maskedOneHK = ImportedFontCatalogPolicy.resolveFaceIdentity(
            rawPostScriptName: "PingFangHK-Regular",
            rawFamilyName: "PingFang HK",
            localizedFamilyName: "苹方-港",
            localizedDisplayName: "苹方-港 常规体",
            fileName: "超级花伦丸.ttf",
            contentHashHex: "1111111111111111aaaa",
            faceIndex: 2
        )
        let maskedTwo = ImportedFontCatalogPolicy.resolveFaceIdentity(
            rawPostScriptName: "PingFangSC-Regular",
            rawFamilyName: "PingFang SC",
            localizedFamilyName: "苹方-简",
            localizedDisplayName: "苹方-简 常规体",
            fileName: "冬青丸pro.ttf",
            contentHashHex: "2222222222222222bbbb",
            faceIndex: 0
        )
        #expect(maskedOne?.postScriptName != maskedTwo?.postScriptName)
        #expect(maskedOne?.familyName == maskedOneBold?.familyName)
        #expect(maskedOne?.familyName == maskedOneHK?.familyName)
        #expect(maskedOne?.familyName != maskedTwo?.familyName)
        #expect(maskedOne?.localizedFamilyName == "超级花伦丸")
        #expect(maskedTwo?.localizedFamilyName == "冬青丸pro")

        let leakedFamily = ImportedFontCatalogPolicy.resolveFaceIdentity(
            rawPostScriptName: "SuperHuaLunWan-Regular",
            rawFamilyName: "PingFang SC",
            localizedFamilyName: "PingFang SC",
            localizedDisplayName: "SuperHuaLunWan",
            fileName: "超级花伦丸.ttf",
            contentHashHex: "3333333333333333cccc",
            faceIndex: 0
        )
        #expect(leakedFamily?.postScriptName == "SuperHuaLunWan-Regular")
        #expect(leakedFamily?.familyName == "masked#3333333333333333")
        #expect(leakedFamily?.localizedFamilyName == "超级花伦丸")
    }

    @Test("Matching face selects the closest upright weight inside the imported family")
    func matchingFaceByWeight() {
        let faces = [
            Self.face("Ali-Light", family: "Ali", weight: -0.4, file: "Ali-Light.ttf"),
            Self.face("Ali-Regular", family: "Ali", weight: 0.0, file: "Ali-Regular.ttf", minute: 1),
            Self.face("Ali-Italic", family: "Ali", weight: 0.0, italic: true, file: "Ali-Italic.ttf", minute: 2),
            Self.face("Ali-Bold", family: "Ali", weight: 0.4, file: "Ali-Bold.ttf", minute: 3),
        ]
        #expect(ImportedFontCatalogPolicy.matchingFace(in: faces, targetWeight: -0.4)?.postScriptName == "Ali-Light")
        #expect(ImportedFontCatalogPolicy.matchingFace(in: faces, targetWeight: 0.0)?.postScriptName == "Ali-Regular")
        #expect(ImportedFontCatalogPolicy.matchingFace(in: faces, targetWeight: 0.3)?.postScriptName == "Ali-Bold")
        #expect(ImportedFontCatalogPolicy.matchingFace(in: faces, targetWeight: 0.4)?.postScriptName == "Ali-Bold")
        #expect(ImportedFontCatalogPolicy.matchingFace(in: faces, targetWeight: 0.0, preferItalic: true)?.postScriptName == "Ali-Italic")

        let single = [Self.face("JiaoLi", family: "JiaoLi", weight: 0.0, file: "JiaoLi.ttf")]
        #expect(ImportedFontCatalogPolicy.matchingFace(in: single, targetWeight: 0.4)?.postScriptName == "JiaoLi")
    }
}
