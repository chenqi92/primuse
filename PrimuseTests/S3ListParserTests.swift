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
