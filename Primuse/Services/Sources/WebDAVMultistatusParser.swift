import Foundation

struct WebDAVMultistatusEntry: Sendable {
    let href: String
    let displayName: String?
    let contentLength: Int64?
    let lastModified: String?
    let etag: String?
    let isDirectory: Bool
}

final class WebDAVMultistatusParser: NSObject, XMLParserDelegate {
    private struct Properties {
        var displayName: String?
        var contentLength: Int64?
        var lastModified: String?
        var etag: String?
        var isDirectory = false

        mutating func merge(_ other: Self) {
            displayName = other.displayName ?? displayName
            contentLength = other.contentLength ?? contentLength
            lastModified = other.lastModified ?? lastModified
            etag = other.etag ?? etag
            isDirectory = isDirectory || other.isDirectory
        }
    }

    private struct ResponseBuilder {
        var href: String?
        var statusCode: Int?
        var properties = Properties()
    }

    private struct PropstatBuilder {
        var statusCode: Int?
        var properties = Properties()
    }

    private var response: ResponseBuilder?
    private var propstat: PropstatBuilder?
    private var textBuffer = ""
    private var depth = 0
    private var sawMultistatusRoot = false
    private(set) var entries: [WebDAVMultistatusEntry] = []

    static func parse(_ data: Data) throws -> [WebDAVMultistatusEntry] {
        let delegate = WebDAVMultistatusParser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        guard parser.parse() else {
            throw SourceError.connectionFailed(
                parser.parserError?.localizedDescription ?? "Invalid WebDAV XML response"
            )
        }
        guard delegate.sawMultistatusRoot else {
            throw SourceError.connectionFailed("Invalid WebDAV multistatus response")
        }
        return delegate.entries
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let element = Self.localName(qName ?? elementName)
        if depth == 0, element == "multistatus" {
            sawMultistatusRoot = true
        }
        depth += 1
        textBuffer = ""
        switch element {
        case "response":
            response = ResponseBuilder()
        case "propstat":
            propstat = PropstatBuilder()
        case "collection":
            propstat?.properties.isDirectory = true
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        textBuffer += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        defer { depth = max(0, depth - 1) }
        let element = Self.localName(qName ?? elementName)
        let value = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        switch element {
        case "href":
            response?.href = value
        case "displayname":
            propstat?.properties.displayName = value.isEmpty ? nil : value
        case "getcontentlength":
            propstat?.properties.contentLength = Int64(value)
        case "getlastmodified":
            propstat?.properties.lastModified = value.isEmpty ? nil : value
        case "getetag":
            propstat?.properties.etag = value.isEmpty ? nil : value
        case "status":
            let status = Self.statusCode(value)
            if propstat != nil {
                propstat?.statusCode = status
            } else {
                response?.statusCode = status
            }
        case "propstat":
            if let propstat,
               propstat.statusCode.map({ (200...299).contains($0) }) != false {
                response?.properties.merge(propstat.properties)
            }
            propstat = nil
        case "response":
            if let response,
               let href = response.href,
               !href.isEmpty,
               response.statusCode.map({ (200...299).contains($0) }) != false {
                entries.append(
                    WebDAVMultistatusEntry(
                        href: href,
                        displayName: response.properties.displayName,
                        contentLength: response.properties.contentLength,
                        lastModified: response.properties.lastModified,
                        etag: response.properties.etag,
                        isDirectory: response.properties.isDirectory
                    )
                )
            }
            response = nil
        default:
            break
        }
        textBuffer = ""
    }

    private static func localName(_ name: String) -> String {
        name.split(separator: ":").last.map { String($0).lowercased() }
            ?? name.lowercased()
    }

    private static func statusCode(_ value: String) -> Int? {
        value.split(separator: " ").compactMap { Int($0) }.first
    }
}
