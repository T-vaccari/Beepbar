import SwiftUI
import BeepbarCore

struct BeepbarShellView: View {
    @ObservedObject var authentication: WeBeepAuthenticationController
    @State private var page: Page = .home

    enum Page { case home, settings, conflicts }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                switch page {
                case .home: HomePage(authentication: authentication, open: open)
                case .settings: SettingsPage(authentication: authentication, back: { page = .home })
                case .conflicts: ConflictsPage(authentication: authentication, back: { page = .home })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 680, minHeight: 500)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Beepbar").font(.title3.weight(.semibold))
                Text(page == .home ? "Materiali WeBeep in locale" : page == .settings ? "Impostazioni" : "Risolutore conflitti")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Impostazioni", systemImage: "gearshape") { page = .settings }
                .help("Impostazioni")
            Button(authentication.conflicts.isEmpty ? "Conflitti" : "Conflitti \(authentication.conflicts.count)", systemImage: "exclamationmark.triangle") {
                page = .conflicts
                authentication.refreshConflicts()
            }
            .help("Conflitti aperti: \(authentication.conflicts.count)")
                .overlay(alignment: .topTrailing) {
                    if !authentication.conflicts.isEmpty {
                        Text("\(authentication.conflicts.count)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(3)
                            .background(.red, in: Circle())
                            .offset(x: 5, y: -5)
                    }
                }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func open(_ destination: Page) { page = destination }
}

private struct HomePage: View {
    @ObservedObject var authentication: WeBeepAuthenticationController
    let open: (BeepbarShellView.Page) -> Void
    @State private var editingCourseID: Int64?
    @State private var proposedFolder = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                syncCard
                coursesCard
            }
            .padding(20)
        }
    }

    private var syncCard: some View {
        GroupBox {
            HStack(alignment: .center, spacing: 24) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Stato")
                        .font(.caption).foregroundStyle(.secondary)
                    Label(authentication.syncState.title, systemImage: authentication.syncState.systemImage)
                        .foregroundStyle(statusColor)
                    Text(authentication.syncState.detail)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: 190, alignment: .leading)
                }
                Spacer()
                if authentication.accountState == .connected {
                    Button(authentication.isSyncActive ? "Annulla" : "Sincronizza ora") {
                        if authentication.isSyncActive { authentication.cancelSynchronization() }
                        else { authentication.synchronizeNow() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(authentication.isSyncActive ? false : !authentication.canSynchronize)
                } else {
                    Button("Accedi a WeBeep") { open(.settings) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 5) {
                    Text("Controllo automatico")
                        .font(.caption).foregroundStyle(.secondary)
                    Picker("Controllo automatico", selection: automaticMode) {
                        Text("Solo manuale").tag(0)
                        Text("Ogni 30 min").tag(1800)
                        Text("Ogni ora").tag(3600)
                        Text("Ogni 2 ore").tag(7200)
                        Text("Ogni 4 ore").tag(14400)
                        Text("Una volta al giorno").tag(86400)
                    }
                    .labelsHidden()
                    .frame(width: 145)
                    Text("Tutti i corsi selezionati vengono controllati in background.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .frame(width: 155, alignment: .trailing)
                }
            }
            .padding(4)
        } label: { Text("Sincronizzazione") }
    }

    private var coursesCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Scegli i corsi da sincronizzare.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Aggiorna corsi") { authentication.loadCourses() }
                        .disabled(!authentication.hasStoredCredential || authentication.isLoadingCourses || authentication.isSyncActive)
                }
                if authentication.courses.isEmpty {
                    ContentUnavailableView("Nessun corso caricato", systemImage: "books.vertical", description: Text("Collega WeBeep e aggiorna l’elenco dei corsi."))
                        .frame(height: 130)
                } else {
                    LazyVStack(spacing: 10) {
                    ForEach(authentication.courses) { course in
                        HStack {
                        Toggle("", isOn: Binding(get: { authentication.isCourseEnabled(course) }, set: { authentication.setCourse(course, enabled: $0) }))
                            .labelsHidden()
                            .accessibilityLabel("Includi \(course.displayName)")
                            .toggleStyle(.checkbox)
                            .disabled(authentication.isSyncActive)
                            VStack(alignment: .leading, spacing: 2) {
                                if editingCourseID == course.id {
                                    HStack(spacing: 5) {
                                        TextField("Nome cartella locale", text: $proposedFolder)
                                            .textFieldStyle(.roundedBorder)
                                            .onSubmit { commitFolderRename(for: course) }
                                            .onChange(of: proposedFolder) { authentication.clearRenameError(for: course) }
                                        Button("Conferma", systemImage: "checkmark") { commitFolderRename(for: course) }
                                            .labelStyle(.iconOnly)
                                            .disabled(proposedFolder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                        Button("Annulla", systemImage: "xmark") {
                                            authentication.clearRenameError(for: course)
                                            editingCourseID = nil
                                        }
                                            .labelStyle(.iconOnly)
                                    }
                                } else {
                                    Button {
                                        authentication.clearRenameError(for: course)
                                        proposedFolder = authentication.folder(for: course)
                                        editingCourseID = course.id
                                    } label: {
                                        HStack(spacing: 5) {
                                            Text(authentication.folder(for: course))
                                            Image(systemName: "pencil")
                                                .font(.caption)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    .font(.body)
                                    .lineLimit(1)
                                }
                                Text(course.displayName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                if authentication.renamingCourseID == course.id {
                                    ProgressView().controlSize(.small)
                                }
                                if let error = authentication.courseRenameErrors[course.id] {
                                    Text(error).font(.caption).foregroundStyle(.red)
                                }
                            }
                            .disabled(authentication.renamingCourseID == course.id)
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if course.id != authentication.courses.last?.id { Divider() }
                    }
                    }
                }
            }
            .padding(4)
        } label: { Text("Corsi") }
    }

    private var statusColor: Color {
        switch authentication.syncState {
        case .synced: .green
        case .conflicts, .failed, .recoveryBlocked, .loginRequired, .needsFolder: .orange
        default: .accentColor
        }
    }

    private var automaticMode: Binding<Int> {
        Binding(
            get: { authentication.automaticSyncEnabled ? authentication.automaticSyncInterval : 0 },
            set: { interval in
                authentication.setAutomaticSync(enabled: interval != 0)
                if interval != 0 { authentication.setAutomaticSyncInterval(interval) }
            }
        )
    }

    private func commitFolderRename(for course: RemoteCourseSummary) {
        let folder = proposedFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !folder.isEmpty else { return }
        let current = authentication.folder(for: course).precomposedStringWithCanonicalMapping
        guard folder.precomposedStringWithCanonicalMapping.localizedCaseInsensitiveCompare(current) != .orderedSame else {
            authentication.clearRenameError(for: course)
            editingCourseID = nil
            return
        }
        authentication.renameFolder(for: course, to: folder)
        editingCourseID = nil
    }
}

private struct SettingsPage: View {
    @ObservedObject var authentication: WeBeepAuthenticationController
    let back: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack { Button("Indietro", systemImage: "chevron.left", action: back); Spacer() }
                GroupBox("Account WeBeep") {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(authentication.accountState.title)
                            Text("Il token resta nel Portachiavi macOS.").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if authentication.accountState != .connected {
                            Button(authentication.accountState == .expired ? "Accedi di nuovo" : "Accedi") { authentication.startLogin() }.buttonStyle(.borderedProminent)
                        }
                        Button("Verifica") { authentication.validateConnection() }
                            .disabled(!authentication.hasStoredCredential || authentication.isVerifying)
                    }.padding(4)
                }
                GroupBox("Cartella dei materiali") {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(authentication.rootURL?.path ?? "Nessuna cartella scelta").textSelection(.enabled)
                            Text("Ogni corso abilitato viene salvato direttamente qui, nella propria cartella.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(authentication.rootURL == nil ? "Scegli cartella…" : "Cambia…") { authentication.chooseRoot() }
                    }.padding(4)
                }
                GroupBox("Attività in background") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Sincronizzazione automatica", isOn: Binding(get: { authentication.automaticSyncEnabled }, set: { authentication.setAutomaticSync(enabled: $0) }))
                        Picker("Intervallo", selection: Binding(get: { authentication.automaticSyncInterval }, set: { authentication.setAutomaticSyncInterval($0) })) {
                            Text("30 minuti").tag(1800)
                            Text("1 ora").tag(3600)
                            Text("2 ore").tag(7200)
                            Text("4 ore").tag(14400)
                            Text("Una volta al giorno").tag(86400)
                        }.disabled(!authentication.automaticSyncEnabled)
                        if authentication.automaticSyncInterval == 86_400 {
                            DatePicker("Orario del controllo", selection: Binding(get: { authentication.automaticDailyCheckTime }, set: { authentication.setAutomaticDailyCheckTime($0) }), displayedComponents: .hourAndMinute)
                                .disabled(!authentication.automaticSyncEnabled)
                        }
                        Text("Tutti i corsi selezionati vengono controllati. Conflitti e modifiche locali non vengono mai sovrascritti automaticamente.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(4)
                }
                GroupBox("Aggiornamenti") {
                    HStack {
                        Toggle("Controlla automaticamente", isOn: Binding(
                            get: { UpdaterController.shared.automaticallyChecksForUpdates },
                            set: { UpdaterController.shared.automaticallyChecksForUpdates = $0 }
                        ))
                        Spacer()
                        Button("Cerca aggiornamenti ora…") { UpdaterController.shared.checkForUpdates() }
                    }.padding(4)
                }
            }
            .padding(20)
        }
    }
}

private struct ConflictsPage: View {
    @ObservedObject var authentication: WeBeepAuthenticationController
    let back: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Button("Indietro", systemImage: "chevron.left", action: back); Spacer(); Button("Aggiorna") { authentication.refreshConflicts() } }
            Text("Conflitti").font(.title2.weight(.semibold))
            Text("La versione remota è conservata separatamente: nessun file locale viene mai sovrascritto senza una tua scelta.")
                .font(.caption).foregroundStyle(.secondary)
            if authentication.conflicts.isEmpty {
                ZStack {
                    VStack(spacing: 8) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 38))
                            .foregroundStyle(.secondary)
                        Text("Nessun conflitto aperto").font(.title3.weight(.semibold))
                        Text("Se due versioni dello stesso file cambiano, potrai scegliere quale mantenere qui.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(authentication.conflicts) { conflict in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(conflict.relativePath.value).font(.body.weight(.medium))
                        Text("Versione remota: \(conflict.incomingPath.value)")
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        HStack {
                            Button("Mantieni locale") { authentication.resolve(conflict, with: .keepLocal) }
                            Button("Usa versione remota") { authentication.resolve(conflict, with: .useRemote) }
                                .buttonStyle(.borderedProminent)
                        }
                        .disabled(authentication.resolvingConflictID != nil)
                    }
                    .padding(.vertical, 3)
                }
            }
        }
        .padding(20)
    }
}
