import Foundation

/// One grouping key for every place that turns an artist name into an
/// identity. Case, diacritics, character width and runs of whitespace do not
/// make a different artist; the same folding already decides whether two names
/// inside one track are the same contributor.
public enum ArtistIdentityPolicy {
    public static func groupingKey(_ name: String) -> String {
        name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: foldingLocale
            )
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// 整库装载时每首歌要算好几次，区域设置不每次现建。
    private static let foldingLocale = Locale(identifier: "en_US_POSIX")

    /// Key used by earlier releases (lowercasing only). Persisted state that is
    /// addressed by an artist ID — artwork overrides, quick-access pins — is
    /// re-keyed from this once the new IDs exist.
    public static func legacyGroupingKey(_ name: String) -> String {
        name.lowercased()
    }
}

/// 「群星」「Various Artists」「未知艺术家」这类署名不是哪一位艺人:合辑和没署名的歌常这么填。
/// 听歌排行与年度报告里的艺人榜、艺人数、前五位占比都不把它当成一位艺人。
public enum PlaceholderArtistPolicy {
    public static func isPlaceholder(_ name: String) -> Bool {
        let key = compactKey(name)
        guard !key.isEmpty else { return false }
        if placeholderKeys.contains(key) { return true }
        // 「华语群星」「欧美群星」这类按地区、厂牌分的合辑署名。
        return key.count <= 6 && (key.hasSuffix("群星") || key.hasSuffix("羣星"))
    }

    /// 只留字母、数字和附加符号,大小写、全半角、变音符号不论:
    /// 「V.A.」「Various  Artists」「ＶＡＲＩＯＵＳ ＡＲＴＩＳＴＳ」是同一种写法。
    static func compactKey(_ name: String) -> String {
        let folded = name.precomposedStringWithCanonicalMapping.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: foldingLocale
        )
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
        return String(scalars)
    }

    private static let foldingLocale = Locale(identifier: "en_US_POSIX")

    /// 各语言里「群星 / 多位艺人 / 未知艺人」的常见写法,包括各家播放器与音乐商店的译名。
    private static let placeholderKeys: Set<String> = Set([
        "群星", "羣星", "多位艺术家", "多位藝術家", "多位艺人", "多位藝人",
        "未知", "未知艺术家", "未知藝術家", "未知艺人", "未知藝人", "未知歌手", "佚名",
        "Various Artists", "Various", "VA", "Unknown Artist", "Unknown",
        "ヴァリアス・アーティスト", "オムニバス", "不明なアーティスト",
        "여러 아티스트", "알 수 없는 아티스트",
        "Verschiedene Interpreten", "Verschiedene Künstler", "Unbekannter Künstler",
        "Artistes divers", "Artistes variés", "Multi-interprètes", "Artiste inconnu",
        "Varios artistas", "Varios intérpretes", "Artista desconocido",
        "Vários artistas", "Vários intérpretes", "Artista desconhecido",
        "Artisti vari", "AA.VV.", "Artista sconosciuto",
        "Różni wykonawcy", "Nieznany wykonawca",
        "Разные исполнители", "Различные исполнители", "Неизвестный исполнитель",
        "Різні виконавці", "Невідомий виконавець",
        "Çeşitli Sanatçılar", "Bilinmeyen Sanatçı",
        "ศิลปินหลากหลาย", "विभिन्न कलाकार",
    ].map(compactKey))
}

/// 播放页「点歌手进作品列表」:把这首歌的艺人名对到曲库里的艺人。
///
/// 先用曲库自己的拆分(用户设置的分隔符)得到的名字;某个名字在曲库里找不到时,再按
/// `&`、`feat.`、`ft.`、`×`、逗号这类只出现在展示里的写法拆一次试各段。只影响链接查找,
/// 不改扫描时的拆分口径 —— 那会改动艺人 id。
public enum ArtistLinkResolutionPolicy {
    private static let fallbackSeparators = [
        " & ", " feat. ", " feat ", " ft. ", " ft ", " featuring ", " with ", " x ", " × ", "×", "，", ", ",
    ]

    public static func linkCandidates(for names: [String], resolves: (String) -> Bool) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        func append(_ name: String) {
            let key = ArtistIdentityPolicy.groupingKey(name)
            guard !key.isEmpty, seen.insert(key).inserted else { return }
            result.append(name)
        }
        for name in names {
            if resolves(name) {
                append(name)
                continue
            }
            for piece in fallbackPieces(of: name) where resolves(piece) {
                append(piece)
            }
        }
        return result
    }

    /// 按展示用的连接写法拆开(不区分大小写),去掉空段。
    public static func fallbackPieces(of name: String) -> [String] {
        var pieces = [name]
        for separator in fallbackSeparators {
            pieces = pieces.flatMap { piece in
                piece.components(separatedBy: separator, caseInsensitive: true)
            }
        }
        return pieces
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

private extension String {
    func components(separatedBy separator: String, caseInsensitive: Bool) -> [String] {
        guard caseInsensitive else { return components(separatedBy: separator) }
        var parts: [String] = []
        var remainder = self[...]
        while let range = remainder.range(of: separator, options: .caseInsensitive) {
            parts.append(String(remainder[..<range.lowerBound]))
            remainder = remainder[range.upperBound...]
        }
        parts.append(String(remainder))
        return parts
    }
}
