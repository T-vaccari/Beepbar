import SwiftUI
import BeepbarCore

struct SettingsPage: View {
    @ObservedObject var authentication: WeBeepAuthenticationController
    // Sparkle's setting isn't observable; mirror it so the toggle reflects changes immediately.
    @State private var checksForUpdates = UpdaterController.shared.automaticallyChecksForUpdates
    @State private var showSignOutConfirmation = false

    var body: some View {
        Form {
            accountSection
            folderSection
            automaticSection
            updatesSection
        }
        .formStyle(.grouped)
        .confirmationDialog("Disconnettere l'account \(authentication.selectedSite.platformName)?", isPresented: $showSignOutConfirmation, titleVisibility: .visible) {
            Button("Disconnetti", role: .destructive) { authentication.signOut() }
            Button("Annulla", role: .cancel) {}
        } message: {
            Text("Il token salvato viene eliminato da questo Mac. La cartella dei materiali e i file restano dove sono.")
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
                Button("Verifica") { authentication.validateConnection() }
                    .disabled(!authentication.hasStoredCredential || authentication.isVerifying)
                if authentication.hasStoredCredential {
                    Button("Disconnetti…") { showSignOutConfirmation = true }
                        .disabled(authentication.isSyncActive || authentication.isLoadingCourses)
                }
                if authentication.accountState != .connected {
                    Button(authentication.accountState == .expired ? "Accedi di nuovo" : "Accedi") { authentication.startLogin() }
                        .buttonStyle(.borderedProminent)
                        .disabled(authentication.isAuthenticating)
                }
            }
        } header: {
            Text("Account \(authentication.selectedSite.platformName)")
        } footer: {
            Label("Il token resta in locale, protetto da permessi ristretti.", systemImage: "lock.fill")
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
                    Text(authentication.rootURL?.lastPathComponent ?? "Nessuna cartella scelta")
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
                    Button("Mostra nel Finder") { Finder.reveal(rootURL) }
                }
                Button(authentication.rootURL == nil ? "Scegli cartella…" : "Cambia…") { authentication.chooseRoot() }
            }
        } header: {
            Text("Cartella dei materiali")
        } footer: {
            Text("Ogni corso abilitato viene salvato direttamente qui, nella propria cartella.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Background

    private var automaticSection: some View {
        Section {
            Toggle("Sincronizzazione automatica", isOn: Binding(
                get: { authentication.automaticSyncEnabled },
                set: { authentication.setAutomaticSync(enabled: $0) }
            ))
            Picker("Frequenza", selection: Binding(
                get: { authentication.automaticSyncInterval },
                set: { authentication.setAutomaticSyncInterval($0) }
            )) {
                ForEach(AutomaticSyncOption.allCases) { option in
                    Text(option.title).tag(option.rawValue)
                }
            }
            .disabled(!authentication.automaticSyncEnabled)
        } header: {
            Text("Attività in background")
        } footer: {
            Text("Tutti i corsi selezionati vengono controllati. Conflitti e modifiche locali non vengono mai sovrascritti automaticamente.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Updates

    private var updatesSection: some View {
        Section("Aggiornamenti") {
            Toggle("Controlla automaticamente gli aggiornamenti", isOn: $checksForUpdates)
                .onChange(of: checksForUpdates) { _, newValue in
                    UpdaterController.shared.automaticallyChecksForUpdates = newValue
                }
            LabeledContent("Versione") {
                HStack(spacing: 10) {
                    Text(appVersion).foregroundStyle(.secondary).monospacedDigit()
                    Button("Cerca aggiornamenti…") { UpdaterController.shared.checkForUpdates() }
                }
            }
        }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        guard let version = info?["CFBundleShortVersionString"] as? String else { return "Sviluppo" }
        if let build = info?["CFBundleVersion"] as? String { return "\(version) (\(build))" }
        return version
    }
}
