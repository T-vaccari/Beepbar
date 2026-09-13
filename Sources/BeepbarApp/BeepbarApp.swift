import AppKit
import BeepbarCore
import SwiftUI
import os

@main
struct BeepbarApp: App {
    @StateObject private var authentication = WeBeepAuthenticationController()

    var body: some Scene {
        MenuBarExtra("Beepbar", systemImage: authentication.menuBarSymbol) {
            MenuBarContent(authentication: authentication)
        }
        .menuBarExtraStyle(.menu)
    }
}

private struct MenuBarContent: View {
    @ObservedObject var authentication: WeBeepAuthenticationController

    var body: some View {
        Label(authentication.menuBarTitle, systemImage: authentication.menuBarSymbol)
            .accessibilityLabel(authentication.menuBarTitle)
        Text(authentication.syncState.detail)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        Button(authentication.menuBarActionTitle) {
            if authentication.isSyncActive {
                authentication.cancelSynchronization()
            } else if !authentication.conflicts.isEmpty {
                ConflictWindowController.shared.show(authentication)
            } else if authentication.accountState != .connected {
                authentication.startLogin()
            } else {
                authentication.synchronizeNow()
            }
        }
        Divider()
        Button("Apri Beepbar…") {
            ConfigurationWindowController.shared.show(authentication)
        }
        Button("Esci da Beepbar") { NSApp.terminate(nil) }
    }
}

@MainActor private final class ConfigurationWindowController: NSObject, NSWindowDelegate {
    static let shared = ConfigurationWindowController()
    private var window: NSWindow?
    private var appearanceTrace: OSSignpostIntervalState?

    func show(_ authentication: WeBeepAuthenticationController) {
        if window?.isKeyWindow != true {
            appearanceTrace = PerformanceTrace.shared.begin("ui.configurationWindow", category: .ui)
        }
        if let window {
            window.makeKeyAndOrderFront(nil)
        } else {
            let controller = NSHostingController(rootView: BeepbarShellView(authentication: authentication))
            let window = NSWindow(contentViewController: controller)
            window.title = "Beepbar"
            window.setContentSize(NSSize(width: 760, height: 640))
            window.minSize = NSSize(width: 640, height: 480)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            self.window = window
            window.makeKeyAndOrderFront(nil)
            authentication.refreshOnWindowOpen()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let appearanceTrace else { return }
        PerformanceTrace.shared.end("ui.configurationWindow", category: .ui, state: appearanceTrace)
        self.appearanceTrace = nil
    }
}

private struct BeepbarConfigurationView: View {
    @ObservedObject var authentication: WeBeepAuthenticationController

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Beepbar").font(.title2.weight(.semibold))
                    Text("Materiali WeBeep, in locale e senza sovrascritture silenziose.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(authentication.syncState.detail)
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                    .frame(maxWidth: 230)
            }
            .padding()
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    authenticationSection
                    destinationSection
                    coursesSection
                }
                .padding()
            }
        }
    }

    private var authenticationSection: some View {
        GroupBox("1. Collegamento WeBeep") {
            HStack {
                            Text(authentication.accountState.title)
                Spacer()
                if !authentication.hasStoredCredential {
                    Button("Accedi a WeBeep") { authentication.startLogin() }.disabled(authentication.isAuthenticating)
                }
                Button("Verifica") { authentication.validateConnection() }
                    .disabled(!authentication.hasStoredCredential || authentication.isAuthenticating || authentication.isVerifying)
                if !authentication.hasStoredCredential {
                    Button("Migra credenziale") { authentication.migrateLegacyCredential() }.disabled(authentication.isAuthenticating)
                }
            }.padding(.top, 4)
        }
    }

    private var destinationSection: some View {
        GroupBox("2. Cartella dei materiali") {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(authentication.rootURL?.path ?? "Scegli una cartella radice").textSelection(.enabled)
                    Text("Beepbar creerà una sottocartella stabile per ogni corso selezionato.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(authentication.rootURL == nil ? "Scegli cartella…" : "Cambia…") { authentication.chooseRoot() }
            }.padding(.top, 4)
        }
    }

    private var coursesSection: some View {
        GroupBox("3. Corsi da sincronizzare") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Abilita esplicitamente i corsi che vuoi includere.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Aggiorna corsi") { authentication.loadCourses() }
                        .disabled(!authentication.hasStoredCredential || authentication.isLoadingCourses)
                }
                if authentication.courses.isEmpty {
                    Text("Nessun corso caricato.").foregroundStyle(.secondary)
                } else {
                    ForEach(authentication.courses) { course in
                        Toggle(isOn: Binding(get: { authentication.isCourseEnabled(course) }, set: { authentication.setCourse(course, enabled: $0) })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(course.displayName)
                                Text(course.shortName).font(.caption).foregroundStyle(.secondary)
                                Text("Cartella: \(authentication.folder(for: course))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }.toggleStyle(.checkbox)
                    }
                }
            }.padding(.top, 4)
        }
    }

}

@MainActor private final class ConflictWindowController: NSObject, NSWindowDelegate {
    static let shared = ConflictWindowController()
    private var window: NSWindow?

    func show(_ authentication: WeBeepAuthenticationController) {
        authentication.refreshConflicts()
        if let window {
            window.makeKeyAndOrderFront(nil)
        } else {
            let window = NSWindow(contentViewController: NSHostingController(rootView: ConflictListView(authentication: authentication)))
            window.title = "Conflitti Beepbar"
            window.setContentSize(NSSize(width: 680, height: 420))
            window.minSize = NSSize(width: 520, height: 280)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            self.window = window
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}

private struct ConflictListView: View {
    @ObservedObject var authentication: WeBeepAuthenticationController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Conflitti") .font(.title2.weight(.semibold))
            Text("Le versioni remote sono conservate separatamente; nessun file locale è stato sovrascritto.")
                .font(.caption).foregroundStyle(.secondary)
            if authentication.conflicts.isEmpty {
                ContentUnavailableView("Nessun conflitto aperto", systemImage: "checkmark.circle")
            } else {
                List(authentication.conflicts) { conflict in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(conflict.relativePath.value).font(.body.weight(.medium))
                        Text("Versione remota conservata: \(conflict.incomingPath.value)")
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        HStack {
                            Button("Mantieni locale") { authentication.resolve(conflict, with: .keepLocal) }
                            Button("Usa versione remota") { authentication.resolve(conflict, with: .useRemote) }
                                .buttonStyle(.borderedProminent)
                        }
                        .disabled(authentication.resolvingConflictID != nil)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Aggiorna") { authentication.refreshConflicts() }
            }
        }
        .padding()
    }
}
