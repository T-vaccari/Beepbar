import AppKit
import Foundation
import LocalAuthentication
import Security
import SwiftUI
@preconcurrency import UserNotifications
import WebKit
import BeepbarCore

enum AppFailure: Equatable {
    case authenticationExpired
    case connectivity
    case serviceUnavailable
    case incompatibleResponse
    case keychainAuthorizationRequired
    case keychainUnavailable
    case partialSync
    case local(String)

    var title: String {
        switch self {
        case .authenticationExpired: "Accesso scaduto"
        case .connectivity: "Connessione assente"
        case .serviceUnavailable: "WeBeep non disponibile"
        case .incompatibleResponse: "Problema con WeBeep"
        case .keychainAuthorizationRequired: "Autorizzazione richiesta"
        case .keychainUnavailable: "Portachiavi non disponibile"
        case .partialSync: "Sincronizzazione incompleta"
        case .local: "Richiede attenzione"
        }
    }

    var detail: String {
        switch self {
        case .authenticationExpired: "Accedi di nuovo per riprendere la sincronizzazione."
        case .connectivity: "Controlla la connessione. Beepbar riproverà automaticamente."
        case .serviceUnavailable: "WeBeep non risponde. I materiali locali restano disponibili."
        case .incompatibleResponse: "WeBeep ha restituito una risposta inattesa. Riprova più tardi."
        case .keychainAuthorizationRequired: "Apri Beepbar e autorizza l'accesso al Portachiavi."
        case .keychainUnavailable: "Beepbar non riesce ad accedere al Portachiavi. Riprova più tardi."
        case .partialSync: "Alcuni materiali non sono stati aggiornati. I file esistenti sono al sicuro."
        case .local(let message): message
        }
    }
}

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
    case failed(AppFailure)
    case recoveryBlocked

    var title: String {
        switch self {
        case .starting: "Avvio"
        case .loginRequired: "Accedi a WeBeep"
        case .needsFolder: "Apri Impostazioni"
        case .readyUnchecked: "Pronto"
        case .checking: "Controllo aggiornamenti"
        case .syncing: "Sincronizzazione in corso"
        case .cancelling: "Annullamento in corso"
        case .synced: "Sincronizzato"
        case .conflicts(let count): "\(count) conflitti da risolvere"
        case .failed(let failure): failure.title
        case .recoveryBlocked: "Intervento richiesto"
        }
    }

    var detail: String {
        switch self {
        case .starting: "Preparazione dello stato locale…"
        case .loginRequired: "Collega il tuo account per iniziare."
        case .needsFolder: "Scegli la cartella dei materiali nelle Impostazioni."
        case .readyUnchecked: "Controlla gli aggiornamenti quando vuoi."
        case .checking: "Verifica delle modifiche remote in corso…"
        case .syncing: "I file locali non vengono mai sovrascritti senza una scelta."
        case .cancelling: "I file incompleti non verranno installati."
        case .synced(let date): "Aggiornato \(date.formatted(date: .abbreviated, time: .shortened))."
        case .conflicts: "Scegli quale versione mantenere nella sezione Conflitti."
        case .failed(let failure): failure.detail
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
    @Published private(set) var automaticDailyCheckTime: Date
    @Published private(set) var recoveryBlocked = false
    @Published private(set) var courseFolders: [Int64: String] = [:]
    @Published private(set) var courseRenameErrors: [Int64: String] = [:]
    @Published private(set) var renamingCourseID: Int64?
    let progressStore = SyncProgressStore()
    @Published private(set) var conflicts: [ConflictRecord] = []
    @Published private(set) var resolvingConflictID: UUID?
    private var loginWindow: LoginWindowController?
    private var siteInfo: WeBeepSiteInfo?
    private var database: SyncDatabase?
    private let operationGate = RootOperationGate()
    private let apiClient: WeBeepAPIClient
    private let credentialVault = CredentialVault(read: KeychainTokenStore.load, write: KeychainTokenStore.save)
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
        automaticDailyCheckTime = Self.dailyTime(UserDefaults.standard.object(forKey: Self.autoSyncDailyTimeKey) as? Int)
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
            let trace = PerformanceTrace.shared.begin("bootstrap.total", category: .bootstrap)
            defer { PerformanceTrace.shared.end("bootstrap.total", category: .bootstrap, state: trace) }
            do {
                let result = try await bootstrap.prepare(databaseDirectory: Self.databaseDirectory(), rootURL: rootURL, rootID: rootID, gate: operationGate)
                guard let self else { return }
                self.database = result.database
                if result.recoveryBlocked {
                    self.recoveryBlocked = true
                    self.setSyncState(.recoveryBlocked)
                } else {
                    switch result.credential {
                    case .present:
                        self.hasStoredCredential = true
                        if UserDefaults.standard.bool(forKey: Self.credentialExpiredKey) {
                            self.accountState = .expired
                            self.setSyncState(.failed(.authenticationExpired))
                        } else {
                            self.accountState = .connected
                            await self.restorePersistedSyncState()
                        }
                        self.configureBackgroundScheduler()
                    case .absent:
                        self.hasStoredCredential = false
                        self.accountState = .notConnected
                        await self.restorePersistedSyncState()
                        self.configureBackgroundScheduler()
                    case .unavailable(let error):
                        await self.handleKeychainError(error)
                    }
                }
            } catch {
                self?.setSyncState(.failed(.local("Impossibile preparare lo stato locale. Riapri Beepbar.")))
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
        switch menuBarAction {
        case .cancelSync: "Annulla sincronizzazione"
        case .openConflicts: "Apri conflitti"
        case .signIn: accountState == .expired ? "Accedi di nuovo" : "Accedi"
        case .authorizeKeychain: "Autorizza accesso"
        case .retryKeychain: "Riprova"
        case .openSettings: "Apri Impostazioni"
        case .synchronize: "Sincronizza ora"
        }
    }

    private var menuBarAction: MenuBarAction {
        let account: MenuBarAccountCondition
        if case .failed(.keychainAuthorizationRequired) = syncState {
            account = .keychainAuthorizationRequired
        } else if case .failed(.keychainUnavailable) = syncState {
            account = .keychainUnavailable
        } else if accountState != .connected || !hasStoredCredential {
            account = .loginRequired
        } else {
            account = .connected
        }
        return MenuBarActionPolicy.action(
            syncActive: isSyncActive,
            hasConflicts: !conflicts.isEmpty,
            account: account,
            hasRoot: rootURL != nil
        )
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
        guard accountState != .expired else { setSyncState(.failed(.authenticationExpired)); return }
        guard hasStoredCredential else { setSyncState(.loginRequired); return }
        guard rootURL != nil, let rootID else { setSyncState(.needsFolder); return }
        let open = (try? await database?.conflicts(rootID: rootID)) ?? []
        conflicts = open
        if !open.isEmpty { setSyncState(.conflicts(open.count)); return }
        let timestamp = UserDefaults.standard.double(forKey: Self.lastSuccessfulReconciliationKey + rootID.uuidString)
        setSyncState(timestamp > 0 ? .synced(Date(timeIntervalSince1970: timestamp)) : .readyUnchecked)
    }

    var canSynchronize: Bool {
        accountState == .connected && hasStoredCredential && rootURL != nil && !enabledCourseIDs.isEmpty && !isSyncActive && !recoveryBlocked
    }

    func performMenuBarAction() {
        switch menuBarAction {
        case .cancelSync: cancelSynchronization()
        case .openConflicts: ConflictWindowController.shared.show(self)
        case .signIn: startLogin()
        case .authorizeKeychain, .retryKeychain: validateConnection()
        case .openSettings: ConfigurationWindowController.shared.show(self)
        case .synchronize: synchronizeNow()
        }
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
                self?.setSyncState(.failed(.local("Non è stato possibile usare questa cartella. Scegline un'altra.")))
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
    func setAutomaticDailyCheckTime(_ time: Date) {
        guard !isSyncActive else { return }
        automaticDailyCheckTime = Self.dailyTime(Self.secondsSinceMidnight(time))
        UserDefaults.standard.set(Self.secondsSinceMidnight(automaticDailyCheckTime), forKey: Self.autoSyncDailyTimeKey)
        configureBackgroundScheduler()
    }

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
                let token = try await self.credentialVault.load()
                let coordinator = try SyncCoordinator(rootID: rootID, rootURL: rootURL, database: database, gate: gate, apiClient: apiClient)
                await self.beginTransfer(operationID, automatic: false)
                let summary = try await coordinator.synchronize(targets: targets, token: token, mode: .manual) { [weak self] progress in
                    await self?.progressStore.publish(progress)
                }
                await self.completeSync(operationID, summary: summary, automatic: false)
            } catch is CancellationError {
                self?.cancelledSync(operationID)
            } catch let error as WeBeepAPIError {
                await self?.failedSync(operationID, error: error, automatic: false)
            } catch let error as KeychainError {
                await self?.handleKeychainError(error, background: false)
                self?.endOperation(operationID)
            } catch {
                await self?.failedSync(operationID, error: nil, automatic: false)
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
                let token = try await self.credentialVault.load()
                let siteInfo = try await self.apiClient.validateToken(token)
                self.siteInfo = siteInfo
                self.accountState = .connected
                UserDefaults.standard.removeObject(forKey: Self.credentialExpiredKey)
                self.notificationCoordinator.clearFailure()
                self.setSyncState(self.rootURL == nil ? .needsFolder : .readyUnchecked)
                self.configureBackgroundScheduler()
            } catch let error as WeBeepAPIError {
                await self?.handleServiceFailure(error, automatic: false)
            } catch let error as KeychainError {
                await self?.handleKeychainError(error, background: false)
            } catch {
                self?.setSyncState(.failed(.local("Non è stato possibile verificare WeBeep. Riprova più tardi.")))
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
                let token = try await self.credentialVault.load()
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
                UserDefaults.standard.removeObject(forKey: Self.credentialExpiredKey)
                self.notificationCoordinator.clearFailure()
                await self.restorePersistedSyncState()
            } catch let error as WeBeepAPIError {
                await self?.handleServiceFailure(error, automatic: false)
            } catch let error as KeychainError {
                await self?.handleKeychainError(error, background: false)
            } catch {
                self?.setSyncState(.failed(.local("Non è stato possibile aggiornare i corsi. Riprova più tardi.")))
            }
        }
    }

    private static let rootKey = "io.github.tvaccari.beepbar.root-path.v1"
    private static let rootIDKey = "io.github.tvaccari.beepbar.root-id.v1"
    private static let enabledCoursesKey = "io.github.tvaccari.beepbar.enabled-courses.v1"
    private static let autoSyncKey = "io.github.tvaccari.beepbar.auto-sync.v1"
    private static let autoSyncIntervalKey = "io.github.tvaccari.beepbar.auto-sync-interval.v1"
    private static let autoSyncDailyTimeKey = "io.github.tvaccari.beepbar.auto-sync-daily-time.v1"
    private static let lastSuccessfulReconciliationKey = "io.github.tvaccari.beepbar.last-successful-reconciliation.v1."
    private static let credentialExpiredKey = "io.github.tvaccari.beepbar.credential-expired.v1"

    private static let automaticIntervals: Set<Int> = [1_800, 3_600, 7_200, 14_400, 86_400]

    private static func validatedAutomaticInterval(_ value: Int?) -> Int {
        guard let value, automaticIntervals.contains(value) else { return 3_600 }
        return value
    }

    private static func dailyTime(_ seconds: Int?) -> Date {
        let valid = min(max(seconds ?? 9 * 3_600, 0), 86_399)
        return Calendar.current.startOfDay(for: Date()).addingTimeInterval(TimeInterval(valid))
    }

    private static func secondsSinceMidnight(_ date: Date) -> Int {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 3_600 + (components.minute ?? 0) * 60
    }

    private static func secondsUntilNextDailyCheck(_ time: Date, now: Date = Date()) -> TimeInterval {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.hour, .minute], from: time)
        let today = calendar.date(bySettingHour: components.hour ?? 0, minute: components.minute ?? 0, second: 0, of: now) ?? now
        let next = today > now ? today : calendar.date(byAdding: .day, value: 1, to: today) ?? today
        return max(next.timeIntervalSince(now), 60)
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
                let token = try await self.credentialVault.load()
                let contents = try await self.apiClient.fetchContents(courseID: selectedCourse.id, token: token)
                guard self.selectedCourse?.id == selectedCourse.id else { return }
                self.contents = contents
                self.status = "Contenuti pronti."
            } catch let error as WeBeepAPIError {
                await self?.handleServiceFailure(error, automatic: false)
            } catch let error as KeychainError {
                await self?.handleKeychainError(error, background: false)
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
            Task { [weak self] in
                guard let self else { return }
                await self.credentialVault.invalidate()
                self.hasStoredCredential = true
                self.accountState = .connected
                UserDefaults.standard.removeObject(forKey: Self.credentialExpiredKey)
                self.notificationCoordinator.clearFailure()
                self.setSyncState(self.rootURL == nil ? .needsFolder : .readyUnchecked)
                self.configureBackgroundScheduler()
                self.status = result == .legacyRetained
                    ? "Credenziale migrata. Il vecchio elemento può essere rimosso manualmente dal Portachiavi."
                    : "Credenziale migrata nel nuovo accesso firmato."
            }
        } catch {
            status = "Migrazione non riuscita. Il vecchio token non è stato modificato: puoi accedere di nuovo."
        }
    }

    private func completeLogin(_ result: Result<URL, LoginWindowError>) {
        loginWindow = nil; isAuthenticating = false
        siteInfo = nil; courses = []; selectedCourse = nil; contents = nil
        guard case let .success(callback) = result, let token = token(from: callback) else {
            status = "Accesso WeBeep annullato o callback non valido."; return
        }
        Task { [weak self] in
            do {
                guard let self else { return }
                let siteInfo = try await self.apiClient.validateToken(token)
                try await self.credentialVault.save(token)
                self.siteInfo = siteInfo
                self.hasStoredCredential = true
                self.accountState = .connected
                UserDefaults.standard.removeObject(forKey: Self.credentialExpiredKey)
                self.notificationCoordinator.clearFailure()
                self.setSyncState(self.rootURL == nil ? .needsFolder : .readyUnchecked)
                self.configureBackgroundScheduler()
            } catch let error as WeBeepAPIError where error == .invalidToken {
                self?.status = "Il token ricevuto non è valido. Accedi di nuovo a WeBeep."
            } catch {
                self?.status = "Impossibile verificare l'accesso WeBeep. Il token non è stato salvato."
            }
        }
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
                let replacement = LocalPathPolicy.generatedCourseFolderReplacement(
                    storedFolder: scope.localFolder,
                    storedCourseName: scope.displayName,
                    currentCourseName: course.displayName,
                    courseID: course.id
                )
                if let replacement, let rootURL {
                    do {
                        let renamer = CourseFolderRenamer(database: database, fileStore: try FileStore(root: rootURL), gate: operationGate)
                        try await renamer.rename(rootID: rootID, courseID: course.id, from: scope.localFolder, to: replacement)
                        courseFolders[course.id] = replacement
                        try await database.upsertScope(SyncScope(
                            rootID: rootID,
                            courseID: course.id,
                            displayName: course.displayName,
                            localFolder: replacement,
                            enabled: scope.enabled,
                            managedDirectory: scope.managedDirectory
                        ))
                    } catch {
                        courseFolders[course.id] = scope.localFolder
                    }
                } else {
                    courseFolders[course.id] = scope.localFolder
                    if scope.displayName != course.displayName {
                        try? await database.upsertScope(SyncScope(
                            rootID: rootID,
                            courseID: course.id,
                            displayName: course.displayName,
                            localFolder: scope.localFolder,
                            enabled: scope.enabled,
                            managedDirectory: scope.managedDirectory
                        ))
                    }
                }
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
            let duplicate = (names[base.precomposedStringWithCanonicalMapping.lowercased()]?.count ?? 0) > 1
            return (course.id, duplicate ? LocalPathPolicy.component(course.displayName) : base)
        })
    }

    private func finishReconciliation(failures: Int) async {
        guard let database, let rootID else { return }
        let open = (try? await database.conflicts(rootID: rootID)) ?? []
        conflicts = open
        if failures > 0 {
            setSyncState(.failed(.partialSync))
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
            dailyTime: Self.secondsSinceMidnight(automaticDailyCheckTime),
            connected: accountState == .connected,
            rootConfigured: rootURL != nil,
            enabledCourseCount: enabledCourseIDs.count,
            recoveryBlocked: recoveryBlocked
        )
        guard configuration != scheduledConfiguration else { return }
        backgroundScheduler?.invalidate()
        backgroundScheduler = nil
        scheduledConfiguration = configuration
        let policy = BackgroundScheduleInput(
            automaticSyncEnabled: configuration.enabled,
            hasCredential: configuration.connected,
            hasRoot: configuration.rootConfigured,
            enabledCourseCount: configuration.enabledCourseCount,
            recoveryBlocked: recoveryBlocked
        )
        guard BackgroundSchedulePolicy.shouldSchedule(policy) else { return }
        let scheduler = NSBackgroundActivityScheduler(identifier: "io.github.tvaccari.beepbar.auto-sync")
        let isDaily = automaticSyncInterval == 86_400
        scheduler.repeats = !isDaily
        scheduler.interval = isDaily ? Self.secondsUntilNextDailyCheck(automaticDailyCheckTime) : TimeInterval(automaticSyncInterval)
        scheduler.tolerance = isDaily ? 3_600 : TimeInterval(automaticSyncInterval) * 0.5
        scheduler.qualityOfService = .utility
        scheduler.schedule { [weak self] completion in
            Task { @MainActor [weak self] in
                let trace = PerformanceTrace.shared.begin("scheduler.callback", category: .scheduler)
                defer { PerformanceTrace.shared.end("scheduler.callback", category: .scheduler, state: trace) }
                let outcome = await self?.runAutomaticSync() ?? .finished
                completion(outcome.schedulerResult)
                if self?.automaticSyncInterval == 86_400 {
                    self?.backgroundScheduler?.invalidate()
                    self?.backgroundScheduler = nil
                    self?.scheduledConfiguration = nil
                    self?.configureBackgroundScheduler()
                }
            }
        }
        backgroundScheduler = scheduler
    }

    private func runAutomaticSync() async -> AutomaticSyncOutcome {
        guard !ProcessInfo.processInfo.isLowPowerModeEnabled else { return .finished }
        guard activeOperationID == nil else { return .finished }
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
                let token = try await self.credentialVault.load(.nonInteractive)
                let coordinator = try SyncCoordinator(rootID: rootID, rootURL: rootURL, database: database, gate: gate, apiClient: apiClient)
                await self.beginTransfer(operationID, automatic: true)
                let summary = try await coordinator.synchronize(targets: targets, token: token, mode: .automatic) { [weak self] progress in
                    await self?.progressStore.publish(progress)
                }
                await self.completeSync(operationID, summary: summary, automatic: true)
            } catch is CancellationError {
                self?.cancelledSync(operationID)
            } catch let error as WeBeepAPIError {
                await self?.failedSync(operationID, error: error, automatic: true)
            } catch let error as KeychainError {
                await self?.handleKeychainError(error, background: true)
                self?.endOperation(operationID)
            } catch is RootOperationGateError {
                self?.deferredAutomaticSync(operationID)
            } catch {
                await self?.failedSync(operationID, error: nil, automatic: true)
            }
        }
        syncTask = task
        await task.value
        return Task.isCancelled ? .cancelled : automaticOutcome
    }

    private func beginTransfer(_ operationID: UUID, automatic: Bool) async {
        guard activeOperationID == operationID else { return }
        await progressStore.reset(automatic: automatic)
        setSyncState(.syncing)
    }

    private func completeSync(_ operationID: UUID, summary: SyncProgress, automatic: Bool) async {
        guard activeOperationID == operationID else { return }
        await finishReconciliation(failures: summary.failures)
        if automatic { await notificationCoordinator.notifyAutomaticRun(installed: summary.installed, conflicts: conflicts, failures: summary.failures) }
        if summary.failures == 0 { notificationCoordinator.clearFailure() }
        configureBackgroundScheduler()
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

    private func failedSync(_ operationID: UUID, error: WeBeepAPIError?, automatic: Bool) async {
        guard activeOperationID == operationID else { return }
        if let error {
            await handleServiceFailure(error, automatic: automatic)
        } else {
            setSyncState(.failed(.partialSync))
            if automatic { await notificationCoordinator.notify(issue: .partialSync) }
        }
        endOperation(operationID)
    }

    private func handleServiceFailure(_ error: WeBeepAPIError, automatic: Bool) async {
        switch SyncServiceFailure(error) {
        case .authenticationExpired:
            await expireCredential(notify: automatic)
        case .connectivity:
            setSyncState(.failed(.connectivity))
        case .serviceUnavailable:
            setSyncState(.failed(.serviceUnavailable))
            if automatic { await notificationCoordinator.notify(issue: .serviceUnavailable) }
        case .incompatibleResponse:
            setSyncState(.failed(.incompatibleResponse))
            if automatic { await notificationCoordinator.notify(issue: .incompatibleResponse) }
        }
    }

    private func expireCredential(notify: Bool = false) async {
        await credentialVault.invalidate()
        UserDefaults.standard.set(true, forKey: Self.credentialExpiredKey)
        accountState = .expired
        setSyncState(.failed(.authenticationExpired))
        if notify { await notificationCoordinator.notify(issue: .authenticationExpired) }
        configureBackgroundScheduler()
    }

    private func handleKeychainError(_ error: KeychainError, background: Bool = false) async {
        await credentialVault.invalidate()
        switch error {
        case .absent, .corrupt:
            hasStoredCredential = false
            accountState = .notConnected
            setSyncState(.loginRequired)
        case .interactionRequired, .accessDenied:
            setSyncState(.failed(.keychainAuthorizationRequired))
            if background {
                backgroundScheduler?.invalidate()
                backgroundScheduler = nil
                scheduledConfiguration = nil
                return
            }
        case .write, .read:
            setSyncState(.failed(.keychainUnavailable))
        }
        configureBackgroundScheduler()
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
    let dailyTime: Int
    let connected: Bool
    let rootConfigured: Bool
    let enabledCourseCount: Int
    let recoveryBlocked: Bool
}

@MainActor final class SyncProgressStore: ObservableObject {
    @Published private(set) var progress = SyncProgress(completed: 0, total: 0, installed: 0, preservedLocal: 0, unchanged: 0, conflicts: 0, failures: 0)
    private let relay = SyncProgressRelay()

    func reset(automatic: Bool) async {
        await relay.reset(interval: automatic ? .seconds(1) : .milliseconds(200))
        progress = SyncProgress(completed: 0, total: 0, installed: 0, preservedLocal: 0, unchanged: 0, conflicts: 0, failures: 0)
    }
    nonisolated func publish(_ value: SyncProgress) async {
        guard let update = await relay.next(value) else { return }
        await receive(update)
    }

    private func receive(_ update: SyncProgress) {
        progress = update
    }
}

private actor SyncProgressRelay {
    private let clock = ContinuousClock()
    private var throttle = SyncProgressThrottle(minimumInterval: .milliseconds(200))

    func reset(interval: Duration) {
        throttle = SyncProgressThrottle(minimumInterval: interval)
    }

    func next(_ progress: SyncProgress) -> SyncProgress? {
        throttle.accept(progress, now: clock.now)
    }
}

private actor BootstrapService {
    struct Result: Sendable {
        let database: SyncDatabase
        let recoveryBlocked: Bool
        let credential: CredentialStatus
    }

    enum CredentialStatus: Sendable {
        case present
        case absent
        case unavailable(KeychainError)
    }

    func prepare(databaseDirectory: URL, rootURL: URL?, rootID: UUID?, gate: RootOperationGate) async throws -> Result {
        let trace = PerformanceTrace.shared.begin("bootstrap.databaseRecovery", category: .bootstrap)
        defer { PerformanceTrace.shared.end("bootstrap.databaseRecovery", category: .bootstrap, state: trace) }
        try FileManager.default.createDirectory(at: databaseDirectory, withIntermediateDirectories: true)
        let database = try SyncDatabase(url: databaseDirectory.appendingPathComponent("sync.sqlite"))
        let credential: CredentialStatus
        do {
            credential = try KeychainTokenStore.containsCredential() ? .present : .absent
        } catch let error as KeychainError {
            credential = .unavailable(error)
        }
        guard let rootURL, let rootID else { return Result(database: database, recoveryBlocked: false, credential: credential) }
        try await database.registerRoot(id: rootID, canonicalPath: rootURL.path)
        let report = try await gate.withLease(.recovering) {
            try await RecoveryCoordinator(rootID: rootID, database: database, fileStore: try FileStore(root: rootURL)).recover()
        }
        return Result(database: database, recoveryBlocked: !report.unresolved.isEmpty, credential: credential)
    }
}

private enum AutomaticNotificationIssue: String {
    case authenticationExpired
    case serviceUnavailable
    case incompatibleResponse
    case partialSync

    var title: String {
        switch self {
        case .authenticationExpired: "Accesso WeBeep scaduto"
        case .serviceUnavailable: "WeBeep non disponibile"
        case .incompatibleResponse: "Problema con WeBeep"
        case .partialSync: "Sincronizzazione incompleta"
        }
    }

    var body: String {
        switch self {
        case .authenticationExpired: "Apri Beepbar e accedi di nuovo per riprendere la sincronizzazione."
        case .serviceUnavailable: "WeBeep non risponde. I materiali locali restano disponibili."
        case .incompatibleResponse: "WeBeep ha restituito una risposta inattesa. Apri Beepbar per i dettagli."
        case .partialSync: "Alcuni materiali non sono stati aggiornati. Apri Beepbar per i dettagli."
        }
    }
}

@MainActor private final class SyncNotificationCoordinator {
    private static let prefix = "io.github.tvaccari.beepbar.notification.v2"
    private let deduplication: NotificationDeduplicationStore

    init(defaults: UserDefaults = .standard) {
        deduplication = NotificationDeduplicationStore(defaults: defaults, prefix: Self.prefix)
    }

    func requestAuthorizationIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    func notifyAutomaticRun(installed: Int, conflicts: [ConflictRecord], failures: Int) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized else { return }
        if conflicts.isEmpty {
            deduplication.resolve(condition: "conflicts")
        } else {
            let fingerprint = NotificationFingerprint.conflicts(conflicts)
            if deduplication.shouldNotify(condition: "conflicts", fingerprint: fingerprint, now: Date()) {
                await send(center, title: "Conflitti da risolvere", body: "Beepbar ha conservato separatamente \(conflicts.count) versione/i remota/e.", identifier: "beepbar-conflicts")
            }
        }
        if failures > 0 {
            await notify(issue: .partialSync)
        } else {
            if installed > 0 {
                await send(center, title: "Nuovi materiali disponibili", body: "Beepbar ha aggiunto \(installed) materiale/i nella cartella scelta.", identifier: "beepbar-new-files-\(UUID().uuidString)")
            }
        }
    }

    func notify(issue: AutomaticNotificationIssue) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized else { return }
        guard deduplication.shouldNotify(condition: issue.rawValue, fingerprint: issue.rawValue, now: Date()) else { return }
        await send(center, title: issue.title, body: issue.body, identifier: "beepbar-\(issue.rawValue)")
    }

    func clearFailure() {
        for issue in [AutomaticNotificationIssue.authenticationExpired, .serviceUnavailable, .incompatibleResponse, .partialSync] {
            deduplication.resolve(condition: issue.rawValue)
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
    private static let service = "io.github.tvaccari.beepbar.auth.local.v3"
    private static let legacyServices = ["io.github.tvaccari.beepbar.auth.local.v2", "io.github.tvaccari.beepbar"]

    enum MigrationResult { case migrated, legacyRetained }

    static func save(_ token: String) throws {
        let query = currentQuery()
        let attributes: [String: Any] = [kSecValueData as String: Data(token.utf8), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let result = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if result == errSecSuccess { return }; guard result == errSecItemNotFound else { throw KeychainError.write }
        var item = query; attributes.forEach { item[$0.key] = $0.value }; guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw KeychainError.write }
    }

    static func load(_ access: CredentialAccess) throws -> String {
        var query = currentQuery()
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        if access == .nonInteractive {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        guard let data = result as? Data, let token = String(data: data, encoding: .utf8), !token.isEmpty else {
            throw KeychainError.corrupt
        }
        return token
    }

    static func containsCredential() throws -> Bool {
        var query = currentQuery()
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnAttributes as String] = true
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess { return true }
        if status == errSecItemNotFound { return false }
        throw KeychainError(status: status)
    }

    static func migrateLegacyCredential() throws -> MigrationResult {
        guard try !containsCredential() else { return .migrated }
        let legacyToken = try loadLegacyCredential()
        try addLocalCredential(legacyToken)
        guard try load(.interactive) == legacyToken else { throw KeychainError.corrupt }
        let deletions = legacyServices.map { SecItemDelete(legacyQuery(service: $0) as CFDictionary) }
        return deletions.allSatisfy { $0 == errSecSuccess || $0 == errSecItemNotFound } ? .migrated : .legacyRetained
    }

    private static func currentQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private static func legacyQuery(service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    private static func loadLegacyCredential() throws -> String {
        for service in legacyServices {
            var query = legacyQuery(service: service)
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            query[kSecReturnData as String] = true
            var result: CFTypeRef?
            if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
               let data = result as? Data,
               let token = String(data: data, encoding: .utf8) {
                return token
            }
        }
        throw KeychainError.absent
    }

    private static func addLocalCredential(_ token: String) throws {
        var item = currentQuery()
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw KeychainError.write }
    }
}

private enum KeychainError: Error, Sendable {
    case write
    case absent
    case accessDenied
    case interactionRequired
    case corrupt
    case read(OSStatus)

    init(status: OSStatus) {
        switch status {
        case errSecItemNotFound: self = .absent
        case errSecInteractionNotAllowed: self = .interactionRequired
        case errSecAuthFailed, errSecUserCanceled: self = .accessDenied
        default: self = .read(status)
        }
    }
}
