import Foundation
import Testing
@testable import PrimuseKit

struct SongTagEditSyncTests {
    private func song(
        title: String = "夜曲",
        artist: String? = "周杰伦",
        album: String? = "十一月的萧邦",
        year: Int? = 2005,
        cover: String? = "0123456789abcdef0123456789abcdef.jpg",
        editedAt: Date? = nil
    ) -> Song {
        Song(
            id: "song-1",
            title: title,
            albumTitle: album,
            artistName: artist,
            albumArtistName: "周杰伦",
            trackNumber: 1,
            duration: 226,
            fileFormat: .flac,
            filePath: "/music/夜曲.flac",
            sourceID: "nas",
            fileSize: 4_000_000,
            bitRate: 900,
            sampleRate: 44_100,
            year: year,
            coverArtFileName: cover,
            userMetadataEditedAt: editedAt
        )
    }

    private let contentKey = String(repeating: "ab", count: 32)

    @Test("A local edit records only the fields that changed, at the edit clock")
    func recordsChangedFields() throws {
        var edited = song(title: "夜曲 (Live)", year: 2006)
        edited.userMetadataEditedAt = Date(timeIntervalSince1970: 1_000)
        let clock = SongTagEditPolicy.editClock(existing: nil, at: Date(timeIntervalSince1970: 1_000))
        let edit = try #require(SongTagEditPolicy.recordingEdit(
            previous: song(), updated: edited, existing: nil, clock: clock
        ))
        #expect(Set(edit.fields.keys) == ["title", "year"])
        #expect(edit[.title]?.text == "夜曲 (Live)")
        #expect(edit[.year]?.number == 2006)
        #expect(edit[.title]?.modifiedAt == 1_000)
    }

    @Test("Edits on two devices to different fields both survive the merge")
    func mergesDifferentFields() {
        var phone = SongTagEdit(songID: "song-1")
        phone[.title] = SongTagEditValue(text: "夜曲 (Live)", modifiedAt: 100)
        var mac = SongTagEdit(songID: "song-1")
        mac[.genre] = SongTagEditValue(text: "流行", modifiedAt: 50)
        let merged = SongTagEditPolicy.merged(phone, mac)
        #expect(merged[.title]?.text == "夜曲 (Live)")
        #expect(merged[.genre]?.text == "流行")
        #expect(merged == SongTagEditPolicy.merged(mac, phone))
    }

    @Test("The later edit of the same field wins; ties resolve the same way on both sides")
    func laterEditWins() {
        var older = SongTagEdit(songID: "song-1")
        older[.title] = SongTagEditValue(text: "旧", modifiedAt: 100)
        var newer = SongTagEdit(songID: "song-1")
        newer[.title] = SongTagEditValue(text: "新", modifiedAt: 200)
        #expect(SongTagEditPolicy.merged(older, newer)[.title]?.text == "新")
        #expect(SongTagEditPolicy.merged(newer, older)[.title]?.text == "新")

        var tieA = SongTagEdit(songID: "song-1")
        tieA[.title] = SongTagEditValue(text: "甲", modifiedAt: 300)
        var tieB = SongTagEdit(songID: "song-1")
        tieB[.title] = SongTagEditValue(text: "乙", modifiedAt: 300)
        #expect(SongTagEditPolicy.merged(tieA, tieB) == SongTagEditPolicy.merged(tieB, tieA))
    }

    @Test("Restoring file tags drops earlier edits on every device, later edits stay")
    func restoreDropsEarlierEdits() {
        var phone = SongTagEdit(songID: "song-1")
        phone[.title] = SongTagEditValue(text: "夜曲 (Live)", modifiedAt: 100)
        phone[.genre] = SongTagEditValue(text: "流行", modifiedAt: 120)
        let restored = SongTagEditPolicy.restoring(
            existing: phone, songID: "song-1", at: Date(timeIntervalSince1970: 90)
        )
        // 设备时钟比改动还早时,恢复仍然排在所有改动之后。
        #expect(restored.restoredAt.map { $0 > 120 } == true)
        #expect(!restored.hasActiveFields)

        // 另一台设备还留着旧改动:合并后不会复活。
        #expect(!SongTagEditPolicy.merged(phone, restored).hasActiveFields)

        // 恢复之后在别处又改了专辑:保留。
        var mac = SongTagEdit(songID: "song-1")
        mac[.album] = SongTagEditValue(text: "新专辑", modifiedAt: (restored.restoredAt ?? 0) + 10)
        let merged = SongTagEditPolicy.merged(restored, mac)
        #expect(Set(merged.fields.keys) == ["album"])
    }

    @Test("A new local edit always lands after earlier edits and restores")
    func editClockMovesForward() {
        var existing = SongTagEdit(songID: "song-1", restoredAt: 500)
        existing[.title] = SongTagEditValue(text: "x", modifiedAt: 600)
        let clock = SongTagEditPolicy.editClock(existing: existing, at: Date(timeIntervalSince1970: 10))
        #expect(clock > 600)
    }

    @Test("Applying an edit sets the fields, clears changed pinyin and stamps the edit marker")
    func applyingFields() {
        var edit = SongTagEdit(songID: "song-1")
        edit[.title] = SongTagEditValue(text: "夜曲 (Live)", modifiedAt: 1_000)
        edit[.artist] = SongTagEditValue(text: "Jay Chou", names: nil, modifiedAt: 900)
        edit[.year] = SongTagEditValue(number: nil, modifiedAt: 800)
        var base = song()
        base.titlePinyin = "yequ"
        base.sourceArtistNames = ["周杰伦"]
        let applied = SongTagEditPolicy.applyingTextFields(edit, to: base)
        #expect(applied.title == "夜曲 (Live)")
        #expect(applied.titlePinyin == nil)
        #expect(applied.artistName == "Jay Chou")
        #expect(applied.sourceArtistNames == nil)
        #expect(applied.year == nil)
        #expect(applied.albumTitle == "十一月的萧邦")
        #expect(applied.userMetadataEditedAt == Date(timeIntervalSince1970: 1_000))

        // 标记已经更晚(本机后来又改过)时不往回改。
        var later = base
        later.userMetadataEditedAt = Date(timeIntervalSince1970: 5_000)
        #expect(SongTagEditPolicy.applyingTextFields(edit, to: later).userMetadataEditedAt
            == Date(timeIntervalSince1970: 5_000))
    }

    @Test("A cover-only edit leaves the edit marker alone")
    func coverOnlyEditDoesNotStamp() {
        var edit = SongTagEdit(songID: "song-1")
        edit[.cover] = SongTagEditValue(cover: .removed, modifiedAt: 1_000)
        #expect(edit.hasActiveFields)
        #expect(!edit.hasActiveTextFields)
        #expect(SongTagEditPolicy.applyingTextFields(edit, to: song()).userMetadataEditedAt == nil)
        edit[.genre] = SongTagEditValue(text: "流行", modifiedAt: 900)
        #expect(SongTagEditPolicy.applyingTextFields(edit, to: song()).userMetadataEditedAt
            == Date(timeIntervalSince1970: 1_000))
    }

    @Test("Only rows edited no later than the restore are restored")
    func needsRestore() {
        let restored = SongTagEdit(songID: "song-1", restoredAt: 1_000)
        #expect(SongTagEditPolicy.needsRestore(restored, song: song(editedAt: Date(timeIntervalSince1970: 900))))
        #expect(!SongTagEditPolicy.needsRestore(restored, song: song(editedAt: Date(timeIntervalSince1970: 1_100))))
        #expect(!SongTagEditPolicy.needsRestore(restored, song: song()))
        var active = restored
        active[.genre] = SongTagEditValue(text: "流行", modifiedAt: 1_200)
        #expect(!SongTagEditPolicy.needsRestore(active, song: song(editedAt: Date(timeIntervalSince1970: 900))))
    }

    @Test("Cover changes that the reference alone explains")
    func referenceCoverChange() {
        #expect(SongTagEditPolicy.referenceCoverChange(from: song(), to: song(cover: nil)) == .removed)
        #expect(SongTagEditPolicy.referenceCoverChange(from: song(), to: song(cover: "/music/cover.jpg"))
            == .sourceFile("/music/cover.jpg"))
        #expect(SongTagEditPolicy.referenceCoverChange(from: song(cover: nil), to: song()) == nil)
        #expect(SongTagEditPolicy.referenceCoverChange(from: song(), to: song()) == nil)
    }

    @Test("A cover edit older than the recorded one or the restore is ignored")
    func recordingCover() {
        var existing = SongTagEdit(songID: "song-1", restoredAt: 100)
        #expect(SongTagEditPolicy.recordingCover(.removed, songID: "song-1", existing: existing, clock: 90)
            == existing)
        existing[.cover] = SongTagEditValue(cover: .removed, modifiedAt: 300)
        #expect(SongTagEditPolicy.recordingCover(
            .image(original: contentKey, portable: nil), songID: "song-1", existing: existing, clock: 200
        ) == existing)
        let updated = SongTagEditPolicy.recordingCover(
            .image(original: contentKey, portable: contentKey), songID: "song-1", existing: existing, clock: 400
        )
        #expect(updated?[.cover]?.cover == .image(original: contentKey, portable: contentKey))
    }

    @Test("Edits made before sync existed are recorded whole, without inventing a removed cover")
    func legacyEdit() throws {
        let edited = song(title: "夜曲 (Live)", cover: nil, editedAt: Date(timeIntervalSince1970: 700))
        let edit = try #require(SongTagEditPolicy.legacyEdit(for: edited, cover: nil))
        #expect(edit[.cover] == nil)
        #expect(edit[.title]?.modifiedAt == 700)
        // 这一行没有流派、碟号:空着的字段不记。
        #expect(Set(edit.fields.keys) == ["title", "artist", "album", "albumArtist", "year", "trackNumber"])
        #expect(SongTagEditPolicy.legacyEdit(for: song(), cover: nil) == nil)
    }

    @Test("A legacy row whose title is still the file name does not send that title")
    func legacyEditSkipsFileNameTitle() throws {
        let unread = song(title: "夜曲", artist: nil, album: nil, year: nil, editedAt: Date(timeIntervalSince1970: 700))
        let edit = try #require(SongTagEditPolicy.legacyEdit(for: unread, cover: nil))
        #expect(edit[.title] == nil)
        #expect(Set(edit.fields.keys) == ["albumArtist", "trackNumber"])
    }

    @Test("Records keep unknown fields from newer versions and survive JSON")
    func codableRoundTrip() throws {
        var edit = SongTagEdit(songID: "song-1", restoredAt: 10)
        edit[.cover] = SongTagEditValue(cover: .image(original: contentKey, portable: nil), modifiedAt: 20)
        edit[.title] = SongTagEditValue(text: "夜曲", modifiedAt: 30)
        edit.fields["composer"] = SongTagEditValue(text: "方文山", modifiedAt: 40)
        let decoded = try JSONDecoder().decode(SongTagEdit.self, from: JSONEncoder().encode(edit))
        #expect(decoded == edit)
        let merged = SongTagEditPolicy.merged(decoded, SongTagEdit(songID: "song-1"))
        #expect(merged.fields["composer"]?.text == "方文山")
        // 套用时不认识的字段不动这一行。
        #expect(SongTagEditPolicy.applyingTextFields(merged, to: song()).title == "夜曲")
    }

    @Test("A legacy row named Artist - Title does not send the names taken from the file name")
    func legacyEditSkipsFileNameArtist() throws {
        var unread = song(title: "夜曲", artist: "周杰伦", album: nil, year: nil, editedAt: Date(timeIntervalSince1970: 700))
        unread.filePath = "/music/周杰伦 - 夜曲.mp3"
        let edit = try #require(SongTagEditPolicy.legacyEdit(for: unread, cover: nil))
        #expect(edit[.title] == nil)
        #expect(edit[.artist] == nil)
    }

    @Test("A legacy row that took a disc-track prefix as its artist does not send it")
    func legacyEditSkipsDiscTrackPrefixArtist() throws {
        var unread = song(title: "夜曲", artist: "03-01", album: nil, year: nil, editedAt: Date(timeIntervalSince1970: 700))
        unread.filePath = "/music/03-01 - 夜曲.flac"
        let edit = try #require(SongTagEditPolicy.legacyEdit(for: unread, cover: nil))
        #expect(edit[.title] == nil)
        #expect(edit[.artist] == nil)
    }

    @Test("Empty text and no text are different values and merge the same way in either order")
    func tieBreakSeparatesNilFromEmpty() {
        var empty = SongTagEdit(songID: "song-1")
        empty[.genre] = SongTagEditValue(text: "", modifiedAt: 100)
        var cleared = SongTagEdit(songID: "song-1")
        cleared[.genre] = SongTagEditValue(text: nil, modifiedAt: 100)
        #expect(SongTagEditPolicy.merged(empty, cleared) == SongTagEditPolicy.merged(cleared, empty))
    }

    @Test("Equal records have equal revision stamps however their fields were inserted")
    func revisionStampIsCanonical() {
        var forward = SongTagEdit(songID: "song-1")
        var backward = SongTagEdit(songID: "song-1")
        let values: [(SongTagEditField, TimeInterval)] = [(.title, 0.1), (.genre, 0.2), (.year, 0.3), (.album, 1e9 + 0.7)]
        for (field, clock) in values { forward[field] = SongTagEditValue(text: "x", modifiedAt: clock) }
        for (field, clock) in values.reversed() { backward[field] = SongTagEditValue(text: "x", modifiedAt: clock) }
        #expect(forward == backward)
        #expect(forward.revisionStamp == backward.revisionStamp)
    }

    @Test("Revision stamps change whenever the merged content changes")
    func revisionStamp() {
        var edit = SongTagEdit(songID: "song-1")
        edit[.title] = SongTagEditValue(text: "a", modifiedAt: 100)
        var other = SongTagEdit(songID: "song-1")
        other[.genre] = SongTagEditValue(text: "b", modifiedAt: 50)
        let merged = SongTagEditPolicy.merged(edit, other)
        #expect(merged.revisionStamp != edit.revisionStamp)
        let restored = SongTagEditPolicy.restoring(existing: merged, songID: "song-1", at: Date())
        #expect(restored.revisionStamp != merged.revisionStamp)
    }

    @Test("Record names stay plain for hex ids and hash everything else")
    func recordNames() {
        #expect(CloudRecordNameEncoding.recordName(for: "song:0123abcd") == "song:0123abcd")
        let genre = CloudRecordNameEncoding.recordName(for: "genre:流行")
        #expect(genre.hasPrefix("~"))
        #expect(genre.count == 33)
        #expect(genre == CloudRecordNameEncoding.recordName(for: "genre:流行"))
        #expect(genre != CloudRecordNameEncoding.recordName(for: "genre:摇滚"))
        #expect(CloudRecordNameEncoding.recordName(for: "_private").hasPrefix("~"))
        #expect(CloudRecordNameEncoding.recordName(for: String(repeating: "a", count: 300)).count == 33)
    }
}
