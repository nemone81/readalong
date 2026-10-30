"""``makebook``: da un EPUB o un PDF a un pacchetto ``.rabook`` per ReadAlong.

Esempi::

    makebook libro.epub --list
    makebook libro.epub -o libro.rabook --voice it_IT-paola-medium --chapters 2-24
    makebook libro.pdf -o libro.rabook --title "Il Cigno nero" --author "Nassim Nicholas Taleb"
"""

from __future__ import annotations

import argparse
import hashlib
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from .extract import Book, Chapter, EpubError, looks_like_path, parse_selection, read_epub
from .package import PackChapter, prepare_cover, validate_rabook, write_rabook
from .synth import (
    ChapterJob,
    TimedChapter,
    find_tool,
    probe_duration,
    resolve_voice,
    synthesize_chapters,
    voice_name,
)

DEFAULT_VOICE = "it_IT-paola-medium"
DEFAULT_VOICES_DIR = Path(__file__).resolve().parents[1] / "voices"


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="makebook", description="Genera un libro .rabook (testo + audio Piper).")
    p.add_argument("source", type=Path, help="libro .epub o .pdf")
    p.add_argument("-o", "--output", type=Path, help="pacchetto da scrivere (default: <nome>.rabook)")
    p.add_argument(
        "--voice", default=DEFAULT_VOICE, help=f"voce Piper o path di un .onnx (default {DEFAULT_VOICE})"
    )
    p.add_argument(
        "--voices-dir",
        type=Path,
        default=Path(os.environ.get("MAKEBOOK_VOICES_DIR", DEFAULT_VOICES_DIR)),
        help="cartella delle voci (default tools/makebook/voices o $MAKEBOOK_VOICES_DIR)",
    )
    p.add_argument(
        "--chapters", help="capitoli da includere, numerati come in --list: es. 2-24 oppure 3,5,7-9"
    )
    p.add_argument(
        "--pdf-mode",
        action=argparse.BooleanOptionalAction,
        default=None,
        help="ricuci le righe spezzate dei PDF (default: automatico, attivo per i .pdf e per gli EPUB"
        " convertiti da PDF con calibre)",
    )
    p.add_argument("--list", action="store_true", help="elenca i capitoli trovati ed esce, senza sintesi")
    p.add_argument("--title", help="titolo (default: dai metadati del libro)")
    p.add_argument("--author", help="autore (default: dai metadati del libro)")
    p.add_argument("--language", help="lingua ISO 639-1 (default: dai metadati, altrimenti it)")
    p.add_argument(
        "--jobs", type=int, default=min(4, os.cpu_count() or 1), help="capitoli sintetizzati in parallelo"
    )
    p.add_argument(
        "--work-dir",
        type=Path,
        help="cartella per audio e tempi intermedi: se rilanci, i capitoli già fatti non si rifanno",
    )
    return p


def load_book(source: Path, pdf_mode: bool | None = None) -> Book:
    """Legge un EPUB; un PDF passa prima da ``ebook-convert`` di calibre.

    ``pdf_mode`` ``None`` lascia decidere: sempre attivo per un PDF, per un EPUB lo decide
    ``read_epub`` guardando se viene da un PDF convertito con calibre.
    """
    suffix = source.suffix.lower()
    if suffix == ".epub":
        return read_epub(source, pdf_mode=pdf_mode)
    if suffix == ".pdf":
        convert = find_tool("ebook-convert", "/Applications/calibre.app/Contents/MacOS/ebook-convert")
        with tempfile.TemporaryDirectory(prefix="makebook-") as tmp:
            epub = Path(tmp) / "libro.epub"
            r = subprocess.run([convert, str(source), str(epub)], capture_output=True, text=True)
            if r.returncode != 0 or not epub.is_file():
                tail = "\n".join((r.stdout + r.stderr).strip().splitlines()[-5:])
                raise EpubError(f"ebook-convert non è riuscito a convertire il PDF:\n{tail}")
            return read_epub(epub, pdf_mode=True if pdf_mode is None else pdf_mode)
    raise EpubError(f"formato non supportato: {suffix or '(senza estensione)'} (servono .epub o .pdf)")


def choose_title(meta_title: str, override: str | None, source: Path) -> str:
    """Il titolo dei metadati, salvo override; mai un path (calibre ci mette il nome del PDF)."""
    if override:
        return override.strip()
    if meta_title and not looks_like_path(meta_title):
        return meta_title
    return source.stem


def print_chapters(chapters: list[Chapter]) -> None:
    for n, c in enumerate(chapters, 1):
        print(f"{n:3d}  {c.words:6d} parole  {c.title[:90]}")


def job_key(voice: str, chapter: Chapter) -> str:
    """Impronta di voce + testo: il lavoro intermedio si riusa solo se nulla è cambiato."""
    data = voice + "\n" + "\n\n".join(chapter.paragraphs)
    return hashlib.sha256(data.encode()).hexdigest()[:12]


def run(args: argparse.Namespace) -> int:
    source: Path = args.source
    if not source.is_file():
        print(f"makebook: file non trovato: {source.name}", file=sys.stderr)
        return 2
    book = load_book(source, args.pdf_mode)
    for w in book.warnings:
        print(f"attenzione: {w}", file=sys.stderr)

    if args.list:
        print_chapters(book.chapters)
        return 0

    selected = (
        parse_selection(args.chapters, len(book.chapters))
        if args.chapters
        else list(range(1, len(book.chapters) + 1))
    )
    chapters = [book.chapters[n - 1] for n in selected]
    title = choose_title(book.title, args.title, source)
    author = (args.author or book.author or "Autore sconosciuto").strip()
    language = (args.language or book.language or "it").strip()
    model = resolve_voice(args.voice, args.voices_dir)
    voice = voice_name(model)
    out: Path = args.output or Path(f"{source.stem}.rabook")

    words = sum(c.words for c in chapters)
    print(f"{title} — {author}: {len(chapters)} capitoli, {words} parole, voce {voice}")

    with tempfile.TemporaryDirectory(prefix="makebook-") as tmp:
        work: Path = args.work_dir or Path(tmp)
        work.mkdir(parents=True, exist_ok=True)
        jobs = []
        for k, c in enumerate(chapters, 1):
            key = job_key(voice, c)
            jobs.append(
                ChapterJob(k, c.paragraphs, work / f"{k:02d}-{key}.m4a", work / f"{k:02d}-{key}.json")
            )

        started = time.monotonic()
        done = 0

        def progress(n: int, timed: TimedChapter) -> None:
            nonlocal done
            done += 1
            elapsed = (time.monotonic() - started) / 60
            audio = timed.durata / 60
            print(f"  [{done}/{len(jobs)}] capitolo {n}: {audio:.1f} min di audio ({elapsed:.1f} min)")

        timed = synthesize_chapters(model, jobs, workers=max(1, args.jobs), on_done=progress)

        pack: list[PackChapter] = []
        for job, c in zip(jobs, chapters, strict=True):
            t = timed[job.n]
            audio_len = probe_duration(job.m4a)
            last_e = t.paragrafi[-1][-1].e
            if last_e > audio_len:
                print(
                    f"makebook: capitolo {job.n}: tempi ({last_e}s) oltre l'audio ({audio_len}s)",
                    file=sys.stderr,
                )
                return 1
            pack.append(PackChapter(c.title, t, job.m4a))

        cover = prepare_cover(book.cover)
        out.parent.mkdir(parents=True, exist_ok=True)
        write_rabook(
            out, title=title, author=author, language=language, voice=voice, chapters=pack, cover_jpeg=cover
        )

    problems = validate_rabook(out)
    if problems:
        print("makebook: pacchetto non valido:\n  " + "\n  ".join(problems[:20]), file=sys.stderr)
        return 1
    total = sum(c.timed.durata for c in pack)
    size = out.stat().st_size / 1_000_000
    print(f"pronto: {out.name} — {size:.1f} MB, {total / 60:.1f} min, {len(pack)} capitoli")
    return 0


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        return run(args)
    except (EpubError, FileNotFoundError, ValueError) as e:
        print(f"makebook: {e}", file=sys.stderr)
        return 2
    except subprocess.CalledProcessError as e:
        tool = Path(str(e.cmd[0])).name if isinstance(e.cmd, list) and e.cmd else "comando"
        print(f"makebook: {tool} è fallito (codice {e.returncode})", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
