import Foundation

/// 在一个 JSON 对象的字节里找到某个顶层键的数组,按页交出数组元素的原始字节,不解码整份。
///
/// 整库快照(`{…,"songs":[…]}`)整份解码要把每一首歌都建出来:10 万首时 iCloud 上传前的整理峰值 1.3 GB。
/// 这里只扫结构(字符串、括号、逗号),一页一页把 `[元素,…]` 抄出来交给 `JSONDecoder`;元素内容的合法性
/// 由解码那一步判断,对象其余部分(数组换成 `[]`)也交给解码。键在对象里的位置不限,`songs` 不必是最后一个。
///
/// 收不收由 `JSONDecoder` 定,与整份解码一样:每个字节不是落在交出的页里,就是落在对象其余部分里,两样都由它解;
/// 页与页之间、数组开头和结尾那几段分隔(逗号与空白)不在任何一页里,拿同样的分隔拼一小段交给它试(它收数组
/// 末尾多一个逗号)。只认 UTF-8(本 App 的编码器与 `JSONSerialization` 写的都是);对象外面除空白之外还有别的、
/// 键重复、括号对不上时抛错,调用方按「这份快照读不了」处理。
public struct TopLevelJSONArrayReader: Sendable {
    public enum ReadError: Error, Equatable {
        case notAnObject
        case malformed(offset: Int)
        case missingKey
        case duplicateKey
        case notAnArray
    }

    /// 整份字节。`Data` 共享存储,不复制。
    public let data: Data
    /// 这个键的值(数组)在 `data` 里的偏移范围(从 0 起算),含两端的方括号。
    public let arrayRange: Range<Int>

    public init(data: Data, key: String) throws {
        self.data = data
        arrayRange = try data.withUnsafeBytes { raw in
            try Scanner(raw).arrayValue(ofTopLevelKey: key)
        }
    }

    /// 对象其余部分:这个数组换成 `[]`,别的字节原样。小状态,解码它得到「数组为空」的那个对象。
    public func objectWithEmptyArray() -> Data {
        data.withUnsafeBytes { raw in
            var object = Data(capacity: raw.count - arrayRange.count + 2)
            object.append(contentsOf: raw[..<arrayRange.lowerBound])
            object.append(contentsOf: [UInt8(ascii: "["), UInt8(ascii: "]")])
            object.append(contentsOf: raw[arrayRange.upperBound...])
            return object
        }
    }

    /// 从头一页一页读数组元素。可以多次调用,各走一遍。
    public func pages(maximumCount: Int) -> Pages {
        Pages(data: data, arrayRange: arrayRange, maximumCount: max(1, maximumCount))
    }

    /// 一页是 `[` + 连续的若干个元素(原样,含元素之间的分隔)+ `]`,可以直接解码成数组。
    public struct Pages: Sendable {
        let data: Data
        let arrayRange: Range<Int>
        let maximumCount: Int
        /// 上一页最后一个元素之后(第一次:左方括号之后)。
        private var cursor: Int
        private var started = false
        private var finished = false
        /// 已经交出的元素个数。
        public private(set) var elementCount = 0

        init(data: Data, arrayRange: Range<Int>, maximumCount: Int) {
            self.data = data
            self.arrayRange = arrayRange
            self.maximumCount = maximumCount
            cursor = arrayRange.lowerBound + 1
        }

        /// 下一页;读完了为 nil。字节对不上时抛错(之前交出的页不作数,调用方整份放弃)。
        public mutating func next() throws -> Data? {
            guard !finished else { return nil }
            let isFirst = !started
            started = true
            let step = try data.withUnsafeBytes { raw -> (range: Range<Int>?, count: Int, cursor: Int) in
                let scanner = Scanner(raw)
                let end = arrayRange.upperBound - 1
                // 这一页前面的那段分隔(数组开头,或上一页与这一页之间)。
                let gap = try scanner.skipSeparator(from: cursor, before: end)
                if gap.end == end {
                    // 数组结尾:空数组 `[ ]`,或最后一个元素后面的分隔(可能多一个逗号)。
                    if gap.commas > 0 {
                        try scanner.requireDecoderAccepts(prefix: isFirst ? "[" : "[0", gap.range, suffix: "]")
                    }
                    return (nil, 0, end)
                }
                if isFirst {
                    if gap.commas > 0 { try scanner.requireDecoderAccepts(prefix: "[", gap.range, suffix: "0]") }
                } else if gap.commas != 1 {
                    try scanner.requireDecoderAccepts(prefix: "[0", gap.range, suffix: "0]")
                }
                // 页里元素之间的分隔原样留在页里,由解码判断。
                let start = gap.end
                var position = start
                var count = 0
                while true {
                    let valueEnd = try scanner.skipValue(at: position, before: end)
                    count += 1
                    let next = try scanner.skipSeparator(from: valueEnd, before: end)
                    if next.end == end || count == maximumCount {
                        return (start..<valueEnd, count, valueEnd)
                    }
                    position = next.end
                }
            }
            cursor = step.cursor
            guard let range = step.range else {
                finished = true
                return nil
            }
            elementCount += step.count
            return data.withUnsafeBytes { raw in
                var page = Data(capacity: range.count + 2)
                page.append(UInt8(ascii: "["))
                page.append(contentsOf: raw[range])
                page.append(UInt8(ascii: "]"))
                return page
            }
        }
    }

    /// 只认结构的扫描:跳过字符串(含转义)、按深度跳过嵌套的对象与数组、跳过数字与字面量、跳过分隔。
    struct Scanner {
        let raw: UnsafeRawBufferPointer

        init(_ raw: UnsafeRawBufferPointer) {
            self.raw = raw
        }

        func arrayValue(ofTopLevelKey key: String) throws -> Range<Int> {
            let count = raw.count
            var position = try skipWhitespace(from: 0, before: count)
            guard position < count, raw[position] == UInt8(ascii: "{") else { throw ReadError.notAnObject }
            var found: Range<Int>?
            // 成员之间的分隔(逗号与空白,包括多出来的逗号)原样留在对象其余部分里,由解码判断。
            position = try skipSeparator(from: position + 1, before: count).end
            while position < count, raw[position] != UInt8(ascii: "}") {
                guard raw[position] == UInt8(ascii: "\"") else { throw ReadError.malformed(offset: position) }
                let keyEnd = try skipString(at: position, before: count)
                let keyRange = position..<keyEnd
                position = try skipWhitespace(from: keyEnd, before: count)
                guard position < count, raw[position] == UInt8(ascii: ":") else {
                    throw ReadError.malformed(offset: position)
                }
                position = try skipWhitespace(from: position + 1, before: count)
                let valueStart = position
                position = try skipValue(at: position, before: count)
                if try keyMatches(keyRange, key) {
                    guard found == nil else { throw ReadError.duplicateKey }
                    found = valueStart..<position
                }
                position = try skipSeparator(from: position, before: count).end
            }
            guard position < count else { throw ReadError.malformed(offset: position) }
            // 对象之后只许有空白(与 JSONDecoder 一样不收尾巴)。
            guard try skipWhitespace(from: position + 1, before: count) == count else {
                throw ReadError.malformed(offset: position + 1)
            }
            guard let found else { throw ReadError.missingKey }
            guard raw[found.lowerBound] == UInt8(ascii: "["), raw[found.upperBound - 1] == UInt8(ascii: "]") else {
                throw ReadError.notAnArray
            }
            return found
        }

        /// 键比原始字节;键里有转义时交给 JSONDecoder 还原再比。
        private func keyMatches(_ range: Range<Int>, _ key: String) throws -> Bool {
            let inner = raw[(range.lowerBound + 1)..<(range.upperBound - 1)]
            guard inner.contains(UInt8(ascii: "\\")) else { return inner.elementsEqual(key.utf8) }
            var wrapped = Data([UInt8(ascii: "[")])
            wrapped.append(contentsOf: raw[range])
            wrapped.append(UInt8(ascii: "]"))
            guard let decoded = try? JSONDecoder().decode([String].self, from: wrapped).first else {
                throw ReadError.malformed(offset: range.lowerBound)
            }
            return decoded == key
        }

        /// 不落在任何一页里的那段分隔:拼成 `{"k":<前缀><分隔><后缀>}` 交给 JSONDecoder,它收才收。
        func requireDecoderAccepts(prefix: String, _ separator: Range<Int>, suffix: String) throws {
            var probe = Data("{\"k\":\(prefix)".utf8)
            probe.append(contentsOf: raw[separator])
            probe.append(contentsOf: Data("\(suffix)}".utf8))
            guard (try? JSONDecoder().decode([String: [Int]].self, from: probe)) != nil else {
                throw ReadError.malformed(offset: separator.lowerBound)
            }
        }

        func skipWhitespace(from start: Int, before end: Int) throws -> Int {
            var position = start
            while position < end {
                switch raw[position] {
                case 0x20, 0x09, 0x0A, 0x0D: position += 1
                default: return position
                }
            }
            return position
        }

        /// 逗号与空白;返回这段的范围与其中逗号的个数。
        func skipSeparator(from start: Int, before end: Int) throws -> (range: Range<Int>, end: Int, commas: Int) {
            var position = start
            var commas = 0
            scan: while position < end {
                switch raw[position] {
                case 0x20, 0x09, 0x0A, 0x0D: position += 1
                case UInt8(ascii: ","):
                    commas += 1
                    position += 1
                default: break scan
                }
            }
            return (start..<position, position, commas)
        }

        /// `position` 指着开头的引号;返回收尾引号之后的偏移。找引号用 memchr,遇到前面是奇数个反斜杠的引号接着找。
        func skipString(at position: Int, before end: Int) throws -> Int {
            guard let base = raw.baseAddress else { throw ReadError.malformed(offset: position) }
            var search = position + 1
            while search < end {
                guard let hit = memchr(base + search, Int32(UInt8(ascii: "\"")), end - search) else { break }
                let quote = base.distance(to: UnsafeRawPointer(hit))
                var backslashes = 0
                var back = quote - 1
                while back > position, raw[back] == UInt8(ascii: "\\") {
                    backslashes += 1
                    back -= 1
                }
                if backslashes.isMultiple(of: 2) { return quote + 1 }
                search = quote + 1
            }
            throw ReadError.malformed(offset: position)
        }

        /// 跳过一个值,返回它之后的偏移。嵌套的对象与数组按深度跳(括号种类与内容由之后的解码检查)。
        func skipValue(at position: Int, before end: Int) throws -> Int {
            guard position < end else { throw ReadError.malformed(offset: position) }
            switch raw[position] {
            case UInt8(ascii: "\""):
                return try skipString(at: position, before: end)
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                var depth = 0
                var cursor = position
                while cursor < end {
                    switch raw[cursor] {
                    case UInt8(ascii: "\""):
                        cursor = try skipString(at: cursor, before: end)
                        continue
                    case UInt8(ascii: "{"), UInt8(ascii: "["):
                        depth += 1
                    case UInt8(ascii: "}"), UInt8(ascii: "]"):
                        depth -= 1
                        if depth == 0 { return cursor + 1 }
                    default:
                        break
                    }
                    cursor += 1
                }
                throw ReadError.malformed(offset: position)
            default:
                var cursor = position
                scan: while cursor < end {
                    switch raw[cursor] {
                    case UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]"), UInt8(ascii: "{"), UInt8(ascii: "["),
                         UInt8(ascii: "\""), UInt8(ascii: ":"), 0x20, 0x09, 0x0A, 0x0D:
                        break scan
                    default:
                        cursor += 1
                    }
                }
                guard cursor > position else { throw ReadError.malformed(offset: position) }
                return cursor
            }
        }
    }
}
