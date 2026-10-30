"""Sintesi vocale frase per frase con Piper, con i tempi di ogni frase.

Il wheel macOS di ``piper-tts`` porta un modulo ``espeakbridge`` che cerca i dati fonetici in un
path della macchina di build: qui la fonetica la fa ``espeak-ng`` di sistema, via riga di comando,
installata al posto del fonemizzatore interno (``CliPhonemizer``).

I tempi sono esatti per costruzione: si contano i campioni prodotti da Piper per ogni frase.
"""

from __future__ import annotations

import contextlib
import json
import os
import re
import shutil
import subprocess
import unicodedata
import wave
from collections.abc import Iterable, Sequence
from concurrent.futures import ProcessPoolExecutor, as_completed
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Protocol

from .extract import split_sentences, text_for_synthesis

_CLAUSE = re.compile(r"[^.,;:!?…]+[.,;:!?…]*")
_TERMINALS = ".,;:!?…"
_SENTENCE_END = (".", "!", "?", "…")


# --------------------------------------------------------------------------- strumenti esterni


def find_tool(name: str, *fallbacks: str) -> str:
    """Path di un eseguibile: PATH, poi i percorsi noti (Homebrew, calibre)."""
    found = shutil.which(name)
    if found:
        return found
    for f in fallbacks:
        if os.access(f, os.X_OK):
            return f
    raise FileNotFoundError(f"{name} non trovato: installalo (vedi tools/makebook/README.md)")


def espeak_bin() -> str:
    return find_tool("espeak-ng", "/opt/homebrew/bin/espeak-ng", "/usr/local/bin/espeak-ng")


def ffmpeg_bin() -> str:
    return find_tool("ffmpeg", "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg")


def ffprobe_bin() -> str:
    return find_tool("ffprobe", "/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe")


# --------------------------------------------------------------------------- fonetica


def clauses(text: str) -> list[tuple[str, str]]:
    """Divide il testo in ``(parole, punteggiatura finale)`` come fa espeak con le pause."""
    out: list[tuple[str, str]] = []
    for m in _CLAUSE.finditer(text):
        chunk = m.group(0).strip()
        if not chunk:
            continue
        words = chunk.rstrip(_TERMINALS).strip()
        term = chunk[len(chunk.rstrip(_TERMINALS)) :][:1]
        out.append((words, term))
    return out


class CliPhonemizer:
    """Sostituto di ``piper.voice.EspeakPhonemizer`` che usa ``espeak-ng -q --ipa``."""

    def __init__(self, binary: str | None = None) -> None:
        self.binary = binary or espeak_bin()

    def _ipa(self, voice: str, words: str) -> str:
        out = subprocess.run(
            [self.binary, "-v", voice, "-q", "--ipa"],
            input=words,
            capture_output=True,
            text=True,
            check=True,
        ).stdout
        return re.sub(r"\([^)]+\)", "", " ".join(out.split()))  # via i cambi di lingua "(en)"

    def phonemize(self, voice: str, text: str) -> list[list[str]]:
        sentences: list[list[str]] = []
        current: list[str] = []
        for words, term in clauses(text):
            ph = self._ipa(voice, words) if words else ""
            ph += term
            if term in (",", ":", ";") or current or ph:
                ph += " "
            current.extend(unicodedata.normalize("NFD", ph))
            if term in _SENTENCE_END:
                sentences.append(current)
                current = []
        if current:
            sentences.append(current)
        return sentences


class Voice(Protocol):
    """Quel che serve di ``PiperVoice``: comodo per i test."""

    @property
    def sample_rate(self) -> int: ...

    def synthesize_pcm(self, text: str) -> bytes: ...


class PiperBackend:
    """Voce Piper caricata da un ``.onnx`` (con il suo ``.onnx.json`` accanto)."""

    def __init__(self, model: Path) -> None:
        import piper.voice as pv
        from piper import PiperVoice

        pv._ESPEAK_PHONEMIZER = CliPhonemizer()  # type: ignore[assignment]
        self._voice = PiperVoice.load(model)
        self._rate = int(self._voice.config.sample_rate)

    @property
    def sample_rate(self) -> int:
        return self._rate

    def synthesize_pcm(self, text: str) -> bytes:
        return b"".join(chunk.audio_int16_bytes for chunk in self._voice.synthesize(text))


def resolve_voice(voice: str, voices_dir: Path) -> Path:
    """``it_IT-paola-medium`` → ``<voices_dir>/it_IT-paola-medium.onnx``; accetta anche un path."""
    direct = Path(voice).expanduser()
    candidates = [direct] if direct.suffix == ".onnx" else [voices_dir / f"{voice}.onnx"]
    for c in candidates:
        if c.is_file() and c.with_name(c.name + ".json").is_file():
            return c
    raise FileNotFoundError(
        f"voce {voice!r} non trovata in {voices_dir.name}/ (servono .onnx e .onnx.json): "
        "vedi «Scaricare una voce» nel README"
    )


def voice_name(model: Path) -> str:
    return model.name.removesuffix(".onnx")


# --------------------------------------------------------------------------- tempi (pura)


@dataclass(frozen=True)
class TimedSentence:
    t: str
    s: float
    e: float


@dataclass(frozen=True)
class TimedChapter:
    durata: float
    paragrafi: list[list[TimedSentence]]

    def to_json(self) -> dict[str, Any]:
        return {
            "durata": self.durata,
            "paragrafi": [[{"t": x.t, "s": x.s, "e": x.e} for x in p] for p in self.paragrafi],
        }

    @staticmethod
    def from_json(data: dict[str, Any]) -> TimedChapter:
        return TimedChapter(
            durata=float(data["durata"]),
            paragrafi=[
                [TimedSentence(x["t"], float(x["s"]), float(x["e"])) for x in p] for p in data["paragrafi"]
            ],
        )


def plan_sentences(paragraphs: Sequence[str]) -> list[list[str]]:
    """Paragrafi → frasi; i paragrafi rimasti vuoti spariscono."""
    return [ss for ss in (split_sentences(p) for p in paragraphs) if ss]


def _ms(samples: int, rate: int) -> float:
    """Campioni → secondi, troncati al millesimo."""
    return (samples * 1000 // rate) / 1000


def timings_from_samples(
    sentences: Sequence[Sequence[str]], samples: Sequence[Sequence[int]], rate: int
) -> TimedChapter:
    """Tempi in secondi (3 decimali) dai campioni prodotti per ogni frase, in ordine.

    Inizio e fine vengono dallo stesso contatore cumulativo, quindi la fine di una frase coincide
    con l'inizio della successiva: niente sovrapposizioni né buchi. I millesimi sono troncati, non
    arrotondati: nessun tempo supera la durata vera dell'audio.
    """
    if [len(p) for p in sentences] != [len(p) for p in samples]:
        raise ValueError("frasi e campioni non corrispondono")
    total = 0
    paragrafi: list[list[TimedSentence]] = []
    for par, counts in zip(sentences, samples, strict=True):
        out = []
        for text, n in zip(par, counts, strict=True):
            start = total
            total += n
            out.append(TimedSentence(text, _ms(start, rate), _ms(total, rate)))
        paragrafi.append(out)
    return TimedChapter(durata=_ms(total, rate), paragrafi=paragrafi)


# --------------------------------------------------------------------------- sintesi (I/O)


def synthesize_to_wav(voice: Voice, sentences: Sequence[Sequence[str]], wav_path: Path) -> TimedChapter:
    """Sintetizza le frasi una per una nello stesso WAV e ne registra i tempi."""
    rate = voice.sample_rate
    samples: list[list[int]] = []
    with wave.open(str(wav_path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        for par in sentences:
            counts = []
            for s in par:
                pcm = voice.synthesize_pcm(text_for_synthesis(s))
                w.writeframes(pcm)
                counts.append(len(pcm) // 2)
            samples.append(counts)
    return timings_from_samples(sentences, samples, rate)


def encode_m4a(wav: Path, m4a: Path) -> None:
    """WAV → AAC 64 kbps mono, senza metadati."""
    subprocess.run(
        [
            ffmpeg_bin(), "-nostdin", "-loglevel", "error", "-y", "-i", str(wav),
            "-map_metadata", "-1", "-vn", "-c:a", "aac", "-b:a", "64k", "-ac", "1", str(m4a),
        ],
        check=True,
    )  # fmt: skip


def probe_duration(path: Path) -> float:
    out = subprocess.run(
        [ffprobe_bin(), "-v", "error", "-show_entries", "format=duration", "-of", "json", str(path)],
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    return float(json.loads(out)["format"]["duration"])


# --------------------------------------------------------------------------- capitoli in parallelo


@dataclass(frozen=True)
class ChapterJob:
    n: int
    paragraphs: list[str]
    m4a: Path
    timings: Path


_WORKER_VOICE: Voice | None = None


def _init_worker(model: Path) -> None:
    global _WORKER_VOICE
    with contextlib.suppress(OSError):
        os.nice(10)  # la sintesi è lunga: il Mac resta usabile
    _WORKER_VOICE = PiperBackend(model)


def _run_job(job: ChapterJob) -> tuple[int, TimedChapter]:
    assert _WORKER_VOICE is not None
    return job.n, synthesize_chapter(_WORKER_VOICE, job)


def synthesize_chapter(voice: Voice, job: ChapterJob) -> TimedChapter:
    """Un capitolo: WAV temporaneo → M4A + JSON dei tempi accanto. Riprende se già fatto."""
    if job.m4a.is_file() and job.timings.is_file():
        return TimedChapter.from_json(json.loads(job.timings.read_text(encoding="utf-8")))
    wav = job.m4a.with_suffix(".wav.tmp")
    tmp_m4a = job.m4a.with_suffix(".tmp.m4a")
    try:
        timed = synthesize_to_wav(voice, plan_sentences(job.paragraphs), wav)
        encode_m4a(wav, tmp_m4a)
    finally:
        wav.unlink(missing_ok=True)
    tmp_m4a.replace(job.m4a)
    job.timings.write_text(json.dumps(timed.to_json(), ensure_ascii=False), encoding="utf-8")
    return timed


def synthesize_chapters(
    model: Path, jobs: Iterable[ChapterJob], workers: int = 1, on_done: Any = None
) -> dict[int, TimedChapter]:
    """Sintetizza i capitoli, ``workers`` processi in parallelo (ognuno carica la voce una volta)."""
    jobs = list(jobs)
    results: dict[int, TimedChapter] = {}
    if workers <= 1:
        _init_worker(model)
        for job in jobs:
            n, timed = _run_job(job)
            results[n] = timed
            if on_done:
                on_done(n, timed)
        return results
    with ProcessPoolExecutor(max_workers=workers, initializer=_init_worker, initargs=(model,)) as ex:
        for fut in as_completed([ex.submit(_run_job, j) for j in jobs]):
            n, timed = fut.result()
            results[n] = timed
            if on_done:
                on_done(n, timed)
    return results
