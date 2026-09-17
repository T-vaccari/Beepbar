import Foundation
import Testing
@testable import BeepbarCore

struct CredentialVaultTests {
    @Test func concurrentLoadsReadSecretOnlyOnce() async throws {
        let store = TestCredentialStore(token: "token")
        let vault = CredentialVault(read: { _ in try store.read() }, write: { try store.write($0) })

        let values = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<20 { group.addTask { try await vault.load() } }
            return try await group.reduce(into: []) { $0.append($1) }
        }

        #expect(values == Array(repeating: "token", count: 20))
        #expect(store.readCount == 1)
    }

    @Test func saveUpdatesCacheWithoutAnotherRead() async throws {
        let store = TestCredentialStore(token: "old")
        let vault = CredentialVault(read: { _ in try store.read() }, write: { try store.write($0) })

        try await vault.save("new")
        let token = try await vault.load()
        #expect(token == "new")
        #expect(store.readCount == 0)
        #expect(store.token == "new")
    }

    @Test func failedReadIsNotCachedAndInvalidationForcesOneNewRead() async throws {
        let store = TestCredentialStore(token: nil)
        let vault = CredentialVault(read: { _ in try store.read() }, write: { try store.write($0) })

        await #expect(throws: TestCredentialError.absent) { _ = try await vault.load() }
        store.token = "first"
        let first = try await vault.load()
        #expect(first == "first")
        await vault.invalidate()
        store.token = "second"
        let second = try await vault.load()
        #expect(second == "second")
        #expect(store.readCount == 3)
    }

    @Test func nonInteractiveAccessIsForwardedToStore() async throws {
        let access = AccessRecorder()
        let vault = CredentialVault(read: { mode in access.record(mode); return "token" }, write: { _ in })

        _ = try await vault.load(.nonInteractive)

        #expect(access.last == .nonInteractive)
    }
}

private final class AccessRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value: CredentialAccess?
    var last: CredentialAccess? { lock.withLock { value } }
    func record(_ access: CredentialAccess) { lock.withLock { value = access } }
}

private enum TestCredentialError: Error { case absent }

private final class TestCredentialStore: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    private var reads = 0

    init(token: String?) { value = token }

    var token: String? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }

    var readCount: Int { lock.withLock { reads } }

    func read() throws -> String {
        try lock.withLock {
            reads += 1
            guard let value else { throw TestCredentialError.absent }
            return value
        }
    }

    func write(_ token: String) throws {
        lock.withLock { value = token }
    }
}
