import SwiftUI
import BeepbarCore

struct OnboardingView: View {
    @ObservedObject var authentication: WeBeepAuthenticationController
    @State private var step: Step = .welcome
    @State private var movingForward = true

    private enum Step: Int, CaseIterable { case welcome, folder, wrapUp }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 16)
            Group {
                switch step {
                case .welcome: welcomeStep
                case .folder: folderStep
                case .wrapUp: wrapUpStep
                }
            }
            .frame(maxWidth: 440)
            .id(step)
            .transition(.asymmetric(
                insertion: .move(edge: movingForward ? .trailing : .leading).combined(with: .opacity),
                removal: .move(edge: movingForward ? .leading : .trailing).combined(with: .opacity)
            ))
            Spacer(minLength: 16)
            footer
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func hero(_ systemImage: String) -> some View {
        SymbolTile(systemImage: systemImage, size: 72)
            .shadow(color: .accentColor.opacity(0.35), radius: 14, y: 6)
            .padding(.bottom, 4)
    }

    private var welcomeStep: some View {
        VStack(spacing: 14) {
            BeepbarLogo(size: 88)
                .shadow(color: .blue.opacity(0.35), radius: 16, y: 8)
                .padding(.bottom, 4)
            Text("Benvenuto in Beepbar").font(.largeTitle.weight(.bold))
            Text("Sincronizza in sicurezza i materiali universitari sul tuo Mac.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 14) {
                onboardingPoint(systemImage: "lock.shield.fill", tint: .green, text: "Non sovrascrive mai il tuo lavoro: se modifichi un file in locale, quella copia resta intoccata.")
                onboardingPoint(systemImage: "clock.arrow.circlepath", tint: .blue, text: "Controlla i nuovi materiali in background, con la frequenza che scegli tu.")
                onboardingPoint(systemImage: "bolt.fill", tint: .orange, text: "Nativo e leggero: vive nella barra dei menu, senza appesantire il Mac.")
            }
            .card(padding: 18)
            .padding(.top, 10)
        }
    }

    private var folderStep: some View {
        VStack(spacing: 14) {
            hero("folder.fill.badge.gearshape")
            Text("Scegli la cartella dei materiali").font(.title.weight(.bold))
            Text("Qui dentro verrà creata una sottocartella per ogni corso che abiliterai.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let rootURL = authentication.rootURL {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.title3)
                    Text((rootURL.path as NSString).abbreviatingWithTildeInPath)
                        .font(.callout)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                .card(padding: 12)
                .padding(.top, 4)
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
            Button(authentication.rootURL == nil ? "Scegli cartella…" : "Cambia cartella…") {
                authentication.chooseRoot()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 4)
            if case .failed = authentication.syncState, authentication.rootURL == nil {
                Text(authentication.syncState.detail)
                    .font(.caption).foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
            Text("Nessun problema, potrai cambiarla in qualsiasi momento da Impostazioni.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .animation(BeepbarStyle.snappy, value: authentication.rootURL)
    }

    private var wrapUpStep: some View {
        VStack(spacing: 14) {
            hero("checkmark.seal.fill")
            Text("Ci siamo quasi").font(.title.weight(.bold))
            accountBox
            VStack(alignment: .leading, spacing: 14) {
                onboardingPoint(systemImage: "slider.horizontal.3", tint: .blue, text: "Frequenza del controllo automatico e aggiornamenti dell'app: sempre modificabili da Impostazioni.")
                onboardingPoint(systemImage: "exclamationmark.triangle.fill", tint: .orange, text: "Se un file cambia sia sul tuo Mac sia su \(authentication.selectedSite.platformName), lo trovi nella sezione Conflitti: decidi tu quale versione tenere.")
            }
            .padding(.top, 6)
        }
    }

    private var accountBox: some View {
        VStack(spacing: 12) {
            if !authentication.hasStoredCredential {
                MoodleSitePicker(authentication: authentication)
            }
            HStack(spacing: 12) {
                SymbolTile(
                    systemImage: authentication.hasStoredCredential ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.plus",
                    tint: authentication.hasStoredCredential ? .green : .accentColor,
                    size: 34
                )
                VStack(alignment: .leading, spacing: 3) {
                    Text("Accedi a \(authentication.selectedSite.displayName)").font(.callout.weight(.medium))
                    Text(authentication.hasStoredCredential ? "Account collegato." : "Necessario per iniziare a sincronizzare i corsi.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if authentication.hasStoredCredential {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.green)
                } else {
                    Button("Accedi…") { authentication.startLogin() }
                        .buttonStyle(.borderedProminent)
                        .disabled(authentication.isAuthenticating)
                }
            }
        }
        .card()
    }

    private func onboardingPoint(systemImage: String, tint: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            SymbolTile(systemImage: systemImage, tint: tint, size: 28, filled: false)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        VStack(spacing: 14) {
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.self) { candidate in
                    Capsule()
                        .fill(candidate == step ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: candidate == step ? 18 : 6, height: 6)
                }
            }
            HStack {
                if step != .welcome {
                    Button("Indietro") { go(to: Step(rawValue: step.rawValue - 1) ?? .welcome) }
                        .controlSize(.large)
                }
                Spacer()
                if step == .wrapUp {
                    // Not the default action: Return must not skip past the sign-in above.
                    Button("Inizia a usare Beepbar") { authentication.completeOnboarding() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                } else {
                    Button("Continua") { go(to: Step(rawValue: step.rawValue + 1) ?? .wrapUp) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                        .disabled(step == .folder && authentication.rootURL == nil)
                }
            }
        }
    }

    private func go(to target: Step) {
        movingForward = target.rawValue > step.rawValue
        withAnimation(BeepbarStyle.snappy) { step = target }
    }
}

struct MoodleSitePicker: View {
    @ObservedObject var authentication: WeBeepAuthenticationController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Università", selection: Binding(
                get: { authentication.selectedSite.university },
                set: { authentication.selectUniversity($0) }
            )) {
                ForEach(MoodleUniversity.allCases) { university in
                    Text(university.displayName).tag(university)
                }
            }
            if authentication.selectedSite.university == .unipd {
                Picker("Area Moodle", selection: Binding(
                    get: { authentication.selectedSite },
                    set: { authentication.selectSite($0) }
                )) {
                    ForEach(MoodleSite.unipd) { site in
                        Text(site.displayName).tag(site)
                    }
                }
            }
        }
    }
}
