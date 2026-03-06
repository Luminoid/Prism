import Testing
@testable import PrismCore

// MARK: - PRMSessionSetupResultTests

@Suite("PRMSessionSetupResult")
struct PRMSessionSetupResultTests {
    @Test("All cases exist")
    func allCases() {
        let success: PRMSessionSetupResult = .success
        let notAuthorized: PRMSessionSetupResult = .notAuthorized
        let failed: PRMSessionSetupResult = .configurationFailed
        #expect(success != notAuthorized)
        #expect(notAuthorized != failed)
        #expect(success != failed)
    }

    @Test("Equatable conformance")
    func equatable() {
        #expect(PRMSessionSetupResult.success == .success)
        #expect(PRMSessionSetupResult.notAuthorized == .notAuthorized)
        #expect(PRMSessionSetupResult.configurationFailed == .configurationFailed)
    }
}
