import Foundation

public enum RemoteDownloadError: Error, Sendable, Equatable {
    case unsafeURL
    case unexpectedRedirect
    case transport(Int)
    case network(NetworkFailure)
    case invalidResponse
    case tooLarge
}

/// Which networks a download may use. Set per request, not per session, so one shared downloader
/// can still hold a scheduled run to the same limits its own session used to impose.
public struct NetworkAccess: Sendable, Equatable {
    public let allowsExpensiveNetworkAccess: Bool
    public let allowsConstrainedNetworkAccess: Bool

    public init(allowsExpensiveNetworkAccess: Bool, allowsConstrainedNetworkAccess: Bool) {
        self.allowsExpensiveNetworkAccess = allowsExpensiveNetworkAccess
        self.allowsConstrainedNetworkAccess = allowsConstrainedNetworkAccess
    }

    /// The user asked for this run and is watching it: any network will do.
    public static let unrestricted = NetworkAccess(allowsExpensiveNetworkAccess: true, allowsConstrainedNetworkAccess: true)
    /// Nobody asked for this run right now: never spend a metered hotspot and honour Low Data Mode.
    public static let background = NetworkAccess(allowsExpensiveNetworkAccess: false, allowsConstrainedNetworkAccess: false)
}

public struct DownloadedRemoteFile: Sendable {
    public let temporaryURL: URL
    public let expectedSize: Int64
}

public final class RemoteDownloader: @unchecked Sendable {
    private let session: URLSession
    private let maximumSize: Int64
    private let policy: WeBeepServerPolicy
    private let ownsSession: Bool

    public init(maximumSize: Int64 = 1_073_741_824, maximumConnections: Int = 3, policy: WeBeepServerPolicy = .production) {
        self.maximumSize = maximumSize
        self.policy = policy
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        configuration.httpMaximumConnectionsPerHost = maximumConnections
        session = URLSession(configuration: configuration, delegate: DownloadRejectRedirects(), delegateQueue: nil)
        ownsSession = true
    }

    public init(session: URLSession, maximumSize: Int64 = 1_073_741_824, policy: WeBeepServerPolicy = .production) {
        self.session = session
        self.maximumSize = maximumSize
        self.policy = policy
        ownsSession = false
    }

    deinit {
        // A session started here retains its delegate until it is invalidated, so a downloader that
        // is simply dropped would leak the session, its delegate and its connections.
        if ownsSession { session.finishTasksAndInvalidate() }
    }

    public func download(_ file: RemoteFileCandidate, token: String, access: NetworkAccess) async throws -> DownloadedRemoteFile {
        guard file.isSupported, let url = file.downloadURL, file.size >= 0, file.size <= maximumSize else { throw RemoteDownloadError.tooLarge }
        var request = try Self.request(url: url, token: token, policy: policy)
        request.allowsExpensiveNetworkAccess = access.allowsExpensiveNetworkAccess
        request.allowsConstrainedNetworkAccess = access.allowsConstrainedNetworkAccess
        let temporaryURL: URL
        let response: URLResponse
        do { (temporaryURL, response) = try await session.download(for: request) }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch let error as URLError where error.code == .badServerResponse { throw RemoteDownloadError.unexpectedRedirect }
        catch let error as URLError { throw RemoteDownloadError.network(NetworkFailure(error.code)) }
        catch { throw RemoteDownloadError.invalidResponse }
        // Every rejection below happens with the body already on disk: drop it, or a refused
        // download stays in the temporary directory until the next reboot.
        func reject(_ error: RemoteDownloadError) -> RemoteDownloadError {
            try? FileManager.default.removeItem(at: temporaryURL)
            return error
        }
        guard let http = response as? HTTPURLResponse else { throw reject(.invalidResponse) }
        guard http.statusCode == 200 else { throw reject(.transport(http.statusCode)) }
        guard let finalURL = http.url, Self.matchesAuthorizedURL(finalURL, requestURL: request.url!) else { throw reject(.unexpectedRedirect) }
        let length = http.expectedContentLength
        if length >= 0, length != file.size { throw reject(.invalidResponse) }
        return DownloadedRemoteFile(temporaryURL: temporaryURL, expectedSize: file.size)
    }

    public static func request(url: URL, token: String) throws -> URLRequest {
        try request(url: url, token: token, policy: .production)
    }

    public static func request(url: URL, token: String, policy: WeBeepServerPolicy) throws -> URLRequest {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false), policy.acceptsPluginURL(url) else {
            throw RemoteDownloadError.unsafeURL
        }
        guard !(components.queryItems ?? []).contains(where: { $0.name.caseInsensitiveCompare("token") == .orderedSame || $0.name.caseInsensitiveCompare("wstoken") == .orderedSame }) else {
            throw RemoteDownloadError.unsafeURL
        }
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "token", value: token)]
        guard let requestURL = components.url else { throw RemoteDownloadError.unsafeURL }
        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        return request
    }

    private static func matchesAuthorizedURL(_ finalURL: URL, requestURL: URL) -> Bool {
        guard let final = URLComponents(url: finalURL, resolvingAgainstBaseURL: false), let request = URLComponents(url: requestURL, resolvingAgainstBaseURL: false) else { return false }
        return final.scheme == request.scheme && final.host?.lowercased() == request.host?.lowercased() && final.port == request.port && final.percentEncodedPath == request.percentEncodedPath && final.percentEncodedQuery == request.percentEncodedQuery
    }
}

private final class DownloadRejectRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
