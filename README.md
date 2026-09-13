# Beepbar

Companion macOS non ufficiale per sincronizzare in locale i materiali di WeBeep.

Beepbar salva il token nel Portachiavi di macOS e non sovrascrive mai in silenzio file modificati localmente: le versioni in conflitto restano separate finché non scegli quale mantenere.

## Requisiti

- macOS 14 o successivo
- Apple Silicon

## Sviluppo

```sh
swift test
xcodebuild -project Beepbar.xcodeproj -target Beepbar -configuration Release build CODE_SIGNING_ALLOWED=NO
scripts/create-dmg.sh build/Release/Beepbar.app build/Beepbar-unsigned.dmg
```

La CI esegue i test e allega un DMG arm64 non firmato. Senza un account Apple Developer e notarizzazione, macOS puo richiedere di autorizzare manualmente la prima apertura.

Beepbar non e affiliata a Politecnico di Milano o WeBeep.
