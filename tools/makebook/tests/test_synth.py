from __future__ import annotations

import shutil
import wave
from pathlib import Path

import pytest

from makebook.synth import (
    PiperBackend,
    TimedChapter,
    clauses,
    plan_sentences,
    resolve_voice,
    synthesize_to_wav,
    timings_from_samples,
)

from .conftest import VOICE


class FakeVoice:
    """Voce finta: 100 campioni per carattere, e si ricorda cosa le è stato chiesto."""

    sample_rate = 1000

    def __init__(self) -> None:
        self.asked: list[str] = []

    def synthesize_pcm(self, text: str) -> bytes:
        self.asked.append(text)
        return b"\x00\x00" * (100 * len(text))


def test_timings_are_cumulative_contiguous_and_truncated() -> None:
    timed = timings_from_samples([["a", "b"], ["c"]], [[1500, 2001], [999]], rate=1000)
    flat = [x for p in timed.paragrafi for x in p]
    assert [(x.s, x.e) for x in flat] == [(0.0, 1.5), (1.5, 3.501), (3.501, 4.5)]
    assert timed.durata == 4.5
    # troncati: 1 campione a 22050 Hz non arrotonda a 0.001 ma resta 0.0
    assert timings_from_samples([["x"]], [[1]], rate=22050).durata == 0.0
    assert timings_from_samples([["x"]], [[22049]], rate=22050).durata == 0.999


def test_timings_reject_mismatched_shapes() -> None:
    with pytest.raises(ValueError):
        timings_from_samples([["a", "b"]], [[1]], rate=1000)


def test_plan_sentences_drops_empty_paragraphs() -> None:
    assert plan_sentences(["Titolo", "", "Uno. Due."]) == [["Titolo"], ["Uno.", "Due."]]


def test_clauses_split_on_punctuation_like_espeak() -> None:
    assert clauses("Ciao, mondo. Come va?") == [("Ciao", ","), ("mondo", "."), ("Come va", "?")]


def test_synthesize_to_wav_with_fake_voice(tmp_path: Path) -> None:
    voice = FakeVoice()
    wav = tmp_path / "c.wav"
    timed = synthesize_to_wav(voice, [["Titolo"], ["Aspetta… ecco.", "Fine."]], wav)
    assert voice.asked == ["Titolo", "Aspetta. ecco.", "Fine."]  # … → . solo per la sintesi
    assert timed.paragrafi[1][0].t == "Aspetta… ecco."  # il testo salvato resta quello originale
    with wave.open(str(wav)) as w:
        assert w.getnframes() / w.getframerate() == pytest.approx(timed.durata)
    assert TimedChapter.from_json(timed.to_json()) == timed


def test_resolve_voice(tmp_path: Path) -> None:
    (tmp_path / "v.onnx").write_bytes(b"")
    with pytest.raises(FileNotFoundError):
        resolve_voice("v", tmp_path)  # manca il .onnx.json
    (tmp_path / "v.onnx.json").write_text("{}")
    assert resolve_voice("v", tmp_path) == tmp_path / "v.onnx"
    assert resolve_voice(str(tmp_path / "v.onnx"), Path("/altrove")) == tmp_path / "v.onnx"
    with pytest.raises(FileNotFoundError, match="non trovata"):
        resolve_voice("inesistente", tmp_path)


@pytest.mark.slow
@pytest.mark.skipif(not VOICE.is_file(), reason="voce Piper non scaricata in tools/makebook/voices")
@pytest.mark.skipif(shutil.which("espeak-ng") is None and not Path("/opt/homebrew/bin/espeak-ng").exists(),
                    reason="espeak-ng non installato")  # fmt: skip
def test_real_piper_synthesis_of_two_sentences(tmp_path: Path) -> None:
    voice = PiperBackend(VOICE)
    wav = tmp_path / "vero.wav"
    timed = synthesize_to_wav(voice, [["C'era una volta un pezzo di legno.", "Un re!"]], wav)
    a, b = timed.paragrafi[0]
    assert 0 == a.s < a.e == b.s < b.e == timed.durata
    assert 1.0 < a.e - a.s < 6.0  # una frase breve dura qualche secondo, non zero né un minuto
    with wave.open(str(wav)) as w:
        assert w.getframerate() == voice.sample_rate
        assert w.getnframes() / w.getframerate() >= timed.durata
