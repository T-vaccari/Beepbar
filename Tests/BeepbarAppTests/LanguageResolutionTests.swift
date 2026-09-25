import Foundation
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

struct PreferredLanguageTests {
    @Test(arguments: [
        (["it-CH"], AppLanguage.italian),
        (["IT"], .italian),
        (["it"], .italian),
        (["en-GB", "it-IT"], .english),
        (["fr-FR"], .english),
    ])
    func followsTheFirstPreferredLanguage(languages: [String], expected: AppLanguage) {
        #expect(AppLanguage.preferred(from: languages) == expected)
    }
}

struct MenuBarSymbolTests {
    private static let summary = SyncCompletionSummary(completedAt: Date(timeIntervalSince1970: 0), added: 0, updated: 0, unchanged: 0, preservedLocal: 0, conflicts: 0, failures: 0)

    @Test(arguments: [AppSyncState.checking, .syncing, .cancelling])
    func activeSyncShowsTheDownloadGlyph(state: AppSyncState) {
        #expect(WeBeepAuthenticationController.menuBarSymbol(for: state) == "arrow.down.circle")
    }

    @Test(arguments: [
        AppSyncState.conflicts(1, nil), .partial(summary), .failed(.connectivity), .recoveryBlocked, .loginRequired, .needsFolder,
    ])
    func statesNeedingTheUserShowAWarning(state: AppSyncState) {
        #expect(WeBeepAuthenticationController.menuBarSymbol(for: state) == "exclamationmark.triangle")
    }

    @Test(arguments: [AppSyncState.starting, .readyUnchecked, .synced(summary)])
    func idleStatesKeepTheDefaultGlyph(state: AppSyncState) {
        #expect(WeBeepAuthenticationController.menuBarSymbol(for: state) == "arrow.triangle.2.circlepath")
    }
}
