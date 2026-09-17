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
}
