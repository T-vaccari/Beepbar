import Foundation
import Testing
@testable import BeepbarCore

struct CourseFolderRenamerTests {
    @Test func renamesDirectoryCreatedAfterScopeRegistration() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rootID = UUID()
        let database = try SyncDatabase(url: root.appending(path: "state.sqlite"))
        try await database.registerRoot(id: rootID, canonicalPath: root.path)
        let store = try FileStore(root: root)
        try await database.upsertScope(SyncScope(rootID: rootID, courseID: 1, displayName: "Course", localFolder: "Old", enabled: true))
        let identity = try await store.ensureTopLevelDirectory("Old").identity
        try await database.upsertScope(SyncScope(rootID: rootID, courseID: 1, displayName: "Course", localFolder: "Old", enabled: true, managedDirectory: identity))
        let renamer = CourseFolderRenamer(database: database, fileStore: store, gate: RootOperationGate())
        try await renamer.rename(rootID: rootID, courseID: 1, from: "Old", to: "New")
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "New").path))
        #expect(try await database.scope(rootID: rootID, courseID: 1)?.localFolder == "New")
    }

    @Test func renamesManagedDirectoryAndTrackedPath() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rootID = UUID()
        let database = try SyncDatabase(url: root.appending(path: "state.sqlite"))
        try await database.registerRoot(id: rootID, canonicalPath: root.path)
        let store = try FileStore(root: root)
        let identity = try await store.ensureTopLevelDirectory("Old").identity
        try await database.upsertScope(SyncScope(rootID: rootID, courseID: 1, displayName: "Course", localFolder: "Old", enabled: true, managedDirectory: identity))
        let path = try RelativePath("Old/notes.txt")
        try Data("local bytes".utf8).write(to: root.appending(path: path.value))
        try await database.upsertBaseline(rootID: rootID, baseline: Baseline(remoteID: "file", relativePath: path, sha256: "base", remoteRevision: "1"))
        let renamer = CourseFolderRenamer(database: database, fileStore: store, gate: RootOperationGate())
        try await renamer.rename(rootID: rootID, courseID: 1, from: "Old", to: "New")
        #expect(try String(contentsOf: root.appending(path: "New/notes.txt"), encoding: .utf8) == "local bytes")
        #expect(try await database.baseline(rootID: rootID, remoteID: "file")?.relativePath.value == "New/notes.txt")
        #expect(try await database.pendingScopeMoves().isEmpty)
    }

    @Test func recoveryFinishesRenameAfterFilesystemMove() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rootID = UUID()
        let database = try SyncDatabase(url: root.appending(path: "state.sqlite"))
        try await database.registerRoot(id: rootID, canonicalPath: root.path)
        let store = try FileStore(root: root)
        let identity = try await store.ensureTopLevelDirectory("Old").identity
        try await database.upsertScope(SyncScope(rootID: rootID, courseID: 1, displayName: "Course", localFolder: "Old", enabled: true, managedDirectory: identity))
        let move = PendingScopeMove(id: UUID(), rootID: rootID, courseID: 1, oldFolder: "Old", newFolder: "New")
        try await database.beginScopeMove(move)
        try await store.renameTopLevelDirectory(from: "Old", to: "New")
        let report = try await RecoveryCoordinator(rootID: rootID, database: database, fileStore: store).recover()
        #expect(report.recovered.contains(move.id))
        #expect(try await database.pendingScopeMoves().isEmpty)
    }

    @Test func recoveryLeavesReplacementAtOldPathUnresolved() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rootID = UUID()
        let database = try SyncDatabase(url: root.appending(path: "state.sqlite"))
        try await database.registerRoot(id: rootID, canonicalPath: root.path)
        let store = try FileStore(root: root)
        let identity = try await store.ensureTopLevelDirectory("Old").identity
        try await database.upsertScope(SyncScope(rootID: rootID, courseID: 1, displayName: "Course", localFolder: "Old", enabled: true, managedDirectory: identity))
        let move = PendingScopeMove(id: UUID(), rootID: rootID, courseID: 1, oldFolder: "Old", newFolder: "New")
        try await database.beginScopeMove(move)
        try FileManager.default.removeItem(at: root.appending(path: "Old"))
        try FileManager.default.createDirectory(at: root.appending(path: "Old"), withIntermediateDirectories: true)

        let report = try await RecoveryCoordinator(rootID: rootID, database: database, fileStore: store).recover()
        #expect(report.unresolved.contains(move.id))
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "Old").path))
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "New").path))
        #expect(try await database.pendingScopeMoves().contains(where: { $0.id == move.id }))
    }

    @Test func recoveryDoesNotCommitReplacementAtNewPath() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rootID = UUID()
        let database = try SyncDatabase(url: root.appending(path: "state.sqlite"))
        try await database.registerRoot(id: rootID, canonicalPath: root.path)
        let store = try FileStore(root: root)
        let identity = try await store.ensureTopLevelDirectory("Old").identity
        try await database.upsertScope(SyncScope(rootID: rootID, courseID: 1, displayName: "Course", localFolder: "Old", enabled: true, managedDirectory: identity))
        let move = PendingScopeMove(id: UUID(), rootID: rootID, courseID: 1, oldFolder: "Old", newFolder: "New")
        try await database.beginScopeMove(move)
        try FileManager.default.removeItem(at: root.appending(path: "Old"))
        try FileManager.default.createDirectory(at: root.appending(path: "New"), withIntermediateDirectories: true)

        let report = try await RecoveryCoordinator(rootID: rootID, database: database, fileStore: store).recover()
        #expect(report.unresolved.contains(move.id))
        #expect(try await database.scope(rootID: rootID, courseID: 1)?.localFolder == "Old")
        #expect(try await database.pendingScopeMoves().contains(where: { $0.id == move.id }))
    }

    @Test func refusesToRenameUnmanagedDirectory() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rootID = UUID()
        let database = try SyncDatabase(url: root.appending(path: "state.sqlite"))
        try await database.registerRoot(id: rootID, canonicalPath: root.path)
        try await database.upsertScope(SyncScope(rootID: rootID, courseID: 1, displayName: "Course", localFolder: "Old", enabled: true))
        try FileManager.default.createDirectory(at: root.appending(path: "Old"), withIntermediateDirectories: true)
        let renamer = CourseFolderRenamer(database: database, fileStore: try FileStore(root: root), gate: RootOperationGate())
        await #expect(throws: SyncDatabaseError.self) {
            try await renamer.rename(rootID: rootID, courseID: 1, from: "Old", to: "New")
        }
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "Old").path))
    }

    @Test func refusesToRenameIntoTheReservedNamespace() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rootID = UUID()
        let database = try SyncDatabase(url: root.appending(path: "state.sqlite"))
        try await database.registerRoot(id: rootID, canonicalPath: root.path)
        let store = try FileStore(root: root)
        let identity = try await store.ensureTopLevelDirectory("Old").identity
        try await database.upsertScope(SyncScope(rootID: rootID, courseID: 1, displayName: "Course", localFolder: "Old", enabled: true, managedDirectory: identity))
        let renamer = CourseFolderRenamer(database: database, fileStore: store, gate: RootOperationGate())
        await #expect(throws: FileStoreError.invalidStage) {
            try await renamer.rename(rootID: rootID, courseID: 1, from: "Old", to: ".BEEPBAR")
        }
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "Old").path))
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: ".BEEPBAR").path))
        #expect(try await database.pendingScopeMoves().isEmpty)
        #expect(try await database.scope(rootID: rootID, courseID: 1)?.localFolder == "Old")
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
