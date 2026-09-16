import CryptoKit
import Darwin
import Foundation
import Testing
@testable import BeepbarCore

struct FileStoreTests {
    @Test func hidesInternalBookkeepingDirectoryFromFinder() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FileStore(root: root)
        _ = try await store.createStage()

        var info = stat()
        let path = root.appending(path: ".beepbar").path
        #expect(stat(path, &info) == 0)
        #expect(info.st_flags & UInt32(UF_HIDDEN) != 0)
    }

    @Test func installsOnlyWhenDestinationIsStillMissing() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FileStore(root: root)
        let path = try RelativePath("Course/notes.txt")
        let stage = try await store.createStage()
        try await store.write(Data("remote".utf8), to: stage)
        let artifact = try await store.finalize(stage)

        #expect(try await store.install(artifact, at: path, expectedLocal: .missing) == .installedNew)
        #expect(try String(contentsOf: root.appending(path: path.value), encoding: .utf8) == "remote")
    }

    @Test func preservesConcurrentLocalReplacement() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appending(path: "Course/notes.txt")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("base".utf8).write(to: destination)
        let store = try FileStore(root: root)
        let path = try RelativePath("Course/notes.txt")
        let stage = try await store.createStage()
        try await store.write(Data("remote".utf8), to: stage)
        let artifact = try await store.finalize(stage)
        try Data("local".utf8).write(to: destination)

        #expect(try await store.install(artifact, at: path, expectedLocal: .present(sha256: SHA256Digest.hash("base"))) == .localChanged)
        #expect(try String(contentsOf: destination, encoding: .utf8) == "local")
    }

    @Test func rejectsAnExistingFileWhenTheExpectedLocalStateIsMissing() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appending(path: "Course/notes.txt")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("local".utf8).write(to: destination)
        let store = try FileStore(root: root)
        let stage = try await store.createStage()
        try await store.write(Data("remote".utf8), to: stage)
        let artifact = try await store.finalize(stage)

        #expect(try await store.install(artifact, at: RelativePath("Course/notes.txt"), expectedLocal: .missing) == .localChanged)
        #expect(try String(contentsOf: destination, encoding: .utf8) == "local")
    }

    @Test func detectsRegularFilesWithoutReadingTheirContents() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FileStore(root: root)
        let path = try RelativePath("Course/material.txt")
        #expect(try await store.containsRegularFile(path) == false)

        let destination = root.appending(path: path.value)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("local".utf8).write(to: destination)
        #expect(try await store.containsRegularFile(path))
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

private enum SHA256Digest {
    static func hash(_ value: String) -> String {
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
