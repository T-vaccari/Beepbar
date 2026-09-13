import CryptoKit
import Foundation
import Testing
@testable import BeepbarCore

struct RecoveryCoordinatorTests {
    @Test func neverRecoversAnotherRootsOperation() async throws {
        let root = try temporaryRoot()
        let otherRoot = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: otherRoot) }
        let rootID = UUID(), otherID = UUID()
        let database = try SyncDatabase(url: root.appending(path: "state.sqlite"))
        try await database.registerRoot(id: rootID, canonicalPath: root.path)
        try await database.registerRoot(id: otherID, canonicalPath: otherRoot.path)
        let otherStore = try FileStore(root: otherRoot)
        let stage = try await otherStore.createStage()
        try await otherStore.write(Data("remote".utf8), to: stage)
        let artifact = try await otherStore.finalize(stage)
        let operation = PendingOperation(rootID: otherID, remoteID: "file", destination: try RelativePath("Course/file.txt"), stagePath: artifact.stagePath, expectedLocal: .missing, remoteSHA256: artifact.sha256, remoteRevision: "1")
        try await database.beginOperation(operation)

        let report = try await RecoveryCoordinator(rootID: rootID, database: database, fileStore: try FileStore(root: root)).recover()
        #expect(report.recovered.isEmpty)
        #expect((try await database.pendingOperations(rootID: otherID)).map(\.id) == [operation.id])
        #expect(FileManager.default.fileExists(atPath: otherRoot.appending(path: artifact.stagePath.value).path))
    }

    @Test func completesPreparedNewFileAfterInterruption() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rootID = UUID()
        let database = try SyncDatabase(url: root.appending(path: "state.sqlite"))
        try await database.registerRoot(id: rootID, canonicalPath: root.path)
        let store = try FileStore(root: root)
        let path = try RelativePath("Course/notes.txt")
        let stage = try await store.createStage()
        try await store.write(Data("remote".utf8), to: stage)
        let artifact = try await store.finalize(stage)
        let operation = PendingOperation(rootID: rootID, remoteID: "file", destination: path, stagePath: artifact.stagePath, expectedLocal: .missing, remoteSHA256: artifact.sha256, remoteRevision: "2")
        try await database.beginOperation(operation)

        let report = try await RecoveryCoordinator(rootID: rootID, database: database, fileStore: store).recover()
        #expect(report.recovered == [operation.id])
        #expect(try String(contentsOf: root.appending(path: path.value), encoding: .utf8) == "remote")
        #expect(try await database.pendingOperations().isEmpty)
    }

    @Test func cleansRollbackAfterCommittedReplacementInterruption() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rootID = UUID()
        let database = try SyncDatabase(url: root.appending(path: "state.sqlite"))
        try await database.registerRoot(id: rootID, canonicalPath: root.path)
        let path = try RelativePath("Course/notes.txt")
        let destination = root.appending(path: path.value)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("base".utf8).write(to: destination)
        let store = try FileStore(root: root)
        let stage = try await store.createStage()
        try await store.write(Data("remote".utf8), to: stage)
        let artifact = try await store.finalize(stage)
        let baseHash = hash("base")
        let operation = PendingOperation(rootID: rootID, remoteID: "file", destination: path, stagePath: artifact.stagePath, expectedLocal: .present(sha256: baseHash), remoteSHA256: artifact.sha256, remoteRevision: "2")
        try await database.beginOperation(operation)
        guard case .installedReplacing = try await store.install(artifact, at: path, expectedLocal: operation.expectedLocal) else { Issue.record("expected replacement"); return }
        try await database.markCommitted(id: operation.id, baseline: Baseline(remoteID: "file", relativePath: path, sha256: artifact.sha256, remoteRevision: "2"))

        let report = try await RecoveryCoordinator(rootID: rootID, database: database, fileStore: store).recover()
        #expect(report.recovered == [operation.id])
        #expect(try String(contentsOf: destination, encoding: .utf8) == "remote")
        #expect(try await database.pendingOperations().isEmpty)
    }

    @Test func commitsSwapThatPrecededTheDatabaseCommit() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rootID = UUID()
        let database = try SyncDatabase(url: root.appending(path: "state.sqlite"))
        try await database.registerRoot(id: rootID, canonicalPath: root.path)
        let path = try RelativePath("Course/notes.txt")
        let destination = root.appending(path: path.value)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("base".utf8).write(to: destination)
        let store = try FileStore(root: root)
        let stage = try await store.createStage()
        try await store.write(Data("remote".utf8), to: stage)
        let artifact = try await store.finalize(stage)
        let operation = PendingOperation(rootID: rootID, remoteID: "file", destination: path, stagePath: artifact.stagePath, expectedLocal: .present(sha256: hash("base")), remoteSHA256: artifact.sha256, remoteRevision: "2")
        try await database.beginOperation(operation)
        guard case .installedReplacing = try await store.install(artifact, at: path, expectedLocal: operation.expectedLocal) else { Issue.record("expected replacement"); return }

        let report = try await RecoveryCoordinator(rootID: rootID, database: database, fileStore: store).recover()
        #expect(report.recovered == [operation.id])
        #expect(try String(contentsOf: destination, encoding: .utf8) == "remote")
        #expect(try await database.baseline(rootID: rootID, remoteID: "file")?.sha256 == artifact.sha256)
        #expect(try await database.pendingOperations().isEmpty)
    }

    @Test func recordsConflictWhenCrashFollowsConflictMove() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rootID = UUID()
        let database = try SyncDatabase(url: root.appending(path: "state.sqlite"))
        try await database.registerRoot(id: rootID, canonicalPath: root.path)
        let path = try RelativePath("Course/notes.txt")
        let destination = root.appending(path: path.value)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("local".utf8).write(to: destination)
        let store = try FileStore(root: root)
        let stage = try await store.createStage()
        try await store.write(Data("remote".utf8), to: stage)
        let artifact = try await store.finalize(stage)
        let operation = PendingOperation(rootID: rootID, remoteID: "file", destination: path, stagePath: artifact.stagePath, expectedLocal: .present(sha256: hash("base")), remoteSHA256: artifact.sha256, remoteRevision: "2")
        try await database.beginOperation(operation)
        _ = try await store.preserveAsConflict(artifact, conflictID: operation.id, at: path)

        let report = try await RecoveryCoordinator(rootID: rootID, database: database, fileStore: store).recover()
        #expect(report.conflicts == [operation.id])
        #expect(try await database.pendingOperations().isEmpty)
        let conflicts = try await database.conflicts(rootID: rootID)
        #expect(conflicts.count == 1)
        #expect(try String(contentsOf: root.appending(path: conflicts[0].incomingPath.value), encoding: .utf8) == "remote")
        #expect(try String(contentsOf: destination, encoding: .utf8) == "local")
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
