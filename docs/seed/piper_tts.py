"""Piper con fonetica da espeak di sistema (il modulo espeakbridge del wheel macOS è rotto).

Uso: python piper_tts.py modello.onnx testo.txt uscita.wav
"""
import re
import subprocess
import sys
import unicodedata
import wave

import piper.voice as pv
from piper import PiperVoice

CLAUSE = re.compile(r"[^.,;:!?…]+[.,;:!?…]*")


class CliPhonemizer:
    def phonemize(self, voice: str, text: str) -> list[list[str]]:
        sentences: list[list[str]] = []
        current: list[str] = []
        for m in CLAUSE.finditer(text):
            chunk = m.group(0).strip()
            if not chunk:
                continue
            words = chunk.rstrip(".,;:!?…").strip()
            term = chunk[len(chunk.rstrip(".,;:!?…")):][:1]
            if words:
                out = subprocess.run(
                    ["espeak-ng", "-v", voice, "-q", "--ipa"],
                    input=words, capture_output=True, text=True, check=True,
                ).stdout
                ph = " ".join(out.split())
                ph = re.sub(r"\([^)]+\)", "", ph)
            else:
                ph = ""
            ph += term
            if term in (",", ":", ";"):
                ph += " "
            elif current or ph:
                ph += " "
            current.extend(unicodedata.normalize("NFD", ph))
            if term in (".", "!", "?", "…"):
                sentences.append(current)
                current = []
        if current:
            sentences.append(current)
        return sentences


def main() -> None:
    model, src, dst = sys.argv[1:4]
    pv._ESPEAK_PHONEMIZER = CliPhonemizer()
    voice = PiperVoice.load(model)
    with open(src, encoding="utf-8") as f, wave.open(dst, "wb") as w:
        voice.synthesize_wav(f.read(), w)


if __name__ == "__main__":
    main()
