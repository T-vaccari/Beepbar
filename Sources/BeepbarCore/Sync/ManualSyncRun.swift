import Foundation

public struct PreparedSyncItem: Sendable, Equatable, Identifiable {
    public let remote: RemoteFileCandidate
    public let destination: RelativePath

    public var id: String { remote.id }

    public init(remote: RemoteFileCandidate, destination: RelativePath) {
        self.remote = remote
        self.destination = destination
    }
}

public struct SyncProgress: Sendable, Equatable {
    public let completed: Int
    public let total: Int
    public let installed: Int
    public let preservedLocal: Int
    public let unchanged: Int
    public let conflicts: Int
    public let failures: Int

    public init(completed: Int, total: Int, installed: Int, preservedLocal: Int, unchanged: Int, conflicts: Int, failures: Int) {
        self.completed = completed
        self.total = total
        self.installed = installed
        self.preservedLocal = preservedLocal
        self.unchanged = unchanged
        self.conflicts = conflicts
        self.failures = failures
    }
}

public actor ManualSyncRun {
    private let rootID: UUID
    private let database: SyncDatabase
    private let fileStore: FileStore
    private let gate: RootOperationGate
    private let maximumConcurrentDownloads: Int
    private let allowsExpensiveNetworkAccess: Bool
    private let serverPolicy: WeBeepServerPolicy

    public init(rootID: UUID, database: SyncDatabase, fileStore: FileStore, gate: RootOperationGate, maximumConcurrentDownloads: Int = 3, allowsExpensiveNetworkAccess: Bool = true, serverPolicy: WeBeepServerPolicy = .production) {
        self.rootID = rootID
        self.database = database
        self.fileStore = fileStore
        self.gate = gate
        self.maximumConcurrentDownloads = maximumConcurrentDownloads
        self.allowsExpensiveNetworkAccess = allowsExpensiveNetworkAccess
        self.serverPolicy = serverPolicy
    }

    public func start(items: [PreparedSyncItem], token: String, progress: @escaping @Sendable (SyncProgress) async -> Void) async throws -> SyncProgress {
        let runID = UUID()
        return try await gate.withLease(.syncing(runID)) {
            try await self.startWithinLease(items: items, token: token, progress: progress)
        }
    }

    public func startWithinLease(items: [PreparedSyncItem], token: String, progress: @escaping @Sendable (SyncProgress) async -> Void) async throws -> SyncProgress {
        let normalizedDestinations = items.map { $0.destination.value.precomposedStringWithCanonicalMapping.lowercased() }
        guard Set(items.map(\.id)).count == items.count, Set(normalizedDestinations).count == items.count else { throw SyncDatabaseError.execution }
        return try await execute(items: items, token: token, progress: progress)
    }

    private func execute(items: [PreparedSyncItem], token: String, progress: @escaping @Sendable (SyncProgress) async -> Void) async throws -> SyncProgress {
        let trace = PerformanceTrace.shared.begin("sync.downloadBatch", category: .sync)
        defer { PerformanceTrace.shared.end("sync.downloadBatch", category: .sync, state: trace) }
        var completed = 0
        var installed = 0
        var preservedLocal = 0
        var unchanged = 0
        var conflicts = 0
        var failures = 0
        let downloader = RemoteDownloader(maximumConnections: maximumConcurrentDownloads, allowsExpensiveNetworkAccess: allowsExpensiveNetworkAccess, policy: serverPolicy)
        try await withThrowingTaskGroup(of: ManualSyncOutcome?.self) { group in
            var next = 0
            func enqueue(_ item: PreparedSyncItem) {
                group.addTask { [rootID, database, fileStore, downloader] in
                    do {
                        let engine = ManualSyncEngine(rootID: rootID, database: database, fileStore: fileStore, downloader: downloader)
                        return try await engine.sync(file: item.remote, destination: item.destination, token: token)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch { return nil }
                }
            }
            while next < min(maximumConcurrentDownloads, items.count) { enqueue(items[next]); next += 1 }
            while let outcome = try await group.next() {
                try Task.checkCancellation()
                completed += 1
                switch outcome {
                case .installed?: installed += 1
                case .adoptedRemoteBaseline?: unchanged += 1
                case .preservedLocal?: preservedLocal += 1
                case .unchanged?, .skipped?: unchanged += 1
                case .conflict?: conflicts += 1
                case nil: failures += 1
                }
                await progress(SyncProgress(completed: completed, total: items.count, installed: installed, preservedLocal: preservedLocal, unchanged: unchanged, conflicts: conflicts, failures: failures))
                if next < items.count { enqueue(items[next]); next += 1 }
            }
        }
        try Task.checkCancellation()
        return SyncProgress(completed: completed, total: items.count, installed: installed, preservedLocal: preservedLocal, unchanged: unchanged, conflicts: conflicts, failures: failures)
    }
}
