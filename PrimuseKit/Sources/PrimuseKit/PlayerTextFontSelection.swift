import Foundation

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
