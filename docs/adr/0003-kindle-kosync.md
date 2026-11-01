# ADR 0003: posizione col Kindle tramite KOReader e un server KOSync nostro

**Stato:** accettata, 2026-11-01 (T18b). **Decide:** Fabio.

## Contesto

Fabio legge anche sul Kindle (Paperwhite 7ª gen). Il lettore Amazon non espone la posizione di lettura: nessuna API, e lo scraping di Amazon o l'uso delle credenziali Kindle sono esclusi dalla spec. Senza un ponte, ciò che si legge sul Kindle non arriva a ReadAlong e viceversa.

Sul Kindle sbloccato gira KOReader, che sincronizza la posizione con il protocollo **KOSync** (quattro chiamate HTTP, autenticazione con utente e MD5 della password) verso un server configurabile. Il server di riferimento, `koreader-sync-server`, è piccolo e si ospita in Docker.

La posizione di KOReader è un XPointer di crengine nell'EPUB (`/body/DocFragment[N]/body/p[M]/text().C`): ha senso solo se l'EPUB ha una struttura nota, da cui ricavare capitolo, paragrafo e frase di ReadAlong.

## Decisione

- **Server nostro**: `koreader-sync-server` sul VPS Hetzner, `https://kosync.fabiocrestoni.it` (T18c). Nessun servizio di terzi, la posizione resta nostra.
- **Canale separato da iCloud**: `KindleSync` (`ios/ReadAlong/Sync/KindleSync.swift`) non è un `SyncStore` e non tocca il documento di `BookState` su iCloud KVS (ADR 0002). Si aggancia a `ProgressStore` dall'esterno con due punti:
  - `remoteWrites()`: ogni scrittura remota di `ProgressStore` (stessa cadenza di iCloud: subito su pausa, flush e cambio di capitolo, in riproduzione al massimo una ogni 30 s) diventa una `PUT` su KOSync;
  - `receiveExternalPosition(_:device:updatedAt:for:)`: una posizione arrivata dal Kindle (`GET` all'avvio, al ritorno in primo piano e all'apertura del libro, se più recente del locale e scritta da un altro `device_id`) entra come record remoto nello stesso merge di T13 (`StateMerge`), con dispositivo «Kindle»; da lì segue la proposta «Riprendi da dove eri arrivato su Kindle?» e prosegue verso iCloud, così anche l'iPad la vede.
- **Traduzione** XPointer ↔ frase in `XPointer` (`ios/ReadAlong/Sync/XPointer.swift`), funzioni pure: `N` = posizione nello spine = posizione in `book.json`, `M` = paragrafo di `chapters/NN.json`, `C` in scalari Unicode (crengine conta in `lChar32`). In scrittura l'offset di inizio della frase corrente; in lettura la frase che contiene `C`; se l'XPointer non si interpreta, ripiego sulla `percentage` (tempo audio trascorso / durata totale).
- **EPUB prodotto da makebook** (`makebook --epub`, T18a): uno XHTML per capitolo nell'ordine di `capitoli`, solo `<p>` (il primo è il titolo del capitolo, poi uno per paragrafo) col testo identico alle frasi unite da uno spazio. L'identità del documento per KOSync (partial MD5 alla KOReader) la calcola makebook e la scrive in `book.json` come `kindle.documento`, facoltativo: i libri senza non partecipano.
- **Credenziali**: URL e utente in `UserDefaults`, password nel Keychain (`KindleSettings`, accessibile dopo il primo sblocco perché la `PUT` parte anche a schermo bloccato); al server va solo l'MD5. Il `deviceID` di ReadAlong è generato una volta per dispositivo.

## Conseguenze

- **Serve il jailbreak** del Kindle (WinterBreak sul firmware 5.16.2.1.1) e KOReader configurato verso il nostro server: senza, il canale non fa nulla. Un aggiornamento del firmware Amazon può chiudere il jailbreak. Fatto il 2026-11-01 con WinterBreak 2.1.0 (dettagli operativi in TASKS, nota T18c): sul Kindle vero KOReader manda XPointer `/body/DocFragment[N]/body/p[M]/text().C`, esattamente il contratto previsto.
- **Niente segnalibri** sul Kindle: KOSync trasporta solo la posizione. Segnalibri e velocità restano su iCloud.
- **L'EPUB va sempre da makebook**, mai da calibre o da un altro file: un EPUB diverso ha un altro partial MD5 (documento sconosciuto) e un'altra struttura (XPointer non traducibile). Cambiare la struttura dell'EPUB di makebook va fatto insieme a `XPointer`.
- **Precisione alla frase**: dal Kindle si riparte dall'inizio della frase che contiene l'offset; verso il Kindle si manda l'inizio della frase corrente, quindi KOReader può tornare indietro di qualche parola.
- **Orologi**: il confronto «più recente» usa il `timestamp` del server KOSync contro `updatedAt` locale. Un orologio del telefono molto avanti può far ignorare una posizione del Kindle; uno indietro non crea problemi, perché una modifica locale è sempre più recente dello stato che modifica (anche se datato nel futuro).
- **Errori silenziosi**: rete assente o server giù non mostrano alert nel lettore; l'ultimo errore e l'ultima sincronizzazione riuscita sono nelle impostazioni «Kindle» della libreria.
- Un server KOSync è un secondo servizio da tenere in piedi (T18c); se cade, ReadAlong e iCloud continuano a funzionare come prima.
