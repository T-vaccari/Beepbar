import SwiftUI
import BeepbarCore

struct ModuleDestinationsSheet: View {
    @ObservedObject var authentication: WeBeepAuthenticationController
    let course: RemoteCourseSummary
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [ModulePathRuleRow] = []
    @State private var isLoading = true
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var editingModuleID: Int64?
    @State private var folder = ""
    @State private var preview: ModuleMovePreview?
    @State private var showApplyConfirmation = false
    @State private var ruleToDelete: ModulePathRuleRow?
    @State private var showDeleteConfirmation = false
    @FocusState private var fieldFocused: Bool

    private var availableRows: [ModulePathRuleRow] { rows.filter(\.isAvailable) }
    private var unavailableRows: [ModulePathRuleRow] { rows.filter { !$0.isAvailable } }
    private var actionsDisabled: Bool { isWorking || authentication.recoveryBlocked }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                if isLoading {
                    ProgressView(tr("Caricamento moduli Moodle…", "Loading Moodle modules…"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    content
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(minWidth: 640, minHeight: 540)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await reload() }
        .animation(BeepbarStyle.snappy, value: preview?.moduleID)
        .animation(BeepbarStyle.snappy, value: editingModuleID)
        .confirmationDialog(tr("Spostare i file del modulo?", "Move the module's files?"), isPresented: $showApplyConfirmation, titleVisibility: .visible) {
            Button(tr("Conferma spostamento", "Confirm move")) { applyPreview() }
            Button(tr("Annulla", "Cancel"), role: .cancel) {}
        } message: {
            Text(tr("I file modificati localmente vengono spostati senza essere sovrascritti. Le destinazioni occupate bloccano l’operazione.", "Locally modified files are moved without being overwritten. Occupied destinations block the operation."))
        }
        .confirmationDialog(tr("Eliminare questa regola?", "Remove this rule?"), isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button(tr("Elimina regola", "Remove rule"), role: .destructive) { deleteRule() }
            Button(tr("Annulla", "Cancel"), role: .cancel) { ruleToDelete = nil }
        } message: {
            Text(tr("I file locali non verranno spostati né eliminati.", "Local files won't be moved or deleted."))
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            SymbolTile(systemImage: "folder.badge.gearshape", size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(tr("Organizza cartelle", "Organize folders")).font(.title3.weight(.semibold))
                Text(course.displayName)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(20)
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let errorMessage {
                    NoticeBanner(text: errorMessage, tint: .red)
                }
                Text(tr("Scegli una cartella relativa alla cartella del corso. Senza una regola, i file seguono l’organizzazione di Moodle.", "Choose a folder relative to the course folder. Without a rule, files follow Moodle's layout."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let preview { previewPanel(preview) }

                VStack(alignment: .leading, spacing: 8) {
                    Text(tr("Moduli disponibili", "Available modules")).font(.headline)
                    if availableRows.isEmpty {
                        Text(tr("Nessun modulo disponibile.", "No modules available."))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .card()
                    } else {
                        rowGroup(availableRows) { moduleRow($0) }
                    }
                }

                if !unavailableRows.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(tr("Regole per moduli non più presenti", "Rules for modules no longer present")).font(.headline)
                        rowGroup(unavailableRows) { unavailableRow($0) }
                    }
                }
            }
            .padding(20)
        }
    }

    private func rowGroup<Row: View>(_ items: [ModulePathRuleRow], @ViewBuilder row: @escaping (ModulePathRuleRow) -> Row) -> some View {
        VStack(spacing: 0) {
            ForEach(items) { item in
                row(item)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                if item.id != items.last?.id {
                    Divider().padding(.leading, 54)
                }
            }
        }
        .card(padding: 0)
    }

    @ViewBuilder private func moduleRow(_ row: ModulePathRuleRow) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                SymbolTile(systemImage: Self.symbol(for: row.moduleType), tint: row.localFolder == nil ? .gray : .accentColor, size: 28, filled: row.localFolder != nil)
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.name).lineLimit(2)
                    HStack(spacing: 6) {
                        Text(tr("\(row.exposedFileCount) file esposti · \(row.trackedFileCount) tracciati", "\(englishCount(row.exposedFileCount, "file", "files")) exposed · \(row.trackedFileCount) tracked"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let localFolder = row.localFolder {
                            Label(localFolder, systemImage: "arrow.turn.down.right")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.tint)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                Spacer(minLength: 8)
                if let localFolder = row.localFolder {
                    Menu(tr("Modifica", "Edit")) {
                        Button(tr("Cambia destinazione…", "Change destination…"), systemImage: "pencil") { beginEditing(row, folder: localFolder) }
                        Button(tr("Ripristina layout Moodle", "Restore Moodle layout"), systemImage: "arrow.uturn.backward") {
                            requestPreview(for: row, action: .remove, folder: nil)
                        }
                    }
                    .menuStyle(.button)
                    .fixedSize()
                    .disabled(actionsDisabled)
                } else if editingModuleID != row.moduleID {
                    Button(tr("Personalizza", "Customize")) { beginEditing(row, folder: "") }
                        .disabled(actionsDisabled)
                }
            }
            if editingModuleID == row.moduleID {
                HStack(spacing: 8) {
                    TextField(tr("Cartella, ad esempio materiali/slide", "Folder, for example materials/slides"), text: $folder)
                        .textFieldStyle(.roundedBorder)
                        .focused($fieldFocused)
                        .onSubmit { submitPreview(for: row) }
                    Button(tr("Annulla", "Cancel")) { editingModuleID = nil; preview = nil }
                        .disabled(isWorking)
                    Button(tr("Anteprima", "Preview")) { submitPreview(for: row) }
                        .buttonStyle(.borderedProminent)
                        .disabled(isWorking || folder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.leading, 40)
                .transition(.opacity)
            }
        }
    }

    private func unavailableRow(_ row: ModulePathRuleRow) -> some View {
        HStack(spacing: 12) {
            SymbolTile(systemImage: "questionmark.folder", tint: .gray, size: 28, filled: false)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.name).foregroundStyle(.secondary)
                Text(tr("\(row.trackedFileCount) file tracciati · \(row.localFolder ?? "")", "\(englishCount(row.trackedFileCount, "tracked file", "tracked files")) · \(row.localFolder ?? "")"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(tr("Elimina regola", "Remove rule"), role: .destructive) {
                ruleToDelete = row
                showDeleteConfirmation = true
            }
            .disabled(actionsDisabled)
        }
    }

    private func previewPanel(_ preview: ModuleMovePreview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.right.doc.on.clipboard")
                    .font(.title3)
                    .foregroundStyle(.tint)
                Text(tr("Anteprima · \(previewName(preview))", "Preview · \(previewName(preview))")).font(.headline)
            }
            VStack(alignment: .leading, spacing: 4) {
                Label(tr("\(preview.changedFileCount) file da spostare; \(preview.localModifiedCount) con modifiche locali preservate.", "\(englishCount(preview.changedFileCount, "file", "files")) to move; \(preview.localModifiedCount) with local changes preserved."), systemImage: "doc.on.doc")
                if !preview.excludedRemoteIDs.isEmpty {
                    Label(tr("\(preview.excludedRemoteIDs.count) file tracciati ma non esposti da Moodle restano nella posizione attuale.", "Left where they are: \(englishCount(preview.excludedRemoteIDs.count, "tracked file", "tracked files")) not exposed by Moodle."), systemImage: "pin")
                }
                if preview.ownerlessBaselineCount > 0 {
                    Label(tr("\(preview.ownerlessBaselineCount) file storici senza modulo attribuibile non vengono spostati.", "Not moved: \(englishCount(preview.ownerlessBaselineCount, "older file", "older files")) with no attributable module."), systemImage: "clock.arrow.circlepath")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(tr("Scarta", "Discard")) { self.preview = nil }
                    .disabled(isWorking)
                Button(isWorking ? tr("Applicazione…", "Applying…") : tr("Conferma anteprima", "Confirm preview")) { showApplyConfirmation = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(actionsDisabled)
            }
        }
        .padding(14)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: BeepbarStyle.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: BeepbarStyle.cardRadius, style: .continuous).strokeBorder(Color.accentColor.opacity(0.3), lineWidth: 0.5))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    // The name is stored as Moodle gave it, possibly empty, so the placeholder follows the language.
    private func previewName(_ preview: ModuleMovePreview) -> String {
        preview.lastKnownName.isEmpty ? tr("Modulo senza nome · ID \(preview.moduleID)", "Untitled module · ID \(preview.moduleID)") : preview.lastKnownName
    }

    private var footer: some View {
        HStack {
            if isWorking { ProgressView().controlSize(.small) }
            Spacer()
            Button(tr("Chiudi", "Close")) { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private static func symbol(for moduleType: String) -> String {
        switch moduleType {
        case "resource": "doc.fill"
        case "folder": "folder.fill"
        case "url": "link"
        case "page": "doc.richtext.fill"
        case "assign": "tray.and.arrow.up.fill"
        default: "square.stack.fill"
        }
    }

    private func beginEditing(_ row: ModulePathRuleRow, folder: String) {
        editingModuleID = row.moduleID
        self.folder = folder
        preview = nil
        fieldFocused = true
    }

    private func submitPreview(for row: ModulePathRuleRow) {
        guard !isWorking, !folder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        requestPreview(for: row, action: .set, folder: folder)
    }

    @MainActor private func reload() async {
        isLoading = true
        errorMessage = nil
        do {
            rows = try await authentication.modulePathRules(for: course)
        } catch {
            errorMessage = WeBeepAuthenticationController.moduleFolderErrorMessage(error)
        }
        isLoading = false
    }

    private func requestPreview(for row: ModulePathRuleRow, action: ModuleMoveAction, folder: String?) {
        isWorking = true
        errorMessage = nil
        Task { @MainActor in
            defer { isWorking = false }
            do {
                preview = try await authentication.previewModulePath(for: course, moduleID: row.moduleID, action: action, proposedFolder: folder)
                editingModuleID = nil
            } catch {
                preview = nil
                errorMessage = WeBeepAuthenticationController.moduleFolderErrorMessage(error)
            }
        }
    }

    private func applyPreview() {
        guard let preview else { return }
        isWorking = true
        errorMessage = nil
        Task { @MainActor in
            defer { isWorking = false }
            do {
                try await authentication.applyModulePath(preview, for: course)
                self.preview = nil
                await reload()
            } catch {
                self.preview = nil
                let message = WeBeepAuthenticationController.moduleFolderErrorMessage(error)
                await reload()
                errorMessage = message
            }
        }
    }

    private func deleteRule() {
        guard let row = ruleToDelete else { return }
        isWorking = true
        errorMessage = nil
        Task { @MainActor in
            defer { isWorking = false; ruleToDelete = nil }
            do {
                try await authentication.deleteUnavailableModuleRule(for: course, moduleID: row.moduleID)
                await reload()
            } catch {
                let message = WeBeepAuthenticationController.moduleFolderErrorMessage(error)
                await reload()
                errorMessage = message
            }
        }
    }
}
