# Piano di implementazione: ReadAlong v1

Riferimento: [SPEC.md](SPEC.md) (approvata 2026-10-30). Dettaglio dei task in [TASKS.md](TASKS.md).

## Sintesi

Due componenti indipendenti legati da un contratto, il formato `.rabook`: il generatore `makebook` (Python, Mac) e l'app iOS. Il contratto è già fissato nella spec, quindi i due lati partono in parallelo. L'app si costruisce a fette verticali: prima "apro un libro e lo ascolto con il testo che segue", poi libreria, background, sync, extra.

## Decisioni di architettura

1. **`.rabook` è uno zip con voci *stored* (non compresse).** L'audio è già AAC e il JSON è piccolo: comprimere non serve. Così l'app legge lo zip con ~120 righe di Swift (central directory + copia dei byte), senza dipendenze e senza `inflate`. Voci compresse → errore esplicito "formato non supportato". Documentato come ADR 0001.
2. **Testo in `UITextView` (UIViewRepresentable)**, un `NSAttributedString` per capitolo; evidenziazione cambiando gli attributi del solo range della frase corrente; tap → `closestPosition(to:)` → indice carattere → frase (tabella offset→frase costruita una volta per capitolo). SwiftUI puro non dà il tap per frase.
3. **Motore audio: `AVAudioPlayer`, un file per capitolo**, dentro un `actor PlayerEngine`; il passaggio di capitolo lo gestisce il motore (precarica il successivo). Posizione pubblicata a 10 Hz via `AsyncStream`; l'UI aggiorna l'evidenziazione solo quando cambia la frase (ricerca binaria sugli `s` delle frasi).
4. **Stato per libro in un unico `BookState` Codable** (posizione, velocità, segnalibri, `updatedAt`), salvato in JSON locale e specchiato su `NSUbiquitousKeyValueStore` con chiave `book.<id>`. Merge: vince `updatedAt` più recente, segnalibri uniti per id. Un solo punto di sincronizzazione, testabile senza iCloud.
5. **Ripresa dopo lettura**: `ReaderModel` conosce la prima frase visibile (riportata dalla `UITextView`); se l'utente ha scrollato mentre era in pausa, play riparte da quella (decisione spec).
6. **Zero dipendenze di terze parti** su entrambi i lati, salvo `piper-tts`, `ffmpeg`, `espeak-ng` già richiesti dal generatore.
7. **Fixture di test con testo di pubblico dominio** (Pinocchio, Collodi, 2 capitoli brevi), generata da `makebook` e committata (eccezione al `.gitignore`): i test dell'app non dipendono da libri protetti da copyright.

## Grafo delle dipendenze

```
Contratto .rabook (SPEC)
 ├── T2 makebook (Python) ──→ fixture Pinocchio ──┐
 └── T1 scheletro Xcode                           │
       └── T3 modello + lettore .rabook ←─────────┘
             ├── T4 PlayerEngine
             ├── T5 SentenceTextView
             │     └── T6 ReaderView (play, evidenziazione, tap, ripresa)   ← checkpoint A
             │           ├── T7 stato locale + ripresa dopo kill
             │           ├── T8 libreria + import                             ← checkpoint B
             │           ├── T9 background + Now Playing + comandi remoti
             │           ├── T10 velocità + timer
             │           ├── T11 indice capitoli
             │           ├── T12 impostazioni lettura (carattere, tema)
             │           └── T13 sync iCloud (su T7)
             │                 └── T14 segnalibri (su T13)
             └── T15 TestFlight + collaudo su dispositivo                     ← checkpoint C
```

## Fasi, checkpoint e parallelismo

| Fase | Task | In parallelo |
|---|---|---|
| 0 Fondamenta | T1, T2 | sì (nessuna dipendenza) |
| 1 Contratto | T3 | — |
| 2 Lettore | T4, T5 → T6 | T4 ∥ T5, poi T6 |
| **Checkpoint A** | *Il Cigno nero* in riproduzione su simulatore, testo che segue, tap → salto | revisione di Fabio |
| 3 Uso quotidiano | T7, T8, T9, T10, T11, T12 | tutti ∥ (file disgiunti; T7 prima di T13) |
| **Checkpoint B** | import dai File, ascolto in background con lock screen, riapertura al punto giusto | revisione di Fabio su iPhone |
| 4 Sync ed extra | T13 → T14 | sequenziali |
| 5 Rilascio | T15 | — |
| **Checkpoint C** | tutti i criteri di successo della spec verificati, `docs/COLLAUDO.md` compilato | |

Ogni task gira in un worktree proprio (`~/Projects/readalong--tNN-<tema>`, branch `tNN-<tema>`) affidato a un sub-agente Opus 5.5; integrazione su `main` via merge dal checkout principale, dopo `scripts/check.sh` verde.

## Rischi

| Rischio | Impatto | Mitigazione |
|---|---|---|
| Evidenziazione lenta o a scatti su capitoli da 10k parole | Alto | T5 misura con il capitolo 10 fin dall'inizio; attributi cambiati solo sul range; se necessario `NSTextStorage` incrementale |
| Deriva tra tempo audio e frase (> 0,5 s) | Alto | I tempi vengono dalla sintesi stessa (esatti); `AVAudioPlayer.currentTime` letto a 10 Hz; test con la fixture reale |
| `AVAudioPlayer` + `rate` su AAC con pitch strano | Medio | `enableRate = true` mantiene il pitch; se insoddisfacente, fallback a `AVPlayer` con `audioTimePitchAlgorithm = .timeDomain` (ADR) |
| iCloud KVS: limite 1 MB, propagazione lenta | Medio | Un record compatto per libro; test di merge offline; la spec accetta 60 s |
| Lettore zip fatto in casa | Medio | Solo voci *stored*, test con zip prodotti da `makebook` e da `zip -0` di macOS |
| Entitlement (background audio, iCloud KVS) e firma | Medio | T1 li dichiara subito in `project.yml`; T15 verifica su dispositivo |
| Il testo estratto da PDF ha residui (titoli spezzati, trattini) | Basso | Test pytest sulla pulizia; la fixture Pinocchio parte da EPUB pulito |

## Domande aperte

Nessuna bloccante. Se durante T5 la `UITextView` non regge, si passa a paginazione per paragrafi (decisione da registrare in ADR).
