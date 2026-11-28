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

    @Test("A queued download waits up to the queued timeout before giving up")
    func queuedDownloadWaitsLongerThanIdle() {
        var monitor = Policy.Monitor(startedAt: 0)
        #expect(monitor.observe(
            status: .notDownloaded,
            isDownloading: false,
            isDownloadRequested: true,
            hasDownloadError: false,
            isOffline: false,
            at: 45
        ) == .waiting)
        #expect(monitor.observe(
            status: .notDownloaded,
            isDownloading: false,
            isDownloadRequested: true,
            hasDownloadError: false,
            isOffline: false,
            at: 89
        ) == .waiting)
        #expect(monitor.observe(
            status: .notDownloaded,
            isDownloading: false,
            isDownloadRequested: true,
            hasDownloadError: false,
            isOffline: false,
            at: 90
        ) == .failed(.neverStarted))

        var resumed = Policy.Monitor(startedAt: 0)
        #expect(resumed.observe(
            status: .notDownloaded,
            isDownloading: false,
            isDownloadRequested: true,
            hasDownloadError: false,
            isOffline: false,
            at: 50
        ) == .waiting)
        #expect(resumed.observe(
            status: .notDownloaded,
            isDownloading: true,
            isDownloadRequested: true,
            hasDownloadError: false,
            isOffline: false,
            at: 120
        ) == .waiting)
        #expect(resumed.observe(
            status: .current,
            isDownloading: false,
            isDownloadRequested: false,
            hasDownloadError: false,
            isOffline: false,
            at: 125
        ) == .ready)
    }

    @Test("Upcoming iCloud prefetch count respects settings and metered network")
    func upcomingPrefetchCount() {
        #expect(Policy.upcomingPrefetchCount(configured: 0, isMeteredNetwork: false) == 0)
        #expect(Policy.upcomingPrefetchCount(configured: 2, isMeteredNetwork: false) == 2)
        #expect(Policy.upcomingPrefetchCount(configured: 10, isMeteredNetwork: false) == Policy.maxUpcomingPrefetchCount)
        let metered = UpcomingPlaybackPrefetchPolicy.plannedSongCount(configured: 4, isMeteredNetwork: true)
        #expect(Policy.upcomingPrefetchCount(configured: 4, isMeteredNetwork: true) == min(metered, Policy.maxUpcomingPrefetchCount))
        #expect(Policy.upcomingPrefetchCount(configured: 0, isMeteredNetwork: true) == 0)
    }

    @Test("Progress normalization and status formatting")
    func progressFormatting() {
        #expect(Policy.normalizedProgressFraction(percent: nil) == nil)
        #expect(Policy.normalizedProgressFraction(percent: .nan) == nil)
        #expect(Policy.normalizedProgressFraction(percent: -10) == nil)
        #expect(Policy.normalizedProgressFraction(percent: 42.5) == 0.425)
        #expect(Policy.normalizedProgressFraction(percent: 150) == 1)

        let chinese = Locale(identifier: "zh_Hans_CN")
        #expect(Policy.formattedDownloadStatus(baseText: "正在从 iCloud 下载", progress: nil, locale: chinese) == "正在从 iCloud 下载")
        #expect(Policy.formattedDownloadStatus(baseText: "正在从 iCloud 下载", progress: 0, locale: chinese) == "正在从 iCloud 下载")
        #expect(Policy.formattedDownloadStatus(baseText: "正在从 iCloud 下载", progress: 0.426, locale: chinese) == "正在从 iCloud 下载 42%")
        #expect(Policy.formattedDownloadStatus(baseText: "正在从 iCloud 下载", progress: 0.999, locale: chinese) == "正在从 iCloud 下载 99%")
        #expect(Policy.formattedDownloadStatus(baseText: "正在从 iCloud 下载", progress: 1.0, locale: chinese) == "正在从 iCloud 下载")
        // 百分号放在哪边按语言来,不是硬写在数字后面。
        #expect(Policy.formattedDownloadStatus(baseText: "iCloud", progress: 0.426, locale: Locale(identifier: "tr_TR")) == "iCloud %42")
    }
}
