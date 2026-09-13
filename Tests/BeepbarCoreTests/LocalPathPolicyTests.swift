import Foundation
import Testing
@testable import BeepbarCore

struct LocalPathPolicyTests {
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

    @Test func extractsForkStyleCourseFolder() {
        #expect(LocalPathPolicy.defaultCourseFolder("054221 - FONDAMENTI DI CALCOLO (2025-26)") == "FONDAMENTI DI CALCOLO")
    }
}
