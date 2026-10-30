# Task ReadAlong v1

Convenzioni: ogni task in un worktree e branch propri (`tNN-<tema>`), PR verso `main`, `scripts/check.sh` verde. Dimensioni: S 1-2 file, M 3-5, L 5-8. Stato: `[ ]` da fare, `[~]` in corso, `[x]` integrato su main.

## Fase 0 — Fondamenta

### [x] T1: Scheletro dell'app Xcode (S→M)
**Descrizione.** Progetto XcodeGen `ios/project.yml` con target `ReadAlong` (SwiftUI, iOS 26, iPhone+iPad, Swift 6 strict) e `ReadAlongTests` (Swift Testing); entitlement e `Info.plist` già pronti per il futuro: `UIBackgroundModes: audio`, iCloud KVS, UTI esportato `it.fabiocrestoni.rabook` (conforme a `public.zip-archive`, estensione `rabook`) e `CFBundleDocumentTypes`. `scripts/check.sh` esegue xcodegen + build + test (+ pytest se `tools/makebook` esiste).
**Accettazione.** `scripts/check.sh` verde da zero; l'app si avvia sul simulatore con una schermata vuota "Libreria"; un test di esempio passa.
**Verifica.** `scripts/check.sh`; `xcodebuild … test`.
**Dipendenze.** Nessuna. **File.** `ios/project.yml`, `ios/ReadAlong/App/ReadAlongApp.swift`, `ios/ReadAlong/Resources/Info.plist`, `ios/ReadAlong/ReadAlong.entitlements`, `ios/ReadAlongTests/SmokeTests.swift`, `scripts/check.sh`.

### [ ] T2: `makebook`, generatore di `.rabook` (M)
**Descrizione.** Pacchetto Python `tools/makebook` (uv, Python 3.12) che porta in forma di CLI gli script già scritti: `extract.py` (EPUB → capitoli puliti: niente `<title>`, note, numeri di pagina, path di file; titolo capitolo sempre paragrafo a sé), `synth.py` (Piper + espeak-ng, frase per frase con tempi, `…`→`.`), `package.py` (zip *stored* con `book.json`, `chapters/NN.json`, `audio/NN.m4a`, `cover.jpg`; `id` = sha256 di titolo+autore+testo), `cli.py` (`makebook libro.epub -o out.rabook --voice … [--chapters 2,24]`). I PDF passano prima da `ebook-convert` (calibre). Genera e committa la fixture `tools/makebook/tests/fixtures/pinocchio.rabook` da due capitoli brevi di Pinocchio (Collodi, pubblico dominio; EPUB da Liber Liber o Gutenberg).
**Accettazione.** `uv run --project tools/makebook makebook pinocchio.epub -o pinocchio.rabook` produce un pacchetto valido (< 3 MB); pytest copre divisione in frasi, pulizia (incluso il caso del path nel `<title>`), validità dello zip e coerenza tempi ≤ durata audio; la fixture è committata (`.gitignore` con eccezione).
**Verifica.** `uv run --project tools/makebook pytest`; `unzip -l` mostra solo voci "Stored".
**Dipendenze.** Nessuna (gli script di partenza sono in `~/Projects/readalong/docs/seed/`). **File.** `tools/makebook/pyproject.toml`, `makebook/{extract,synth,package,cli}.py`, `tests/test_*.py`, `tests/fixtures/pinocchio.rabook`, `tools/makebook/README.md`.

## Fase 1 — Contratto

### [ ] T3: Modello e lettore di `.rabook` (M)
**Descrizione.** `Model/`: `Book`, `Chapter`, `Sentence`, `SentenceID(chapter, index)`, `Progress`, tutti `Codable`/`Sendable`. `Package/ZipReader.swift` (central directory, solo voci stored, errori tipizzati), `Package/RABookReader.swift` (valida `book.json`, versione formato, apre capitoli a richiesta), `Package/RABookImporter.swift` (copia il pacchetto in `Application Support/Books/<id>/` e ne scompatta le voci; idempotente). `Model/SentenceIndex.swift`: frase ↔ tempo (ricerca binaria) e frase ↔ offset carattere.
**Accettazione.** Con la fixture Pinocchio: apre il libro, elenca capitoli, trova la frase a un dato secondo, rifiuta uno zip con voci compresse e un `book.json` con `versioneFormato: 2` con errori distinti.
**Verifica.** Swift Testing su tutti i casi sopra; `scripts/check.sh`.
**Dipendenze.** T1, T2 (fixture; nel frattempo usa `ios/ReadAlongTests/Fixtures/mini.rabook` costruito a mano con `zip -0`). **File.** `ios/ReadAlong/Model/*.swift` (4), `ios/ReadAlong/Package/*.swift` (3), `ios/ReadAlongTests/PackageTests.swift`, `SentenceIndexTests.swift`.

## Fase 2 — Lettore

### [ ] T4: `PlayerEngine` (M)
**Descrizione.** `actor PlayerEngine` su `AVAudioPlayer`: `load(book:)`, `play()`, `pause()`, `seek(to: SentenceID)`, `seek(by: seconds)`, `rate`, passaggio automatico al capitolo successivo con precarica, `AsyncStream<PlaybackPosition>` a 10 Hz, `AVAudioSession` categoria `.playback`. Nessuna UI.
**Accettazione.** Test con la fixture: seek a una frase → `currentTime` entro 50 ms dal suo `s`; fine capitolo 1 → inizia capitolo 2 senza intervento; `rate` 1.5 mantiene il pitch (`enableRate`).
**Verifica.** Swift Testing (riproduzione reale su simulatore, timeout corti); `scripts/check.sh`.
**Dipendenze.** T3. **File.** `ios/ReadAlong/Playback/PlayerEngine.swift`, `PlaybackPosition.swift`, `ios/ReadAlongTests/PlayerEngineTests.swift`.

### [ ] T5: `SentenceTextView` (M)
**Descrizione.** `UIViewRepresentable` su `UITextView` non editabile: riceve il capitolo e la frase corrente, evidenzia solo quel range (sfondo + grassetto leggero), scorre per tenerla visibile se l'utente non sta scrollando, riporta la prima frase visibile e i tap (`onTapSentence`). Stile: dimensione carattere e tema da parametri.
**Accettazione.** Con il capitolo più lungo della fixture (e, a mano, con il capitolo 10 del Cigno nero): cambio frase a 10 Hz senza scatti (< 4 ms per aggiornamento misurati con `os_signpost`); tap su una frase chiama `onTapSentence` con l'id giusto; scroll manuale sospende l'autoscroll per 5 s.
**Verifica.** Test unitari sulla tabella offset→frase; misura prestazioni documentata nel PR; `scripts/check.sh`.
**Dipendenze.** T3. **File.** `ios/ReadAlong/UI/Reader/SentenceTextView.swift`, `ChapterAttributedText.swift`, `ios/ReadAlongTests/ChapterAttributedTextTests.swift`.

### [ ] T6: `ReaderView` e ripresa dalla frase in vista (M)
**Descrizione.** `ReaderModel` (`@MainActor @Observable`) collega T4 e T5: play/pausa, ±15 s, frase corrente evidenziata, tap → seek, regola di ripresa (se in pausa l'utente ha scrollato, play riparte dalla prima frase visibile). `PlayerBar` con copertina, titolo capitolo, tempo e barra. Entry point provvisorio: all'avvio apre la fixture se non c'è libreria.
**Accettazione.** Sul simulatore: play, il testo segue; tap → salto; pausa, scroll, play → riparte dalla frase in vista; ±15 s attraversa il confine di capitolo.
**Verifica.** Test della regola di ripresa in `ReaderModelTests`; collaudo manuale descritto nel PR con screenshot; `scripts/check.sh`.
**Dipendenze.** T4, T5. **File.** `ios/ReadAlong/UI/Reader/ReaderView.swift`, `ReaderModel.swift`, `PlayerBar.swift`, `ios/ReadAlongTests/ReaderModelTests.swift`.

### Checkpoint A
- [ ] `scripts/check.sh` verde su `main`
- [ ] *Il Cigno nero* (`.rabook` generato da T2) in riproduzione sul simulatore con testo sincronizzato
- [ ] Revisione di Fabio

## Fase 3 — Uso quotidiano (tutti in parallelo dopo A)

### [ ] T7: Stato locale e ripresa dopo kill (S)
**Descrizione.** `Sync/BookState.swift` (posizione, velocità, segnalibri vuoti, `updatedAt`) e `Sync/ProgressStore.swift` con salvataggio JSON in `Application Support/<id>/state.json`, debounce 2 s e salvataggio immediato su pausa/background. All'apertura il lettore riparte dalla frase salvata.
**Accettazione.** Kill e riapertura → stessa frase e stesso secondo; test di round-trip e di merge locale.
**Verifica.** Swift Testing; `scripts/check.sh`.
**Dipendenze.** T6. **File.** `ios/ReadAlong/Sync/BookState.swift`, `ProgressStore.swift`, `ios/ReadAlongTests/ProgressStoreTests.swift`, modifica a `ReaderModel.swift`.

### [ ] T8: Libreria e importazione (M)
**Descrizione.** `LibraryView` (griglia: copertina, titolo, autore, durata, % avanzamento), importazione via `fileImporter` e via "Apri in…"/AirDrop (`onOpenURL`), progresso durante la copia, cancellazione con conferma, errori leggibili (formato non supportato, versione futura, file corrotto).
**Accettazione.** Import di un `.rabook` da 350 MB dai File in < 15 s; il libro appare con copertina; riapertura dell'app → libreria persistente; import dello stesso libro non duplica.
**Verifica.** Test del catalogo (`LibraryStore`); collaudo manuale su simulatore con il Cigno nero; `scripts/check.sh`.
**Dipendenze.** T6. **File.** `ios/ReadAlong/UI/Library/LibraryView.swift`, `ImportFlow.swift`, `ios/ReadAlong/Package/LibraryStore.swift`, `ios/ReadAlongTests/LibraryStoreTests.swift`, modifica a `ReadAlongApp.swift`.

### [ ] T9: Background, Now Playing e comandi remoti (M)
**Descrizione.** `Playback/NowPlayingController.swift`: `MPNowPlayingInfoCenter` (copertina, titolo libro, capitolo, durata, posizione, rate) e `MPRemoteCommandCenter` (play, pausa, toggle, ±15 s, capitolo precedente/successivo); gestione interruzioni (telefonata) e disconnessione cuffie (pausa).
**Accettazione.** Schermo bloccato: audio continua 1 h; play/pausa e ±15 s da lock screen e da AirPods; sfilare le AirPods mette in pausa; copertina e capitolo corretti su lock screen.
**Verifica.** Collaudo su dispositivo (checklist in `docs/COLLAUDO.md`, sezione aggiunta da questo task); test unitari sulla costruzione del dizionario Now Playing; `scripts/check.sh`.
**Dipendenze.** T6. **File.** `ios/ReadAlong/Playback/NowPlayingController.swift`, `AudioSessionController.swift`, `ios/ReadAlongTests/NowPlayingTests.swift`, `docs/COLLAUDO.md`.

### [ ] T10: Velocità e timer di spegnimento (S→M)
**Descrizione.** Selettore velocità 0,8–2,0× a passi di 0,1, salvata nel `BookState`; `SleepTimer` (N minuti, fine capitolo) con fade-out di 3 s e annullamento; foglio impostazioni dal `PlayerBar`.
**Accettazione.** Velocità applicata subito e ricordata dopo la riapertura; il timer ferma l'audio al momento giusto (test con durate corte) e a fine capitolo.
**Verifica.** Swift Testing su `SleepTimer`; `scripts/check.sh`.
**Dipendenze.** T6, T7. **File.** `ios/ReadAlong/Playback/SleepTimer.swift`, `ios/ReadAlong/UI/Settings/PlaybackSettingsSheet.swift`, `ios/ReadAlongTests/SleepTimerTests.swift`, modifica a `ReaderModel.swift`.

### [ ] T11: Indice dei capitoli (S)
**Descrizione.** `ChapterListView`: titolo, durata, stato (letto / in corso con % / da leggere); tap → salto all'inizio del capitolo.
**Accettazione.** Percentuali corrette rispetto alla posizione; salto funziona durante la riproduzione.
**Verifica.** Test sul calcolo dell'avanzamento; `scripts/check.sh`.
**Dipendenze.** T6. **File.** `ios/ReadAlong/UI/Reader/ChapterListView.swift`, `ios/ReadAlongTests/ChapterProgressTests.swift`.

### [ ] T12: Impostazioni di lettura (S)
**Descrizione.** Dimensione carattere (5 passi) e tema chiaro/scuro/sepia, globali, in `UserDefaults`; applicati alla `SentenceTextView` senza perdere la posizione.
**Accettazione.** Cambio tema/carattere a riproduzione in corso: la frase evidenziata resta visibile.
**Verifica.** Collaudo manuale; `scripts/check.sh`.
**Dipendenze.** T6. **File.** `ios/ReadAlong/UI/Settings/ReadingSettings.swift`, `ReadingSettingsSheet.swift`.

### Checkpoint B
- [ ] Build su iPhone di Fabio (firma di sviluppo, senza TestFlight)
- [ ] Import del Cigno nero dai File, ascolto in auto con lock screen, riapertura al punto giusto
- [ ] Revisione di Fabio

## Fase 4 — Sync ed extra

### [ ] T13: Sincronizzazione iCloud (M)
**Descrizione.** `ProgressStore` specchia ogni `BookState` su `NSUbiquitousKeyValueStore` (chiave `book.<id>`), ascolta `didChangeExternallyNotification`, applica il merge (vince `updatedAt` più recente; segnalibri uniti per id, cancellazioni come tombstone). Il lettore, se riceve una posizione più recente mentre è in pausa, propone "Riprendi da iPad?" invece di saltare da solo.
**Accettazione.** Test di merge (locale più nuovo, remoto più nuovo, segnalibri disgiunti, tombstone); su due dispositivi la posizione arriva entro 60 s.
**Verifica.** Swift Testing con un `KeyValueStore` finto; collaudo iPhone+iPad; `scripts/check.sh`.
**Dipendenze.** T7. **File.** `ios/ReadAlong/Sync/ProgressStore.swift`, `CloudKeyValueStore.swift`, `StateMerge.swift`, `ios/ReadAlongTests/StateMergeTests.swift`.

### [ ] T14: Segnalibri (M)
**Descrizione.** Pressione lunga su una frase → segnalibro (con nota opzionale); lista per libro con anteprima della frase e salto; cancellazione; salvati nel `BookState` e sincronizzati tramite T13.
**Accettazione.** Creazione, lista, salto, cancellazione; dopo sync il segnalibro compare sull'altro dispositivo.
**Verifica.** Test su aggiunta/rimozione/merge; collaudo manuale; `scripts/check.sh`.
**Dipendenze.** T13, T5 (pressione lunga). **File.** `ios/ReadAlong/Model/Bookmark.swift`, `ios/ReadAlong/UI/Reader/BookmarksView.swift`, modifiche a `SentenceTextView.swift`, `ReaderModel.swift`, `ios/ReadAlongTests/BookmarkTests.swift`.

## Fase 5 — Rilascio

### [ ] T15: TestFlight e collaudo finale (S)
**Descrizione.** `ios/Tools/testflight.sh` adattato da `~/Projects/battlefits-ios/Tools/testflight.sh` (archivio, export, upload); `docs/COLLAUDO.md` completo con i 10 criteri di successo della spec e gli esiti; `README.md` del repo (come generare un libro e installare l'app).
**Accettazione.** Build installata via TestFlight sull'iPhone di Fabio; tutti i criteri di successo spuntati con data.
**Verifica.** Checklist compilata; `scripts/check.sh`.
**Dipendenze.** tutto. **File.** `ios/Tools/testflight.sh`, `docs/COLLAUDO.md`, `README.md`.

### Checkpoint C
- [ ] Criteri di successo 1–10 della spec verificati
- [ ] Approvazione finale di Fabio
