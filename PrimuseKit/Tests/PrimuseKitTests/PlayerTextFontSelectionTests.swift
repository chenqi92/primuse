import Foundation
import Testing
@testable import PrimuseKit

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
}
