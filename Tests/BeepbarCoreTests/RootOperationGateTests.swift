import Foundation
import Testing
@testable import BeepbarCore

@Suite(.serialized) struct RootOperationGateTests {
    @Test func rejectsOverlappingOperationsAndReleasesTheLease() async throws {
        let gate = RootOperationGate()
        let lease = try await gate.acquire(.syncing(UUID()))

        await #expect(throws: RootOperationGateError.self) {
            try await gate.acquire(.renaming(42))
        }

        await lease.release()
        let rename = try await gate.acquire(.renaming(42))
        await rename.release()
        #expect(await gate.currentOperation() == nil)
    }

    @Test func releasesTheLeaseWhenAnOperationIsCancelled() async throws {
        let gate = RootOperationGate()
        let task = Task {
            try await gate.withLease(.syncing(UUID())) {
                try await Task.sleep(for: .seconds(30))
            }
        }

        try await Task.sleep(for: .milliseconds(10))
        task.cancel()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(await gate.currentOperation() == nil)
    }
}
