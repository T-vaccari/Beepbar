import Foundation

public enum TransactionOutcome: Sendable, Equatable {
    case installed
    case conflict(ConflictRecord)
}

public actor SyncTransactionCoordinator {
    private let database: SyncDatabase
    private let fileStore: FileStore

    public init(database: SyncDatabase, fileStore: FileStore) {
        self.database = database
        self.fileStore = fileStore
    }

    public func install(rootID: UUID, remoteID: String, destination: RelativePath, expectedLocal: LocalState, remote: RemoteState, artifact: StagedArtifact) async throws -> TransactionOutcome {
        guard artifact.sha256 == remote.sha256 else { throw FileStoreError.invalidStage }
        let operation = PendingOperation(rootID: rootID, remoteID: remoteID, destination: destination, stagePath: artifact.stagePath, expectedLocal: expectedLocal, remoteSHA256: remote.sha256, remoteRevision: remote.revision)
        try await database.beginOperation(operation)
        let result = try await fileStore.install(artifact, at: destination, expectedLocal: expectedLocal)
        switch result {
        case .installedNew:
            try await database.markCommitted(id: operation.id, baseline: Baseline(remoteID: remoteID, relativePath: destination, sha256: remote.sha256, remoteRevision: remote.revision))
            try await database.finishOperation(id: operation.id)
            return .installed
        case .installedReplacing(let rollback):
            try await database.markCommitted(id: operation.id, baseline: Baseline(remoteID: remoteID, relativePath: destination, sha256: remote.sha256, remoteRevision: remote.revision))
            try await fileStore.discard(rollback)
            try await database.finishOperation(id: operation.id)
            return .installed
        case .localChanged:
            let conflictID = operation.id
            let incoming = try await fileStore.preserveAsConflict(artifact, conflictID: conflictID, at: destination)
            let local = try await fileStore.inspect(destination)
            let conflict = ConflictRecord(id: conflictID, rootID: rootID, remoteID: remoteID, relativePath: destination, incomingPath: incoming, baseSHA256: expectedLocal.sha256, localSHA256: local.sha256, remoteSHA256: remote.sha256, remoteRevision: remote.revision, detectedAt: Date(), status: .open)
            try await database.finishAsConflict(id: operation.id, conflict: conflict)
            return .conflict(conflict)
        }
    }

    public func recordConflict(rootID: UUID, remoteID: String, destination: RelativePath, local: LocalState, remote: RemoteState, artifact: StagedArtifact) async throws -> ConflictRecord {
        guard artifact.sha256 == remote.sha256 else { throw FileStoreError.invalidStage }
        let operation = PendingOperation(rootID: rootID, remoteID: remoteID, destination: destination, stagePath: artifact.stagePath, expectedLocal: local, remoteSHA256: remote.sha256, remoteRevision: remote.revision)
        try await database.beginOperation(operation)
        let incoming = try await fileStore.preserveAsConflict(artifact, conflictID: operation.id, at: destination)
        let conflict = ConflictRecord(id: operation.id, rootID: rootID, remoteID: remoteID, relativePath: destination, incomingPath: incoming, baseSHA256: try await database.baseline(rootID: rootID, remoteID: remoteID)?.sha256, localSHA256: local.sha256, remoteSHA256: remote.sha256, remoteRevision: remote.revision, detectedAt: Date(), status: .open)
        try await database.finishAsConflict(id: operation.id, conflict: conflict)
        return conflict
    }
}

private extension LocalState {
    var sha256: String? {
        if case .present(let sha256) = self { return sha256 }
        return nil
    }
}
