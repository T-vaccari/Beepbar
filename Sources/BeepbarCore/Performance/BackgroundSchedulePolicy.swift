import Foundation

public struct BackgroundScheduleInput: Sendable, Equatable {
    public let automaticSyncEnabled: Bool
    public let hasCredential: Bool
    public let hasRoot: Bool
    public let enabledCourseCount: Int
    public let recoveryBlocked: Bool

    public init(automaticSyncEnabled: Bool, hasCredential: Bool, hasRoot: Bool, enabledCourseCount: Int, recoveryBlocked: Bool) {
        self.automaticSyncEnabled = automaticSyncEnabled
        self.hasCredential = hasCredential
        self.hasRoot = hasRoot
        self.enabledCourseCount = enabledCourseCount
        self.recoveryBlocked = recoveryBlocked
    }
}

public enum BackgroundSchedulePolicy {
    public static func shouldSchedule(_ input: BackgroundScheduleInput) -> Bool {
        input.automaticSyncEnabled && input.hasCredential && input.hasRoot && input.enabledCourseCount > 0 && !input.recoveryBlocked
    }
}
