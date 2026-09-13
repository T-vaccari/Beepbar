import Foundation
import Testing
@testable import BeepbarCore

@Suite(.serialized) struct ManualSyncEngineIntegrationTests {
    @Test func preservesLocalEditWhenRemoteDidNotChange() async throws {
        let fixture = try await Fixture(remoteData: Data("base".utf8))
        defer { fixture.remove() }
        let engine = fixture.engine()
        #expect(try await engine.sync(file: fixture.file(revision: "1"), destination: fixture.path, token: "token") == .installed)

        try Data("local edit".utf8).write(to: fixture.destination)
        #expect(try await engine.sync(file: fixture.file(revision: "1"), destination: fixture.path, token: "token") == .preservedLocal)
        #expect(try Data(contentsOf: fixture.destination) == Data("local edit".utf8))
        #expect(try await fixture.database.baseline(rootID: fixture.rootID, remoteID: "file")?.remoteRevision == "1")
    }

    @Test func recordsOneConflictAndKeepsLocalWhenBothVersionsChange() async throws {
        let fixture = try await Fixture(remoteData: Data("base".utf8))
        defer { fixture.remove() }
        let engine = fixture.engine()
        #expect(try await engine.sync(file: fixture.file(revision: "1"), destination: fixture.path, token: "token") == .installed)
        try Data("local edit".utf8).write(to: fixture.destination)
        IntegrationDownloadProtocol.data = Data("remote edit".utf8)

        let result = try await engine.sync(file: fixture.file(revision: "2"), destination: fixture.path, token: "token")
        guard case .conflict = result else { Issue.record("expected conflict"); return }
        #expect(try Data(contentsOf: fixture.destination) == Data("local edit".utf8))
        #expect(try await fixture.database.conflicts(rootID: fixture.rootID).count == 1)
        #expect(try await engine.sync(file: fixture.file(revision: "2"), destination: fixture.path, token: "token") == .skipped("conflitto già aperto"))
        #expect(try await fixture.database.conflicts(rootID: fixture.rootID).count == 1)
    }

    @Test func leavesLocalAndBaselineUntouchedAfter404() async throws {
        let fixture = try await Fixture(remoteData: Data("base".utf8))
        defer { fixture.remove() }
        let engine = fixture.engine()
        #expect(try await engine.sync(file: fixture.file(revision: "1"), destination: fixture.path, token: "token") == .installed)
        IntegrationDownloadProtocol.status = 404
        IntegrationDownloadProtocol.data = Data()

        await #expect(throws: RemoteDownloadError.transport(404)) {
            try await engine.sync(file: fixture.file(revision: "2"), destination: fixture.path, token: "token")
        }
        #expect(try Data(contentsOf: fixture.destination) == Data("base".utf8))
        #expect(try await fixture.database.baseline(rootID: fixture.rootID, remoteID: "file")?.remoteRevision == "1")
    }

    @Test func reinstallsRemoteWhenTrackedLocalFileWasDeleted() async throws {
        let fixture = try await Fixture(remoteData: Data("base".utf8))
        defer { fixture.remove() }
        let engine = fixture.engine()
        #expect(try await engine.sync(file: fixture.file(revision: "1"), destination: fixture.path, token: "token") == .installed)
        try FileManager.default.removeItem(at: fixture.destination)
        IntegrationDownloadProtocol.data = Data("remote v2".utf8)

        #expect(try await engine.sync(file: fixture.file(revision: "2"), destination: fixture.path, token: "token") == .installed)
        #expect(try Data(contentsOf: fixture.destination) == Data("remote v2".utf8))
        #expect(try await fixture.database.baseline(rootID: fixture.rootID, remoteID: "file")?.remoteRevision == "2")
    }

    @Test func loadsBaselinesForOneRootInOneSnapshot() async throws {
        let fixture = try await Fixture(remoteData: Data("base".utf8))
        defer { fixture.remove() }
        let engine = fixture.engine()
        #expect(try await engine.sync(file: fixture.file(revision: "1"), destination: fixture.path, token: "token") == .installed)

        let values = try await fixture.database.baselines(rootID: fixture.rootID)
        #expect(values.count == 1)
        #expect(values["file"]?.remoteRevision == "1")
        #expect(values["file"]?.relativePath == fixture.path)
    }

    private final class Fixture {
        let root: URL
        let rootID = UUID()
        let database: SyncDatabase
        let store: FileStore
        let path = try! RelativePath("Course/material.txt")
        let destination: URL

        init(remoteData: Data) async throws {
            root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            database = try SyncDatabase(url: root.appending(path: "state.sqlite"))
            store = try FileStore(root: root)
            destination = root.appending(path: path.value)
            try await database.registerRoot(id: rootID, canonicalPath: root.path)
            IntegrationDownloadProtocol.status = 200
            IntegrationDownloadProtocol.data = remoteData
        }

        func engine() -> ManualSyncEngine {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [IntegrationDownloadProtocol.self]
            return ManualSyncEngine(rootID: rootID, database: database, fileStore: store, downloader: RemoteDownloader(session: URLSession(configuration: configuration)))
        }

        func file(revision: String) -> RemoteFileCandidate {
            RemoteFileCandidate(id: "file", courseID: 1, sectionID: 1, moduleID: 1, sectionName: "", moduleName: "", filename: "material.txt", remoteFilePath: "/", canonicalPluginPath: "/pluginfile.php/test", downloadURL: URL(string: "https://webeep.polimi.it/pluginfile.php/test")!, size: Int64(IntegrationDownloadProtocol.data.count), modifiedAt: nil, observedRevision: revision, isSupported: true)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}

private final class IntegrationDownloadProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var data = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: ["Content-Length": "\(Self.data.count)"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
