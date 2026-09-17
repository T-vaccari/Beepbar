import Foundation

public enum CredentialAccess: Sendable, Equatable {
    case interactive
    case nonInteractive
}

public enum CredentialMigrationOutcome: Sendable, Equatable {
    case migrated
    case notNeeded
    case noLegacyCredential
    case migrationFailed
}

public actor CredentialVault {
    private let read: @Sendable (CredentialAccess) throws -> String
    private let write: @Sendable (String) throws -> Void
    private var cachedToken: String?

    public init(
        read: @escaping @Sendable (CredentialAccess) throws -> String,
        write: @escaping @Sendable (String) throws -> Void
    ) {
        self.read = read
        self.write = write
    }

    public func load(_ access: CredentialAccess = .interactive) throws -> String {
        if let cachedToken { return cachedToken }
        let token = try read(access)
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

    /// Migrates a credential from a legacy store into this vault's backing store.
    ///
    /// Runs entirely within this actor, using the same `write` this vault already serializes
    /// `save()` through, so it can never interleave with a concurrent `load()`/`save()` call from
    /// a fresh login: one fully completes before the other starts, instead of racing to write the
    /// backing file and leaving whichever token lost the race silently in place.
    public func migrateFromLegacyStore(
        destinationAlreadyHasCredential: @Sendable () throws -> Bool,
        loadFromLegacyStore: @Sendable () throws -> String,
        deleteFromLegacyStore: @Sendable () -> Void
    ) -> CredentialMigrationOutcome {
        if let hasCredential = try? destinationAlreadyHasCredential(), hasCredential {
            return .notNeeded
        }
        guard let token = try? loadFromLegacyStore() else {
            return .noLegacyCredential
        }
        do {
            try write(token)
        } catch {
            return .migrationFailed
        }
        cachedToken = token
        deleteFromLegacyStore()
        return .migrated
    }
}
