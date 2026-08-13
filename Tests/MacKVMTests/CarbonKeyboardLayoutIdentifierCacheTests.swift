import Foundation
import XCTest
@testable import MacKVM

@MainActor
final class CarbonKeyboardLayoutIdentifierCacheTests: XCTestCase {
    func testCachesInjectedIdentifierUntilLayoutChange() {
        var calls = 0
        let cache = CarbonKeyboardLayoutIdentifierCache {
            calls += 1
            return calls == 1 ? "com.apple.keylayout.US" : "com.apple.keylayout.German"
        }

        XCTAssertEqual(cache.currentIdentifier(), "com.apple.keylayout.US")
        XCTAssertEqual(calls, 1)

        cache.invalidate()

        XCTAssertEqual(cache.currentIdentifier(), "com.apple.keylayout.German")
        XCTAssertEqual(cache.currentIdentifier(), "com.apple.keylayout.German")
        XCTAssertEqual(calls, 2)
    }

    func testNotificationDuringRefreshKeepsNewGenerationStale() {
        final class CacheReference {
            weak var cache: CarbonKeyboardLayoutIdentifierCache?
        }

        var calls = 0
        let reference = CacheReference()
        let cache = CarbonKeyboardLayoutIdentifierCache {
            calls += 1
            if calls == 2 {
                // This callback runs during a refresh that was already
                // invalidated. It models a second layout change arriving
                // while the first Carbon read is still in progress.
                reference.cache?.invalidate()
                return "com.apple.keylayout.US"
            }
            return "com.apple.keylayout.German"
        }
        reference.cache = cache
        cache.invalidate()

        XCTAssertNil(cache.currentIdentifier())
        XCTAssertEqual(cache.currentIdentifier(), "com.apple.keylayout.German")
        XCTAssertEqual(calls, 3)
    }

    func testFailedIdentifierRefreshIsRetried() {
        var responses: [String?] = [nil, nil, "com.apple.keylayout.US"]
        let cache = CarbonKeyboardLayoutIdentifierCache {
            responses.removeFirst()
        }

        XCTAssertNil(cache.currentIdentifier())
        XCTAssertEqual(cache.currentIdentifier(), "com.apple.keylayout.US")
        XCTAssertTrue(responses.isEmpty)
    }
}
