import Foundation
import Testing
@testable import PrimuseKit

@MainActor
struct LyricLineCommentsTests {
    private func withStore(_ body: (LyricLineCommentStore, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(LyricLineCommentStore(directory: directory), directory)
    }

    @Test func commentsSurviveRestartRetimingAndRegeneratedLineIDs() throws {
        try withStore { store, directory in
            let original = LyricLine(id: "old", timestamp: 10, text: "纸船经过小桥")
            let anchor = try #require(LyricLineCommentAnchor.index([original])["old"])
            try store.save(songID: "song", anchor: anchor, text: "  想起从前的河岸。  ")
            let reloaded = LyricLine(id: "new", timestamp: 12.5, text: "纸船经过小桥")
            let newAnchor = try #require(LyricLineCommentAnchor.index([reloaded])["new"])
            let restored = LyricLineCommentStore(directory: directory)
            #expect(try restored.comment(songID: "song", anchor: newAnchor)?.text == "想起从前的河岸。")
            #expect(try restored.comment(songID: "another-song", anchor: newAnchor) == nil)
        }
    }

    @Test func repeatedLinesAndVoicesHaveIndependentComments() throws {
        try withStore { store, _ in
            let lines = [
                LyricLine(id: "a", timestamp: 10, text: "晚风会回来", background: [
                    LyricLine(id: "harmony", timestamp: 11, text: "晚风会回来")
                ]),
                LyricLine(id: "b", timestamp: 40, text: "晚风会回来"),
            ]
            let anchors = LyricLineCommentAnchor.index(lines)
            try store.save(songID: "song", anchor: #require(anchors["a"]), text: "第一次")
            try store.save(songID: "song", anchor: #require(anchors["b"]), text: "第二次")
            #expect(try store.comments(songID: "song").map(\.text) == ["第一次", "第二次"])
            try store.save(songID: "song", anchor: #require(anchors["harmony"]), text: "和声")
            #expect(try store.comment(songID: "song", anchor: #require(anchors["a"]))?.text == "第一次")
            #expect(try store.comment(songID: "song", anchor: #require(anchors["harmony"]))?.text == "和声")
            let voice = LyricLineCommentAnchor(text: lines[0].text, occurrence: 0, voice: .secondary, timestamp: 10)
            #expect(try store.comment(songID: "song", anchor: voice) == nil)
        }
    }

    @Test func replacingLyricsDoesNotDeleteSavedOriginalLines() throws {
        try withStore { store, directory in
            let old = LyricLineCommentAnchor(text: "月色落在窗台", occurrence: 0, timestamp: 5)
            try store.save(songID: "song", anchor: old, text: "留着这一句")
            let replacement = LyricLineCommentAnchor(text: "换了一份歌词", occurrence: 0, timestamp: 5)
            #expect(try store.comment(songID: "song", anchor: replacement) == nil)
            let restored = LyricLineCommentStore(directory: directory)
            #expect(try restored.comments(songID: "song").first?.anchor.text == old.text)
        }
    }

    @Test func editingAndClearingOneLinePreservesOtherLinesAndWindows() throws {
        try withStore { store, directory in
            let first = LyricLineCommentAnchor(text: "雨停了", occurrence: 0, timestamp: 1)
            let second = LyricLineCommentAnchor(text: "灯亮了", occurrence: 0, timestamp: 2)
            let other = LyricLineCommentStore(directory: directory)
            _ = try other.comments(songID: "song")
            try store.save(songID: "song", anchor: first, text: "第一句")
            try other.save(songID: "song", anchor: second, text: "第二句")
            try store.save(songID: "song", anchor: first, text: "改过了")
            try store.save(songID: "song", anchor: first, text: "  \n ")
            let restored = LyricLineCommentStore(directory: directory)
            #expect(try restored.comments(songID: "song").map(\.text) == ["第二句"])
        }
    }

    @Test func corruptStorageIsNotOverwrittenAndFailedSaveDoesNotPublishDraft() throws {
        try withStore { store, directory in
            let anchor = LyricLineCommentAnchor(text: "天边的信", occurrence: 0, timestamp: 0)
            try store.save(songID: "song", anchor: anchor, text: "已保存")
            let file = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
            let corrupt = Data("damaged".utf8)
            try corrupt.write(to: file)
            #expect(throws: (any Error).self) { try store.save(songID: "song", anchor: anchor, text: "未保存") }
            #expect(try Data(contentsOf: file) == corrupt)
            #expect(try store.comment(songID: "song", anchor: anchor)?.text == "已保存")
        }
    }

    @Test func offlineDevicesMergeDifferentLinesAndPendingChangesSurviveRestart() throws {
        try withStore { first, firstDirectory in
            try withStore { second, secondDirectory in
                let a = LyricLineCommentAnchor(text: "纸船驶向晨光", occurrence: 0, timestamp: 5)
                let b = LyricLineCommentAnchor(text: "灯火留在岸边", occurrence: 0, timestamp: 10)
                try first.save(songID: "song", anchor: a, text: "手机上的评论")
                try second.save(songID: "song", anchor: b, text: "电脑上的评论")
                let firstUpload = try #require(LyricLineCommentStore(directory: firstDirectory).syncRecords(pendingOnly: true).first)
                let secondUpload = try #require(second.syncRecords(pendingOnly: true).first)
                try first.applyRemote(secondUpload)
                try second.applyRemote(firstUpload)
                #expect(try first.comments(songID: "song").map(\.text) == ["手机上的评论", "电脑上的评论"])
                #expect(try LyricLineCommentStore(directory: secondDirectory).comments(songID: "song") == first.comments(songID: "song"))
                #expect(try first.syncRecords(pendingOnly: true).map(\.id) == [firstUpload.id])
                try first.acknowledgeUpload(firstUpload)
                #expect(try LyricLineCommentStore(directory: firstDirectory).syncRecords(pendingOnly: true).isEmpty)
            }
        }
    }

    @Test func deletionTombstoneRejectsStaleDeviceAndCanBeExplicitlyRestored() throws {
        try withStore { store, directory in
            let anchor = LyricLineCommentAnchor(text: "月亮落进杯中", occurrence: 0, timestamp: 1)
            let time = Date(timeIntervalSince1970: 100)
            try store.save(songID: "song", anchor: anchor, text: "旧评论", now: time)
            let stale = try #require(store.syncRecords().first)
            try store.save(songID: "song", anchor: anchor, text: "", now: time.addingTimeInterval(1))
            let restored = LyricLineCommentStore(directory: directory)
            #expect(try restored.applyRemote(stale))
            #expect(try restored.comment(songID: "song", anchor: anchor) == nil)
            let deleted = try #require(restored.syncRecords(pendingOnly: true).first)
            #expect(deleted.comment.isDeleted)
            try restored.save(songID: "song", anchor: anchor, text: "重新写下", now: time)
            #expect(try restored.applyRemote(deleted))
            #expect(try restored.comment(songID: "song", anchor: anchor)?.text == "重新写下")
        }
    }

    @Test func acknowledgementOfAnOlderUploadDoesNotClearNewerPendingEdit() throws {
        try withStore { store, directory in
            let anchor = LyricLineCommentAnchor(text: "小桥等着晚风", occurrence: 0, timestamp: 2)
            try store.save(songID: "song", anchor: anchor, text: "第一次")
            let inFlight = try #require(store.syncRecords(pendingOnly: true).first)
            try store.save(songID: "song", anchor: anchor, text: "发送时继续修改")
            try store.acknowledgeUpload(inFlight)
            let pending = try LyricLineCommentStore(directory: directory).syncRecords(pendingOnly: true)
            #expect(pending.map(\.comment.text) == ["发送时继续修改"])
        }
    }

    @Test func equalClockEditsConvergeAndDeletionWinsATie() {
        let anchor = LyricLineCommentAnchor(text: "留一盏灯", occurrence: 0, timestamp: 3)
        let time = Date(timeIntervalSince1970: 100)
        let a = LyricLineComment(anchor: anchor, text: "a", updatedAt: time)
        let b = LyricLineComment(anchor: anchor, text: "b", updatedAt: time)
        let deleted = LyricLineComment(anchor: anchor, text: "", updatedAt: time, deletedAt: time)
        #expect(LyricLineComment.winner(a, b) == LyricLineComment.winner(b, a))
        #expect(LyricLineComment.winner(a, deleted) == deleted)
        #expect(LyricLineComment.winner(deleted, a) == deleted)
    }

    @Test func legacyLocalCommentsAreSeededWithoutChangingTheirContents() throws {
        try withStore { store, directory in
            let anchor = LyricLineCommentAnchor(text: "晨风敲响小窗", occurrence: 0, timestamp: 2)
            try store.save(songID: "song", anchor: anchor, text: "旧版本留下的评论")
            let file = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
            var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            json.removeValue(forKey: "pendingUploadIDs")
            try JSONSerialization.data(withJSONObject: json).write(to: file)
            let upgraded = LyricLineCommentStore(directory: directory)
            let record = try #require(upgraded.syncRecords(pendingOnly: true).first)
            #expect(record.comment.text == "旧版本留下的评论")
            #expect(try upgraded.syncRecord(for: record.id) == record)
            #expect(record.id.hasPrefix(LyricLineCommentSyncRecord.prefix))
            try upgraded.acknowledgeUpload(record)
            #expect(try upgraded.syncRecords(pendingOnly: true).isEmpty)
        }
    }

    @Test func failedRemoteMergeDoesNotOverwriteCorruptLocalData() throws {
        try withStore { store, directory in
            let anchor = LyricLineCommentAnchor(text: "走过雾里的桥", occurrence: 0, timestamp: 1)
            try store.save(songID: "song", anchor: anchor, text: "保留")
            let record = try #require(store.syncRecords().first)
            let file = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
            let corrupt = Data("damaged".utf8)
            try corrupt.write(to: file)
            #expect(throws: (any Error).self) { try store.applyRemote(record) }
            #expect(try Data(contentsOf: file) == corrupt)
            #expect(try store.comment(songID: "song", anchor: anchor)?.text == "保留")
        }
    }
}
