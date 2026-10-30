from __future__ import annotations

import json
import zipfile
from pathlib import Path

import pytest

from makebook.package import (
    PackChapter,
    book_id,
    book_text,
    check_timings,
    find_leaks,
    validate_rabook,
    write_rabook,
)
from makebook.synth import TimedChapter, TimedSentence


def chapter(title: str, *sentences: str) -> TimedChapter:
    """Titolo come primo paragrafo, poi un paragrafo con le frasi; 1,25 s a frase."""
    timed = [TimedSentence(s, k * 1.25, (k + 1) * 1.25) for k, s in enumerate((title, *sentences))]
    return TimedChapter(durata=timed[-1].e, paragrafi=[timed[:1], timed[1:]])


@pytest.fixture
def pack(tmp_path: Path) -> list[PackChapter]:
    audio = tmp_path / "a.m4a"
    audio.write_bytes(b"audio finto")
    return [
        PackChapter("I. Primo", chapter("I. Primo", "Uno.", "Due…"), audio),
        PackChapter("II. Secondo", chapter("II. Secondo", "Tre."), audio),
    ]


def write(path: Path, pack: list[PackChapter], **kw: str) -> dict:
    args = {"title": "Libro", "author": "Autore", "language": "it", "voice": "it_IT-paola-medium"} | kw
    return write_rabook(path, chapters=pack, cover_jpeg=b"\xff\xd8jpeg", **args)


def test_book_id_is_stable_and_depends_on_text() -> None:
    a = book_id("T", "A", "testo")
    assert a == book_id("T", "A", "testo")
    assert len(a) == 64
    assert a != book_id("T", "A", "testo diverso") != book_id("T", "B", "testo")


def test_written_package_matches_spec(tmp_path: Path, pack: list[PackChapter]) -> None:
    out = tmp_path / "libro.rabook"
    book = write(out, pack)
    assert validate_rabook(out) == []
    with zipfile.ZipFile(out) as z:
        infos = z.infolist()
        assert {i.compress_type for i in infos} == {zipfile.ZIP_STORED}
        assert [i.filename for i in infos] == [
            "book.json",
            "cover.jpg",
            "chapters/01.json",
            "chapters/02.json",
            "audio/01.m4a",
            "audio/02.m4a",
        ]
        stored = json.loads(z.read("book.json"))
        ch1 = json.loads(z.read("chapters/01.json"))
    assert stored == book
    assert set(stored) == {"id", "titolo", "autore", "lingua", "voce", "versioneFormato", "capitoli"}
    assert stored["versioneFormato"] == 1
    assert stored["capitoli"][0] == {"n": 1, "titolo": "I. Primo", "file": "chapters/01.json", "durata": 3.75}
    assert stored["id"] == book_id("Libro", "Autore", book_text([p.timed for p in pack]))
    assert set(ch1) == {"durata", "paragrafi"}
    assert set(ch1["paragrafi"][0][0]) == {"t", "s", "e"}
    assert ch1["paragrafi"][1][1]["t"] == "Due…"  # i puntini restano nel testo salvato


def test_same_input_gives_identical_bytes(tmp_path: Path, pack: list[PackChapter]) -> None:
    write(tmp_path / "a.rabook", pack)
    write(tmp_path / "b.rabook", pack)
    assert (tmp_path / "a.rabook").read_bytes() == (tmp_path / "b.rabook").read_bytes()


def test_refuses_to_write_user_paths(tmp_path: Path, pack: list[PackChapter]) -> None:
    out = tmp_path / "x.rabook"
    with pytest.raises(ValueError, match="path"):
        write(out, pack, title="/Users/fabio/Dropbox/libro.pdf")
    assert not out.exists()
    assert find_leaks({"a": ["ok", {"b": "/home/x/y"}]}) == ["/home/x/y"]


def test_validate_rejects_deflated_entries(tmp_path: Path, pack: list[PackChapter]) -> None:
    good = tmp_path / "good.rabook"
    write(good, pack)
    bad = tmp_path / "bad.rabook"
    with zipfile.ZipFile(good) as src, zipfile.ZipFile(bad, "w", zipfile.ZIP_DEFLATED) as dst:
        for info in src.infolist():
            dst.writestr(info.filename, src.read(info.filename))
    assert any("compresso" in p for p in validate_rabook(bad))


def test_validate_rejects_extra_and_missing_files(tmp_path: Path, pack: list[PackChapter]) -> None:
    good = tmp_path / "good.rabook"
    write(good, pack)
    bad = tmp_path / "bad.rabook"
    with zipfile.ZipFile(good) as src, zipfile.ZipFile(bad, "w") as dst:
        for info in src.infolist():
            if info.filename != "audio/02.m4a":
                dst.writestr(info, src.read(info.filename))
        dst.writestr("extra.txt", "x")
    problems = validate_rabook(bad)
    assert any("mancano" in p for p in problems)
    assert any("extra.txt" in p for p in problems)


def test_check_timings_finds_overlaps_and_overruns() -> None:
    ok = {"durata": 3.0, "paragrafi": [[{"t": "a", "s": 0.0, "e": 1.0}], [{"t": "b", "s": 1.0, "e": 3.0}]]}
    assert check_timings(ok) == []
    overlap = {"durata": 3.0, "paragrafi": [[{"t": "a", "s": 0.0, "e": 2.0}, {"t": "b", "s": 1.5, "e": 3.0}]]}
    assert any("sovrapposizione" in p for p in check_timings(overlap))
    overrun = {"durata": 2.0, "paragrafi": [[{"t": "a", "s": 0.0, "e": 2.5}]]}
    assert any("dopo la durata" in p for p in check_timings(overrun))
    empty = {"durata": 1.0, "paragrafi": [[{"t": " ", "s": 0.0, "e": 1.0}], []]}
    assert len(check_timings(empty)) == 2
