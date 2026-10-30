"""Sintesi frase per frase con registrazione dei tempi (stessa voce e stesso audio di piper_tts.py).

Uso: python piper_tts_timed.py modello.onnx capitolo.txt uscita.wav uscita.json
Il JSON contiene i paragrafi e, per ogni frase, testo e intervallo in secondi.
"""
import json
import os
import re
import sys
import wave

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import piper.voice as pv  # noqa: E402
from piper import PiperVoice  # noqa: E402
from piper_tts import CliPhonemizer  # noqa: E402

FRASE = re.compile(r"[^.!?…]+[.!?…]*")


def main() -> None:
    model, src, wav_out, json_out = sys.argv[1:5]
    pv._ESPEAK_PHONEMIZER = CliPhonemizer()
    voice = PiperVoice.load(model)
    rate = voice.config.sample_rate

    testo = open(src, encoding="utf-8").read()
    paragrafi, t = [], 0
    with wave.open(wav_out, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        for par in testo.split("\n\n"):
            frasi = []
            for m in FRASE.finditer(par.replace("\n", " ")):
                s = m.group(0).strip()
                if not s:
                    continue
                inizio = t
                for chunk in voice.synthesize(s.replace("…", ".")):
                    data = getattr(chunk, "audio_int16_bytes", None) or chunk.audio_int16_array.tobytes()
                    w.writeframes(data)
                    t += len(data) // 2
                frasi.append({"t": s, "s": round(inizio / rate, 3), "e": round(t / rate, 3)})
            if frasi:
                paragrafi.append(frasi)
    json.dump({"durata": round(t / rate, 3), "paragrafi": paragrafi}, open(json_out, "w"), ensure_ascii=False)
    print(f"{os.path.basename(src)}: {sum(len(p) for p in paragrafi)} frasi, {t / rate / 60:.1f} min")


if __name__ == "__main__":
    main()
