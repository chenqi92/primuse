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
            "Audiobook", "audio book", "Spoken Word", "Podcast", "Radio Drama",
            "Hörbuch", "Livre audio", "Audiolibro", "Lecture", "Storytelling",
        ]
        for genre in genres {
            #expect(
                SpokenWordContentPolicy.classify(filePath: "/a.mp3", genre: genre) == .spokenWord,
                "\(genre) should be spoken word"
            )
        }
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
