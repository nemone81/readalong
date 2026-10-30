from __future__ import annotations

from pathlib import Path

import pytest

from makebook.cli import build_parser, choose_title, job_key, main
from makebook.extract import Chapter

from .conftest import make_epub, xhtml


def test_defaults() -> None:
    args = build_parser().parse_args(["libro.epub"])
    assert args.voice == "it_IT-paola-medium"
    assert args.voices_dir.name == "voices"
    assert args.chapters is None and args.output is None


def test_title_never_comes_from_a_path() -> None:
    assert choose_title("/Users/fabio/Dropbox/Il Cigno nero.pdf", None, Path("cigno.pdf")) == "cigno"
    assert choose_title("Il Cigno nero", None, Path("x.pdf")) == "Il Cigno nero"
    assert choose_title("qualsiasi", "  Altro titolo ", Path("x.pdf")) == "Altro titolo"


def test_job_key_changes_with_voice_or_text() -> None:
    ch = Chapter("T", ["T", "Testo."])
    assert job_key("v", ch) == job_key("v", Chapter("T", ["T", "Testo."]))
    assert job_key("v", ch) != job_key("w", ch) != job_key("v", Chapter("T", ["T", "Altro."]))


def test_list_prints_chapters_without_synthesis(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    body = " ".join(["Una frase di prova."] * 20)
    epub = make_epub(
        tmp_path / "l.epub",
        {"a.xhtml": xhtml(f"<h1>Uno</h1><p>{body}</p>"), "b.xhtml": xhtml(f"<h1>Due</h1><p>{body}</p>")},
        [("Uno", "a.xhtml"), ("Due", "b.xhtml")],
    )
    assert main([str(epub), "--list"]) == 0
    out = capsys.readouterr().out.splitlines()
    assert [line.split()[-1] for line in out] == ["Uno", "Due"]


def test_errors_are_reported_without_traceback(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    txt = tmp_path / "libro.txt"
    txt.write_text("x")
    assert main([str(txt)]) == 2
    assert "formato non supportato" in capsys.readouterr().err
    assert main([str(tmp_path / "manca.epub")]) == 2


def test_bad_chapter_selection_is_an_error(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    epub = make_epub(
        tmp_path / "s.epub", {"a.xhtml": xhtml("<h1>Uno</h1><p>Testo.</p>")}, [("Uno", "a.xhtml")]
    )
    assert main([str(epub), "--chapters", "5"]) == 2
    assert "inesistente" in capsys.readouterr().err
