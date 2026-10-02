import Foundation
import Testing
@testable import PrimuseKit

@Suite("iCloud download before playback")
struct UbiquitousPlaybackDownloadPolicyTests {
    typealias Policy = UbiquitousPlaybackDownloadPolicy

    @Test("Only a file that is not on this device needs a download")
    func needsDownload() {
        #expect(Policy.needsDownload(.notDownloaded))
        #expect(!Policy.needsDownload(.downloaded))
        #expect(!Policy.needsDownload(.current))
        #expect(!Policy.needsDownload(.notUbiquitous))
    }

    @Test("A finished download is ready")
    func ready() {
        var monitor = Policy.Monitor(startedAt: 100)
        #expect(monitor.observe(status: .notDownloaded, isDownloading: true, hasDownloadError: false, isOffline: false, at: 101) == .waiting)
        #expect(monitor.observe(status: .current, isDownloading: false, hasDownloadError: false, isOffline: false, at: 140) == .ready)
    }

    @Test("Errors and a missing network fail at once")
    func immediateFailures() {
        var monitor = Policy.Monitor(startedAt: 0)
        #expect(monitor.observe(status: .notDownloaded, isDownloading: true, hasDownloadError: true, isOffline: false, at: 1) == .failed(.downloadError))
        var offline = Policy.Monitor(startedAt: 0)
        #expect(offline.observe(status: .notDownloaded, isDownloading: false, hasDownloadError: false, isOffline: true, at: 1) == .failed(.offline))
        // 已经在本机的文件不受网络影响。
        var local = Policy.Monitor(startedAt: 0)
        #expect(local.observe(status: .downloaded, isDownloading: false, hasDownloadError: false, isOffline: true, at: 1) == .ready)
    }

    @Test("A download that never starts gives up after the idle timeout")
    func neverStarted() {
        var monitor = Policy.Monitor(startedAt: 0)
        #expect(monitor.observe(status: .notDownloaded, isDownloading: false, hasDownloadError: false, isOffline: false, at: 29) == .waiting)
        #expect(monitor.observe(status: .notDownloaded, isDownloading: false, hasDownloadError: false, isOffline: false, at: 30) == .failed(.neverStarted))
    }

    @Test("An active download keeps waiting until the overall limit")
    func activeDownload() {
        var monitor = Policy.Monitor(startedAt: 0)
        #expect(monitor.observe(status: .notDownloaded, isDownloading: true, hasDownloadError: false, isOffline: false, at: 200) == .waiting)
        // 下载停了一会儿:从最后一次见到在下载算起,不是从开始算。
        #expect(monitor.observe(status: .notDownloaded, isDownloading: false, hasDownloadError: false, isOffline: false, at: 220) == .waiting)
        #expect(monitor.observe(status: .notDownloaded, isDownloading: false, hasDownloadError: false, isOffline: false, at: 230) == .failed(.neverStarted))
        var long = Policy.Monitor(startedAt: 0)
        #expect(long.observe(status: .notDownloaded, isDownloading: true, hasDownloadError: false, isOffline: false, at: 600) == .failed(.timedOut))
    }
}
