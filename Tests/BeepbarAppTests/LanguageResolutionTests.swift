import Testing
import BeepbarCore
@testable import BeepbarApp

struct LanguageResolutionTests {
    @Test func storedChoiceAlwaysWins() {
        #expect(WeBeepAuthenticationController.resolveLanguage(stored: "en", needsOnboarding: false, preferredLanguages: ["it-IT"]) == .english)
        #expect(WeBeepAuthenticationController.resolveLanguage(stored: "it", needsOnboarding: true, preferredLanguages: ["en-US"]) == .italian)
    }

    @Test func existingInstallWithoutAChoiceStaysItalian() {
        // Every install set up before the setting existed only ever had Italian copy.
        #expect(WeBeepAuthenticationController.resolveLanguage(stored: nil, needsOnboarding: false, preferredLanguages: ["en-US"]) == .italian)
    }

    @Test func freshInstallStartsFromTheSystemLanguage() {
        #expect(WeBeepAuthenticationController.resolveLanguage(stored: nil, needsOnboarding: true, preferredLanguages: ["it-IT", "en-US"]) == .italian)
        #expect(WeBeepAuthenticationController.resolveLanguage(stored: nil, needsOnboarding: true, preferredLanguages: ["de-DE", "it-IT"]) == .english)
    }

    @Test func unknownStoredValueFallsBackLikeNoChoice() {
        #expect(WeBeepAuthenticationController.resolveLanguage(stored: "fr", needsOnboarding: false, preferredLanguages: ["en-US"]) == .italian)
    }

    @Test func systemPreferenceWithNoLanguagesDefaultsToItalian() {
        #expect(AppLanguage.preferred(from: []) == .italian)
    }
}
