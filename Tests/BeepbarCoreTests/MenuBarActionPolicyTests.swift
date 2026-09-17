import Testing
@testable import BeepbarCore

struct MenuBarActionPolicyTests {
    @Test(arguments: [
        (true, false, false, MenuBarAccountCondition.connected, true, MenuBarAction.cancelSync),
        (true, true, false, .connected, true, .cancelSync),
        (false, true, true, .connected, true, .retryRecovery),
        (false, true, false, .loginRequired, true, .retryRecovery),
        (false, false, true, .connected, true, .openConflicts),
        (false, false, false, .loginRequired, true, .signIn),
        (false, false, false, .keychainAuthorizationRequired, true, .authorizeKeychain),
        (false, false, false, .keychainUnavailable, true, .retryKeychain),
        (false, false, false, .connected, false, .openSettings),
        (false, false, false, .connected, true, .synchronize)
    ])
    func resolvesAction(_ active: Bool, _ recoveryBlocked: Bool, _ conflicts: Bool, _ account: MenuBarAccountCondition, _ root: Bool, _ expected: MenuBarAction) {
        #expect(MenuBarActionPolicy.action(syncActive: active, recoveryBlocked: recoveryBlocked, hasConflicts: conflicts, account: account, hasRoot: root) == expected)
    }
}
