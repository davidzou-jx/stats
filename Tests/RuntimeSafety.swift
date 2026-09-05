import XCTest
import Darwin
@testable import Kit
@testable import Net
@testable import Disk

final class RuntimeSafetyTests: XCTestCase {
    func testCommandDrainsBothPipes() {
        let result = runCommand(path: "/bin/sh", arguments: ["-c", "head -c 262144 /dev/zero >&2; head -c 262144 /dev/zero"], timeout: 5)
        XCTAssertTrue(result.succeeded, result.failure ?? "unexpected exit")
        XCTAssertEqual(result.output.count, 262144)
        XCTAssertEqual(result.error.count, 262144)
    }

    func testCommandFailureAndLimits() {
        XCTAssertFalse(runCommand(path: "/no-such-stats-test-command").succeeded)
        let failure = runCommand(path: "/bin/sh", arguments: ["-c", "echo failure >&2; exit 7"])
        XCTAssertEqual(failure.exitCode, 7)
        XCTAssertEqual(String(data: failure.error, encoding: .utf8), "failure\n")
        let oversized = runCommand(path: "/usr/bin/yes", maxOutputBytes: 4096)
        XCTAssertEqual(oversized.failure, "Command output exceeded limit")
        XCTAssertLessThanOrEqual(oversized.output.count + oversized.error.count, 4096)
    }

    func testCommandTimeoutAndCancellation() {
        let start = ProcessInfo.processInfo.systemUptime
        let result = runCommand(path: "/bin/sh", arguments: ["-c", "trap '' TERM; while :; do :; done"], timeout: 0.1)
        XCTAssertEqual(result.failure, "Command timed out")
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 2)
        let cancelled = runCommand(path: "/bin/sleep", arguments: ["2"], cancelled: { true })
        XCTAssertEqual(cancelled.failure, "Command cancelled")
        let cancelAt = ProcessInfo.processInfo.systemUptime + 0.1
        let running = runCommand(path: "/bin/sleep", arguments: ["2"], cancelled: {
            ProcessInfo.processInfo.systemUptime >= cancelAt
        })
        XCTAssertEqual(running.failure, "Command cancelled")
    }

    func testCommandDoesNotWaitForInheritedPipe() {
        let start = ProcessInfo.processInfo.systemUptime
        let result = runCommand(path: "/bin/sh", arguments: ["-c", "sleep 1 &"], timeout: 0.1)
        XCTAssertEqual(result.failure, "Command timed out")
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.8)
    }

    func testSamplingSerializesAndCoalescesBursts() {
        let scheduler = ReadScheduler()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let done = expectation(description: "latest refresh follows running refresh")
        scheduler.request {
            XCTAssertFalse(Thread.isMainThread)
            entered.signal()
            XCTAssertEqual(release.wait(timeout: .now() + 3), .success)
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 3), .success)
        for _ in 0..<100 {
            scheduler.request { XCTFail("superseded refresh must be coalesced") }
        }
        scheduler.request { done.fulfill() }
        release.signal()
        wait(for: [done], timeout: 3)
    }

    func testStopDropsPendingSampleAndAllowsRestart() {
        let scheduler = ReadScheduler()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        scheduler.request {
            entered.signal()
            _ = release.wait(timeout: .now() + 3)
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 3), .success)
        scheduler.request { XCTFail("cancelled refresh ran") }
        scheduler.cancelPending()
        release.signal()
        scheduler.queue.sync {}
        let restarted = expectation(description: "restart")
        scheduler.request { restarted.fulfill() }
        wait(for: [restarted], timeout: 3)
    }

    func testIntervalResetRunsOffMainThread() {
        let refreshed = expectation(description: "immediate background refresh")
        let timer = Repeater(seconds: 60) {
            XCTAssertFalse(Thread.isMainThread)
            refreshed.fulfill()
        }
        timer.start()
        timer.reset(seconds: 60, restart: true)
        wait(for: [refreshed], timeout: 3)
        timer.pause()
    }

    func testSharedCountersRemainFreshForEachConsumer() {
        var now: TimeInterval = 10
        var calls = 0
        var fail = false
        let samples = SharedSample<Int>(now: { now }) {
            calls += 1
            return fail ? nil : calls * 100
        }
        XCTAssertEqual(samples.read(consumer: "usage", maxAge: 0.25), 100)
        XCTAssertEqual(samples.read(consumer: "popup", maxAge: 0.25), 100)
        XCTAssertEqual(calls, 1)
        // A consumer must receive new counters on its next poll, even if rapid.
        XCTAssertEqual(samples.read(consumer: "popup", maxAge: 0.25), 200)
        XCTAssertEqual(samples.read(consumer: "usage", maxAge: 0.25), 200)
        now += 1
        XCTAssertEqual(samples.read(consumer: "usage", maxAge: 0.25), 300)
        now += 1
        fail = true
        XCTAssertNil(samples.read(consumer: "popup", maxAge: 0.25))
        fail = false
        XCTAssertEqual(samples.read(consumer: "usage", maxAge: 0.25), 500)
    }

    func testConcurrentConsumersCollectOnce() {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = expectation(description: "both consumers")
        finished.expectedFulfillmentCount = 2
        var collections = 0
        let samples = SharedSample<Int> {
            collections += 1
            entered.signal()
            _ = release.wait(timeout: .now() + 3)
            return 1234
        }
        DispatchQueue.global().async {
            XCTAssertEqual(samples.read(consumer: "usage", maxAge: 1), 1234)
            finished.fulfill()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 3), .success)
        DispatchQueue.global().async {
            XCTAssertEqual(samples.read(consumer: "popup", maxAge: 1), 1234)
            finished.fulfill()
        }
        release.signal()
        wait(for: [finished], timeout: 3)
        XCTAssertEqual(collections, 1)
    }

    func testIPv4AndIPv6KeepFullAddressStorage() {
        var v4 = sockaddr_in()
        v4.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        v4.sin_family = sa_family_t(AF_INET)
        XCTAssertEqual(inet_pton(AF_INET, "192.0.2.17", &v4.sin_addr), 1)
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        withUnsafePointer(to: &v4) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                XCTAssertTrue(numericAddress($0, into: &buffer))
            }
        }
        XCTAssertEqual(String(cString: buffer), "192.0.2.17")
        var v6 = sockaddr_in6()
        v6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        v6.sin6_family = sa_family_t(AF_INET6)
        XCTAssertEqual(inet_pton(AF_INET6, "2001:db8:1234:5678::abcd", &v6.sin6_addr), 1)
        withUnsafePointer(to: &v6) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                XCTAssertTrue(numericAddress($0, into: &buffer))
            }
        }
        XCTAssertEqual(String(cString: buffer), "2001:db8:1234:5678::abcd")
        v6.sin6_len = UInt8(MemoryLayout<sockaddr>.size)
        withUnsafePointer(to: &v6) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                XCTAssertFalse(numericAddress($0, into: &buffer))
            }
        }
    }

    func testSMARTConversionsPreserveNormalValuesAndSaturateOverflow() {
        XCTAssertEqual(SMARTConversion.celsius(303), 30)
        XCTAssertEqual(SMARTConversion.celsius(273), 0)
        XCTAssertEqual(SMARTConversion.celsius(0), 0)
        XCTAssertEqual(SMARTConversion.bytes(10), 5_120_000)
        XCTAssertEqual(SMARTConversion.bytes(0), 0)
        XCTAssertEqual(SMARTConversion.bytes(Int64.max), Int64.max)
        let boundary = Int64.max / 512_000
        XCTAssertEqual(SMARTConversion.bytes(boundary), boundary * 512_000)
        XCTAssertEqual(SMARTConversion.bytes(boundary + 1), Int64.max)
    }
}
