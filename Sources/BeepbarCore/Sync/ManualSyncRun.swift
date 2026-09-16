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

public struct SyncedItem: Sendable, Equatable, Codable, Identifiable, Hashable {
    public enum Kind: Sendable, Equatable, Codable { case added, updated }

    public let id: String
    public let name: String
    public let kind: Kind

    public init(id: String, name: String, kind: Kind) {
        self.id = id
        self.name = name
        self.kind = kind
    }
}

public struct CourseSyncCount: Sendable, Equatable, Codable, Identifiable {
    public let courseID: Int64
    public let courseFolder: String
    public let added: Int
    public let updated: Int
    public let items: [SyncedItem]

    public var id: Int64 { courseID }
    public var total: Int { added + updated }

    public init(courseID: Int64, courseFolder: String, added: Int, updated: Int, items: [SyncedItem] = []) {
        self.courseID = courseID
        self.courseFolder = courseFolder
        self.added = added
        self.updated = updated
        self.items = items
    }
}

public struct SyncProgress: Sendable, Equatable {
    public let completed: Int
    public let total: Int
    public let added: Int
    public let updated: Int
    public let preservedLocal: Int
    public let unchanged: Int
    public let conflicts: Int
    public let failures: Int
    public let perCourse: [CourseSyncCount]

    public var installed: Int { added + updated }

    public init(completed: Int, total: Int, added: Int, updated: Int, preservedLocal: Int, unchanged: Int, conflicts: Int, failures: Int, perCourse: [CourseSyncCount] = []) {
        self.completed = completed
        self.total = total
        self.added = added
        self.updated = updated
        self.preservedLocal = preservedLocal
        self.unchanged = unchanged
        self.conflicts = conflicts
        self.failures = failures
        self.perCourse = perCourse
    }

    public init(completed: Int, total: Int, installed: Int, preservedLocal: Int, unchanged: Int, conflicts: Int, failures: Int) {
        self.init(completed: completed, total: total, added: installed, updated: 0, preservedLocal: preservedLocal, unchanged: unchanged, conflicts: conflicts, failures: failures)
    }
}

public enum SyncDownloadError: Error, Sendable, Equatable {
    case authorizationRejected(Int)
}

public actor ManualSyncRun {
    private let rootID: UUID
    private let database: SyncDatabase
    private let fileStore: FileStore
    private let gate: RootOperationGate
    private let maximumConcurrentDownloads: Int
    private let allowsExpensiveNetworkAccess: Bool
    private let serverPolicy: WeBeepServerPolicy
    private let downloader: RemoteDownloader?

    public init(rootID: UUID, database: SyncDatabase, fileStore: FileStore, gate: RootOperationGate, maximumConcurrentDownloads: Int = 3, allowsExpensiveNetworkAccess: Bool = true, serverPolicy: WeBeepServerPolicy = .production, downloader: RemoteDownloader? = nil) {
        self.rootID = rootID
        self.database = database
        self.fileStore = fileStore
        self.gate = gate
        self.maximumConcurrentDownloads = maximumConcurrentDownloads
        self.allowsExpensiveNetworkAccess = allowsExpensiveNetworkAccess
        self.serverPolicy = serverPolicy
        self.downloader = downloader
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
        var added = 0
        var updated = 0
        var preservedLocal = 0
        var unchanged = 0
        var conflicts = 0
        var failures = 0
        var perCourseAdded: [Int64: Int] = [:]
        var perCourseUpdated: [Int64: Int] = [:]
        var perCourseFolder: [Int64: String] = [:]
        var perCourseItems: [Int64: [SyncedItem]] = [:]
        let downloader = downloader ?? RemoteDownloader(maximumConnections: maximumConcurrentDownloads, allowsExpensiveNetworkAccess: allowsExpensiveNetworkAccess, policy: serverPolicy)
        try await withThrowingTaskGroup(of: (PreparedSyncItem, ManualSyncOutcome?).self) { group in
            var next = 0
            func enqueue(_ item: PreparedSyncItem) {
                group.addTask { [rootID, database, fileStore, downloader] in
                    do {
                        let engine = ManualSyncEngine(rootID: rootID, database: database, fileStore: fileStore, downloader: downloader)
                        return (item, try await engine.sync(file: item.remote, destination: item.destination, token: token))
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch let error as RemoteDownloadError {
                        switch error {
                        case .cancelled:
                            throw CancellationError()
                        case .network(let failure):
                            throw WeBeepAPIError.network(failure)
                        case .transport(let status) where status == 401 || status == 403:
                            throw SyncDownloadError.authorizationRejected(status)
                        case .transport(let status) where status >= 500:
                            throw WeBeepAPIError.transport(status)
                        default:
                            return (item, nil)
                        }
                    } catch {
                        return (item, nil)
                    }
                }
            }
            while next < min(maximumConcurrentDownloads, items.count) { enqueue(items[next]); next += 1 }
            while let (item, outcome) = try await group.next() {
                try Task.checkCancellation()
                completed += 1
                let courseID = item.remote.courseID
                switch outcome {
                case .installedNew?:
                    added += 1
                    perCourseAdded[courseID, default: 0] += 1
                    perCourseFolder[courseID] = Self.courseFolder(for: item.destination)
                    perCourseItems[courseID, default: []].append(Self.syncedItem(for: item, kind: .added))
                case .installedReplacing?:
                    updated += 1
                    perCourseUpdated[courseID, default: 0] += 1
                    perCourseFolder[courseID] = Self.courseFolder(for: item.destination)
                    perCourseItems[courseID, default: []].append(Self.syncedItem(for: item, kind: .updated))
                case .adoptedRemoteBaseline?: unchanged += 1
                case .preservedLocal?: preservedLocal += 1
                case .unchanged?, .skipped?: unchanged += 1
                case .conflict?: conflicts += 1
                case nil: failures += 1
                }
                await progress(SyncProgress(completed: completed, total: items.count, added: added, updated: updated, preservedLocal: preservedLocal, unchanged: unchanged, conflicts: conflicts, failures: failures, perCourse: Self.snapshotPerCourse(added: perCourseAdded, updated: perCourseUpdated, folders: perCourseFolder, items: perCourseItems)))
                if next < items.count { enqueue(items[next]); next += 1 }
            }
        }
        try Task.checkCancellation()
        return SyncProgress(completed: completed, total: items.count, added: added, updated: updated, preservedLocal: preservedLocal, unchanged: unchanged, conflicts: conflicts, failures: failures, perCourse: Self.snapshotPerCourse(added: perCourseAdded, updated: perCourseUpdated, folders: perCourseFolder, items: perCourseItems))
    }

    private static func courseFolder(for destination: RelativePath) -> String {
        destination.value.split(separator: "/", maxSplits: 1).first.map(String.init) ?? destination.value
    }

    private static func syncedItem(for item: PreparedSyncItem, kind: SyncedItem.Kind) -> SyncedItem {
        let name = item.destination.value.split(separator: "/").last.map(String.init) ?? item.destination.value
        return SyncedItem(id: item.id, name: name, kind: kind)
    }

    private static func snapshotPerCourse(added: [Int64: Int], updated: [Int64: Int], folders: [Int64: String], items: [Int64: [SyncedItem]]) -> [CourseSyncCount] {
        let ids = Set(added.keys).union(updated.keys)
        return ids.map { id in
            let sortedItems = (items[id] ?? []).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return CourseSyncCount(courseID: id, courseFolder: folders[id] ?? "", added: added[id] ?? 0, updated: updated[id] ?? 0, items: sortedItems)
        }.sorted { $0.courseFolder.localizedStandardCompare($1.courseFolder) == .orderedAscending }
    }
}
