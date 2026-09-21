import AppKit
import BeepbarCore
import SwiftUI
import os

@main
struct BeepbarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // No window-bearing scene: the status item and its menu are owned and driven
        // entirely by AppKit (see StatusItemController) to avoid the SwiftUI MenuBarExtra
        // Button→AppKit bridging path that crashed with SIGBUS in ButtonAction.callAsFunction()
        // when @Published state mutated during menu tracking (issue #30). `Settings` is the
        // lightest scene that satisfies `App`'s requirement without creating any UI on launch.
        Settings { EmptyView() }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    // Owned here, not by the SwiftUI App struct: for a window-less scene, SwiftUI doesn't
    // guarantee `body` runs before applicationDidFinishLaunching, so a reference handed over
    // from `body` can still be nil when this fires. AppKit does guarantee the delegate itself
    // is fully constructed and assigned before that call, so creating the controller here
    // removes the race entirely.
    let authentication = WeBeepAuthenticationController()
    private var statusItemController: StatusItemController?
    private var terminationPending = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = UpdaterController.shared
        statusItemController = StatusItemController(authentication: authentication)
        guard authentication.needsOnboarding else { return }
        ConfigurationWindowController.shared.show(authentication)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let syncTask = authentication.prepareForTermination() else { return .terminateNow }
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        Task { [weak self] in
            await syncTask.value
            self?.finishTermination()
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            self?.finishTermination()
        }
        return .terminateLater
    }

    private func finishTermination() {
        guard terminationPending else { return }
        terminationPending = false
        NSApp.reply(toApplicationShouldTerminate: true)
    }
}

/// Hand-built NSStatusItem/NSMenu replacement for the old SwiftUI `MenuBarExtra`.
/// Menu items are discarded and rebuilt from scratch in `menuNeedsUpdate(_:)` right before
/// each time the menu opens, instead of being bound to `@Published` state via SwiftUI.
///
/// Deliberately NOT `@MainActor`, and deliberately never calls into any `@MainActor`-isolated
/// member of `authentication` synchronously. AppKit invokes `NSMenuDelegate`/target-action
/// methods via Objective-C dispatch, and bridging that into `@MainActor`-isolated Swift code
/// (whether through a compiler-synthesized `@objc` thunk or an explicit `MainActor.assumeIsolated`)
/// makes the Swift runtime dynamically re-verify "is this actually the main executor?"
/// (`swift_task_isCurrentExecutorWithFlagsImpl` → `swift_getObjectType`). On this OS build that
/// verification itself crashes with SIGBUS at a fixed address inside `libswiftCore.dylib` — the
/// same instruction, same address, in five separate app builds, both before and after #31's
/// MenuBarExtra→NSStatusItem rewrite (`ButtonAction.callAsFunction()` pre-#31,
/// `menuNeedsUpdate(_:)` post-#31), always on the first status-item interaction after the Mac
/// wakes from sleep. #31 relocated which `@objc` call site triggered the check; it didn't remove
/// the check, so the crash reappeared. The delegate requirement itself is `@MainActor` in the
/// AppKit SDK, so its implementation must be explicitly `nonisolated`; otherwise its generated
/// Objective-C thunk performs the crashing check before the method body can read the snapshot.
/// The method reads only `authentication`'s `nonisolated(unsafe) menuBarSnapshot` — see its doc
/// comment — and the action methods hand off to the main actor via `Task`.
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let authentication: WeBeepAuthenticationController

    @MainActor init(authentication: WeBeepAuthenticationController) {
        self.authentication = authentication
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        let image = NSImage(systemSymbolName: authentication.menuBarSymbol, accessibilityDescription: "Beepbar")
        image?.isTemplate = true
        statusItem.button?.image = image
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let snapshot = authentication.menuBarSnapshot

        let titleItem = NSMenuItem()
        titleItem.title = snapshot.title
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        let detailItem = NSMenuItem()
        detailItem.attributedTitle = NSAttributedString(
            string: snapshot.detail,
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.secondaryLabelColor]
        )
        detailItem.isEnabled = false
        menu.addItem(detailItem)

        let actionItem = NSMenuItem(title: snapshot.actionTitle, action: #selector(performAction), keyEquivalent: "")
        actionItem.target = self
        menu.addItem(actionItem)

        menu.addItem(.separator())

        let openItem = NSMenuItem(title: "Apri Beepbar…", action: #selector(openConfiguration), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        let quitItem = NSMenuItem(title: "Esci da Beepbar", action: #selector(quit), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    @objc private func performAction() {
        let authentication = authentication
        Task { @MainActor in authentication.performMenuBarAction() }
    }

    @objc private func openConfiguration() {
        let authentication = authentication
        Task { @MainActor in ConfigurationWindowController.shared.show(authentication) }
    }

    @objc private func quit() {
        Task { @MainActor in NSApp.terminate(nil) }
    }
}

@MainActor final class ConfigurationWindowController: NSObject, NSWindowDelegate {
    static let shared = ConfigurationWindowController()
    private var window: NSWindow?
    private var appearanceTrace: OSSignpostIntervalState?

    func show(_ authentication: WeBeepAuthenticationController) {
        if window?.isKeyWindow != true {
            if let appearanceTrace {
                PerformanceTrace.shared.end("ui.configurationWindow", category: .ui, state: appearanceTrace)
            }
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
        }
        authentication.refreshOnWindowOpen()
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        if let appearanceTrace {
            PerformanceTrace.shared.end("ui.configurationWindow", category: .ui, state: appearanceTrace)
        }
        appearanceTrace = nil
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let appearanceTrace else { return }
        PerformanceTrace.shared.end("ui.configurationWindow", category: .ui, state: appearanceTrace)
        self.appearanceTrace = nil
    }
}

@MainActor final class ConflictWindowController: NSObject, NSWindowDelegate {
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
