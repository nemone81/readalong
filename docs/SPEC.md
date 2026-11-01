# Spec: ReadAlong

App iOS per leggere e ascoltare lo stesso libro dallo stesso punto, con audio generato in locale (Piper) e testo sincronizzato frase per frase.

Stato: **approvata da Fabio il 2026-10-30**. Decisioni prese in approvazione: nome ReadAlong confermato; dopo una pausa in cui si è continuato a leggere, play riparte dalla prima frase visibile sullo schermo.

## Obiettivo

Fabio ha libri in PDF/EPUB che vuole fruire in due modi intercambiabili: leggendo sul telefono o ascoltando (auto, passeggiata, AirPods). Oggi i due mondi non comunicano: il Kindle non espone la posizione di lettura e l'audiolibro `.m4b` in Apple Books non sa nulla del testo.

ReadAlong unisce i due: un solo "libro-pacchetto" con testo, audio e mappa dei tempi; l'utente passa da ascolto a lettura e ritorno senza perdere il punto. Il Kindle resta fuori (nessuna API: decisione presa, vedi *Fuori ambito*).

**Utente:** Fabio (e familiari), distribuzione via TestFlight. Non è un prodotto da App Store nella v1.

**Successo:** importare *Il Cigno nero* dai File, ascoltarlo in auto con i comandi dal volante, aprire l'app a casa e trovare la frase evidenziata dove l'audio si è fermato, continuare a leggere, e il giorno dopo sull'iPad ripartire da lì.

### Storie utente (v1)

1. Importo un file `.rabook` da File/Dropbox/AirDrop e lo vedo in libreria con copertina, titolo, durata, avanzamento.
2. Apro un libro: vedo il testo del capitolo; premo play e la frase in lettura si evidenzia e scorre.
3. Tocco una frase: l'audio riparte da lì. Metto in pausa e continuo a leggere; quando premo play riparte dalla prima frase visibile sullo schermo (decisione del 2026-10-30).
4. Chiudo l'app, la riapro (anche sull'altro dispositivo): sono alla stessa frase.
5. Velocità 0,8×–2,0×, ricordata per libro.
6. Timer di spegnimento: tra N minuti o a fine capitolo.
7. Segnalibri su una frase, con nota opzionale; lista e salto.
8. Lock screen, Control Center e AirPods: play/pausa, ±15 s, capitolo precedente/successivo; copertina e titolo visibili.
9. Indice dei capitoli con durata e avanzamento.
10. Regolazioni di lettura minime: dimensione del carattere, tema chiaro/scuro/sepia, controlli di riproduzione riducibili a una pillola (play/pausa e tempo) per chi vuole solo leggere; scelte globali e persistenti.

### Fuori ambito (v1)

- Sincronizzazione con Kindle/Amazon (nessuna API; niente scraping).
- Audiolibri senza mappa dei tempi (Audible, m4b generici).
- Generazione audio sul telefono: avviene sul Mac con `makebook`.
- Sincronizzazione dei file libro tra dispositivi (solo posizione/segnalibri/velocità; il file si importa su ciascun dispositivo).
- Account, cloud proprio, App Store.

## Formato del libro: `.rabook`

Uno zip con estensione propria (UTI `it.fabiocrestoni.rabook`, conforme a `public.zip-archive`), registrato dall'app per "Apri in…" e per l'importazione dai File.

```
book.json            → {id, titolo, autore, lingua, voce, versioneFormato: 1, capitoli: [{n, titolo, file, durata}], kindle?: {documento}}
cover.jpg
chapters/01.json     → {durata, paragrafi: [[{t: "testo frase", s: 12.345, e: 15.010}, …], …]}
audio/01.m4a         → AAC 64 kbps mono, un file per capitolo
```

`id` è stabile (sha256 di titolo+autore+testo) ed è la chiave di posizione e segnalibri su iCloud. Il formato è versionato: l'app rifiuta versioni maggiori di quella che conosce con un messaggio chiaro.

`kindle` è **facoltativo** (T18): c'è solo se il libro è stato generato con `makebook --epub`, e `kindle.documento` è il partial MD5 alla KOReader dell'EPUB per il Kindle (stringa esadecimale minuscola di 32 caratteri), cioè l'identità del documento su KOSync. Non entra nell'`id` e non cambia `versioneFormato`, che resta 1: un'app che non lo conosce lo ignora.

## Stack tecnico

| Componente | Scelta |
|---|---|
| App | Swift 6 (strict concurrency `complete`), SwiftUI, iOS 26+, iPhone e iPad, XcodeGen, zero dipendenze di terze parti |
| Audio | `AVAudioPlayer` (`enableRate` per la velocità), `AVAudioSession` playback in background, `MPRemoteCommandCenter` + `MPNowPlayingInfoCenter` |
| Testo | `UITextView` via `UIViewRepresentable` con `NSAttributedString` (evidenziazione per range, tap → `characterIndex` → frase). SwiftUI puro non dà il tap per frase dentro un paragrafo |
| Persistenza locale | Stato per libro (`BookState`) in `Application Support/State/<bookId>.json`, separato dai file del libro; libri importati copiati in `Application Support/Books/<bookId>/` |
| Sync | `NSUbiquitousKeyValueStore` dietro il protocollo `SyncStore` (ADR 0002; limite 1 MB: posizione, velocità, segnalibri per libro). Merge in `StateMerge`: vedi sotto, "Sincronizzazione" |
| Generatore | `tools/makebook` in Python 3.12 (`uv`), Piper + espeak-ng, ffmpeg; riusa gli script già scritti (`estrai_capitoli.py`, `piper_tts.py`, `piper_tts_timed.py`) |

Convenzioni allineate a `~/Projects/battlefits-ios` (XcodeGen, Swift 6, script in `Tools/`).

## Comandi

```
# iOS
cd ios && xcodegen generate
xcodebuild -project ios/ReadAlong.xcodeproj -scheme ReadAlong -destination 'platform=iOS Simulator,name=iPhone 17' build
xcodebuild -project ios/ReadAlong.xcodeproj -scheme ReadAlong -destination 'platform=iOS Simulator,name=iPhone 17' test
scripts/check.sh            # xcodegen + build + test + pytest, in un colpo solo
Tools/testflight.sh         # archivio e upload (come battlefits-ios)

# Generatore
uv run --project tools/makebook makebook libro.epub -o "Il Cigno nero.rabook" --voice it_IT-paola-medium
uv run --project tools/makebook pytest
```

## Struttura del repo (`~/Projects/readalong`)

```
docs/SPEC.md, docs/PLAN.md, docs/TASKS.md, docs/adr/
ios/project.yml
ios/ReadAlong/App/            → entry point, AppState
ios/ReadAlong/Model/          → Book, Chapter, Sentence, PlaybackState, Bookmark (Codable, Sendable)
ios/ReadAlong/Package/        → RABookImporter, RABookReader (unzip, validazione, versioni)
ios/ReadAlong/Playback/       → PlayerEngine (AVAudioPlayer), NowPlayingController, SleepTimer
ios/ReadAlong/Sync/           → ProgressStore (locale + iCloud KVS, merge)
ios/ReadAlong/UI/Library/     → LibraryView, ImportFlow
ios/ReadAlong/UI/Reader/      → ReaderView, SentenceTextView (UITextView), ChapterList, PlayerBar
ios/ReadAlong/UI/Settings/    → velocità, timer, tema
ios/ReadAlongTests/           → Swift Testing
ios/Tools/                    → testflight.sh
tools/makebook/makebook/      → extract.py, synth.py, package.py, cli.py
tools/makebook/tests/
scripts/check.sh
```

## Sincronizzazione (T13)

Un documento per libro, il JSON compatto di `BookState` (chiavi ordinate, date in secondi dal 1970, nessuno spazio):

```
{"bookmarks":[{"createdAt":…,"id":"…","modifiedAt":…,"note":"…","sentence":{"chapter":2,"index":4}}],
 "deletedBookmarks":[{"deletedAt":…,"id":"…"}], "device":"iPad",
 "position":{"chapter":2,"seconds":31.25,"sentence":7}, "rate":1.3, "updatedAt":…}
```

`modifiedAt`, `deletedBookmarks` e `device` (aggiunti con T13) sono facoltativi e si scrivono solo se presenti: un record senza è identico al formato di T7 e T14, e si legge con i default.

Regola di merge (`StateMerge.merge(local:remote:)`, pura e deterministica, così due dispositivi convergono senza rimbalzi):
- posizione, velocità e dispositivo dal record con `updatedAt` più recente; a parità di data vince la posizione più avanti nel libro (poi velocità e dispositivo), uguale dai due lati;
- segnalibri uniti per id; per ogni id vince la versione modificata più di recente (`modifiedAt`, altrimenti `createdAt`);
- cancellazioni come tombstone (`deletedBookmarks`): il tombstone toglie il segnalibro con lo stesso id se questo non è stato modificato dopo; i tombstone più vecchi di 90 giorni rispetto a `updatedAt` si potano (un dispositivo spento più a lungo può far ricomparire un segnalibro cancellato).

Quando il merge si fa: dopo i salvataggi locali (il salvataggio locale resta col debounce di 2 s; la scrittura remota avviene subito su pausa, background, chiusura, modifiche di velocità o segnalibri e cambio di capitolo, ma durante la riproduzione al massimo una ogni 30 s per libro, `ProgressStore.remoteWriteInterval`: iCloud KVS strozza le scritture frequenti), all'avvio e al ritorno in primo piano, e a ogni cambiamento esterno. Si riscrive solo la parte che differisce dal risultato. Se in pausa arriva una posizione più recente, il lettore non salta: propone «Riprendi da dove eri arrivato su iPad? (Capitolo 3, 12:40)» con Riprendi / Ignora (Ignora rende di nuovo più recente la posizione locale). In riproduzione la posizione locale continua a vincere. Cancellare un libro cancella il suo stato locale, non il documento remoto.

## Kindle via KOReader e KOSync (T18)

Il lettore Amazon non espone la posizione. Sul Kindle sbloccato (Paperwhite 7ª gen, firmware 5.16.2.1.1, WinterBreak) si legge con KOReader, che sincronizza la posizione con il protocollo **KOSync** verso un server nostro (`koreader-sync-server` in Docker sul VPS Hetzner, `https://kosync.fabiocrestoni.it`). ReadAlong parla con lo stesso server: la posizione del Kindle arriva su iPhone e iPad e viceversa.

**Protocollo KOSync** (client KOReader, `plugins/kosync.koplugin/api.json`):
- `POST /users/create` `{"username","password"}` → 201 (402 se esiste);
- `GET /users/auth` → 200/401; autenticazione con header `x-auth-user: <username>` e `x-auth-key: <md5 esadecimale della password>` su ogni chiamata; `Accept: application/vnd.koreader.v1+json`;
- `PUT /syncs/progress` `{"document","progress","percentage","device","device_id"}` → 200; il server aggiunge `timestamp` (secondi Unix);
- `GET /syncs/progress/:document` → `{"document","progress","percentage","device","device_id","timestamp"}`.

**Identità del documento**: `document` = *partial MD5* del file EPUB come lo calcola KOReader (`util.partialMD5`): MD5 della concatenazione di campioni da 1024 byte letti agli offset `1024·4^i` per `i = -1…10` (il primo campione, per via dello shift a 32 bit, parte dall'offset 0), fermandosi al primo campione vuoto. makebook lo calcola sull'EPUB prodotto e lo scrive in `book.json` come `kindle.documento`; l'EPUB è dunque un prodotto di makebook (`--epub`), mai un file di calibre.

**EPUB per il Kindle** (`makebook --epub`): EPUB 3, uno XHTML per capitolo nello stesso ordine di `capitoli`, **nessun altro elemento nello spine** (niente pagina di copertina o frontespizio: la copertina va solo nel manifest), un `<h2>` col titolo del capitolo e poi un `<p>` per paragrafo, il cui testo è la concatenazione delle frasi del paragrafo separate da uno spazio, identica a `chapters/NN.json`.

**Posizione** (`progress`): per gli EPUB KOReader usa un XPointer di crengine del tipo `/body/DocFragment[N]/body/p[M]/text().C` (N = capitolo 1-based nello spine, M = indice 1-based del `<p>` nel `body` del capitolo, C = offset in caratteri nel testo del paragrafo; l'`<h2>` non è un `p` e non conta). ReadAlong traduce XPointer ↔ (capitolo, paragrafo, frase): in lettura cerca la frase il cui intervallo di caratteri contiene C; in scrittura emette l'offset di inizio della frase corrente. `percentage` = avanzamento nel libro (0…1, tempo audio trascorso / durata totale), usato come ripiego se l'XPointer non si interpreta. Il parsing dell'XPointer è tollerante: varianti con `text()[k]`, `/h2`, `/body/DocFragment[N]/body` senza `p` tornano all'inizio del paragrafo o del capitolo.

**Nell'app**: impostazione «Kindle (KOSync)» con URL del server, utente e password (password nel Keychain; si invia solo l'MD5); un `KOSyncClient` con le quattro chiamate; dopo ogni scrittura remota di `ProgressStore` (stessa cadenza di iCloud) si fa `PUT` se il libro ha `kindle.documento`; all'avvio, al ritorno in primo piano e all'apertura del libro si fa `GET`: se `timestamp` è più recente di `updatedAt` locale e `device_id` non è il nostro, la posizione tradotta entra nel flusso di T13 come posizione remota con dispositivo «Kindle» (stessa barra «Riprendi da dove eri arrivato su Kindle?»; in riproduzione si ignora). I segnalibri restano solo su iCloud: KOSync non li trasporta. Errori di rete silenziosi con un indicatore nelle impostazioni («ultima sincronizzazione Kindle: …»).

## Stile del codice

```swift
/// Posizione corrente nel libro, condivisa tra dispositivi.
struct Progress: Codable, Sendable, Equatable {
    var chapter: Int
    var sentence: Int
    var seconds: Double
    var updatedAt: Date

    /// Vince il record più recente; a parità, quello locale.
    func merged(with remote: Progress) -> Progress {
        remote.updatedAt > updatedAt ? remote : self
    }
}

@MainActor @Observable
final class ReaderModel {
    private(set) var currentSentence: SentenceID?
    func seek(to sentence: SentenceID) { … }
}
```

- `@Observable` + `@MainActor` per i model di UI; motore audio in un attore dedicato.
- Niente force unwrap in codice di produzione; errori tipizzati (`enum RABookError: Error`).
- Nomi in inglese nel codice, commenti e UI in italiano (localizzabile dopo).
- Python: tipizzato, `ruff`, funzioni pure testabili separate dall'I/O.

## Strategia di test

- **Swift Testing** (`import Testing`) per: parsing e validazione del pacchetto, ricerca binaria frase↔tempo, regole di merge della sincronizzazione, timer di spegnimento, calcolo avanzamento. Target: tutta la logica non-UI coperta.
- **UI**: collaudo manuale su dispositivo via TestFlight, con checklist in `docs/COLLAUDO.md` (background audio, lock screen, AirPods, kill/riapertura, iPad↔iPhone).
- **pytest** per `makebook`: divisione in frasi, pulizia del testo (niente numeri di pagina, note, intestazioni, *path di file*), validità dello zip prodotto, coerenza tempi/durata audio.
- Un pacchetto di prova piccolo (2 capitoli, voce reale, ~1 min) in `tools/makebook/tests/fixtures/` per i test dell'app.

## Confini

- **Sempre:** `scripts/check.sh` verde prima di ogni commit; branch + PR verso `main`; strict concurrency senza warning; ogni task in un worktree proprio (sub-agenti Opus 5.5).
- **Chiedere prima:** aggiungere dipendenze (obiettivo: zero), cambiare il formato `.rabook` dopo la v1, passare da KVS a CloudKit, pubblicare su App Store, cambiare voce o parametri della sintesi.
- **Mai:** committare libri, audio o segreti; scraping di Amazon o uso di credenziali Kindle; disabilitare test rossi; commit diretti su `main`.

## Criteri di successo (v1 finita quando tutti sono veri)

1. Import di un `.rabook` da 350 MB dai File in < 15 s; in libreria compaiono copertina, titolo, durata, avanzamento.
2. In riproduzione la frase evidenziata è quella che si sente, con scarto < 0,5 s, per l'intero capitolo 10 (il più lungo).
3. Tocco una frase → l'audio riparte da lì entro 0,3 s.
4. Audio in background per 1 h con schermo bloccato; play/pausa e ±15 s funzionano da lock screen e da AirPods; Now Playing mostra copertina e capitolo.
5. Kill dell'app e riapertura: stessa frase evidenziata, stessa posizione audio.
6. Posizione cambiata su iPhone, iPad aperto entro 60 s: riparte dalla stessa frase.
7. Velocità e timer funzionano come da storie 5 e 6; la velocità resta dopo la riapertura.
8. Segnalibri: creazione, lista, salto, cancellazione; sincronizzati.
9. `scripts/check.sh` verde; build TestFlight installata sull'iPhone di Fabio.
10. `makebook` genera *Il Cigno nero* da zero senza intervento manuale e i test pytest sono verdi.

## Domande aperte

1. Il generatore gira solo sul Mac di Fabio: va bene o lo si vuole eseguibile anche sul VPS (più lento, senza GPU)? Per la v1: solo Mac.

## Domande chiuse

- Nome: ReadAlong (2026-10-30).
- Ripresa dopo pausa con lettura: dalla prima frase visibile (2026-10-30).
