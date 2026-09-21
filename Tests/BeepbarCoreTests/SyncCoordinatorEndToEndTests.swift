import Foundation
import Testing
@testable import BeepbarCore

@Suite(.serialized) struct SyncCoordinatorEndToEndTests {
    @Test func installsThousandFilesAndSecondRunDoesNotDownloadAgain() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }

        let first = try await fixture.synchronize()
        #expect(first.total == 1_000)
        #expect(first.installed == 1_000)
        #expect(first.added == 1_000)
        #expect(first.updated == 0)
        #expect(fixture.upstream.downloadCount == 1_000)
        #expect(fixture.upstream.maximumActiveDownloads <= 3)

        fixture.upstream.resetDownloadCount()
        let second = try await fixture.synchronize()
        #expect(second.added == 0)
        #expect(second.updated == 0)
        #expect(second.total == 0)
        #expect(fixture.upstream.downloadCount == 0)
    }

    @Test func distinguishesNewDownloadsFromRemoteUpdates() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let target = fixture.targets[0]

        let first = try await fixture.synchronize(targets: [target])
        #expect(first.added == 100)
        #expect(first.updated == 0)

        fixture.upstream.setFile(course: 1, file: 0, value: "remote update", revision: "2")
        let second = try await fixture.synchronize(targets: [target])
        #expect(second.added == 0)
        #expect(second.updated == 1)
    }

    @Test func aggregatesAddedAndUpdatedCountsPerCourse() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let courseA = fixture.targets[0]
        let courseB = fixture.targets[1]

        let first = try await fixture.synchronize(targets: [courseA, courseB])
        #expect(first.perCourse.count == 2)
        let firstA = try #require(first.perCourse.first { $0.courseID == courseA.courseID })
        let firstB = try #require(first.perCourse.first { $0.courseID == courseB.courseID })
        #expect(firstA.added == 100 && firstA.updated == 0)
        #expect(firstB.added == 100 && firstB.updated == 0)
        #expect(firstA.courseFolder == courseA.localFolder)

        fixture.upstream.setFile(course: courseA.courseID, file: 0, value: "remote update", revision: "2")
        let second = try await fixture.synchronize(targets: [courseA, courseB])
        #expect(second.perCourse.count == 1)
        let secondA = try #require(second.perCourse.first)
        #expect(secondA.courseID == courseA.courseID)
        #expect(secondA.added == 0 && secondA.updated == 1)
    }

    @Test func resolvesBothConflictChoicesWithoutReopeningTheConflict() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        _ = try await fixture.synchronize(targets: [fixture.targets[0]])

        let firstID = fixture.remoteID(course: 1, file: 0)
        let firstBaseline = try #require(await fixture.database.baseline(rootID: fixture.rootID, remoteID: firstID))
        try Data("local".utf8).write(to: fixture.root.appending(path: firstBaseline.relativePath.value))
        fixture.upstream.setFile(course: 1, file: 0, value: "remote", revision: "2")

        let conflictProgress = try await fixture.synchronize(targets: [fixture.targets[0]])
        #expect(conflictProgress.conflicts == 1)
        let firstConflict = try #require(await fixture.database.conflicts(rootID: fixture.rootID).first)
        try await ConflictResolver(database: fixture.database, fileStore: try FileStore(root: fixture.root), gate: fixture.gate).keepLocal(id: firstConflict.id)
        #expect(try await fixture.synchronize(targets: [fixture.targets[0]]).conflicts == 0)
        #expect(try await fixture.database.conflicts(rootID: fixture.rootID).isEmpty)
        #expect(try Data(contentsOf: fixture.root.appending(path: firstBaseline.relativePath.value)) == Data("local".utf8))

        let secondID = fixture.remoteID(course: 1, file: 1)
        let secondBaseline = try #require(await fixture.database.baseline(rootID: fixture.rootID, remoteID: secondID))
        try Data("local-second".utf8).write(to: fixture.root.appending(path: secondBaseline.relativePath.value))
        fixture.upstream.setFile(course: 1, file: 1, value: "remote-second", revision: "2")
        #expect(try await fixture.synchronize(targets: [fixture.targets[0]]).conflicts == 1)
        let secondConflict = try #require(await fixture.database.conflicts(rootID: fixture.rootID).first)
        _ = try await ConflictResolver(database: fixture.database, fileStore: try FileStore(root: fixture.root), gate: fixture.gate).useRemote(id: secondConflict.id)
        #expect(try Data(contentsOf: fixture.root.appending(path: secondBaseline.relativePath.value)) == Data("remote-second".utf8))
        #expect(try await fixture.database.conflicts(rootID: fixture.rootID).isEmpty)
    }

    @Test func keepsFileAndBaselineOn404AndReinstallsDeletedFile() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        _ = try await fixture.synchronize(targets: [fixture.targets[0]])
        let remoteID = fixture.remoteID(course: 1, file: 0)
        let baseline = try #require(await fixture.database.baseline(rootID: fixture.rootID, remoteID: remoteID))
        let destination = fixture.root.appending(path: baseline.relativePath.value)
        let original = try Data(contentsOf: destination)

        fixture.upstream.setFile(course: 1, file: 0, value: "changed", revision: "2")
        fixture.upstream.setStatus(course: 1, file: 0, status: 404)
        let failed = try await fixture.synchronize(targets: [fixture.targets[0]])
        #expect(failed.failures == 1)
        #expect(try Data(contentsOf: destination) == original)
        #expect(try await fixture.database.baseline(rootID: fixture.rootID, remoteID: remoteID) == baseline)

        fixture.upstream.setStatus(course: 1, file: 0, status: 200)
        try FileManager.default.removeItem(at: destination)
        let restored = try await fixture.synchronize(targets: [fixture.targets[0]])
        #expect(restored.installed == 1)
        #expect(restored.added == 1)
        #expect(try Data(contentsOf: destination) == Data("changed".utf8))
    }

    @Test func propagatesServerFailureDuringDownload() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        fixture.upstream.setStatus(course: 1, file: 0, status: 503)

        await #expect(throws: WeBeepAPIError.transport(503)) {
            try await fixture.synchronize(targets: [fixture.targets[0]])
        }
    }

    @Test(arguments: [401, 403])
    func validatesTokenOnceBeforeClassifyingDownloadAuthorizationFailure(_ status: Int) async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        fixture.upstream.setStatus(course: 1, file: 0, status: status)

        await #expect(throws: WeBeepAPIError.transport(status)) {
            try await fixture.synchronize(targets: [fixture.targets[0]])
        }
        #expect(fixture.upstream.validationCount == 1)
    }

    @Test func reportsExpiredTokenAfterDownloadAuthorizationFailure() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        fixture.upstream.setStatus(course: 1, file: 0, status: 401)
        fixture.upstream.tokenIsValid = false

        await #expect(throws: WeBeepAPIError.invalidToken) {
            try await fixture.synchronize(targets: [fixture.targets[0]])
        }
        #expect(fixture.upstream.validationCount == 1)
    }

    @Test func recreatesDeletedCourseDirectoryAndReinstallsFiles() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let target = fixture.targets[0]
        _ = try await fixture.synchronize(targets: [target])
        let baseline = try #require(await fixture.database.baseline(rootID: fixture.rootID, remoteID: fixture.remoteID(course: 1, file: 0)))

        try FileManager.default.removeItem(at: fixture.root.appending(path: target.localFolder))
        let restored = try await fixture.synchronize(targets: [target])

        #expect(restored.installed == 100)
        #expect(FileManager.default.fileExists(atPath: fixture.root.appending(path: baseline.relativePath.value).path))
    }

    @Test func missingBaselineFileKeepsItsTrackedDestination() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let remoteID = fixture.remoteID(course: 1, file: 0)
        let destination = try RelativePath("Course 1/original.txt")
        try await fixture.database.upsertBaseline(rootID: fixture.rootID, baseline: Baseline(
            remoteID: remoteID,
            relativePath: destination,
            sha256: String(repeating: "0", count: 64),
            remoteRevision: "0"
        ))

        let result = try await fixture.synchronize(targets: [fixture.targets[0]])
        let baseline = try #require(await fixture.database.baseline(rootID: fixture.rootID, remoteID: remoteID))

        #expect(result.installed == 100)
        #expect(baseline.relativePath == destination)
        #expect(FileManager.default.fileExists(atPath: fixture.root.appending(path: destination.value).path))
    }

    @Test func ghostBaselineWithNoLocalFileDoesNotStealAFreshFilesName() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let ghostDestination = try RelativePath("Course 1/Lezioni/0.txt")
        try await fixture.database.upsertBaseline(rootID: fixture.rootID, baseline: Baseline(
            remoteID: "1:100:/webservice/pluginfile.php/1/ghost.txt",
            relativePath: ghostDestination,
            sha256: String(repeating: "0", count: 64),
            remoteRevision: "0"
        ))

        let result = try await fixture.synchronize(targets: [fixture.targets[0]])

        #expect(result.installed == 100)
        #expect(FileManager.default.fileExists(atPath: fixture.root.appending(path: ghostDestination.value).path))
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: "Course 1/Lezioni/0 (1).txt").path))
    }

    @Test func secondRunWithNothingChangedDoesNotHashAnyFile() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        _ = try await fixture.synchronize()
        let hashesAfterFirstRun = await fixture.coordinator.fileStore.hashCount
        #expect(hashesAfterFirstRun > 0)

        let second = try await fixture.synchronize()

        #expect(second.total == 0)
        #expect(await fixture.coordinator.fileStore.hashCount == hashesAfterFirstRun)
    }

    @Test func syncedPathReplacedByDirectoryDoesNotAbortTheRun() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let target = fixture.targets[0]
        _ = try await fixture.synchronize(targets: [target])
        let remoteID = fixture.remoteID(course: 1, file: 0)
        let baseline = try #require(await fixture.database.baseline(rootID: fixture.rootID, remoteID: remoteID))
        let destination = fixture.root.appending(path: baseline.relativePath.value)
        try FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        fixture.upstream.setFile(course: 1, file: 1, value: "remote update", revision: "2")

        let result = try await fixture.synchronize(targets: [target])

        #expect(result.total == 2)
        #expect(result.updated == 1)
        #expect(result.failures == 1)
        #expect(try destination.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
        #expect(try await fixture.database.baseline(rootID: fixture.rootID, remoteID: remoteID) == baseline)
    }

    @Test func deletedLocalFileKeepsItsNameReservedForItsOwnRemoteItem() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let target = fixture.targets[0]
        _ = try await fixture.synchronize(targets: [target])
        let baseline = try #require(await fixture.database.baseline(rootID: fixture.rootID, remoteID: fixture.remoteID(course: 1, file: 0)))
        let destination = fixture.root.appending(path: baseline.relativePath.value)
        try FileManager.default.removeItem(at: destination)
        fixture.upstream.addFile(course: 1, file: 100, filename: "0.txt", value: "newcomer", revision: "1")

        let result = try await fixture.synchronize(targets: [target])
        let newcomer = try #require(await fixture.database.baseline(rootID: fixture.rootID, remoteID: fixture.remoteID(course: 1, file: 100)))

        #expect(result.added == 2)
        #expect(result.failures == 0)
        #expect(try newcomer.relativePath == RelativePath("Course 1/Lezioni/0 (1).txt"))
        #expect(try Data(contentsOf: destination) == Data("x".utf8))
        #expect(try Data(contentsOf: fixture.root.appending(path: newcomer.relativePath.value)) == Data("newcomer".utf8))
    }

    @Test func changedLocalAndRemoteFileConflictsAtTrackedLegacyDestination() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        _ = try await fixture.synchronize(targets: [fixture.targets[0]])
        let remoteID = fixture.remoteID(course: 1, file: 0)
        let baseline = try #require(await fixture.database.baseline(rootID: fixture.rootID, remoteID: remoteID))
        let legacyPath = try RelativePath("Course 1/legacy/0.txt")
        let legacyURL = fixture.root.appending(path: legacyPath.value)
        try FileManager.default.createDirectory(at: legacyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("local edit".utf8).write(to: legacyURL)
        try await fixture.database.upsertBaseline(rootID: fixture.rootID, baseline: Baseline(
            remoteID: remoteID,
            relativePath: legacyPath,
            sha256: baseline.sha256,
            remoteRevision: baseline.remoteRevision
        ))
        fixture.upstream.setFile(course: 1, file: 0, value: "remote edit", revision: "2")

        let result = try await fixture.synchronize(targets: [fixture.targets[0]])
        let conflict = try #require(await fixture.database.conflicts(rootID: fixture.rootID).first)

        #expect(result.conflicts == 1)
        #expect(conflict.relativePath == legacyPath)
        #expect(try Data(contentsOf: legacyURL) == Data("local edit".utf8))
        #expect(try await fixture.database.baseline(rootID: fixture.rootID, remoteID: remoteID)?.relativePath == legacyPath)
    }

    @Test func duplicateTrackedDestinationsFailBeforeDownloading() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let sharedPath = try RelativePath("Course 1/shared.txt")
        for file in 0...1 {
            try await fixture.database.upsertBaseline(rootID: fixture.rootID, baseline: Baseline(
                remoteID: fixture.remoteID(course: 1, file: file),
                relativePath: sharedPath,
                sha256: String(repeating: "0", count: 64),
                remoteRevision: "0"
            ))
        }

        await #expect(throws: SyncDatabaseError.execution) {
            try await fixture.synchronize(targets: [fixture.targets[0]])
        }
        #expect(fixture.upstream.downloadCount == 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: sharedPath.value).path))
    }

    @Test func cancellationLeavesNoBaselineOrStagingArtifacts() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        fixture.upstream.setFile(course: 1, file: 0, value: String(repeating: "x", count: 65_536), revision: "2")
        fixture.upstream.downloadDelay = 1
        let task = Task { try await fixture.synchronize(targets: [fixture.targets[0]]) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await fixture.database.baselines(rootID: fixture.rootID).isEmpty)
        #expect(fixture.stagingFiles().isEmpty)
    }

    @Test func downloadConcurrencyIsBoundedAndProgressIsMonotonic() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        fixture.upstream.downloadDelay = 0.01
        let recorder = ProgressRecorder()
        _ = try await fixture.coordinator.synchronize(targets: [fixture.targets[0]], token: "test-token", mode: .manual) { update in recorder.append(update) }
        let progress = recorder.values
        #expect(fixture.upstream.maximumActiveDownloads == 3)
        #expect(progress.count == 100)
        #expect(progress.enumerated().allSatisfy { $0.element.completed == $0.offset + 1 })
        #expect(progress.last?.completed == progress.last?.total)
    }

    @Test func cancellationDuringStagingPreservesExistingFileAndBaseline() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        _ = try await fixture.synchronize(targets: [fixture.targets[0]])
        let remoteID = fixture.remoteID(course: 1, file: 0)
        let baseline = try #require(await fixture.database.baseline(rootID: fixture.rootID, remoteID: remoteID))
        let destination = fixture.root.appending(path: baseline.relativePath.value)
        let original = try Data(contentsOf: destination)
        fixture.upstream.setFile(course: 1, file: 0, value: String(repeating: "x", count: 67_108_864), revision: "2")
        fixture.upstream.downloadDelay = 0.01

        let task = Task { try await fixture.synchronize(targets: [fixture.targets[0]]) }
        var stageCreated = false
        for _ in 0..<2_000 {
            if !fixture.stagingFiles().isEmpty {
                stageCreated = true
                task.cancel()
                break
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(stageCreated)
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try Data(contentsOf: destination) == original)
        #expect(try await fixture.database.baseline(rootID: fixture.rootID, remoteID: remoteID) == baseline)
        #expect(fixture.stagingFiles().isEmpty)
    }

    @Test func missingRootAndConcurrentRunsDoNotMutateState() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        fixture.upstream.downloadDelay = 1
        let first = Task { try await fixture.synchronize(targets: [fixture.targets[0]]) }
        try await Task.sleep(for: .milliseconds(100))
        await #expect(throws: RootOperationGateError.self) { try await fixture.synchronize(targets: [fixture.targets[0]], mode: .automatic) }
        first.cancel()
        _ = try? await first.value

        try FileManager.default.removeItem(at: fixture.root)
        await #expect(throws: FileStoreError.self) { try await fixture.synchronize(targets: [fixture.targets[0]]) }
        #expect(!FileManager.default.fileExists(atPath: fixture.root.path))
    }

    @Test func automaticSyncDownloadsWithoutExpensiveOrConstrainedNetworkAccess() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        _ = try await fixture.synchronize(targets: [fixture.targets[0]], mode: .automatic)
        #expect(fixture.upstream.downloadCount > 0)
        // A scheduled run must not spend a metered hotspot, nor ignore Low Data Mode.
        #expect(fixture.upstream.downloadNetworkAccess == [RecordedNetworkAccess(expensive: false, constrained: false)])
    }

    @Test func manualSyncDownloadsOverAnyNetwork() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        _ = try await fixture.synchronize(targets: [fixture.targets[0]], mode: .manual)
        #expect(fixture.upstream.downloadCount > 0)
        #expect(fixture.upstream.downloadNetworkAccess == [RecordedNetworkAccess(expensive: true, constrained: true)])
    }

private final class Fixture: @unchecked Sendable {
        let root: URL
        // The real app keeps the database in Application Support, outside the sync folder, so a
        // deleted sync folder must leave it intact. Keep the fixture's layout the same.
        let supportDirectory: URL
        let rootID = UUID()
        let database: SyncDatabase
        let upstream = MutableFixtureUpstream()
        let policy = WeBeepServerPolicy(endpoint: URL(string: "https://fixture.beepbar.test/webservice/rest/server.php")!, siteURL: URL(string: "https://fixture.beepbar.test")!, scheme: "https", host: "fixture.beepbar.test", port: 443)
        let gate = RootOperationGate()
        let targets = (1...10).map { SyncTarget(courseID: Int64($0), localFolder: "Course \($0)") }
        let coordinator: SyncCoordinator

        init() async throws {
            let container = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
            root = container.appending(path: "Sync", directoryHint: .isDirectory)
            supportDirectory = container.appending(path: "Support", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
            database = try SyncDatabase(url: supportDirectory.appending(path: "state.sqlite"))
            FixtureURLProtocol.upstream = upstream
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [FixtureURLProtocol.self]
            let session = URLSession(configuration: configuration)
            let client = WeBeepAPIClient(policy: policy, session: session)
            let downloader = RemoteDownloader(session: session, policy: policy)
            coordinator = try SyncCoordinator(rootID: rootID, rootURL: root, database: database, gate: gate, apiClient: client, downloader: downloader)
            try await database.registerRoot(id: rootID, canonicalPath: root.path)
            for target in targets {
                try await database.upsertScope(SyncScope(rootID: rootID, courseID: target.courseID, displayName: target.localFolder, localFolder: target.localFolder, enabled: true))
            }
            upstream.populate(courses: 10, filesPerCourse: 100)
        }

        func synchronize(targets: [SyncTarget]? = nil, mode: SyncCoordinatorMode = .manual) async throws -> SyncProgress {
            try await coordinator.synchronize(targets: targets ?? self.targets, token: "test-token", mode: mode) { _ in }
        }

        func remoteID(course: Int64, file: Int) -> String { "\(course):\(course * 100):/webservice/pluginfile.php/\(course)/\(file).txt" }

        func stagingFiles() -> [URL] {
            let staging = root.appending(path: ".beepbar/staging", directoryHint: .isDirectory)
            return (try? FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)) ?? []
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: supportDirectory)
        }
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [SyncProgress] = []

    func append(_ update: SyncProgress) { lock.withLock { storage.append(update) } }
    var values: [SyncProgress] { lock.withLock { storage } }
}

private struct RecordedNetworkAccess: Hashable {
    let expensive: Bool
    let constrained: Bool
}

private final class MutableFixtureUpstream: @unchecked Sendable {
    private struct File { var value: Data; var revision: String; var status = 200; var filename: String? = nil }
    private let lock = NSLock()
    private var files: [Int64: [Int: File]] = [:]
    private var downloads = 0
    private var activeDownloads = 0
    private var peakDownloads = 0
    private var validations = 0
    private var networkAccess: Set<RecordedNetworkAccess> = []
    var downloadDelay: TimeInterval = 0
    var tokenIsValid = true

    var downloadCount: Int { lock.withLock { downloads } }
    var maximumActiveDownloads: Int { lock.withLock { peakDownloads } }
    var validationCount: Int { lock.withLock { validations } }
    var downloadNetworkAccess: Set<RecordedNetworkAccess> { lock.withLock { networkAccess } }
    func resetDownloadCount() { lock.withLock { downloads = 0 } }

    func populate(courses: Int, filesPerCourse: Int) {
        lock.withLock {
            files = Dictionary(uniqueKeysWithValues: (1...courses).map { course in
                (Int64(course), Dictionary(uniqueKeysWithValues: (0..<filesPerCourse).map { index in (index, File(value: Data("x".utf8), revision: "1")) }))
            })
        }
    }

    func setFile(course: Int64, file: Int, value: String, revision: String) {
        lock.withLock {
            let status = files[course]?[file]?.status ?? 200
            files[course]?[file] = File(value: Data(value.utf8), revision: revision, status: status)
        }
    }
    func setStatus(course: Int64, file: Int, status: Int) { lock.withLock { guard var value = files[course]?[file] else { return }; value.status = status; files[course]?[file] = value } }
    func addFile(course: Int64, file: Int, filename: String, value: String, revision: String) {
        lock.withLock { files[course, default: [:]][file] = File(value: Data(value.utf8), revision: revision, filename: filename) }
    }

    func response(for request: URLRequest) -> (HTTPURLResponse, Data, TimeInterval, Bool) {
        lock.withLock {
            let url = request.url!
            if request.httpMethod == "POST" {
                let body = String(data: request.httpBody ?? bodyData(from: request.httpBodyStream), encoding: .utf8) ?? ""
                if formValue("wsfunction", body: body) == "core_webservice_get_site_info" {
                    validations += 1
                    let response: Data
                    if tokenIsValid {
                        response = Data(#"{"userid":7,"siteurl":"https://fixture.beepbar.test","functions":[{"name":"core_enrol_get_users_courses"},{"name":"core_course_get_contents"}]}"#.utf8)
                    } else {
                        response = Data(#"{"exception":"invalidtoken","errorcode":"invalidtoken"}"#.utf8)
                    }
                    return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, response, 0, false)
                }
                let course = Int64(formValue("courseid", body: body) ?? "") ?? 0
                let response = contents(course: course)
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, response, 0, false)
            }
            let parts = url.path.split(separator: "/")
            guard parts.count >= 4, let course = Int64(parts[2]), let index = Int(parts[3].split(separator: ".")[0]), let file = files[course]?[index] else {
                return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: ["Content-Length": "0"])!, Data(), 0, true)
            }
            downloads += 1
            networkAccess.insert(RecordedNetworkAccess(expensive: request.allowsExpensiveNetworkAccess, constrained: request.allowsConstrainedNetworkAccess))
            activeDownloads += 1
            peakDownloads = max(peakDownloads, activeDownloads)
            return (HTTPURLResponse(url: url, statusCode: file.status, httpVersion: nil, headerFields: ["Content-Length": "\(file.value.count)"])!, file.value, downloadDelay, true)
        }
    }

    func finishDownload() { lock.withLock { activeDownloads = max(0, activeDownloads - 1) } }

    private func contents(course: Int64) -> Data {
        let values = files[course] ?? [:]
        let contents: [[String: Any]] = values.keys.sorted().compactMap { index in
            guard let file = values[index] else { return nil }
            let contentHash = String(repeating: file.revision == "1" ? "a" : "b", count: 40)
            return ["type": "file", "filename": file.filename ?? "\(index).txt", "filepath": "/", "filesize": file.value.count, "timemodified": 1, "contenthash": contentHash, "fileurl": "https://fixture.beepbar.test/webservice/pluginfile.php/\(course)/\(index).txt"]
        }
        return try! JSONSerialization.data(withJSONObject: [["id": course, "name": "Materiali", "modules": [["id": course * 100, "name": "Lezioni", "modname": "folder", "contents": contents]]]])
    }

    private func formValue(_ name: String, body: String) -> String? {
        body.split(separator: "&").first { $0.hasPrefix("\(name)=") }.flatMap { String($0.dropFirst(name.count + 1)).removingPercentEncoding }
    }

    private func bodyData(from stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            result.append(buffer, count: count)
        }
        return result
    }
}

private final class FixtureURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var upstream: MutableFixtureUpstream!
    private var workItem: DispatchWorkItem?
    private let completionLock = NSLock()
    private var isDownload = false
    private var downloadFinished = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (response, data, delay, isDownload) = Self.upstream.response(for: request)
        self.isDownload = isDownload
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if delay > 0, !data.isEmpty {
                let split = max(1, data.count / 2)
                self.client?.urlProtocol(self, didLoad: data.prefix(split))
                DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self else { return }
                    guard self.workItem?.isCancelled != true else { self.finishDownloadIfNeeded(); return }
                    self.client?.urlProtocol(self, didLoad: data.dropFirst(split))
                    self.client?.urlProtocolDidFinishLoading(self)
                    self.finishDownloadIfNeeded()
                }
                return
            }
            if !data.isEmpty { self.client?.urlProtocol(self, didLoad: data) }
            self.client?.urlProtocolDidFinishLoading(self)
            self.finishDownloadIfNeeded()
        }
        workItem = item
        item.perform()
    }

    override func stopLoading() {
        workItem?.cancel()
        finishDownloadIfNeeded()
    }

    private func finishDownloadIfNeeded() {
        completionLock.withLock {
            guard isDownload, !downloadFinished else { return }
            downloadFinished = true
            Self.upstream.finishDownload()
        }
    }
}
