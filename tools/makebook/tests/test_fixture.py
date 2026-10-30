"""La fixture committata (Pinocchio, 2 capitoli, voce reale) rispetta il contratto con l'app."""

from __future__ import annotations

import json
import shutil
import zipfile
from itertools import pairwise
from pathlib import Path

import pytest

from makebook.package import validate_rabook
from makebook.synth import probe_duration

HAS_FFPROBE = shutil.which("ffprobe") is not None or Path("/opt/homebrew/bin/ffprobe").exists()


def test_fixture_is_small_and_valid(fixture_rabook: Path) -> None:
    assert fixture_rabook.stat().st_size < 3_000_000
    assert validate_rabook(fixture_rabook) == []


def test_fixture_has_only_stored_entries_and_expected_files(fixture_rabook: Path) -> None:
    with zipfile.ZipFile(fixture_rabook) as z:
        infos = z.infolist()
        assert all(i.compress_type == zipfile.ZIP_STORED for i in infos)
        assert sorted(i.filename for i in infos) == [
            "audio/01.m4a",
            "audio/02.m4a",
            "book.json",
            "chapters/01.json",
            "chapters/02.json",
            "cover.jpg",
        ]
        assert z.read("cover.jpg")[:2] == b"\xff\xd8"
        book = json.loads(z.read("book.json"))
    assert book["versioneFormato"] == 1
    assert book["lingua"] == "it"
    assert book["voce"] == "it_IT-paola-medium"
    assert book["autore"] == "Carlo Collodi"
    assert len(book["capitoli"]) == 2


def test_fixture_chapters_start_with_their_title(fixture_rabook: Path) -> None:
    with zipfile.ZipFile(fixture_rabook) as z:
        book = json.loads(z.read("book.json"))
        for ch in book["capitoli"]:
            data = json.loads(z.read(ch["file"]))
            first = " ".join(s["t"] for s in data["paragrafi"][0])
            assert first == ch["titolo"]


@pytest.mark.skipif(not HAS_FFPROBE, reason="ffprobe non installato")
def test_fixture_timings_fit_inside_the_real_audio(fixture_rabook: Path, tmp_path: Path) -> None:
    with zipfile.ZipFile(fixture_rabook) as z:
        book = json.loads(z.read("book.json"))
        for ch in book["capitoli"]:
            stem = Path(ch["file"]).stem
            audio = tmp_path / f"{stem}.m4a"
            audio.write_bytes(z.read(f"audio/{stem}.m4a"))
            data = json.loads(z.read(ch["file"]))
            sentences = [s for p in data["paragrafi"] for s in p]
            starts = [s["s"] for s in sentences]
            assert starts == sorted(starts)
            assert all(a["e"] <= b["s"] for a, b in pairwise(sentences))
            real = probe_duration(audio)
            assert sentences[-1]["e"] <= real
            assert real - data["durata"] < 0.1  # l'AAC aggiunge al più un pacchetto di padding
