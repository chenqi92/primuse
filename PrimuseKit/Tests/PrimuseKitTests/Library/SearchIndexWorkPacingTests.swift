import Testing
@testable import PrimuseKit

struct SearchIndexWorkPacingTests {
    @Test func nominalIndexingLeavesFourTimesItsWorkDurationIdle() {
        for work in [0.001, 0.05, 0.4, 2.0] {
            let idle = SearchIndexWorkPacing.delay(workSeconds: work, thermalLevel: 0)
            #expect(abs(work / (work + idle) - 0.2) < 0.000001)
        }
    }

    @Test func thermalPressureLowersTheDutyCycleAndWaitsStayBounded() {
        let delays = (0...3).map { SearchIndexWorkPacing.delay(workSeconds: 0.2, thermalLevel: $0) }
        #expect(zip(delays, delays.dropFirst()).allSatisfy { $0.0 < $0.1 })
        #expect(SearchIndexWorkPacing.delay(workSeconds: 100, thermalLevel: 3) == 30)
        #expect(SearchIndexWorkPacing.delay(workSeconds: -.infinity, thermalLevel: 0) == 0)
    }
}
