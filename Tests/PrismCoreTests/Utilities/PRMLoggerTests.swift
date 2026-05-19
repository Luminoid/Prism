import Testing
@testable import PrismCore

struct PRMLoggerTests {
    @Test
    func `Categories have stable raw values`() {
        #expect(PRMLogCategory.session.rawValue == "Session")
        #expect(PRMLogCategory.capture.rawValue == "Capture")
        #expect(PRMLogCategory.filter.rawValue == "Filter")
        #expect(PRMLogCategory.preview.rawValue == "Preview")
        #expect(PRMLogCategory.general.rawValue == "General")
    }

    @Test
    func `Convenience static loggers exist`() {
        _ = PRMLogger.session
        _ = PRMLogger.capture
        _ = PRMLogger.filter
        _ = PRMLogger.preview
        _ = PRMLogger.general
    }
}
