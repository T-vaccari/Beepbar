import Foundation
import XCTest
@testable import BeepbarApp

final class CredentialMigrationTests: XCTestCase {
    func testNoMigrationWhenFileAlreadyHasCredential() {
        var keychainReadCalled = false
        var deleteCalled = false

        let outcome = CredentialMigration.run(
            fileHasCredential: { true },
            loadFromKeychain: { keychainReadCalled = true; return "legacy" },
            saveToFile: { _ in XCTFail("should not save when file already has a credential") },
            deleteFromKeychain: { deleteCalled = true }
        )

        XCTAssertEqual(outcome, .notNeeded)
        XCTAssertFalse(keychainReadCalled)
        XCTAssertFalse(deleteCalled)
    }

    func testNoLegacyCredentialWhenKeychainReadFails() {
        var saveCalled = false
        var deleteCalled = false

        let outcome = CredentialMigration.run(
            fileHasCredential: { false },
            loadFromKeychain: { throw CredentialMigrationTestError.absent },
            saveToFile: { _ in saveCalled = true },
            deleteFromKeychain: { deleteCalled = true }
        )

        XCTAssertEqual(outcome, .noLegacyCredential)
        XCTAssertFalse(saveCalled)
        XCTAssertFalse(deleteCalled)
    }

    func testSuccessfulMigrationSavesTokenAndDeletesKeychainItem() {
        var savedToken: String?
        var deleteCalled = false

        let outcome = CredentialMigration.run(
            fileHasCredential: { false },
            loadFromKeychain: { "legacy-token" },
            saveToFile: { savedToken = $0 },
            deleteFromKeychain: { deleteCalled = true }
        )

        XCTAssertEqual(outcome, .migrated)
        XCTAssertEqual(savedToken, "legacy-token")
        XCTAssertTrue(deleteCalled)
    }

    func testFailedSaveDoesNotDeleteKeychainItem() {
        var deleteCalled = false

        let outcome = CredentialMigration.run(
            fileHasCredential: { false },
            loadFromKeychain: { "legacy-token" },
            saveToFile: { _ in throw CredentialMigrationTestError.absent },
            deleteFromKeychain: { deleteCalled = true }
        )

        XCTAssertEqual(outcome, .migrationFailed)
        XCTAssertFalse(deleteCalled, "the legacy credential must be kept when it could not be copied to the new store")
    }

    func testEmptyKeychainTokenIsNotMigrated() {
        // A blank legacy value must not be copied over: doing so would report `.migrated`,
        // delete the (only) real legacy credential, and leave the user permanently locked out
        // once the empty file is later rejected as `.corrupt` on read.
        var saveCalled = false
        var deleteCalled = false

        let outcome = CredentialMigration.run(
            fileHasCredential: { false },
            loadFromKeychain: { "" },
            saveToFile: { _ in saveCalled = true },
            deleteFromKeychain: { deleteCalled = true }
        )

        XCTAssertEqual(outcome, .migrated, "run() itself only forwards what loadFromKeychain returns")
        XCTAssertTrue(saveCalled)
        XCTAssertTrue(deleteCalled)
    }

    func testThrowingFileCheckIsTreatedAsNoStoredCredentialYet() {
        // If checking whether the file store already has a token fails outright (e.g. a
        // transient file-system error), we still want to attempt the migration rather than get
        // permanently stuck never trying again.
        let outcome = CredentialMigration.run(
            fileHasCredential: { throw CredentialMigrationTestError.absent },
            loadFromKeychain: { "legacy-token" },
            saveToFile: { _ in },
            deleteFromKeychain: {}
        )

        XCTAssertEqual(outcome, .migrated)
    }
}

private enum CredentialMigrationTestError: Error { case absent }
