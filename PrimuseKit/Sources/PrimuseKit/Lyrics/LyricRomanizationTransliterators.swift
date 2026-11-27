import Foundation

// MARK: - 韩文：国语罗马字（文化观光部 2000 年式）

/// 谚文按实际发音转成国语罗马字。音节拆成初声、中声、终声，在同一个词（连续的谚文音节）
/// 里处理主要音变：连音、鼻音化、流音化、ㅎ 的激音化与脱落、ㄷ/ㅌ + 이 的腭化、终声代表音。
/// 紧音化按规定不写出来（학교 → hakgyo）。不是谚文的字符原样保留。
public enum KoreanRevisedRomanization {
    public static func romanize(_ text: String) -> String {
        var output = ""
        var word: [Syllable] = []
        func flush() {
            guard !word.isEmpty else { return }
            output += render(word)
            word.removeAll(keepingCapacity: true)
        }
        for scalar in text.unicodeScalars {
            if let syllable = Syllable(scalar) {
                word.append(syllable)
                continue
            }
            flush()
            if let jamo = compatibilityJamo[scalar.value] {
                output += jamo
            } else {
                output.unicodeScalars.append(scalar)
            }
        }
        flush()
        return output
    }

    /// 基本辅音。双收尾（ㄳ、ㄺ……）拆成两个基本辅音存。
    enum Consonant: Equatable {
        case g, kk, n, d, tt, r, m, b, pp, s, ss, j, jj, ch, k, t, p, h, ng

        var onsetLatin: String {
            switch self {
            case .g: "g"
            case .kk: "kk"
            case .n: "n"
            case .d: "d"
            case .tt: "tt"
            case .r: "r"
            case .m: "m"
            case .b: "b"
            case .pp: "pp"
            case .s: "s"
            case .ss: "ss"
            case .j: "j"
            case .jj: "jj"
            case .ch: "ch"
            case .k: "k"
            case .t: "t"
            case .p: "p"
            case .h: "h"
            case .ng: ""
            }
        }

        /// 终声的七个代表音。
        var representative: Consonant {
            switch self {
            case .g, .kk, .k: .g
            case .n: .n
            case .d, .s, .ss, .j, .ch, .t, .h, .tt, .jj: .d
            case .r: .r
            case .m: .m
            case .b, .p, .pp: .b
            case .ng: .ng
            }
        }

        var codaLatin: String {
            switch representative {
            case .g: "k"
            case .n: "n"
            case .d: "t"
            case .r: "l"
            case .m: "m"
            case .b: "p"
            case .ng: "ng"
            default: ""
            }
        }
    }

    struct Syllable {
        /// nil 表示初声是不发音的 ㅇ。
        var onset: Consonant?
        var vowel: Int
        var coda: [Consonant]

        init?(_ scalar: Unicode.Scalar) {
            guard (0xAC00...0xD7A3).contains(scalar.value) else { return nil }
            let index = Int(scalar.value - 0xAC00)
            let initial = index / (21 * 28)
            vowel = (index % (21 * 28)) / 28
            let final = index % 28
            onset = Self.initials[initial]
            coda = Self.finals[final]
        }

        static let initials: [Consonant?] = [
            .g, .kk, .n, .d, .tt, .r, .m, .b, .pp, .s, .ss, nil, .j, .jj, .ch, .k, .t, .p, .h,
        ]

        static let finals: [[Consonant]] = [
            [], [.g], [.kk], [.g, .s], [.n], [.n, .j], [.n, .h], [.d], [.r], [.r, .g], [.r, .m],
            [.r, .b], [.r, .s], [.r, .t], [.r, .p], [.r, .h], [.m], [.b], [.b, .s], [.s], [.ss],
            [.ng], [.j], [.ch], [.k], [.t], [.p], [.h],
        ]
    }

    static let vowels = [
        "a", "ae", "ya", "yae", "eo", "e", "yeo", "ye", "o", "wa", "wae",
        "oe", "yo", "u", "wo", "we", "wi", "yu", "eu", "ui", "i",
    ]

    /// 中声 ㅣ 的序号（腭化只发生在 이/히 前）。
    private static let vowelI = 20

    /// 单独出现的兼容字母（ㅋㅋ、ㅠㅠ）。
    static let compatibilityJamo: [UInt32: String] = {
        let consonants: [(UInt32, String)] = [
            (0x3131, "g"), (0x3132, "kk"), (0x3134, "n"), (0x3137, "d"), (0x3138, "tt"),
            (0x3139, "r"), (0x3141, "m"), (0x3142, "b"), (0x3143, "pp"), (0x3145, "s"),
            (0x3146, "ss"), (0x3147, "ng"), (0x3148, "j"), (0x3149, "jj"), (0x314A, "ch"),
            (0x314B, "k"), (0x314C, "t"), (0x314D, "p"), (0x314E, "h"),
        ]
        var table = Dictionary(uniqueKeysWithValues: consonants)
        for (offset, latin) in vowels.enumerated() {
            table[0x314F + UInt32(offset)] = latin
        }
        return table
    }()

    /// 一个词里的音节先逐个处理相邻两个音节之间的音变，再拼出罗马字。
    static func render(_ input: [Syllable]) -> String {
        var syllables = input
        for index in syllables.indices.dropLast() {
            var coda = syllables[index].coda
            var onset = syllables[index + 1].onset
            resolveBoundary(coda: &coda, onset: &onset, nextVowel: syllables[index + 1].vowel)
            syllables[index].coda = coda
            syllables[index + 1].onset = onset
        }

        var output = ""
        var previousCoda: Consonant?
        for syllable in syllables {
            if let onset = syllable.onset {
                // ㄹㄹ 写作 ll。
                output += onset == .r && previousCoda == .r ? "l" : onset.onsetLatin
            }
            output += vowels[syllable.vowel]
            let coda = codaSound(syllable.coda)
            if let coda { output += coda.codaLatin }
            previousCoda = coda
        }
        return output
    }

    /// 双收尾在辅音前（或词尾）读哪一个：ㄺ、ㄻ、ㄿ 读后一个，其余读前一个。
    static func codaSound(_ coda: [Consonant]) -> Consonant? {
        guard let first = coda.first else { return nil }
        guard coda.count == 2 else { return first.representative }
        switch (coda[0], coda[1]) {
        case (.r, .g), (.r, .m), (.r, .p): return coda[1].representative
        default: return first.representative
        }
    }

    static func resolveBoundary(coda: inout [Consonant], onset: inout Consonant?, nextVowel: Int) {
        guard !coda.isEmpty else { return }

        // 后一个音节以元音开头：ㅎ 脱落，其余收尾移到后面（连音），ㄷ/ㅌ + 이 腭化。
        // 收尾 ㅇ 不移（사랑이 → sarangi）。
        guard let next = onset else {
            if coda == [.ng] { return }
            if coda.last == .h { coda.removeLast() }
            guard let last = coda.last else { return }
            coda.removeLast()
            if nextVowel == vowelI, last == .d {
                onset = .j
            } else if nextVowel == vowelI, last == .t {
                onset = .ch
            } else {
                onset = last
            }
            return
        }

        // 收尾 ㅎ：ㄱ/ㄷ/ㅈ 前变激音，ㅅ 前变紧音，ㄴ 前读 ㄴ。
        if coda.last == .h {
            switch next {
            case .g: onset = .k; coda.removeLast(); return
            case .d: onset = .t; coda.removeLast(); return
            case .j: onset = .ch; coda.removeLast(); return
            case .s: onset = .ss; coda.removeLast(); return
            case .n:
                coda.removeLast()
                if coda.isEmpty { coda = [.n] }
            default:
                coda.removeLast()
                if coda.isEmpty { return }
            }
        }

        // 后面是 ㅎ：前面的 ㄱ/ㄷ/ㅂ/ㅈ（含双收尾里的那一个）合成激音。
        if next == .h, let last = coda.last {
            var aspirated: Consonant?
            switch last {
            case .g, .kk, .k: aspirated = .k
            case .d, .s, .ss, .t: aspirated = nextVowel == vowelI && (last == .d || last == .t) ? .ch : .t
            case .j, .ch: aspirated = .ch
            case .b, .p: aspirated = .p
            default: aspirated = nil
            }
            if let aspirated {
                coda.removeLast()
                onset = aspirated
                return
            }
        }

        guard let sound = codaSound(coda) else { return }
        // 辅音前只剩代表音。
        coda = [sound]

        switch next {
        case .r:
            switch sound {
            case .m, .ng: onset = .n                    // 심리 → 심니
            case .g: coda = [.ng]; onset = .n           // 국력 → 궁녁
            case .b: coda = [.m]; onset = .n            // 협력 → 혐녁
            case .d: coda = [.n]; onset = .n
            case .n: coda = [.r]                        // 신라 → 실라
            default: break
            }
        case .n, .m:
            switch sound {
            case .g: coda = [.ng]                       // 국물 → 궁물
            case .d: coda = [.n]                        // 믿는 → 민는
            case .b: coda = [.m]                        // 십년 → 심년
            case .r where next == .n: onset = .r        // 설날 → 설랄
            default: break
            }
        default:
            break
        }
    }
}

// MARK: - 印地文（天城文）

/// 天城文按印地语的读法转成拉丁字母：长元音带长音符号（ā ī ū），辅音用不带下加点的常用写法
/// （ट t、श sh、च ch、छ chh），送气音写 h，nukta 字母写 q z f r。会做 schwa 省略：词尾辅音
/// 的固有 a 不读（单个辅音成词、或者词尾是以 र/य/व 收尾的复辅音时保留，如 मित्र mitra）；
/// 词中按 V C _ C V 从右往左省，省了会连出三个辅音的不省。不是天城文的字符原样保留。
public enum HindiLyricTransliteration {
    public static func romanize(_ text: String) -> String {
        var output = ""
        var word: [Unicode.Scalar] = []
        func flush() {
            guard !word.isEmpty else { return }
            output += romanizeWord(word)
            word.removeAll(keepingCapacity: true)
        }
        for scalar in text.unicodeScalars {
            if isWordScalar(scalar) {
                word.append(scalar)
                continue
            }
            flush()
            if let mapped = punctuation[scalar.value] {
                output += mapped
            } else {
                output.unicodeScalars.append(scalar)
            }
        }
        flush()
        return output
    }

    private static let virama: UInt32 = 0x094D
    private static let nukta: UInt32 = 0x093C
    private static let anusvara: UInt32 = 0x0902
    private static let chandrabindu: UInt32 = 0x0901
    private static let visarga: UInt32 = 0x0903

    static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0900...0x0963, 0x0971...0x097F, 0x200C, 0x200D: return true
        default: return false
        }
    }

    static let consonants: [UInt32: String] = [
        0x0915: "k", 0x0916: "kh", 0x0917: "g", 0x0918: "gh", 0x0919: "n",
        0x091A: "ch", 0x091B: "chh", 0x091C: "j", 0x091D: "jh", 0x091E: "n",
        0x091F: "t", 0x0920: "th", 0x0921: "d", 0x0922: "dh", 0x0923: "n",
        0x0924: "t", 0x0925: "th", 0x0926: "d", 0x0927: "dh", 0x0928: "n", 0x0929: "n",
        0x092A: "p", 0x092B: "ph", 0x092C: "b", 0x092D: "bh", 0x092E: "m",
        0x092F: "y", 0x0930: "r", 0x0931: "r", 0x0932: "l", 0x0933: "l", 0x0934: "l", 0x0935: "v",
        0x0936: "sh", 0x0937: "sh", 0x0938: "s", 0x0939: "h",
        // 预组合的 nukta 字母
        0x0958: "q", 0x0959: "kh", 0x095A: "gh", 0x095B: "z", 0x095C: "r", 0x095D: "rh",
        0x095E: "f", 0x095F: "y",
    ]

    /// 辅音后跟 nukta（़）时的读法。
    static let nuktaForms: [UInt32: String] = [
        0x0915: "q", 0x0916: "kh", 0x0917: "gh", 0x091C: "z", 0x0921: "r", 0x0922: "rh",
        0x092B: "f", 0x092F: "y",
    ]

    static let independentVowels: [UInt32: String] = [
        0x0905: "a", 0x0906: "ā", 0x0907: "i", 0x0908: "ī", 0x0909: "u", 0x090A: "ū",
        0x090B: "ri", 0x0960: "rī", 0x090C: "li", 0x090D: "e", 0x090F: "e", 0x0910: "ai",
        0x0911: "o", 0x0913: "o", 0x0914: "au", 0x0972: "a",
    ]

    static let vowelSigns: [UInt32: String] = [
        0x093E: "ā", 0x093F: "i", 0x0940: "ī", 0x0941: "u", 0x0942: "ū", 0x0943: "ri",
        0x0944: "rī", 0x0962: "li", 0x0945: "e", 0x0947: "e", 0x0948: "ai", 0x0949: "o",
        0x094B: "o", 0x094C: "au",
    ]

    static let punctuation: [UInt32: String] = {
        var table: [UInt32: String] = [0x0964: ".", 0x0965: ".", 0x0970: "."]
        for digit in 0...9 { table[0x0966 + UInt32(digit)] = String(digit) }
        return table
    }()

    /// 唇音（प फ ब भ म）前的 anusvara 读 m。
    private static let labials: Set<UInt32> = [0x092A, 0x092B, 0x092C, 0x092D, 0x092E, 0x095E]

    /// 词尾复辅音以这些收尾时保留末尾的 a（मित्र mitra、सूर्य sūrya）；其余复辅音不保留（दोस्त dost）。
    private static let finalClusterKeepsSchwa: Set<String> = ["r", "y", "v"]

    struct Unit {
        enum Kind { case consonant, vowel, anusvara, chandrabindu, visarga }
        var kind: Kind
        var text: String
        var scalar: UInt32 = 0
        /// 固有元音 a（可以省略）。
        var isSchwa = false
        /// 和前一个辅音由 virama 连成复辅音。
        var joined = false
        var deleted = false
    }

    static func romanizeWord(_ scalars: [Unicode.Scalar]) -> String {
        var units: [Unit] = []
        var afterVirama = false
        var index = 0
        while index < scalars.count {
            let value = scalars[index].value
            if var latin = consonants[value] {
                var next = index + 1
                if next < scalars.count, scalars[next].value == nukta {
                    latin = nuktaForms[value] ?? latin
                    next += 1
                }
                var unit = Unit(kind: .consonant, text: latin, scalar: value, joined: afterVirama)
                // ज्ञ 读 gy。
                if value == 0x091E, afterVirama,
                   let previous = units.lastIndex(where: { $0.kind == .consonant }),
                   units[previous].scalar == 0x091C {
                    units[previous].text = "g"
                    unit.text = "y"
                }
                units.append(unit)
                afterVirama = false
                // 跳过零宽连接符。
                while next < scalars.count, scalars[next].value == 0x200C || scalars[next].value == 0x200D {
                    next += 1
                }
                if next < scalars.count, let sign = vowelSigns[scalars[next].value] {
                    units.append(Unit(kind: .vowel, text: sign))
                    next += 1
                } else if next < scalars.count, scalars[next].value == virama {
                    afterVirama = true
                    next += 1
                } else {
                    units.append(Unit(kind: .vowel, text: "a", isSchwa: true))
                }
                index = next
                continue
            }
            afterVirama = false
            if let vowel = independentVowels[value] {
                units.append(Unit(kind: .vowel, text: vowel))
            } else if value == anusvara {
                units.append(Unit(kind: .anusvara, text: "n"))
            } else if value == chandrabindu {
                units.append(Unit(kind: .chandrabindu, text: "n"))
            } else if value == visarga {
                units.append(Unit(kind: .visarga, text: "h"))
            } else if value == 0x0950 {
                units.append(Unit(kind: .vowel, text: "om"))
            } else if let mapped = punctuation[value] {
                units.append(Unit(kind: .vowel, text: mapped))
            }
            index += 1
        }

        deleteSchwas(&units)

        var output = ""
        for (position, unit) in units.enumerated() where !unit.deleted {
            if unit.kind == .anusvara {
                let next = units[(position + 1)...].first { !$0.deleted }
                output += next.map { $0.kind == .consonant && labials.contains($0.scalar) } == true ? "m" : "n"
            } else {
                output += unit.text
            }
        }
        return output
    }

    static func deleteSchwas(_ units: inout [Unit]) {
        func isVowel(_ index: Int) -> Bool {
            units.indices.contains(index) && units[index].kind == .vowel && !units[index].deleted
        }
        func isConsonant(_ index: Int) -> Bool {
            units.indices.contains(index) && units[index].kind == .consonant
        }
        /// 往左找元音时跳过 chandrabindu（它只是让元音带鼻音），anusvara 算辅音。
        func vowelBefore(_ index: Int) -> Bool {
            var cursor = index
            while units.indices.contains(cursor), units[cursor].kind == .chandrabindu { cursor -= 1 }
            return isVowel(cursor)
        }

        // 词尾的固有 a。
        if let last = units.indices.last, units[last].isSchwa {
            let otherVowels = units.indices.contains { $0 != last && units[$0].kind == .vowel }
            let previous = last - 1
            let keepsForCluster = isConsonant(previous) && units[previous].joined
                && finalClusterKeepsSchwa.contains(units[previous].text)
            if otherVowels, !keepsForCluster {
                units[last].deleted = true
            }
        }

        // 词中：V C _ C V，从右往左。
        var index = units.count - 1
        while index >= 0 {
            if units[index].isSchwa, !units[index].deleted,
               isConsonant(index - 1), vowelBefore(index - 2),
               isConsonant(index + 1), isVowel(index + 2) {
                units[index].deleted = true
            }
            index -= 1
        }
    }
}

// MARK: - 俄文、乌克兰文

/// 俄文按 BGN/PCGN 风格的常用写法（ё yo、й y、ы y、х kh、ц ts、щ shch，ъ ь 不写），乌克兰文按
/// 乌克兰 2010 年官方拉丁转写（г h、ґ g、и y、і i；є ї й ю я 在词首写 ye yi y yu ya、词中写
/// ie i i iu ia；зг 写 zgh；ь 和撇号不写）。保留大小写：全大写的词整词大写，否则只大写首字母。
public enum CyrillicLyricTransliteration {
    /// 整首歌出现乌克兰文特有的字母（і ї є ґ）就按乌克兰文。
    public static func isUkrainian(_ texts: [String]) -> Bool {
        texts.contains { text in text.unicodeScalars.contains { ukrainianLetters.contains($0.value) } }
    }

    public static func romanizeRussian(_ text: String) -> String {
        transliterate(text) { lower, _, _ in russian[lower] }
    }

    public static func romanizeUkrainian(_ text: String) -> String {
        transliterate(text) { lower, isWordInitial, previous in
            switch lower {
            case "є": return isWordInitial ? "ye" : "ie"
            case "ї": return isWordInitial ? "yi" : "i"
            case "й": return isWordInitial ? "y" : "i"
            case "ю": return isWordInitial ? "yu" : "iu"
            case "я": return isWordInitial ? "ya" : "ia"
            case "г": return previous == "з" ? "gh" : "h"
            default: return ukrainian[lower]
            }
        }
    }

    private static let ukrainianLetters: Set<UInt32> = [
        0x0456, 0x0406, 0x0457, 0x0407, 0x0454, 0x0404, 0x0491, 0x0490,
    ]

    private static let apostrophes: Set<Character> = ["'", "\u{2019}", "\u{02BC}", "\u{2018}"]

    static let russian: [Character: String] = [
        "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ё": "yo", "ж": "zh",
        "з": "z", "и": "i", "й": "y", "к": "k", "л": "l", "м": "m", "н": "n", "о": "o",
        "п": "p", "р": "r", "с": "s", "т": "t", "у": "u", "ф": "f", "х": "kh", "ц": "ts",
        "ч": "ch", "ш": "sh", "щ": "shch", "ъ": "", "ы": "y", "ь": "", "э": "e", "ю": "yu",
        "я": "ya",
    ]

    static let ukrainian: [Character: String] = [
        "а": "a", "б": "b", "в": "v", "ґ": "g", "д": "d", "е": "e", "ж": "zh", "з": "z",
        "и": "y", "і": "i", "к": "k", "л": "l", "м": "m", "н": "n", "о": "o", "п": "p",
        "р": "r", "с": "s", "т": "t", "у": "u", "ф": "f", "х": "kh", "ц": "ts", "ч": "ch",
        "ш": "sh", "щ": "shch", "ь": "",
        // 乌克兰歌词里偶尔夹着俄文字母。
        "ё": "yo", "ы": "y", "э": "e", "ъ": "",
    ]

    private static func isCyrillicLetter(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        return (0x0400...0x052F).contains(scalar.value) && character.isLetter
    }

    /// 按词处理：`map(小写字母, 是否词首, 词里前一个小写字母)` 给出转写，nil 表示原样保留。
    private static func transliterate(
        _ text: String,
        map: (Character, Bool, Character?) -> String?
    ) -> String {
        let characters = Array(text)
        var output = ""
        var index = 0
        while index < characters.count {
            guard isCyrillicLetter(characters[index]) else {
                output.append(characters[index])
                index += 1
                continue
            }
            // 一个词：连续的西里尔字母，词中的撇号也算在里面（м'ясо）。
            var end = index
            while end < characters.count {
                if isCyrillicLetter(characters[end]) {
                    end += 1
                } else if apostrophes.contains(characters[end]),
                          end + 1 < characters.count, isCyrillicLetter(characters[end + 1]) {
                    end += 1
                } else {
                    break
                }
            }
            let word = Array(characters[index..<end])
            let letters = word.filter(isCyrillicLetter)
            let isAllCaps = letters.count > 1 && letters.allSatisfy { $0.isUppercase }
            var previous: Character?
            var isWordInitial = true
            for character in word {
                if apostrophes.contains(character) {
                    // 撇号不写，后面的字母也不算词首。
                    continue
                }
                let lower = character.lowercased().first ?? character
                guard let latin = map(lower, isWordInitial, previous) else {
                    output.append(character)
                    previous = lower
                    isWordInitial = false
                    continue
                }
                if character.isUppercase, !latin.isEmpty {
                    output += isAllCaps ? latin.uppercased() : latin.prefix(1).uppercased() + latin.dropFirst()
                } else {
                    output += latin
                }
                previous = lower
                isWordInitial = false
            }
            index = end
        }
        return output
    }
}

// MARK: - 日文：分词读音拼成罗马字

/// 本机日文罗马音的拼装：分词器给出每个词的读音（拉丁转写），这里负责词间空格、
/// 助词 は/へ/を 读作 wa/e/o、日文标点换成拉丁标点。分词与取读音在 App 层做。
public enum JapaneseRomajiAssembler {
    public enum Piece: Equatable, Sendable {
        /// 一个词：原文与读音。没有读音（拉丁字母、数字、符号）时照原文。
        case word(surface: String, reading: String?)
        /// 词与词之间分词器没覆盖到的文字：空白、标点。
        case gap(String)
    }

    public static func assemble(_ pieces: [Piece]) -> String {
        var tokens: [String] = []
        for piece in pieces {
            switch piece {
            case .word(let surface, let reading):
                tokens.append(romaji(surface: surface, reading: reading))
            case .gap(let text):
                tokens.append(contentsOf: RomanizedPunctuation.tokens(in: text))
            }
        }
        return RomanizedPunctuation.join(tokens)
    }

    /// 单独成词的助词按发音写；带在词尾的 では/には/とは（分词器常把它们并成一个词）同理。
    static func romaji(surface: String, reading: String?) -> String {
        if let fixed = particleReadings[surface] { return fixed }
        guard let reading = reading?.trimmingCharacters(in: .whitespacesAndNewlines),
              !reading.isEmpty else {
            return RomanizedPunctuation.latinized(surface)
        }
        var latin = reading.lowercased()
        if surface.count >= 2, surface.hasSuffix("は"),
           particlePrefixes.contains(String(surface.dropLast())),
           latin.hasSuffix("ha") {
            latin = String(latin.dropLast(2)) + "wa"
        }
        return latin
    }

    static let particleReadings: [String: String] = [
        "は": "wa", "へ": "e", "を": "o",
        "こんにちは": "konnichiwa", "こんばんは": "konbanwa",
    ]

    static let particlePrefixes: Set<String> = ["で", "に", "と", "から", "まで", "より", "へ", "では", "には"]
}

// MARK: - 中文：分词拼音

/// 本机中文拼音的拼装：分词器给出每个词的带声调拼音，词内音节连写（a/o/e 开头的音节
/// 前加隔音符号 '），词与词之间空一格，中文标点换成拉丁标点。
public enum PinyinWordAssembler {
    public enum Piece: Equatable, Sendable {
        case word(surface: String, reading: String?)
        case gap(String)
    }

    public static func assemble(_ pieces: [Piece]) -> String {
        var tokens: [String] = []
        for piece in pieces {
            switch piece {
            case .word(let surface, let reading):
                guard let reading = reading?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !reading.isEmpty else {
                    tokens.append(RomanizedPunctuation.latinized(surface))
                    continue
                }
                tokens.append(joinedSyllables(reading.lowercased()))
            case .gap(let text):
                tokens.append(contentsOf: RomanizedPunctuation.tokens(in: text))
            }
        }
        return RomanizedPunctuation.join(tokens)
    }

    /// 「tiān ān mén」→「tiān'ānmén」。
    static func joinedSyllables(_ reading: String) -> String {
        let syllables = reading.split(whereSeparator: \.isWhitespace).map(String.init)
        guard syllables.count > 1 else { return syllables.first ?? reading }
        var output = syllables[0]
        for syllable in syllables.dropFirst() {
            if let first = syllable.unicodeScalars.first,
               let base = String(first).decomposedStringWithCanonicalMapping.unicodeScalars.first,
               "aoe".unicodeScalars.contains(base) {
                output += "'"
            }
            output += syllable
        }
        return output
    }
}

// MARK: - 罗马音里的标点与空格

enum RomanizedPunctuation {
    /// 全角与中日文标点换成拉丁标点。
    static let replacements: [Character: String] = [
        "、": ",", "，": ",", "。": ".", "．": ".", "！": "!", "？": "?", "：": ":", "；": ";",
        "（": "(", "）": ")", "「": "\u{201C}", "」": "\u{201D}", "『": "\u{201C}", "』": "\u{201D}",
        "《": "\u{201C}", "》": "\u{201D}", "〈": "\u{2018}", "〉": "\u{2019}", "【": "[", "】": "]",
        "〜": "~", "～": "~", "・": " ", "　": " ", "＆": "&", "－": "-",
    ]

    /// 贴着前一个词、前面不留空格的标点。
    static let attachesToPrevious: Set<String> = [",", ".", "!", "?", ":", ";", ")", "]", "\u{201D}", "\u{2019}", "…", "~"]
    /// 贴着后一个词、后面不留空格的标点。
    static let attachesToNext: Set<String> = ["(", "[", "\u{201C}", "\u{2018}"]

    static func latinized(_ text: String) -> String {
        String(text.map { replacements[$0] ?? String($0) }.joined())
    }

    /// 词间文字拆成标点与普通文字两类片段；空白只当分隔，不单独留下。
    static func tokens(in text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        func flush() {
            if !current.isEmpty { tokens.append(current) }
            current = ""
        }
        for character in latinized(text) {
            if character.isWhitespace {
                flush()
            } else if character.isPunctuation {
                flush()
                tokens.append(String(character))
            } else {
                current.append(character)
            }
        }
        flush()
        return tokens
    }

    static func join(_ tokens: [String]) -> String {
        var output = ""
        var previousOpens = false
        for token in tokens where !token.isEmpty {
            let trimmed = token.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if output.isEmpty || previousOpens || attachesToPrevious.contains(trimmed) {
                output += trimmed
            } else {
                output += " " + trimmed
            }
            previousOpens = attachesToNext.contains(trimmed)
        }
        return output
    }
}
