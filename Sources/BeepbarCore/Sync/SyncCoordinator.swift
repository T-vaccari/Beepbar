import Foundation

public struct SyncTarget: Sendable, Equatable {
    public let courseID: Int64
    public let localFolder: String

    public init(courseID: Int64, localFolder: String) {
        self.courseID = courseID
        self.localFolder = localFolder
    }
}

public enum SyncCoordinatorMode: Sendable {
    case manual
    case automatic

    var metadataConcurrency: Int { self == .manual ? 3 : 2 }
    var downloadConcurrency: Int { self == .manual ? 3 : 2 }
    var allowsExpensiveNetworkAccess: Bool { self == .manual }
}

public actor SyncCoordinator {
    private let rootID: UUID
    private let rootURL: URL
    private let database: SyncDatabase
    private let fileStore: FileStore
    private let gate: RootOperationGate
    private let apiClient: WeBeepAPIClient

    public init(rootID: UUID, rootURL: URL, database: SyncDatabase, gate: RootOperationGate, apiClient: WeBeepAPIClient) throws {
        self.rootID = rootID
        self.rootURL = rootURL
        self.database = database
        self.fileStore = try FileStore(root: rootURL)
        self.gate = gate
        self.apiClient = apiClient
    }

    public func synchronize(targets: [SyncTarget], token: String, mode: SyncCoordinatorMode, progress: @escaping @Sendable (SyncProgress) async -> Void) async throws -> SyncProgress {
        let trace = PerformanceTrace.shared.begin("sync.run", category: .sync)
        defer { PerformanceTrace.shared.end("sync.run", category: .sync, state: trace) }
        let runID = UUID()
        return try await gate.withLease(.syncing(runID)) {
            try await self.synchronizeWithinLease(targets: targets, token: token, mode: mode, progress: progress)
        }
    }

    private func synchronizeWithinLease(targets: [SyncTarget], token: String, mode: SyncCoordinatorMode, progress: @escaping @Sendable (SyncProgress) async -> Void) async throws -> SyncProgress {
        try Task.checkCancellation()
        guard !targets.isEmpty else { return SyncProgress(completed: 0, total: 0, installed: 0, preservedLocal: 0, unchanged: 0, conflicts: 0, failures: 0) }
        try await ensureManagedDirectories(targets)
        let baselines: [String: Baseline]
        do {
            let trace = PerformanceTrace.shared.begin("sync.baselines", category: .database)
            defer { PerformanceTrace.shared.end("sync.baselines", category: .database, state: trace) }
            baselines = try await database.baselines(rootID: rootID)
        }
        let items: [PreparedSyncItem]
        do {
            let trace = PerformanceTrace.shared.begin("sync.metadata", category: .sync)
            defer { PerformanceTrace.shared.end("sync.metadata", category: .sync, state: trace) }
            items = try await prepareItems(targets: targets, token: token, baselines: baselines, concurrency: mode.metadataConcurrency)
        }
        let work: [PreparedSyncItem]
        do {
            let trace = PerformanceTrace.shared.begin("sync.planning", category: .sync)
            defer { PerformanceTrace.shared.end("sync.planning", category: .sync, state: trace) }
            work = try await itemsRequiringReconciliation(items, baselines: baselines)
        }
        guard !work.isEmpty else { return SyncProgress(completed: 0, total: 0, installed: 0, preservedLocal: 0, unchanged: 0, conflicts: 0, failures: 0) }
        let runner = ManualSyncRun(rootID: rootID, database: database, fileStore: fileStore, gate: gate, maximumConcurrentDownloads: mode.downloadConcurrency, allowsExpensiveNetworkAccess: mode.allowsExpensiveNetworkAccess, serverPolicy: apiClient.policy)
        return try await runner.startWithinLease(items: work, token: token, progress: progress)
    }

    private func ensureManagedDirectories(_ targets: [SyncTarget]) async throws {
        let scopes = try await database.scopes(rootID: rootID)
        let scopesByCourse = Dictionary(uniqueKeysWithValues: scopes.map { ($0.courseID, $0) })
        for target in targets {
            try Task.checkCancellation()
            let result = try await fileStore.ensureTopLevelDirectory(target.localFolder)
            if result.created, let scope = scopesByCourse[target.courseID] {
                try await database.upsertScope(SyncScope(rootID: rootID, courseID: scope.courseID, displayName: scope.displayName, localFolder: target.localFolder, enabled: scope.enabled, managedDirectory: result.identity))
            }
        }
    }

    private func prepareItems(targets: [SyncTarget], token: String, baselines: [String: Baseline], concurrency: Int) async throws -> [PreparedSyncItem] {
        try await withThrowingTaskGroup(of: (Int, [RemoteFileCandidate]).self) { group in
            var next = 0
            var fetched: [(Int, [RemoteFileCandidate])] = []
            func enqueue(_ index: Int) {
                let target = targets[index]
                group.addTask { [apiClient] in
                    try Task.checkCancellation()
                    let contents = try await apiClient.fetchContents(courseID: target.courseID, token: token)
                    try Task.checkCancellation()
                    return (index, contents.sections.flatMap(\.modules).flatMap(\.files).filter(\.isSupported))
                }
            }
            while next < min(concurrency, targets.count) { enqueue(next); next += 1 }
            while let result = try await group.next() {
                fetched.append(result)
                if next < targets.count { enqueue(next); next += 1 }
            }
            var items: [PreparedSyncItem] = []
            for (index, files) in fetched.sorted(by: { $0.0 < $1.0 }) {
                for file in files {
                    try Task.checkCancellation()
                    let destination = try baselines[file.id]?.relativePath ?? LocalPathPolicy.destination(courseFolder: targets[index].localFolder, file: file)
                    items.append(PreparedSyncItem(remote: file, destination: destination))
                }
            }
            try validateNoDestinationCollisions(items)
            return items
        }
    }

    private func itemsRequiringReconciliation(_ items: [PreparedSyncItem], baselines: [String: Baseline]) async throws -> [PreparedSyncItem] {
        var work: [PreparedSyncItem] = []
        for item in items {
            try Task.checkCancellation()
            if let baseline = baselines[item.remote.id], baseline.remoteRevision == item.remote.observedRevision, try await fileStore.containsRegularFile(item.destination) { continue }
            work.append(item)
        }
        return work
    }

    private func validateNoDestinationCollisions(_ items: [PreparedSyncItem]) throws {
        var identifiersByPath: [String: Set<String>] = [:]
        for item in items {
            identifiersByPath[item.destination.value.precomposedStringWithCanonicalMapping.lowercased(), default: []].insert(item.remote.id)
        }
        guard identifiersByPath.values.allSatisfy({ $0.count == 1 }) else { throw SyncDatabaseError.execution }
    }
}
