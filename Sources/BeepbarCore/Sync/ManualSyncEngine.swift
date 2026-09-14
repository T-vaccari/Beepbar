import Foundation

public enum ManualSyncOutcome: Sendable, Equatable {
    case installed
    case preservedLocal
    case adoptedRemoteBaseline
    case conflict(ConflictRecord)
    case unchanged
    case skipped(String)
}

public actor ManualSyncEngine {
    private let rootID: UUID
    private let database: SyncDatabase
    private let fileStore: FileStore
    private let downloader: RemoteDownloader
    private let transactions: SyncTransactionCoordinator

    public init(rootID: UUID, database: SyncDatabase, fileStore: FileStore, downloader: RemoteDownloader = RemoteDownloader()) {
        self.rootID = rootID
        self.database = database
        self.fileStore = fileStore
        self.downloader = downloader
        transactions = SyncTransactionCoordinator(database: database, fileStore: fileStore)
    }

    public func sync(file: RemoteFileCandidate, courseFolder: String, token: String) async throws -> ManualSyncOutcome {
        try Task.checkCancellation()
        guard file.isSupported else { return .skipped(file.ineligibilityReason ?? "materiale non supportato") }
        guard !(try await database.hasOpenConflict(rootID: rootID, remoteID: file.id, revision: file.observedRevision)) else { return .skipped("conflitto già aperto") }
        let baseline = try await database.baseline(rootID: rootID, remoteID: file.id)
        let destination = try baseline?.relativePath ?? LocalPathPolicy.destination(courseFolder: courseFolder, file: file)
        let local = try await fileStore.inspect(destination)

        if let baseline, baseline.remoteRevision == file.observedRevision, case .present = local {
            return try await apply(SyncPlanner.decide(baseline: baseline, local: local, remote: RemoteState(sha256: baseline.sha256, revision: file.observedRevision)), remoteID: file.id, baseline: baseline, destination: destination, local: local, remote: RemoteState(sha256: baseline.sha256, revision: file.observedRevision), artifact: nil)
        }

        try Task.checkCancellation()
        let downloaded = try await downloader.download(file, token: token)
        try Task.checkCancellation()
        let artifact = try await fileStore.importDownloadedFile(at: downloaded.temporaryURL, expectedSize: downloaded.expectedSize, maximumSize: 1_073_741_824)
        let remote = RemoteState(sha256: artifact.sha256, revision: file.observedRevision)
        do {
            try Task.checkCancellation()
            return try await apply(SyncPlanner.decide(baseline: baseline, local: local, remote: remote), remoteID: file.id, baseline: baseline, destination: destination, local: local, remote: remote, artifact: artifact)
        } catch {
            try? await fileStore.discard(artifact)
            throw error
        }
    }

    public func sync(file: RemoteFileCandidate, destination: RelativePath, token: String) async throws -> ManualSyncOutcome {
        try Task.checkCancellation()
        guard file.isSupported else { return .skipped(file.ineligibilityReason ?? "materiale non supportato") }
        guard !(try await database.hasOpenConflict(rootID: rootID, remoteID: file.id, revision: file.observedRevision)) else { return .skipped("conflitto già aperto") }
        let baseline = try await database.baseline(rootID: rootID, remoteID: file.id)
        if let oldPath = baseline?.relativePath, oldPath != destination,
           try await fileStore.containsRegularFile(oldPath) {
            throw SyncDatabaseError.execution
        }
        let local = try await fileStore.inspect(destination)
        if let baseline, baseline.remoteRevision == file.observedRevision, case .present = local {
            return try await apply(SyncPlanner.decide(baseline: baseline, local: local, remote: RemoteState(sha256: baseline.sha256, revision: file.observedRevision)), remoteID: file.id, baseline: baseline, destination: destination, local: local, remote: RemoteState(sha256: baseline.sha256, revision: file.observedRevision), artifact: nil)
        }
        try Task.checkCancellation()
        let downloaded = try await downloader.download(file, token: token)
        try Task.checkCancellation()
        let artifact = try await fileStore.importDownloadedFile(at: downloaded.temporaryURL, expectedSize: downloaded.expectedSize, maximumSize: 1_073_741_824)
        let remote = RemoteState(sha256: artifact.sha256, revision: file.observedRevision)
        do {
            try Task.checkCancellation()
            return try await apply(SyncPlanner.decide(baseline: baseline, local: local, remote: remote), remoteID: file.id, baseline: baseline, destination: destination, local: local, remote: remote, artifact: artifact)
        } catch {
            try? await fileStore.discard(artifact)
            throw error
        }
    }

    private func apply(_ decision: SyncDecision, remoteID: String, baseline: Baseline?, destination: RelativePath, local: LocalState, remote: RemoteState, artifact: StagedArtifact?) async throws -> ManualSyncOutcome {
        switch decision {
        case .noOp:
            if let artifact { try await fileStore.discard(artifact) }
            return .unchanged
        case .preserveLocal:
            if let artifact { try await fileStore.discard(artifact) }
            return .preservedLocal
        case .adoptRemoteBaseline:
            if let artifact { try await fileStore.discard(artifact) }
            try await database.upsertBaseline(rootID: rootID, baseline: Baseline(remoteID: remoteID, relativePath: destination, sha256: remote.sha256, remoteRevision: remote.revision))
            return .adoptedRemoteBaseline
        case .installRemote:
            guard let artifact else { throw FileStoreError.invalidStage }
            switch try await transactions.install(rootID: rootID, remoteID: remoteID, destination: destination, expectedLocal: local, remote: remote, artifact: artifact) {
            case .installed: return .installed
            case .conflict(let conflict): return .conflict(conflict)
            }
        case .conflict:
            guard let artifact else { throw FileStoreError.invalidStage }
            return .conflict(try await transactions.recordConflict(rootID: rootID, remoteID: remoteID, destination: destination, local: local, remote: remote, artifact: artifact))
        }
    }
}
