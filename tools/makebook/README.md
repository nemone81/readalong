# makebook

Genera i libri `.rabook` per ReadAlong: testo diviso in capitoli, paragrafi e frasi, audio sintetizzato in locale con [Piper](https://github.com/rhasspy/piper) e, per ogni frase, il secondo in cui inizia e finisce. Il formato è descritto in `docs/SPEC.md`.

Gira sul Mac (testato su Apple Silicon, macOS 27).

## Installazione

Strumenti di sistema:

```sh
brew install uv espeak-ng ffmpeg
brew install --cask calibre        # solo per i PDF (fornisce ebook-convert)
```

Ambiente Python (3.12, dipendenze bloccate in `uv.lock`):

```sh
uv sync --project tools/makebook
```

L'unica dipendenza è `piper-tts==1.3.0`. Le versioni più recenti del wheel macOS sono rotte; anche la 1.3.0 ha il modulo `espeakbridge` che cerca i dati fonetici in un path della macchina di build, per questo `makebook` usa `espeak-ng` di sistema da riga di comando (`synth.CliPhonemizer`).

### Scaricare una voce

Le voci stanno in `tools/makebook/voices/` (ignorata da git; si può cambiare con `--voices-dir` o `MAKEBOOK_VOICES_DIR`). Servono due file, il modello `.onnx` e la sua configurazione `.onnx.json`:

```sh
mkdir -p tools/makebook/voices && cd tools/makebook/voices
base=https://huggingface.co/rhasspy/piper-voices/resolve/main/it/it_IT/paola/medium
curl -LO $base/it_IT-paola-medium.onnx
curl -LO $base/it_IT-paola-medium.onnx.json
```

Altre voci: <https://huggingface.co/rhasspy/piper-voices> (stesso schema: `lingua/LOCALE/nome/qualità/`). Si sceglie con `--voice <nome>` oppure passando il path di un `.onnx`.

## Generare un libro da EPUB

Prima si guarda come `makebook` ha diviso il libro, senza sintetizzare nulla:

```sh
uv run --project tools/makebook makebook libro.epub --list
```

```
  1      52 parole  LE AVVENTURE DI PINOCCHIO
  2     672 parole  I. Come andò che Maestro Ciliegia, falegname trovò un pezzo di legno…
  …
 38    1014 parole  INDICE
 39    2693 parole  THE FULL PROJECT GUTENBERG™ LICENSE
```

Poi si generano i capitoli che servono (numerati come in `--list`; intervalli e liste: `2-37`, `3,5,7-9`):

```sh
uv run --project tools/makebook makebook libro.epub -o "Pinocchio.rabook" --chapters 2-37
```

Opzioni utili:

| Opzione | Default | |
|---|---|---|
| `--voice` | `it_IT-paola-medium` | nome della voce in `--voices-dir`, o path di un `.onnx` |
| `--chapters` | tutti | capitoli da includere |
| `--title`, `--author`, `--language` | dai metadati dell'EPUB | |
| `--pdf-mode`, `--no-pdf-mode` | automatico | forza accesa o spenta la ricucitura delle righe dei PDF (vedi sotto) |
| `--jobs` | 4 | capitoli sintetizzati in parallelo (un processo Piper ciascuno) |
| `--work-dir` | temporanea | tiene audio e tempi dei capitoli: se la generazione si interrompe e la rilanci con la stessa cartella, i capitoli già fatti non si rifanno |
| `--epub PATH` | no | scrive anche l'EPUB per il Kindle (vedi sotto) e mette in `book.json` il suo `kindle.documento` |

La sintesi va più o meno in tempo reale per processo (un'ora di audio ≈ un'ora di CPU per capitolo): un libro lungo richiede qualche ora con `--jobs 4`. Conviene `--work-dir` dedicata.

## Generare un libro da PDF

Il PDF passa prima da `ebook-convert` di calibre (PDF → EPUB), poi dalla stessa estrazione con in più: righe spezzate ricucite in paragrafi, parole sillabate a fine riga riunite, testatine ripetute rimosse. Calibre mette nei metadati il nome del file, quindi conviene indicare titolo e autore:

```sh
uv run --project tools/makebook makebook "Il Cigno nero.pdf" --list
uv run --project tools/makebook makebook "Il Cigno nero.pdf" -o "Il Cigno nero.rabook" \
  --title "Il Cigno nero" --author "Nassim Nicholas Taleb" --chapters 2-24 --work-dir ~/makebook-cigno
```

Se hai già l'EPUB fatto da calibre a partire dal PDF, puoi passare direttamente quello: la modalità PDF si accende da sola quando valgono **entrambe** queste condizioni (sono le tracce che calibre 9 lascia davvero nel file):

- l'OPF è firmato da calibre: `<dc:contributor opf:role="bkp">calibre (…)</dc:contributor>` oppure un `<meta name="calibre:…">`;
- almeno una pagina viene da un PDF: `<title>` che finisce in `.pdf` (calibre ci mette il path del PDF sorgente) oppure `<meta name="generator" content="PDF Reflow conversion">` (o `pdftohtml`).

Quando succede lo dice su stderr. `--no-pdf-mode` la spegne, `--pdf-mode` la forza anche su EPUB che non hanno quelle tracce. Senza la modalità PDF ogni riga del PDF diventerebbe un paragrafo e le frasi verrebbero spezzate a metà.

## EPUB per il Kindle (KOReader + KOSync)

Con `--epub PATH` makebook scrive, accanto al `.rabook`, un EPUB 3 da copiare sul Kindle (KOReader). KOReader sincronizza la posizione via KOSync identificando il libro con il *partial MD5* del file: makebook lo calcola sull'EPUB appena scritto e lo mette in `book.json` come `kindle.documento`, così l'app sa a quale documento KOSync corrisponde il libro. Per questo l'EPUB va sempre da makebook e mai da calibre, e non va modificato dopo (cambierebbe l'MD5).

- Spine = esattamente i capitoli, nell'ordine di `capitoli`: per crengine `DocFragment[N]` è il capitolo N. Indice (`nav.xhtml`) e copertina stanno solo nel manifest, perché crengine crea un `DocFragment` per ogni voce dello spine, anche con `linear="no"`.
- Ogni capitolo: `<h2>` col titolo, poi un `<p>` per paragrafo con il testo delle frasi unite da uno spazio, identico a `chapters/NN.json` (`<p>[M]` = paragrafo M, contando da 1). Nient'altro nel `body`.
- Deterministico: date fisse nello zip, `dcterms:modified` fisso, nessuna dipendenza dall'orologio. Stesso input, stesso file, stesso `kindle.documento`.
- L'`id` del libro non cambia chiedendo l'EPUB.
- Conviene `--language it` sui PDF: calibre spesso dichiara `en`, e KOReader userebbe la sillabazione inglese.

Per confrontare l'MD5 con quello che calcola KOReader sul Kindle:

```sh
uv run --project tools/makebook makebook kindle-id libro-kindle.epub
```

Se la `--work-dir` della prima generazione c'è ancora, aggiungere l'EPUB a un libro già fatto non risintetizza nulla: basta rilanciare lo stesso comando con `--epub` (qualche secondo, più la conversione del PDF).

## Cosa fa con il testo

- Segue l'indice dell'EPUB (`toc.ncx`, oppure il `nav` di EPUB 3). Le voci con meno di 40 parole (intestazioni di Parte) confluiscono nel capitolo dopo.
- Scarta il materiale prima del primo capitolo e su stderr dice quante parole ha tolto (`attenzione: scartate 47 parole prima del primo capitolo (Copertina, Frontespizio, Dedica)`): il testo prima della prima voce dell'indice e, prima della prima voce lunga almeno 40 parole, le voci brevi che hanno testo oltre al titolo (copertina, colophon, frontespizio, dedica). Un'intestazione nuda come «Parte prima» resta e va col capitolo dopo; se nessuna voce arriva a 40 parole (raccolte di testi brevi) non si scarta nessuna voce. Una voce editoriale lunga (un colophon di 52 parole) resta invece un capitolo: si esclude con `--chapters`.
- Il titolo del capitolo è sempre il primo paragrafo, da solo.
- Scarta: `<title>` delle pagine (calibre ci mette il path del PDF), note in `<sup>` e `<aside>`, rimandi `[12]`, numeri di pagina, didascalie delle figure, righe che sono path o nomi di file. Prima di scrivere il pacchetto controlla che nessun path dell'utente sia finito nel testo, altrimenti si ferma.
- Divide i paragrafi in frasi (`. ! ? …`, con virgolette di chiusura attaccate; non spezza dopo abbreviazioni come `sig.`, iniziali, numeri come `3.30`, né prima di un inciso in minuscolo come «— Un re! — diranno…»).
- A Piper i `…` arrivano come `.` (il testo salvato resta quello originale).

## Il pacchetto

Uno zip con tutte le voci *stored* (mai compresse: l'app legge lo zip senza `inflate`), data delle voci fissa, quindi due generazioni identiche danno lo stesso file:

```
book.json          {id, titolo, autore, lingua, voce, versioneFormato: 1, capitoli: [{n, titolo, file, durata}], kindle?: {documento}}
cover.jpg          copertina dell'EPUB (lato max 1400 px), o tinta unita se manca
chapters/NN.json   {durata, paragrafi: [[{t, s, e}, …], …]}
audio/NN.m4a       AAC 64 kbps mono
```

- `id`: sha256 di `titolo + "\n" + autore + "\n" + testo`, dove il testo è l'insieme delle frasi (unite da spazio), dei paragrafi (riga vuota) e dei capitoli (due righe vuote).
- `file`: path del JSON del capitolo nello zip (`chapters/01.json`); l'audio ha lo stesso numero.
- `kindle.documento` (facoltativo, solo con `--epub`): partial MD5 alla KOReader dell'EPUB per il Kindle, 32 caratteri esadecimali minuscoli. È l'identità del documento per KOSync. `versioneFormato` resta 1: chi non lo conosce lo ignora.
- `s`, `e`, `durata`: secondi, troncati al millesimo. Contati sui campioni prodotti da Piper, quindi esatti; la fine di una frase coincide con l'inizio della successiva.

Alla fine `makebook` rilegge il pacchetto e lo valida (`package.validate_rabook`).

## Sviluppo

```sh
uv run --project tools/makebook pytest            # ~35 s: include una sintesi reale di 2 frasi
uv run --project tools/makebook pytest -m "not slow"
uv run --project tools/makebook ruff check tools/makebook
```

La fixture `tests/fixtures/pinocchio.rabook` (2 capitoli di *Le avventure di Pinocchio*, Collodi, pubblico dominio, EPUB Project Gutenberg n. 52484) serve anche ai test dell'app. Per rigenerarla:

```sh
curl -LO https://gutenberg.pglaf.org/cache/epub/52484/pg52484-images-3.epub
uv run --project tools/makebook makebook pg52484-images-3.epub \
  -o tools/makebook/tests/fixtures/pinocchio.rabook --chapters 5,7 --title "Le avventure di Pinocchio"
```

(capitoli IV e VI dell'originale, i più corti: ~5 min di audio, < 3 MB).
