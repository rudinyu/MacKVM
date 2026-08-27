import MacKVMCore
import XCTest
@testable import MacKVM

private struct SnapshotTestLayout: UnicodeLayoutCharacterProviding {
    func character(
        forKeyCode keyCode: UInt16,
        shift: Bool,
        option: Bool,
        capsLock: Bool
    ) -> String? {
        guard keyCode == 0, !shift, !option, !capsLock else { return nil }
        return "a"
    }
}

@MainActor
final class CarbonKeyboardLayoutSnapshotCacheTests: XCTestCase {
    func testIdentifierAndReverseMapArePublishedAsOneSnapshot() {
        var identifierCalls = 0
        var reverseMapCalls = 0
        var forwardMapCalls = 0
        let map = KeyboardLayoutReverseMap(
            translator: SnapshotTestLayout()
        )
        let forwardMap = KeyboardLayoutForwardMap(
            translator: SnapshotTestLayout()
        )
        let cache = CarbonKeyboardLayoutSnapshotCache(
            identifierSource: {
                identifierCalls += 1
                return "com.apple.keylayout.US"
            },
            reverseMapSource: {
                reverseMapCalls += 1
                return map
            },
            forwardMapSource: {
                forwardMapCalls += 1
                return forwardMap
            }
        )

        XCTAssertEqual(cache.currentIdentifier(), "com.apple.keylayout.US")
        XCTAssertNotNil(cache.currentReverseMap())
        XCTAssertEqual(identifierCalls, 1)
        XCTAssertEqual(reverseMapCalls, 1)
        XCTAssertEqual(forwardMapCalls, 1)
        XCTAssertEqual(
            cache.currentSnapshot()?.forwardMap?.character(
                forKeyCode: 0,
                shift: false,
                option: false,
                capsLock: false
            ),
            "a"
        )
    }

    func testMissingReverseMapDoesNotPublishAnIdentifier() {
        let cache = CarbonKeyboardLayoutSnapshotCache(
            identifierSource: { "com.apple.keylayout.US" },
            reverseMapSource: { nil }
        )

        XCTAssertNil(cache.currentIdentifier())
        XCTAssertNil(cache.currentReverseMap())
    }
}
