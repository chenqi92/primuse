import Foundation
import Testing
@testable import PrimuseKit

@Suite("Start listening ranking")
struct ListeningIntentRankingTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func moment(_ situation: ListeningSituation, weekend: Bool = false) -> ListeningMoment {
        ListeningMoment(situation: situation, holiday: nil, isWeekend: weekend, dayStamp: 20_261_002, validUntil: now.addingTimeInterval(3_600))
    }

    private func availability(_ scores: [(ListeningIntent, Double)]) -> ListeningIntentAvailability {
        ListeningIntentAvailability(
            songCounts: Dictionary(uniqueKeysWithValues: scores.map { ($0.0.id, 100) }),
            scores: Dictionary(uniqueKeysWithValues: scores.map { ($0.0.id, $0.1) }),
            libraryGeneration: 1,
            computedAt: now
        )
    }

    private func rank(_ scores: [(ListeningIntent, Double)], at moment: ListeningMoment, usage: ListeningIntentUsage = .init()) -> [String] {
        ListeningIntentRankingPolicy.rank(
            scores.map(\.0),
            availability: availability(scores),
            moment: moment,
            usage: usage,
            now: now
        ).map(\.id)
    }

    @Test("Bedtime leads late in the evening and steps back on the commute; workout the other way round")
    func momentOfDay() {
        let bedtime = ListeningIntent.builtIn(.bedtime)
        let workout = ListeningIntent.builtIn(.workout)
        let scores = [(workout, 0.3), (bedtime, 0.3)]
        #expect(rank(scores, at: moment(.bedtime)).first == bedtime.id)
        #expect(rank(scores, at: moment(.lateNight)).first == bedtime.id)
        #expect(rank(scores, at: moment(.commute)).first == workout.id)

        let focus = ListeningIntent.builtIn(.focus)
        let calm = ListeningIntent.builtIn(.calm)
        #expect(rank([(calm, 0.3), (focus, 0.3)], at: moment(.workday)).first == focus.id)
    }

    @Test("Genre intents follow the moment's family weights")
    func genreWeights() {
        let classical = ListeningIntent.builtIn(.classical)
        let hipHop = ListeningIntent.builtIn(.hipHop)
        let scores = [(hipHop, 0.35), (classical, 0.3)]
        #expect(rank(scores, at: moment(.bedtime)).first == classical.id)
        #expect(rank(scores, at: moment(.commute)).first == hipHop.id)
    }

    @Test("Four decades do not take the first four places when other kinds are close behind")
    func variety() {
        let eras: [(ListeningIntent, Double)] = [
            (.builtIn(.eighties), 0.5), (.builtIn(.nineties), 0.49),
            (.builtIn(.twoThousands), 0.48), (.builtIn(.twentyTens), 0.47),
        ]
        let genres: [(ListeningIntent, Double)] = [(.builtIn(.pop), 0.45), (.builtIn(.rock), 0.44)]
        let order = rank(eras + genres, at: moment(.workday))
        let firstFour = Set(order.prefix(4))
        #expect(firstFour.contains(ListeningIntent.builtIn(.pop).id))
        #expect(firstFour.contains(ListeningIntent.builtIn(.rock).id))
        #expect(order.first == ListeningIntent.builtIn(.eighties).id)
        #expect(Set(order) == Set((eras + genres).map(\.0.id)))
    }

    @Test("What the listener keeps starting at this time of day rises; the one just played steps aside")
    func usage() {
        let jazz = ListeningIntent.builtIn(.jazz)
        let rock = ListeningIntent.builtIn(.rock)
        var usage = ListeningIntentUsage()
        for day in 1...5 {
            usage.record(jazz.id, at: now.addingTimeInterval(-Double(day) * 86_400), situation: .tonight)
        }
        #expect(rank([(rock, 0.45), (jazz, 0.35)], at: moment(.tonight), usage: usage).first == jazz.id)

        var justPlayed = ListeningIntentUsage()
        justPlayed.record(rock.id, at: now.addingTimeInterval(-1_800), situation: .tonight)
        #expect(rank([(rock, 0.45), (jazz, 0.38)], at: moment(.tonight), usage: justPlayed).first == jazz.id)
    }

    @Test("The order is stable for a moment and keeps every intent exactly once")
    func stable() {
        let scores: [(ListeningIntent, Double)] = ListeningIntentShelfPolicy.builtInCatalog.enumerated().map { ($1, Double($0 % 5) / 10) }
        let first = rank(scores, at: moment(.tonight))
        #expect(first == rank(scores, at: moment(.tonight)))
        #expect(first.count == scores.count)
        #expect(Set(first).count == first.count)
    }

    @Test("Usage keeps two months, at most thirty starts an intent, and survives a round trip")
    func usageStore() {
        var usage = ListeningIntentUsage()
        for index in 0..<40 {
            usage.record("builtin:pop", at: now.addingTimeInterval(-Double(40 - index) * 3_600), situation: .commute)
        }
        #expect(usage.starts(of: "builtin:pop").count == ListeningIntentUsage.perIntentLimit)
        usage.record("builtin:jazz", at: now.addingTimeInterval(-70 * 86_400), situation: .tonight)
        usage.prune(now: now)
        #expect(usage.starts(of: "builtin:jazz").isEmpty)
        #expect(usage.starts(of: "builtin:pop").count == ListeningIntentUsage.perIntentLimit)
        let decoded = ListeningIntentUsage.decode(usage.encoded())
        #expect(decoded == usage)
        #expect(ListeningIntentUsage.decode(Data("nope".utf8)) == ListeningIntentUsage())
    }

    @Test("The shelf follows the ranked order after the lead card")
    func shelfOrder() throws {
        let intents: [ListeningIntent] = [.builtIn(.pop), .builtIn(.rock), .builtIn(.jazz)]
        var counts = Dictionary(uniqueKeysWithValues: intents.map { ($0.id, 50) })
        counts[ListeningIntent.builtIn(.anything).id] = 200
        let lit = ListeningIntentAvailability(songCounts: counts, libraryGeneration: 1, computedAt: now)
        let order = [ListeningIntent.builtIn(.jazz).id, ListeningIntent.builtIn(.pop).id, ListeningIntent.builtIn(.rock).id]
        let row = ListeningIntentShelfPolicy.row(availability: lit, configuration: .init(), resumeSongCount: nil, order: order)
        #expect(row.first?.intent == .builtIn(.anything))
        #expect(Array(row.dropFirst().map(\.id)) == order)
    }
}
