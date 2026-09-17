import Foundation

public actor ConflictResolver {
    private let database: SyncDatabase
    private let fileStore: FileStore
    private let gate: RootOperationGate

    public init(database: SyncDatabase, fileStore: FileStore, gate: RootOperationGate) {
        self.database = database
        self.fileStore = fileStore
        self.gate = gate
    }

    public func keepLocal(id: UUID) async throws {
        try await gate.withLease(.resolving(id)) { [database, fileStore] in
            let conflict = try await database.acceptRemoteAndResolve(id: id)
            try? await fileStore.discardConflictArtifact(at: conflict.incomingPath, expectedSHA256: conflict.remoteSHA256)
        }
    }

    public func useRemote(id: UUID) async throws -> TransactionOutcome {
        try await gate.withLease(.resolving(id)) { [database, fileStore] in
            guard let conflict = try await database.conflict(id: id) else { throw SyncDatabaseError.execution }
            let remote = RemoteState(sha256: conflict.remoteSHA256, revision: conflict.remoteRevision)
            if try await fileStore.inspect(conflict.relativePath) == .present(sha256: remote.sha256),
               let baseline = try await database.baseline(rootID: conflict.rootID, remoteID: conflict.remoteID),
               baseline.sha256 == remote.sha256, baseline.remoteRevision == remote.revision {
                try await database.markResolved(id: conflict.id)
                try? await fileStore.discardConflictArtifact(at: conflict.incomingPath, expectedSHA256: remote.sha256)
                return .installedReplacing
            }
            let expectedLocal: LocalState = conflict.localSHA256.map { .present(sha256: $0) } ?? .missing
            let artifact = try await fileStore.copyConflictArtifactToStage(at: conflict.incomingPath, expectedSHA256: conflict.remoteSHA256)
            let coordinator = SyncTransactionCoordinator(database: database, fileStore: fileStore)
            let outcome = try await coordinator.install(rootID: conflict.rootID, remoteID: conflict.remoteID, destination: conflict.relativePath, expectedLocal: expectedLocal, remote: remote, artifact: artifact)
            // Either the remote content is now installed, or the local file changed again after detection and the
            // coordinator recorded a replacement conflict that carries the current local hash and its own copy of
            // the remote content. In both cases this record and its artifact are superseded, so resolve them
            // instead of leaving a second open conflict (and a second disk copy) for the same file.
            try await database.markResolved(id: conflict.id)
            try await fileStore.discardConflictArtifact(at: conflict.incomingPath, expectedSHA256: conflict.remoteSHA256)
            return outcome
        }
    }
}
