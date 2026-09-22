import SwiftUI
import BeepbarCore

struct OnboardingView: View {
    @ObservedObject var authentication: WeBeepAuthenticationController
    @State private var step: Step = .welcome

    private enum Step: Int, CaseIterable { case welcome, folder, wrapUp }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Group {
                switch step {
                case .welcome: welcomeStep
                case .folder: folderStep
                case .wrapUp: wrapUpStep
                }
            }
            .frame(maxWidth: 420)
            Spacer()
            footer
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var welcomeStep: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .font(.system(size: 46))
                .foregroundStyle(.tint)
            Text("Benvenuto in Beepbar").font(.title.weight(.semibold))
            Text("Sincronizza in sicurezza i materiali universitari sul tuo Mac.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 10) {
                onboardingPoint(systemImage: "lock.shield", text: "Non sovrascrive mai il tuo lavoro: se modifichi un file in locale, quella copia resta intoccata.")
                onboardingPoint(systemImage: "clock.arrow.circlepath", text: "Controlla i nuovi materiali in background, con la frequenza che scegli tu.")
                onboardingPoint(systemImage: "bolt.fill", text: "Nativo e leggero: vive nella barra dei menu, senza appesantire il Mac.")
            }
            .padding(.top, 6)
        }
    }

    private var folderStep: some View {
        VStack(spacing: 14) {
            Image(systemName: "folder.fill.badge.gearshape")
                .font(.system(size: 46))
                .foregroundStyle(.tint)
            Text("Scegli la cartella dei materiali").font(.title2.weight(.semibold))
            Text("Beepbar creerà qui dentro una sottocartella per ogni corso che abiliterai.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let rootURL = authentication.rootURL {
                Label(rootURL.path, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .padding(.top, 4)
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
    }

    private var wrapUpStep: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 46))
                .foregroundStyle(.tint)
            Text("Ci siamo quasi").font(.title2.weight(.semibold))
            accountBox
            VStack(alignment: .leading, spacing: 10) {
                onboardingPoint(systemImage: "arrow.triangle.2.circlepath", text: "Frequenza del controllo automatico e aggiornamenti dell'app: sempre modificabili da Impostazioni.")
                onboardingPoint(systemImage: "exclamationmark.triangle", text: "Se un file cambia sia sul tuo Mac sia su Moodle, lo trovi nella sezione Conflitti: decidi tu quale versione tenere.")
            }
        }
    }

    private var accountBox: some View {
        GroupBox {
            VStack(spacing: 12) {
                if !authentication.hasStoredCredential {
                    MoodleSitePicker(authentication: authentication)
                }
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Accedi a \(authentication.selectedSite.displayName)").font(.callout.weight(.medium))
                        Text(authentication.hasStoredCredential ? "Account collegato." : "Necessario per iniziare a sincronizzare i corsi.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if authentication.hasStoredCredential {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Accedi…") { authentication.startLogin() }
                            .buttonStyle(.borderedProminent)
                            .disabled(authentication.isAuthenticating)
                    }
                }
            }
            .padding(6)
        }
    }

    private func onboardingPoint(systemImage: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(.tint)
                .frame(width: 20)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        VStack(spacing: 12) {
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.self) { candidate in
                    Circle()
                        .fill(candidate == step ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 6, height: 6)
                }
            }
            HStack {
                if step != .welcome {
                    Button("Indietro") { step = Step(rawValue: step.rawValue - 1) ?? .welcome }
                }
                Spacer()
                if step == .wrapUp {
                    Button("Inizia a usare Beepbar") { authentication.completeOnboarding() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                } else {
                    Button("Continua") { step = Step(rawValue: step.rawValue + 1) ?? .wrapUp }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(step == .folder && authentication.rootURL == nil)
                }
            }
        }
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
