import Foundation
import Testing
@testable import BeepbarCore

@Suite(.serialized) struct RemoteDownloaderTests {
    @Test(arguments: [
        (URLError.Code.notConnectedToInternet, RemoteDownloadError.network(.offline)),
        (.timedOut, .network(.timedOut)),
        (.networkConnectionLost, .network(.connectionLost))
    ])
    func preservesNetworkFailure(_ code: URLError.Code, _ expected: RemoteDownloadError) async {
        DownloadFailureProtocol.code = code
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DownloadFailureProtocol.self]
        let downloader = RemoteDownloader(session: URLSession(configuration: configuration))
        let file = RemoteFileCandidate(
            id: "file", courseID: 1, sectionID: 1, moduleID: 1,
            sectionName: "", moduleName: "", filename: "file.txt", remoteFilePath: "/",
            canonicalPluginPath: "/pluginfile.php/file",
            downloadURL: URL(string: "https://webeep.polimi.it/pluginfile.php/file")!,
            size: 1, modifiedAt: nil, observedRevision: "1", isSupported: true
        )
        await #expect(throws: expected) { try await downloader.download(file, token: "token") }
    }

    @Test func removesTemporaryFileWhenResponseIsRejected() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DownloadRejectedProtocol.self]
        let downloader = RemoteDownloader(session: URLSession(configuration: configuration))
        let file = RemoteFileCandidate(
            id: "file", courseID: 1, sectionID: 1, moduleID: 1,
            sectionName: "", moduleName: "", filename: "file.txt", remoteFilePath: "/",
            canonicalPluginPath: "/pluginfile.php/file",
            downloadURL: URL(string: "https://webeep.polimi.it/pluginfile.php/file")!,
            size: 4, modifiedAt: nil, observedRevision: "1", isSupported: true
        )
        let before = Self.downloadTemporaryFiles()
        await #expect(throws: RemoteDownloadError.transport(404)) { try await downloader.download(file, token: "token") }
        #expect(Self.leakedDownloadTemporaries(since: before, body: DownloadRejectedProtocol.body).isEmpty)
    }

    // URLSession stages every download in the process temporary directory, which the rest of the
    // suite uses at the same time: only a file holding this test's body is our leak.
    private static func leakedDownloadTemporaries(since before: Set<String>, body: Data) -> [String] {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return downloadTemporaryFiles().subtracting(before).filter {
            (try? Data(contentsOf: directory.appending(path: $0))) == body
        }
    }

    private static func downloadTemporaryFiles() -> Set<String> {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory())) ?? []
        return Set(entries.filter { $0.hasPrefix("CFNetworkDownload") })
    }
}

private final class DownloadRejectedProtocol: URLProtocol, @unchecked Sendable {
    static let body = Data("rejected-body-\(UUID().uuidString)".utf8)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class DownloadFailureProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var code = URLError.Code.notConnectedToInternet
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(Self.code)) }
    override func stopLoading() {}
}
