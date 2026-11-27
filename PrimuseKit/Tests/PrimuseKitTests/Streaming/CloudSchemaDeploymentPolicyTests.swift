import Foundation
import Testing
@testable import PrimuseKit

@Suite("CloudKit production schema gaps")
struct CloudSchemaDeploymentPolicyTests {
    private let domain = CloudSchemaDeploymentPolicy.errorDomain
    private let code = CloudSchemaDeploymentPolicy.invalidArgumentsCode

    @Test("A missing record type is recognised from the CloudKit message")
    func detectsMissingRecordType() {
        let gap = CloudSchemaDeploymentPolicy.gap(
            domain: domain,
            code: code,
            message: """
            Error saving record <CKRecordID: 0x92f2fa320; recordName=library-snapshot, \
            zoneID=_defaultZone:__defaultOwner__> to server: \
            Cannot create new type LibrarySnapshot in production schema
            """
        )
        #expect(gap == .recordType("LibrarySnapshot"))
        #expect(gap?.name == "LibrarySnapshot")
    }

    @Test("A missing field is recognised and unquoted")
    func detectsMissingField() {
        let gap = CloudSchemaDeploymentPolicy.gap(
            domain: domain,
            code: code,
            message: "Cannot create new field 'radioStationsGz' in production schema"
        )
        #expect(gap == .field("radioStationsGz"))
    }

    @Test("The server description is inspected when the localized text is generic")
    func detectsServerDescription() {
        let error = NSError(
            domain: domain,
            code: code,
            userInfo: [
                NSLocalizedDescriptionKey: "Invalid Arguments",
                "ServerErrorDescription":
                    "Cannot create new field 'logoData' in production schema",
            ]
        )
        #expect(CloudSchemaDeploymentPolicy.gap(in: error) == .field("logoData"))
    }

    @Test("A schema rejection nested in a partial failure is detected")
    func detectsNestedPartialFailure() {
        let recordError = NSError(
            domain: domain,
            code: code,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Cannot create new type RadioStation in production schema",
            ]
        )
        let partialFailure = NSError(
            domain: domain,
            code: 2,
            userInfo: ["CKPartialErrors": ["RadioStation/1": recordError]]
        )
        #expect(
            CloudSchemaDeploymentPolicy.gap(in: partialFailure)
                == .recordType("RadioStation")
        )
    }

    @Test("Unrelated CloudKit failures are not misread as schema gaps")
    func ignoresUnrelatedFailures() {
        #expect(CloudSchemaDeploymentPolicy.gap(
            domain: domain,
            code: code,
            message: "Invalid arguments: asset file size exceeds the limit"
        ) == nil)
        // Right message, wrong code — a quota or network error must stay itself.
        #expect(CloudSchemaDeploymentPolicy.gap(
            domain: domain,
            code: 25,
            message: "Cannot create new type LibrarySnapshot in production schema"
        ) == nil)
        #expect(CloudSchemaDeploymentPolicy.gap(
            domain: NSURLErrorDomain,
            code: code,
            message: "Cannot create new type LibrarySnapshot in production schema"
        ) == nil)
    }

    @Test("Schema failures carry their own diagnostic code and name the gap")
    func schemaFailureSurfacesGap() {
        let failure = AppleTVTransferFailure.cloudSchemaNotDeployed(
            gap: .recordType("LibrarySnapshot")
        )
        #expect(failure.diagnosticCode == "TV-ICLOUD-SCHEMA")
        #expect(failure.userFacingMessage.contains("LibrarySnapshot"))
        #expect(failure != .cloudUploadFailed(detail: "LibrarySnapshot"))
    }
}
