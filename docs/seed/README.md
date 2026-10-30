# Script di partenza per makebook (T2)

Scritti a mano il 2026-10-29/30 per generare *Il Cigno nero*. Funzionano con: `uv venv --python 3.12`, `piper-tts==1.3.0`, voce `it_IT-paola-medium` da rhasspy/piper-voices, `espeak-ng` (brew), `ffmpeg`.

- `estrai_capitoli.py` EPUB scompattato → capitoli txt + indice.json (segue il toc.ncx; salta `<title>`, note `<sup>`, numeri di pagina)
- `piper_tts.py` sintesi con fonetica da `espeak-ng` CLI (il modulo espeakbridge del wheel macOS di piper è rotto: cerca i dati in un path di build)
- `piper_tts_timed.py` sintesi frase per frase con tempi → wav + json
- `sintetizza_timed.sh`, `genera_timed.sh` orchestrazione (4 in parallelo, m4b finale)

Vanno riscritti come pacchetto `tools/makebook`, non copiati.
