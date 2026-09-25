import Foundation
import PrimuseKit

/// 每个电台的「刚播过」，落盘在本机。
///
/// 播放器的 `radioTitleHistory` 只属于这一次收听（换台、暂停再续都会清空），
/// 电台详情页要回答的是「这个台最近放过什么」，所以另存一份按电台分开的。
/// 只在本机，不进 CloudKit —— 听到什么是这台设备上发生的事，
/// 跨设备合并反而会把两边各自的时间线搅在一起。
///
/// 写入由播放器在电台推来新标题时调用（见 `AudioPlayerService+Radio`），
/// 攒 3 秒合并成一次写盘；进后台/退出前由 `flush()` 兜底。
@MainActor
@Observable
final class RadioTitleHistoryStore {
    static let shared = RadioTitleHistoryStore()

    private(set) var log: [String: RadioStationHeardTitles] = [:]

    @ObservationIgnored private let storeURL: URL
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    /// `storeURL` 给测试用；应用里用 `shared`。
    init(storeURL: URL? = nil) {
        if let storeURL {
            self.storeURL = storeURL
        } else {
            let base = FileManager.default.primuseDirectoryURL(for: .applicationSupportDirectory)
                .appendingPathComponent("Primuse", isDirectory: true)
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            self.storeURL = base.appendingPathComponent("radio-title-history.json")
        }
        load()
    }

    /// 这个台听到过的标题，最新的在最前。
    func entries(forStationID stationID: String) -> [RadioHeardTitle] {
        log[stationID]?.entries ?? []
    }

    /// 记下一条电台推来的标题。与该台最近一条相同就什么也不做。
    func record(_ metadata: RadioLiveMetadata, stationID: String, at date: Date = Date()) {
        guard let title = metadata.title else { return }
        let entry = RadioHeardTitle(
            text: title.rawText,
            artist: title.artist,
            title: title.title,
            artworkURL: metadata.artworkURL,
            heardAt: date
        )
        guard let updated = RadioHeardTitlePolicy.recording(entry, stationID: stationID, in: log) else {
            return
        }
        log = updated
        scheduleSave()
    }

    /// 清掉一个台的记录（详情页「清除」、电台被删除时）。
    func clear(stationID: String) {
        guard log.removeValue(forKey: stationID) != nil else { return }
        scheduleSave()
    }

    /// 立刻写盘。进后台、退出前调。
    func flush() {
        guard saveTask != nil else { return }
        saveTask?.cancel()
        saveTask = nil
        saveNow()
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode([String: RadioStationHeardTitles].self, from: data) else {
            return
        }
        log = RadioHeardTitlePolicy.sanitized(decoded)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.saveTask = nil
            self?.saveNow()
        }
    }

    private func saveNow() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(log) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}
