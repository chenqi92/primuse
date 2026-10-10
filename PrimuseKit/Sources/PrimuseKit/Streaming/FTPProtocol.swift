import Foundation

// FTP 协议里与传输无关的部分:回复切分、被动/主动模式地址、目录列表解析、文字编码。
// 只依赖 Foundation,连接与收发在 `FTPClient.swift`。

// MARK: - Text encoding

/// 服务器上文件名的编码。声明了 UTF8 的服务器一律 UTF-8;没声明的旧服务器(常见于中文
/// Windows 上的 FTP)文件名多是 GBK,读到不是合法 UTF-8 的列表时改用 GB18030 解,
/// 之后发命令也用它编码,路径才能原样送回服务器。
public enum FTPTextEncoding: String, Sendable, Equatable {
    case utf8
    case gb18030

    public func decode(_ data: Data) -> String? {
        String(data: data, encoding: stringEncoding)
    }

    public func encode(_ string: String) -> Data? {
        string.data(using: stringEncoding)
    }

    /// 先按 UTF-8;不是合法 UTF-8 才试 GB18030。
    public static func detect(_ data: Data) -> FTPTextEncoding? {
        if String(data: data, encoding: .utf8) != nil { return .utf8 }
        if String(data: data, encoding: FTPTextEncoding.gb18030.stringEncoding) != nil { return .gb18030 }
        return nil
    }

    private var stringEncoding: String.Encoding {
        switch self {
        case .utf8:
            return .utf8
        case .gb18030:
            #if canImport(Darwin)
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            ))
            #else
            return .isoLatin1
            #endif
        }
    }
}

// MARK: - Replies

/// 一条完整的回复,多行回复的每一行都在 `lines` 里(含回复码)。
public struct FTPReply: Equatable, Sendable {
    public let code: Int
    public let lines: [String]

    public init(code: Int, lines: [String]) {
        self.code = code
        self.lines = lines
    }

    /// 去掉回复码后的正文。
    public var text: String {
        lines.enumerated().map { index, line in
            if index == 0 || index == lines.count - 1,
               line.count >= 3,
               line.prefix(3).allSatisfy(\.isNumber) {
                return String(line.dropFirst(min(4, line.count)))
            }
            return line
        }.joined(separator: "\n")
    }

    public var isPreliminary: Bool { (100..<200).contains(code) }
    public var isCompletion: Bool { (200..<300).contains(code) }
    public var isIntermediate: Bool { (300..<400).contains(code) }
    public var isTransientFailure: Bool { (400..<500).contains(code) }
    public var isPermanentFailure: Bool { (500..<600).contains(code) }
}

public enum FTPProtocolError: Error, Equatable, Sendable {
    case malformedReply(String)
    case replyTooLong
    case unsafeArgument
}

/// 把控制连接上收到的字节切成一条条回复。多行回复以 `123-` 开头,以 `123 ` 开头的
/// 那一行结束,中间的行原样保留。
public struct FTPReplyParser: Sendable {
    public var encoding: FTPTextEncoding
    private var buffer = Data()
    private var pendingCode: Int?
    private var pendingLines: [String] = []

    static let maximumBufferedByteCount = 1 << 20

    public init(encoding: FTPTextEncoding = .utf8) {
        self.encoding = encoding
    }

    public mutating func append(_ data: Data) throws -> [FTPReply] {
        buffer.append(data)
        var replies: [FTPReply] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            var lineData = buffer[buffer.startIndex..<newline]
            buffer = Data(buffer[buffer.index(after: newline)...])
            if lineData.last == 0x0D { lineData = lineData.dropLast() }
            let line = encoding.decode(Data(lineData))
                ?? String(decoding: lineData, as: UTF8.self)
            if let reply = try consume(line: line) {
                replies.append(reply)
            }
        }
        guard buffer.count <= Self.maximumBufferedByteCount else { throw FTPProtocolError.replyTooLong }
        return replies
    }

    private mutating func consume(line: String) throws -> FTPReply? {
        if let code = pendingCode {
            pendingLines.append(line)
            guard Self.code(of: line) == code, Self.separator(of: line) != "-" else { return nil }
            let reply = FTPReply(code: code, lines: pendingLines)
            pendingCode = nil
            pendingLines = []
            return reply
        }
        // 两条回复之间偶尔夹着空行,跳过。
        if line.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
        guard let code = Self.code(of: line) else { throw FTPProtocolError.malformedReply(line) }
        if Self.separator(of: line) == "-" {
            pendingCode = code
            pendingLines = [line]
            return nil
        }
        return FTPReply(code: code, lines: [line])
    }

    private static func code(of line: String) -> Int? {
        let digits = line.prefix(3)
        guard digits.count == 3, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        let separator = line.dropFirst(3).first
        guard separator == nil || separator == " " || separator == "-" else { return nil }
        return Int(digits)
    }

    private static func separator(of line: String) -> Character? {
        line.dropFirst(3).first
    }
}

/// 一行命令。参数里带回车换行会被服务器当成第二条命令,一律拒绝。
public enum FTPCommand {
    public static func data(_ verb: String, _ argument: String? = nil, encoding: FTPTextEncoding) throws -> Data {
        // 按 Unicode 标量查:Swift 把 "\r\n" 算成一个字符,按字符比较会漏掉它。
        if let argument, argument.unicodeScalars.contains(where: { $0 == "\r" || $0 == "\n" || $0 == "\0" }) {
            throw FTPProtocolError.unsafeArgument
        }
        let line = argument.map { "\(verb) \($0)" } ?? verb
        guard var data = encoding.encode(line) else { throw FTPProtocolError.unsafeArgument }
        data.append(contentsOf: [0x0D, 0x0A])
        return data
    }
}

/// `FEAT` 回复里列出的扩展,统一成大写的首个词(`REST STREAM` 记作 `REST`)。
public struct FTPFeatures: Equatable, Sendable {
    public let names: Set<String>

    public init(names: Set<String> = []) {
        self.names = names
    }

    public init(reply: FTPReply) {
        guard reply.isCompletion, reply.lines.count > 2 else {
            self.names = []
            return
        }
        var names: Set<String> = []
        for line in reply.lines.dropFirst().dropLast() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let first = trimmed.split(separator: " ").first else { continue }
            names.insert(first.uppercased())
            if first.uppercased() == "AUTH" { names.insert("AUTH TLS") }
        }
        self.names = names
    }

    public var supportsMLSD: Bool { names.contains("MLST") || names.contains("MLSD") }
    public var supportsUTF8: Bool { names.contains("UTF8") }
    public var supportsEPSV: Bool { names.contains("EPSV") }
    public var supportsSize: Bool { names.contains("SIZE") }
}

// MARK: - Passive and active data connections

public enum FTPDataEndpointParser {
    /// `227 Entering Passive Mode (h1,h2,h3,h4,p1,p2)`。括号可有可无,只认六个 0–255 的数。
    public static func passiveEndpoint(from reply: FTPReply) -> (host: String, port: Int)? {
        let text = reply.text
        let pattern = #"(\d{1,3})\s*,\s*(\d{1,3})\s*,\s*(\d{1,3})\s*,\s*(\d{1,3})\s*,\s*(\d{1,3})\s*,\s*(\d{1,3})"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in expression.matches(in: text, range: range) {
            let numbers = (1...6).compactMap { group -> Int? in
                guard let groupRange = Range(match.range(at: group), in: text) else { return nil }
                return Int(text[groupRange])
            }
            guard numbers.count == 6, numbers.allSatisfy({ (0...255).contains($0) }) else { continue }
            let port = numbers[4] * 256 + numbers[5]
            guard port > 0 else { continue }
            return (numbers[0...3].map(String.init).joined(separator: "."), port)
        }
        return nil
    }

    /// `229 Entering Extended Passive Mode (|||port|)`:只有端口,四个分隔符相同。
    public static func extendedPassivePort(from reply: FTPReply) -> Int? {
        let characters = Array(reply.text)
        var index = 0
        while index < characters.count {
            defer { index += 1 }
            guard characters[index] == "(", index + 4 < characters.count else { continue }
            let delimiter = characters[index + 1]
            guard !delimiter.isNumber,
                  characters[index + 2] == delimiter,
                  characters[index + 3] == delimiter else { continue }
            var cursor = index + 4
            var digits = ""
            while cursor < characters.count, characters[cursor].isASCII, characters[cursor].isNumber {
                digits.append(characters[cursor])
                cursor += 1
            }
            guard cursor + 1 < characters.count,
                  characters[cursor] == delimiter,
                  characters[cursor + 1] == ")",
                  let port = Int(digits),
                  (1...65_535).contains(port) else { continue }
            return port
        }
        return nil
    }
}

public enum FTPActiveCommand {
    /// `PORT h1,h2,h3,h4,p1,p2`,只用于 IPv4。
    public static func port(address: String, port: Int) -> String? {
        guard let octets = ipv4Octets(address), (1...65_535).contains(port) else { return nil }
        return "PORT " + (octets.map(String.init) + [String(port / 256), String(port % 256)])
            .joined(separator: ",")
    }

    /// `EPRT |1|ip|port|` 或 `EPRT |2|ip|port|`。
    public static func extendedPort(address: String, port: Int) -> String? {
        guard (1...65_535).contains(port) else { return nil }
        if ipv4Octets(address) != nil { return "EPRT |1|\(address)|\(port)|" }
        let bare = address.split(separator: "%", maxSplits: 1).first.map(String.init) ?? address
        guard bare.contains(":"), !bare.contains("|") else { return nil }
        return "EPRT |2|\(bare)|\(port)|"
    }

    static func ipv4Octets(_ address: String) -> [Int]? {
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let octets = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.count <= 3, part.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return Int(part)
        }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return nil }
        return octets
    }
}

/// PASV 回复里报的地址常常是服务器自己的内网地址(服务器在路由器后面时),从外网照着连
/// 必然连不上。这时改连用户填的服务器地址:被动端口是路由器转发过去的,连回同一个地址
/// 才对。用户填的本身就是内网地址时(同一局域网),照服务器报的连。
public enum FTPPassiveAddressPolicy {
    public static func dataHost(replyAddress: String, controlHost: String) -> String {
        guard let reply = FTPActiveCommand.ipv4Octets(replyAddress) else { return controlHost }
        if reply == [0, 0, 0, 0] { return controlHost }
        guard isNonRoutable(reply) else { return replyAddress }
        if let control = FTPActiveCommand.ipv4Octets(controlHost), isNonRoutable(control) {
            return replyAddress
        }
        return controlHost
    }

    static func isNonRoutable(_ octets: [Int]) -> Bool {
        switch (octets[0], octets[1]) {
        case (10, _), (127, _), (0, _): return true
        case (172, 16...31): return true
        case (192, 168): return true
        case (169, 254): return true
        case (100, 64...127): return true // 运营商级 NAT
        default: return false
        }
    }
}

// MARK: - Directory listings

public struct FTPListEntry: Equatable, Sendable {
    public var name: String
    public var isDirectory: Bool
    public var isSymbolicLink: Bool
    /// 目录与不知道大小时是 -1。
    public var size: Int64
    public var modifiedDate: Date?

    public init(name: String, isDirectory: Bool, isSymbolicLink: Bool = false, size: Int64, modifiedDate: Date?) {
        self.name = name
        self.isDirectory = isDirectory
        self.isSymbolicLink = isSymbolicLink
        self.size = size
        self.modifiedDate = modifiedDate
    }
}

/// 解析 MLSD 与 LIST 的输出。
///
/// 修改时间刻意沿用旧版 FTP 库(FilesProvider 0.26)的算法:同样的格式串(12 小时制的
/// `hh`、MLSD 也按设备时区)、同样的「今年 / 往前推一年」规则。歌曲的版本号由「大小 +
/// 修改时间」组成,算法一变,老用户整个 FTP 曲库都会被当成换了文件、重读一遍。文件名与
/// 类型则按正确方式解析:多个连续空格原样保留、符号链接去掉 `-> 目标`。
public enum FTPListParser {
    public static func parseMLSD(_ text: String, timeZone: TimeZone = .current) -> [FTPListEntry] {
        let formatter = makeFormatter("yyyyMMddhhmmss", timeZone: timeZone)
        return lines(of: text).compactMap { line in
            guard let separator = line.firstIndex(of: " ") else { return nil }
            let factsText = line[..<separator]
            var name = String(line[line.index(after: separator)...])
            if name.hasPrefix("/") { name = (name as NSString).lastPathComponent }
            guard !name.isEmpty, name != ".", name != ".." else { return nil }
            var facts: [String: String] = [:]
            for fact in factsText.split(separator: ";") {
                guard let equals = fact.firstIndex(of: "=") else { continue }
                facts[fact[..<equals].lowercased()] = String(fact[fact.index(after: equals)...])
            }
            let type = facts["type"]?.lowercased() ?? "file"
            if type == "cdir" || type == "pdir" { return nil }
            let isDirectory = type == "dir"
            let isLink = type == "os.unix=symlink" || type.hasPrefix("os.unix=slink")
            return FTPListEntry(
                name: name,
                isDirectory: isDirectory,
                isSymbolicLink: isLink,
                size: isDirectory ? -1 : (facts["size"].flatMap { Int64($0) } ?? -1),
                modifiedDate: facts["modify"].flatMap { formatter.date(from: $0) }
            )
        }
    }

    public static func parseLIST(_ text: String, now: Date = Date(), timeZone: TimeZone = .current) -> [FTPListEntry] {
        let near = makeFormatter("MMM dd hh:mm yyyy", timeZone: timeZone)
        let far = makeFormatter("MMM dd yyyy", timeZone: timeZone)
        let dos = makeFormatter("M-d-y hh:mma", timeZone: timeZone)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let thisYear = calendar.component(.year, from: now)
        return lines(of: text).compactMap { line in
            unixEntry(line, near: near, far: far, thisYear: thisYear, now: now, calendar: calendar)
                ?? dosEntry(line, formatter: dos)
        }
    }

    // MARK: Unix `ls -l`

    private static func unixEntry(
        _ line: String,
        near: DateFormatter,
        far: DateFormatter,
        thisYear: Int,
        now: Date,
        calendar: Calendar
    ) -> FTPListEntry? {
        guard let typeCharacter = line.first, "-dlcbps".contains(typeCharacter) else { return nil }
        let tokens = tokenRanges(in: line)
        // 权限 链接数 属主 属组 大小 月 日 时间/年份 文件名。九列的照旧版不看月份是否英文
        // (月份是本地化写法的服务器旧版也列得出来,只是没有修改时间);没有属组、少一列的
        // 服务器要求月份是英文缩写才认。
        let layouts: [(size: Int, month: Int, requiresMonth: Bool)] = [(4, 5, false), (3, 4, true)]
        for layout in layouts {
            guard tokens.count > layout.month + 3,
                  let size = Int64(line[tokens[layout.size]]),
                  !layout.requiresMonth || isMonth(line[tokens[layout.month]]) else { continue }
            let nameStart = tokens[layout.month + 3].lowerBound
            var name = String(line[nameStart...])
            let isLink = typeCharacter == "l"
            if isLink, let arrow = name.range(of: " -> ") {
                name = String(name[..<arrow.lowerBound])
            }
            guard !name.isEmpty, name != ".", name != ".." else { return nil }
            let dateText = (layout.month...(layout.month + 2)).map { String(line[tokens[$0]]) }.joined(separator: " ")
            var modified: Date?
            if let parsed = near.date(from: dateText + " " + String(thisYear)) {
                modified = parsed > now ? calendar.date(byAdding: .year, value: -1, to: parsed) : parsed
            } else {
                modified = far.date(from: dateText)
            }
            let isDirectory = typeCharacter == "d"
            return FTPListEntry(
                name: name,
                isDirectory: isDirectory,
                isSymbolicLink: isLink,
                size: isDirectory ? -1 : size,
                modifiedDate: modified
            )
        }
        return nil
    }

    // MARK: DOS / IIS

    private static func dosEntry(_ line: String, formatter: DateFormatter) -> FTPListEntry? {
        let tokens = tokenRanges(in: line)
        guard tokens.count >= 4 else { return nil }
        let dateText = String(line[tokens[0]])
        guard dateText.contains("-") || dateText.contains("/"),
              dateText.first?.isNumber == true else { return nil }
        let sizeText = String(line[tokens[2]])
        let isDirectory = sizeText.uppercased() == "<DIR>"
        guard isDirectory || Int64(sizeText) != nil else { return nil }
        let name = String(line[tokens[3].lowerBound...])
        guard !name.isEmpty, name != ".", name != ".." else { return nil }
        return FTPListEntry(
            name: name,
            isDirectory: isDirectory,
            size: isDirectory ? -1 : (Int64(sizeText) ?? -1),
            modifiedDate: formatter.date(from: dateText + " " + String(line[tokens[1]]))
        )
    }

    // MARK: Helpers

    private static func lines(of text: String) -> [String] {
        text.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" })
            .map { $0.hasSuffix("\r") ? String($0.dropLast()) : String($0) }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private static func tokenRanges(in line: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var index = line.startIndex
        while index < line.endIndex {
            while index < line.endIndex, line[index] == " " || line[index] == "\t" {
                index = line.index(after: index)
            }
            guard index < line.endIndex else { break }
            let start = index
            while index < line.endIndex, line[index] != " ", line[index] != "\t" {
                index = line.index(after: index)
            }
            ranges.append(start..<index)
        }
        return ranges
    }

    private static let months: Set<String> = [
        "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec",
    ]

    private static func isMonth(_ token: Substring) -> Bool {
        months.contains(token.lowercased())
    }

    private static func makeFormatter(_ format: String, timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter
    }
}
