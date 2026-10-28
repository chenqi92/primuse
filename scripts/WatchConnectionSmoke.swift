import Foundation

@main struct WatchConnectionSmoke {
    static func main() {
        let start = Date(timeIntervalSince1970: 100)
        var state = WatchConnectionPresentation()
        precondition(!state.showsDisconnected(at: start))
        state.setActive(true, reachable: false, now: start)
        precondition(!state.showsDisconnected(at: start.addingTimeInterval(2.9)))
        precondition(state.showsDisconnected(at: start.addingTimeInterval(3)))
        state.update(reachable: true, now: start.addingTimeInterval(3.1))
        precondition(!state.showsDisconnected(at: start.addingTimeInterval(4)))
        state.setActive(false, reachable: false, now: start.addingTimeInterval(5))
        precondition(!state.showsDisconnected(at: start.addingTimeInterval(100)))
        state.setActive(true, reachable: false, now: start.addingTimeInterval(100))
        precondition(!state.showsDisconnected(at: start.addingTimeInterval(100)))
        state.update(reachable: true, now: start.addingTimeInterval(101))
        precondition(!state.showsDisconnected(at: start.addingTimeInterval(104)))
        state.update(reachable: false, now: start.addingTimeInterval(105))
        state.update(reachable: false, now: start.addingTimeInterval(107))
        precondition(state.showsDisconnected(at: start.addingTimeInterval(108)))
        state.setActive(false, reachable: false, now: start.addingTimeInterval(110))
        state.setActive(true, reachable: false, now: start.addingTimeInterval(200))
        precondition(!state.showsDisconnected(at: start.addingTimeInterval(201)))
        precondition(state.showsDisconnected(at: start.addingTimeInterval(203)))
        print("Watch connection: cold start, wrist raise, recovery, sustained disconnect passed")
    }
}
