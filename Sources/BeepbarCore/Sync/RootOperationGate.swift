import Foundation

public enum RootOperation: Sendable, Equatable {
    case recovering
    case syncing(UUID)
    case resolving(UUID)
    case renaming(Int64)
}

public enum RootOperationGateError: Error, Sendable, Equatable {
    case busy(RootOperation)
}

public actor RootOperationGate {
    private var active: RootOperation?

    public init() {}

    public func acquire(_ operation: RootOperation) throws -> Lease {
        if let active { throw RootOperationGateError.busy(active) }
        active = operation
        return Lease(gate: self, operation: operation)
    }

    public func currentOperation() -> RootOperation? { active }

    fileprivate func release(_ operation: RootOperation) {
        guard active == operation else { return }
        active = nil
    }

    public func withLease<T: Sendable>(_ operation: RootOperation, _ body: @Sendable () async throws -> T) async throws -> T {
        let lease = try acquire(operation)
        do {
            let result = try await body()
            await lease.release()
            return result
        } catch {
            await lease.release()
            throw error
        }
    }
}

public actor Lease {
    private let gate: RootOperationGate
    private let operation: RootOperation
    private var released = false

    fileprivate init(gate: RootOperationGate, operation: RootOperation) {
        self.gate = gate
        self.operation = operation
    }

    public func release() async {
        let shouldRelease = !released
        released = true
        if shouldRelease { await gate.release(operation) }
    }
}
