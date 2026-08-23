import Foundation

/// Builds the JSON payload used to transfer cached lyrics between Primuse
/// devices without ever materializing the entire lyrics directory as a Swift
/// dictionary. The output format remains `{ "<hash>.json": "<base64>" }` for
/// backward compatibility with existing snapshots.
public enum LyricsSnapshotEncoder {
    public struct Result: Sendable {
        public let data: Data
        public let fileCount: Int
        public let skippedFileCount: Int
        public let isTruncated: Bool
    }

    public static func encodeDirectory(
        _ directory: URL,
        maximumOutputBytes: Int,
        maximumFileBytes: Int,
        allowedFileNames: Set<String>? = nil,
        fileManager: FileManager = .default
    ) -> Result? {
        guard maximumOutputBytes >= 2, maximumFileBytes > 0 else { return nil }

        let keys: Set<URLResourceKey> = [
            .contentModificationDateKey,
            .fileSizeKey,
            .isRegularFileKey,
        ]
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        struct Candidate {
            let url: URL
            let name: String
            let modifiedAt: Date
            let fileSize: Int?
        }

        var skipped = 0
        var candidates: [Candidate] = []
        candidates.reserveCapacity(urls.count)
        for url in urls {
            guard !Task.isCancelled else { return nil }
            let name = url.lastPathComponent
            if let allowedFileNames, !allowedFileNames.contains(name) {
                continue
            }
            guard isValidFileName(name),
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else {
                skipped += 1
                continue
            }
            let size = values.fileSize
            if let size, size <= 0 || size > maximumFileBytes {
                skipped += 1
                continue
            }
            candidates.append(
                Candidate(
                    url: url,
                    name: name,
                    modifiedAt: values.contentModificationDate ?? .distantPast,
                    fileSize: size
                )
            )
        }

        // When the cache is larger than the transport budget, keep the most
        // recently updated lyrics. A name tie-breaker makes snapshots stable.
        candidates.sort {
            if $0.modifiedAt != $1.modifiedAt {
                return $0.modifiedAt > $1.modifiedAt
            }
            return $0.name < $1.name
        }

        var output = Data()
        output.reserveCapacity(min(maximumOutputBytes, 256 * 1024))
        output.append(0x7B) // {

        var fileCount = 0
        var truncated = false
        for candidate in candidates {
            guard !Task.isCancelled else { return nil }
            let commaBytes = fileCount == 0 ? 0 : 1
            let fixedBytes = commaBytes + candidate.name.utf8.count + 5
            let availableForBase64 = maximumOutputBytes - output.count - fixedBytes - 1
            guard availableForBase64 > 0 else {
                skipped += 1
                truncated = true
                continue
            }

            if let fileSize = candidate.fileSize {
                let expectedBase64Bytes = ((fileSize + 2) / 3) * 4
                guard expectedBase64Bytes <= availableForBase64 else {
                    skipped += 1
                    truncated = true
                    continue
                }
            }

            guard let raw = try? Data(contentsOf: candidate.url, options: [.mappedIfSafe]),
                  !raw.isEmpty,
                  raw.count <= maximumFileBytes else {
                skipped += 1
                continue
            }
            let base64 = raw.base64EncodedData()
            guard base64.count <= availableForBase64 else {
                skipped += 1
                truncated = true
                continue
            }

            if fileCount > 0 { output.append(0x2C) } // ,
            output.append(0x22) // "
            output.append(contentsOf: candidate.name.utf8)
            output.append(contentsOf: [0x22, 0x3A, 0x22]) // ":"
            output.append(base64)
            output.append(0x22) // "
            fileCount += 1
        }

        guard fileCount > 0 else { return nil }
        output.append(0x7D) // }
        return Result(
            data: output,
            fileCount: fileCount,
            skippedFileCount: skipped,
            isTruncated: truncated
        )
    }

    public static func isValidFileName(_ name: String) -> Bool {
        guard name.count == 37, name.hasSuffix(".json") else { return false }
        return name.prefix(32).unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 48...57, 65...70, 97...102:
                true
            default:
                false
            }
        }
    }
}
