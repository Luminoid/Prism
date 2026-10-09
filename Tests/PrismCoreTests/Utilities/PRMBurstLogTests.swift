import Testing
@testable import PrismCore

/// `PRMBurstLog` writes through `PRMLog`, whose handler and level are process-wide (only
/// `PRMLogTests` may set them), so these cover the closing-line rule.
struct PRMBurstLogTests {
    @Test
    func `A burst closes with the value it settled on`() {
        #expect(PRMBurstLog.closingLine(first: "iso=100", latest: "iso=800", count: 41) == "iso=800 (settled after 41 more)")
    }

    @Test
    func `A burst with nothing after its first call has no closing line`() {
        #expect(PRMBurstLog.closingLine(first: "iso=100", latest: "iso=100", count: 0) == nil)
        // A drag that came back to where it started.
        #expect(PRMBurstLog.closingLine(first: "iso=100", latest: "iso=100", count: 6) == nil)
    }
}
