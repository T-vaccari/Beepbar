import Foundation

public actor CredentialVault {
    private let read: @Sendable () throws -> String
    private let write: @Sendable (String) throws -> Void
    private var cachedToken: String?

    public init(
        read: @escaping @Sendable () throws -> String,
        write: @escaping @Sendable (String) throws -> Void
    ) {
        self.read = read
        self.write = write
    }

    public func load() throws -> String {
        if let cachedToken { return cachedToken }
        let token = try read()
        cachedToken = token
        return token
    }

    public func save(_ token: String) throws {
        try write(token)
        cachedToken = token
    }

    public func invalidate() {
        cachedToken = nil
    }
}
