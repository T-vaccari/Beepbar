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
    case synced(SyncCompletionSummary)
    case conflicts(Int, SyncCompletionSummary?)
    case partial(SyncCompletionSummary)
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
        case .conflicts(let count, _): "\(count) conflitti da risolvere"
        case .partial: "Sincronizzazione incompleta"
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
        case .synced(let summary): summary.detail
        case .conflicts(_, let summary): summary?.conflictDetail ?? "Scegli quale versione mantenere nella sezione Conflitti."
        case .partial(let summary): summary.partialDetail
        case .failed(let failure): failure.detail
        case .recoveryBlocked: "Il recupero locale non è stato completato. Riprova dal menu o scegli un'altra cartella."
        }
    }

    var systemImage: String {
        switch self {
        case .synced: "checkmark.circle.fill"
        case .checking, .syncing, .cancelling: "arrow.triangle.2.circlepath"
        case .conflicts, .partial: "exclamationmark.triangle.fill"
        case .loginRequired, .needsFolder, .failed, .recoveryBlocked: "exclamationmark.circle.fill"
        case .starting, .readyUnchecked: "arrow.triangle.2.circlepath"
        }
    }
}

struct SyncCompletionSummary: Codable, Equatable {
    let completedAt: Date
    let added: Int
    let updated: Int
    let unchanged: Int
    let preservedLocal: Int
    let conflicts: Int
    let failures: Int
    let perCourse: [CourseSyncCount]

    init(progress: SyncProgress, completedAt: Date = Date()) {
        self.completedAt = completedAt
        added = progress.added
        updated = progress.updated
        unchanged = progress.unchanged
        preservedLocal = progress.preservedLocal
        conflicts = progress.conflicts
        failures = progress.failures
        perCourse = progress.perCourse
    }

    init(completedAt: Date, added: Int, updated: Int, unchanged: Int, preservedLocal: Int, conflicts: Int, failures: Int, perCourse: [CourseSyncCount] = []) {
        self.completedAt = completedAt
        self.added = added
        self.updated = updated
        self.unchanged = unchanged
        self.preservedLocal = preservedLocal
        self.conflicts = conflicts
        self.failures = failures
        self.perCourse = perCourse
    }

    var affectedCourses: [CourseSyncCount] { perCourse.filter { $0.total > 0 } }
    var hasDetail: Bool { !affectedCourses.isEmpty }

    var detail: String {
        let activity: String
        switch (added, updated) {
        case (0, 0):
            activity = "Nessun nuovo materiale."
        case let (a, 0):
            activity = a == 1 ? "1 nuovo materiale scaricato." : "\(a) nuovi materiali scaricati."
        case let (0, u):
            activity = u == 1 ? "1 materiale aggiornato." : "\(u) materiali aggiornati."
        case let (a, u):
            let addedPart = a == 1 ? "1 nuovo materiale" : "\(a) nuovi materiali"
            let updatedPart = u == 1 ? "1 aggiornato" : "\(u) aggiornati"
            activity = "\(addedPart) · \(updatedPart)."
        }
        return activity + preservedSuffix
    }

    var conflictDetail: String { detail + " Apri Conflitti per scegliere quale versione mantenere." }
    var partialDetail: String { "\(failures) materiali non aggiornati. I file esistenti sono al sicuro." }
    private var preservedSuffix: String {
        guard preservedLocal > 0 else { return "" }
        return preservedLocal == 1 ? " 1 modifica locale conservata." : " \(preservedLocal) modifiche locali conservate."
    }
}

extension CourseSyncCount {
    var addedLabel: String { added == 1 ? "1 nuovo" : "\(added) nuovi" }
    var updatedLabel: String { updated == 1 ? "1 aggiornato" : "\(updated) aggiornati" }
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
    @Published private(set) var courses: [RemoteCourseSummary] = [] {
        didSet { defaultCourseFolders = Self.defaultFolders(for: courses) }
    }
    @Published private(set) var selectedCourse: RemoteCourseSummary?
    @Published private(set) var contents: RemoteCourseContents?
    @Published private(set) var isLoadingContents = false
    @Published private(set) var hasStoredCredential: Bool
    @Published private(set) var status = "Avvio Beepbar…"
    @Published private(set) var syncState: AppSyncState = .starting
    @Published private(set) var accountState: AccountState = .notConnected
    @Published private(set) var rootURL: URL?
    @Published private(set) var needsOnboarding: Bool
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
    // Default folder name per course id, derived from `courses` and rebuilt only when that list
    // changes: `folder(for:)` runs for every row on every render of the course list, so it has
    // to be a lookup, not a rescan of every course name.
    private var defaultCourseFolders: [Int64: String] = [:]
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

    // Pure and independently testable: whether onboarding should show depends only on these two
    // inputs. An existing root always wins, regardless of the persisted flag — this is what makes
    // an update to an already-set-up install never retrigger onboarding, even before this feature
    // existed to ever set the flag in the first place.
    nonisolated static func resolveNeedsOnboarding(existingRootURL: URL?, onboardingAlreadyCompleted: Bool) -> Bool {
        existingRootURL == nil && !onboardingAlreadyCompleted
    }

    override init() {
        hasStoredCredential = false
        let resolvedRootURL = Self.storedRootURL()
        rootURL = resolvedRootURL
        needsOnboarding = Self.resolveNeedsOnboarding(existingRootURL: resolvedRootURL, onboardingAlreadyCompleted: Self.defaults.bool(forKey: Self.onboardingCompletedKey))
        if resolvedRootURL != nil {
            Self.defaults.set(true, forKey: Self.onboardingCompletedKey)
        }
        enabledCourseIDs = Set(Self.defaults.stringArray(forKey: Self.enabledCoursesKey)?.compactMap(Int64.init) ?? [])
        automaticSyncEnabled = Self.defaults.bool(forKey: Self.autoSyncKey)
        automaticSyncInterval = Self.validatedAutomaticInterval(Self.defaults.object(forKey: Self.autoSyncIntervalKey) as? Int)
        automaticDailyCheckTime = Self.dailyTime(Self.defaults.object(forKey: Self.autoSyncDailyTimeKey) as? Int)
        rootID = Self.storedRootID()
        apiClient = WeBeepAPIClient()
        database = nil
        super.init()
#if DEBUG
        if Self.isUIPreviewOnboarding {
            // Fall through to the real bootstrap flow below (with the isolated preview
            // database/defaults) instead of returning early, so "Scegli cartella…" in the
            // onboarding UI exercises the actual chooseRoot() codepath, not a mock.
            needsOnboarding = true
            rootURL = nil
            hasStoredCredential = false
            accountState = .notConnected
        }
        if Self.isUIPreview {
            needsOnboarding = false
            let mockCourses = (1...100).map { index in
                RemoteCourseSummary(id: Int64(index), shortName: String(format: "%06d", 58000 + index), displayName: "CORSO DI PROVA \(index) — MATERIALI E ATTIVITÀ", isVisible: true, startDate: nil, endDate: nil)
            }
            enabledCourseIDs = Set(mockCourses.prefix(64).map(\.id))
            courses = Self.orderedForDisplay(mockCourses, enabledCourseIDs: enabledCourseIDs)
            courseFolders = Dictionary(uniqueKeysWithValues: mockCourses.map { ($0.id, "Corso di prova \($0.id)") })
            hasStoredCredential = true
            accountState = .connected
            rootURL = FileManager.default.temporaryDirectory
            func mockItems(added: Int, updated: Int) -> [SyncedItem] {
                (0..<added).map { SyncedItem(id: "a\($0)", name: "Slide \($0 + 1).pdf", kind: .added) }
                    + (0..<updated).map { SyncedItem(id: "u\($0)", name: "Esercizi \($0 + 1).pdf", kind: .updated) }
            }
            let mockPerCourse = [
                CourseSyncCount(courseID: 1, courseFolder: "Corso di prova 1", added: 5, updated: 1, items: mockItems(added: 5, updated: 1)),
                CourseSyncCount(courseID: 7, courseFolder: "Corso di prova 7", added: 4, updated: 0, items: mockItems(added: 4, updated: 0)),
                CourseSyncCount(courseID: 23, courseFolder: "Corso di prova 23", added: 2, updated: 2, items: mockItems(added: 2, updated: 2)),
                CourseSyncCount(courseID: 41, courseFolder: "Corso di prova 41", added: 1, updated: 1, items: mockItems(added: 1, updated: 1)),
            ]
            setSyncState(.synced(SyncCompletionSummary(completedAt: Date(), added: 12, updated: 4, unchanged: 83, preservedLocal: 1, conflicts: 0, failures: 0, perCourse: mockPerCourse)))
            return
        }
#endif
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
                await self.applyBootstrap(result)
            } catch {
                self?.setSyncState(.failed(.local("Impossibile preparare lo stato locale. Riapri Beepbar.")))
            }
        }
    }

    /// Applies the outcome of the launch bootstrap or of a recovery retry. A blocked recovery keeps
    /// every root operation gated; otherwise the account and the persisted sync state are restored.
    private func applyBootstrap(_ result: BootstrapService.Result) async {
        if result.recoveryBlocked {
            recoveryBlocked = true
            setSyncState(.recoveryBlocked)
            return
        }
        recoveryBlocked = false
        switch result.credential {
        case .present:
            hasStoredCredential = true
            if Self.defaults.bool(forKey: Self.credentialExpiredKey) {
                accountState = .expired
                setSyncState(.failed(.authenticationExpired))
            } else {
                accountState = .connected
                await restorePersistedSyncState()
            }
            configureBackgroundScheduler()
        case .absent:
            hasStoredCredential = false
            accountState = .notConnected
            await restorePersistedSyncState()
            configureBackgroundScheduler()
        case .unavailable(let error):
            await handleKeychainError(error)
        }
    }

    /// Re-runs the launch recovery for the current root without re-picking the folder, so a pending
    /// operation that could not be recovered (for example after the user fixed the file on disk)
    /// no longer keeps every sync blocked.
    func retryRecovery() {
        guard recoveryBlocked, case .recoveryBlocked = syncState, !isSyncActive, let rootURL, let rootID, let database else { return }
        setSyncState(.starting)
        let bootstrap = BootstrapService()
        let operationGate = self.operationGate
        Task { [weak self] in
            let trace = PerformanceTrace.shared.begin("bootstrap.retryRecovery", category: .bootstrap)
            defer { PerformanceTrace.shared.end("bootstrap.retryRecovery", category: .bootstrap, state: trace) }
            do {
                let result = try await bootstrap.retryRecovery(rootURL: rootURL, rootID: rootID, database: database, gate: operationGate)
                await self?.applyBootstrap(result)
            } catch {
                self?.setSyncState(.recoveryBlocked)
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
        case .retryRecovery: "Riprova recupero"
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
            recoveryBlocked: recoveryBlocked,
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
        if case .synced(let summary) = newState, let rootID {
            Self.defaults.set(summary.completedAt.timeIntervalSince1970, forKey: Self.lastSuccessfulReconciliationKey + rootID.uuidString)
            if let data = try? JSONEncoder().encode(summary) {
                Self.defaults.set(data, forKey: Self.lastSuccessfulSummaryKey + rootID.uuidString)
            }
        }
    }

    private func restorePersistedSyncState() async {
        guard !Self.isUIPreview else { return }
        guard !recoveryBlocked else { setSyncState(.recoveryBlocked); return }
        guard accountState != .expired else { setSyncState(.failed(.authenticationExpired)); return }
        guard hasStoredCredential else { setSyncState(.loginRequired); return }
        guard rootURL != nil, let rootID else { setSyncState(.needsFolder); return }
        let open = (try? await database?.conflicts(rootID: rootID)) ?? []
        conflicts = open
        if !open.isEmpty { setSyncState(.conflicts(open.count, nil)); return }
        if let data = Self.defaults.data(forKey: Self.lastSuccessfulSummaryKey + rootID.uuidString),
           let summary = try? JSONDecoder().decode(SyncCompletionSummary.self, from: data) {
            setSyncState(.synced(summary))
            return
        }
        let timestamp = Self.defaults.double(forKey: Self.lastSuccessfulReconciliationKey + rootID.uuidString)
        let legacy = SyncCompletionSummary(completedAt: Date(timeIntervalSince1970: timestamp), added: 0, updated: 0, unchanged: 0, preservedLocal: 0, conflicts: 0, failures: 0)
        setSyncState(timestamp > 0 ? .synced(legacy) : .readyUnchecked)
    }

    var lastSyncSummary: SyncCompletionSummary? {
        switch syncState {
        case .synced(let summary), .partial(let summary): return summary
        case .conflicts(_, let summary): return summary
        default: return nil
        }
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
        case .retryRecovery: retryRecovery()
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
                Self.defaults.set(selectedURL.path, forKey: Self.rootKey)
                Self.defaults.set(selectedID.uuidString, forKey: Self.rootIDKey)
                await self.restorePersistedSyncState()
                self.configureBackgroundScheduler()
            } catch {
                self?.setSyncState(.failed(.local("Non è stato possibile usare questa cartella. Scegline un'altra.")))
            }
        }
    }

    func completeOnboarding() {
        needsOnboarding = false
        Self.defaults.set(true, forKey: Self.onboardingCompletedKey)
    }

    func isCourseEnabled(_ course: RemoteCourseSummary) -> Bool {
        enabledCourseIDs.contains(course.id)
    }

    func setCourse(_ course: RemoteCourseSummary, enabled: Bool) {
        guard !isSyncActive else { return }
        if enabled { enabledCourseIDs.insert(course.id) }
        else { enabledCourseIDs.remove(course.id) }
        Self.defaults.set(enabledCourseIDs.map(String.init).sorted(), forKey: Self.enabledCoursesKey)
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
        Self.defaults.set(enabled, forKey: Self.autoSyncKey)
        if enabled { Task { await notificationCoordinator.requestAuthorizationIfNeeded() } }
        configureBackgroundScheduler()
    }
    func setAutomaticSyncInterval(_ seconds: Int) { guard !isSyncActive else { return }; automaticSyncInterval = Self.validatedAutomaticInterval(seconds); Self.defaults.set(automaticSyncInterval, forKey: Self.autoSyncIntervalKey); configureBackgroundScheduler() }
    func setAutomaticDailyCheckTime(_ time: Date) {
        guard !isSyncActive else { return }
        automaticDailyCheckTime = Self.dailyTime(Self.secondsSinceMidnight(time))
        Self.defaults.set(Self.secondsSinceMidnight(automaticDailyCheckTime), forKey: Self.autoSyncDailyTimeKey)
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
#if DEBUG
        if Self.isUIPreview {
            courses = Self.orderedForDisplay(courses, enabledCourseIDs: enabledCourseIDs)
            return
        }
#endif
        guard !recoveryBlocked else { setSyncState(.recoveryBlocked); return }
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
            if !found.isEmpty { self.setSyncState(.conflicts(found.count, nil)) }
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
                    guard result.isInstalled else {
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
        guard !Self.isUIPreview else { return }
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
                Self.defaults.removeObject(forKey: Self.credentialExpiredKey)
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
        guard !Self.isUIPreview else { return }
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
                await self.restoreScopes(for: courses)
                self.courses = Self.orderedForDisplay(courses, enabledCourseIDs: self.enabledCourseIDs)
                self.accountState = .connected
                Self.defaults.removeObject(forKey: Self.credentialExpiredKey)
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

    private static let onboardingCompletedKey = "io.github.tvaccari.beepbar.onboarding-completed.v1"
    private static let rootKey = "io.github.tvaccari.beepbar.root-path.v1"
    private static let rootIDKey = "io.github.tvaccari.beepbar.root-id.v1"
    private static let enabledCoursesKey = "io.github.tvaccari.beepbar.enabled-courses.v1"
    private static let autoSyncKey = "io.github.tvaccari.beepbar.auto-sync.v1"
    private static let autoSyncIntervalKey = "io.github.tvaccari.beepbar.auto-sync-interval.v1"
    private static let autoSyncDailyTimeKey = "io.github.tvaccari.beepbar.auto-sync-daily-time.v1"
    private static let lastSuccessfulReconciliationKey = "io.github.tvaccari.beepbar.last-successful-reconciliation.v1."
    private static let lastSuccessfulSummaryKey = "io.github.tvaccari.beepbar.last-successful-summary.v1."
    private static let credentialExpiredKey = "io.github.tvaccari.beepbar.credential-expired.v1"
    private static var isUIPreview: Bool {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains("--ui-preview")
#else
        false
#endif
    }

    private static var isUIPreviewOnboarding: Bool {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains("--ui-preview-onboarding")
#else
        false
#endif
    }

    /// Every persisted setting goes through this instead of `Self.defaults` directly:
    /// the raw `--ui-preview`/`--ui-preview-onboarding` binaries share the real app's bundle
    /// identifier (they're unsigned executables built from the same target), so writing straight
    /// to `.standard` during manual preview testing would silently overwrite the real installed
    /// app's settings (sync root, credentials-expired flag, etc). Preview runs get their own
    /// throwaway suite, wiped at launch so every preview run starts from a clean slate.
    private static let defaults: UserDefaults = {
        guard isUIPreview || isUIPreviewOnboarding else { return .standard }
        let suiteName = "io.github.tvaccari.beepbar.preview"
        let store = UserDefaults(suiteName: suiteName) ?? .standard
        if let domain = store.persistentDomain(forName: suiteName) {
            for key in domain.keys { store.removeObject(forKey: key) }
        }
        return store
    }()

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
        guard let path = Self.defaults.string(forKey: rootKey), !path.isEmpty else { return nil }
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
                Self.defaults.removeObject(forKey: Self.credentialExpiredKey)
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
                Self.defaults.removeObject(forKey: Self.credentialExpiredKey)
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
        Self.defaults.string(forKey: rootIDKey).flatMap(UUID.init(uuidString:))
    }

    private static func databaseDirectory() throws -> URL {
        guard !isUIPreview, !isUIPreviewOnboarding else {
            // Same reasoning as `defaults`: don't let a manual preview run touch the real
            // installed app's sync database. A fresh throwaway directory per launch also gives
            // onboarding testing a clean "first install" every time.
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Beepbar-preview-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        }
        return try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            .appendingPathComponent("Beepbar", isDirectory: true)
    }

    private func restoreScopes(for courses: [RemoteCourseSummary]) async {
        guard let database, let rootID else { return }
        guard let scopes = try? await database.scopes(rootID: rootID) else { return }
        let remoteIDs = Set(courses.map(\.id))
        let scopesByCourse = Dictionary(scopes.map { ($0.courseID, $0) }, uniquingKeysWith: { first, _ in first })
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
        Self.defaults.set(enabledCourseIDs.map(String.init).sorted(), forKey: Self.enabledCoursesKey)
    }

    func folder(for course: RemoteCourseSummary) -> String {
        courseFolders[course.id] ?? defaultFolder(for: course)
    }

    private func defaultFolder(for course: RemoteCourseSummary) -> String {
        defaultCourseFolders[course.id] ?? LocalPathPolicy.defaultCourseFolder(course.displayName)
    }

    static func orderedForDisplay(_ courses: [RemoteCourseSummary], enabledCourseIDs: Set<Int64>) -> [RemoteCourseSummary] {
        courses.sorted { lhs, rhs in
            let lhsEnabled = enabledCourseIDs.contains(lhs.id)
            let rhsEnabled = enabledCourseIDs.contains(rhs.id)
            if lhsEnabled != rhsEnabled { return lhsEnabled }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending || (lhs.displayName == rhs.displayName && lhs.id < rhs.id)
        }
    }

    // Pure and independently testable: the default folder for each course, falling back to the
    // full course name when two courses would otherwise share the same folder.
    nonisolated static func defaultFolders(for courses: [RemoteCourseSummary]) -> [Int64: String] {
        let names = Dictionary(grouping: courses, by: { LocalPathPolicy.defaultCourseFolder($0.displayName).precomposedStringWithCanonicalMapping.lowercased() })
        return Dictionary(courses.map { course -> (Int64, String) in
            let base = LocalPathPolicy.defaultCourseFolder(course.displayName)
            let duplicate = (names[base.precomposedStringWithCanonicalMapping.lowercased()]?.count ?? 0) > 1
            return (course.id, duplicate ? LocalPathPolicy.component(course.displayName) : base)
        }, uniquingKeysWith: { first, _ in first })
    }

    private func finishReconciliation(progress: SyncProgress) async {
        guard let database, let rootID else { return }
        let open = (try? await database.conflicts(rootID: rootID)) ?? []
        conflicts = open
        courses = Self.orderedForDisplay(courses, enabledCourseIDs: enabledCourseIDs)
        let summary = SyncCompletionSummary(progress: progress)
        if progress.failures > 0 {
            setSyncState(.partial(summary))
        } else if !open.isEmpty {
            setSyncState(.conflicts(open.count, summary))
        } else {
            setSyncState(.synced(summary))
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
        await finishReconciliation(progress: summary)
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
        Self.defaults.set(true, forKey: Self.credentialExpiredKey)
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
        let credential = try credentialStatus()
        guard let rootURL, let rootID else { return Result(database: database, recoveryBlocked: false, credential: credential) }
        let blocked = try await recoveryBlocked(rootURL: rootURL, rootID: rootID, database: database, gate: gate)
        return Result(database: database, recoveryBlocked: blocked, credential: credential)
    }

    /// Runs the same recovery as `prepare` on an already-open database, under the `.recovering` lease.
    func retryRecovery(rootURL: URL, rootID: UUID, database: SyncDatabase, gate: RootOperationGate) async throws -> Result {
        let credential = try credentialStatus()
        let blocked = try await recoveryBlocked(rootURL: rootURL, rootID: rootID, database: database, gate: gate)
        return Result(database: database, recoveryBlocked: blocked, credential: credential)
    }

    private func credentialStatus() throws -> CredentialStatus {
        do {
            return try KeychainTokenStore.containsCredential() ? .present : .absent
        } catch let error as KeychainError {
            return .unavailable(error)
        }
    }

    private func recoveryBlocked(rootURL: URL, rootID: UUID, database: SyncDatabase, gate: RootOperationGate) async throws -> Bool {
        try await database.registerRoot(id: rootID, canonicalPath: rootURL.path)
        let report = try await gate.withLease(.recovering) {
            try await RecoveryCoordinator(rootID: rootID, database: database, fileStore: try FileStore(root: rootURL)).recover()
        }
        return !report.unresolved.isEmpty
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
    private static let entryURL = URL(string: "https://webeep.polimi.it/auth/shibboleth/index.php")!
    private static let maximumAutomaticRetries = 2
    private var phase: Phase = .signingIn
    private var completion: ((Result<URL, LoginWindowError>) -> Void)?
    private let webView: WKWebView
    private let retryButton: NSButton
    private let waitingOverlay: NSView
    private var automaticRetriesRemaining = LoginWindowController.maximumAutomaticRetries

    init(completion: @escaping (Result<URL, LoginWindowError>) -> Void) {
        self.completion = completion
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.translatesAutoresizingMaskIntoConstraints = false
        retryButton = NSButton(title: "Ricarica", target: nil, action: nil)
        retryButton.translatesAutoresizingMaskIntoConstraints = false
        retryButton.bezelStyle = .rounded

        let spinner = NSProgressIndicator(); spinner.style = .spinning; spinner.controlSize = .regular
        spinner.startAnimation(nil); spinner.translatesAutoresizingMaskIntoConstraints = false
        let waitingLabel = NSTextField(wrappingLabelWithString: "In attesa di risposta da WeBeep, può richiedere qualche secondo.\nSe il caricamento non va a buon fine, chiudi e riprova, oppure premi Ricarica.")
        waitingLabel.alignment = .center; waitingLabel.textColor = .secondaryLabelColor
        waitingLabel.translatesAutoresizingMaskIntoConstraints = false
        let waitingStack = NSStackView(views: [spinner, waitingLabel])
        waitingStack.orientation = .vertical; waitingStack.alignment = .centerX; waitingStack.spacing = 10
        waitingStack.translatesAutoresizingMaskIntoConstraints = false
        waitingOverlay = NSView()
        waitingOverlay.addSubview(waitingStack)
        NSLayoutConstraint.activate([
            waitingStack.centerXAnchor.constraint(equalTo: waitingOverlay.centerXAnchor),
            waitingStack.centerYAnchor.constraint(equalTo: waitingOverlay.centerYAnchor),
            waitingLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 340),
        ])

        let container = NSView()
        container.addSubview(webView); container.addSubview(waitingOverlay); container.addSubview(retryButton)
        waitingOverlay.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            waitingOverlay.topAnchor.constraint(equalTo: container.topAnchor),
            waitingOverlay.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            waitingOverlay.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            waitingOverlay.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            retryButton.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            retryButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
        ])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 680), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Accesso WeBeep"; window.contentView = container
        super.init(window: window); window.delegate = self; webView.navigationDelegate = self; webView.uiDelegate = self
        retryButton.target = self; retryButton.action = #selector(retryTapped)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        // Without this, an accessory (menu-bar-only) app can leave the window visible but not
        // key: it draws on screen but doesn't actually own keyboard focus, so the WebView's
        // fields silently reject typing and pasting.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        webView.load(URLRequest(url: Self.entryURL))
    }

    @objc private func retryTapped() {
        automaticRetriesRemaining = Self.maximumAutomaticRetries
        phase = .signingIn
        waitingOverlay.isHidden = false
        webView.load(URLRequest(url: Self.entryURL))
    }

    func windowWillClose(_ notification: Notification) { finish(.failure(.cancelled)) }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        waitingOverlay.isHidden = false
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        retryAutomaticallyOrGiveUp(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        retryAutomaticallyOrGiveUp(error)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        automaticRetriesRemaining = Self.maximumAutomaticRetries
        waitingOverlay.isHidden = true
    }

    // A first navigation attempt can occasionally fail outright (no network yet, DNS hiccup,
    // etc), leaving a blank window with no feedback. Retrying automatically (plus always offering
    // a one-click "Ricarica") means the user never has to close and reopen the whole window for
    // that.
    //
    // Only ever retry on a genuine network failure (NSURLErrorDomain). decidePolicyFor below
    // intentionally cancels navigations mid-flow — once to intercept the moodlemobile:// scheme,
    // once to redirect into launch.php — and WKWebView reports each of those as a navigation
    // "failure" too (WKErrorDomain, WKErrorFrameLoadInterruptedByPolicyChange). Retrying on those
    // as well would restart the login from scratch every time it was about to succeed, which is
    // exactly the infinite-reset loop this shipped with until caught.
    private func retryAutomaticallyOrGiveUp(_ error: Error) {
        guard phase != .finished else { return }
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain, nsError.code != NSURLErrorCancelled else { return }
        guard automaticRetriesRemaining > 0 else { return }
        automaticRetriesRemaining -= 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.phase != .finished else { return }
            self.phase = .signingIn
            self.webView.load(URLRequest(url: Self.entryURL))
        }
    }

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
