import CoreText
import CryptoKit
import SwiftUI
import UniformTypeIdentifiers
import PrimuseKit
#if os(macOS)
import AppKit
#endif

// 歌词与文稿可以用自己导入的字体(#332)。字体文件拷进 App 自己的 Application Support/Primuse/ImportedFonts/
// (不放 App Group、不进 iCloud),直接以文件描述符创建 CoreText 字体,不写入系统/进程字体表,
// 既不污染应用内既有字体,也能加载与系统字体同名或 PostScript 名不规范的字体文件。
// 选中值会随 iCloud 同步,字体文件本身不同步:别的设备没导入同一个字体时显示系统字体并在设置里说明。
// 电视没有文件选择,不做导入。哪些算重复、怎么列、叫什么名字的规则在 Kit 的 `ImportedFontCatalogPolicy`。

/// 导入字体文件的读写与描述符加载。都是 CoreText 与文件操作,不碰主线程。
enum ImportedPlayerTextFontFiles {
    static var directory: URL {
        FileManager.default.primuseDirectoryURL(for: .applicationSupportDirectory)
            .appendingPathComponent("Primuse", isDirectory: true)
            .appendingPathComponent("ImportedFonts", isDirectory: true)
    }

    struct Loaded: Sendable {
        var faces: [ImportedFontDescriptorStore.Face] = []
        /// 加载好、能用的字体标识。
        var activatedNames: Set<String> = []
    }

    struct ImportResult: Sendable {
        var addedFaces: [ImportedFontDescriptorStore.Face] = []
        var activatedNames: Set<String> = []
        var report = PlayerTextFontImportReport()
    }

    /// 启动时:读出目录里每个文件的可用字体描述符。
    static func loadAll(in directory: URL = ImportedPlayerTextFontFiles.directory) async -> Loaded {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.creationDateKey, .isRegularFileKey]
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return Loaded() }

        var loaded = Loaded()
        for url in urls {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile != false else { continue }
            let faces = loadedFaces(in: url, fileName: url.lastPathComponent, importedAt: values?.creationDate ?? .distantPast)
            guard !faces.isEmpty else { continue }
            loaded.faces += faces
        }
        loaded.activatedNames = Set(loaded.faces.map(\.metadata.postScriptName))
        return loaded
    }

    /// 导入选好(或拖进来)的文件:读不出字体的、全都导入过的不拷;拷进来校验不通过的删掉。
    static func importFiles(
        _ urls: [URL],
        existingPostScriptNames: Set<String>,
        directory: URL = ImportedPlayerTextFontFiles.directory
    ) async -> ImportResult {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var existing = existingPostScriptNames
        var result = ImportResult()

        for url in urls {
            let originalName = url.lastPathComponent
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }

            let now = Date()
            let sourceFaces = loadedFaces(in: url, fileName: originalName, importedAt: now)
            guard !sourceFaces.isEmpty else {
                result.report.unreadable.append(originalName)
                continue
            }
            let added = ImportedFontCatalogPolicy.addedFaces(
                sourceFaces.map(\.metadata),
                existingPostScriptNames: existing
            )
            guard !added.isEmpty else {
                result.report.duplicates.append(originalName)
                continue
            }

            let storedNames = Set((try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? [])
            let storedName = ImportedFontCatalogPolicy.storedFileName(for: originalName, existing: storedNames)
            let destination = directory.appendingPathComponent(storedName)
            do {
                try fileManager.copyItem(at: url, to: destination)
            } catch {
                result.report.failed.append(originalName)
                continue
            }
            // 拷贝会带上原文件的创建时间;改成现在,「我导入的」才按导入的先后排。
            try? fileManager.setAttributes([.creationDate: now, .modificationDate: now], ofItemAtPath: destination.path)

            // 必须基于本地持久副本重新读取描述符，不能持有即将失效的临时安全域 URL。
            var remainingIDs = Set(added.map(\.postScriptName))
            let activatedFaces = loadedFaces(in: destination, fileName: storedName, importedAt: now)
                .filter { remainingIDs.remove($0.metadata.postScriptName) != nil }
            guard !activatedFaces.isEmpty else {
                try? fileManager.removeItem(at: destination)
                result.report.failed.append(originalName)
                continue
            }
            let activated = activatedFaces.map(\.metadata.postScriptName)
            result.addedFaces += activatedFaces
            result.activatedNames.formUnion(activated)
            result.report.importedPostScriptNames.append(contentsOf: activated)
            existing.formUnion(activated)
        }
        return result
    }

    /// 删掉导入的字体文件。
    static func remove(_ urls: [URL]) async {
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// 文件里的每个可用字体;读不出来(不是字体文件、文件坏了)是空数组。名字取这台设备语言的本地化名。
    static func faces(in url: URL, fileName: String, importedAt: Date) -> [ImportedFontFace] {
        loadedFaces(in: url, fileName: fileName, importedAt: importedAt).map(\.metadata)
    }

    static func loadedFaces(in url: URL, fileName: String, importedAt: Date) -> [ImportedFontDescriptorStore.Face] {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              !data.isEmpty,
              let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              !descriptors.isEmpty else {
            return []
        }
        let contentHashHex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let rawNames = descriptors.map { CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String }
        let visibleIndices = ImportedFontCatalogPolicy.selectVisibleFaceIndices(postScriptNames: rawNames)
        let expectedURL = url.resolvingSymlinksInPath().standardizedFileURL

        return visibleIndices.compactMap { index in
            let descriptor = descriptors[index]
            let font = CTFontCreateWithFontDescriptor(descriptor, 12, nil)
            guard CTFontGetGlyphCount(font) > 0 else { return nil }
            if let resolvedURL = CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL,
               resolvedURL.resolvingSymlinksInPath().standardizedFileURL != expectedURL {
                return nil
            }

            let rawFamily = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String ?? ""
            let localizedFamily = CTFontDescriptorCopyLocalizedAttribute(descriptor, kCTFontFamilyNameAttribute, nil) as? String
            let localizedDisplay = CTFontDescriptorCopyLocalizedAttribute(descriptor, kCTFontDisplayNameAttribute, nil) as? String
            guard let identity = ImportedFontCatalogPolicy.resolveFaceIdentity(
                rawPostScriptName: rawNames[index],
                rawFamilyName: rawFamily,
                localizedFamilyName: localizedFamily,
                localizedDisplayName: localizedDisplay,
                fileName: fileName,
                contentHashHex: contentHashHex,
                faceIndex: index
            ) else { return nil }

            let traits = CTFontCopyTraits(font) as NSDictionary
            let weight = (traits[kCTFontWeightTrait as String] as? NSNumber)?.doubleValue ?? 0
            let isItalic = CTFontGetSymbolicTraits(font).contains(.traitItalic)
            let characters = CTFontCopyCharacterSet(font)
            func covers(_ scalar: UInt32) -> Bool { CFCharacterSetIsLongCharacterMember(characters, scalar) }

            let metadata = ImportedFontFace(
                postScriptName: identity.postScriptName,
                familyName: identity.familyName,
                localizedFamilyName: identity.localizedFamilyName,
                localizedDisplayName: identity.localizedDisplayName,
                weight: weight,
                isItalic: isItalic,
                // 「字」、「あ」、「가」
                sampleScript: .preferred(
                    coversHan: covers(0x5B57),
                    coversKana: covers(0x3042),
                    coversHangul: covers(0xAC00)
                ),
                fileName: fileName,
                importedAt: importedAt
            )
            return ImportedFontDescriptorStore.Face(metadata: metadata, descriptor: descriptor)
        }
    }
}

/// 一次导入的结果。只有出问题的文件才弹提示;导入成功的选中第一个。
struct PlayerTextFontImportReport: Sendable {
    var importedPostScriptNames: [String] = []
    var unreadable: [String] = []
    var duplicates: [String] = []
    var failed: [String] = []

    var hasProblems: Bool { !unreadable.isEmpty || !duplicates.isEmpty || !failed.isEmpty }

    var message: String {
        var lines: [String] = []
        lines += unreadable.map { String(format: String(localized: "transcript_reader_font_import_unreadable_format"), $0) }
        lines += duplicates.map { String(format: String(localized: "transcript_reader_font_import_duplicate_format"), $0) }
        lines += failed.map { String(format: String(localized: "transcript_reader_font_import_failed_format"), $0) }
        return lines.joined(separator: "\n")
    }
}

extension PlayerTextFontLibrary {
    /// 启动时在后台把导入过的字体读出来;加载好之前选中的导入字体先画系统字体。
    func loadImportedFonts(from directory: URL = ImportedPlayerTextFontFiles.directory) {
        Task {
            await reloadImportedFonts(from: directory)
        }
    }

    func reloadImportedFonts(from directory: URL = ImportedPlayerTextFontFiles.directory) async {
        let loaded = await Task.detached(priority: .utility) {
            await ImportedPlayerTextFontFiles.loadAll(in: directory)
        }.value
        let previousImportedNames = Set(importedFaces.map(\.postScriptName))
        activatedNames.subtract(previousImportedNames)
        importedFaceDescriptors = loaded.faces
        importedFaces = loaded.faces.map(\.metadata)
        activatedNames.formUnion(loaded.activatedNames)
        importedFonts = ImportedFontCatalogPolicy.entries(from: importedFaces)
        descriptorStore.replaceAll(faces: importedFaceDescriptors, entries: importedFonts)
        importedFontsLoaded = true
    }

    /// 导入字体文件。返回这次的结果;导入成功的字体立刻能用。
    func importFonts(
        from urls: [URL],
        into directory: URL = ImportedPlayerTextFontFiles.directory
    ) async -> PlayerTextFontImportReport {
        guard !urls.isEmpty, !isImporting else { return PlayerTextFontImportReport() }
        isImporting = true
        defer { isImporting = false }
        let existing = Set(importedFaces.map(\.postScriptName))
        let result = await Task.detached(priority: .userInitiated) {
            await ImportedPlayerTextFontFiles.importFiles(
                urls,
                existingPostScriptNames: existing,
                directory: directory
            )
        }.value
        importedFaceDescriptors += result.addedFaces
        importedFaces += result.addedFaces.map(\.metadata)
        activatedNames.formUnion(result.activatedNames)
        importedFonts = ImportedFontCatalogPolicy.entries(from: importedFaces)
        descriptorStore.replaceAll(faces: importedFaceDescriptors, entries: importedFonts)
        return result.report
    }

    /// 删掉一个导入的字体(连同它所在文件里的别的字体)。歌词或文稿正选着它就先退回系统字体。
    func removeImportedFont(
        _ entry: ImportedFontEntry,
        in directory: URL = ImportedPlayerTextFontFiles.directory
    ) {
        let files = Set(entry.fileNames)
        let removedNames = Set(importedFaces.filter { files.contains($0.fileName) }.map(\.postScriptName))
        Self.resetSelections(using: removedNames)
        importedFaceDescriptors.removeAll { files.contains($0.metadata.fileName) }
        importedFaces.removeAll { files.contains($0.fileName) }
        activatedNames.subtract(removedNames)
        importedFonts = ImportedFontCatalogPolicy.entries(from: importedFaces)
        descriptorStore.replaceAll(faces: importedFaceDescriptors, entries: importedFonts)
        let urls = files.map { directory.appendingPathComponent($0) }
        Task.detached(priority: .utility) {
            await ImportedPlayerTextFontFiles.remove(urls)
        }
    }

    /// 歌词(随 iCloud 同步)与文稿(这台设备自己的)的字体正选着要删的字体时退回系统字体。
    private static func resetSelections(using removedNames: Set<String>) {
        let defaults = UserDefaults.standard
        var preferences = LyricsLanguageFontPreferences(rawValue: defaults.string(forKey: LyricsFontLanguage.preferencesKey) ?? "")
        preferences.removeImportedFonts(named: removedNames)
        defaults.set(preferences.rawValue, forKey: LyricsFontLanguage.preferencesKey)
        CloudKVSSync.shared.markChanged(key: LyricsFontLanguage.preferencesKey)
        for key in [PlayerAppearancePreferences.lyricsFontKey, SpokenWordTranscriptReaderPreferences.fontKey] {
            guard let rawValue = defaults.string(forKey: key),
                  case let .imported(name)? = PlayerTextFont(rawValue: rawValue),
                  removedNames.contains(name) else { continue }
            defaults.set(PlayerTextFont.system.rawValue, forKey: key)
        }
    }
}

/// 导入一批字体文件,得出要选中的那一个(导入成功的第一个,按家族代表)。iPhone / iPad 经下面的修饰符调用;
/// Mac 由字体选择器直接调用,不经视图状态(见 `PlayerTextFontPicker.importOnMac`)。
enum PlayerTextFontImportFlow {
    @MainActor
    static func run(_ urls: [URL]) async -> (font: PlayerTextFont?, report: PlayerTextFontImportReport) {
        let library = PlayerTextFontLibrary.shared
        let report = await library.importFonts(from: urls)
        let font = report.importedPostScriptNames.first.map { library.pickerFont(for: .imported(postScriptName: $0)) }
        return (font, report)
    }
}

#if os(iOS)
/// iPhone / iPad 导入字体的入口与结果提示,挂在有导入按钮的视图上:打开文件选择,选好的文件放进 `pendingURLs`
/// 交给这里导入。导入成功的选中第一个;有读不出、导入过、用不了的文件时逐个说明。
struct PlayerTextFontImportModifier: ViewModifier {
    @Binding var isPresented: Bool
    @Binding var pendingURLs: [URL]
    let onImported: (PlayerTextFont) -> Void

    @State private var report: PlayerTextFontImportReport? = nil

    func body(content: Content) -> some View {
        content
            .fileImporter(
                isPresented: $isPresented,
                allowedContentTypes: [.font],
                allowsMultipleSelection: true
            ) { result in
                guard case let .success(urls) = result, !urls.isEmpty else { return }
                pendingURLs = urls
            }
            .onChange(of: pendingURLs) { _, urls in
                guard !urls.isEmpty else { return }
                pendingURLs = []
                Task { await run(urls) }
            }
            .alert(
                Text("transcript_reader_font_import_failed_title"),
                isPresented: Binding(
                    get: { report != nil },
                    set: { if !$0 { report = nil } }
                ),
                presenting: report
            ) { _ in
                Button("ok", role: .cancel) {}
            } message: { report in
                Text(verbatim: report.message)
            }
    }

    private func run(_ urls: [URL]) async {
        let outcome = await PlayerTextFontImportFlow.run(urls)
        if let font = outcome.font {
            onImported(font)
        }
        if outcome.report.hasProblems {
            report = outcome.report
        }
    }
}
#endif

#if os(macOS)
/// Mac 上导入字体用的打开面板与结果提示框(和别处选文件一样直接弹,不经 SwiftUI 的文件选择与提示,
/// 「更多」里的弹层收起也不影响)。
enum PlayerTextFontImportPanel {
    @MainActor
    static func chooseFiles() -> [URL] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.font]
        return panel.runModal() == .OK ? panel.urls : []
    }

    /// 有读不出、导入过、用不了的文件时逐个说明。
    @MainActor
    static func showProblems(_ report: PlayerTextFontImportReport) {
        let alert = NSAlert()
        alert.messageText = String(localized: "transcript_reader_font_import_failed_title")
        alert.informativeText = report.message
        alert.addButton(withTitle: String(localized: "ok"))
        alert.runModal()
    }
}
#endif
