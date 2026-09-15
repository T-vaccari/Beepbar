import Foundation

public enum NotificationFingerprint {
    public static func conflicts(_ conflicts: [ConflictRecord]) -> String {
        conflicts.map { conflict in
            [conflict.rootID.uuidString, conflict.remoteID, conflict.remoteRevision, conflict.remoteSHA256]
                .map { Data($0.utf8).base64EncodedString() }
                .joined(separator: ".")
        }
        .sorted()
        .joined(separator: "|")
    }
}

public final class NotificationDeduplicationStore {
    private let defaults: UserDefaults
    private let prefix: String

    public init(defaults: UserDefaults, prefix: String) {
        self.defaults = defaults
        self.prefix = prefix
    }

    public func shouldNotify(condition: String, fingerprint: String, now: Date, cooldown: TimeInterval = 86_400) -> Bool {
        let activeKey = "\(prefix).active.\(condition)"
        let dateKey = "\(prefix).date.\(condition)"
        let activeFingerprint = defaults.string(forKey: activeKey)
        let timestamp = defaults.double(forKey: dateKey)
        let lastDate = timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil
        if activeFingerprint == fingerprint, let lastDate, now.timeIntervalSince(lastDate) < cooldown {
            return false
        }
        defaults.set(fingerprint, forKey: activeKey)
        defaults.set(now.timeIntervalSince1970, forKey: dateKey)
        return true
    }

    public func resolve(condition: String) {
        defaults.removeObject(forKey: "\(prefix).active.\(condition)")
    }
}
