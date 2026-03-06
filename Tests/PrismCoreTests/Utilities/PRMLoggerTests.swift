import Testing
@testable import PrismCore

// MARK: - PRMLoggerTests

@Suite("PRMLogger")
struct PRMLoggerTests {
    // MARK: - Category

    @Test("All categories have non-empty raw values")
    func categoryRawValues() {
        let categories: [PRMLogCategory] = [.session, .capture, .filter, .preview, .general]
        for category in categories {
            #expect(!category.rawValue.isEmpty)
        }
    }

    @Test("Category raw values are capitalized")
    func categoryCapitalization() {
        #expect(PRMLogCategory.session.rawValue == "Session")
        #expect(PRMLogCategory.capture.rawValue == "Capture")
        #expect(PRMLogCategory.filter.rawValue == "Filter")
        #expect(PRMLogCategory.preview.rawValue == "Preview")
        #expect(PRMLogCategory.general.rawValue == "General")
    }

    // MARK: - Logger Instances

    @Test("Logger for category returns a valid Logger")
    func loggerForCategory() {
        let logger = PRMLogger.logger(for: .session)
        // os.Logger has no public properties to inspect, but construction should not crash
        _ = logger
    }

    @Test("Convenience loggers are accessible")
    func convenienceLoggers() {
        _ = PRMLogger.session
        _ = PRMLogger.capture
        _ = PRMLogger.filter
        _ = PRMLogger.preview
        _ = PRMLogger.general
    }
}
