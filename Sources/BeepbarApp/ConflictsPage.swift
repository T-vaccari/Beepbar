import SwiftUI
import BeepbarCore

/// The single conflict resolver: both the shell tab and the menu bar's "Apri conflitti"
/// action land here.
struct ConflictsPage: View {
    @ObservedObject var authentication: WeBeepAuthenticationController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(
                    title: tr("Conflitti", "Conflicts"),
                    subtitle: authentication.conflicts.isEmpty ? nil : tr("\(authentication.conflicts.count) da risolvere", "\(authentication.conflicts.count) to resolve")
                ) {
                    Button { authentication.refreshConflicts() } label: {
                        Image(systemName: "arrow.clockwise").frame(width: 20, height: 20)
                    }
                    .buttonStyle(.borderless)
                    .help(tr("Aggiorna l’elenco dei conflitti", "Refresh the conflict list"))
                    .accessibilityLabel(tr("Aggiorna conflitti", "Refresh conflicts"))
                }
                Label(tr("La versione remota è conservata separatamente: nessun file locale viene mai sovrascritto senza una tua scelta.", "The remote version is kept separately: no local file is ever overwritten without your choice."), systemImage: "lock.shield")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if authentication.conflicts.isEmpty {
                    ContentUnavailableView {
                        Label(tr("Nessun conflitto aperto", "No open conflicts"), systemImage: "checkmark.seal")
                    } description: {
                        Text(tr("Se lo stesso file cambia sia sul Mac sia su \(authentication.selectedSite.platformName), potrai scegliere qui quale versione tenere.", "If the same file changes both on your Mac and on \(authentication.selectedSite.platformName), you can choose here which version to keep."))
                    }
                    .frame(minHeight: 260)
                    .frame(maxWidth: .infinity)
                    .card()
                    .transition(.opacity)
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(authentication.conflicts) { conflict in
                            ConflictCard(
                                conflict: conflict,
                                localURL: authentication.rootURL?.appending(path: conflict.relativePath.value),
                                isResolving: authentication.resolvingConflictID == conflict.id,
                                isLocked: authentication.resolvingConflictID != nil,
                                resolve: { authentication.resolve(conflict, with: $0) }
                            )
                            .transition(.asymmetric(insertion: .opacity, removal: .opacity.combined(with: .scale(scale: 0.96))))
                        }
                    }
                }
            }
            .padding(BeepbarStyle.pagePadding)
            .animation(BeepbarStyle.snappy, value: authentication.conflicts.map(\.id))
        }
    }
}

private struct ConflictCard: View {
    let conflict: ConflictRecord
    let localURL: URL?
    let isResolving: Bool
    let isLocked: Bool
    let resolve: (ConflictResolution) -> Void

    private var fileName: String { (conflict.relativePath.value as NSString).lastPathComponent }
    private var directory: String { (conflict.relativePath.value as NSString).deletingLastPathComponent }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                SymbolTile(systemImage: "doc.on.doc.fill", tint: .orange, size: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text(fileName)
                        .font(.body.weight(.semibold))
                        .lineLimit(2)
                    if !directory.isEmpty {
                        Label(directory, systemImage: "folder")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Text(tr("Rilevato \(conflict.detectedAt.relativeText)", "Detected \(conflict.detectedAt.relativeText)"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 8)
                if let localURL {
                    Button { Finder.reveal(localURL) } label: {
                        Image(systemName: "magnifyingglass.circle")
                            .font(.title3)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help(tr("Mostra la copia locale nel Finder", "Show the local copy in Finder"))
                    .accessibilityLabel(tr("Mostra \(fileName) nel Finder", "Show \(fileName) in Finder"))
                }
            }
            HStack(spacing: 10) {
                choice(title: tr("Mantieni la mia", "Keep mine"), subtitle: tr("La copia sul Mac resta com’è", "The copy on your Mac stays as it is"), systemImage: "laptopcomputer", prominent: false) {
                    resolve(.keepLocal)
                }
                choice(title: tr("Usa la versione remota", "Use the remote version"), subtitle: tr("Sostituisce la copia locale", "Replaces the local copy"), systemImage: "icloud.and.arrow.down", prominent: true) {
                    resolve(.useRemote)
                }
            }
            .disabled(isLocked)
            .overlay {
                if isResolving { ProgressView().controlSize(.small) }
            }
        }
        .card()
    }

    private func choice(title: String, subtitle: String, systemImage: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.callout.weight(.semibold))
                    Text(subtitle).font(.caption).opacity(0.8)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(prominent ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(.quaternary.opacity(0.7)))
            }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .opacity(isLocked && !isResolving ? 0.5 : 1)
    }
}
