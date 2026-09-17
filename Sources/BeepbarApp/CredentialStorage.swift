import Foundation
import LocalAuthentication
import Security
import BeepbarCore

/// File-backed token storage: replaces the Keychain as the app's ongoing credential store.
///
/// The WeBeep mobile token is a revocable session token, not a password, so trading Keychain's
/// encryption-at-rest for a plain file avoids the macOS "BeepBar wants to use your confidential
/// information…" prompt that Keychain items trigger whenever the requesting app's code signature
/// changes between builds (dev/ad-hoc signing during development, before a stable Developer ID).
enum FileTokenStore {
    /// Overridable only from tests (`@testable import`) so they can point at an isolated,
    /// throwaway subdirectory instead of the developer's real Application Support folder.
    nonisolated(unsafe) static var directoryName = "Beepbar"
    private static let fileName = "credential.token"
    private static let tempFilePrefix = ".credential-"
    private static let tempFileSuffix = ".tmp"

    static func save(_ token: String) throws {
        let url = try fileURL()
        guard let data = token.data(using: .utf8) else { throw KeychainError.write }
        cleanUpOrphanedTempFiles(in: url.deletingLastPathComponent())
        // Written with 0600 permissions from the moment the file is created (rather than
        // written-then-chmod'd), and moved into place atomically, so there is never a window
        // where the token sits on disk under the default, more permissive umask.
        let tempURL = url.deletingLastPathComponent().appendingPathComponent("\(tempFilePrefix)\(UUID().uuidString)\(tempFileSuffix)")
        do {
            guard FileManager.default.createFile(atPath: tempURL.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                throw KeychainError.write
            }
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL, options: .usingNewMetadataOnly)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw KeychainError.write
        }
    }

    static func load(_ access: CredentialAccess) throws -> String {
        let url = try fileURL()
        guard FileManager.default.fileExists(atPath: url.path) else { throw KeychainError.absent }
        guard let data = try? Data(contentsOf: url) else { throw KeychainError.write }
        guard let token = String(data: data, encoding: .utf8), !token.isEmpty else {
            throw KeychainError.corrupt
        }
        return token
    }

    static func containsCredential() throws -> Bool {
        let url = try fileURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        guard let data = try? Data(contentsOf: url) else { throw KeychainError.write }
        guard let token = String(data: data, encoding: .utf8) else { return false }
        return !token.isEmpty
    }

    /// A crash or force-quit between creating the temp file and replacing the destination in
    /// `save()` leaves a stray `.tmp` behind; sweep those up before writing a new one.
    private static func cleanUpOrphanedTempFiles(in directory: URL) {
        guard let contents = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for item in contents where item.lastPathComponent.hasPrefix(tempFilePrefix) && item.lastPathComponent.hasSuffix(tempFileSuffix) {
            try? FileManager.default.removeItem(at: item)
        }
    }

    static func delete() {
        guard let url = try? fileURL() else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func fileURL() throws -> URL {
        do {
            let directory = try applicationSupportDirectory().appendingPathComponent(directoryName, isDirectory: true)
            if !FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            // The same "Beepbar" directory also holds the sync database, created independently
            // by `WeBeepAuthenticationController.databaseDirectory()` with default permissions
            // when it runs first — re-assert 0700 here so the credential file's directory is
            // never left group/world-readable regardless of creation order.
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            return directory.appendingPathComponent(fileName)
        } catch {
            throw KeychainError.write
        }
    }

    /// Never the developer's real Application Support folder when running a `--ui-preview` /
    /// `--ui-preview-onboarding` debug build, so a preview run's login/save calls can't touch the
    /// developer's real stored token.
    private static func applicationSupportDirectory() throws -> URL {
        if PreviewMode.isActive {
            return FileManager.default.temporaryDirectory.appendingPathComponent("Beepbar-credential-preview", isDirectory: true)
        }
        return try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    }
}

/// `--ui-preview-onboarding` intentionally exercises the real bootstrap flow (see
/// `WeBeepAuthenticationController.isUIPreviewOnboarding`) so "Scegli cartella…" works against the
/// real `chooseRoot()` code path. Anything that would otherwise touch the developer's *real*
/// Keychain or credential file — not just where a new file lands — must check this first.
enum PreviewMode {
    static var isActive: Bool {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains("--ui-preview") || ProcessInfo.processInfo.arguments.contains("--ui-preview-onboarding")
#else
        false
#endif
    }
}

/// Read-only access to whatever token a previous version of the app left in the Keychain, kept
/// around only long enough to migrate it into `FileTokenStore`. Nothing writes to the Keychain
/// anymore.
enum KeychainTokenStore {
    private static let account = "webeep.mobile.token"
    private static let service = "io.github.tvaccari.beepbar.auth.local.v3"
    private static let legacyServices = ["io.github.tvaccari.beepbar.auth.local.v2", "io.github.tvaccari.beepbar"]

    static func loadAnyCredential() throws -> String {
        if let token = try? load(.interactive) {
            return token
        }
        return try loadLegacyCredential()
    }

    static func deleteAllCredentials() {
        _ = SecItemDelete(currentQuery() as CFDictionary)
        for legacyService in legacyServices {
            _ = SecItemDelete(legacyQuery(service: legacyService) as CFDictionary)
        }
    }

    private static func load(_ access: CredentialAccess) throws -> String {
        var query = currentQuery()
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        if access == .nonInteractive {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        guard let data = result as? Data, let token = String(data: data, encoding: .utf8), !token.isEmpty else {
            throw KeychainError.corrupt
        }
        return token
    }

    private static func currentQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private static func legacyQuery(service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    private static func loadLegacyCredential() throws -> String {
        for legacyService in legacyServices {
            var query = legacyQuery(service: legacyService)
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            query[kSecReturnData as String] = true
            var result: CFTypeRef?
            if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
               let data = result as? Data,
               let token = String(data: data, encoding: .utf8),
               !token.isEmpty {
                return token
            }
        }
        throw KeychainError.absent
    }
}

enum CredentialMigrationOutcome: Equatable {
    case migrated
    case notNeeded
    case noLegacyCredential
    case migrationFailed
}

/// Pure decision logic, independent of the Keychain/file system, so it can be unit tested with
/// fakes the way `CredentialVault` already is.
enum CredentialMigration {
    static func run(
        fileHasCredential: () throws -> Bool,
        loadFromKeychain: () throws -> String,
        saveToFile: (String) throws -> Void,
        deleteFromKeychain: () -> Void
    ) -> CredentialMigrationOutcome {
        if let hasFile = try? fileHasCredential(), hasFile {
            return .notNeeded
        }
        guard let token = try? loadFromKeychain() else {
            return .noLegacyCredential
        }
        do {
            try saveToFile(token)
        } catch {
            return .migrationFailed
        }
        deleteFromKeychain()
        return .migrated
    }
}

enum ProductionCredentialMigration {
    static func run() -> CredentialMigrationOutcome {
        // Redirecting FileTokenStore to an isolated directory during preview builds (see
        // `FileTokenStore.applicationSupportDirectory()`) only protects where a *copy* lands —
        // it does nothing to stop this migration from reading and then deleting the developer's
        // real Keychain item. Skip the whole migration outright in that case.
        guard !PreviewMode.isActive else { return .notNeeded }
        return CredentialMigration.run(
            fileHasCredential: FileTokenStore.containsCredential,
            loadFromKeychain: KeychainTokenStore.loadAnyCredential,
            saveToFile: FileTokenStore.save,
            deleteFromKeychain: KeychainTokenStore.deleteAllCredentials
        )
    }
}
