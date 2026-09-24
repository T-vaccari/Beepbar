import Foundation
import Testing
@testable import BeepbarCore

struct ModulePathMigratorTests {
    @Test func previewRejectsOccupiedDestinationForUntrackedFile() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let rootID = UUID()
        let courseID: Int64 = 42
        let moduleID: Int64 = 7
        let destination = try RelativePath("Course/Custom/notes.pdf")
        let destinationURL = fixture.root.appending(path: destination.value)
        try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("local untracked file".utf8).write(to: destinationURL)

        let database = try SyncDatabase(url: fixture.base.appending(path: "state.sqlite"))
        try await database.registerRoot(id: rootID, canonicalPath: fixture.root.path)
        let fileStore = try FileStore(root: fixture.root)
        let apiClient = WeBeepAPIClient(session: URLSession(configuration: .ephemeral))
        let migrator = ModulePathMigrator(rootID: rootID, database: database, fileStore: fileStore, gate: RootOperationGate(), apiClient: apiClient)
        let file = RemoteFileCandidate(
            id: "remote-untracked",
            courseID: courseID,
            sectionID: 3,
            moduleID: moduleID,
            sectionName: "Resources",
            moduleName: "Slides",
            filename: "notes.pdf",
            remoteFilePath: "/",
            canonicalPluginPath: "pluginfile.php/42/notes.pdf",
            downloadURL: nil,
            size: 10,
            modifiedAt: nil,
            observedRevision: "1",
            isSupported: true
        )
        let contents = RemoteCourseContents(
            sections: [RemoteContentSection(id: 3, name: "Resources", modules: [RemoteContentModule(id: moduleID, name: "Slides", files: [file])])],
            issueCount: 0
        )

        await #expect(throws: ModulePathMigrationError.destinationOccupied(destination.value)) {
            try await migrator.preview(courseID: courseID, moduleID: moduleID, courseFolder: "Course", action: .set, folder: "Custom", contents: contents)
        }
        #expect(try String(contentsOf: destinationURL, encoding: .utf8) == "local untracked file")
    }

    @Test func deletingUnavailableRuleWaitsForPendingSyncOperation() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let rootID = UUID()
        let courseID: Int64 = 42
        let moduleID: Int64 = 7
        let database = try SyncDatabase(url: fixture.base.appending(path: "state.sqlite"))
        try await database.registerRoot(id: rootID, canonicalPath: fixture.root.path)
        try await database.beginOperation(PendingOperation(
            rootID: rootID,
            remoteID: "pending",
            destination: try RelativePath("Course/pending.pdf"),
            stagePath: try RelativePath(internal: ".beepbar/staging/pending.partial"),
            expectedLocal: .missing,
            remoteSHA256: "sha",
            remoteRevision: "1"
        ))
        let fileStore = try FileStore(root: fixture.root)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RejectNetworkProtocol.self]
        let apiClient = WeBeepAPIClient(session: URLSession(configuration: configuration))
        let migrator = ModulePathMigrator(rootID: rootID, database: database, fileStore: fileStore, gate: RootOperationGate(), apiClient: apiClient)

        await #expect(throws: ModulePathMigrationError.pendingOperation) {
            try await migrator.deleteUnavailableRule(courseID: courseID, moduleID: moduleID, token: "token")
        }
        #expect(try await database.pendingOperations(rootID: rootID).count == 1)
    }

    private func makeFixture() throws -> (base: URL, root: URL) {
        let base = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let root = base.appending(path: "sync", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (base, root)
    }
}

private final class RejectNetworkProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}
