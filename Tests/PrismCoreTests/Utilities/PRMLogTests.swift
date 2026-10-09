//
//  PRMLogTests.swift
//  PrismCoreTests
//
//  Tests for the logging core in PRMLog.swift.
//

import Foundation
import os
import Testing
@testable import PrismCore

@Suite("PRMLog core", .serialized)
struct PRMLogTests {
    enum SampleError: Error {
        case timeout
        case failed(String)
        case wrapped(any Error)
        case labeled(underlying: any Error)
        case pair(String, underlying: any Error)
    }

    private final class Capture: Sendable {
        private let entries = OSAllocatedUnfairLock<[PRMLogEntry]>(initialState: [])

        func append(_ entry: PRMLogEntry) {
            entries.withLock { $0.append(entry) }
        }

        var all: [PRMLogEntry] {
            entries.withLock { $0 }.filter { $0.category == PRMLogTests.category.name }
        }
    }

    static let category = PRMLog.Category("LogCoreTests")

    /// Runs `body` with a capturing handler at `level`, scoped to this task. The process-wide
    /// configuration is never changed here: other suites log in parallel and rely on it.
    private func capturing(at level: PRMLogLevel = .info, _ body: () -> Void) -> [PRMLogEntry] {
        let capture = Capture()
        PRMLog.withScopedConfiguration(minimumLevel: level, handler: { capture.append($0) }, body)
        return capture.all
    }

    @Test
    func `levels are ordered and map to unified-logging types like os.Logger's methods`() {
        #expect(PRMLogLevel.allCases.sorted() == PRMLogLevel.allCases)
        #expect(PRMLogLevel.debug.osLogType == .debug)
        #expect(PRMLogLevel.info.osLogType == .info)
        #expect(PRMLogLevel.notice.osLogType == .default)
        #expect(PRMLogLevel.warning.osLogType == .error)
        #expect(PRMLogLevel.error.osLogType == .error)
        #expect(PRMLogLevel.fault.osLogType == .fault)
    }

    @Test
    func `the default threshold is info, and filtered lines are never built`() {
        #expect(PRMLog.minimumLevel == .info)
        var evaluated = false
        let entries = capturing {
            PRMLog.debug(Self.category, {
                evaluated = true
                return "hidden"
            }())
            PRMLog.info(Self.category, "shown")
        }
        #expect(!evaluated)
        #expect(entries.map(\.message) == ["shown"])
        #expect(entries.first?.file == "PRMLogTests.swift")
    }

    @Test
    func `the threshold clamps at error, so errors and faults always come through`() {
        let entries = capturing(at: .fault) {
            #expect(!PRMLog.isLogging(.warning))
            #expect(PRMLog.isLogging(.error))
            PRMLog.warning(Self.category, "dropped")
            PRMLog.error(Self.category, "kept")
            PRMLog.fault(Self.category, "kept too")
        }
        #expect(entries.map(\.level) == [.error, .fault])
    }

    @Test
    func `a scoped configuration leaves the process-wide settings alone`() {
        let entries = PRMLog.withScopedConfiguration(minimumLevel: .debug, handler: nil) {
            #expect(PRMLog.isLogging(.debug))
            #expect(PRMLog.minimumLevel == .info)
            return capturing(at: .warning) {
                PRMLog.notice(Self.category, "inner scope wins")
            }
        }
        #expect(entries.isEmpty)
        #expect(!PRMLog.isLogging(.debug))
    }

    @Test
    func `debug lines are written once the threshold is lowered`() {
        let entries = capturing(at: .debug) {
            PRMLog.debug(Self.category, "trace")
        }
        #expect(entries.map(\.level) == [.debug])
    }

    @Test
    func `private detail stays out of the public message`() {
        let entries = capturing {
            PRMLog.notice(Self.category, "Fetched page", private: "https://example.com/?token=secret")
        }
        #expect(entries.first?.message == "Fetched page")
        #expect(entries.first?.privateDetail == "https://example.com/?token=secret")
    }

    @Test
    func `an attached error adds its summary to the message and its description to the private detail`() {
        let underlying = NSError(domain: NSPOSIXErrorDomain, code: 60)
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: [NSUnderlyingErrorKey: underlying])
        let entries = capturing {
            PRMLog.error(Self.category, "Request failed", error: error)
        }
        #expect(entries.first?.message == "Request failed [NSURLErrorDomain -1001 <- NSPOSIXErrorDomain 60]")
        #expect(entries.first?.privateDetail?.contains("NSURLErrorDomain") == true)
    }

    @Test
    func `Swift enum errors summarize as type and case, keeping payloads private`() {
        let failed = PRMLog.describe(SampleError.failed("user text"))
        #expect(failed.summary.hasSuffix("SampleError.failed"))
        #expect(!failed.summary.contains("user text"))
        #expect(failed.detail?.contains("user text") == true)

        let timeout = PRMLog.describe(SampleError.timeout)
        #expect(timeout.summary.hasSuffix("SampleError.timeout"))
        #expect(timeout.detail == nil)

        let wrapped = PRMLog.describe(SampleError.wrapped(URLError(.timedOut)))
        #expect(wrapped.summary.hasSuffix("SampleError.wrapped <- NSURLErrorDomain -1001"))

        let labeled = PRMLog.describe(SampleError.labeled(underlying: URLError(.timedOut)))
        #expect(labeled.summary.hasSuffix("SampleError.labeled <- NSURLErrorDomain -1001"))

        let pair = PRMLog.describe(SampleError.pair("stage", underlying: URLError(.timedOut)))
        #expect(pair.summary.hasSuffix("SampleError.pair <- NSURLErrorDomain -1001"))
        #expect(!pair.summary.contains("stage"))
    }

    @Test
    func `once writes a key a single time until it is reset`() {
        let entries = capturing {
            for _ in 0 ..< 3 {
                PRMLog.once("test.flood", .error, Self.category, "Pool exhausted")
            }
            PRMLog.resetOnce("test.flood")
            PRMLog.once("test.flood", .error, Self.category, "Pool exhausted")
        }
        PRMLog.resetOnce("test.flood")
        #expect(entries.count == 2)
    }

    @Test
    func `formattedMessage prefixes the call site`() {
        let entry = PRMLogEntry(level: .info, category: "Test", message: "hello", file: "File.swift", line: 12)
        #expect(entry.formattedMessage == "[File.swift:12] hello")
        #expect(PRMLogEntry(level: .info, category: "Test", message: "hello").formattedMessage == "hello")
    }
}
