import Foundation
import Testing
@testable import BeepbarCore

struct LocalPathPolicyTests {
    @Test func migratesOnlyGeneratedCourseFolderNames() {
        let current = "056902 - GPUS & HETEROGENEOUS SYSTEMS (PROGRAMMING MODELS AND ARCHITECTURES) (MIELE) [2026-27]"
        #expect(LocalPathPolicy.generatedCourseFolderReplacement(
            storedFolder: "GPUS &amp; HETEROGENEOUS SYSTEMS (PROGRAMMING MODELS AND ARCHITECTURES)",
            storedCourseName: current,
            currentCourseName: current,
            courseID: 24_760
        ) == "GPUS & HETEROGENEOUS SYSTEMS (PROGRAMMING MODELS AND ARCHITECTURES)")
        #expect(LocalPathPolicy.generatedCourseFolderReplacement(
            storedFolder: "My GPU course",
            storedCourseName: current,
            currentCourseName: current,
            courseID: 24_760
        ) == nil)
    }

    @Test func buildsStableSafeDestination() throws {
        let file = RemoteFileCandidate(id: "9:4:/pluginfile.php/a.pdf", courseID: 9, sectionID: 1, moduleID: 4, sectionName: "Settimana 1", moduleName: "Lezioni", filename: "Analisi è.pdf", remoteFilePath: "/", canonicalPluginPath: "/pluginfile.php/a.pdf", downloadURL: URL(string: "https://webeep.polimi.it/pluginfile.php/a.pdf"), size: 4, modifiedAt: nil, observedRevision: "1:4", isSupported: true)
        #expect(try LocalPathPolicy.destination(courseFolder: "Analisi", file: file).value == "Analisi/Settimana 1/Lezioni/Analisi è.pdf")
    }

    @Test func blocksReservedRemotePath() {
        let file = RemoteFileCandidate(id: "9:4:/pluginfile.php/a.pdf", courseID: 9, sectionID: 1, moduleID: 4, sectionName: "S", moduleName: "M", filename: "a.pdf", remoteFilePath: "/.beepbar/", canonicalPluginPath: "/pluginfile.php/a.pdf", downloadURL: nil, size: 4, modifiedAt: nil, observedRevision: "1:4", isSupported: false)
        #expect(throws: LocalPathPolicyError.invalidRemotePath) { try LocalPathPolicy.destination(courseFolder: "Analisi", file: file) }
    }

    @Test func omitsMaterialsSectionAndFlattensSingleResource() throws {
        let file = RemoteFileCandidate(id: "9:4:/pluginfile.php/a.pdf", courseID: 9, sectionID: 1, moduleID: 4, sectionName: "Materiali", moduleName: "Dispensa", moduleType: "resource", isSingleFileResource: true, filename: "originale.pdf", remoteFilePath: "/", canonicalPluginPath: "/pluginfile.php/a.pdf", downloadURL: URL(string: "https://webeep.polimi.it/pluginfile.php/a.pdf"), size: 4, modifiedAt: nil, observedRevision: "1:4", isSupported: true)
        #expect(try LocalPathPolicy.destination(courseFolder: "Analisi", file: file).value == "Analisi/Dispensa.pdf")
    }

    @Test func omitsUnnamedSection() throws {
        let file = RemoteFileCandidate(id: "9:4:/pluginfile.php/a.pdf", courseID: 9, sectionID: 1, moduleID: 4, sectionName: "", moduleName: "LECTURES", filename: "intro.pdf", remoteFilePath: "/", canonicalPluginPath: "/pluginfile.php/a.pdf", downloadURL: URL(string: "https://webeep.polimi.it/pluginfile.php/a.pdf"), size: 4, modifiedAt: nil, observedRevision: "1:4", isSupported: true)
        #expect(try LocalPathPolicy.destination(courseFolder: "ALGEBRA", file: file).value == "ALGEBRA/LECTURES/intro.pdf")
    }

    @Test func numbersDuplicateFilenamesLikeWeBeepSync() throws {
        let original = try RelativePath("ALGEBRA/LECTURES/notes.pdf")
        var reserved = Set<String>()

        #expect(try LocalPathPolicy.uniqueDestination(original, reserving: &reserved).value == "ALGEBRA/LECTURES/notes.pdf")
        #expect(try LocalPathPolicy.uniqueDestination(original, reserving: &reserved).value == "ALGEBRA/LECTURES/notes (1).pdf")
        #expect(try LocalPathPolicy.uniqueDestination(original, reserving: &reserved).value == "ALGEBRA/LECTURES/notes (2).pdf")
    }

    @Test func extractsForkStyleCourseFolder() {
        #expect(LocalPathPolicy.defaultCourseFolder("054221 - FONDAMENTI DI CALCOLO (2025-26)") == "FONDAMENTI DI CALCOLO")
    }
}
