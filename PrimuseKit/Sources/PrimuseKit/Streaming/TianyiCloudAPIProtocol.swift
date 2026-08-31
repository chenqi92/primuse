import Foundation

public enum TianyiCloudIntegrationRequirement: String, CaseIterable, Hashable, Sendable {
    case commercialAgreement
    case businessDeveloperApproval
    case currentAPIContract
    case fileAndDownloadAbilityGrant
    case productionApplicationCredentials
    case serverSideRequestSigner
    case endUserAuthorizationContract
    case tokenRevocationContract
    case authorizedTestAccount
    case downloadTransportValidation
    case connectorVerification
    case localizedProductReview
}

public struct TianyiCloudIntegrationReadiness: Equatable, Sendable {
    public let satisfiedRequirements: Set<TianyiCloudIntegrationRequirement>

    public init(satisfiedRequirements: Set<TianyiCloudIntegrationRequirement>) {
        self.satisfiedRequirements = satisfiedRequirements
    }

    public var unmetRequirements: [TianyiCloudIntegrationRequirement] {
        TianyiCloudIntegrationRequirement.allCases.filter {
            !satisfiedRequirements.contains($0)
        }
    }

    /// Registering a source before every external and product requirement is
    /// satisfied would expose an authorization flow that cannot safely finish.
    public var canRegisterSource: Bool {
        unmetRequirements.isEmpty
    }
}

public enum TianyiCloudCredentialMaterial: Hashable, Sendable {
    case accessToken
    case refreshToken
    case applicationSecret
    case rsaPrivateKey
}

public enum TianyiCloudCredentialResidence: Equatable, Sendable {
    case perSourceKeychain
    case serverOnly
}

public enum TianyiCloudCredentialPolicy {
    public static func requiredResidence(
        for material: TianyiCloudCredentialMaterial
    ) -> TianyiCloudCredentialResidence {
        switch material {
        case .accessToken, .refreshToken:
            return .perSourceKeychain
        case .applicationSecret, .rsaPrivateKey:
            // Current signed requests depend on both values. Shipping either
            // one would let an extracted app binary impersonate the partner.
            return .serverOnly
        }
    }
}

public struct TianyiCloudOpaqueID: Hashable, Decodable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            rawValue = value
            return
        }
        if let value = try? container.decode(Int64.self) {
            rawValue = String(value)
            return
        }
        throw DecodingError.typeMismatch(
            String.self,
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Expected a Tianyi opaque identifier encoded as a string or integer."
            )
        )
    }
}

public struct TianyiCloudListFilesResponse: Decodable, Equatable, Sendable {
    public let resultCode: String
    public let resultMessage: String?
    public let catalog: TianyiCloudFileList?
    public let lastRevision: String?

    public var isSuccess: Bool {
        resultCode == "0"
    }

    private enum CodingKeys: String, CodingKey {
        case resultCode = "res_code"
        case resultMessage = "res_message"
        case catalog = "fileListAO"
        case lastRevision = "lastRev"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        resultCode = try container.decodeTianyiRequiredString(forKey: .resultCode)
        resultMessage = try container.decodeIfPresent(String.self, forKey: .resultMessage)
        catalog = try container.decodeIfPresent(TianyiCloudFileList.self, forKey: .catalog)
        lastRevision = try container.decodeTianyiStringIfPresent(forKey: .lastRevision)
    }
}

public struct TianyiCloudFileList: Decodable, Equatable, Sendable {
    public let totalItemCount: Int?
    public let folders: [TianyiCloudFolder]
    public let files: [TianyiCloudFile]
    public let reportedFileCount: Int?

    public var receivedItemCount: Int {
        folders.count + files.count
    }

    private enum CodingKeys: String, CodingKey {
        case totalItemCount = "count"
        case folders = "folderList"
        case files = "fileList"
        case reportedFileCount = "fileListSize"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        totalItemCount = try container.decodeTianyiIntIfPresent(forKey: .totalItemCount)
        folders = try container.decodeIfPresent([TianyiCloudFolder].self, forKey: .folders) ?? []
        files = try container.decodeIfPresent([TianyiCloudFile].self, forKey: .files) ?? []
        reportedFileCount = try container.decodeTianyiIntIfPresent(forKey: .reportedFileCount)
    }
}

public struct TianyiCloudFolder: Decodable, Equatable, Sendable {
    public let id: TianyiCloudOpaqueID?
    public let name: String?
    public let parentID: TianyiCloudOpaqueID?
    public let revision: String?
    public let creationDate: String?
    public let lastOperationTime: String?

    public var providerID: String? {
        id?.rawValue
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case parentID = "parentId"
        case revision = "rev"
        case creationDate = "createDate"
        case lastOperationTime = "lastOpTime"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(TianyiCloudOpaqueID.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        parentID = try container.decodeIfPresent(TianyiCloudOpaqueID.self, forKey: .parentID)
        revision = try container.decodeTianyiStringIfPresent(forKey: .revision)
        creationDate = try container.decodeIfPresent(String.self, forKey: .creationDate)
        lastOperationTime = try container.decodeIfPresent(String.self, forKey: .lastOperationTime)
    }
}

public struct TianyiCloudFile: Decodable, Equatable, Sendable {
    public let id: TianyiCloudOpaqueID?
    public let name: String?
    public let parentID: TianyiCloudOpaqueID?
    public let revision: String?
    public let size: Int64?
    public let md5: String?
    public let mediaType: Int?
    public let creationDate: String?
    public let lastOperationTime: String?

    public var providerID: String? {
        id?.rawValue
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case parentID = "parentId"
        case revision = "rev"
        case size
        case md5
        case mediaType
        case creationDate = "createDate"
        case lastOperationTime = "lastOpTime"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(TianyiCloudOpaqueID.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        parentID = try container.decodeIfPresent(TianyiCloudOpaqueID.self, forKey: .parentID)
        revision = try container.decodeTianyiStringIfPresent(forKey: .revision)
        size = try container.decodeTianyiInt64IfPresent(forKey: .size)
        md5 = try container.decodeIfPresent(String.self, forKey: .md5)
        mediaType = try container.decodeTianyiIntIfPresent(forKey: .mediaType)
        creationDate = try container.decodeIfPresent(String.self, forKey: .creationDate)
        lastOperationTime = try container.decodeIfPresent(String.self, forKey: .lastOperationTime)
    }
}

public struct TianyiCloudCatalogPage: Equatable, Sendable {
    public let response: TianyiCloudListFilesResponse
    public let pageNumber: Int
    public let pageSize: Int

    public init(
        response: TianyiCloudListFilesResponse,
        pageNumber: Int,
        pageSize: Int
    ) {
        self.response = response
        self.pageNumber = pageNumber
        self.pageSize = pageSize
    }

    public var nextPageNumber: Int? {
        guard response.isSuccess, let catalog = response.catalog else { return nil }
        return TianyiCloudCatalogPagingPolicy.nextPageNumber(
            currentPage: pageNumber,
            pageSize: pageSize,
            receivedItemCount: catalog.receivedItemCount,
            totalItemCount: catalog.totalItemCount
        )
    }
}

public enum TianyiCloudCatalogPagingPolicy {
    public static func nextPageNumber(
        currentPage: Int,
        pageSize: Int,
        receivedItemCount: Int,
        totalItemCount: Int?
    ) -> Int? {
        guard currentPage >= 1,
              pageSize > 0,
              receivedItemCount > 0,
              receivedItemCount <= pageSize else {
            return nil
        }

        let (priorItemCount, multiplicationOverflow) = (currentPage - 1)
            .multipliedReportingOverflow(by: pageSize)
        guard !multiplicationOverflow else { return nil }
        let (consumedItemCount, additionOverflow) = priorItemCount
            .addingReportingOverflow(receivedItemCount)
        guard !additionOverflow else { return nil }

        guard let totalItemCount,
              totalItemCount >= 0,
              consumedItemCount <= totalItemCount else { return nil }
        guard consumedItemCount < totalItemCount else { return nil }

        // A short non-final page contradicts the advertised count. Stopping
        // avoids skipping records if the directory changed during traversal.
        guard receivedItemCount == pageSize else { return nil }

        let (nextPage, pageOverflow) = currentPage.addingReportingOverflow(1)
        return pageOverflow ? nil : nextPage
    }
}

public enum TianyiCloudCatalogSyncPolicy {
    /// `lastRev` is documented as the latest storage revision, but no public
    /// change-feed operation documents how to consume it as a delta cursor.
    public static let supportsNativeDeltaFeed = false

    public static func snapshotRevisionHint(
        from response: TianyiCloudListFilesResponse
    ) -> String? {
        response.lastRevision
    }
}

public enum TianyiCloudPlaybackStrategy: Equatable, Sendable {
    case controlledFullFileCache
    case verifiedByteRange(totalLength: Int64)
}

public enum TianyiCloudPlaybackPolicy {
    public static func strategyForProbe(
        statusCode: Int,
        contentRange: String?,
        contentLength: Int64?,
        receivedBodyLength: Int
    ) -> TianyiCloudPlaybackStrategy {
        guard statusCode == 206,
              let totalLength = HTTPRangeProbePolicy.validatedTotalLength(
                  contentRange: contentRange,
                  contentLength: contentLength
              ),
              receivedBodyLength == Int(min(Int64(2), totalLength)) else {
            return .controlledFullFileCache
        }
        return .verifiedByteRange(totalLength: totalLength)
    }
}

private extension KeyedDecodingContainer {
    func decodeTianyiRequiredString(forKey key: Key) throws -> String {
        if let value = try decodeTianyiStringIfPresent(forKey: key) {
            return value
        }
        throw DecodingError.keyNotFound(
            key,
            DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Missing required Tianyi response field."
            )
        )
    }

    func decodeTianyiStringIfPresent(forKey key: Key) throws -> String? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        if let value = try? decode(String.self, forKey: key) { return value }
        if let value = try? decode(Int64.self, forKey: key) { return String(value) }
        throw DecodingError.typeMismatch(
            String.self,
            DecodingError.Context(
                codingPath: codingPath + [key],
                debugDescription: "Expected a Tianyi field encoded as a string or integer."
            )
        )
    }

    func decodeTianyiIntIfPresent(forKey key: Key) throws -> Int? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        if let value = try? decode(Int.self, forKey: key) { return value }
        if let value = try? decode(String.self, forKey: key), let integer = Int(value) {
            return integer
        }
        throw DecodingError.typeMismatch(
            Int.self,
            DecodingError.Context(
                codingPath: codingPath + [key],
                debugDescription: "Expected a Tianyi integer field."
            )
        )
    }

    func decodeTianyiInt64IfPresent(forKey key: Key) throws -> Int64? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        if let value = try? decode(Int64.self, forKey: key) { return value }
        if let value = try? decode(String.self, forKey: key), let integer = Int64(value) {
            return integer
        }
        throw DecodingError.typeMismatch(
            Int64.self,
            DecodingError.Context(
                codingPath: codingPath + [key],
                debugDescription: "Expected a Tianyi 64-bit integer field."
            )
        )
    }
}
