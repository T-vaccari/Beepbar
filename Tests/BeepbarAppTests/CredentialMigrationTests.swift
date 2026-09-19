import Foundation
import XCTest
import BeepbarCore
@testable import BeepbarApp

final class CredentialMigrationTests: XCTestCase {
    func testNoMigrationWhenDestinationAlreadyHasCredential() async {
        let flags = Flags()
        let vault = CredentialVault(read: { _ in "cached" }, write: { _ in XCTFail("should not write when the destination already has a credential") })

        let outcome = await vault.migrateFromLegacyStore(
            destinationAlreadyHasCredential: { true },
            loadFromLegacyStore: { flags.set(\.legacyReadCalled); return "legacy" },
            deleteFromLegacyStore: { flags.set(\.deleteCalled) }
        )

        XCTAssertEqual(outcome, .notNeeded)
        XCTAssertFalse(flags.legacyReadCalled)
        XCTAssertFalse(flags.deleteCalled)
    }

    func testNoLegacyCredentialWhenLegacyReadFails() async {
        let flags = Flags()
        let vault = CredentialVault(read: { _ in "cached" }, write: { _ in flags.set(\.writeCalled) })

        let outcome = await vault.migrateFromLegacyStore(
            destinationAlreadyHasCredential: { false },
            loadFromLegacyStore: { throw CredentialMigrationTestError.absent },
            deleteFromLegacyStore: { flags.set(\.deleteCalled) }
        )

        XCTAssertEqual(outcome, .noLegacyCredential)
        XCTAssertFalse(flags.writeCalled)
        XCTAssertFalse(flags.deleteCalled)
    }

    func testSuccessfulMigrationWritesTokenAndDeletesLegacyItem() async throws {
        let writtenToken = Box<String>()
        let flags = Flags()
        let vault = CredentialVault(read: { _ in "cached" }, write: { writtenToken.value = $0 })

        let outcome = await vault.migrateFromLegacyStore(
            destinationAlreadyHasCredential: { false },
            loadFromLegacyStore: { "legacy-token" },
            deleteFromLegacyStore: { flags.set(\.deleteCalled) }
        )

        XCTAssertEqual(outcome, .migrated)
        XCTAssertEqual(writtenToken.value, "legacy-token")
        XCTAssertTrue(flags.deleteCalled)
        // The vault must not need a fresh read to serve the token it just migrated.
        let reloaded = try await vault.load()
        XCTAssertEqual(reloaded, "legacy-token")
    }

    func testFailedWriteDoesNotDeleteLegacyItem() async {
        let flags = Flags()
        let vault = CredentialVault(read: { _ in "cached" }, write: { _ in throw CredentialMigrationTestError.absent })

        let outcome = await vault.migrateFromLegacyStore(
            destinationAlreadyHasCredential: { false },
            loadFromLegacyStore: { "legacy-token" },
            deleteFromLegacyStore: { flags.set(\.deleteCalled) }
        )

        XCTAssertEqual(outcome, .migrationFailed)
        XCTAssertFalse(flags.deleteCalled, "the legacy credential must be kept when it could not be copied to the new store")
    }

    func testThrowingDestinationCheckIsTreatedAsNoStoredCredentialYet() async {
        // If checking whether the destination already has a credential fails outright (e.g. a
        // transient file-system error), we still want to attempt the migration rather than get
        // permanently stuck never trying again.
        let vault = CredentialVault(read: { _ in "cached" }, write: { _ in })

        let outcome = await vault.migrateFromLegacyStore(
            destinationAlreadyHasCredential: { throw CredentialMigrationTestError.absent },
            loadFromLegacyStore: { "legacy-token" },
            deleteFromLegacyStore: {}
        )

        XCTAssertEqual(outcome, .migrated)
    }

    /// Guards the fix for the race a concurrent login could hit: `write` and `cachedToken` are
    /// only ever touched from synchronous, non-suspending actor-isolated code in both
    /// `migrateFromLegacyStore` and `save`, so Swift's actor isolation runs either call to
    /// completion before the other starts — there is no `await` between reading the destination
    /// and updating the cache where a second call could interleave and leave a stale token in
    /// place. A concurrent `save()` therefore either lands entirely before migration reads the
    /// destination (migration then reports `.notNeeded`) or entirely after it (migration's write
    /// is overwritten by the newer login, exactly as a same-thread call order would behave).
    func testConcurrentSaveDuringMigrationLeavesTheVaultInAConsistentState() async throws {
        let writes = WriteLog()
        let vault = CredentialVault(read: { _ in "cached" }, write: { writes.append($0) })

        async let migration: CredentialMigrationOutcome = vault.migrateFromLegacyStore(
            destinationAlreadyHasCredential: { false },
            loadFromLegacyStore: { "legacy-token" },
            deleteFromLegacyStore: {}
        )
        async let save: Void = vault.save("fresh-login-token")
        _ = try await (migration, save)

        // Exactly one write landed for each call, never a torn or dropped one, and the cache
        // matches the last write actually applied.
        XCTAssertEqual(writes.all.count, 2)
        let current = try await vault.load()
        XCTAssertEqual(current, writes.all.last)
    }
}

/// Simple thread-safe mutable flags/value boxes, mirroring `TestCredentialStore` in
/// `CredentialVaultTests`, needed because the migration closures are `@Sendable` and so cannot
/// capture a plain local `var` by mutable reference.
private final class Flags: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = (legacyReadCalled: false, writeCalled: false, deleteCalled: false)

    var legacyReadCalled: Bool { lock.withLock { storage.legacyReadCalled } }
    var writeCalled: Bool { lock.withLock { storage.writeCalled } }
    var deleteCalled: Bool { lock.withLock { storage.deleteCalled } }

    func set(_ flag: WritableKeyPath<(legacyReadCalled: Bool, writeCalled: Bool, deleteCalled: Bool), Bool>) {
        lock.withLock { storage[keyPath: flag] = true }
    }
}

private final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value?
    var value: Value? {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

private final class WriteLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    var all: [String] { lock.withLock { values } }
    func append(_ value: String) { lock.withLock { values.append(value) } }
}

private enum CredentialMigrationTestError: Error { case absent }
