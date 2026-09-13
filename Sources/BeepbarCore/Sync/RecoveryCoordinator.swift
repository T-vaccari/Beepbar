import Foundation

public struct RecoveryReport: Sendable, Equatable {
    public let recovered: [UUID]
    public let conflicts: [UUID]
    public let unresolved: [UUID]

    public init(recovered: [UUID] = [], conflicts: [UUID] = [], unresolved: [UUID] = []) {
        self.recovered = recovered
        self.conflicts = conflicts
        self.unresolved = unresolved
    }
}

public actor RecoveryCoordinator {
    private let database: SyncDatabase
    private let fileStore: FileStore
    private let rootID: UUID

    public init(rootID: UUID, database: SyncDatabase, fileStore: FileStore) {
        self.rootID = rootID; self.database = database; self.fileStore = fileStore
    }

    public func recover() async throws -> RecoveryReport {
        var report = RecoveryReport()
        for operation in try await database.pendingOperations(rootID: rootID) {
            let outcome = try await recover(operation)
            switch outcome {
            case .recovered: report = RecoveryReport(recovered: report.recovered + [operation.id], conflicts: report.conflicts, unresolved: report.unresolved)
            case .conflict: report = RecoveryReport(recovered: report.recovered, conflicts: report.conflicts + [operation.id], unresolved: report.unresolved)
            case .unresolved: report = RecoveryReport(recovered: report.recovered, conflicts: report.conflicts, unresolved: report.unresolved + [operation.id])
            }
        }
        for move in try await database.pendingScopeMoves(rootID: rootID) {
            let outcome = try await recover(move)
            switch outcome {
            case .recovered: report = RecoveryReport(recovered: report.recovered + [move.id], conflicts: report.conflicts, unresolved: report.unresolved)
            case .unresolved: report = RecoveryReport(recovered: report.recovered, conflicts: report.conflicts, unresolved: report.unresolved + [move.id])
            case .conflict: break
            }
        }
        return report
    }

    private enum Outcome { case recovered, conflict, unresolved }

    private func recover(_ operation: PendingOperation) async throws -> Outcome {
        let stage = try await fileStore.stagedArtifact(at: operation.stagePath)
        let destination = try await fileStore.inspect(operation.destination)
        let baseline = Baseline(remoteID: operation.remoteID, relativePath: operation.destination, sha256: operation.remoteSHA256, remoteRevision: operation.remoteRevision)

        switch operation.phase {
        case .prepared:
            return try await recoverPrepared(operation, stage: stage, destination: destination, baseline: baseline)
        case .committed:
            guard let stage else {
                try await database.finishOperation(id: operation.id)
                return .recovered
            }
            guard case .present(let expectedHash) = operation.expectedLocal, stage.sha256 == expectedHash else { return .unresolved }
            try await fileStore.discard(stage)
            try await database.finishOperation(id: operation.id)
            return .recovered
        }
    }

    private func recover(_ move: PendingScopeMove) async throws -> Outcome {
        guard let scope = try await database.scope(rootID: move.rootID, courseID: move.courseID),
              scope.localFolder == move.oldFolder,
              let managedDirectory = scope.managedDirectory else { return .unresolved }
        let old = try await fileStore.topLevelDirectoryState(move.oldFolder)
        let new = try await fileStore.topLevelDirectoryState(move.newFolder)
        switch (old, new) {
        case (.directory, .missing):
            guard try await fileStore.topLevelDirectoryIdentity(move.oldFolder) == managedDirectory else { return .unresolved }
            try await fileStore.renameTopLevelDirectory(from: move.oldFolder, to: move.newFolder)
            guard try await fileStore.topLevelDirectoryIdentity(move.newFolder) == managedDirectory else { return .unresolved }
            try await database.commitScopeMove(move)
            return .recovered
        case (.missing, .directory):
            guard try await fileStore.topLevelDirectoryIdentity(move.newFolder) == managedDirectory else { return .unresolved }
            try await database.commitScopeMove(move)
            return .recovered
        default:
            return .unresolved
        }
    }

    private func recoverPrepared(_ operation: PendingOperation, stage: StagedArtifact?, destination: LocalState, baseline: Baseline) async throws -> Outcome {
        guard let stage else {
            let incomingPath = try RelativePath(internal: ".beepbar/conflicts/\(operation.id.uuidString)/\(operation.destination.value)")
            if let incoming = try await fileStore.conflictArtifact(at: incomingPath),
               incoming.sha256 == operation.remoteSHA256,
               destination != .present(sha256: operation.remoteSHA256) {
                let conflict = ConflictRecord(id: operation.id, rootID: operation.rootID, remoteID: operation.remoteID, relativePath: operation.destination, incomingPath: incomingPath, baseSHA256: operation.expectedLocal.sha256, localSHA256: destination.sha256, remoteSHA256: operation.remoteSHA256, remoteRevision: operation.remoteRevision, detectedAt: Date(), status: .open)
                try await database.finishAsConflict(id: operation.id, conflict: conflict)
                return .conflict
            }
            if destination == .present(sha256: operation.remoteSHA256) {
                try await database.markCommitted(id: operation.id, baseline: baseline)
                try await database.finishOperation(id: operation.id)
                return .recovered
            }
            return .unresolved
        }

        if stage.sha256 != operation.remoteSHA256 {
            guard case .present(let expectedHash) = operation.expectedLocal, stage.sha256 == expectedHash else { return .unresolved }
            guard destination != operation.expectedLocal else { return .unresolved }
            try await database.markCommitted(id: operation.id, baseline: baseline)
            try await fileStore.discard(stage)
            try await database.finishOperation(id: operation.id)
            return .recovered
        }
        if destination == operation.expectedLocal {
            switch try await fileStore.install(stage, at: operation.destination, expectedLocal: operation.expectedLocal) {
            case .installedNew:
                try await database.markCommitted(id: operation.id, baseline: baseline)
                try await database.finishOperation(id: operation.id)
                return .recovered
            case .installedReplacing(let rollback):
                try await database.markCommitted(id: operation.id, baseline: baseline)
                try await fileStore.discard(rollback)
                try await database.finishOperation(id: operation.id)
                return .recovered
            case .localChanged:
                return try await preserveConflict(operation, stage: stage, destination: try await fileStore.inspect(operation.destination))
            }
        }
        return try await preserveConflict(operation, stage: stage, destination: destination)
    }

    private func preserveConflict(_ operation: PendingOperation, stage: StagedArtifact, destination: LocalState) async throws -> Outcome {
        let incoming = try await fileStore.preserveAsConflict(stage, conflictID: operation.id, at: operation.destination)
        let conflict = ConflictRecord(id: operation.id, rootID: operation.rootID, remoteID: operation.remoteID, relativePath: operation.destination, incomingPath: incoming, baseSHA256: operation.expectedLocal.sha256, localSHA256: destination.sha256, remoteSHA256: operation.remoteSHA256, remoteRevision: operation.remoteRevision, detectedAt: Date(), status: .open)
        try await database.finishAsConflict(id: operation.id, conflict: conflict)
        return .conflict
    }
}

private extension LocalState {
    var sha256: String? {
        if case .present(let sha256) = self { return sha256 }
        return nil
    }
}
