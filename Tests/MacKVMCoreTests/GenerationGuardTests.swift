import XCTest
@testable import MacKVMCore

final class GenerationGuardTests: XCTestCase {
    func testPerKeyGenerationsAdvanceAndCanBePruned() {
        let first = UUID()
        let second = UUID()
        let guardStore = GenerationGuard<UUID>()

        XCTAssertEqual(guardStore.current(for: first), 0)
        XCTAssertEqual(guardStore.advance(for: first), 1)
        guardStore.set(9, for: second)
        XCTAssertEqual(guardStore.current(for: second), 9)

        guardStore.prune(keeping: [first])
        XCTAssertEqual(guardStore.current(for: first), 1)
        XCTAssertEqual(guardStore.current(for: second), 0)
    }

    func testInvalidatingAKeyRetainsItsCapturedGeneration() {
        let key = UUID()
        let guardStore = GenerationGuard<UUID>()
        _ = guardStore.advance(for: key)

        _ = guardStore.invalidate(for: key)

        XCTAssertGreaterThan(guardStore.current(for: key), 1)
    }

    func testRemovingAKeyAllowsSafeReuseAfterItsWorkIsGone() {
        let key = UUID()
        let guardStore = GenerationGuard<UUID>()
        _ = guardStore.advance(for: key)

        guardStore.remove(for: key)

        XCTAssertEqual(guardStore.current(for: key), 0)
    }

    func testUnrelatedKeyGenerationsDoNotInterfere() {
        let first = UUID()
        let second = UUID()
        let guardStore = GenerationGuard<UUID>()

        _ = guardStore.advance(for: first)
        guardStore.set(0, for: second)

        XCTAssertEqual(guardStore.current(for: second), 0)
    }

    func testEpochGuardAdvancesLifecycleGenerations() {
        let epoch = EpochGuard()

        XCTAssertEqual(epoch.current(), 0)
        XCTAssertEqual(epoch.advance(), 1)
        XCTAssertEqual(epoch.current(), 1)
    }
}
