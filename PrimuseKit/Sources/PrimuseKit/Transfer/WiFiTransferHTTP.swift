import Foundation

struct WiFiTransferRequest {
    let method: String
    let route: String
    let path: String
    let headers: [String: String]
    let contentLength: Int64

    init(_ data: Data) throws {
        guard data.count <= 16 * 1024, let text = String(data: data, encoding: .utf8) else {
            throw WiFiTransferError.invalidRequest
        }
        let lines = text.components(separatedBy: "\r\n")
        let request = (lines.first ?? "").split(separator: " ", omittingEmptySubsequences: false)
        guard request.count == 3, request[2] == "HTTP/1.1", request[1].hasPrefix("/"),
              !request[1].hasPrefix("//"),
              let components = URLComponents(string: String(request[1])),
              components.fragment == nil, components.host == nil else {
            throw WiFiTransferError.invalidRequest
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":"),
                  !line.hasPrefix(" "), !line.hasPrefix("\t") else { throw WiFiTransferError.invalidRequest }
            let name = String(line[..<colon]).lowercased()
            guard !name.isEmpty, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }),
                  headers[name] == nil else { throw WiFiTransferError.invalidRequest }
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["host"] != nil, headers["transfer-encoding"] == nil,
              headers["expect"] == nil else { throw WiFiTransferError.invalidRequest }
        let sizeString = headers["content-length"] ?? "0"
        guard !sizeString.isEmpty, sizeString.allSatisfy({ $0.isASCII && $0.isNumber }),
              let size = Int64(sizeString) else { throw WiFiTransferError.invalidRequest }
        let paths = components.queryItems?.filter { $0.name == "path" } ?? []
        guard paths.count <= 1 else { throw WiFiTransferError.invalidRequest }
        method = String(request[0])
        route = components.path
        path = paths.first?.value ?? ""
        self.headers = headers
        contentLength = size
    }
}

struct WiFiTransferAuthorization {
    let code: String
    private var failures = 0
    private var blockedUntil = Date.distantPast

    init(code: String) { self.code = code }

    mutating func validate(_ supplied: String?, now: Date = Date()) throws {
        guard now >= blockedUntil else { throw WiFiTransferError.tooManyAttempts }
        guard supplied == code else {
            failures += 1
            if failures >= 5 {
                failures = 0
                blockedUntil = now.addingTimeInterval(30)
            }
            throw WiFiTransferError.unauthorized
        }
        failures = 0
    }
}
