import Foundation

public struct SyncProgressThrottle: Sendable {
    private let minimumInterval: Duration
    private var lastCompleted = -1
    private var lastEmission: ContinuousClock.Instant?

    public init(minimumInterval: Duration) {
        self.minimumInterval = minimumInterval
    }

    public mutating func reset() {
        lastCompleted = -1
        lastEmission = nil
    }

    public mutating func accept(_ progress: SyncProgress, now: ContinuousClock.Instant) -> SyncProgress? {
        guard progress.completed >= lastCompleted else { return nil }
        let isFinal = progress.total > 0 && progress.completed == progress.total
        if !isFinal, let lastEmission, lastEmission.duration(to: now) < minimumInterval { return nil }
        lastCompleted = progress.completed
        lastEmission = now
        return progress
    }
}
