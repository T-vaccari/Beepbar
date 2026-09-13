import Foundation
import os

public enum PerformanceCategory: String, Sendable {
    case bootstrap
    case ui
    case scheduler
    case sync
    case database
    case filesystem
}

public final class PerformanceTrace: @unchecked Sendable {
    public static let shared = PerformanceTrace()

    private let signposters: [PerformanceCategory: OSSignposter]

    private init() {
        signposters = Dictionary(uniqueKeysWithValues: PerformanceCategory.allCases.map {
            ($0, OSSignposter(subsystem: "io.github.tvaccari.beepbar.performance", category: $0.rawValue))
        })
    }

    public func begin(_ name: StaticString, category: PerformanceCategory) -> OSSignpostIntervalState {
        signposters[category]!.beginInterval(name)
    }

    public func end(_ name: StaticString, category: PerformanceCategory, state: OSSignpostIntervalState) {
        signposters[category]!.endInterval(name, state)
    }

    public func event(_ name: StaticString, category: PerformanceCategory) {
        signposters[category]!.emitEvent(name)
    }

}

extension PerformanceCategory: CaseIterable {}
