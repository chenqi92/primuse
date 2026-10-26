import Foundation
import Testing
@testable import PrimuseKit

@Suite("CUE 分轨共用整轨文件的首尾段")
struct SharedFileRangeMemoTests {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func file(_ path: String = "/album/CDImage.ape", size: Int64 = 400_000_000,
                      revision: String? = "r1") -> SharedFileRangeMemo.FileKey {
        SharedFileRangeMemo.FileKey(sourceID: "baidu", path: path, fileSize: size,
                                    revision: revision, modifiedAt: start)
    }

    private func bytes(_ count: Int, _ value: UInt8 = 1) -> Data {
        Data(repeating: value, count: count)
    }

    @Test("另一条分轨读同一段时直接拿到, 首段和尾段各认各的")
    func siblingReuse() {
        let memo = SharedFileRangeMemo()
        let head = bytes(256 * 1024, 1)
        let tail = bytes(256 * 1024, 2)
        memo.store(head, for: file(), offset: 0, length: 262_144, now: start)
        memo.store(tail, for: file(), offset: -262_144, length: 262_144, now: start)

        #expect(memo.data(for: file(), offset: 0, length: 262_144, now: start + 5) == head)
        #expect(memo.data(for: file(), offset: -262_144, length: 262_144, now: start + 5) == tail)
        // 偏移或长度不一样不算命中。
        #expect(memo.data(for: file(), offset: 0, length: 65_536, now: start + 5) == nil)
        #expect(memo.data(for: file(), offset: 262_144, length: 262_144, now: start + 5) == nil)
    }

    @Test("文件变了(大小、版本、修改时间、路径、源)就不再给旧字节")
    func fileIdentity() {
        let memo = SharedFileRangeMemo()
        memo.store(bytes(1024), for: file(), offset: 0, length: 1024, now: start)

        #expect(memo.data(for: file(size: 400_000_001), offset: 0, length: 1024, now: start) == nil)
        #expect(memo.data(for: file(revision: "r2"), offset: 0, length: 1024, now: start) == nil)
        #expect(memo.data(for: file("/album/other.ape"), offset: 0, length: 1024, now: start) == nil)
        let moved = SharedFileRangeMemo.FileKey(sourceID: "baidu", path: "/album/CDImage.ape",
                                                fileSize: 400_000_000, revision: "r1",
                                                modifiedAt: start + 60)
        #expect(memo.data(for: moved, offset: 0, length: 1024, now: start) == nil)
        let otherSource = SharedFileRangeMemo.FileKey(sourceID: "webdav", path: "/album/CDImage.ape",
                                                      fileSize: 400_000_000, revision: "r1",
                                                      modifiedAt: start)
        #expect(memo.data(for: otherSource, offset: 0, length: 1024, now: start) == nil)
        #expect(memo.data(for: file(), offset: 0, length: 1024, now: start) != nil)
    }

    @Test("一直有分轨在用就一直留着, 闲置超过时限才作废")
    func lifetimeSlidesWithUse() {
        let memo = SharedFileRangeMemo(lifetime: 120)
        memo.store(bytes(1024), for: file(), offset: 0, length: 1024, now: start)

        // 一张十几轨的专辑在后台限速下要读好几分钟, 每读一首都续上。
        for minute in 1...5 {
            #expect(memo.data(for: file(), offset: 0, length: 1024, now: start + Double(minute) * 60) != nil)
        }
        #expect(memo.data(for: file(), offset: 0, length: 1024, now: start + 300 + 121) == nil)
    }

    @Test("只留最近的两个文件, 最久没用的先让出")
    func fileCountCap() {
        let memo = SharedFileRangeMemo(maximumFiles: 2)
        memo.store(bytes(10), for: file("/a.ape"), offset: 0, length: 10, now: start)
        memo.store(bytes(10), for: file("/b.ape"), offset: 0, length: 10, now: start + 1)
        // 碰一下 a, b 就成了最久没用的。
        #expect(memo.data(for: file("/a.ape"), offset: 0, length: 10, now: start + 2) != nil)
        memo.store(bytes(10), for: file("/c.ape"), offset: 0, length: 10, now: start + 3)

        #expect(memo.data(for: file("/a.ape"), offset: 0, length: 10, now: start + 4) != nil)
        #expect(memo.data(for: file("/b.ape"), offset: 0, length: 10, now: start + 4) == nil)
        #expect(memo.data(for: file("/c.ape"), offset: 0, length: 10, now: start + 4) != nil)
    }

    @Test("总量超上限时先让出别的文件; 单这一个文件放不下的段不留")
    func byteCap() {
        let memo = SharedFileRangeMemo(maximumFiles: 2, maximumBytes: 100)
        memo.store(bytes(60), for: file("/a.ape"), offset: 0, length: 60, now: start)
        memo.store(bytes(60), for: file("/b.ape"), offset: 0, length: 60, now: start + 1)
        #expect(memo.data(for: file("/a.ape"), offset: 0, length: 60, now: start + 2) == nil)
        #expect(memo.data(for: file("/b.ape"), offset: 0, length: 60, now: start + 2) != nil)

        // b 已经有 60, 再来 60 超了: 这一段不留, 原来那段还在。
        memo.store(bytes(60), for: file("/b.ape"), offset: -60, length: 60, now: start + 3)
        #expect(memo.data(for: file("/b.ape"), offset: -60, length: 60, now: start + 4) == nil)
        #expect(memo.data(for: file("/b.ape"), offset: 0, length: 60, now: start + 4) != nil)

        // 本身就超上限的一段直接不留。
        memo.store(bytes(101), for: file("/c.ape"), offset: 0, length: 101, now: start + 5)
        #expect(memo.data(for: file("/c.ape"), offset: 0, length: 101, now: start + 6) == nil)
    }

    @Test("同一段再存一次按新字节算, 空结果不留, 清空后都没了")
    func replaceEmptyAndClear() {
        let memo = SharedFileRangeMemo(maximumBytes: 100)
        memo.store(bytes(80, 1), for: file(), offset: 0, length: 80, now: start)
        memo.store(bytes(80, 2), for: file(), offset: 0, length: 80, now: start + 1)
        #expect(memo.data(for: file(), offset: 0, length: 80, now: start + 2) == bytes(80, 2))

        memo.store(Data(), for: file(), offset: -80, length: 80, now: start + 3)
        #expect(memo.data(for: file(), offset: -80, length: 80, now: start + 4) == nil)

        memo.removeAll()
        #expect(memo.data(for: file(), offset: 0, length: 80, now: start + 5) == nil)
    }
}
