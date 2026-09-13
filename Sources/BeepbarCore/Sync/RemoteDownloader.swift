import Foundation

public enum RemoteDownloadError: Error, Sendable, Equatable {
    case unsafeURL
    case unexpectedRedirect
    case cancelled
    case transport(Int)
    case invalidResponse
    case tooLarge
}

public struct DownloadedRemoteFile: Sendable {
    public let temporaryURL: URL
    public let expectedSize: Int64
}

public final class RemoteDownloader: @unchecked Sendable {
    private let session: URLSession
    private let maximumSize: Int64
    private let policy: WeBeepServerPolicy

    public init(maximumSize: Int64 = 1_073_741_824, maximumConnections: Int = 3, allowsExpensiveNetworkAccess: Bool = true, policy: WeBeepServerPolicy = .production) {
        self.maximumSize = maximumSize
        self.policy = policy
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        configuration.httpMaximumConnectionsPerHost = maximumConnections
        configuration.allowsExpensiveNetworkAccess = allowsExpensiveNetworkAccess
        configuration.allowsConstrainedNetworkAccess = allowsExpensiveNetworkAccess
        session = URLSession(configuration: configuration, delegate: DownloadRejectRedirects(), delegateQueue: nil)
    }

    public init(session: URLSession, maximumSize: Int64 = 1_073_741_824, policy: WeBeepServerPolicy = .production) {
        self.session = session
        self.maximumSize = maximumSize
        self.policy = policy
    }

    public func download(_ file: RemoteFileCandidate, token: String) async throws -> DownloadedRemoteFile {
        guard file.isSupported, let url = file.downloadURL, file.size >= 0, file.size <= maximumSize else { throw RemoteDownloadError.tooLarge }
        let request = try Self.request(url: url, token: token, policy: policy)
        let temporaryURL: URL
        let response: URLResponse
        do { (temporaryURL, response) = try await session.download(for: request) }
        catch let error as URLError where error.code == .cancelled { throw RemoteDownloadError.cancelled }
        catch let error as URLError where error.code == .badServerResponse { throw RemoteDownloadError.unexpectedRedirect }
        catch { throw RemoteDownloadError.invalidResponse }
        guard let http = response as? HTTPURLResponse else { throw RemoteDownloadError.invalidResponse }
        guard http.statusCode == 200 else { throw RemoteDownloadError.transport(http.statusCode) }
        guard let finalURL = http.url, Self.matchesAuthorizedURL(finalURL, requestURL: request.url!) else { throw RemoteDownloadError.unexpectedRedirect }
        let length = http.expectedContentLength
        if length >= 0, length != file.size { throw RemoteDownloadError.invalidResponse }
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
