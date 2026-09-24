import Foundation
import Testing
@testable import BeepbarCore

struct ModuleMoveRecoveryTests {
    @Test func recoveryMovesPreparedFileAndPreservesEditsMadeAfterJournal() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let rootID = UUID()
        let courseID: Int64 = 42
        let moduleID: Int64 = 7
        let oldPath = try RelativePath("Course/Section/notes.txt")
        let newPath = try RelativePath("Course/Custom/notes.txt")
        let sourceURL = fixture.root.appending(path: oldPath.value)
        try FileManager.default.createDirectory(at: sourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("original local edit".utf8).write(to: sourceURL)

        let database = try SyncDatabase(url: fixture.base.appending(path: "state.sqlite"))
        try await database.registerRoot(id: rootID, canonicalPath: fixture.root.path)
        let fileStore = try FileStore(root: fixture.root)
        let snapshot = try await presentSnapshot(fileStore, at: oldPath)
        let baseline = Baseline(remoteID: "file-1", relativePath: oldPath, sha256: "remote-base", remoteRevision: "r1", courseID: courseID, moduleID: moduleID)
        try await database.upsertBaseline(rootID: rootID, baseline: baseline)
        let move = move(rootID: rootID, courseID: courseID, moduleID: moduleID, remoteID: "file-1", oldPath: oldPath, newPath: newPath, source: .present(snapshot))
        try await database.beginModuleMove(move)

        let handle = try FileHandle(forWritingTo: sourceURL)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("edit after journal".utf8))
        try handle.close()

        let pending = try await database.pendingModuleMoves(rootID: rootID)
        #expect(pending.count == 1)
        #expect(try await ModuleMoveRecovery.recover(pending[0], database: database, fileStore: fileStore))
        #expect(try String(contentsOf: fixture.root.appending(path: newPath.value), encoding: .utf8) == "edit after journal")
        #expect(!FileManager.default.fileExists(atPath: sourceURL.path))
        #expect(try await database.baseline(rootID: rootID, remoteID: "file-1")?.relativePath == newPath)
        #expect(try await database.modulePathOverride(rootID: rootID, courseID: courseID, moduleID: moduleID)?.localFolder == "Custom")
        #expect(try await database.pendingModuleMoves(rootID: rootID).isEmpty)
    }

    @Test func recoveryCommitsWhenRenameCompletedBeforeCrash() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let rootID = UUID()
        let oldPath = try RelativePath("Course/Old/file.pdf")
        let newPath = try RelativePath("Course/New/file.pdf")
        let sourceURL = fixture.root.appending(path: oldPath.value)
        try FileManager.default.createDirectory(at: sourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("content".utf8).write(to: sourceURL)

        let database = try SyncDatabase(url: fixture.base.appending(path: "state.sqlite"))
        try await database.registerRoot(id: rootID, canonicalPath: fixture.root.path)
        let fileStore = try FileStore(root: fixture.root)
        let snapshot = try await presentSnapshot(fileStore, at: oldPath)
        try await database.upsertBaseline(rootID: rootID, baseline: Baseline(remoteID: "file-2", relativePath: oldPath, sha256: snapshot.sha256, remoteRevision: "r1", courseID: 42, moduleID: 8))
        let move = move(rootID: rootID, courseID: 42, moduleID: 8, remoteID: "file-2", oldPath: oldPath, newPath: newPath, source: .present(snapshot))
        try await database.beginModuleMove(move)
        try await fileStore.moveRegularFile(from: oldPath, to: newPath, expected: snapshot)

        let pending = try await database.pendingModuleMoves(rootID: rootID)
        #expect(try await ModuleMoveRecovery.recover(pending[0], database: database, fileStore: fileStore))
        #expect(try await database.baseline(rootID: rootID, remoteID: "file-2")?.relativePath == newPath)
        #expect(try await database.pendingModuleMoves(rootID: rootID).isEmpty)
    }

    @Test func recoveryDoesNotOverwriteAnOccupiedDestination() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let rootID = UUID()
        let oldPath = try RelativePath("Course/Old/file.pdf")
        let newPath = try RelativePath("Course/New/file.pdf")
        let sourceURL = fixture.root.appending(path: oldPath.value)
        let destinationURL = fixture.root.appending(path: newPath.value)
        try FileManager.default.createDirectory(at: sourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("source".utf8).write(to: sourceURL)
        try Data("occupied".utf8).write(to: destinationURL)

        let database = try SyncDatabase(url: fixture.base.appending(path: "state.sqlite"))
        try await database.registerRoot(id: rootID, canonicalPath: fixture.root.path)
        let fileStore = try FileStore(root: fixture.root)
        let snapshot = try await presentSnapshot(fileStore, at: oldPath)
        try await database.upsertBaseline(rootID: rootID, baseline: Baseline(remoteID: "file-3", relativePath: oldPath, sha256: snapshot.sha256, remoteRevision: "r1", courseID: 42, moduleID: 8))
        try await database.beginModuleMove(move(rootID: rootID, courseID: 42, moduleID: 8, remoteID: "file-3", oldPath: oldPath, newPath: newPath, source: .present(snapshot)))

        let pending = try await database.pendingModuleMoves(rootID: rootID)
        #expect(!(try await ModuleMoveRecovery.recover(pending[0], database: database, fileStore: fileStore)))
        #expect(try String(contentsOf: sourceURL, encoding: .utf8) == "source")
        #expect(try String(contentsOf: destinationURL, encoding: .utf8) == "occupied")
        #expect(try await database.baseline(rootID: rootID, remoteID: "file-3")?.relativePath == oldPath)
        #expect(try await database.pendingModuleMoves(rootID: rootID).count == 1)
    }

    @Test func missingLocalFileUpdatesItsBaselineWithoutCreatingAFile() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let rootID = UUID()
        let oldPath = try RelativePath("Course/Old/missing.pdf")
        let newPath = try RelativePath("Course/New/missing.pdf")
        let database = try SyncDatabase(url: fixture.base.appending(path: "state.sqlite"))
        try await database.registerRoot(id: rootID, canonicalPath: fixture.root.path)
        let fileStore = try FileStore(root: fixture.root)
        try await database.upsertBaseline(rootID: rootID, baseline: Baseline(remoteID: "file-4", relativePath: oldPath, sha256: "remote", remoteRevision: "r1", courseID: 42, moduleID: 8))
        try await database.beginModuleMove(move(rootID: rootID, courseID: 42, moduleID: 8, remoteID: "file-4", oldPath: oldPath, newPath: newPath, source: .missing))

        let pending = try await database.pendingModuleMoves(rootID: rootID)
        #expect(try await ModuleMoveRecovery.recover(pending[0], database: database, fileStore: fileStore))
        #expect(try await database.baseline(rootID: rootID, remoteID: "file-4")?.relativePath == newPath)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: newPath.value).path))
    }

    @Test func noOpMoveAttributesLegacyBaselineAndCommitsRule() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let rootID = UUID()
        let courseID: Int64 = 42
        let moduleID: Int64 = 8
        let path = try RelativePath("Course/Custom/file.pdf")
        let sourceURL = fixture.root.appending(path: path.value)
        try FileManager.default.createDirectory(at: sourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("local content".utf8).write(to: sourceURL)

        let database = try SyncDatabase(url: fixture.base.appending(path: "state.sqlite"))
        try await database.registerRoot(id: rootID, canonicalPath: fixture.root.path)
        let fileStore = try FileStore(root: fixture.root)
        let snapshot = try await presentSnapshot(fileStore, at: path)
        try await database.upsertBaseline(rootID: rootID, baseline: Baseline(remoteID: "file-noop", relativePath: path, sha256: "remote", remoteRevision: "r1"))
        let move = PendingModuleMove(
            rootID: rootID,
            courseID: courseID,
            moduleID: moduleID,
            action: .set,
            oldFolder: nil,
            newFolder: "Custom",
            lastKnownName: "Modulo",
            files: [PendingModuleMoveFile(remoteID: "file-noop", oldPath: path, newPath: path, source: .present(snapshot))]
        )
        try await database.beginModuleMove(move)
        try FileManager.default.removeItem(at: sourceURL)

        let pending = try await database.pendingModuleMoves(rootID: rootID)
        #expect(try await ModuleMoveRecovery.recover(pending[0], database: database, fileStore: fileStore))
        let baseline = try await database.baseline(rootID: rootID, remoteID: "file-noop")
        #expect(baseline?.relativePath == path)
        #expect(baseline?.courseID == courseID)
        #expect(baseline?.moduleID == moduleID)
        #expect(try await database.modulePathOverride(rootID: rootID, courseID: courseID, moduleID: moduleID)?.localFolder == "Custom")
        #expect(try await database.pendingModuleMoves(rootID: rootID).isEmpty)
    }

    @Test func partialMultiFileRecoveryAttributesMovedAndNoOpBaselines() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let rootID = UUID()
        let courseID: Int64 = 42
        let moduleID: Int64 = 8
        let oldPath = try RelativePath("Course/Section/a.pdf")
        let newPath = try RelativePath("Course/Custom/a.pdf")
        let noOpPath = try RelativePath("Course/Custom/b.pdf")
        let oldURL = fixture.root.appending(path: oldPath.value)
        let noOpURL = fixture.root.appending(path: noOpPath.value)
        try FileManager.default.createDirectory(at: oldURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: noOpURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("move me".utf8).write(to: oldURL)
        try Data("metadata only".utf8).write(to: noOpURL)

        let database = try SyncDatabase(url: fixture.base.appending(path: "state.sqlite"))
        try await database.registerRoot(id: rootID, canonicalPath: fixture.root.path)
        let fileStore = try FileStore(root: fixture.root)
        let movedSnapshot = try await presentSnapshot(fileStore, at: oldPath)
        let noOpSnapshot = try await presentSnapshot(fileStore, at: noOpPath)
        try await database.upsertBaseline(rootID: rootID, baseline: Baseline(remoteID: "file-moved", relativePath: oldPath, sha256: "remote-a", remoteRevision: "r1"))
        try await database.upsertBaseline(rootID: rootID, baseline: Baseline(remoteID: "file-noop", relativePath: noOpPath, sha256: "remote-b", remoteRevision: "r1"))
        let move = PendingModuleMove(
            rootID: rootID,
            courseID: courseID,
            moduleID: moduleID,
            action: .set,
            oldFolder: nil,
            newFolder: "Custom",
            lastKnownName: "Modulo",
            files: [
                PendingModuleMoveFile(remoteID: "file-moved", oldPath: oldPath, newPath: newPath, source: .present(movedSnapshot)),
                PendingModuleMoveFile(remoteID: "file-noop", oldPath: noOpPath, newPath: noOpPath, source: .present(noOpSnapshot))
            ]
        )
        try await database.beginModuleMove(move)
        try await fileStore.moveRegularFile(from: oldPath, to: newPath, expected: movedSnapshot)
        try FileManager.default.removeItem(at: noOpURL)

        let pending = try await database.pendingModuleMoves(rootID: rootID)
        #expect(try await ModuleMoveRecovery.recover(pending[0], database: database, fileStore: fileStore))
        let baselines = try await database.baselines(rootID: rootID)
        #expect(baselines["file-moved"]?.relativePath == newPath)
        #expect(baselines["file-moved"]?.courseID == courseID)
        #expect(baselines["file-moved"]?.moduleID == moduleID)
        #expect(baselines["file-noop"]?.relativePath == noOpPath)
        #expect(baselines["file-noop"]?.courseID == courseID)
        #expect(baselines["file-noop"]?.moduleID == moduleID)
        #expect(baselines["not-tracked"] == nil)
        #expect(try await database.pendingModuleMoves(rootID: rootID).isEmpty)
    }

    @Test func recoveryRemovesTheEmptiedModuleFolderButNeverTheCourseFolder() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let rootID = UUID()
        let oldPath = try RelativePath("Course/Old/Nested/file.pdf")
        let keptPath = try RelativePath("Course/Kept/file.pdf")
        let newPath = try RelativePath("Course/New/file.pdf")
        for path in [oldPath, keptPath] {
            let url = fixture.root.appending(path: path.value)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(path.value.utf8).write(to: url)
        }
        let database = try SyncDatabase(url: fixture.base.appending(path: "state.sqlite"))
        try await database.registerRoot(id: rootID, canonicalPath: fixture.root.path)
        let fileStore = try FileStore(root: fixture.root)
        let snapshot = try await presentSnapshot(fileStore, at: oldPath)
        try await database.upsertBaseline(rootID: rootID, baseline: Baseline(remoteID: "file", relativePath: oldPath, sha256: snapshot.sha256, remoteRevision: "r1", courseID: 1, moduleID: 2))
        let pending = move(rootID: rootID, courseID: 1, moduleID: 2, remoteID: "file", oldPath: oldPath, newPath: newPath, source: .present(snapshot))
        try await database.beginModuleMove(pending)

        #expect(try await ModuleMoveRecovery.recover(pending, database: database, fileStore: fileStore))

        #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: "Course/Old").path))
        #expect(FileManager.default.fileExists(atPath: fixture.root.appending(path: keptPath.value).path))
        #expect(FileManager.default.fileExists(atPath: fixture.root.appending(path: newPath.value).path))
    }

    @Test func recoveryKeepsAModuleFolderThatStillHasOtherEntries() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let rootID = UUID()
        let oldPath = try RelativePath("Course/Old/file.pdf")
        let newPath = try RelativePath("Course/New/file.pdf")
        let oldURL = fixture.root.appending(path: oldPath.value)
        try FileManager.default.createDirectory(at: oldURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("content".utf8).write(to: oldURL)
        try Data("user notes".utf8).write(to: fixture.root.appending(path: "Course/Old/notes.txt"))
        let database = try SyncDatabase(url: fixture.base.appending(path: "state.sqlite"))
        try await database.registerRoot(id: rootID, canonicalPath: fixture.root.path)
        let fileStore = try FileStore(root: fixture.root)
        let snapshot = try await presentSnapshot(fileStore, at: oldPath)
        try await database.upsertBaseline(rootID: rootID, baseline: Baseline(remoteID: "file", relativePath: oldPath, sha256: snapshot.sha256, remoteRevision: "r1", courseID: 1, moduleID: 2))
        let pending = move(rootID: rootID, courseID: 1, moduleID: 2, remoteID: "file", oldPath: oldPath, newPath: newPath, source: .present(snapshot))
        try await database.beginModuleMove(pending)

        #expect(try await ModuleMoveRecovery.recover(pending, database: database, fileStore: fileStore))

        #expect(try String(contentsOf: fixture.root.appending(path: "Course/Old/notes.txt"), encoding: .utf8) == "user notes")
    }

    @Test func abandonRecordsWhereEachFileReallyIsWithoutTouchingTheDisk() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let rootID = UUID()
        let courseID: Int64 = 1
        let moduleID: Int64 = 2
        // moved: already renamed before the crash. stayed: not moved yet, and the user then put a
        // different file at its destination. lost: moved, then deleted by the user.
        let paths = ["moved", "stayed", "lost"].map { name in
            (name, try! RelativePath("Course/Old/\(name).pdf"), try! RelativePath("Course/New/\(name).pdf"))
        }
        for (name, old, _) in paths {
            let url = fixture.root.appending(path: old.value)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(name.utf8).write(to: url)
        }
        let database = try SyncDatabase(url: fixture.base.appending(path: "state.sqlite"))
        try await database.registerRoot(id: rootID, canonicalPath: fixture.root.path)
        try await database.commitModuleMove(PendingModuleMove(rootID: rootID, courseID: courseID, moduleID: moduleID, action: .set, oldFolder: nil, newFolder: "Old", lastKnownName: "Modulo", files: []))
        let fileStore = try FileStore(root: fixture.root)
        var files: [PendingModuleMoveFile] = []
        for (name, old, new) in paths {
            let snapshot = try await presentSnapshot(fileStore, at: old)
            try await database.upsertBaseline(rootID: rootID, baseline: Baseline(remoteID: name, relativePath: old, sha256: snapshot.sha256, remoteRevision: "r1", courseID: courseID, moduleID: moduleID))
            files.append(PendingModuleMoveFile(remoteID: name, oldPath: old, newPath: new, source: .present(snapshot)))
        }
        let pending = PendingModuleMove(rootID: rootID, courseID: courseID, moduleID: moduleID, action: .set, oldFolder: "Old", newFolder: "New", lastKnownName: "Modulo", files: files)
        try await database.beginModuleMove(pending)
        try await fileStore.moveRegularFile(from: paths[0].1, to: paths[0].2, expected: try await presentSnapshot(fileStore, at: paths[0].1))
        try await fileStore.moveRegularFile(from: paths[2].1, to: paths[2].2, expected: try await presentSnapshot(fileStore, at: paths[2].1))
        try FileManager.default.removeItem(at: fixture.root.appending(path: paths[2].2.value))
        try Data("someone else".utf8).write(to: fixture.root.appending(path: paths[1].2.value))
        #expect(try await ModuleMoveRecovery.recover(pending, database: database, fileStore: fileStore) == false)

        try await ModuleMoveRecovery.abandon(pending, database: database, fileStore: fileStore)

        let baselines = try await database.baselines(rootID: rootID)
        #expect(baselines["moved"]?.relativePath == paths[0].2)
        #expect(baselines["stayed"]?.relativePath == paths[1].1)
        #expect(baselines["lost"] == nil)
        #expect(try await database.pendingModuleMoves(rootID: rootID).isEmpty)
        #expect(try await database.modulePathOverride(rootID: rootID, courseID: courseID, moduleID: moduleID)?.localFolder == "Old")
        #expect(try String(contentsOf: fixture.root.appending(path: paths[1].1.value), encoding: .utf8) == "stayed")
        #expect(try String(contentsOf: fixture.root.appending(path: paths[1].2.value), encoding: .utf8) == "someone else")
        #expect(try String(contentsOf: fixture.root.appending(path: paths[0].2.value), encoding: .utf8) == "moved")
    }

    private func makeFixture() throws -> (base: URL, root: URL) {
        let base = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let root = base.appending(path: "sync", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (base, root)
    }

    private func presentSnapshot(_ fileStore: FileStore, at path: RelativePath) async throws -> FileSnapshot {
        guard case .present(let snapshot) = try await fileStore.snapshotRegularFile(path) else { throw FileStoreError.ioFailure }
        return snapshot
    }

    private func move(rootID: UUID, courseID: Int64, moduleID: Int64, remoteID: String, oldPath: RelativePath, newPath: RelativePath, source: FileSnapshotState) -> PendingModuleMove {
        PendingModuleMove(
            rootID: rootID,
            courseID: courseID,
            moduleID: moduleID,
            action: .set,
            oldFolder: nil,
            newFolder: "Custom",
            lastKnownName: "Modulo",
            files: [PendingModuleMoveFile(remoteID: remoteID, oldPath: oldPath, newPath: newPath, source: source)]
        )
    }
}
