import Foundation
@testable import KontextVideoSDK
import Testing

/// `awaitShared`: every waiter gets the shared result, a cancelled waiter stops alone, and a cancellation
/// racing the completion resumes once.
extension SerialSuites {
@Suite
@MainActor
struct AwaitSharedTests {
    /// Lets a test hold shared work open until it says so.
    final class Gate {
        var open = false
    }

    private struct Boom: Error {}

    @Test func awaitSharedGivesEveryWaiterTheSameResultEvenWhenTheWorkIsAlreadyDone() async throws {
        let done = Task<Int, Error> { 7 }
        _ = try await done.value
        #expect(try await awaitShared(done) == 7)
        #expect(try await awaitShared(done) == 7, "a finished task answers every later waiter")
        let failed = Task<Int, Error> { throw Boom() }
        await #expect(throws: Boom.self) { try await awaitShared(failed) }
        await #expect(throws: Boom.self) { try await awaitShared(failed) }
    }

    @Test func awaitSharedSharesAFailureAmongItsWaiters() async {
        let gate = Gate()
        let work = Task<Int, Error> { @MainActor in
            while !gate.open { try await Task.sleep(nanoseconds: 5_000_000) }
            throw Boom()
        }
        let first = Task { try await awaitShared(work) }
        let second = Task { try await awaitShared(work) }
        gate.open = true
        for waiter in [first, second] {
            await #expect(throws: Boom.self) { try await waiter.value }
        }
    }

    @Test func aCallerCancelledBeforeItWaitsStopsAtOnce() async throws {
        let gate = Gate()
        defer { gate.open = true }
        let work = Task<Int, Error> { @MainActor in
            while !gate.open { try await Task.sleep(nanoseconds: 5_000_000) }
            return 1
        }
        let waiter = Task { () throws -> Int in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await awaitShared(work)
        }
        await #expect(throws: CancellationError.self) { try await waiter.value }
        #expect(!gate.open && !work.isCancelled, "the work was neither finished nor cancelled")
    }

    @Test func oneCancelledWaiterLeavesTheOthersWaiting() async throws {
        let gate = Gate()
        let work = Task<Int, Error> { @MainActor in
            while !gate.open { try await Task.sleep(nanoseconds: 5_000_000) }
            return 42
        }
        let cancelled = Task { try await awaitShared(work) }
        let kept = Task { try await awaitShared(work) }
        await sleepMs(20)
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(!gate.open, "it stopped before the work finished")
        gate.open = true
        #expect(try await kept.value == 42)
        #expect(!work.isCancelled)
    }

    @Test func cancellationRacingCompletionResumesOnce() async {
        // Many rounds of cancel and finish at the same moment: each waiter ends exactly once, with either
        // the value or a cancellation, never twice (a double resume would trap).
        for _ in 0..<50 {
            let gate = Gate()
            let work = Task<Int, Error> { @MainActor in
                while !gate.open { await Task.yield() }
                return 1
            }
            let waiter = Task { try await awaitShared(work) }
            await Task.yield()
            gate.open = true
            waiter.cancel()
            let result = await waiter.result
            switch result {
            case .success(let value): #expect(value == 1)
            case .failure(let error): #expect(error is CancellationError)
            }
        }
    }
}
}
