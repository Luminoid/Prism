import Testing
@testable import PrismCore

struct PRMStreamRegistryTests {
    @Test
    func `The initial value arrives first`() async {
        let registry = PRMStreamRegistry<Int>()
        var iterator = registry.makeStream(initial: 1).makeAsyncIterator()
        registry.yield(2)
        #expect(await iterator.next() == 1)
        #expect(await iterator.next() == 2)
    }

    @Test
    func `Every subscriber receives each value`() async {
        let registry = PRMStreamRegistry<Int>()
        var first = registry.makeStream().makeAsyncIterator()
        var second = registry.makeStream().makeAsyncIterator()
        #expect(registry.count == 2)
        registry.yield(7)
        #expect(await first.next() == 7)
        #expect(await second.next() == 7)
    }

    @Test
    func `Cancelling a subscriber removes it`() async {
        let registry = PRMStreamRegistry<Int>()
        let stream = registry.makeStream()
        let task = Task {
            for await _ in stream {}
        }
        #expect(registry.count == 1)
        task.cancel()
        await task.value
        for _ in 0 ..< 1000 where !registry.isEmpty {
            await Task.yield()
        }
        #expect(registry.isEmpty)
    }

    @Test
    func `finishAll ends every subscription`() async {
        let registry = PRMStreamRegistry<Int>()
        var iterator = registry.makeStream().makeAsyncIterator()
        registry.finishAll()
        #expect(await iterator.next() == nil)
        #expect(registry.isEmpty)
    }

    @Test
    func `Newest-only buffering keeps the latest value`() async {
        let registry = PRMStreamRegistry<Int>(bufferingPolicy: .bufferingNewest(1))
        var iterator = registry.makeStream().makeAsyncIterator()
        registry.yield(1)
        registry.yield(2)
        registry.yield(3)
        #expect(await iterator.next() == 3)
    }

    @Test
    func `Yielding with no subscribers is a no-op`() {
        let registry = PRMStreamRegistry<Int>()
        registry.yield(1)
        #expect(registry.isEmpty)
    }
}
