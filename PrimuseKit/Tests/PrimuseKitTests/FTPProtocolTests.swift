import Foundation
import Testing
@testable import PrimuseKit

@Suite("FTP protocol parsing")
struct FTPProtocolTests {
    // MARK: Replies

    @Test("Replies are cut from a byte stream, including multi-line ones split across reads")
    func replyParsing() throws {
        var parser = FTPReplyParser()
        #expect(try parser.append(Data("220 Welcome\r\n331 Pass".utf8)) == [
            FTPReply(code: 220, lines: ["220 Welcome"]),
        ])
        let replies = try parser.append(Data("word required\r\n211-Features:\r\n MLST type*;size*;\r\n UTF8\r\n EPSV\r\n211 End\r\n".utf8))
        #expect(replies.count == 2)
        #expect(replies[0].code == 331)
        #expect(replies[1].code == 211)
        #expect(replies[1].lines.count == 5)

        let features = FTPFeatures(reply: replies[1])
        #expect(features.supportsMLSD)
        #expect(features.supportsUTF8)
        #expect(features.supportsEPSV)
        #expect(!features.supportsSize)
    }

    @Test("A line that is not a reply is rejected")
    func malformedReply() {
        var parser = FTPReplyParser()
        #expect(throws: FTPProtocolError.self) {
            _ = try parser.append(Data("hello there\r\n".utf8))
        }
    }

    @Test("Reply text drops the code")
    func replyText() {
        #expect(FTPReply(code: 213, lines: ["213 12345"]).text == "12345")
        #expect(FTPReply(code: 227, lines: ["227 Entering Passive Mode (1,2,3,4,5,6)."]).text
            == "Entering Passive Mode (1,2,3,4,5,6).")
    }

    @Test("Command arguments cannot smuggle a second command")
    func commandInjection() throws {
        #expect(try FTPCommand.data("RETR", "/a b.flac", encoding: .utf8) == Data("RETR /a b.flac\r\n".utf8))
        #expect(throws: FTPProtocolError.self) {
            _ = try FTPCommand.data("RETR", "/x.flac\r\nDELE /y", encoding: .utf8)
        }
    }

    // MARK: Data connections

    @Test("PASV and EPSV replies give the data endpoint")
    func passiveReplies() {
        let pasv = FTPDataEndpointParser.passiveEndpoint(
            from: FTPReply(code: 227, lines: ["227 Entering Passive Mode (192,168,1,5,195,80)."])
        )
        #expect(pasv?.host == "192.168.1.5")
        #expect(pasv?.port == 195 * 256 + 80)

        let spaced = FTPDataEndpointParser.passiveEndpoint(
            from: FTPReply(code: 227, lines: ["227 =10, 0, 0, 7, 4, 1"])
        )
        #expect(spaced?.host == "10.0.0.7")
        #expect(spaced?.port == 1025)

        #expect(FTPDataEndpointParser.passiveEndpoint(
            from: FTPReply(code: 227, lines: ["227 Entering Passive Mode (300,1,1,1,1,1)"])
        ) == nil)

        #expect(FTPDataEndpointParser.extendedPassivePort(
            from: FTPReply(code: 229, lines: ["229 Entering Extended Passive Mode (|||50123|)"])
        ) == 50123)
        #expect(FTPDataEndpointParser.extendedPassivePort(
            from: FTPReply(code: 229, lines: ["229 Extended Passive (!!!6446!)"])
        ) == 6446)
        #expect(FTPDataEndpointParser.extendedPassivePort(
            from: FTPReply(code: 229, lines: ["229 nonsense"])
        ) == nil)
    }

    @Test("PORT and EPRT are formatted for IPv4 and IPv6")
    func activeCommands() {
        #expect(FTPActiveCommand.port(address: "192.168.1.20", port: 50_000) == "PORT 192,168,1,20,195,80")
        #expect(FTPActiveCommand.port(address: "fe80::1", port: 50_000) == nil)
        #expect(FTPActiveCommand.extendedPort(address: "192.168.1.20", port: 50_000) == "EPRT |1|192.168.1.20|50000|")
        #expect(FTPActiveCommand.extendedPort(address: "fe80::1%en0", port: 2121) == "EPRT |2|fe80::1|2121|")
        #expect(FTPActiveCommand.port(address: "192.168.1.20", port: 0) == nil)
    }

    @Test("A private PASV address is swapped for the address the user entered")
    func passiveAddressPolicy() {
        // 服务器在路由器后面,从外网连:报的是内网地址,改连用户填的公网地址或域名。
        #expect(FTPPassiveAddressPolicy.dataHost(replyAddress: "192.168.1.5", controlHost: "203.0.113.7") == "203.0.113.7")
        #expect(FTPPassiveAddressPolicy.dataHost(replyAddress: "10.0.0.5", controlHost: "nas.example.com") == "nas.example.com")
        #expect(FTPPassiveAddressPolicy.dataHost(replyAddress: "100.64.1.2", controlHost: "nas.example.com") == "nas.example.com")
        // 同一局域网里直连内网地址:照服务器报的连。
        #expect(FTPPassiveAddressPolicy.dataHost(replyAddress: "192.168.1.6", controlHost: "192.168.1.5") == "192.168.1.6")
        // 公网地址照用,0.0.0.0 换成用户填的地址。
        #expect(FTPPassiveAddressPolicy.dataHost(replyAddress: "198.51.100.9", controlHost: "nas.example.com") == "198.51.100.9")
        #expect(FTPPassiveAddressPolicy.dataHost(replyAddress: "0.0.0.0", controlHost: "nas.example.com") == "nas.example.com")
    }

    // MARK: Listings

    @Test("Unix LIST keeps exact names and skips noise")
    func unixList() {
        let now = date("2026-10-10 12:00")
        let text = """
        total 24
        drwxr-xr-x    2 ftp      ftp          4096 Mar 03 09:15 Album  Two\r
        -rw-r--r--    1 ftp      ftp      31457280 Mar 03 09:15 01 - Song.flac\r
        lrwxrwxrwx    1 ftp      ftp            12 Mar 03 09:15 Latest -> Album  Two\r
        -rw-r--r--    1 1000     1000         2048 Dec 25  2024 cover.jpg\r
        drwxr-xr-x    2 ftp      ftp          4096 Jan 01 09:00 .\r
        -rw-r--r-- 1 owner 1234 Feb 14 08:30 no-group.mp3\r
        """
        let entries = FTPListParser.parseLIST(text, now: now, timeZone: TimeZone(identifier: "UTC")!)
        #expect(entries.map(\.name) == ["Album  Two", "01 - Song.flac", "Latest", "cover.jpg", "no-group.mp3"])
        #expect(entries[0].isDirectory && entries[0].size == -1)
        #expect(entries[1].size == 31_457_280 && !entries[1].isDirectory)
        #expect(entries[2].isSymbolicLink && !entries[2].isDirectory)
        #expect(entries[4].size == 1234)
        #expect(entries[1].modifiedDate == date("2026-03-03 09:15"))
        #expect(entries[3].modifiedDate == date("2024-12-25 00:00"))
    }

    @Test("A month-day in the future belongs to last year")
    func listYearRollover() {
        let now = date("2026-03-01 12:00")
        let entries = FTPListParser.parseLIST(
            "-rw-r--r-- 1 ftp ftp 10 Dec 25 09:30 late.mp3",
            now: now,
            timeZone: TimeZone(identifier: "UTC")!
        )
        #expect(entries.first?.modifiedDate == date("2025-12-25 09:30"))
    }

    @Test("DOS/IIS LIST lines are understood")
    func dosList() {
        let text = """
        03-04-24  10:15AM       <DIR>          Live Album
        03-04-24  10:16AM             1048576 track 01.mp3
        """
        let entries = FTPListParser.parseLIST(text)
        #expect(entries.map(\.name) == ["Live Album", "track 01.mp3"])
        #expect(entries[0].isDirectory)
        #expect(entries[1].size == 1_048_576)
    }

    @Test("MLSD facts, odd names and the dot entries")
    func mlsd() {
        let text = """
        type=cdir;modify=20260101090000; .\r
        type=pdir;modify=20260101090000; ..\r
        type=dir;modify=20260101090000; Disc 1\r
        type=file;size=4096;modify=20260101090000;perm=r; a;b c.flac\r
        Type=File;Size=12;Modify=20260101090000; /music/abs.mp3\r
        """
        let entries = FTPListParser.parseMLSD(text, timeZone: TimeZone(identifier: "UTC")!)
        #expect(entries.map(\.name) == ["Disc 1", "a;b c.flac", "abs.mp3"])
        #expect(entries[0].isDirectory)
        #expect(entries[1].size == 4096)
        #expect(entries[2].size == 12)
        #expect(entries[1].modifiedDate == date("2026-01-01 09:00"))
    }

    #if canImport(Darwin)
    @Test("GBK file names from servers without UTF8 round-trip through GB18030")
    func gb18030Names() throws {
        let name = "周杰伦 - 晴天.mp3"
        let encoded = try #require(FTPTextEncoding.gb18030.encode(name))
        #expect(String(data: encoded, encoding: .utf8) == nil)
        #expect(FTPTextEncoding.detect(encoded) == .gb18030)
        #expect(FTPTextEncoding.gb18030.decode(encoded) == name)
        #expect(FTPTextEncoding.detect(Data(name.utf8)) == .utf8)
    }
    #endif

    private func date(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: text)!
    }
}
