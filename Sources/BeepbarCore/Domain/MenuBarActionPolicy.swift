public enum MenuBarAccountCondition: Sendable, Equatable {
    case connected
    case loginRequired
    case keychainAuthorizationRequired
    case keychainUnavailable
}

public enum MenuBarAction: Sendable, Equatable {
    case cancelSync
    case openConflicts
    case signIn
    case authorizeKeychain
    case retryKeychain
    case openSettings
    case synchronize
}

public enum MenuBarActionPolicy {
    public static func action(
        syncActive: Bool,
        hasConflicts: Bool,
        account: MenuBarAccountCondition,
        hasRoot: Bool
    ) -> MenuBarAction {
        if syncActive { return .cancelSync }
        if hasConflicts { return .openConflicts }
        switch account {
        case .loginRequired: return .signIn
        case .keychainAuthorizationRequired: return .authorizeKeychain
        case .keychainUnavailable: return .retryKeychain
        case .connected: return hasRoot ? .synchronize : .openSettings
        }
    }
}
