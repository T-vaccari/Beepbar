# Beepbar

Companion macOS nativo e non ufficiale per sincronizzare in locale i materiali di WeBeep.

Beepbar salva il token nel Portachiavi di macOS e non sovrascrive mai in silenzio file modificati localmente: le versioni in conflitto restano separate finché non scegli quale mantenere.

## Funzionalità

- menu bar discreta con stato di sincronizzazione e azione contestuale;
- accesso WeBeep nel browser e token custodito nel Portachiavi di macOS;
- sincronizzazione manuale o automatica configurabile;
- download paralleli controllati, progresso e annullamento reale;
- rinomina delle cartelle dei corsi e scelta della cartella radice;
- sync three-way con baseline SQLite, staging e rename atomico;
- risoluzione esplicita dei conflitti: conserva locale oppure usa il remoto.

## Perché Beepbar

Beepbar è pensata solo per macOS e Apple Silicon: non usa Electron, non tenta di essere multipiattaforma e non sincronizza mai modifiche locali alla cieca. La UI principale si apre solo dalla menu bar; il lavoro di rete e filesystem resta isolato dalla UI.

In una misura locale preliminare della build Release, con sincronizzazione automatica disattivata, è rimasta per 30 minuti intorno a 14–15 MiB di memoria con CPU praticamente inattiva. È un riferimento di sviluppo, non una garanzia universale.

## Requisiti

- macOS 14 o successivo
- Apple Silicon

## Installazione

1. Scarica `Beepbar-unsigned.dmg` dall'ultima release e trascina Beepbar in Applicazioni.
2. Al primo avvio, fai clic destro su Beepbar e scegli **Apri**. Se macOS la blocca, vai in **Impostazioni di Sistema > Privacy e Sicurezza** e scegli **Apri comunque**.
3. Apri Beepbar dalla menu bar, accedi a WeBeep nel browser e scegli la cartella locale da sincronizzare.

Il DMG è arm64 ma al momento non è firmato né notarizzato, quindi il passaggio iniziale di Gatekeeper è previsto. Per utenti esperti, dopo aver spostato l'app in Applicazioni, è disponibile anche:

```sh
xattr -dr com.apple.quarantine /Applications/Beepbar.app
```

## Sviluppo

```sh
swift test
xcodebuild -project Beepbar.xcodeproj -target Beepbar -configuration Release build CODE_SIGNING_ALLOWED=NO
scripts/create-dmg.sh build/Release/Beepbar.app build/Beepbar-unsigned.dmg
```

La CI esegue i test e crea un DMG arm64 non firmato.

Beepbar non e affiliata a Politecnico di Milano o WeBeep.
