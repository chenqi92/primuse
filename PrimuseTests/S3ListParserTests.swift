import Foundation
import XCTest
@testable import Primuse

final class S3ListParserTests: XCTestCase {
    func testIndentedBackblazeListingKeepsExactKeysAndPrefixes() throws {
        let parser = try parse("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
            <Name>music</Name>
            <Prefix></Prefix>
            <MaxKeys>1000</MaxKeys>
            <Delimiter>/</Delimiter>
            <IsTruncated>false</IsTruncated>
            <Contents>
                <ETag>"85f30635602dc09bd85957a6e82a2c21"</ETag>
                <Key>song.mp3</Key>
                <LastModified>2026-10-01T10:00:00.000Z</LastModified>
                <Size>1234</Size>
                <StorageClass>STANDARD</StorageClass>
            </Contents>
            <CommonPrefixes>
                <Prefix>2 live Crew/</Prefix>
            </CommonPrefixes>
        </ListBucketResult>
        """)

        XCTAssertEqual(parser.items.count, 2)
        let file = try XCTUnwrap(parser.items.first { !$0.isDirectory })
        XCTAssertEqual(file.path, "song.mp3")
        XCTAssertEqual(file.name, "song.mp3")
        XCTAssertEqual(file.size, 1234)
        XCTAssertEqual(file.revision, "\"85f30635602dc09bd85957a6e82a2c21\"")
        let folder = try XCTUnwrap(parser.items.first { $0.isDirectory })
        XCTAssertEqual(folder.path, "2 live Crew/")
        XCTAssertEqual(folder.name, "2 live Crew")
        XCTAssertFalse(parser.isTruncated)
    }

    func testCompactListingKeepsSpacesEntitiesAndContinuationToken() throws {
        let parser = try parse(
            #"<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">"#
                + "<IsTruncated>true</IsTruncated><NextContinuationToken>1ueGcxLPRx1Tr</NextContinuationToken>"
                + "<Contents><Key>Rock &amp; Roll/ Intro .flac</Key><Size>7</Size></Contents>"
                + "<CommonPrefixes><Prefix>Live &amp; Loud/</Prefix></CommonPrefixes>"
                + "</ListBucketResult>",
            prefix: ""
        )

        XCTAssertEqual(parser.items.map(\.path), ["Rock & Roll/ Intro .flac", "Live & Loud/"])
        XCTAssertEqual(parser.items.first?.name, " Intro .flac")
        XCTAssertTrue(parser.isTruncated)
        XCTAssertEqual(parser.nextContinuationToken, "1ueGcxLPRx1Tr")
    }

    /// B2 上 `... -The Truth + Kamasutra/` 每次都 403：线上发的是原样 `+`，服务端读成空格，
    /// 和按 `%2B` 算的签名对不上。签名用的查询串必须和服务端按表单规则解出来的一致。
    func testListRequestSignsTheSameQueryTheServerDecodes() throws {
        let prefix = "Prince/1. Studio/1998 - Crystal Ball -The Truth + Kamasutra/"
        let token = "1ueGcxLPRx1Tr+Ab/Cd=="
        let url = try XCTUnwrap(S3Source.listObjectsURL(
            bucketURL: try XCTUnwrap(URL(string: "https://s3.us-west-004.backblazeb2.com/music")),
            prefix: prefix,
            continuationToken: token
        ))
        let wireQuery = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .percentEncodedQuery)
        XCTAssertFalse(wireQuery.contains("+"))

        var serverDecoded: [String: String] = [:]
        for pair in wireQuery.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map {
                $0.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? ""
            }
            serverDecoded[parts[0]] = parts.count > 1 ? parts[1] : ""
        }
        XCTAssertEqual(serverDecoded["prefix"], prefix)
        XCTAssertEqual(serverDecoded["continuation-token"], token)
        XCTAssertEqual(serverDecoded["delimiter"], "/")

        let canonical = S3Source.canonicalQueryString(for: url)
        XCTAssertTrue(canonical.contains("prefix=Prince%2F1.%20Studio%2F1998%20-%20Crystal%20Ball%20-The%20Truth%20%2B%20Kamasutra%2F"))
        XCTAssertTrue(canonical.contains("continuation-token=1ueGcxLPRx1Tr%2BAb%2FCd%3D%3D"))
    }

    private func parse(_ xml: String, prefix: String = "") throws -> S3ListParser {
        let parser = S3ListParser(prefix: prefix)
        let xmlParser = XMLParser(data: Data(xml.utf8))
        xmlParser.shouldProcessNamespaces = true
        xmlParser.delegate = parser
        XCTAssertTrue(xmlParser.parse())
        XCTAssertTrue(parser.isStructurallyValid)
        XCTAssertTrue(parser.sawListBucketResult)
        XCTAssertTrue(parser.sawValidIsTruncatedMarker)
        return parser
    }
}
