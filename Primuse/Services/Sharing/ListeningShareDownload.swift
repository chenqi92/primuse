import Foundation
import PrimuseKit

enum ListeningShareDownload {
    static func download(_ url: URL, maximumBytes: Int64) async throws -> URL {
        _ = try ListeningShareURLPolicy.validate(url.absoluteString, publicSharing: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60 * 60
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let delegate = Delegate(maximumBytes: maximumBytes)
        let (temporary, response) = try await session.download(from: url, delegate: delegate)
        do {
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let finalURL = http.url else { throw ListeningShareError.incompleteFile }
            _ = try ListeningShareURLPolicy.validate(finalURL.absoluteString, publicSharing: true)
            let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, size <= maximumBytes else { throw ListeningShareError.tooLarge }
            let mime = (http.mimeType ?? "").lowercased()
            guard mime.isEmpty || mime.hasPrefix("audio/") || ["application/octet-stream", "application/ogg", "video/mp4"].contains(mime) else {
                throw ListeningShareError.invalidPackage
            }
            return temporary
        } catch { try? FileManager.default.removeItem(at: temporary); throw error }
    }

    private final class Delegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let maximumBytes: Int64
        init(maximumBytes: Int64) { self.maximumBytes = maximumBytes }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            guard let url = request.url, (try? ListeningShareURLPolicy.validate(url.absoluteString, publicSharing: true)) != nil else {
                completionHandler(nil); return
            }
            completionHandler(request)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            if totalBytesWritten > maximumBytes || totalBytesExpectedToWrite > maximumBytes { downloadTask.cancel() }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    }
}
