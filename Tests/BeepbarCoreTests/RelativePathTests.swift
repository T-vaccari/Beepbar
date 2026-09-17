import Testing
@testable import BeepbarCore

struct RelativePathTests {
    @Test func acceptsNestedUnicodePath() throws {
        #expect(try RelativePath("Analisi/Lezione è.pdf").value == "Analisi/Lezione è.pdf")
    }

    @Test func rejectsUnsafePaths() {
        for value in ["", "/tmp/file", "../file", "Course/../file", "Course//file", "./file", ".beepbar/state.sqlite"] {
            #expect(throws: RelativePathError.invalid) { try RelativePath(value) }
        }
    }

    @Test func rejectsTheReservedNamespaceRegardlessOfCase() {
        for value in [".BEEPBAR", ".BEEPBAR/state.sqlite", ".Beepbar/staging/x.partial", ".BeePbAr/conflicts/a/b.pdf"] {
            #expect(throws: RelativePathError.invalid) { try RelativePath(value) }
        }
    }
}
