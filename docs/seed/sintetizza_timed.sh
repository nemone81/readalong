#!/bin/zsh
# Uso: sintetizza_timed.sh capitoli/NN.txt → timed/NN.wav + NN.json + NN.m4a (salta se già fatto)
set -euo pipefail
S=${0:A:h}
A=$S/audio
f=$1; n=${${f:t}%.txt}
mkdir -p $A/timed
[[ -s $A/timed/$n.m4a && -s $A/timed/$n.json ]] && exit 0
nice -n 15 $A/venv/bin/python -I $S/piper_tts_timed.py $A/it_IT-paola-medium.onnx $f $A/timed/$n.wav.tmp $A/timed/$n.json.tmp 2>>$A/errori_timed.log
mv $A/timed/$n.wav.tmp $A/timed/$n.wav
mv $A/timed/$n.json.tmp $A/timed/$n.json
nice -n 15 ffmpeg -loglevel error -y -i $A/timed/$n.wav -c:a aac -b:a 64k -ac 1 $A/timed/$n.m4a
echo "fatto $n"
