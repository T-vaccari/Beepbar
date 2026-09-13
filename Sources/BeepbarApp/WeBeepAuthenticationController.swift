import AppKit
import Foundation
import Security
import SwiftUI
import UserNotifications
import WebKit
import BeepbarCore

enum AppSyncState: Equatable {
    case starting
    case loginRequired
    case needsFolder
    case readyUnchecked
    case checking
    case syncing
    case cancelling
    case synced(Date)
    case conflicts(Int)
    case failed(String)
    case recoveryBlocked

    var title: String {
        switch self {
        case .starting: "Avvio"
        case .loginRequired: "Accedi a WeBeep"
        case .needsFolder: "Scegli una cartella"
        case .readyUnchecked: "Pronto"
        case .checking: "Controllo aggiornamenti"
        case .syncing: "Sincronizzazione in corso"
        case .cancelling: "Annullamento in corso"
        case .synced: "Sincronizzato"
        case .conflicts(let count): "\(count) conflitti da risolvere"
        case .failed: "Richiede attenzione"
        case .recoveryBlocked: "Intervento richiesto"
        }
    }

    var detail: String {
        switch self {
        case .starting: "Preparazione dello stato locale…"
        case .loginRequired: "Collega il tuo account per iniziare."
        case .needsFolder: "Scegli dove salvare i materiali."
        case .readyUnchecked: "Controlla gli aggiornamenti quando vuoi."
        case .checking: "Verifica delle modifiche remote in corso…"
        case .syncing: "I file locali non vengono mai sovrascritti senza una scelta."
        case .cancelling: "I file incompleti non verranno installati."
        case .synced(let date): "Aggiornato \(date.formatted(date: .abbreviated, time: .shortened))."
        case .conflicts: "Scegli quale versione mantenere nella sezione Conflitti."
        case .failed(let message): message
        case .recoveryBlocked: "Apri Beepbar per completare il recupero locale."
        }
    }

    var systemImage: String {
        switch self {
        case .synced: "checkmark.circle.fill"
        case .checking, .syncing, .cancelling: "arrow.triangle.2.circlepath"
        case .conflicts: "exclamationmark.triangle.fill"
        case .loginRequired, .needsFolder, .failed, .recoveryBlocked: "exclamationmark.circle.fill"
        case .starting, .readyUnchecked: "arrow.triangle.2.circlepath"
        }
    }
}

enum AccountState: Equatable {
    case notConnected
    case connected
    case expired

    var title: String {
        switch self {
        case .notConnected: "Nessun account collegato"
        case .connected: "Account collegato"
        case .expired: "Accesso scaduto"
        }
    }
}

@MainActor final class WeBeepAuthenticationController: NSObject, ObservableObject {
    @Published private(set) var isAuthenticating = false
    @Published private(set) var isVerifying = false
    @Published private(set) var isLoadingCourses = false
    @Published private(set) var courses: [RemoteCourseSummary] = []
    @Published private(set) var selectedCourse: RemoteCourseSummary?
    @Published private(set) var contents: RemoteCourseContents?
    @Published private(set) var isLoadingContents = false
    @Published private(set) var hasStoredCredential: Bool
    @Published private(set) var status = "Avvio Beepbar…"
    @Published private(set) var syncState: AppSyncState = .starting
    @Published private(set) var accountState: AccountState = .notConnected
    @Published private(set) var rootURL: URL?
    @Published private(set) var enabledCourseIDs: Set<Int64>
    @Published private(set) var automaticSyncEnabled: Bool
    @Published private(set) var automaticSyncInterval: Int
    @Published private(set) var recoveryBlocked = false
    @Published private(set) var courseFolders: [Int64: String] = [:]
    @Published private(set) var courseRenameErrors: [Int64: String] = [:]
    @Published private(set) var renamingCourseID: Int64?
    let progressStore = SyncProgressStore()
    @Published private(set) var conflicts: [ConflictRecord] = []
    @Published private(set) var resolvingConflictID: UUID?
    private var loginWindow: LoginWindowController?
    private var pendingToken: String?
    private var siteInfo: WeBeepSiteInfo?
    private var database: SyncDatabase?
    private let operationGate = RootOperationGate()
    private let apiClient: WeBeepAPIClient
    private let credentialService = CredentialService()
    private let notificationCoordinator = SyncNotificationCoordinator()
    private var backgroundScheduler: NSBackgroundActivityScheduler?
    private var syncTask: Task<Void, Never>?
    private var activeOperationID: UUID?
    private var automaticOutcome: AutomaticSyncOutcome = .finished
    private var rootID: UUID?
    private var scheduledConfiguration: BackgroundScheduleConfiguration?

    override init() {
        hasStoredCredential = false
        rootURL = Self.storedRootURL()
        enabledCourseIDs = Set(UserDefaults.standard.stringArray(forKey: Self.enabledCoursesKey)?.compactMap(Int64.init) ?? [])
        automaticSyncEnabled = UserDefaults.standard.bool(forKey: Self.autoSyncKey)
        automaticSyncInterval = Self.validatedAutomaticInterval(UserDefaults.standard.object(forKey: Self.autoSyncIntervalKey) as? Int)
        rootID = Self.storedRootID()
        apiClient = WeBeepAPIClient()
        database = nil
        super.init()
        accountState = hasStoredCredential ? .connected : .notConnected
        setSyncState(.starting)
        let bootstrap = BootstrapService()
        let rootURL = self.rootURL
        let rootID = self.rootID
        let operationGate = self.operationGate
        Task { [weak self] in
            do {
                let result = try await bootstrap.prepare(databaseDirectory: Self.databaseDirectory(), rootURL: rootURL, rootID: rootID, gate: operationGate)
                guard let self else { return }
                self.database = result.database
                self.hasStoredCredential = result.hasStoredCredential
                self.accountState = result.hasStoredCredential ? .connected : .notConnected
                if result.recoveryBlocked {
                    self.recoveryBlocked = true
                    self.setSyncState(.recoveryBlocked)
                } else {
                    await self.restorePersistedSyncState()
                    self.configureBackgroundScheduler()
                }
            } catch {
                self?.setSyncState(.failed("Impossibile preparare lo stato locale. Riapri Beepbar."))
            }
        }
    }

    var menuBarSymbol: String {
        "arrow.triangle.2.circlepath"
    }

    var menuBarTitle: String {
        syncState.title
    }

    var menuBarActionTitle: String {
        if case .syncing = syncState { return "Annulla sincronizzazione" }
        if case .cancelling = syncState { return "Annulla sincronizzazione" }
        if case .conflicts = syncState { return "Apri conflitti" }
        if case .loginRequired = syncState { return "Accedi" }
        if case .failed = syncState, accountState == .expired { return "Accedi di nuovo" }
        return "Sincronizza ora"
    }

    var isSyncActive: Bool {
        activeOperationID != nil
    }

    private func setSyncState(_ newState: AppSyncState) {
        syncState = newState
        status = newState.detail
        if case .synced(let date) = newState, let rootID {
            UserDefaults.standard.set(date.timeIntervalSince1970, forKey: Self.lastSuccessfulReconciliationKey + rootID.uuidString)
        }
    }

    private func restorePersistedSyncState() async {
        guard !recoveryBlocked else { setSyncState(.recoveryBlocked); return }
        guard hasStoredCredential else { setSyncState(.loginRequired); return }
        guard rootURL != nil, let rootID else { setSyncState(.needsFolder); return }
        let open = (try? await database?.conflicts(rootID: rootID)) ?? []
        conflicts = open
        if !open.isEmpty { setSyncState(.conflicts(open.count)); return }
        let timestamp = UserDefaults.standard.double(forKey: Self.lastSuccessfulReconciliationKey + rootID.uuidString)
        setSyncState(timestamp > 0 ? .synced(Date(timeIntervalSince1970: timestamp)) : .readyUnchecked)
    }

    var canSynchronize: Bool {
        hasStoredCredential && rootURL != nil && !enabledCourseIDs.isEmpty && !isSyncActive && !recoveryBlocked
    }

    func refreshOnWindowOpen() {
        guard hasStoredCredential else { return }
        if courses.isEmpty { loadCourses() }
        refreshConflicts()
    }

    func chooseRoot() {
        let panel = NSOpenPanel()
        panel.title = "Scegli la cartella dei materiali Beepbar"
        panel.message = "Beepbar creerà una sottocartella per ogni corso abilitato."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let selectedURL = url.standardizedFileURL
        guard !isSyncActive else { return }
        Task { [weak self] in
            do {
                guard let self, let database else { throw SyncDatabaseError.open }
                _ = try FileStore(root: selectedURL)
                let selectedID = try await database.rootID(canonicalPath: selectedURL.path) ?? UUID()
                try await database.registerRoot(id: selectedID, canonicalPath: selectedURL.path)
                let report = try await operationGate.withLease(.recovering) {
                    try await RecoveryCoordinator(rootID: selectedID, database: database, fileStore: try FileStore(root: selectedURL)).recover()
                }
                guard report.unresolved.isEmpty else { throw SyncDatabaseError.execution }
                rootURL = selectedURL; rootID = selectedID; recoveryBlocked = false
                courseFolders = [:]; conflicts = []
                await restoreScopes(for: courses)
                UserDefaults.standard.set(selectedURL.path, forKey: Self.rootKey)
                UserDefaults.standard.set(selectedID.uuidString, forKey: Self.rootIDKey)
                await self.restorePersistedSyncState()
                self.configureBackgroundScheduler()
            } catch {
                self?.setSyncState(.failed("Non è stato possibile usare questa cartella. Scegline un'altra."))
            }
        }
    }

    func isCourseEnabled(_ course: RemoteCourseSummary) -> Bool {
        enabledCourseIDs.contains(course.id)
    }

    func setCourse(_ course: RemoteCourseSummary, enabled: Bool) {
        guard !isSyncActive else { return }
        if enabled { enabledCourseIDs.insert(course.id) }
        else { enabledCourseIDs.remove(course.id) }
        UserDefaults.standard.set(enabledCourseIDs.map(String.init).sorted(), forKey: Self.enabledCoursesKey)
        configureBackgroundScheduler()
        if let database, let rootID {
            let folder = courseFolders[course.id] ?? defaultFolder(for: course)
            courseFolders[course.id] = folder
            Task { try? await database.upsertScope(SyncScope(rootID: rootID, courseID: course.id, displayName: course.displayName, localFolder: folder, enabled: enabled)) }
        }
    }

    func setAutomaticSync(enabled: Bool) {
        guard !isSyncActive else { return }
        automaticSyncEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.autoSyncKey)
        if enabled { Task { await notificationCoordinator.requestAuthorizationIfNeeded() } }
        configureBackgroundScheduler()
    }
    func setAutomaticSyncInterval(_ seconds: Int) { guard !isSyncActive else { return }; automaticSyncInterval = Self.validatedAutomaticInterval(seconds); UserDefaults.standard.set(automaticSyncInterval, forKey: Self.autoSyncIntervalKey); configureBackgroundScheduler() }

    func renameFolder(for course: RemoteCourseSummary, to newFolder: String) {
        guard let rootURL, let rootID, let database, !recoveryBlocked, !isSyncActive else { return }
        let oldFolder = folder(for: course)
        let trimmedFolder = newFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFolder.isEmpty else {
            courseRenameErrors[course.id] = "Nome cartella non valido."
            return
        }
        courseRenameErrors[course.id] = nil
        renamingCourseID = course.id
        Task { [weak self] in
            defer { self?.renamingCourseID = nil }
            do {
                guard let self else { return }
                let renamer = CourseFolderRenamer(database: database, fileStore: try FileStore(root: rootURL), gate: self.operationGate)
                try await renamer.rename(rootID: rootID, courseID: course.id, from: oldFolder, to: trimmedFolder)
                self.courseFolders[course.id] = trimmedFolder
            } catch {
                self?.courseRenameErrors[course.id] = "Rinomina non riuscita."
            }
        }
    }

    func clearRenameError(for course: RemoteCourseSummary) {
        courseRenameErrors[course.id] = nil
    }

    func synchronizeNow() {
        let selected = courses.filter { enabledCourseIDs.contains($0.id) }
        guard !selected.isEmpty else { setSyncState(.readyUnchecked); return }
        guard let database else { return }
        guard let rootURL, let rootID else { setSyncState(.needsFolder); return }
        guard activeOperationID == nil else { return }
        let operationID = UUID()
        activeOperationID = operationID
        setSyncState(.checking)
        let targets = selected.map { SyncTarget(courseID: $0.id, localFolder: folder(for: $0)) }
        let apiClient = self.apiClient
        let gate = operationGate
        syncTask = Task { [weak self] in
            do {
                guard let self else { return }
                let token = try await self.credentialService.load()
                let coordinator = try SyncCoordinator(rootID: rootID, rootURL: rootURL, database: database, gate: gate, apiClient: apiClient)
                self.beginTransfer(operationID, automatic: false)
                let summary = try await coordinator.synchronize(targets: targets, token: token, mode: .manual) { [weak self] progress in
                    await self?.progressStore.publish(progress)
                }
                await self.completeSync(operationID, summary: summary, automatic: false)
            } catch is CancellationError {
                self?.cancelledSync(operationID)
            } catch let error as WeBeepAPIError where error == .invalidToken {
                await self?.failedSync(operationID, expired: true, automatic: false)
            } catch {
                await self?.failedSync(operationID, expired: false, automatic: false)
            }
        }
    }

    func cancelSynchronization() {
        guard let operationID = activeOperationID else { return }
        guard let syncTask else {
            cancelledSync(operationID)
            return
        }
        syncTask.cancel()
        setSyncState(.cancelling)
    }

    func refreshConflicts() {
        guard !isSyncActive else { return }
        guard let database, let rootID else { conflicts = []; return }
        Task { [weak self] in
            guard let self else { return }
            let found = (try? await database.conflicts(rootID: rootID)) ?? []
            self.conflicts = found
            if !found.isEmpty { self.setSyncState(.conflicts(found.count)) }
            else if case .conflicts = self.syncState { await self.restorePersistedSyncState() }
        }
    }

    func resolve(_ conflict: ConflictRecord, with resolution: ConflictResolution) {
        guard resolvingConflictID == nil, let rootURL, let database, !recoveryBlocked, !isSyncActive else { return }
        resolvingConflictID = conflict.id
        Task { [weak self] in
            defer { self?.resolvingConflictID = nil }
            do {
                guard let self else { return }
                let resolver = ConflictResolver(database: database, fileStore: try FileStore(root: rootURL), gate: self.operationGate)
                switch resolution {
                case .keepLocal:
                    try await resolver.keepLocal(id: conflict.id)
                    self.status = "Conflitto risolto: la modifica locale è stata mantenuta."
                case .useRemote:
                    let result = try await resolver.useRemote(id: conflict.id)
                    guard case .installed = result else {
                        self.status = "Il file locale è cambiato nel frattempo: conflitto lasciato aperto."
                        self.refreshConflicts()
                        return
                    }
                    self.status = "Conflitto risolto: la versione remota è stata installata."
                }
                self.refreshConflicts()
            } catch {
                self?.status = "Impossibile risolvere il conflitto: nessun file locale è stato scartato."
                self?.refreshConflicts()
            }
        }
    }

    func startLogin() {
        guard !isAuthenticating else { return }
        isAuthenticating = true; status = "Autenticazione WeBeep in corso…"
        loginWindow = LoginWindowController { [weak self] result in self?.completeLogin(result) }
        loginWindow?.showWindow(nil)
    }

    func validateConnection() {
        guard !isVerifying else { return }
        isVerifying = true; status = "Verifica connessione WeBeep in corso…"
        Task { [weak self] in
            defer { self?.isVerifying = false }
            do {
                guard let self else { return }
                let token = try await self.credentialService.load()
                let siteInfo = try await self.apiClient.validateToken(token)
                self.siteInfo = siteInfo
                self.accountState = .connected
                self.setSyncState(self.rootURL == nil ? .needsFolder : .readyUnchecked)
                self.configureBackgroundScheduler()
            } catch let error as WeBeepAPIError where error == .invalidToken {
                self?.accountState = .expired
                self?.setSyncState(.failed("La sessione WeBeep è scaduta. Accedi di nuovo."))
                self?.configureBackgroundScheduler()
            } catch {
                self?.setSyncState(.failed("Non è stato possibile verificare WeBeep. Riprova più tardi."))
            }
        }
    }

    func loadCourses() {
        guard !isLoadingCourses, !isSyncActive else { return }
        isLoadingCourses = true; status = "Caricamento corsi in corso…"
        Task { [weak self] in
            defer { self?.isLoadingCourses = false }
            do {
                guard let self else { return }
                let token = try await self.credentialService.load()
                let siteInfo: WeBeepSiteInfo
                if let existing = self.siteInfo {
                    siteInfo = existing
                } else {
                    siteInfo = try await self.apiClient.validateToken(token)
                }
                let courses = try await self.apiClient.fetchCourses(userID: siteInfo.userID, token: token)
                self.siteInfo = siteInfo
                self.courses = courses.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending || ($0.displayName == $1.displayName && $0.id < $1.id) }
                await self.restoreScopes(for: courses)
                self.accountState = .connected
                if case .starting = self.syncState { self.setSyncState(.readyUnchecked) }
            } catch let error as WeBeepAPIError where error == .invalidToken {
                self?.accountState = .expired
                self?.setSyncState(.failed("La sessione WeBeep è scaduta. Accedi di nuovo."))
                self?.configureBackgroundScheduler()
            } catch {
                self?.setSyncState(.failed("Non è stato possibile aggiornare i corsi. Riprova più tardi."))
            }
        }
    }

    private static let rootKey = "io.github.tvaccari.beepbar.root-path.v1"
    private static let rootIDKey = "io.github.tvaccari.beepbar.root-id.v1"
    private static let enabledCoursesKey = "io.github.tvaccari.beepbar.enabled-courses.v1"
    private static let autoSyncKey = "io.github.tvaccari.beepbar.auto-sync.v1"
    private static let autoSyncIntervalKey = "io.github.tvaccari.beepbar.auto-sync-interval.v1"
    private static let lastSuccessfulReconciliationKey = "io.github.tvaccari.beepbar.last-successful-reconciliation.v1."

    private static let automaticIntervals: Set<Int> = [1_800, 3_600, 7_200, 14_400]

    private static func validatedAutomaticInterval(_ value: Int?) -> Int {
        guard let value, automaticIntervals.contains(value) else { return 3_600 }
        return value
    }

    private static func storedRootURL() -> URL? {
        guard let path = UserDefaults.standard.string(forKey: rootKey), !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue ? url : nil
    }

    func selectCourse(_ course: RemoteCourseSummary) { selectedCourse = course; contents = nil }

    func loadContents() {
        guard let selectedCourse, !isLoadingContents else { return }
        let alert = NSAlert(); alert.messageText = "Mostrare i contenuti del corso?"
        alert.informativeText = "Beepbar leggerà sezioni, moduli e nomi file del corso selezionato. Non scaricherà né salverà alcun file."
        alert.addButton(withTitle: "Mostra contenuti"); alert.addButton(withTitle: "Annulla")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        isLoadingContents = true; status = "Caricamento contenuti in corso…"
        Task { [weak self] in
            defer { self?.isLoadingContents = false }
            do {
                guard let self else { return }
                let token = try await self.credentialService.load()
                let contents = try await self.apiClient.fetchContents(courseID: selectedCourse.id, token: token)
                guard self.selectedCourse?.id == selectedCourse.id else { return }
                self.contents = contents
                self.status = "Contenuti caricati solo in memoria."
            } catch { self?.status = "Impossibile caricare i contenuti. Nessun dato locale è stato modificato." }
        }
    }

    func migrateLegacyCredential() {
        let alert = NSAlert()
        alert.messageText = "Migrare la credenziale esistente?"
        alert.informativeText = "Beepbar leggerà una sola volta il vecchio token dal Portachiavi, lo copierà nel nuovo accesso firmato e poi proverà a rimuovere il vecchio elemento."
        alert.addButton(withTitle: "Migra credenziale")
        alert.addButton(withTitle: "Annulla")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let result = try KeychainTokenStore.migrateLegacyCredential()
            hasStoredCredential = true
            status = result == .legacyRetained
                ? "Credenziale migrata. Il vecchio elemento può essere rimosso manualmente dal Portachiavi."
                : "Credenziale migrata nel nuovo accesso firmato."
        } catch {
            status = "Migrazione non riuscita. Il vecchio token non è stato modificato: puoi accedere di nuovo."
        }
    }

    private func completeLogin(_ result: Result<URL, LoginWindowError>) {
        loginWindow = nil; isAuthenticating = false
        siteInfo = nil; courses = []; selectedCourse = nil; contents = nil
        guard case let .success(callback) = result, let token = token(from: callback) else {
            status = "Accesso WeBeep annullato o callback non valido."; pendingToken = nil; return
        }
        pendingToken = token; confirmKeychainSave()
    }

    private func token(from callback: URL) -> String? {
        let prefix = "moodlemobile://token="
        let encoded = callback.absoluteString.hasPrefix(prefix)
            ? String(callback.absoluteString.dropFirst(prefix.count))
            : URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "token" })?.value
        guard let encoded, encoded.utf8.count <= 32_768,
              let payload = encoded.removingPercentEncoding,
              let data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters),
              let decoded = String(data: data, encoding: .utf8) else { return nil }
        let fields = decoded.components(separatedBy: ":::")
        guard (fields.count == 2 || fields.count == 3), fields.allSatisfy({ !$0.isEmpty }) else { return nil }
        return fields[1]
    }

    private func confirmKeychainSave() {
        let alert = NSAlert(); alert.messageText = "Collegare Beepbar a WeBeep?"
        alert.informativeText = "Il token verrà salvato solo nel Portachiavi di macOS. Beepbar non scaricherà materiali in questa verifica."
        alert.addButton(withTitle: "Salva nel Portachiavi"); alert.addButton(withTitle: "Non salvare")
        if alert.runModal() == .alertFirstButtonReturn, let pendingToken {
            do {
                try KeychainTokenStore.save(pendingToken)
                hasStoredCredential = true
                accountState = .connected
                setSyncState(rootURL == nil ? .needsFolder : .readyUnchecked)
                configureBackgroundScheduler()
            }
            catch { status = "Accesso completato, ma il Portachiavi ha rifiutato il token." }
        } else { status = "Accesso completato, token non salvato." }
        self.pendingToken = nil
    }

    private static func storedRootID() -> UUID? {
        UserDefaults.standard.string(forKey: rootIDKey).flatMap(UUID.init(uuidString:))
    }

    private static func databaseDirectory() throws -> URL {
        return try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            .appendingPathComponent("Beepbar", isDirectory: true)
    }

    private func restoreScopes(for courses: [RemoteCourseSummary]) async {
        guard let database, let rootID else { return }
        guard let scopes = try? await database.scopes(rootID: rootID) else { return }
        let remoteIDs = Set(courses.map(\.id))
        let scopesByCourse = Dictionary(uniqueKeysWithValues: scopes.map { ($0.courseID, $0) })
        let defaults = Self.defaultFolders(for: courses)
        enabledCourseIDs = Set(scopes.lazy.filter { $0.enabled && remoteIDs.contains($0.courseID) }.map(\.courseID))
        for course in courses {
            if let scope = scopesByCourse[course.id], !scope.localFolder.isEmpty {
                courseFolders[course.id] = scope.localFolder
            } else {
                courseFolders[course.id] = defaults[course.id] ?? LocalPathPolicy.defaultCourseFolder(course.displayName)
            }
        }
        UserDefaults.standard.set(enabledCourseIDs.map(String.init).sorted(), forKey: Self.enabledCoursesKey)
    }

    func folder(for course: RemoteCourseSummary) -> String {
        courseFolders[course.id] ?? defaultFolder(for: course)
    }

    private func defaultFolder(for course: RemoteCourseSummary) -> String {
        Self.defaultFolders(for: courses)[course.id] ?? LocalPathPolicy.defaultCourseFolder(course.displayName)
    }

    private static func defaultFolders(for courses: [RemoteCourseSummary]) -> [Int64: String] {
        let names = Dictionary(grouping: courses, by: { LocalPathPolicy.defaultCourseFolder($0.displayName).precomposedStringWithCanonicalMapping.lowercased() })
        return Dictionary(uniqueKeysWithValues: courses.map { course in
            let base = LocalPathPolicy.defaultCourseFolder(course.displayName)
            return (course.id, (names[base.precomposedStringWithCanonicalMapping.lowercased()]?.count ?? 0) > 1 ? "\(base) (\(course.id))" : base)
        })
    }

    private func finishReconciliation(failures: Int) async {
        guard let database, let rootID else { return }
        let open = (try? await database.conflicts(rootID: rootID)) ?? []
        conflicts = open
        if failures > 0 {
            setSyncState(.failed("Alcuni materiali non sono stati aggiornati. Riprova più tardi."))
        } else if !open.isEmpty {
            setSyncState(.conflicts(open.count))
        } else {
            setSyncState(.synced(Date()))
        }
    }

    private func configureBackgroundScheduler() {
        let configuration = BackgroundScheduleConfiguration(
            enabled: automaticSyncEnabled,
            interval: automaticSyncInterval,
            connected: accountState == .connected,
            rootConfigured: rootURL != nil,
            enabledCourseCount: enabledCourseIDs.count
        )
        guard configuration != scheduledConfiguration else { return }
        backgroundScheduler?.invalidate()
        backgroundScheduler = nil
        scheduledConfiguration = configuration
        guard configuration.enabled, configuration.connected, configuration.rootConfigured, configuration.enabledCourseCount > 0 else { return }
        let scheduler = NSBackgroundActivityScheduler(identifier: "io.github.tvaccari.beepbar.auto-sync")
        scheduler.repeats = true
        scheduler.interval = TimeInterval(automaticSyncInterval)
        scheduler.tolerance = TimeInterval(automaticSyncInterval) * 0.5
        scheduler.qualityOfService = .utility
        scheduler.schedule { [weak self] completion in
            Task { @MainActor [weak self] in
                let outcome = await self?.runAutomaticSync() ?? .finished
                completion(outcome.schedulerResult)
            }
        }
        backgroundScheduler = scheduler
    }

    private func runAutomaticSync() async -> AutomaticSyncOutcome {
        guard !ProcessInfo.processInfo.isLowPowerModeEnabled else { return .deferred }
        guard activeOperationID == nil else { return .deferred }
        guard let rootURL, let rootID, let database, accountState == .connected, !recoveryBlocked else { return .finished }
        let operationID = UUID()
        activeOperationID = operationID
        automaticOutcome = .finished
        setSyncState(.checking)
        guard let automaticScopes = try? await database.scopes(rootID: rootID, enabledOnly: true), !automaticScopes.isEmpty else {
            guard activeOperationID == operationID else { return .cancelled }
            setSyncState(.readyUnchecked)
            endOperation(operationID)
            return .finished
        }
        guard activeOperationID == operationID else { return .cancelled }
        let targets = automaticScopes.map { SyncTarget(courseID: $0.courseID, localFolder: $0.localFolder) }
        let apiClient = self.apiClient
        let gate = operationGate
        let task = Task { [weak self] in
            do {
                guard let self else { return }
                let token = try await self.credentialService.load()
                let coordinator = try SyncCoordinator(rootID: rootID, rootURL: rootURL, database: database, gate: gate, apiClient: apiClient)
                self.beginTransfer(operationID, automatic: true)
                let summary = try await coordinator.synchronize(targets: targets, token: token, mode: .automatic) { [weak self] progress in
                    await self?.progressStore.publish(progress)
                }
                await self.completeSync(operationID, summary: summary, automatic: true)
            } catch is CancellationError {
                self?.cancelledSync(operationID)
            } catch let error as WeBeepAPIError where error == .invalidToken {
                await self?.failedSync(operationID, expired: true, automatic: true)
            } catch is RootOperationGateError {
                self?.deferredAutomaticSync(operationID)
            } catch {
                await self?.failedSync(operationID, expired: false, automatic: true)
            }
        }
        syncTask = task
        await task.value
        return Task.isCancelled ? .cancelled : automaticOutcome
    }

    private func beginTransfer(_ operationID: UUID, automatic: Bool) {
        guard activeOperationID == operationID else { return }
        progressStore.reset(automatic: automatic)
        setSyncState(.syncing)
    }

    private func completeSync(_ operationID: UUID, summary: SyncProgress, automatic: Bool) async {
        guard activeOperationID == operationID else { return }
        await finishReconciliation(failures: summary.failures)
        if automatic { await notificationCoordinator.notifyAutomaticRun(installed: summary.installed, conflicts: summary.conflicts, failures: summary.failures) }
        endOperation(operationID)
    }

    private func cancelledSync(_ operationID: UUID) {
        guard activeOperationID == operationID else { return }
        setSyncState(.readyUnchecked)
        endOperation(operationID)
    }

    private func deferredAutomaticSync(_ operationID: UUID) {
        guard activeOperationID == operationID else { return }
        automaticOutcome = .deferred
        setSyncState(.readyUnchecked)
        endOperation(operationID)
    }

    private func failedSync(_ operationID: UUID, expired: Bool, automatic: Bool) async {
        guard activeOperationID == operationID else { return }
        if expired {
            accountState = .expired
            setSyncState(.failed("La sessione WeBeep è scaduta. Accedi di nuovo."))
            configureBackgroundScheduler()
        } else {
            setSyncState(.failed(automatic ? "Il controllo automatico non è riuscito. I file locali non sono stati modificati." : "Non è stato possibile controllare gli aggiornamenti. I file locali non sono stati modificati."))
            if automatic { await notificationCoordinator.notifyAutomaticRun(installed: 0, conflicts: 0, failures: 1) }
        }
        endOperation(operationID)
    }

    private func endOperation(_ operationID: UUID) {
        guard activeOperationID == operationID else { return }
        activeOperationID = nil
        syncTask = nil
    }

}

private struct BackgroundScheduleConfiguration: Equatable {
    let enabled: Bool
    let interval: Int
    let connected: Bool
    let rootConfigured: Bool
    let enabledCourseCount: Int
}

@MainActor final class SyncProgressStore: ObservableObject {
    @Published private(set) var progress = SyncProgress(completed: 0, total: 0, installed: 0, preservedLocal: 0, unchanged: 0, conflicts: 0, failures: 0)
    private var relay = SyncProgressRelay(interval: .milliseconds(200))

    func reset(automatic: Bool) {
        relay = SyncProgressRelay(interval: automatic ? .seconds(1) : .milliseconds(200))
        progress = SyncProgress(completed: 0, total: 0, installed: 0, preservedLocal: 0, unchanged: 0, conflicts: 0, failures: 0)
    }
    func publish(_ value: SyncProgress) async {
        guard let update = await relay.next(value) else { return }
        progress = update
    }
}

private actor SyncProgressRelay {
    private let clock = ContinuousClock()
    private let interval: Duration
    private var lastPublication: ContinuousClock.Instant?
    private var lastCompleted = 0

    init(interval: Duration) { self.interval = interval }

    func next(_ progress: SyncProgress) -> SyncProgress? {
        guard progress.completed >= lastCompleted else { return nil }
        let now = clock.now
        let requiredInterval: Duration = progress.total > 0 && progress.completed == progress.total ? .zero : interval
        guard lastPublication == nil || lastPublication!.duration(to: now) >= requiredInterval else { return nil }
        lastPublication = now
        lastCompleted = progress.completed
        return progress
    }
}

private actor CredentialService {
    func load() throws -> String { try KeychainTokenStore.load() }
}

private actor BootstrapService {
    struct Result: Sendable {
        let database: SyncDatabase
        let recoveryBlocked: Bool
        let hasStoredCredential: Bool
    }

    func prepare(databaseDirectory: URL, rootURL: URL?, rootID: UUID?, gate: RootOperationGate) async throws -> Result {
        try FileManager.default.createDirectory(at: databaseDirectory, withIntermediateDirectories: true)
        let database = try SyncDatabase(url: databaseDirectory.appendingPathComponent("sync.sqlite"))
        let hasStoredCredential = KeychainTokenStore.hasStoredCredential()
        guard let rootURL, let rootID else { return Result(database: database, recoveryBlocked: false, hasStoredCredential: hasStoredCredential) }
        try await database.registerRoot(id: rootID, canonicalPath: rootURL.path)
        let report = try await gate.withLease(.recovering) {
            try await RecoveryCoordinator(rootID: rootID, database: database, fileStore: try FileStore(root: rootURL)).recover()
        }
        return Result(database: database, recoveryBlocked: !report.unresolved.isEmpty, hasStoredCredential: hasStoredCredential)
    }
}

private actor SyncNotificationCoordinator {
    private var lastErrorSignature: String?

    func requestAuthorizationIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    func notifyAutomaticRun(installed: Int, conflicts: Int, failures: Int) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized else { return }
        if conflicts > 0 {
            await send(center, title: "Conflitti da risolvere", body: "Beepbar ha conservato separatamente \(conflicts) versione/i remota/e.", identifier: "beepbar-conflicts-\(UUID().uuidString)")
        }
        if failures > 0 {
            let signature = "automatic-sync-failure"
            guard lastErrorSignature != signature else { return }
            lastErrorSignature = signature
            await send(center, title: "Sincronizzazione non completata", body: "Alcuni materiali non sono stati aggiornati. Apri Beepbar per i dettagli.", identifier: "beepbar-error-\(UUID().uuidString)")
        } else {
            lastErrorSignature = nil
            if installed > 0 {
                await send(center, title: "Nuovi materiali disponibili", body: "Beepbar ha aggiunto \(installed) materiale/i nella cartella scelta.", identifier: "beepbar-new-files-\(UUID().uuidString)")
            }
        }
    }

    private func send(_ center: UNUserNotificationCenter, title: String, body: String, identifier: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        try? await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }
}

enum LoginWindowError: Error { case cancelled }

private enum AutomaticSyncOutcome {
    case finished, deferred, cancelled

    var schedulerResult: NSBackgroundActivityScheduler.Result {
        switch self {
        case .finished: .finished
        case .deferred: .deferred
        case .cancelled: .finished
        }
    }
}

@MainActor final class LoginWindowController: NSWindowController, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    private enum Phase { case signingIn, launchingMobile, finished }
    private var phase: Phase = .signingIn
    private var completion: ((Result<URL, LoginWindowError>) -> Void)?
    private let webView: WKWebView

    init(completion: @escaping (Result<URL, LoginWindowError>) -> Void) {
        self.completion = completion
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 680), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Accesso WeBeep"; window.contentView = webView
        super.init(window: window); window.delegate = self; webView.navigationDelegate = self; webView.uiDelegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        webView.load(URLRequest(url: URL(string: "https://webeep.polimi.it/auth/shibboleth/index.php")!))
    }

    func windowWillClose(_ notification: Notification) { finish(.failure(.cancelled)) }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if url.scheme == "moodlemobile" {
            decisionHandler(.cancel); guard phase == .launchingMobile else { return }; webView.stopLoading(); finish(.success(url)); return
        }
        guard url.scheme == "https" else { decisionHandler(.cancel); return }
        if phase == .signingIn, url.host?.lowercased() == "webeep.polimi.it", url.path == "/my" || url.path == "/my/" {
            phase = .launchingMobile; decisionHandler(.cancel)
            let url = URL(string: "https://webeep.polimi.it/admin/tool/mobile/launch.php?service=moodle_mobile_app&passport=\(UUID().uuidString)")!
            webView.load(URLRequest(url: url)); return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard action.targetFrame == nil, let url = action.request.url, url.scheme == "https" else { return nil }
        webView.load(action.request); return nil
    }

    private func finish(_ result: Result<URL, LoginWindowError>) {
        guard phase != .finished else { return }; phase = .finished; webView.stopLoading(); webView.navigationDelegate = nil; webView.uiDelegate = nil
        let completion = completion; self.completion = nil; completion?(result); window?.close()
    }
}

private enum KeychainTokenStore {
    private static let account = "webeep.mobile.token"
    private static let legacyService = "io.github.tvaccari.beepbar"
    private static let service = "io.github.tvaccari.beepbar.auth.local.v2"

    enum MigrationResult { case migrated, legacyRetained }

    static func save(_ token: String) throws {
        let query = currentQuery()
        let attributes: [String: Any] = [kSecValueData as String: Data(token.utf8), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let result = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if result == errSecSuccess { return }; guard result == errSecItemNotFound else { throw KeychainError.write }
        var item = query; attributes.forEach { item[$0.key] = $0.value }; guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw KeychainError.write }
    }

    static func load() throws -> String {
        var query = currentQuery()
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else { throw KeychainError.read }
        return token
    }

    static func hasStoredCredential() -> Bool {
        (try? load()) != nil
    }

    static func migrateLegacyCredential() throws -> MigrationResult {
        guard !hasStoredCredential() else { return .migrated }
        let legacyToken = try loadLegacyCredential()
        try addLocalCredential(legacyToken)
        guard try load() == legacyToken else { throw KeychainError.read }
        let deletion = SecItemDelete(legacyQuery() as CFDictionary)
        return deletion == errSecSuccess || deletion == errSecItemNotFound ? .migrated : .legacyRetained
    }

    private static func currentQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private static func legacyQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: legacyService, kSecAttrAccount as String: account]
    }

    private static func loadLegacyCredential() throws -> String {
        var query = legacyQuery()
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else { throw KeychainError.read }
        return token
    }

    private static func addLocalCredential(_ token: String) throws {
        var item = currentQuery()
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw KeychainError.write }
    }
}
private enum KeychainError: Error { case write, read }
