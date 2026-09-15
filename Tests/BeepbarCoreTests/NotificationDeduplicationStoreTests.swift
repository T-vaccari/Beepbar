import Foundation
import Testing
@testable import BeepbarCore

@Suite(.serialized) struct NotificationDeduplicationStoreTests {
    @Test func persistsCooldownAcrossInstancesAndSeparatesConditions() {
        let suite = "NotificationDeduplicationStoreTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 100_000)
        let first = NotificationDeduplicationStore(defaults: defaults, prefix: "test")
        #expect(first.shouldNotify(condition: "service", fingerprint: "service", now: now))
        #expect(first.shouldNotify(condition: "auth", fingerprint: "auth", now: now))

        let relaunched = NotificationDeduplicationStore(defaults: defaults, prefix: "test")
        #expect(!relaunched.shouldNotify(condition: "service", fingerprint: "service", now: now.addingTimeInterval(60)))
        #expect(!relaunched.shouldNotify(condition: "auth", fingerprint: "auth", now: now.addingTimeInterval(60)))
    }

    @Test func changedFingerprintAndResolvedConditionNotifyAgain() {
        let suite = "NotificationDeduplicationStoreTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = NotificationDeduplicationStore(defaults: defaults, prefix: "test")
        let now = Date(timeIntervalSince1970: 100_000)
        #expect(store.shouldNotify(condition: "conflicts", fingerprint: "a:1", now: now))
        #expect(store.shouldNotify(condition: "conflicts", fingerprint: "a:2", now: now.addingTimeInterval(1)))
        store.resolve(condition: "conflicts")
        #expect(store.shouldNotify(condition: "conflicts", fingerprint: "a:2", now: now.addingTimeInterval(2)))
    }

    @Test func conflictFingerprintUsesRemoteIdentityInsteadOfTransientID() throws {
        let rootID = UUID()
        let first = ConflictRecord(id: UUID(), rootID: rootID, remoteID: "file", relativePath: try RelativePath("Course/file.pdf"), incomingPath: try RelativePath(internal: ".beepbar/conflicts/one/file.pdf"), baseSHA256: "base", localSHA256: "local", remoteSHA256: "remote", remoteRevision: "2", detectedAt: .now, status: .open)
        let recreated = ConflictRecord(id: UUID(), rootID: rootID, remoteID: "file", relativePath: try RelativePath("Other/file.pdf"), incomingPath: try RelativePath(internal: ".beepbar/conflicts/two/file.pdf"), baseSHA256: "different-base", localSHA256: "different-local", remoteSHA256: "remote", remoteRevision: "2", detectedAt: .now, status: .open)
        let changedRemote = ConflictRecord(id: UUID(), rootID: rootID, remoteID: "file", relativePath: first.relativePath, incomingPath: first.incomingPath, baseSHA256: first.baseSHA256, localSHA256: first.localSHA256, remoteSHA256: "new-remote", remoteRevision: "2", detectedAt: .now, status: .open)

        #expect(NotificationFingerprint.conflicts([first]) == NotificationFingerprint.conflicts([recreated]))
        #expect(NotificationFingerprint.conflicts([first]) != NotificationFingerprint.conflicts([changedRemote]))
    }
}
