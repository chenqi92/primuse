import Foundation

public enum LyricsFontLanguage: String, CaseIterable, Codable, Sendable {
    case chinese, latin, japanese, korean

    public static let preferencesKey = "primuse.player.lyricsLanguageFonts"

    /// 汉字与假名共存时使用日文字体；逐字歌词传整句上下文，避免汉字片段误用中文字体。
    public static func cjkLanguage(in text: String) -> Self {
        if text.unicodeScalars.contains(where: { script(of: $0) == .japanese }) { return .japanese }
        if text.unicodeScalars.contains(where: { script(of: $0) == .korean }) { return .korean }
        return .chinese
    }

    private static func script(of scalar: Unicode.Scalar) -> Self? {
        switch scalar.value {
        case 0x3041...0x3096, 0x309D...0x309F, 0x30A1...0x30FA, 0x30FC...0x30FF,
             0x31F0...0x31FF, 0xFF66...0xFF9D, 0x1B000...0x1B16F: .japanese
        case 0x1100...0x11FF, 0x3130...0x318F, 0xA960...0xA97F, 0xAC00...0xD7FF: .korean
        case 0x3005...0x3007, 0x303B, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xF900...0xFAFF, 0x20000...0x323AF: .chinese
        case 0x41...0x5A, 0x61...0x7A, 0xC0...0x2AF, 0x1E00...0x1EFF,
             0xAB30...0xAB6F, 0xFF21...0xFF3A, 0xFF41...0xFF5A: .latin
        default: nil
        }
    }

    public struct Run: Equatable, Sendable {
        public var text: String
        public var language: LyricsFontLanguage?
    }

    public static func runs(in text: String, cjkLanguage: Self? = nil) -> [Run] {
        let cjk = cjkLanguage ?? Self.cjkLanguage(in: text)
        var result: [Run] = []
        var previous: Self?
        for character in text {
            let scalars = character.unicodeScalars
            let detected = scalars.compactMap(script(of:)).first
            let language: Self?
            if detected == .chinese {
                language = cjk
            } else if let detected {
                language = detected
            } else if scalars.contains(where: { CharacterSet.letters.contains($0) }) {
                language = nil
            } else {
                language = previous
            }
            if !result.isEmpty, result[result.count - 1].language == language {
                result[result.count - 1].text.append(character)
            } else {
                result.append(Run(text: String(character), language: language))
            }
            previous = language
        }
        return result
    }
}

public struct LyricsLanguageFontPreferences: Equatable, Sendable {
    private var values: [String: String]

    public init(rawValue: String = "") {
        values = (try? JSONDecoder().decode([String: String].self, from: Data(rawValue.utf8))) ?? [:]
    }

    public var rawValue: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(values)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    public subscript(language: LyricsFontLanguage) -> String? {
        get { values[language.rawValue].flatMap { PlayerTextFontSelection(rawValue: $0)?.rawValue } }
        set { values[language.rawValue] = newValue.flatMap { PlayerTextFontSelection(rawValue: $0)?.rawValue } }
    }

    public mutating func removeImportedFonts(named names: Set<String>) {
        values = values.filter { _, value in
            guard case let .imported(name)? = PlayerTextFontSelection(rawValue: value) else { return true }
            return !names.contains(name)
        }
    }

    /// 单独选了字体的几种文字,按 `LyricsFontLanguage.allCases` 的先后。
    public var overriddenLanguages: [LyricsFontLanguage] {
        LyricsFontLanguage.allCases.filter { self[$0] != nil }
    }

    /// 几种文字都改回跟默认字体。
    public mutating func removeAllLanguageFonts() {
        values.removeAll()
    }
}

/// 歌词里每种文字最终画哪一个字体(#332 按语言选字体)。选中值随 iCloud 同步,字体本身未必跟着来:
/// 别的设备上导入的字体这台没有,要下载的字体这台还没下好。
public enum LyricsFontFallbackPolicy {
    /// 单独选了字体的一种文字,连同这台设备上现在能不能画出它。
    public struct LanguageFont: Equatable, Sendable {
        public var language: LyricsFontLanguage
        public var selection: String
        public var isAvailable: Bool

        public init(language: LyricsFontLanguage, selection: String, isAvailable: Bool) {
            self.language = language
            self.selection = selection
            self.isAvailable = isAvailable
        }
    }

    /// 单独选了字体的几种文字(按 `LyricsFontLanguage.allCases` 的先后)。设置里默认字体下面据此交代:
    /// 这几种不跟着默认字体变,其中这台设备上用不了的先跟默认字体显示。
    public static func languageFonts(
        in preferences: LyricsLanguageFontPreferences,
        isAvailable: (String) -> Bool
    ) -> [LanguageFont] {
        preferences.overriddenLanguages.compactMap { language in
            guard let selection = preferences[language] else { return nil }
            return LanguageFont(language: language, selection: selection, isAvailable: isAvailable(selection))
        }
    }

    /// 真正按自己选的字体画的几种文字。这台设备上用不了的(别的设备导入、这台没有,还没下好,
    /// 新版本才有的内置字体)不在里面,跟默认字体走 —— 不直接退回系统字体,否则在这台设备上
    /// 怎么改默认字体,这种文字都不变。默认字体自己用不了时由调用方再退回系统字体。
    public static func drawableLanguageFonts(
        in preferences: LyricsLanguageFontPreferences,
        isAvailable: (String) -> Bool
    ) -> [LyricsFontLanguage: String] {
        var result: [LyricsFontLanguage: String] = [:]
        for font in languageFonts(in: preferences, isAvailable: isAvailable) where font.isAvailable {
            result[font.language] = font.selection
        }
        return result
    }
}

/// 歌词与文稿字体的选中值(#332)。内置的字体存它自己的名字(和只有内置字体时存的一样,老的设置照样认);
/// 用户导入的字体存 `imported:<PostScript 名>`。选中值随 iCloud 同步到别的设备,那台设备没导入这个字体时
/// 照样认得出它是「导入的字体」,只是画不出来,先用系统字体。
public enum PlayerTextFontSelection: Hashable, Sendable {
    case builtin(String)
    case imported(postScriptName: String)

    public static let importedPrefix = "imported:"

    /// 空串、只有前缀、名字里带换行或控制字符的都不认,交给调用方退回系统字体。
    public init?(rawValue: String) {
        if rawValue.hasPrefix(Self.importedPrefix) {
            let name = String(rawValue.dropFirst(Self.importedPrefix.count))
            guard Self.isUsablePostScriptName(name) else { return nil }
            self = .imported(postScriptName: name)
        } else {
            guard !rawValue.isEmpty else { return nil }
            self = .builtin(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case let .builtin(name): name
        case let .imported(postScriptName): Self.importedPrefix + postScriptName
        }
    }

    /// 能存进选中值的 PostScript 名:非空,不带换行与控制字符(读出来残缺的字体不列)。
    public static func isUsablePostScriptName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 255 else { return false }
        return !name.unicodeScalars.contains { scalar in
            CharacterSet.newlines.contains(scalar) || CharacterSet.controlCharacters.contains(scalar)
        }
    }

    /// CoreText 在字体的 PostScript 名缺失、含非 ASCII 字符或 MacRoman 乱码时，
    /// 会按当前秒级时间生成形如 `font0000000030b6595a` 的临时名，跨秒或重启即变。
    public static func isSyntheticCoreTextPostScriptName(_ name: String) -> Bool {
        guard name.count == 20, name.hasPrefix("font") else { return false }
        return name.dropFirst(4).unicodeScalars.allSatisfy { scalar in
            (0x30...0x39).contains(scalar.value)
                || (0x41...0x46).contains(scalar.value)
                || (0x61...0x66).contains(scalar.value)
        }
    }
}

/// 字体块上的样字用哪种文字写:中文字体写「字」,日文写「あ」,韩文写「가」,其余写 Aa。
public enum PlayerTextFontSampleScript: String, Hashable, Sendable {
    case han, kana, hangul, latin

    public var sample: String {
        switch self {
        case .han: "\u{5B57}"
        case .kana: "\u{3042}"
        case .hangul: "\u{AC00}"
        case .latin: "Aa"
        }
    }

    /// 导入的字体按它带的字形挑:有汉字就写「字」(日文、韩文字体带汉字的也一样),
    /// 没有汉字再看假名、谚文,都没有是西文字体。
    public static func preferred(coversHan: Bool, coversKana: Bool, coversHangul: Bool) -> Self {
        if coversHan { return .han }
        if coversKana { return .kana }
        if coversHangul { return .hangul }
        return .latin
    }
}

/// 导入的字体文件里的一个字体(.ttc 里有好几个)。名字都是 CoreText 读出来的,本地化的两项按这台设备的语言。
public struct ImportedFontFace: Hashable, Sendable {
    public var postScriptName: String
    /// 不本地化的家族名,分组认它。
    public var familyName: String
    public var localizedFamilyName: String?
    public var localizedDisplayName: String?
    /// CoreText 的字重,-1…1,0 是常规。
    public var weight: Double
    public var isItalic: Bool
    public var sampleScript: PlayerTextFontSampleScript
    /// 拷进 App 里以后的文件名。
    public var fileName: String
    public var importedAt: Date

    public init(
        postScriptName: String,
        familyName: String,
        localizedFamilyName: String? = nil,
        localizedDisplayName: String? = nil,
        weight: Double = 0,
        isItalic: Bool = false,
        sampleScript: PlayerTextFontSampleScript = .latin,
        fileName: String,
        importedAt: Date
    ) {
        self.postScriptName = postScriptName
        self.familyName = familyName
        self.localizedFamilyName = localizedFamilyName
        self.localizedDisplayName = localizedDisplayName
        self.weight = weight
        self.isItalic = isItalic
        self.sampleScript = sampleScript
        self.fileName = fileName
        self.importedAt = importedAt
    }
}

/// 选择器「我导入的」里的一项:一个家族一项,不管它的几种字重是一个文件还是分几次导入的。
public struct ImportedFontEntry: Hashable, Sendable, Identifiable {
    /// 选中时存的那一个(最接近常规体的直体);其余字重由系统按字重就近取。
    public var postScriptName: String
    public var title: String
    public var sampleScript: PlayerTextFontSampleScript
    public var memberPostScriptNames: [String]
    /// 删掉这一项要删的文件(同一个文件里别的家族也跟着删掉)。
    public var fileNames: [String]

    public var id: String { postScriptName }

    public init(
        postScriptName: String,
        title: String,
        sampleScript: PlayerTextFontSampleScript,
        memberPostScriptNames: [String],
        fileNames: [String]
    ) {
        self.postScriptName = postScriptName
        self.title = title
        self.sampleScript = sampleScript
        self.memberPostScriptNames = memberPostScriptNames
        self.fileNames = fileNames
    }

    public func contains(postScriptName name: String) -> Bool {
        memberPostScriptNames.contains(name)
    }
}

/// 导入字体的几条规则:哪些算重复、选择器里怎么列、叫什么名字、拷进来存成什么文件名。
public enum ImportedFontCatalogPolicy {
    public struct ResolvedFaceIdentity: Equatable, Sendable {
        public var postScriptName: String
        public var familyName: String
        public var localizedFamilyName: String?
        public var localizedDisplayName: String?

        public init(
            postScriptName: String,
            familyName: String,
            localizedFamilyName: String? = nil,
            localizedDisplayName: String? = nil
        ) {
            self.postScriptName = postScriptName
            self.familyName = familyName
            self.localizedFamilyName = localizedFamilyName
            self.localizedDisplayName = localizedDisplayName
        }
    }

    /// 同一字体集合同时包含普通字面与 `.` 开头私有系统字面时，跳过私有副本避免列表重复；
    /// 若整个文件只有 `.` 开头字面则全部保留。苹方集合同时包含港/台/简多个地区变体时优先排简体字面。
    public static func selectVisibleFaceIndices(postScriptNames: [String?]) -> [Int] {
        let nonPrivate = postScriptNames.indices.filter { index in
            guard let name = postScriptNames[index] else { return true }
            return !name.hasPrefix(".")
        }
        let selected = nonPrivate.isEmpty ? Array(postScriptNames.indices) : nonPrivate
        let hasPingFangSC = selected.contains { index in
            postScriptNames[index]?.lowercased().hasPrefix("pingfangsc") == true
        }
        guard hasPingFangSC else { return selected }
        return selected.filter { postScriptNames[$0]?.lowercased().hasPrefix("pingfangsc") == true }
            + selected.filter { postScriptNames[$0]?.lowercased().hasPrefix("pingfangsc") != true }
    }

    /// 部分魔改字库把各字重字面的 `OS/2 usWeightClass` 都留成了 400（CoreText 读出 0），
    /// 仅在 PostScript 名后缀保留字重词；当 CoreText 字重为 0 时按常见后缀补推。
    public static func resolvedWeight(coreTextWeight: Double, rawPostScriptName: String?) -> Double {
        guard abs(coreTextWeight) < 0.001, let raw = rawPostScriptName?.lowercased() else {
            return coreTextWeight
        }
        let tokens = raw.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        guard let tail = tokens.last else { return coreTextWeight }
        switch tail {
        case "ultralight", "extralight": return -0.8
        case "thin": return -0.6
        case "light": return -0.4
        case "regular", "normal", "book", "roman": return 0.0
        case "medium": return 0.23
        case "semibold", "demibold": return 0.3
        case "bold": return 0.4
        case "heavy", "extrabold": return 0.56
        case "black", "extrablack", "ultra": return 0.62
        default: return coreTextWeight
        }
    }

    /// 苹果系统私有或常被手机美化包借壳替换的系统字体标识（`.` 前缀与苹方家族）。
    public static func isSystemMaskedPostScriptName(_ name: String) -> Bool {
        if name.hasPrefix(".") { return true }
        let lower = name.lowercased()
        return lower.hasPrefix("pingfangsc-")
            || lower.hasPrefix("pingfangtc-")
            || lower.hasPrefix("pingfanghk-")
            || lower.hasPrefix("pingfangmo-")
            || lower == "pingfangsc"
            || lower == "pingfangtc"
            || lower == "pingfanghk"
            || lower == "pingfangmo"
    }

    public static func isSystemMaskedFamilyName(_ family: String) -> Bool {
        let trimmed = family.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(".") { return true }
        let lower = trimmed.lowercased()
        return lower == "pingfang sc"
            || lower == "pingfang tc"
            || lower == "pingfang hk"
            || lower == "pingfang mo"
            || lower == "苹方-简"
            || lower == "苹方-繁"
            || lower == "苹方-港"
            || lower == "苹方-澳"
            || lower == "蘋方-簡"
            || lower == "蘋方-繁"
            || lower == "蘋方-港"
            || lower == "蘋方-澳"
    }

    /// 为导入字面确定跨重启、跨设备一致的标识与归组信息：
    /// 常规有效 PostScript 名沿用原值；CoreText 动态合成名、缺失/非法名及系统借壳名
    /// 改用文件内容哈希 + 字面序号，并对借壳系统家族按文件隔离分组、优先以文件名展示。
    public static func resolveFaceIdentity(
        rawPostScriptName: String?,
        rawFamilyName: String,
        localizedFamilyName: String?,
        localizedDisplayName: String?,
        fileName: String,
        contentHashHex: String,
        faceIndex: Int
    ) -> ResolvedFaceIdentity? {
        let hashPrefix = String(contentHashHex.lowercased().prefix(16))
        let usableRawName: String? = rawPostScriptName.flatMap { name in
            PlayerTextFontSelection.isUsablePostScriptName(name) ? name : nil
        }
        let isSynthetic = usableRawName.map(PlayerTextFontSelection.isSyntheticCoreTextPostScriptName) ?? true
        let isMaskedPS = usableRawName.map(isSystemMaskedPostScriptName) ?? false
        let isMaskedFamily = isSystemMaskedFamilyName(rawFamilyName)
            || (localizedFamilyName.map(isSystemMaskedFamilyName) ?? false)

        let stableID: String
        if let usableRawName, !isSynthetic, !isMaskedPS {
            stableID = usableRawName
        } else {
            guard !hashPrefix.isEmpty else { return nil }
            stableID = "file-\(hashPrefix)-\(faceIndex)"
        }

        let stem = fileNameStem(for: fileName)
        let trimmedFamily = rawFamilyName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLocalizedFamily = localizedFamilyName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedLocalizedDisplay = localizedDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let scopedFamily: String
        let displayLocalizedFamily: String?
        let displayLocalizedFull: String?
        if isMaskedPS || isMaskedFamily, !hashPrefix.isEmpty {
            scopedFamily = "masked#\(hashPrefix)"
            displayLocalizedFamily = stem.isEmpty ? localizedFamilyName : stem
            displayLocalizedFull = stem.isEmpty ? localizedDisplayName : stem
        } else {
            scopedFamily = rawFamilyName
            if isSynthetic, trimmedLocalizedFamily.isEmpty, trimmedFamily.isEmpty, trimmedLocalizedDisplay.isEmpty, !stem.isEmpty {
                displayLocalizedFamily = stem
            } else {
                displayLocalizedFamily = localizedFamilyName
            }
            displayLocalizedFull = localizedDisplayName
        }

        return ResolvedFaceIdentity(
            postScriptName: stableID,
            familyName: scopedFamily,
            localizedFamilyName: displayLocalizedFamily,
            localizedDisplayName: displayLocalizedFull
        )
    }

    /// 在同一导入家族的已加载字面中按字重就近择面，优先直体，避免交由系统按家族名重查。
    public static func matchingFace(
        in faces: [ImportedFontFace],
        targetWeight: Double,
        preferItalic: Bool = false
    ) -> ImportedFontFace? {
        faces.enumerated().min { lhs, rhs in
            let lhsItalicMismatch = lhs.element.isItalic != preferItalic
            let rhsItalicMismatch = rhs.element.isItalic != preferItalic
            if lhsItalicMismatch != rhsItalicMismatch { return !lhsItalicMismatch }
            let lhsDistance = abs(lhs.element.weight - targetWeight)
            let rhsDistance = abs(rhs.element.weight - targetWeight)
            if abs(lhsDistance - rhsDistance) > 0.0001 { return lhsDistance < rhsDistance }
            return lhs.offset < rhs.offset
        }?.element
    }

    /// 这个文件里还没导入过的字体(同一文件里重名的也只留一个)。空数组 = 整个文件都导入过了。
    public static func addedFaces(
        _ faces: [ImportedFontFace],
        existingPostScriptNames: Set<String>
    ) -> [ImportedFontFace] {
        var seen = existingPostScriptNames
        return faces.filter { seen.insert($0.postScriptName).inserted }
    }

    /// 选择器里的条目:先导入的排前面;同一家族并成一项,代表字体取直体里字重最接近常规的那个;
    /// PostScript 名重复的只认先导入的那份。两个家族叫同一个名字时在名字后面带上 PostScript 名区分。
    public static func entries(from faces: [ImportedFontFace]) -> [ImportedFontEntry] {
        let ordered = faces.enumerated().sorted { lhs, rhs in
            if lhs.element.importedAt != rhs.element.importedAt {
                return lhs.element.importedAt < rhs.element.importedAt
            }
            if lhs.element.fileName != rhs.element.fileName {
                return lhs.element.fileName < rhs.element.fileName
            }
            return lhs.offset < rhs.offset
        }.map(\.element)

        var groupOrder: [String] = []
        var members: [String: [ImportedFontFace]] = [:]
        var files: [String: [String]] = [:]
        var claimedNames = Set<String>()
        for face in ordered {
            let key = familyKey(for: face)
            if members[key] == nil {
                groupOrder.append(key)
                members[key] = []
                files[key] = []
            }
            if !(files[key] ?? []).contains(face.fileName) {
                files[key, default: []].append(face.fileName)
            }
            if claimedNames.insert(face.postScriptName).inserted {
                members[key, default: []].append(face)
            }
        }

        var entries: [ImportedFontEntry] = groupOrder.compactMap { key in
            guard let group = members[key], let representative = representative(of: group) else { return nil }
            return ImportedFontEntry(
                postScriptName: representative.postScriptName,
                title: title(for: representative),
                sampleScript: representative.sampleScript,
                memberPostScriptNames: group.map(\.postScriptName),
                fileNames: files[key] ?? []
            )
        }

        var titleCounts: [String: Int] = [:]
        for entry in entries {
            titleCounts[entry.title.lowercased(), default: 0] += 1
        }
        for index in entries.indices where (titleCounts[entries[index].title.lowercased()] ?? 0) > 1 {
            entries[index].title += " \u{00B7} " + entries[index].postScriptName
        }
        return entries
    }

    /// 显示名:本地化的家族名,其次家族名、本地化的完整名,都没有时用 PostScript 名。
    public static func title(for face: ImportedFontFace) -> String {
        let candidates = [face.localizedFamilyName, face.familyName, face.localizedDisplayName, face.postScriptName]
        for candidate in candidates {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return face.postScriptName
    }

    /// 拷进字体目录时用的文件名:照原名,只取最后一段;和已有的撞名(不分大小写)时在扩展名前加「 2」「 3」。
    public static func storedFileName(for originalName: String, existing: Set<String>) -> String {
        let lastComponent = originalName
            .split(whereSeparator: { $0 == "/" || $0 == "\\" })
            .last
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = lastComponent.isEmpty || lastComponent.hasPrefix(".") ? "font" + lastComponent : lastComponent
        let taken = Set(existing.map { $0.lowercased() })
        guard taken.contains(name.lowercased()) else { return name }

        let base: String
        let suffix: String
        if let dot = name.lastIndex(of: "."), dot != name.startIndex {
            base = String(name[..<dot])
            suffix = String(name[dot...])
        } else {
            base = name
            suffix = ""
        }
        var counter = 2
        while taken.contains("\(base) \(counter)\(suffix)".lowercased()) {
            counter += 1
        }
        return "\(base) \(counter)\(suffix)"
    }

    private static func fileNameStem(for fileName: String) -> String {
        let last = fileName
            .split(whereSeparator: { $0 == "/" || $0 == "\\" })
            .last
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !last.isEmpty else { return "" }
        if let dot = last.lastIndex(of: "."), dot != last.startIndex {
            return String(last[..<dot]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return last
    }

    private static func familyKey(for face: ImportedFontFace) -> String {
        let family = face.familyName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return family.isEmpty ? "postscript:" + face.postScriptName : "family:" + family
    }

    private static func representative(of group: [ImportedFontFace]) -> ImportedFontFace? {
        group.enumerated().min { lhs, rhs in
            if lhs.element.isItalic != rhs.element.isItalic { return !lhs.element.isItalic }
            let lhsDistance = abs(lhs.element.weight)
            let rhsDistance = abs(rhs.element.weight)
            if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
            return lhs.offset < rhs.offset
        }?.element
    }
}
