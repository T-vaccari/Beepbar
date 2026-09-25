import SwiftUI
import BeepbarCore

struct SettingsPage: View {
    @ObservedObject var authentication: WeBeepAuthenticationController
    // Sparkle's setting isn't observable; mirror it so the toggle reflects changes immediately.
    @State private var checksForUpdates = UpdaterController.shared.automaticallyChecksForUpdates
    @State private var showSignOutConfirmation = false

    var body: some View {
        Form {
            languageSection
            accountSection
            folderSection
            automaticSection
            updatesSection
        }
        .formStyle(.grouped)
        .confirmationDialog(tr("Disconnettere l'account \(authentication.selectedSite.platformName)?", "Disconnect the \(authentication.selectedSite.platformName) account?"), isPresented: $showSignOutConfirmation, titleVisibility: .visible) {
            Button(tr("Disconnetti", "Disconnect"), role: .destructive) { authentication.signOut() }
            Button(tr("Annulla", "Cancel"), role: .cancel) {}
        } message: {
            Text(tr("Il token salvato viene eliminato da questo Mac. La cartella dei materiali e i file restano dove sono.", "The saved token is removed from this Mac. The materials folder and files stay where they are."))
        }
    }

    // MARK: Language

    private var languageSection: some View {
        Section {
            LanguagePicker(authentication: authentication)
        } header: {
            Text(tr("Lingua", "Language"))
        }
    }

    // MARK: Account

    private var accountSection: some View {
        Section {
            if !authentication.hasStoredCredential {
                MoodleSitePicker(authentication: authentication)
            }
            HStack(spacing: 12) {
                SymbolTile(systemImage: accountSymbol, tint: accountTint, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(authentication.accountState.title).font(.body.weight(.medium))
                    Text(authentication.selectedSite.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if authentication.isVerifying || authentication.isAuthenticating {
                    ProgressView().controlSize(.small)
                }
                Button(tr("Verifica", "Verify")) { authentication.validateConnection() }
                    .disabled(!authentication.hasStoredCredential || authentication.isVerifying)
                if authentication.hasStoredCredential {
                    Button(tr("Disconnetti…", "Disconnect…")) { showSignOutConfirmation = true }
                        .disabled(authentication.isSyncActive || authentication.isLoadingCourses)
                }
                if authentication.accountState != .connected {
                    Button(authentication.accountState == .expired ? tr("Accedi di nuovo", "Sign in again") : tr("Accedi", "Sign in")) { authentication.startLogin() }
                        .buttonStyle(.borderedProminent)
                        .disabled(authentication.isAuthenticating)
                }
            }
        } header: {
            Text(tr("Account \(authentication.selectedSite.platformName)", "\(authentication.selectedSite.platformName) account"))
        } footer: {
            Label(tr("Il token resta in locale, protetto da permessi ristretti.", "The token stays on this Mac, protected by restricted permissions."), systemImage: "lock.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var accountSymbol: String {
        switch authentication.accountState {
        case .connected: "person.crop.circle.badge.checkmark"
        case .expired: "person.crop.circle.badge.exclamationmark"
        case .notConnected: "person.crop.circle.badge.plus"
        }
    }

    private var accountTint: Color {
        switch authentication.accountState {
        case .connected: .green
        case .expired: .orange
        case .notConnected: .gray
        }
    }

    // MARK: Folder

    private var folderSection: some View {
        Section {
            HStack(spacing: 12) {
                SymbolTile(systemImage: "folder.fill", tint: .blue, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(authentication.rootURL?.lastPathComponent ?? tr("Nessuna cartella scelta", "No folder chosen"))
                        .font(.body.weight(.medium))
                    if let rootURL = authentication.rootURL {
                        Text((rootURL.path as NSString).abbreviatingWithTildeInPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
                Spacer()
                if let rootURL = authentication.rootURL {
                    Button(tr("Mostra nel Finder", "Show in Finder")) { Finder.reveal(rootURL) }
                }
                Button(authentication.rootURL == nil ? tr("Scegli cartella…", "Choose folder…") : tr("Cambia…", "Change…")) { authentication.chooseRoot() }
            }
        } header: {
            Text(tr("Cartella dei materiali", "Materials folder"))
        } footer: {
            Text(tr("Ogni corso abilitato viene salvato direttamente qui, nella propria cartella.", "Each enabled course is saved right here, in its own folder."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Background

    private var automaticSection: some View {
        Section {
            Toggle(tr("Sincronizzazione automatica", "Automatic sync"), isOn: Binding(
                get: { authentication.automaticSyncEnabled },
                set: { authentication.setAutomaticSync(enabled: $0) }
            ))
            Picker(tr("Frequenza", "Frequency"), selection: Binding(
                get: { authentication.automaticSyncInterval },
                set: { authentication.setAutomaticSyncInterval($0) }
            )) {
                ForEach(AutomaticSyncOption.allCases) { option in
                    Text(option.title).tag(option.rawValue)
                }
            }
            .disabled(!authentication.automaticSyncEnabled)
        } header: {
            Text(tr("Attività in background", "Background activity"))
        } footer: {
            Text(tr("Tutti i corsi selezionati vengono controllati. Conflitti e modifiche locali non vengono mai sovrascritti automaticamente.", "All selected courses are checked. Conflicts and local changes are never overwritten automatically."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Updates

    private var updatesSection: some View {
        Section(tr("Aggiornamenti", "Updates")) {
            Toggle(tr("Controlla automaticamente gli aggiornamenti", "Check for updates automatically"), isOn: $checksForUpdates)
                .onChange(of: checksForUpdates) { _, newValue in
                    UpdaterController.shared.automaticallyChecksForUpdates = newValue
                }
            LabeledContent(tr("Versione", "Version")) {
                HStack(spacing: 10) {
                    Text(appVersion).foregroundStyle(.secondary).monospacedDigit()
                    Button(tr("Cerca aggiornamenti…", "Check for updates…")) { UpdaterController.shared.checkForUpdates() }
                }
            }
        }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        guard let version = info?["CFBundleShortVersionString"] as? String else { return tr("Sviluppo", "Development") }
        if let build = info?["CFBundleVersion"] as? String { return "\(version) (\(build))" }
        return version
    }
}
