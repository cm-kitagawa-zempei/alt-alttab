import CoreGraphics
import Testing
@testable import AltAltTab

/// Covers `MRUTracker.orderedIDs`, the pure ordering core extracted from
/// `MRUTracker.order(_:)`. Operates on plain `CGWindowID`s so it doesn't need
/// a real `WindowInfo`/`AXUIElement` to exercise the ordering logic.
struct MRUOrderingTests {
    @Test("mru-known ids come first, in mru order")
    func mruFirstOrder() {
        let result = MRUTracker.orderedIDs(present: [1, 2, 3, 4], mru: [3, 1])
        #expect(result == [3, 1, 2, 4])
    }

    @Test("ids not in mru keep their given (z-order) order, after mru ones")
    func unknownIDsKeepGivenOrder() {
        let result = MRUTracker.orderedIDs(present: [10, 20, 30], mru: [20])
        #expect(result == [20, 10, 30])
    }

    @Test("mru ids absent from present are pruned (simply don't appear)")
    func absentMRUIDsArePruned() {
        let result = MRUTracker.orderedIDs(present: [1, 2], mru: [5, 1, 6, 2])
        #expect(result == [1, 2])
    }

    @Test("empty mru falls back to the given order")
    func emptyMRUFallsBackToGivenOrder() {
        let result = MRUTracker.orderedIDs(present: [7, 8, 9], mru: [])
        #expect(result == [7, 8, 9])
    }

    @Test("mru with ids entirely absent from present yields the given order")
    func mruEntirelyAbsentYieldsGivenOrder() {
        let result = MRUTracker.orderedIDs(present: [1, 2, 3], mru: [40, 50])
        #expect(result == [1, 2, 3])
    }

    @Test("duplicate-free present with a single mru match reorders only that id")
    func singleMRUMatchMovesToFront() {
        let result = MRUTracker.orderedIDs(present: [1, 2, 3, 4], mru: [3])
        #expect(result == [3, 1, 2, 4])
    }

    @Test("current window first in z-order, mru puts the previous window second")
    func currentFirstMRUPutsPreviousSecond() {
        // Typical Cmd+Tab invocation: `present` is z-order (current window
        // topmost), `mru` front is the currently-focused window (it was the
        // last one noted), second is the previously-focused window.
        let current: CGWindowID = 100
        let previous: CGWindowID = 200
        let older: CGWindowID = 300
        let newWindow: CGWindowID = 400

        let result = MRUTracker.orderedIDs(
            present: [current, older, previous, newWindow],
            mru: [current, previous, older]
        )

        #expect(result[0] == current)
        #expect(result[1] == previous)
        #expect(result == [current, previous, older, newWindow])
    }

    @Test("all present ids also in mru, order fully driven by mru")
    func allPresentInMRU() {
        let result = MRUTracker.orderedIDs(present: [1, 2, 3], mru: [3, 2, 1])
        #expect(result == [3, 2, 1])
    }

    @Test("empty present yields empty result regardless of mru")
    func emptyPresentYieldsEmpty() {
        let result = MRUTracker.orderedIDs(present: [], mru: [1, 2, 3])
        #expect(result.isEmpty)
    }
}
