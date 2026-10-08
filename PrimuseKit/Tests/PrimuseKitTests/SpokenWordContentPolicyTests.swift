import Foundation
import Testing
@testable import PrimuseKit

@Suite("Spoken word classification")
struct SpokenWordContentPolicyTests {
    @Test("An .m4b container is an audiobook on its own")
    func audiobookContainer() {
        #expect(
            SpokenWordContentPolicy.classify(filePath: "/Books/Dune.m4b", genre: nil)
                == .spokenWord
        )
        #expect(
            SpokenWordContentPolicy.classify(filePath: "/Books/Dune.M4B", genre: nil)
                == .spokenWord
        )
    }

    @Test("Ordinary music containers stay music without other evidence")
    func musicContainers() {
        for path in ["/Music/song.m4a", "/Music/song.mp3", "/Music/song.flac"] {
            #expect(SpokenWordContentPolicy.classify(filePath: path, genre: nil) == .music)
        }
    }

    @Test("Genres that name the category are recognized across languages")
    func categoryGenres() {
        let genres = [
            "Audiobook", "audio book", "Spoken Word", "Radio Drama",
            "Hörbuch", "Livre audio", "Audiolibro", "Lecture", "Storytelling",
        ]
        for genre in genres {
            #expect(
                SpokenWordContentPolicy.classify(filePath: "/a.mp3", genre: genre) == .spokenWord,
                "\(genre) should be spoken word"
            )
        }
    }

    @Test("A genre that names a podcast files the episode with the podcasts")
    func podcastGenres() {
        for genre in ["Podcast", "Podcasts", "播客", "ポッドキャスト", "팟캐스트", "Tech Podcast"] {
            #expect(SpokenWordContentPolicy.classify(filePath: "/a.mp3", genre: genre) == .podcast, "\(genre)")
            #expect(SpokenWordContentPolicy.genreNamesSpokenWord(genre), "\(genre) is still not music")
        }
        // A book container is a book whatever the genre says.
        #expect(SpokenWordContentPolicy.classify(filePath: "/a.m4b", genre: "Podcast") == .spokenWord)
        #expect(ListeningContentKind.podcast.isSpokenWordListening)
        #expect(!ListeningContentKind.music.isSpokenWordListening)
    }

    @Test("Chinese spoken-word categories are recognized")
    func chineseCategoryGenres() {
        let genres = ["\u{6709}\u{58F0}\u{4E66}", "\u{8BC4}\u{4E66}", "\u{76F8}\u{58F0}",
                      "\u{5E7F}\u{64AD}\u{5267}", "\u{8BF4}\u{4E66}", "\u{8131}\u{53E3}\u{79C0}"]
        for genre in genres {
            #expect(
                SpokenWordContentPolicy.classify(filePath: "/a.mp3", genre: genre) == .spokenWord
            )
        }
    }

    @Test("Music genres are never reclassified")
    func musicGenresUntouched() {
        let genres = [
            "Rock", "Pop", "Classical", "Jazz", "Soundtrack", "Electronic",
            "Comedy", "Folk", "Hip-Hop", "Blues", "World", "Vocal", "New Age",
            "\u{6D41}\u{884C}", "\u{6C11}\u{8C23}", "\u{53E4}\u{5178}",
        ]
        for genre in genres {
            #expect(
                SpokenWordContentPolicy.classify(filePath: "/a.mp3", genre: genre) == .music,
                "\(genre) should stay music"
            )
        }
    }

    @Test("Duration is never evidence: long music stays music")
    func lengthIsNotEvidence() {
        // A 74-minute symphony movement, a DJ set and a live set are all music.
        #expect(
            SpokenWordContentPolicy.classify(filePath: "/Live/set.flac", genre: "Electronic")
                == .music
        )
    }

    @Test("An explicit choice overrides inference in both directions")
    func userOverrideWins() {
        #expect(
            SpokenWordContentPolicy.classify(
                filePath: "/Books/Dune.m4b",
                genre: "Audiobook",
                userOverride: .music
            ) == .music
        )
        #expect(
            SpokenWordContentPolicy.classify(
                filePath: "/Music/track.mp3",
                genre: "Rock",
                userOverride: .spokenWord
            ) == .spokenWord
        )
    }

    @Test("A junk genre value cannot be a category name")
    func junkGenre() {
        #expect(SpokenWordContentPolicy.genreNamesSpokenWord("") == false)
        #expect(SpokenWordContentPolicy.genreNamesSpokenWord("   ") == false)
        #expect(
            SpokenWordContentPolicy.genreNamesSpokenWord(String(repeating: "audiobook", count: 20))
                == false
        )
    }
}

@Suite("Spoken word progress")
struct SpokenWordProgressPolicyTests {
    @Test("A position is kept once past the opening seconds")
    func remembersAfterOpening() {
        #expect(SpokenWordProgressPolicy.shouldRemember(position: 5, duration: 3600) == false)
        #expect(SpokenWordProgressPolicy.shouldRemember(position: 20, duration: 3600))
        #expect(SpokenWordProgressPolicy.shouldRemember(position: 1800, duration: 3600))
    }

    @Test("A finished item drops its position")
    func forgetsWhenFinished() {
        #expect(SpokenWordProgressPolicy.shouldRemember(position: 3590, duration: 3600) == false)
        #expect(SpokenWordProgressPolicy.shouldRemember(position: 3570, duration: 3600))
    }

    @Test("An unknown duration cannot prove the item was finished")
    func unknownDurationKeepsPosition() {
        #expect(SpokenWordProgressPolicy.shouldRemember(position: 900, duration: 0))
        #expect(SpokenWordProgressPolicy.shouldRemember(position: 5, duration: 0) == false)
    }

    @Test("Resuming rewinds a few seconds to pick up the sentence")
    func resumeRewinds() {
        #expect(SpokenWordProgressPolicy.resumePosition(stored: 600, duration: 3600) == 595)
        #expect(SpokenWordProgressPolicy.resumePosition(stored: nil, duration: 3600) == nil)
        #expect(SpokenWordProgressPolicy.resumePosition(stored: 3, duration: 3600) == nil)
        #expect(SpokenWordProgressPolicy.resumePosition(stored: 3599, duration: 3600) == nil)
    }

    @Test("Non-finite values never become a seek target")
    func rejectsNonFinite() {
        #expect(
            SpokenWordProgressPolicy.shouldRemember(position: .infinity, duration: 3600) == false
        )
        #expect(SpokenWordProgressPolicy.shouldRemember(position: 100, duration: .nan) == false)
        #expect(SpokenWordProgressPolicy.resumePosition(stored: .nan, duration: 3600) == nil)
    }
}

@Suite("Spoken word skipping")
struct SpokenWordSkipPolicyTests {
    @Test("Skipping stays inside the item")
    func clampsToItem() {
        #expect(
            SpokenWordSkipPolicy.position(from: 100, offset: 30, duration: 3600) == 130
        )
        #expect(SpokenWordSkipPolicy.position(from: 10, offset: -15, duration: 3600) == 0)
        #expect(
            SpokenWordSkipPolicy.position(from: 3590, offset: 30, duration: 3600) == 3600
        )
    }

    @Test("An unknown duration still allows forward skipping")
    func unknownDuration() {
        #expect(SpokenWordSkipPolicy.position(from: 100, offset: 30, duration: 0) == 130)
        #expect(SpokenWordSkipPolicy.position(from: 5, offset: -15, duration: 0) == 0)
    }

    @Test("The intervals are the audiobook conventions")
    func intervals() {
        #expect(SpokenWordSkipPolicy.backwardInterval == 15)
        #expect(SpokenWordSkipPolicy.forwardInterval == 30)
    }
}

@Suite("Transcript reading paragraphs")
struct SpokenWordTranscriptReadingPolicyTests {
    private typealias Policy = SpokenWordTranscriptReadingPolicy

    @Test("Subtitle cues join into paragraphs that break at pauses and speaker changes")
    func joinsCues() {
        let cues = [
            Policy.Cue(text: "Welcome back", start: 0, end: 1.5, speaker: "A"),
            Policy.Cue(text: "to the show.", start: 1.6, end: 3, speaker: "A"),
            Policy.Cue(text: "Thanks for having me.", start: 3.2, end: 5, speaker: "B"),
            Policy.Cue(text: "So, where were we?", start: 9, end: 11, speaker: "B"),
        ]
        let paragraphs = Policy.paragraphs(from: cues)
        #expect(paragraphs.map(\.text) == ["Welcome back to the show.", "Thanks for having me.", "So, where were we?"])
        #expect(paragraphs.map(\.firstCue) == [0, 2, 3])
        #expect(paragraphs.map(\.start) == [0, 3.2, 9])
        #expect(Policy.paragraphIndex(at: 4, in: paragraphs) == 1)
        #expect(Policy.paragraphIndex(at: 0, in: paragraphs) == 0)
        #expect(Policy.paragraphIndex(at: 100, in: paragraphs) == 2)
    }

    @Test("Chinese joins without spaces and LRC lines break only at long gaps")
    func chineseAndLRC() {
        let cues = [
            Policy.Cue(text: "第一章 山河", start: 0),
            Policy.Cue(text: "天色渐暗，", start: 4),
            Policy.Cue(text: "他推门而出。", start: 7),
            Policy.Cue(text: "第二天清晨", start: 30),
        ]
        let paragraphs = Policy.paragraphs(from: cues)
        #expect(paragraphs.map(\.text) == ["第一章 山河天色渐暗，他推门而出。", "第二天清晨"])
    }

    @Test("Plain text keeps the author's blank lines as paragraph breaks and is never timed")
    func plainText() {
        let cues = ["First line", "continues here.", "", "Second paragraph."].map { Policy.Cue(text: $0, start: nil) }
        let paragraphs = Policy.paragraphs(from: cues)
        #expect(paragraphs.map(\.text) == ["First line continues here.", "Second paragraph."])
        #expect(paragraphs.allSatisfy { $0.start == nil })
        #expect(Policy.paragraphIndex(at: 10, in: paragraphs) == nil)
    }

    @Test("A long paragraph breaks at the next sentence end")
    func longParagraphs() {
        let sentence = String(repeating: "字", count: 100) + "。"
        let cues = (0..<5).map { Policy.Cue(text: sentence, start: Double($0), end: Double($0) + 0.9) }
        let paragraphs = Policy.paragraphs(from: cues)
        #expect(paragraphs.count == 2)
        #expect(paragraphs[0].lastCue == 2)
        #expect(paragraphs.allSatisfy { $0.text.count <= Policy.hardLength })
    }
}
