import CoreImage
import Testing
@testable import PrismCore

// MARK: - Mock Filter

final class MockFilter: PRMCameraFilter, @unchecked Sendable {
    var renderCallCount = 0
    var shouldReturnNil = false

    func render(image: CIImage) -> CIImage? {
        renderCallCount += 1
        if shouldReturnNil { return nil }
        // Simple pass-through
        return image
    }
}

// MARK: - PRMCameraFilterTests

@Suite("PRMCameraFilter Protocol")
struct PRMCameraFilterTests {
    @Test("Mock filter conforms to protocol")
    func protocolConformance() {
        let filter: any PRMCameraFilter = MockFilter()
        let image = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
        let result = filter.render(image: image)
        #expect(result != nil)
    }

    @Test("Filter render is called")
    func renderIsCalled() {
        let filter = MockFilter()
        let image = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
        _ = filter.render(image: image)
        #expect(filter.renderCallCount == 1)
    }

    @Test("Filter can return nil")
    func filterReturnsNil() {
        let filter = MockFilter()
        filter.shouldReturnNil = true
        let image = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
        let result = filter.render(image: image)
        #expect(result == nil)
    }
}
