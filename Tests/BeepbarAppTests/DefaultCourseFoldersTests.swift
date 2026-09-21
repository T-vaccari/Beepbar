import Foundation
import Testing
import BeepbarCore
@testable import BeepbarApp

struct DefaultCourseFoldersTests {
    private func course(_ id: Int64, _ displayName: String) -> RemoteCourseSummary {
        RemoteCourseSummary(id: id, shortName: String(id), displayName: displayName, isVisible: true, startDate: nil, endDate: nil)
    }

    @Test func mapsEveryCourseToItsForkStyleFolder() {
        let folders = WeBeepAuthenticationController.defaultFolders(for: [
            course(1, "054221 - FONDAMENTI DI CALCOLO (2025-26)"),
            course(2, "056902 - ANALISI MATEMATICA 1 (2025-26)"),
            course(3, "Tesi di laurea"),
        ])
        #expect(folders == [1: "FONDAMENTI DI CALCOLO", 2: "ANALISI MATEMATICA 1", 3: "Tesi di laurea"])
    }

    @Test func fallsBackToTheFullNameOnlyForCoursesWhoseDefaultsCollide() {
        // Two editions of the same course would otherwise share one folder (the comparison is
        // case-insensitive); the courses that collide keep their full name, the others do not.
        let folders = WeBeepAuthenticationController.defaultFolders(for: [
            course(1, "054221 - FONDAMENTI DI CALCOLO (2024-25)"),
            course(2, "054221 - Fondamenti di Calcolo (2025-26)"),
            course(3, "056902 - ANALISI MATEMATICA 1 (2025-26)"),
        ])
        #expect(folders[1] == "054221 - FONDAMENTI DI CALCOLO (2024-25)")
        #expect(folders[2] == "054221 - Fondamenti di Calcolo (2025-26)")
        #expect(folders[3] == "ANALISI MATEMATICA 1")
    }

    @Test func emptyCourseListYieldsEmptyMap() {
        #expect(WeBeepAuthenticationController.defaultFolders(for: []).isEmpty)
    }

    @Test func identicalNamesUseIDAsAStrictTieBreaker() {
        let ordered = WeBeepAuthenticationController.orderedForDisplay([
            course(3, "Analisi"), course(1, "Analisi"), course(2, "Analisi")
        ], enabledCourseIDs: [])
        #expect(ordered.map(\.id) == [1, 2, 3])
    }

    @Test func progressDetailIncludesCompletedAndTotalFiles() {
        let progress = SyncProgress(completed: 3, total: 10, installed: 2, preservedLocal: 0, unchanged: 1, conflicts: 0, failures: 0)
        #expect(WeBeepAuthenticationController.progressDetail(progress) == "3 di 10 file")
    }

    @Test func newRootKeepsCurrentSelectionsForAvailableCourses() {
        let restored = WeBeepAuthenticationController.restoredEnabledCourseIDs(
            scopes: [], current: [1, 3, 99], remoteIDs: [1, 2, 3]
        )
        #expect(restored == [1, 3])
    }

    @Test func existingRootUsesPersistedSelections() {
        let rootID = UUID()
        let scopes = [
            SyncScope(rootID: rootID, courseID: 1, displayName: "One", localFolder: "One", enabled: false),
            SyncScope(rootID: rootID, courseID: 2, displayName: "Two", localFolder: "Two", enabled: true),
        ]
        let restored = WeBeepAuthenticationController.restoredEnabledCourseIDs(
            scopes: scopes, current: [1], remoteIDs: [1, 2]
        )
        #expect(restored == [2])
    }
}
