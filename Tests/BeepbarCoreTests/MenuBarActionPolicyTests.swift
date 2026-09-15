import Testing
@testable import BeepbarCore

struct MenuBarActionPolicyTests {
    @Test(arguments: [
        (true, false, MenuBarAccountCondition.connected, true, MenuBarAction.cancelSync),
        (false, true, .connected, true, .openConflicts),
        (false, false, .loginRequired, true, .signIn),
        (false, false, .keychainAuthorizationRequired, true, .authorizeKeychain),
        (false, false, .keychainUnavailable, true, .retryKeychain),
        (false, false, .connected, false, .openSettings),
        (false, false, .connected, true, .synchronize)
    ])
    func resolvesAction(_ active: Bool, _ conflicts: Bool, _ account: MenuBarAccountCondition, _ root: Bool, _ expected: MenuBarAction) {
        #expect(MenuBarActionPolicy.action(syncActive: active, hasConflicts: conflicts, account: account, hasRoot: root) == expected)
    }
}
