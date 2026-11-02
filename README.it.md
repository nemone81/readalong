# ReadAlong

*Italiano* · [English](README.md)

App iOS per leggere e ascoltare lo stesso libro dallo stesso punto. Il testo è diviso in frasi, ognuna con il suo tempo di inizio e fine nell'audio: mentre ascolti la frase in lettura si evidenzia, tocchi una frase e l'audio riparte da lì, metti in pausa e continui a leggere. Posizione e segnalibri si sincronizzano tra iPhone e iPad via iCloud e, attraverso KOReader e un server KOSync, anche con un Kindle sbloccato.

È nata da una domanda sola: «si può creare un player audio per questo libro che si sincronizzi con l'avanzamento sul Kindle e viceversa?». Il Kindle non espone la posizione di lettura, quindi l'app è diventata il lettore, e il Kindle ci è entrato dopo, dalla porta di servizio.

Progetto personale, sviluppato con Claude Code: le specifiche, il piano e lo stato dei lavori sono in `docs/`.

## Com'è fatto

```
tools/makebook/   generatore sul Mac (Python 3.12, uv): PDF/EPUB → .rabook (+ EPUB per il Kindle)
ios/              app SwiftUI (iOS 26, Swift 6, XcodeGen, Swift Testing, zero dipendenze)
docs/             SPEC, PLAN, TASKS, ADR, checklist di collaudo
scripts/check.sh  xcodegen + build + test iOS + pytest, in un colpo solo
```

**Il pacchetto `.rabook`** è uno zip con `book.json` (metadati), un JSON per capitolo con le frasi e i loro tempi, un file audio AAC per capitolo e la copertina. Il formato è descritto in `docs/SPEC.md`.

**L'audio** lo genera [Piper](https://github.com/rhasspy/piper) in locale (voce italiana `it_IT-paola-medium`); i tempi per frase escono dalla sintesi stessa, senza allineamento a posteriori.

**Il Kindle** legge un EPUB prodotto dallo stesso generatore (`makebook --epub`) con KOReader, che scambia la posizione con l'app tramite il protocollo KOSync (`docs/adr/0003-kindle-kosync.md`).

## Provarlo

Generatore:

```sh
uv run --project tools/makebook makebook libro.pdf -o libro.rabook --title "Titolo" --author "Autore" --language it
```

App: `cd ios && xcodegen generate` e apri `ReadAlong.xcodeproj`; `ios/Tools/build-device.sh` firma e installa su un dispositivo collegato (serve un account Apple Developer). Tutto il repo si verifica con `scripts/check.sh`.

## Stato

Uso personale, distribuzione via TestFlight; non è un prodotto da App Store. Lo stato dei task è in `docs/TASKS.md`.

## Licenza

MIT, vedi `LICENSE`.
