import CoreText
import SwiftUI
import UniformTypeIdentifiers
import PrimuseKit
#if os(macOS)
import AppKit
#endif

// 歌词与文稿可以用自己导入的字体(#332)。字体文件拷进 App 自己的 Application Support/Primuse/ImportedFonts/
// (不放 App Group、不进 iCloud),只在本 App 的进程里注册,不装进系统、不需要额外权限。
// 选中值会随 iCloud 同步,字体文件本身不同步:别的设备没导入同一个字体时显示系统字体并在设置里说明。
// 电视没有文件选择,不做导入。哪些算重复、怎么列、叫什么名字的规则在 Kit 的 `ImportedFontCatalogPolicy`。

/// 导入字体文件的读写与注册。都是 CoreText 与文件操作,不碰主线程。
enum ImportedPlayerTextFontFiles {
    static var directory: URL {
        FileManager.default.primuseDirectoryURL(for: .applicationSupportDirectory)
            .appendingPathComponent("Primuse", isDirectory: true)
            .appendingPathComponent("ImportedFonts", isDirectory: true)
    }

    struct Loaded: Sendable {
        var faces: [ImportedFontFace] = []
        /// 注册好、能用的字体名。
        var activatedNames: Set<String> = []
    }

    struct ImportResult: Sendable {
        var addedFaces: [ImportedFontFace] = []
        var activatedNames: Set<String> = []
        var report = PlayerTextFontImportReport()
    }

    /// 启动时:读出目录里每个文件的字体,一次注册完。
    static func loadAll() async -> Loaded {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.creationDateKey, .isRegularFileKey]
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return Loaded() }

        var loaded = Loaded()
        var fontURLs: [URL] = []
        for url in urls {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile != false else { continue }
            let faces = faces(in: url, fileName: url.lastPathComponent, importedAt: values?.creationDate ?? .distantPast)
            guard !faces.isEmpty else { continue }
            loaded.faces += faces
            fontURLs.append(url)
        }
        await register(fontURLs)
        loaded.activatedNames = Set(loaded.faces.map(\.postScriptName).filter { PlayerTextFontLibrary.isInstalled($0) })
        return loaded
    }

    /// 导入选好(或拖进来)的文件:读不出字体的、全都导入过的不拷;拷进来注册不上的删掉。
    static func importFiles(_ urls: [URL], existingPostScriptNames: Set<String>) async -> ImportResult {
        let fileManager = FileManager.default
        let directory = self.directory
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var existing = existingPostScriptNames
        var result = ImportResult()

        for url in urls {
            let originalName = url.lastPathComponent
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }

            let now = Date()
            let faces = faces(in: url, fileName: originalName, importedAt: now)
            guard !faces.isEmpty else {
                result.report.unreadable.append(originalName)
                continue
            }
            let added = ImportedFontCatalogPolicy.addedFaces(faces, existingPostScriptNames: existing)
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

            await register([destination])
            let activated = added.map(\.postScriptName).filter { PlayerTextFontLibrary.isInstalled($0) }
            guard !activated.isEmpty else {
                await unregister([destination])
                try? fileManager.removeItem(at: destination)
                result.report.failed.append(originalName)
                continue
            }
            result.addedFaces += added.map { face in
                var face = face
                face.fileName = storedName
                return face
            }
            result.activatedNames.formUnion(activated)
            result.report.importedPostScriptNames.append(contentsOf: activated)
            existing.formUnion(added.map(\.postScriptName))
        }
        return result
    }

    /// 删掉导入的字体:先在本进程里注销,再删文件。
    static func remove(_ urls: [URL]) async {
        await unregister(urls)
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// 文件里的每个字体;读不出来(不是字体文件、文件坏了)是空数组。名字取这台设备语言的本地化名。
    static func faces(in url: URL, fileName: String, importedAt: Date) -> [ImportedFontFace] {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] else {
            return []
        }
        return descriptors.compactMap { face(from: $0, fileName: fileName, importedAt: importedAt) }
    }

    private static func face(from descriptor: CTFontDescriptor, fileName: String, importedAt: Date) -> ImportedFontFace? {
        guard let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String,
              PlayerTextFontSelection.isUsablePostScriptName(name) else { return nil }
        let family = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String ?? ""
        let localizedFamily = CTFontDescriptorCopyLocalizedAttribute(descriptor, kCTFontFamilyNameAttribute, nil) as? String
        let localizedDisplay = CTFontDescriptorCopyLocalizedAttribute(descriptor, kCTFontDisplayNameAttribute, nil) as? String

        let font = CTFontCreateWithFontDescriptor(descriptor, 12, nil)
        let traits = CTFontCopyTraits(font) as NSDictionary
        let weight = (traits[kCTFontWeightTrait as String] as? NSNumber)?.doubleValue ?? 0
        let isItalic = CTFontGetSymbolicTraits(font).contains(.traitItalic)
        let characters = CTFontCopyCharacterSet(font)
        func covers(_ scalar: UInt32) -> Bool { CFCharacterSetIsLongCharacterMember(characters, scalar) }

        return ImportedFontFace(
            postScriptName: name,
            familyName: family,
            localizedFamilyName: localizedFamily,
            localizedDisplayName: localizedDisplay,
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
    }

    /// 只在本进程里注册(`.process`):别的 App 看不到,也不需要额外权限。成没成由调用方逐个字体名查。
    private static func register(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }
        let once = PlayerTextFontActivation()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            CTFontManagerRegisterFontURLs(urls as CFArray, .process, true) { _, done in
                if done, once.claim() { continuation.resume() }
                return true
            }
        }
    }

    private static func unregister(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }
        let once = PlayerTextFontActivation()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            CTFontManagerUnregisterFontURLs(urls as CFArray, .process) { _, done in
                if done, once.claim() { continuation.resume() }
                return true
            }
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
    /// 启动时在后台把导入过的字体读出来、注册一遍;注册好之前选中的导入字体先画系统字体。
    func loadImportedFonts() {
        Task {
            let loaded = await Task.detached(priority: .utility) {
                await ImportedPlayerTextFontFiles.loadAll()
            }.value
            importedFaces = loaded.faces
            activatedNames.formUnion(loaded.activatedNames)
            importedFonts = ImportedFontCatalogPolicy.entries(from: importedFaces)
            importedFontsLoaded = true
        }
    }

    /// 导入字体文件。返回这次的结果;导入成功的字体立刻能用。
    func importFonts(from urls: [URL]) async -> PlayerTextFontImportReport {
        guard !urls.isEmpty, !isImporting else { return PlayerTextFontImportReport() }
        isImporting = true
        defer { isImporting = false }
        let existing = Set(importedFaces.map(\.postScriptName))
        let result = await Task.detached(priority: .userInitiated) {
            await ImportedPlayerTextFontFiles.importFiles(urls, existingPostScriptNames: existing)
        }.value
        importedFaces += result.addedFaces
        activatedNames.formUnion(result.activatedNames)
        importedFonts = ImportedFontCatalogPolicy.entries(from: importedFaces)
        return result.report
    }

    /// 删掉一个导入的字体(连同它所在文件里的别的字体)。歌词或文稿正选着它就先退回系统字体。
    func removeImportedFont(_ entry: ImportedFontEntry) {
        let files = Set(entry.fileNames)
        let removedNames = Set(importedFaces.filter { files.contains($0.fileName) }.map(\.postScriptName))
        Self.resetSelections(using: removedNames)
        importedFaces.removeAll { files.contains($0.fileName) }
        activatedNames.subtract(removedNames)
        importedFonts = ImportedFontCatalogPolicy.entries(from: importedFaces)
        let directory = ImportedPlayerTextFontFiles.directory
        let urls = files.map { directory.appendingPathComponent($0) }
        Task.detached(priority: .utility) {
            await ImportedPlayerTextFontFiles.remove(urls)
        }
    }

    /// 歌词(随 iCloud 同步)与文稿(这台设备自己的)的字体正选着要删的字体时退回系统字体。
    private static func resetSelections(using removedNames: Set<String>) {
        let defaults = UserDefaults.standard
        for key in [PlayerAppearancePreferences.lyricsFontKey, SpokenWordTranscriptReaderPreferences.fontKey] {
            guard let rawValue = defaults.string(forKey: key),
                  case let .imported(name)? = PlayerTextFont(rawValue: rawValue),
                  removedNames.contains(name) else { continue }
            defaults.set(PlayerTextFont.system.rawValue, forKey: key)
        }
    }
}

/// 导入字体的入口与结果提示,挂在有导入按钮的视图上:iPhone / iPad 打开文件选择;Mac 由按钮直接弹打开面板
/// (`PlayerTextFontImportPanel`),选好或拖进来的文件放进 `pendingURLs` 交给这里导入。
/// 导入成功的选中第一个;有读不出、导入过、用不了的文件时逐个说明。
struct PlayerTextFontImportModifier: ViewModifier {
    @Binding var isPresented: Bool
    @Binding var pendingURLs: [URL]
    let onImported: (PlayerTextFont) -> Void

    @State private var report: PlayerTextFontImportReport? = nil

    func body(content: Content) -> some View {
        content
            #if os(iOS)
            .fileImporter(
                isPresented: $isPresented,
                allowedContentTypes: [.font],
                allowsMultipleSelection: true
            ) { result in
                guard case let .success(urls) = result, !urls.isEmpty else { return }
                pendingURLs = urls
            }
            #endif
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
        let library = PlayerTextFontLibrary.shared
        let outcome = await library.importFonts(from: urls)
        if let first = outcome.importedPostScriptNames.first {
            onImported(library.pickerFont(for: .imported(postScriptName: first)))
        }
        if outcome.hasProblems {
            report = outcome
        }
    }
}

#if os(macOS)
/// Mac 上导入字体用的打开面板(和别处选文件一样直接弹,不经 SwiftUI 的文件选择,弹层收起也不影响)。
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
}
#endif
