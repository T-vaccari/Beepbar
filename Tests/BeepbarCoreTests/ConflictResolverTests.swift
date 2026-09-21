import Foundation
import Testing
@testable import BeepbarCore

struct ConflictResolverTests {
    @Test func keepsLocalAndAdvancesBaseline() async throws {
        let fixture = try await conflictFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await fixture.resolver.keepLocal(id: fixture.conflict.id)
        #expect(try String(contentsOf: fixture.destination, encoding: .utf8) == "local")
        #expect(try await fixture.database.conflicts(rootID: fixture.rootID).isEmpty)
        #expect(try await fixture.database.baseline(rootID: fixture.rootID, remoteID: "file")?.sha256 == fixture.conflict.remoteSHA256)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: ".beepbar/conflicts/\(fixture.conflict.id.uuidString)").path))
    }

    @Test func usesRemoteOnlyWhenLocalIsUnchanged() async throws {
        let fixture = try await conflictFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        #expect(try await fixture.resolver.useRemote(id: fixture.conflict.id) == .installedReplacing)
        #expect(try String(contentsOf: fixture.destination, encoding: .utf8) == "remote")
        #expect(try await fixture.database.conflicts(rootID: fixture.rootID).isEmpty)
    }

    @Test func usesRemoteAfterAnotherLocalEditLeavesExactlyOneOpenConflict() async throws {
        let fixture = try await conflictFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try Data("local again".utf8).write(to: fixture.destination)

        let outcome = try await fixture.resolver.useRemote(id: fixture.conflict.id)
        guard case .conflict(let replacement) = outcome else {
            Issue.record("expected a new conflict for the re-edited file, got \(outcome)")
            return
        }

        #expect(replacement.id != fixture.conflict.id)
        #expect(try String(contentsOf: fixture.destination, encoding: .utf8) == "local again")
        #expect(try await fixture.store.inspect(fixture.conflict.relativePath) == .present(sha256: try #require(replacement.localSHA256)))

        let open = try await fixture.database.conflicts(rootID: fixture.rootID)
        #expect(open.map(\.id) == [replacement.id])
        #expect(try await fixture.database.conflict(id: fixture.conflict.id) == nil)
        #expect(try await fixture.database.pendingOperations(rootID: fixture.rootID).isEmpty)

        #expect(try await fixture.store.conflictArtifact(at: fixture.conflict.incomingPath) == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: fixture.conflict.incomingPath.value).path))
        #expect(try await fixture.store.conflictArtifact(at: replacement.incomingPath)?.sha256 == replacement.remoteSHA256)
        #expect(try String(contentsOf: fixture.root.appending(path: replacement.incomingPath.value), encoding: .utf8) == "remote")
    }

    private func conflictFixture() async throws -> (root: URL, rootID: UUID, database: SyncDatabase, store: FileStore, destination: URL, conflict: ConflictRecord, resolver: ConflictResolver) {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let rootID = UUID()
        let database = try SyncDatabase(url: root.appending(path: "state.sqlite"))
        try await database.registerRoot(id: rootID, canonicalPath: root.path)
        let destination = root.appending(path: "Course/notes.txt")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("local".utf8).write(to: destination)
        let store = try FileStore(root: root)
        let stage = try await store.createStage()
        try await store.write(Data("remote".utf8), to: stage)
        let artifact = try await store.finalize(stage)
        let coordinator = SyncTransactionCoordinator(database: database, fileStore: store)
        let outcome = try await coordinator.install(rootID: rootID, remoteID: "file", destination: RelativePath("Course/notes.txt"), expectedLocal: .missing, remote: RemoteState(sha256: artifact.sha256, revision: "2"), artifact: artifact)
        guard case .conflict(let conflict) = outcome else { throw FixtureError.missingConflict }
        return (root, rootID, database, store, destination, conflict, ConflictResolver(database: database, fileStore: store, gate: RootOperationGate()))
    }

    private enum FixtureError: Error { case missingConflict }
}
