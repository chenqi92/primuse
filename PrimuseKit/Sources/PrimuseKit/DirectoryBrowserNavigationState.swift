public struct DirectoryBrowserNavigationState: Equatable, Sendable {
    public struct Segment: Equatable, Sendable {
        public let path: String
        public let title: String

        public init(path: String, title: String) {
            self.path = path
            self.title = title
        }
    }

    public struct Request: Equatable, Sendable {
        public let generation: UInt64
        public let path: String
    }

    public private(set) var segments: [Segment]
    public private(set) var requestGeneration: UInt64 = 0

    public var currentPath: String {
        segments[segments.count - 1].path
    }

    public init(rootPath: String = "/", rootTitle: String) {
        segments = [.init(path: rootPath, title: rootTitle)]
    }

    @discardableResult
    public mutating func enterDirectory(path: String, title: String) -> Bool {
        guard path != currentPath else { return false }
        segments.append(.init(path: path, title: title))
        return true
    }

    @discardableResult
    public mutating func navigateToBreadcrumb(at index: Int) -> Bool {
        guard segments.indices.contains(index), index != segments.index(before: segments.endIndex) else {
            return false
        }
        segments = Array(segments.prefix(index + 1))
        return true
    }

    public mutating func beginRequest() -> Request {
        requestGeneration &+= 1
        return Request(generation: requestGeneration, path: currentPath)
    }

    public func accepts(_ request: Request) -> Bool {
        request.generation == requestGeneration && request.path == currentPath
    }
}
