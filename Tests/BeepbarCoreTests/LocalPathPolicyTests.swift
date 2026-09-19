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
        let file = RemoteFileCandidate(id: "9:4:/pluginfile.php/a.pdf", courseID: 9, sectionID: 1, moduleID: 4, sectionName: "Materiali", moduleName: "Dispensa", moduleType: "resource", isSingleFileResource: true, filename: "originale.pdf", remoteFilePath: "/dispense/", canonicalPluginPath: "/pluginfile.php/a.pdf", downloadURL: URL(string: "https://webeep.polimi.it/pluginfile.php/a.pdf"), size: 4, modifiedAt: nil, observedRevision: "1:4", isSupported: true)
        #expect(try LocalPathPolicy.destination(courseFolder: "Analisi", file: file).value == "Analisi/dispense/Dispensa.pdf")
    }

    @Test func keepsSectionAndRemotePathForSingleResource() throws {
        let file = RemoteFileCandidate(id: "9:4:/pluginfile.php/a.pdf", courseID: 9, sectionID: 1, moduleID: 4, sectionName: "Esami", moduleName: "Regole esame", moduleType: "resource", isSingleFileResource: true, filename: "originale.pdf", remoteFilePath: "/2026/", canonicalPluginPath: "/pluginfile.php/a.pdf", downloadURL: URL(string: "https://webeep.polimi.it/pluginfile.php/a.pdf"), size: 4, modifiedAt: nil, observedRevision: "1:4", isSupported: true)
        #expect(try LocalPathPolicy.destination(courseFolder: "Analisi", file: file).value == "Analisi/Esami/2026/Regole esame.pdf")
    }

    @Test func omitsUnnamedSection() throws {
        let file = RemoteFileCandidate(id: "9:4:/pluginfile.php/a.pdf", courseID: 9, sectionID: 1, moduleID: 4, sectionName: "", moduleName: "LECTURES", filename: "intro.pdf", remoteFilePath: "/", canonicalPluginPath: "/pluginfile.php/a.pdf", downloadURL: URL(string: "https://webeep.polimi.it/pluginfile.php/a.pdf"), size: 4, modifiedAt: nil, observedRevision: "1:4", isSupported: true)
        #expect(try LocalPathPolicy.destination(courseFolder: "ALGEBRA", file: file).value == "ALGEBRA/LECTURES/intro.pdf")
    }

    @Test func flattensUnnamedModuleIntoCourseFolder() throws {
        let file = RemoteFileCandidate(id: "9:4:/pluginfile.php/a.pdf", courseID: 9, sectionID: 1, moduleID: 4, sectionName: "", moduleName: "", filename: "P0_Antonietti.pdf", remoteFilePath: "/", canonicalPluginPath: "/pluginfile.php/a.pdf", downloadURL: URL(string: "https://webeep.polimi.it/pluginfile.php/a.pdf"), size: 4, modifiedAt: nil, observedRevision: "1:4", isSupported: true)
        #expect(try LocalPathPolicy.destination(courseFolder: "NUMERICAL LINEAR ALGEBRA", file: file).value == "NUMERICAL LINEAR ALGEBRA/P0_Antonietti.pdf")
    }

    @Test func numbersDuplicateFilenames() throws {
        let original = try RelativePath("ALGEBRA/LECTURES/notes.pdf")
        var reserved = Set<String>()

        #expect(try LocalPathPolicy.uniqueDestination(original, reserving: &reserved).value == "ALGEBRA/LECTURES/notes.pdf")
        #expect(try LocalPathPolicy.uniqueDestination(original, reserving: &reserved).value == "ALGEBRA/LECTURES/notes (1).pdf")
        #expect(try LocalPathPolicy.uniqueDestination(original, reserving: &reserved).value == "ALGEBRA/LECTURES/notes (2).pdf")
    }

    @Test func replacesFilenameSeparatorsWithoutCreatingDirectories() throws {
        let file = RemoteFileCandidate(id: "9:4:/pluginfile.php/a.pdf", courseID: 9, sectionID: 1, moduleID: 4, sectionName: "", moduleName: "LECTURES", filename: "part/one\\draft.pdf", remoteFilePath: "/", canonicalPluginPath: "/pluginfile.php/a.pdf", downloadURL: nil, size: 4, modifiedAt: nil, observedRevision: "1:4", isSupported: true)
        #expect(try LocalPathPolicy.destination(courseFolder: "ALGEBRA", file: file).value == "ALGEBRA/LECTURES/part_one_draft.pdf")
    }

    @Test func sanitizesSpecialCharacters() throws {
        let file = RemoteFileCandidate(id: "9:4:/pluginfile.php/a.pdf", courseID: 9, sectionID: 1, moduleID: 4, sectionName: "Exam:\t2026", moduleName: "Rules?*", filename: "draft\n\"one\"<>|.pdf", remoteFilePath: "/", canonicalPluginPath: "/pluginfile.php/a.pdf", downloadURL: nil, size: 4, modifiedAt: nil, observedRevision: "1:4", isSupported: true)
        #expect(try LocalPathPolicy.destination(courseFolder: "ALGEBRA", file: file).value == "ALGEBRA/Exam_ 2026/Rules__/draft _one____.pdf")
    }

    @Test func treatsCaseAndUnicodeEquivalentDestinationsAsDuplicates() throws {
        var reserved = Set<String>()
        let uppercase = try RelativePath("ALGEBRA/Notes.pdf")
        let lowercase = try RelativePath("algebra/notes.pdf")
        let decomposed = try RelativePath("ALGEBRA/Cafe\u{301}.pdf")
        let composed = try RelativePath("ALGEBRA/Caf\u{e9}.pdf")

        #expect(try LocalPathPolicy.uniqueDestination(uppercase, reserving: &reserved).value == "ALGEBRA/Notes.pdf")
        #expect(try LocalPathPolicy.uniqueDestination(lowercase, reserving: &reserved).value == "algebra/notes (1).pdf")
        #expect(try LocalPathPolicy.uniqueDestination(decomposed, reserving: &reserved).value == "ALGEBRA/Cafe\u{301}.pdf")
        #expect(try LocalPathPolicy.uniqueDestination(composed, reserving: &reserved).value == "ALGEBRA/Caf\u{e9} (1).pdf")
    }

    @Test func extractsForkStyleCourseFolder() {
        #expect(LocalPathPolicy.defaultCourseFolder("054221 - FONDAMENTI DI CALCOLO (2025-26)") == "FONDAMENTI DI CALCOLO")
    }

    @Test func treatsTheReservedNamespaceAsReservedRegardlessOfCase() {
        #expect(LocalPathPolicy.component(".BEEPBAR") == "_")
        #expect(LocalPathPolicy.component(".Beepbar") == "_")
        let file = RemoteFileCandidate(id: "9:4:/pluginfile.php/a.pdf", courseID: 9, sectionID: 1, moduleID: 4, sectionName: "S", moduleName: "M", filename: "a.pdf", remoteFilePath: "/.BEEPBAR/", canonicalPluginPath: "/pluginfile.php/a.pdf", downloadURL: nil, size: 4, modifiedAt: nil, observedRevision: "1:4", isSupported: false)
        #expect(throws: LocalPathPolicyError.invalidRemotePath) { try LocalPathPolicy.destination(courseFolder: "Analisi", file: file) }
    }
}
