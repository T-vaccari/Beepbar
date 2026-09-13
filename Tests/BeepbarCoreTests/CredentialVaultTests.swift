import Foundation
import XCTest
@testable import BeepbarCore

final class CredentialVaultTests: XCTestCase {
    func testConcurrentLoadsReadSecretOnlyOnce() async throws {
        let store = TestCredentialStore(token: "token")
        let vault = CredentialVault(read: { try store.read() }, write: { try store.write($0) })

        let values = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<20 { group.addTask { try await vault.load() } }
            return try await group.reduce(into: []) { $0.append($1) }
        }

        XCTAssertEqual(values, Array(repeating: "token", count: 20))
        XCTAssertEqual(store.readCount, 1)
    }

    func testSaveUpdatesCacheWithoutAnotherRead() async throws {
        let store = TestCredentialStore(token: "old")
        let vault = CredentialVault(read: { try store.read() }, write: { try store.write($0) })

        try await vault.save("new")
        let token = try await vault.load()
        XCTAssertEqual(token, "new")
        XCTAssertEqual(store.readCount, 0)
        XCTAssertEqual(store.token, "new")
    }

    func testFailedReadIsNotCachedAndInvalidationForcesOneNewRead() async throws {
        let store = TestCredentialStore(token: nil)
        let vault = CredentialVault(read: { try store.read() }, write: { try store.write($0) })

        await XCTAssertThrowsErrorAsync { _ = try await vault.load() }
        store.token = "first"
        let first = try await vault.load()
        XCTAssertEqual(first, "first")
        await vault.invalidate()
        store.token = "second"
        let second = try await vault.load()
        XCTAssertEqual(second, "second")
        XCTAssertEqual(store.readCount, 3)
    }
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

private func XCTAssertThrowsErrorAsync(
    _ expression: @escaping () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {}
}
