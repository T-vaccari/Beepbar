import Foundation
import Testing
@testable import BeepbarApp

struct OnboardingGatingTests {
    @Test func freshInstallNeedsOnboarding() {
        #expect(WeBeepAuthenticationController.resolveNeedsOnboarding(existingRootURL: nil, onboardingAlreadyCompleted: false) == true)
    }

    @Test func existingInstallUpdatingNeverRetriggersOnboardingEvenIfFlagWasNeverSet() {
        // This is the exact scenario for every user who set up Beepbar before onboarding existed:
        // they have a root but the flag was never written. An existing root must win on its own.
        let root = URL(fileURLWithPath: "/tmp/some-existing-root")
        #expect(WeBeepAuthenticationController.resolveNeedsOnboarding(existingRootURL: root, onboardingAlreadyCompleted: false) == false)
    }

    @Test func completedOnboardingWithRootDoesNotReappear() {
        let root = URL(fileURLWithPath: "/tmp/some-existing-root")
        #expect(WeBeepAuthenticationController.resolveNeedsOnboarding(existingRootURL: root, onboardingAlreadyCompleted: true) == false)
    }

    @Test func completedOnboardingSurvivesRootGoingMissing() {
        // e.g. the user deleted the sync folder from Finder without redoing setup: onboarding
        // must not come back just because storedRootURL() now resolves to nil.
        #expect(WeBeepAuthenticationController.resolveNeedsOnboarding(existingRootURL: nil, onboardingAlreadyCompleted: true) == false)
    }
}
