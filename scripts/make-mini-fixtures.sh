#!/bin/zsh
# Rigenera i pacchetti di prova minuscoli dei test iOS in
# ios/ReadAlongTests/Fixtures/: mini.rabook (zip -0, valido),
# mini-deflate.rabook (stesso contenuto, zip -9: voci compresse, da rifiutare)
# e mini-v2.rabook (versioneFormato 2, da rifiutare).
# Testo originale; audio di silenzio da 3 s generato con ffmpeg.
set -euo pipefail

ROOT="${0:A:h:h}"
FIX="$ROOT/ios/ReadAlongTests/Fixtures"
WORK="$(mktemp -d -t readalong-mini)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/v1/chapters" "$WORK/v1/audio" "$FIX"
cd "$WORK/v1"

cat > book.json <<'EOF'
{
  "id": "mini-0001",
  "titolo": "Il faro di Punta Lunga",
  "autore": "Autore di prova",
  "lingua": "it",
  "voce": "it_IT-paola-medium",
  "versioneFormato": 1,
  "capitoli": [
    {"n": 1, "titolo": "La lanterna", "file": "chapters/01.json", "durata": 3.0},
    {"n": 2, "titolo": "Il temporale", "file": "chapters/02.json", "durata": 3.0}
  ]
}
EOF
cat > chapters/01.json <<'EOF'
{
  "durata": 3.0,
  "paragrafi": [
    [
      {"t": "Il faro di Punta Lunga si accendeva ogni sera alle sette.", "s": 0.0, "e": 0.8},
      {"t": "Lo custodiva Ernesta, che non aveva mai visto il mare in tempesta.", "s": 0.8, "e": 1.5}
    ],
    [
      {"t": "Quella sera la lanterna tremò.", "s": 1.6, "e": 2.3},
      {"t": "Ernesta salì le scale con la candela in mano.", "s": 2.3, "e": 2.9}
    ]
  ]
}
EOF
cat > chapters/02.json <<'EOF'
{
  "durata": 3.0,
  "paragrafi": [
    [
      {"t": "Il vento arrivò da sud, carico di sale.", "s": 0.0, "e": 1.0},
      {"t": "Le barche rientrarono una dopo l'altra.", "s": 1.0, "e": 2.0}
    ],
    [
      {"t": "All'alba il cielo era di nuovo limpido.", "s": 2.0, "e": 2.9}
    ]
  ]
}
EOF
for n in 01 02; do
    ffmpeg -loglevel error -y -f lavfi -i anullsrc=r=22050:cl=mono -t 3 -c:a aac -b:a 64k "audio/$n.m4a"
done
ffmpeg -loglevel error -y -f lavfi -i color=c=navy:s=60x90 -frames:v 1 cover.jpg

FILES=(book.json cover.jpg chapters/01.json chapters/02.json audio/01.m4a audio/02.m4a)
rm -f "$FIX/mini.rabook" "$FIX/mini-deflate.rabook" "$FIX/mini-v2.rabook"
zip -q -X -D -0 "$FIX/mini.rabook" $FILES
zip -q -X -D -9 "$FIX/mini-deflate.rabook" $FILES

cp -R "$WORK/v1" "$WORK/v2"
cd "$WORK/v2"
sed -i '' 's/"versioneFormato": 1/"versioneFormato": 2/' book.json
zip -q -X -D -0 "$FIX/mini-v2.rabook" $FILES

print "Fixture rigenerate in $FIX"
