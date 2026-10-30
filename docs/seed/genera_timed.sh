#!/bin/zsh
# Rigenera tutti i capitoli con i tempi per frase (4 in parallelo), poi rimonta il .m4b su Dropbox.
set -euo pipefail
S=${0:A:h}
A=$S/audio
C=$A/capitoli
OUT="/Users/f.crestoni/Library/CloudStorage/Dropbox/libri/narrativa/Cigno Nero - Taleb.m4b"
cd $A

# Guardia: niente spazzatura nel testo
if grep -l -E "crestoni|Dropbox|calibre" $C/??.txt >/dev/null 2>&1; then
  echo "TESTO SPORCO, mi fermo"; exit 1
fi

ls $C/??.txt | xargs -n 1 -P 4 $S/sintetizza_timed.sh
n_ok=$(ls $A/timed/??.m4a | wc -l); n_txt=$(ls $C/??.txt | wc -l)
(( n_ok == n_txt )) || { echo "mancano capitoli: $n_ok/$n_txt"; exit 1; }

venv/bin/python -I - <<'PY'
import json, subprocess
idx = json.load(open("capitoli/indice.json"))
idx[-1]["titolo"] = "Epilogo – I cigni bianchi di Evgenija"
meta = [";FFMETADATA1", "title=Il Cigno nero", "artist=Nassim Nicholas Taleb", "genre=Audiobook"]
lista, t = [], 0
for c in idx:
    n = c["file"][:-4]
    ms = int(json.load(open(f"timed/{n}.json"))["durata"] * 1000)
    meta += ["[CHAPTER]", "TIMEBASE=1/1000", f"START={t}", f"END={t+ms}", f"title={c['titolo']}"]
    lista.append(f"file 'timed/{n}.wav'"); t += ms
open("meta.txt", "w").write("\n".join(meta) + "\n")
open("lista.txt", "w").write("\n".join(lista) + "\n")
print("durata totale", t // 60000, "min")
PY

nice -n 15 ffmpeg -loglevel error -y -f concat -safe 0 -i lista.txt -i meta.txt -i epub/cover_image.jpg \
  -map 0:a -map 2:v -map_metadata 1 -map_chapters 1 \
  -c:a aac -b:a 64k -ac 1 -c:v mjpeg -disposition:v attached_pic "$OUT.tmp.m4b"
mv "$OUT.tmp.m4b" "$OUT"
echo "PRONTO: $OUT"
