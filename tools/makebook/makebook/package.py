"""Il pacchetto ``.rabook``: zip con voci *stored* (mai compresse), come da docs/SPEC.md.

::

    book.json         {id, titolo, autore, lingua, voce, versioneFormato: 1,
                       capitoli: [{n, titolo, file, durata}], kindle?: {documento}}
    cover.jpg
    chapters/NN.json  {durata, paragrafi: [[{t, s, e}, …], …]}
    audio/NN.m4a      AAC 64 kbps mono

``file`` di ogni capitolo è il path del suo JSON nello zip (``chapters/01.json``); l'audio ha lo
stesso numero (``audio/01.m4a``). ``kindle`` c'è solo se si è prodotto anche l'EPUB per il Kindle:
``documento`` è il suo partial MD5 alla KOReader (vedi ``epub.py``).
"""

from __future__ import annotations

import hashlib
import json
import re
import subprocess
import zipfile
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .synth import TimedChapter, ffmpeg_bin

FORMAT_VERSION = 1
# Data fissa per tutte le voci: due generazioni identiche danno lo stesso zip.
_ZIP_DATE = (2026, 1, 1, 0, 0, 0)

# Path dell'utente che non devono mai finire dentro un pacchetto.
KINDLE_DOCUMENT = re.compile(r"[0-9a-f]{32}")
LEAK = re.compile(r"/Users/|/home/|/private/(?:tmp|var)/|/var/folders/|[A-Za-z]:\\\\|file://|~/")


@dataclass(frozen=True)
class PackChapter:
    title: str
    timed: TimedChapter
    audio: Path


def chapter_stem(n: int) -> str:
    return f"{n:02d}"


def book_text(chapters: Sequence[TimedChapter]) -> str:
    """Tutto il testo del libro: frasi unite da spazio, paragrafi da riga vuota, capitoli da due."""
    return "\n\n\n".join("\n\n".join(" ".join(s.t for s in par) for par in ch.paragrafi) for ch in chapters)


def book_id(title: str, author: str, text: str) -> str:
    """sha256 esadecimale di ``titolo + "\\n" + autore + "\\n" + testo`` (UTF-8)."""
    return hashlib.sha256(f"{title}\n{author}\n{text}".encode()).hexdigest()


def build_book_json(
    *,
    title: str,
    author: str,
    language: str,
    voice: str,
    chapters: Sequence[PackChapter],
    kindle_document: str | None = None,
) -> dict[str, Any]:
    """``kindle_document`` (partial MD5 dell'EPUB) aggiunge ``kindle.documento``; l'id non cambia."""
    book: dict[str, Any] = {
        "id": book_id(title, author, book_text([c.timed for c in chapters])),
        "titolo": title,
        "autore": author,
        "lingua": language,
        "voce": voice,
        "versioneFormato": FORMAT_VERSION,
        "capitoli": [
            {
                "n": n,
                "titolo": c.title,
                "file": f"chapters/{chapter_stem(n)}.json",
                "durata": c.timed.durata,
            }
            for n, c in enumerate(chapters, 1)
        ],
    }
    if kindle_document is not None:
        if not KINDLE_DOCUMENT.fullmatch(kindle_document):
            raise ValueError(f"kindle.documento non è un MD5 esadecimale minuscolo: {kindle_document!r}")
        book["kindle"] = {"documento": kindle_document}
    return book


def _dumps(data: Any) -> bytes:
    return json.dumps(data, ensure_ascii=False, separators=(",", ":")).encode()


def find_leaks(data: Any) -> list[str]:
    """Stringhe che sembrano path dell'utente, ovunque nel JSON."""
    found: list[str] = []
    if isinstance(data, str):
        if LEAK.search(data):
            found.append(data[:80])
    elif isinstance(data, dict):
        for v in data.values():
            found += find_leaks(v)
    elif isinstance(data, list):
        for v in data:
            found += find_leaks(v)
    return found


def write_rabook(
    out: Path,
    *,
    title: str,
    author: str,
    language: str,
    voice: str,
    chapters: Sequence[PackChapter],
    cover_jpeg: bytes,
    kindle_document: str | None = None,
) -> dict[str, Any]:
    """Scrive il pacchetto (prima in un file temporaneo accanto, poi rinomina). Ritorna book.json."""
    book = build_book_json(
        title=title,
        author=author,
        language=language,
        voice=voice,
        chapters=chapters,
        kindle_document=kindle_document,
    )
    leaks = find_leaks(book) + [x for c in chapters for x in find_leaks(c.timed.to_json())]
    if leaks:
        raise ValueError(f"il testo contiene path di file, pacchetto non scritto: {leaks[:3]}")

    tmp = out.with_name(out.name + ".tmp")
    with zipfile.ZipFile(tmp, "w", compression=zipfile.ZIP_STORED) as z:

        def put(name: str, data: bytes) -> None:
            info = zipfile.ZipInfo(name, date_time=_ZIP_DATE)
            info.compress_type = zipfile.ZIP_STORED
            info.external_attr = 0o644 << 16
            z.writestr(info, data)

        put("book.json", _dumps(book))
        put("cover.jpg", cover_jpeg)
        for n, c in enumerate(chapters, 1):
            put(f"chapters/{chapter_stem(n)}.json", _dumps(c.timed.to_json()))
        for n, c in enumerate(chapters, 1):
            put(f"audio/{chapter_stem(n)}.m4a", c.audio.read_bytes())
    tmp.replace(out)
    return book


# --------------------------------------------------------------------------- copertina


def prepare_cover(image: bytes | None, *, max_side: int = 1400) -> bytes:
    """Copertina in JPEG, lato massimo ``max_side``, senza metadati; tinta unita se manca."""
    base = [ffmpeg_bin(), "-nostdin", "-loglevel", "error", "-y"]
    tail = ["-map_metadata", "-1", "-frames:v", "1", "-q:v", "3", "-f", "image2", "-c:v", "mjpeg", "pipe:1"]
    if image:
        scale = f"scale='min({max_side},iw)':'min({max_side},ih)':force_original_aspect_ratio=decrease"
        cmd = [*base, "-i", "pipe:0", "-vf", f"{scale},format=yuvj420p", *tail]
        return subprocess.run(cmd, input=image, capture_output=True, check=True).stdout
    cmd = [*base, "-f", "lavfi", "-i", "color=c=0x34495e:s=900x1350", "-vf", "format=yuvj420p", *tail]
    return subprocess.run(cmd, capture_output=True, check=True).stdout


# --------------------------------------------------------------------------- validazione


def validate_rabook(path: Path) -> list[str]:
    """Problemi del pacchetto rispetto alla spec (lista vuota = valido).

    Controlla: solo voci stored, file previsti presenti e nessun altro, JSON validi e coerenti,
    frasi in ordine e senza sovrapposizioni, nessun path dell'utente nel testo.
    """
    problems: list[str] = []
    try:
        z = zipfile.ZipFile(path)
    except zipfile.BadZipFile:
        return ["non è uno zip"]
    with z:
        infos = {i.filename: i for i in z.infolist()}
        problems += [f"{n}: compresso" for n, i in infos.items() if i.compress_type != zipfile.ZIP_STORED]
        for required in ("book.json", "cover.jpg"):
            if required not in infos:
                problems.append(f"manca {required}")
        if "book.json" not in infos:
            return problems
        try:
            book = json.loads(z.read("book.json"))
        except ValueError as e:
            return [*problems, f"book.json non valido: {e}"]
        for key in ("id", "titolo", "autore", "lingua", "voce", "versioneFormato", "capitoli"):
            if key not in book:
                problems.append(f"book.json senza {key}")
        if book.get("versioneFormato") != FORMAT_VERSION:
            problems.append(f"versioneFormato {book.get('versioneFormato')!r} invece di {FORMAT_VERSION}")
        if not re.fullmatch(r"[0-9a-f]{64}", str(book.get("id", ""))):
            problems.append("id non è uno sha256 esadecimale")
        if "kindle" in book:
            kindle = book["kindle"]
            doc = kindle.get("documento") if isinstance(kindle, dict) else None
            if not isinstance(doc, str) or not KINDLE_DOCUMENT.fullmatch(doc):
                problems.append("kindle.documento non è un MD5 esadecimale minuscolo")
        expected = {"book.json", "cover.jpg"}
        timed: list[TimedChapter] = []
        for k, ch in enumerate(book.get("capitoli", []), 1):
            stem = chapter_stem(k)
            if ch.get("n") != k:
                problems.append(f"capitolo {k}: n={ch.get('n')!r}")
            if ch.get("file") != f"chapters/{stem}.json":
                problems.append(f"capitolo {k}: file={ch.get('file')!r}")
            expected |= {f"chapters/{stem}.json", f"audio/{stem}.m4a"}
            name = f"chapters/{stem}.json"
            if name not in infos or f"audio/{stem}.m4a" not in infos:
                problems.append(f"capitolo {k}: mancano JSON o audio")
                continue
            data = json.loads(z.read(name))
            problems += [f"{name}: {p}" for p in check_timings(data)]
            if data.get("durata") != ch.get("durata"):
                problems.append(f"{name}: durata diversa da book.json")
            timed.append(TimedChapter.from_json(data))
        problems += [f"voce inattesa: {n}" for n in sorted(set(infos) - expected)]
        if timed and book_id(book.get("titolo", ""), book.get("autore", ""), book_text(timed)) != book.get(
            "id"
        ):
            problems.append("id non corrisponde a titolo+autore+testo")
        problems += [f"path nel testo: {x}" for x in find_leaks(book)]
        for t in timed:
            problems += [f"path nel testo: {x}" for x in find_leaks(t.to_json())]
    return problems


def check_timings(chapter: dict[str, Any]) -> list[str]:
    """Frasi non vuote, in ordine, ``s < e``, senza sovrapposizioni, entro la durata."""
    problems: list[str] = []
    prev_e = 0.0
    paragrafi = chapter.get("paragrafi")
    if not isinstance(paragrafi, list) or not paragrafi:
        return ["nessun paragrafo"]
    for i, par in enumerate(paragrafi):
        if not par:
            problems.append(f"paragrafo {i} vuoto")
        for x in par:
            if not str(x.get("t", "")).strip():
                problems.append(f"frase vuota nel paragrafo {i}")
            s, e = x.get("s"), x.get("e")
            if not isinstance(s, int | float) or not isinstance(e, int | float):
                problems.append(f"tempi mancanti nel paragrafo {i}")
                continue
            if s < prev_e:
                problems.append(f"sovrapposizione a {s}")
            if e <= s:
                problems.append(f"frase di durata nulla a {s}")
            if round(s, 3) != s or round(e, 3) != e:
                problems.append(f"più di 3 decimali a {s}")
            prev_e = e
    if prev_e > chapter.get("durata", 0):
        problems.append("l'ultima frase finisce dopo la durata")
    return problems
