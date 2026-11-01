# Task ReadAlong v1

Convenzioni: ogni task in un worktree e branch propri (`tNN-<tema>`), PR verso `main`, `scripts/check.sh` verde. Dimensioni: S 1-2 file, M 3-5, L 5-8. Stato: `[ ]` da fare, `[~]` in corso, `[x]` integrato su main.

## Fase 0 — Fondamenta

### [x] T1: Scheletro dell'app Xcode (S→M)
**Descrizione.** Progetto XcodeGen `ios/project.yml` con target `ReadAlong` (SwiftUI, iOS 26, iPhone+iPad, Swift 6 strict) e `ReadAlongTests` (Swift Testing); entitlement e `Info.plist` già pronti per il futuro: `UIBackgroundModes: audio`, iCloud KVS, UTI esportato `it.fabiocrestoni.rabook` (conforme a `public.zip-archive`, estensione `rabook`) e `CFBundleDocumentTypes`. `scripts/check.sh` esegue xcodegen + build + test (+ pytest se `tools/makebook` esiste).
**Accettazione.** `scripts/check.sh` verde da zero; l'app si avvia sul simulatore con una schermata vuota "Libreria"; un test di esempio passa.
**Verifica.** `scripts/check.sh`; `xcodebuild … test`.
**Dipendenze.** Nessuna. **File.** `ios/project.yml`, `ios/ReadAlong/App/ReadAlongApp.swift`, `ios/ReadAlong/Resources/Info.plist`, `ios/ReadAlong/ReadAlong.entitlements`, `ios/ReadAlongTests/SmokeTests.swift`, `scripts/check.sh`.

### [x] T2: `makebook`, generatore di `.rabook` (M)
**Descrizione.** Pacchetto Python `tools/makebook` (uv, Python 3.12) che porta in forma di CLI gli script già scritti: `extract.py` (EPUB → capitoli puliti: niente `<title>`, note, numeri di pagina, path di file; titolo capitolo sempre paragrafo a sé), `synth.py` (Piper + espeak-ng, frase per frase con tempi, `…`→`.`), `package.py` (zip *stored* con `book.json`, `chapters/NN.json`, `audio/NN.m4a`, `cover.jpg`; `id` = sha256 di titolo+autore+testo), `cli.py` (`makebook libro.epub -o out.rabook --voice … [--chapters 2,24]`). I PDF passano prima da `ebook-convert` (calibre). Genera e committa la fixture `tools/makebook/tests/fixtures/pinocchio.rabook` da due capitoli brevi di Pinocchio (Collodi, pubblico dominio; EPUB da Liber Liber o Gutenberg).
**Accettazione.** `uv run --project tools/makebook makebook pinocchio.epub -o pinocchio.rabook` produce un pacchetto valido (< 3 MB); pytest copre divisione in frasi, pulizia (incluso il caso del path nel `<title>`), validità dello zip e coerenza tempi ≤ durata audio; la fixture è committata (`.gitignore` con eccezione).
**Verifica.** `uv run --project tools/makebook pytest`; `unzip -l` mostra solo voci "Stored".
**Dipendenze.** Nessuna (gli script di partenza sono in `~/Projects/readalong/docs/seed/`). **File.** `tools/makebook/pyproject.toml`, `makebook/{extract,synth,package,cli}.py`, `tests/test_*.py`, `tests/fixtures/pinocchio.rabook`, `tools/makebook/README.md`.

## Fase 1 — Contratto

### [x] T3: Modello e lettore di `.rabook` (M)
**Descrizione.** `Model/`: `Book`, `Chapter`, `Sentence`, `SentenceID(chapter, index)`, `Progress`, tutti `Codable`/`Sendable`. `Package/ZipReader.swift` (central directory, solo voci stored, errori tipizzati), `Package/RABookReader.swift` (valida `book.json`, versione formato, apre capitoli a richiesta), `Package/RABookImporter.swift` (copia il pacchetto in `Application Support/Books/<id>/` e ne scompatta le voci; idempotente). `Model/SentenceIndex.swift`: frase ↔ tempo (ricerca binaria) e frase ↔ offset carattere.
**Accettazione.** Con la fixture Pinocchio: apre il libro, elenca capitoli, trova la frase a un dato secondo, rifiuta uno zip con voci compresse e un `book.json` con `versioneFormato: 2` con errori distinti.
**Verifica.** Swift Testing su tutti i casi sopra; `scripts/check.sh`.
**Dipendenze.** T1, T2 (fixture; nel frattempo usa `ios/ReadAlongTests/Fixtures/mini.rabook` costruito a mano con `zip -0`). **File.** `ios/ReadAlong/Model/*.swift` (4), `ios/ReadAlong/Package/*.swift` (3), `ios/ReadAlongTests/PackageTests.swift`, `SentenceIndexTests.swift`.

## Fase 2 — Lettore

### [x] T4: `PlayerEngine` (M)
**Descrizione.** `actor PlayerEngine` su `AVAudioPlayer`: `load(book:)`, `play()`, `pause()`, `seek(to: SentenceID)`, `seek(by: seconds)`, `rate`, passaggio automatico al capitolo successivo con precarica, `AsyncStream<PlaybackPosition>` a 10 Hz, `AVAudioSession` categoria `.playback`. Nessuna UI.
**Accettazione.** Test con la fixture: seek a una frase → `currentTime` entro 50 ms dal suo `s`; fine capitolo 1 → inizia capitolo 2 senza intervento; `rate` 1.5 mantiene il pitch (`enableRate`).
**Verifica.** Swift Testing (riproduzione reale su simulatore, timeout corti); `scripts/check.sh`.
**Dipendenze.** T3. **File.** `ios/ReadAlong/Playback/PlayerEngine.swift`, `PlaybackPosition.swift`, `ios/ReadAlongTests/PlayerEngineTests.swift`.

### [x] T5: `SentenceTextView` (M)
**Descrizione.** `UIViewRepresentable` su `UITextView` non editabile: riceve il capitolo e la frase corrente, evidenzia solo quel range (sfondo + grassetto leggero), scorre per tenerla visibile se l'utente non sta scrollando, riporta la prima frase visibile e i tap (`onTapSentence`). Stile: dimensione carattere e tema da parametri.
**Accettazione.** Con il capitolo più lungo della fixture (e, a mano, con il capitolo 10 del Cigno nero): cambio frase a 10 Hz senza scatti (< 4 ms per aggiornamento misurati con `os_signpost`); tap su una frase chiama `onTapSentence` con l'id giusto; scroll manuale sospende l'autoscroll per 5 s.
**Verifica.** Test unitari sulla tabella offset→frase; misura prestazioni documentata nel PR; `scripts/check.sh`.
**Dipendenze.** T3. **File.** `ios/ReadAlong/UI/Reader/SentenceTextView.swift`, `ChapterAttributedText.swift`, `ios/ReadAlongTests/ChapterAttributedTextTests.swift`.

### [x] T6: `ReaderView` e ripresa dalla frase in vista (M)
**Descrizione.** `ReaderModel` (`@MainActor @Observable`) collega T4 e T5: play/pausa, ±15 s, frase corrente evidenziata, tap → seek, regola di ripresa (se in pausa l'utente ha scrollato, play riparte dalla prima frase visibile). `PlayerBar` con copertina, titolo capitolo, tempo e barra. Entry point provvisorio: all'avvio apre la fixture se non c'è libreria.
**Accettazione.** Sul simulatore: play, il testo segue; tap → salto; pausa, scroll, play → riparte dalla frase in vista; ±15 s attraversa il confine di capitolo.
**Verifica.** Test della regola di ripresa in `ReaderModelTests`; collaudo manuale descritto nel PR con screenshot; `scripts/check.sh`.
**Dipendenze.** T4, T5. **File.** `ios/ReadAlong/UI/Reader/ReaderView.swift`, `ReaderModel.swift`, `PlayerBar.swift`, `ios/ReadAlongTests/ReaderModelTests.swift`.

### Checkpoint A
- [x] `scripts/check.sh` verde su `main` (2026-10-30: 62 test Swift, 67 pytest, verificato sul ramo t06-reader prima del merge)
- [x] *Il Cigno nero* (`.rabook` generato da T2) in riproduzione sul simulatore con testo sincronizzato (2026-10-30, collaudo pilotato: play, tap, pausa+scroll+play)
- [x] Revisione di Fabio (2026-10-30: approvato). Difetti del generatore emersi: EPUB da PDF senza `pdf_mode` → righe spezzate (usare il PDF come sorgente); frontespizio nel Prologo (T2b); Note e Bibliografia da escludere (`--chapters 1-24`)

## Fase 3 — Uso quotidiano (tutti in parallelo dopo A)

### [x] T2b: makebook, frontespizio e modalità PDF automatica (S) — 2026-10-30
Emerso al checkpoint A: il frontespizio (Copertina, Colophon, Dedica: voci dell'indice sotto le 40 parole con testo oltre il titolo) finiva nel Prologo; `pdf_mode` non si attivava sugli EPUB fatti da calibre a partire da un PDF. Ora `drop_front_matter` scarta e conta le parole; `pdf_mode=None` rileva calibre + pagine con `<title>` `.pdf`/`PDF Reflow`; flag `--pdf-mode/--no-pdf-mode`. 13 test pytest nuovi.

### [x] T7: Stato locale e ripresa dopo kill (S) — integrato 2026-10-30 (79 test Swift verdi; collaudo kill/riapertura sul simulatore da fare con T8)
**Descrizione.** `Sync/BookState.swift` (posizione, velocità, segnalibri vuoti, `updatedAt`) e `Sync/ProgressStore.swift` con salvataggio JSON in `Application Support/<id>/state.json`, debounce 2 s e salvataggio immediato su pausa/background. All'apertura il lettore riparte dalla frase salvata.
**Accettazione.** Kill e riapertura → stessa frase e stesso secondo; test di round-trip e di merge locale.
**Verifica.** Swift Testing; `scripts/check.sh`.
**Dipendenze.** T6. **File.** `ios/ReadAlong/Sync/BookState.swift`, `ProgressStore.swift`, `ios/ReadAlongTests/ProgressStoreTests.swift`, modifica a `ReaderModel.swift`.

### [x] T8: Libreria e importazione (M) — integrato 2026-10-30 (estrazione 430 MB in 3,6 s; libreria radice, riapertura ultimo libro)
**Descrizione.** `LibraryView` (griglia: copertina, titolo, autore, durata, % avanzamento), importazione via `fileImporter` e via "Apri in…"/AirDrop (`onOpenURL`), progresso durante la copia, cancellazione con conferma, errori leggibili (formato non supportato, versione futura, file corrotto).
**Accettazione.** Import di un `.rabook` da 350 MB dai File in < 15 s; il libro appare con copertina; riapertura dell'app → libreria persistente; import dello stesso libro non duplica.
**Verifica.** Test del catalogo (`LibraryStore`); collaudo manuale su simulatore con il Cigno nero; `scripts/check.sh`.
**Dipendenze.** T6. **File.** `ios/ReadAlong/UI/Library/LibraryView.swift`, `ImportFlow.swift`, `ios/ReadAlong/Package/LibraryStore.swift`, `ios/ReadAlongTests/LibraryStoreTests.swift`, modifica a `ReadAlongApp.swift`.

### [x] T9: Background, Now Playing e comandi remoti (M) — integrato 2026-10-30 (collaudo su dispositivo al checkpoint B con docs/COLLAUDO.md)
**Descrizione.** `Playback/NowPlayingController.swift`: `MPNowPlayingInfoCenter` (copertina, titolo libro, capitolo, durata, posizione, rate) e `MPRemoteCommandCenter` (play, pausa, toggle, ±15 s, capitolo precedente/successivo); gestione interruzioni (telefonata) e disconnessione cuffie (pausa).
**Accettazione.** Schermo bloccato: audio continua 1 h; play/pausa e ±15 s da lock screen e da AirPods; sfilare le AirPods mette in pausa; copertina e capitolo corretti su lock screen.
**Verifica.** Collaudo su dispositivo (checklist in `docs/COLLAUDO.md`, sezione aggiunta da questo task); test unitari sulla costruzione del dizionario Now Playing; `scripts/check.sh`.
**Dipendenze.** T6. **File.** `ios/ReadAlong/Playback/NowPlayingController.swift`, `AudioSessionController.swift`, `ios/ReadAlongTests/NowPlayingTests.swift`, `docs/COLLAUDO.md`.

### [x] T10: Velocità e timer di spegnimento (S→M) — integrato 2026-10-30 (timer su minuti di ascolto; fade 3 s)
**Descrizione.** Selettore velocità 0,8–2,0× a passi di 0,1, salvata nel `BookState`; `SleepTimer` (N minuti, fine capitolo) con fade-out di 3 s e annullamento; foglio impostazioni dal `PlayerBar`.
**Accettazione.** Velocità applicata subito e ricordata dopo la riapertura; il timer ferma l'audio al momento giusto (test con durate corte) e a fine capitolo.
**Verifica.** Swift Testing su `SleepTimer`; `scripts/check.sh`.
**Dipendenze.** T6, T7. **File.** `ios/ReadAlong/Playback/SleepTimer.swift`, `ios/ReadAlong/UI/Settings/PlaybackSettingsSheet.swift`, `ios/ReadAlongTests/SleepTimerTests.swift`, modifica a `ReaderModel.swift`.

### [x] T11: Indice dei capitoli (S) — integrato 2026-10-30
**Descrizione.** `ChapterListView`: titolo, durata, stato (letto / in corso con % / da leggere); tap → salto all'inizio del capitolo.
**Accettazione.** Percentuali corrette rispetto alla posizione; salto funziona durante la riproduzione.
**Verifica.** Test sul calcolo dell'avanzamento; `scripts/check.sh`.
**Dipendenze.** T6. **File.** `ios/ReadAlong/UI/Reader/ChapterListView.swift`, `ios/ReadAlongTests/ChapterProgressTests.swift`.

### [x] T12: Impostazioni di lettura (S) — integrato 2026-10-30 (cambio carattere a riproduzione in corso da provare a mano al checkpoint B)
**Descrizione.** Dimensione carattere (5 passi) e tema chiaro/scuro/sepia, globali, in `UserDefaults`; applicati alla `SentenceTextView` senza perdere la posizione.
**Accettazione.** Cambio tema/carattere a riproduzione in corso: la frase evidenziata resta visibile.
**Verifica.** Collaudo manuale; `scripts/check.sh`.
**Dipendenze.** T6. **File.** `ios/ReadAlong/UI/Settings/ReadingSettings.swift`, `ReadingSettingsSheet.swift`.

### Checkpoint B
- [x] Build su iPhone di Fabio (2026-10-30, `ios/Tools/build-device.sh`; entitlement iCloud escluso finché Apple non ha il PLA accettato)
- [x] Import del Cigno nero da Dropbox e lettura sull'iPhone (2026-10-30; lock screen e auto da verificare con `docs/COLLAUDO.md`)
- [x] Revisione di Fabio (2026-10-30: «funziona ma ho delle osservazioni»: righe spezzate → dati vecchi, rigenerazione in corso; stacco tra paragrafi troppo grande → T12b)

### [x] T12b: Stacco tra paragrafi a mezza riga (XS) — integrato 2026-10-30 (causa: paragrafo vuoto del separatore "\n\n"; ora 0,5 righe)
Dallo screenshot di Fabio: tra due paragrafi c'è una riga vuota intera. Capire la causa con un test che misura, portare lo stacco a ~mezza riga senza disallineare `SentenceIndex.characterRanges`.

## Fase 4 — Sync ed extra

### [x] T13: Sincronizzazione iCloud (M) — 2026-10-31
**Descrizione.** `ProgressStore` specchia ogni `BookState` su `NSUbiquitousKeyValueStore` (chiave `book.<id>`), ascolta `didChangeExternallyNotification`, applica il merge (vince `updatedAt` più recente; segnalibri uniti per id, cancellazioni come tombstone). Il lettore, se riceve una posizione più recente mentre è in pausa, propone "Riprendi da iPad?" invece di saltare da solo.
**Accettazione.** Test di merge (locale più nuovo, remoto più nuovo, segnalibri disgiunti, tombstone); su due dispositivi la posizione arriva entro 60 s.
**Verifica.** Swift Testing con un `KeyValueStore` finto; collaudo iPhone+iPad; `scripts/check.sh`.
**Dipendenze.** T7. **File.** `ios/ReadAlong/Sync/ProgressStore.swift`, `CloudKeyValueStore.swift`, `StateMerge.swift`, `ios/ReadAlongTests/StateMergeTests.swift`.
**Note.** Sync dietro il protocollo `SyncStore` (ADR 0002), implementato da `CloudKeyValueStore`; nei test `InMemorySyncStore` con più "dispositivi" su un cloud condiviso. Chiave `book.<id>` accorciata a 64 byte (limite KVS, gli id sono sha256 da 64 caratteri): l'id completo sta nel valore. `BookState` ha campi nuovi facoltativi (`deletedBookmarks`, `device`, `Bookmark.modifiedAt`), il formato precedente si legge e si riscrive identico. Merge in `StateMerge` (deterministico: a parità di `updatedAt` vince la posizione più avanti, non più "il locale", che avrebbe fatto rimbalzare due record con la stessa data). `ProgressStore` scrive sul `SyncStore` subito su pausa/flush/background, `update` e cambio capitolo, in riproduzione al massimo una volta ogni 30 s (`remoteWriteInterval`; il resto parte a fine finestra); riconcilia dopo queste scritture, all'avvio, al ritorno in primo piano e a ogni cambiamento esterno, una riconciliazione alla volta; notifica `externalChanges()` e `externalRevision` (libreria). `ReaderModel.pendingRemotePosition` + barra "Riprendi / Ignora" in `ReaderView`; segnalibri ricaricati al merge. `LibraryStore.onDelete` → `removeState` (il remoto resta). Da fare nel collaudo T15: due dispositivi veri (la firma con l'entitlement KVS richiede la PLA accettata), tempo di propagazione entro 60 s.

### [x] T14: Segnalibri (M) — integrato 2026-10-30
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

### [x] T16: Icona app e spaziatura griglia libreria (S) — 2026-10-31
**Note.** Icona da un solo PNG 1024 in `Resources/Assets.xcassets` (`ASSETCATALOG_COMPILER_APPICON_NAME`); le copertine attaccate erano colpa di `CoverImage` (immagine 3:4 `scaledToFill` in un frame `maxWidth: .infinity` che allargava la cella), ora in overlay su `Color.clear`; colonne da `LibraryGridMetrics` (20 pt tra celle e bordi, 2 colonne su iPhone, 4+ su iPad), testata in `LibraryGridMetricsTests`.

### [x] T17: Controlli di riproduzione riducibili a pillola (S) — 2026-10-31
**Note.** `ReadingSettings.isPlayerMinimized` (chiave `reading.playerMinimized`, default barra completa, globale e persistente). `PlayerBar` mostra la barra completa con chevron "Riduci i controlli" (`player.minimize`) o una pillola a destra con play/pausa, `player.elapsed` e chevron "Mostra i controlli" (`player.expand`); tocco sulla pillola e swipe giù/su (`PlayerBarSwipe`, testato) cambiano stato con animazione `.snappy`. Il testo sta sotto la fascia (trasparente ai lati della pillola, tocchi inclusi); al cambio di inset il bordo alto resta fermo e, riaprendo la barra, la frase in lettura se era in vista torna sopra la barra (`insetChangeTarget`, testato). Screenshot dei due stati sul simulatore.

### [ ] T18: Kindle via KOReader e KOSync (M)
**Descrizione.** Vedi SPEC «Kindle via KOReader e KOSync». Tre parti indipendenti sul contratto fissato nella spec: **T18a** makebook `--epub` (EPUB 3 deterministico, un XHTML per capitolo, solo un `<p>` per paragrafo, partial MD5 alla KOReader scritto in `book.json` → `kindle.documento`); **T18b** app: `KOSyncClient`, traduzione XPointer ↔ frase, impostazioni Kindle (Keychain), aggancio a `ProgressStore` e alla proposta di T13 con dispositivo «Kindle»; **T18c** server `koreader-sync-server` sul VPS (`kosync.fabiocrestoni.it`) e jailbreak del Paperwhite con KOReader puntato al server.
**Accettazione.** `makebook --epub` produce lo stesso file byte per byte da stesso input; il partial MD5 coincide con quello calcolato da KOReader sul file copiato sul Kindle; posizione letta sul Kindle → proposta su iPhone entro 60 s dall'apertura, e viceversa la posizione dell'iPhone riapre il Kindle sulla stessa pagina.
**Verifica.** pytest (EPUB, partial MD5 con vettori noti); Swift Testing (parser/serializzatore XPointer, client con URLProtocol finto, aggancio allo store); collaudo su Kindle vero; `scripts/check.sh`.
**Dipendenze.** T13. **File.** `tools/makebook/src/makebook/epub.py`, `ios/ReadAlong/Sync/KOSync*.swift`, `ios/ReadAlong/UI/Settings/KindleSettingsView.swift`, `docs/adr/0003-kindle-kosync.md`.
**Note.**
- [x] T18a — 2026-11-01: `tools/makebook/makebook/epub.py` (non `src/`), `makebook --epub PATH` e `makebook kindle-id PATH`; `kindle.documento` facoltativo in `book.json` (spec «Formato del libro»), `versioneFormato` resta 1, `id` invariato con o senza EPUB (testato). Nav e copertina solo nel manifest: crengine (`epubfmt.cpp`) crea un `DocFragment` anche per gli itemref `linear="no"`. Test in `tests/test_epub.py` (partial MD5 su vettori costruiti a mano, struttura OPF/XHTML, determinismo, testo identico alla fixture). Il Cigno nero si rigenera dalla `--work-dir` in ~15 s senza risintetizzare.
- [x] **T18b** (2026-11-01; ADR 0003). `Book.kindle` (`kindle.documento` facoltativo, `kindleDocument`). `Sync/KOSyncClient.swift`: `KOSyncAPI` (register, authorize, putProgress, getProgress), `KOSyncClient` su `URLSession` iniettabile, timeout 10 s, `KOSyncCredentials.userKey` = MD5 (CryptoKit), `KOSyncError` tipizzato; `getProgress` → `nil` per 404, `{}` o record senza posizione. `Sync/XPointer.swift`: `parse` tollerante e `string`; `sentenceIndex(in:)`, `sentence(in:contentOf:)`, `pointer(for:in:content:)`; `M` conta tutti i paragrafi di `chapters/NN.json` (anche vuoti), `C` in scalari Unicode come crengine. `ProgressStore`: `remoteWrites()` (stessa cadenza delle scritture iCloud, anche senza `SyncStore`) e `receiveExternalPosition` (stesso merge e stessa proposta di T13, poi verso iCloud); una modifica locale ha sempre `updatedAt` successivo allo stato che modifica, anche se datato nel futuro (sennò «Ignora» su una posizione del Kindle perdeva il merge). `Sync/KindleSync.swift`: PUT su ogni scrittura remota (XPointer di inizio frase, `percentage` a 4 decimali), GET all'avvio/primo piano (`pullAll`) e all'apertura del libro (`pull`), scarta il nostro `deviceID` e i record non più recenti, ripiego sulla percentuale; errori in `KindleSettings.lastError`. `UI/Settings/KindleSettings.swift` (UserDefaults + Keychain, `deviceID` stabile) e `KindleSettingsView` (ingranaggio in alto a sinistra nella libreria: server, utente, password, Verifica → su 401 «Crea l'utente sul server», Attivo, ultima sincronizzazione). Test: `KOSyncClientTests` (URLProtocol finto), `XPointerTests`, `KindleSyncTests` (ProgressStore + InMemorySyncStore + client finto, Pinocchio con `kindle.documento` aggiunto per la proposta nel lettore). Da fare al collaudo: struttura reale degli XPointer di KOReader sull'EPUB di T18a (eventuali `div` o spazi iniziali nel testo del `<p>`), orologi.

### Checkpoint C
- [ ] Criteri di successo 1–10 della spec verificati
- [ ] Approvazione finale di Fabio
