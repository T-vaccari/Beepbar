import CSQLite
import Foundation

public enum SyncDatabaseError: Error, Sendable, Equatable {
    case open
    case statement
    case execution
    case invalidPath
    case legacyPendingOperation
}

private final class SQLiteHandle: @unchecked Sendable {
    let pointer: OpaquePointer?

    init(_ pointer: OpaquePointer?) { self.pointer = pointer }
    deinit { sqlite3_close(pointer) }
}

public actor SyncDatabase {
    private let handle: SQLiteHandle
    private var database: OpaquePointer? { handle.pointer }

    public init(url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(database)
            throw SyncDatabaseError.open
        }
        self.handle = SQLiteHandle(database)
        try Self.execute(database, "PRAGMA foreign_keys = ON")
        try Self.execute(database, "PRAGMA journal_mode = WAL")
        try Self.migrate(database)
    }

    public func migrate() throws {
        try Self.migrate(database)
    }

    public func registerRoot(id: UUID, canonicalPath: String, securityBookmark: Data? = nil) throws {
        try withStatement("INSERT INTO roots(id, canonical_path, security_bookmark) VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET canonical_path = excluded.canonical_path, security_bookmark = excluded.security_bookmark") { statement in
            try bind(id.uuidString, to: statement, index: 1)
            try bind(canonicalPath, to: statement, index: 2)
            if let securityBookmark { sqlite3_bind_blob(statement, 3, [UInt8](securityBookmark), Int32(securityBookmark.count), transientDestructor) }
            else { sqlite3_bind_null(statement, 3) }
            try stepDone(statement)
        }
    }

    public func rootID(canonicalPath: String) throws -> UUID? {
        try withStatement("SELECT id FROM roots WHERE canonical_path = ?") { statement in
            try bind(canonicalPath, to: statement, index: 1)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            guard let id = uuid(statement, 0) else { throw SyncDatabaseError.execution }
            return id
        }
    }

    public func baseline(rootID: UUID, remoteID: String) throws -> Baseline? {
        try withStatement("SELECT relative_path, base_sha256, remote_revision FROM items WHERE root_id = ? AND remote_id = ?") { statement in
            try bind(rootID.uuidString, to: statement, index: 1)
            try bind(remoteID, to: statement, index: 2)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            guard let pathText = sqlite3_column_text(statement, 0), let hashText = sqlite3_column_text(statement, 1), let revisionText = sqlite3_column_text(statement, 2) else { throw SyncDatabaseError.execution }
            let path = try RelativePath(String(cString: pathText))
            return Baseline(remoteID: remoteID, relativePath: path, sha256: String(cString: hashText), remoteRevision: String(cString: revisionText))
        }
    }

    public func baselines(rootID: UUID) throws -> [String: Baseline] {
        try withStatement("SELECT remote_id, relative_path, base_sha256, remote_revision FROM items WHERE root_id = ?") { statement in
            try bind(rootID.uuidString, to: statement, index: 1)
            var values: [String: Baseline] = [:]
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let remoteID = text(statement, 0), let pathText = text(statement, 1), let hashText = text(statement, 2), let revisionText = text(statement, 3) else { throw SyncDatabaseError.execution }
                values[remoteID] = Baseline(remoteID: remoteID, relativePath: try RelativePath(pathText), sha256: hashText, remoteRevision: revisionText)
            }
            return values
        }
    }

    public func upsertBaseline(rootID: UUID, baseline: Baseline) throws {
        try withStatement("INSERT INTO items(root_id, remote_id, relative_path, base_sha256, remote_revision, last_seen_at) VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(root_id, remote_id) DO UPDATE SET relative_path = excluded.relative_path, base_sha256 = excluded.base_sha256, remote_revision = excluded.remote_revision, last_seen_at = excluded.last_seen_at") { statement in
            try bind(rootID.uuidString, to: statement, index: 1)
            try bind(baseline.remoteID, to: statement, index: 2)
            try bind(baseline.relativePath.value, to: statement, index: 3)
            try bind(baseline.sha256, to: statement, index: 4)
            try bind(baseline.remoteRevision, to: statement, index: 5)
            sqlite3_bind_double(statement, 6, Date().timeIntervalSince1970)
            try stepDone(statement)
        }
    }

    public func upsertScope(_ scope: SyncScope) throws {
        try withStatement("INSERT INTO sync_scopes(root_id, course_id, display_name, local_folder, enabled, managed_directory, directory_device, directory_inode) VALUES (?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(root_id, course_id) DO UPDATE SET display_name = excluded.display_name, local_folder = excluded.local_folder, enabled = excluded.enabled, managed_directory = CASE WHEN excluded.managed_directory = 1 THEN 1 ELSE sync_scopes.managed_directory END, directory_device = CASE WHEN excluded.managed_directory = 1 THEN excluded.directory_device ELSE sync_scopes.directory_device END, directory_inode = CASE WHEN excluded.managed_directory = 1 THEN excluded.directory_inode ELSE sync_scopes.directory_inode END") { statement in
            try bind(scope.rootID.uuidString, to: statement, index: 1)
            guard sqlite3_bind_int64(statement, 2, scope.courseID) == SQLITE_OK else { throw SyncDatabaseError.execution }
            try bind(scope.displayName, to: statement, index: 3)
            try bind(scope.localFolder, to: statement, index: 4)
            guard sqlite3_bind_int(statement, 5, scope.enabled ? 1 : 0) == SQLITE_OK else { throw SyncDatabaseError.execution }
            guard sqlite3_bind_int(statement, 6, scope.managedDirectory == nil ? 0 : 1) == SQLITE_OK else { throw SyncDatabaseError.execution }
            if let identity = scope.managedDirectory {
                guard sqlite3_bind_int64(statement, 7, identity.device) == SQLITE_OK,
                      sqlite3_bind_int64(statement, 8, Int64(bitPattern: identity.inode)) == SQLITE_OK else { throw SyncDatabaseError.execution }
            } else { sqlite3_bind_null(statement, 7); sqlite3_bind_null(statement, 8) }
            try stepDone(statement)
        }
    }

    public func scopes(rootID: UUID, enabledOnly: Bool = false) throws -> [SyncScope] {
        let sql = enabledOnly
            ? "SELECT course_id, display_name, local_folder, enabled, managed_directory, directory_device, directory_inode FROM sync_scopes WHERE root_id = ? AND enabled = 1 ORDER BY display_name, course_id"
            : "SELECT course_id, display_name, local_folder, enabled, managed_directory, directory_device, directory_inode FROM sync_scopes WHERE root_id = ? ORDER BY display_name, course_id"
        return try withStatement(sql) { statement in
            try bind(rootID.uuidString, to: statement, index: 1)
            var scopes: [SyncScope] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let displayName = text(statement, 1), let localFolder = text(statement, 2) else { throw SyncDatabaseError.execution }
                let identity: DirectoryIdentity? = sqlite3_column_int(statement, 4) != 0 && sqlite3_column_type(statement, 5) != SQLITE_NULL && sqlite3_column_type(statement, 6) != SQLITE_NULL ? DirectoryIdentity(device: sqlite3_column_int64(statement, 5), inode: UInt64(bitPattern: sqlite3_column_int64(statement, 6))) : nil
                scopes.append(SyncScope(rootID: rootID, courseID: sqlite3_column_int64(statement, 0), displayName: displayName, localFolder: localFolder, enabled: sqlite3_column_int(statement, 3) != 0, managedDirectory: identity))
            }
            return scopes
        }
    }

    public func beginScopeMove(_ move: PendingScopeMove) throws {
        try withStatement("INSERT INTO pending_scope_moves(id, root_id, course_id, old_folder, new_folder, phase) VALUES (?, ?, ?, ?, ?, 'prepared')") { statement in
            try bind(move.id.uuidString, to: statement, index: 1); try bind(move.rootID.uuidString, to: statement, index: 2)
            guard sqlite3_bind_int64(statement, 3, move.courseID) == SQLITE_OK else { throw SyncDatabaseError.execution }
            try bind(move.oldFolder, to: statement, index: 4); try bind(move.newFolder, to: statement, index: 5); try stepDone(statement)
        }
    }

    public func commitScopeMove(_ move: PendingScopeMove) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try withStatement("UPDATE sync_scopes SET local_folder = ? WHERE root_id = ? AND course_id = ? AND local_folder = ?") { statement in
                try bind(move.newFolder, to: statement, index: 1); try bind(move.rootID.uuidString, to: statement, index: 2)
                guard sqlite3_bind_int64(statement, 3, move.courseID) == SQLITE_OK else { throw SyncDatabaseError.execution }
                try bind(move.oldFolder, to: statement, index: 4); try stepDone(statement)
                guard sqlite3_changes(database) == 1 else { throw SyncDatabaseError.execution }
            }
            try withStatement("UPDATE items SET relative_path = ? || substr(relative_path, length(?) + 1) WHERE root_id = ? AND (relative_path = ? OR substr(relative_path, 1, length(?) + 1) = ? || '/')") { statement in
                try bind(move.newFolder, to: statement, index: 1); try bind(move.oldFolder, to: statement, index: 2); try bind(move.rootID.uuidString, to: statement, index: 3)
                try bind(move.oldFolder, to: statement, index: 4); try bind(move.oldFolder, to: statement, index: 5); try bind(move.oldFolder, to: statement, index: 6); try stepDone(statement)
            }
            try withStatement("DELETE FROM pending_scope_moves WHERE id = ?") { statement in try bind(move.id.uuidString, to: statement, index: 1); try stepDone(statement) }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }

    public func insertConflict(_ conflict: ConflictRecord) throws {
        try withStatement("INSERT INTO conflicts(id, root_id, remote_id, relative_path, incoming_path, base_sha256, local_sha256, remote_sha256, remote_revision, detected_at, status) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)") { statement in
            try bind(conflict.id.uuidString, to: statement, index: 1)
            try bind(conflict.rootID.uuidString, to: statement, index: 2)
            try bind(conflict.remoteID, to: statement, index: 3)
            try bind(conflict.relativePath.value, to: statement, index: 4)
            try bind(conflict.incomingPath.value, to: statement, index: 5)
            try bind(conflict.baseSHA256, to: statement, index: 6)
            try bind(conflict.localSHA256, to: statement, index: 7)
            try bind(conflict.remoteSHA256, to: statement, index: 8)
            try bind(conflict.remoteRevision, to: statement, index: 9)
            sqlite3_bind_double(statement, 10, conflict.detectedAt.timeIntervalSince1970)
            try bind(conflict.status.rawValue, to: statement, index: 11)
            try stepDone(statement)
        }
    }

    public func conflicts(rootID: UUID) throws -> [ConflictRecord] {
        try withStatement("SELECT id, remote_id, relative_path, incoming_path, base_sha256, local_sha256, remote_sha256, remote_revision, detected_at, status FROM conflicts WHERE root_id = ? AND status = 'open' ORDER BY detected_at DESC") { statement in
            try bind(rootID.uuidString, to: statement, index: 1)
            var records: [ConflictRecord] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let id = uuid(statement, 0), let remoteID = text(statement, 1), let relativePath = text(statement, 2), let incomingPath = text(statement, 3), let remoteSHA256 = text(statement, 6), let revision = text(statement, 7), let statusText = text(statement, 9), let status = ConflictStatus(rawValue: statusText) else { throw SyncDatabaseError.execution }
                records.append(ConflictRecord(id: id, rootID: rootID, remoteID: remoteID, relativePath: try RelativePath(relativePath), incomingPath: try RelativePath(internal: incomingPath), baseSHA256: text(statement, 4), localSHA256: text(statement, 5), remoteSHA256: remoteSHA256, remoteRevision: revision, detectedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 8)), status: status))
            }
            return records
        }
    }

    public func conflict(id: UUID) throws -> ConflictRecord? {
        try withStatement("SELECT root_id, remote_id, relative_path, incoming_path, base_sha256, local_sha256, remote_sha256, remote_revision, detected_at, status FROM conflicts WHERE id = ? AND status = 'open'") { statement in
            try bind(id.uuidString, to: statement, index: 1)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            guard let rootID = uuid(statement, 0), let remoteID = text(statement, 1), let relativePath = text(statement, 2), let incomingPath = text(statement, 3), let remoteSHA256 = text(statement, 6), let revision = text(statement, 7), let statusText = text(statement, 9), let status = ConflictStatus(rawValue: statusText) else { throw SyncDatabaseError.execution }
            return ConflictRecord(id: id, rootID: rootID, remoteID: remoteID, relativePath: try RelativePath(relativePath), incomingPath: try RelativePath(internal: incomingPath), baseSHA256: text(statement, 4), localSHA256: text(statement, 5), remoteSHA256: remoteSHA256, remoteRevision: revision, detectedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 8)), status: status)
        }
    }

    public func acceptRemoteAndResolve(id: UUID) throws -> ConflictRecord {
        guard let conflict = try conflict(id: id) else { throw SyncDatabaseError.execution }
        let baseline = Baseline(remoteID: conflict.remoteID, relativePath: conflict.relativePath, sha256: conflict.remoteSHA256, remoteRevision: conflict.remoteRevision)
        try resolveConflict(id: id, resolution: .keepLocal, baseline: baseline)
        return conflict
    }

    public func markResolved(id: UUID) throws {
        try withStatement("UPDATE conflicts SET status = 'resolved' WHERE id = ? AND status = 'open'") { statement in
            try bind(id.uuidString, to: statement, index: 1)
            try stepDone(statement)
        }
    }

    public func resolveConflict(id: UUID, resolution _: ConflictResolution, baseline: Baseline) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            let rootID = try withStatement("SELECT root_id FROM conflicts WHERE id = ?") { statement in
                try bind(id.uuidString, to: statement, index: 1)
                guard sqlite3_step(statement) == SQLITE_ROW, let rootID = uuid(statement, 0) else { throw SyncDatabaseError.execution }
                return rootID
            }
            try upsertBaseline(rootID: rootID, baseline: baseline)
            try withStatement("UPDATE conflicts SET status = 'resolved' WHERE id = ?") { statement in
                try bind(id.uuidString, to: statement, index: 1)
                try stepDone(statement)
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func beginOperation(_ operation: PendingOperation) throws {
        try withStatement("INSERT INTO pending_operations(id, root_id, remote_id, destination_path, stage_path, expected_local_kind, expected_local_sha256, remote_sha256, remote_revision, phase) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)") { statement in
            try bind(operation.id.uuidString, to: statement, index: 1)
            try bind(operation.rootID.uuidString, to: statement, index: 2)
            try bind(operation.remoteID, to: statement, index: 3)
            try bind(operation.destination.value, to: statement, index: 4)
            try bind(operation.stagePath.value, to: statement, index: 5)
            switch operation.expectedLocal {
            case .missing:
                try bind("missing", to: statement, index: 6)
                try bind(nil, to: statement, index: 7)
            case .present(let sha256):
                try bind("present", to: statement, index: 6)
                try bind(sha256, to: statement, index: 7)
            }
            try bind(operation.remoteSHA256, to: statement, index: 8)
            try bind(operation.remoteRevision, to: statement, index: 9)
            try bind(operation.phase.rawValue, to: statement, index: 10)
            try stepDone(statement)
        }
    }

    public func markCommitted(id: UUID, baseline: Baseline) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            let rootID = try rootID(forOperation: id)
            try upsertBaseline(rootID: rootID, baseline: baseline)
            try withStatement("UPDATE pending_operations SET phase = 'committed' WHERE id = ?") { statement in
                try bind(id.uuidString, to: statement, index: 1)
                try stepDone(statement)
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func finishOperation(id: UUID) throws {
        try withStatement("DELETE FROM pending_operations WHERE id = ?") { statement in
            try bind(id.uuidString, to: statement, index: 1)
            try stepDone(statement)
        }
    }

    public func finishAsConflict(id: UUID, conflict: ConflictRecord) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try insertConflict(conflict)
            try finishOperation(id: id)
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func pendingOperations(rootID: UUID? = nil) throws -> [PendingOperation] {
        let sql = rootID == nil ? "SELECT id, root_id, remote_id, destination_path, stage_path, expected_local_kind, expected_local_sha256, remote_sha256, remote_revision, phase FROM pending_operations" : "SELECT id, root_id, remote_id, destination_path, stage_path, expected_local_kind, expected_local_sha256, remote_sha256, remote_revision, phase FROM pending_operations WHERE root_id = ?"
        return try withStatement(sql) { statement in
            if let rootID { try bind(rootID.uuidString, to: statement, index: 1) }
            var operations: [PendingOperation] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let id = uuid(statement, 0), let rootID = uuid(statement, 1), let remoteID = text(statement, 2), let destination = text(statement, 3), let stage = text(statement, 4), let expectedKind = text(statement, 5), let remoteSHA256 = text(statement, 7), let remoteRevision = text(statement, 8), let phaseText = text(statement, 9), let phase = PendingOperationPhase(rawValue: phaseText) else { throw SyncDatabaseError.execution }
                let expectedLocal: LocalState
                switch expectedKind {
                case "missing": expectedLocal = .missing
                case "present":
                    guard let hash = text(statement, 6) else { throw SyncDatabaseError.execution }
                    expectedLocal = .present(sha256: hash)
                default: throw SyncDatabaseError.legacyPendingOperation
                }
                operations.append(PendingOperation(id: id, rootID: rootID, remoteID: remoteID, destination: try RelativePath(destination), stagePath: try RelativePath(internal: stage), expectedLocal: expectedLocal, remoteSHA256: remoteSHA256, remoteRevision: remoteRevision, phase: phase))
            }
            return operations
        }
    }

    public func pendingScopeMoves(rootID: UUID? = nil) throws -> [PendingScopeMove] {
        let sql = rootID == nil ? "SELECT id, root_id, course_id, old_folder, new_folder FROM pending_scope_moves" : "SELECT id, root_id, course_id, old_folder, new_folder FROM pending_scope_moves WHERE root_id = ?"
        return try withStatement(sql) { statement in
            if let rootID { try bind(rootID.uuidString, to: statement, index: 1) }
            var moves: [PendingScopeMove] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let id = uuid(statement, 0), let root = uuid(statement, 1), let old = text(statement, 3), let new = text(statement, 4) else { throw SyncDatabaseError.execution }
                moves.append(PendingScopeMove(id: id, rootID: root, courseID: sqlite3_column_int64(statement, 2), oldFolder: old, newFolder: new))
            }
            return moves
        }
    }

    public func scopeFolder(rootID: UUID, courseID: Int64) throws -> String? {
        try withStatement("SELECT local_folder FROM sync_scopes WHERE root_id = ? AND course_id = ?") { statement in
            try bind(rootID.uuidString, to: statement, index: 1)
            guard sqlite3_bind_int64(statement, 2, courseID) == SQLITE_OK else { throw SyncDatabaseError.execution }
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            guard let folder = text(statement, 0) else { throw SyncDatabaseError.execution }
            return folder
        }
    }

    public func scope(rootID: UUID, courseID: Int64) throws -> SyncScope? {
        try scopes(rootID: rootID).first { $0.courseID == courseID }
    }

    public func renameScopeMetadata(rootID: UUID, courseID: Int64, from oldFolder: String, to newFolder: String) throws {
        let move = PendingScopeMove(id: UUID(), rootID: rootID, courseID: courseID, oldFolder: oldFolder, newFolder: newFolder)
        try commitScopeMove(move)
    }

    public func hasOpenConflicts(rootID: UUID, prefix: String) throws -> Bool { try hasPath("conflicts", column: "relative_path", rootID: rootID, prefix: prefix, extra: "AND status = 'open'") }
    public func hasOpenConflict(rootID: UUID, remoteID: String, revision: String) throws -> Bool {
        try withStatement("SELECT 1 FROM conflicts WHERE root_id = ? AND remote_id = ? AND remote_revision = ? AND status = 'open' LIMIT 1") { statement in
            try bind(rootID.uuidString, to: statement, index: 1); try bind(remoteID, to: statement, index: 2); try bind(revision, to: statement, index: 3)
            return sqlite3_step(statement) == SQLITE_ROW
        }
    }
    public func hasPendingOperations(rootID: UUID, prefix: String) throws -> Bool { try hasPath("pending_operations", column: "destination_path", rootID: rootID, prefix: prefix, extra: "") }
    public func trackedItemCount(rootID: UUID, prefix: String) throws -> Int {
        try withStatement("SELECT COUNT(*) FROM items WHERE root_id = ? AND (relative_path = ? OR substr(relative_path, 1, length(?) + 1) = ? || '/')") { statement in
            try bind(rootID.uuidString, to: statement, index: 1); try bind(prefix, to: statement, index: 2); try bind(prefix, to: statement, index: 3); try bind(prefix, to: statement, index: 4)
            guard sqlite3_step(statement) == SQLITE_ROW else { throw SyncDatabaseError.execution }; return Int(sqlite3_column_int(statement, 0))
        }
    }

    private func hasPath(_ table: String, column: String, rootID: UUID, prefix: String, extra: String) throws -> Bool {
        try withStatement("SELECT 1 FROM \(table) WHERE root_id = ? AND (\(column) = ? OR substr(\(column), 1, length(?) + 1) = ? || '/') \(extra) LIMIT 1") { statement in
            try bind(rootID.uuidString, to: statement, index: 1); try bind(prefix, to: statement, index: 2); try bind(prefix, to: statement, index: 3); try bind(prefix, to: statement, index: 4)
            return sqlite3_step(statement) == SQLITE_ROW
        }
    }

    private var transientDestructor: sqlite3_destructor_type { unsafeBitCast(-1, to: sqlite3_destructor_type.self) }

    private func execute(_ sql: String) throws {
        try Self.execute(database, sql)
    }

    private static func migrate(_ database: OpaquePointer?) throws {
        try execute(database, "CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY)")
        try execute(database, "CREATE TABLE IF NOT EXISTS roots (id TEXT PRIMARY KEY, canonical_path TEXT NOT NULL UNIQUE, security_bookmark BLOB, settings_json TEXT NOT NULL DEFAULT '{}')")
        try execute(database, "CREATE TABLE IF NOT EXISTS sync_scopes (root_id TEXT NOT NULL REFERENCES roots(id) ON DELETE CASCADE, course_id INTEGER NOT NULL, display_name TEXT NOT NULL, local_folder TEXT NOT NULL DEFAULT '', enabled INTEGER NOT NULL CHECK(enabled IN (0, 1)), auto_sync INTEGER NOT NULL DEFAULT 0 CHECK(auto_sync IN (0, 1)), managed_directory INTEGER NOT NULL DEFAULT 0 CHECK(managed_directory IN (0, 1)), directory_device INTEGER, directory_inode INTEGER, PRIMARY KEY(root_id, course_id), UNIQUE(root_id, local_folder))")
        if try !columnExists(database, table: "sync_scopes", column: "auto_sync") { try execute(database, "ALTER TABLE sync_scopes ADD COLUMN auto_sync INTEGER NOT NULL DEFAULT 0") }
        try execute(database, "CREATE TABLE IF NOT EXISTS remote_observations (root_id TEXT NOT NULL REFERENCES roots(id) ON DELETE CASCADE, course_id INTEGER NOT NULL, remote_id TEXT NOT NULL, observed_revision TEXT NOT NULL, observed_sha256 TEXT, relative_path TEXT NOT NULL, size INTEGER NOT NULL, first_seen_at REAL NOT NULL, last_seen_at REAL NOT NULL, last_notified_revision TEXT, PRIMARY KEY(root_id, remote_id))")
        try execute(database, "CREATE TABLE IF NOT EXISTS items (root_id TEXT NOT NULL REFERENCES roots(id) ON DELETE CASCADE, remote_id TEXT NOT NULL, relative_path TEXT NOT NULL, base_sha256 TEXT NOT NULL, remote_revision TEXT NOT NULL, last_seen_at REAL, PRIMARY KEY(root_id, remote_id))")
        try execute(database, "CREATE TABLE IF NOT EXISTS conflicts (id TEXT PRIMARY KEY, root_id TEXT NOT NULL REFERENCES roots(id) ON DELETE CASCADE, remote_id TEXT NOT NULL, relative_path TEXT NOT NULL, incoming_path TEXT NOT NULL, base_sha256 TEXT, local_sha256 TEXT, remote_sha256 TEXT NOT NULL, remote_revision TEXT NOT NULL, detected_at REAL NOT NULL, status TEXT NOT NULL CHECK(status IN ('open', 'resolved')))")
        try execute(database, "CREATE TABLE IF NOT EXISTS pending_operations (id TEXT PRIMARY KEY, root_id TEXT NOT NULL REFERENCES roots(id) ON DELETE CASCADE, remote_id TEXT NOT NULL, destination_path TEXT NOT NULL, stage_path TEXT NOT NULL, expected_local_kind TEXT NOT NULL DEFAULT 'unknown' CHECK(expected_local_kind IN ('missing', 'present', 'unknown')), expected_local_sha256 TEXT, remote_sha256 TEXT NOT NULL DEFAULT '', remote_revision TEXT NOT NULL DEFAULT '', phase TEXT NOT NULL DEFAULT 'prepared' CHECK(phase IN ('prepared', 'committed')), UNIQUE(root_id, remote_id), UNIQUE(root_id, destination_path))")
        try execute(database, "CREATE TABLE IF NOT EXISTS pending_scope_moves (id TEXT PRIMARY KEY, root_id TEXT NOT NULL REFERENCES roots(id) ON DELETE CASCADE, course_id INTEGER NOT NULL, old_folder TEXT NOT NULL, new_folder TEXT NOT NULL, phase TEXT NOT NULL CHECK(phase IN ('prepared')), UNIQUE(root_id, course_id), UNIQUE(root_id, new_folder))")
        if try !columnExists(database, table: "pending_operations", column: "expected_local_kind") {
            try execute(database, "ALTER TABLE pending_operations ADD COLUMN expected_local_kind TEXT NOT NULL DEFAULT 'unknown'")
            try execute(database, "ALTER TABLE pending_operations ADD COLUMN expected_local_sha256 TEXT")
            try execute(database, "ALTER TABLE pending_operations ADD COLUMN remote_sha256 TEXT NOT NULL DEFAULT ''")
            try execute(database, "ALTER TABLE pending_operations ADD COLUMN remote_revision TEXT NOT NULL DEFAULT ''")
            try execute(database, "ALTER TABLE pending_operations ADD COLUMN phase TEXT NOT NULL DEFAULT 'prepared'")
        }
        if try !columnExists(database, table: "sync_scopes", column: "local_folder") {
            try execute(database, "ALTER TABLE sync_scopes ADD COLUMN local_folder TEXT NOT NULL DEFAULT ''")
        }
        if try !columnExists(database, table: "sync_scopes", column: "managed_directory") {
            try execute(database, "ALTER TABLE sync_scopes ADD COLUMN managed_directory INTEGER NOT NULL DEFAULT 0")
            try execute(database, "ALTER TABLE sync_scopes ADD COLUMN directory_device INTEGER")
            try execute(database, "ALTER TABLE sync_scopes ADD COLUMN directory_inode INTEGER")
        }
        try execute(database, "CREATE UNIQUE INDEX IF NOT EXISTS pending_operations_root_remote ON pending_operations(root_id, remote_id)")
        try execute(database, "CREATE UNIQUE INDEX IF NOT EXISTS pending_operations_root_destination ON pending_operations(root_id, destination_path)")
        try execute(database, "INSERT OR IGNORE INTO schema_migrations(version) VALUES (1)")
        try execute(database, "INSERT OR IGNORE INTO schema_migrations(version) VALUES (2)")
        try execute(database, "INSERT OR IGNORE INTO schema_migrations(version) VALUES (3)")
    }

    private static func execute(_ database: OpaquePointer?, _ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw SyncDatabaseError.execution }
    }

    private static func columnExists(_ database: OpaquePointer?, table: String, column: String) throws -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK, let statement else { throw SyncDatabaseError.statement }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 1), String(cString: name) == column { return true }
        }
        return false
    }

    private func withStatement<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw SyncDatabaseError.statement }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    private func bind(_ value: String?, to statement: OpaquePointer, index: Int32) throws {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        guard sqlite3_bind_text(statement, index, value, -1, transientDestructor) == SQLITE_OK else { throw SyncDatabaseError.execution }
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw SyncDatabaseError.execution }
    }

    private func rootID(forOperation id: UUID) throws -> UUID {
        try withStatement("SELECT root_id FROM pending_operations WHERE id = ?") { statement in
            try bind(id.uuidString, to: statement, index: 1)
            guard sqlite3_step(statement) == SQLITE_ROW, let rootID = uuid(statement, 0) else { throw SyncDatabaseError.execution }
            return rootID
        }
    }

    private func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }

    private func uuid(_ statement: OpaquePointer, _ column: Int32) -> UUID? {
        text(statement, column).flatMap(UUID.init(uuidString:))
    }
}
