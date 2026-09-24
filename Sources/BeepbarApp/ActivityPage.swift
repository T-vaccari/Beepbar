import SwiftUI
import BeepbarCore

/// What the last synchronization brought in, course by course.
struct ActivityPage: View {
    @ObservedObject var authentication: WeBeepAuthenticationController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let summary = authentication.lastSyncSummary {
                    SectionHeader(title: "Ultima sincronizzazione", subtitle: summary.completedAt.shortItalian)
                    HStack(spacing: 8) {
                        MetricTile(value: summary.added, label: "Nuovi", systemImage: "plus.circle.fill", tint: .green)
                        MetricTile(value: summary.updated, label: "Aggiornati", systemImage: "arrow.triangle.2.circlepath.circle.fill", tint: .blue)
                        MetricTile(value: summary.preservedLocal, label: "Modifiche tue", systemImage: "lock.circle.fill", tint: .purple)
                        MetricTile(value: summary.failures, label: "Non aggiornati", systemImage: "exclamationmark.triangle.fill", tint: .orange)
                    }
                    if summary.affectedCourses.isEmpty {
                        ContentUnavailableView("Nessun corso con nuovi materiali", systemImage: "checkmark.circle", description: Text("Tutto era già aggiornato."))
                            .frame(minHeight: 220)
                            .frame(maxWidth: .infinity)
                            .card()
                    } else {
                        LazyVStack(spacing: 10) {
                            ForEach(summary.affectedCourses) { course in
                                CourseActivityCard(
                                    course: course,
                                    folderURL: authentication.rootURL?.appending(path: course.courseFolder, directoryHint: .isDirectory)
                                )
                            }
                        }
                    }
                } else {
                    SectionHeader(title: "Ultima sincronizzazione")
                    ContentUnavailableView("Nessuna sincronizzazione recente", systemImage: "clock", description: Text("Qui troverai i materiali arrivati con l’ultima sincronizzazione."))
                        .frame(minHeight: 260)
                        .frame(maxWidth: .infinity)
                        .card()
                }
            }
            .padding(BeepbarStyle.pagePadding)
        }
    }
}

private struct CourseActivityCard: View {
    let course: CourseSyncCount
    let folderURL: URL?
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(BeepbarStyle.snappy) { isExpanded.toggle() } } label: {
                HStack(spacing: 12) {
                    SymbolTile(systemImage: "folder.fill", size: 30)
                    Text(course.courseFolder)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if course.added > 0 { CountPill(text: course.addedLabel, tint: .green) }
                    if course.updated > 0 { CountPill(text: course.updatedLabel, tint: .blue) }
                    if course.courseFailure != nil { CountPill(text: "non sincronizzato", tint: .orange) }
                    if !course.failedItems.isEmpty { CountPill(text: "\(course.failedItems.count) non aggiornati", tint: .orange) }
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(isExpanded ? "Comprimi" : "Espandi")

            if isExpanded {
                Divider().padding(.leading, 56)
                VStack(alignment: .leading, spacing: 7) {
                    if let failure = course.courseFailure {
                        Label {
                            Text(failure).font(.callout)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                    }
                    ForEach(course.items) { item in
                        Label {
                            Text(item.name).font(.callout).lineLimit(1)
                        } icon: {
                            Image(systemName: item.kind == .added ? "plus.circle.fill" : "arrow.triangle.2.circlepath.circle.fill")
                                .foregroundStyle(item.kind == .added ? .green : .blue)
                        }
                    }
                    ForEach(course.failedItems) { item in
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.name).font(.callout).lineLimit(1)
                                Text(item.reason).font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                    }
                    if let folderURL {
                        Button("Mostra nel Finder", systemImage: "folder") { Finder.reveal(folderURL) }
                            .buttonStyle(.link)
                            .font(.callout)
                            .padding(.top, 2)
                    }
                }
                .symbolRenderingMode(.hierarchical)
                .padding(.leading, 56)
                .padding(.trailing, 14)
                .padding(.vertical, 12)
                .transition(.opacity)
            }
        }
        .card(padding: 0)
        .clipShape(RoundedRectangle(cornerRadius: BeepbarStyle.cardRadius, style: .continuous))
    }
}
