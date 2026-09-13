import Foundation
import Testing
@testable import BeepbarCore

struct SyncTransactionCoordinatorTests {
    @Test func commitsBaselineAfterInstallingNewFile() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rootID = UUID()
        let database = try SyncDatabase(url: root.appending(path: "state.sqlite"))
        try await database.registerRoot(id: rootID, canonicalPath: root.path)
        let store = try FileStore(root: root)
        let coordinator = SyncTransactionCoordinator(database: database, fileStore: store)
        let path = try RelativePath("Course/notes.txt")
        let stage = try await store.createStage()
        try await store.write(Data("remote".utf8), to: stage)
        let artifact = try await store.finalize(stage)
        let remote = RemoteState(sha256: artifact.sha256, revision: "2")

        #expect(try await coordinator.install(rootID: rootID, remoteID: "file", destination: path, expectedLocal: .missing, remote: remote, artifact: artifact) == .installed)
        #expect(try await database.baseline(rootID: rootID, remoteID: "file") == Baseline(remoteID: "file", relativePath: path, sha256: artifact.sha256, remoteRevision: "2"))
        #expect(try await database.pendingOperations().isEmpty)
    }

    @Test func preservesLocalFileAndRecordsConflict() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rootID = UUID()
        let database = try SyncDatabase(url: root.appending(path: "state.sqlite"))
        try await database.registerRoot(id: rootID, canonicalPath: root.path)
        let destination = root.appending(path: "Course/notes.txt")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("local".utf8).write(to: destination)
        let store = try FileStore(root: root)
        let coordinator = SyncTransactionCoordinator(database: database, fileStore: store)
        let path = try RelativePath("Course/notes.txt")
        let stage = try await store.createStage()
        try await store.write(Data("remote".utf8), to: stage)
        let artifact = try await store.finalize(stage)
        let remote = RemoteState(sha256: artifact.sha256, revision: "2")

        let outcome = try await coordinator.install(rootID: rootID, remoteID: "file", destination: path, expectedLocal: .missing, remote: remote, artifact: artifact)
        guard case .conflict(let conflict) = outcome else { Issue.record("expected conflict"); return }
        #expect(try String(contentsOf: destination, encoding: .utf8) == "local")
        #expect(try String(contentsOf: root.appending(path: conflict.incomingPath.value), encoding: .utf8) == "remote")
        let conflicts = try await database.conflicts(rootID: rootID)
        #expect(conflicts.count == 1)
        #expect(conflicts.first?.id == conflict.id)
        #expect(conflicts.first?.incomingPath == conflict.incomingPath)
        #expect(try await database.pendingOperations().isEmpty)
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
