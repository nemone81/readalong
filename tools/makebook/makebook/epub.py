"""L'EPUB per il Kindle (T18): lo legge KOReader, che sincronizza la posizione via KOSync.

Il contratto è in docs/SPEC.md («Kindle via KOReader e KOSync»):

- EPUB 3, spine = esattamente i capitoli, nello stesso ordine di ``capitoli`` in ``book.json``:
  crengine crea un ``DocFragment`` per ogni ``itemref`` dello spine, anche con ``linear="no"``
  (``epubfmt.cpp``: ``appender.setNonLinearFlag(...)`` segna il frammento ma lo crea lo stesso),
  quindi nav e copertina stanno solo nel manifest e ``DocFragment[N]`` è il capitolo N;
- ogni capitolo: ``<body>`` con un ``<h2>`` (titolo) e poi un ``<p>`` per paragrafo, il cui testo
  è la concatenazione delle frasi separate da uno spazio, identica a ``chapters/NN.json``;
- deterministico: stesso input, stessi byte (date fisse, ordine fisso, nessun orologio).

L'identità del documento per KOSync è il *partial MD5* di KOReader (``partial_md5``).
"""

from __future__ import annotations

import hashlib
import re
import zipfile
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path

from .package import find_leaks
from .synth import TimedChapter

# Stessa data fissa del .rabook: due generazioni identiche danno lo stesso EPUB.
_ZIP_DATE = (2026, 1, 1, 0, 0, 0)
_MODIFIED = "2026-01-01T00:00:00Z"
# Caratteri che XML 1.0 non ammette nemmeno come entità: non si possono scrivere senza cambiare il testo.
_XML_INVALID = re.compile("[\x00-\x08\x0b\x0c\x0e-\x1f￾￿]")
_BAD_SPACE = re.compile(r"\s\s|[^\S ]|^\s|\s$")

CONTAINER = (
    '<?xml version="1.0" encoding="UTF-8"?>\n'
    '<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">\n'
    '  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>'
    "</rootfiles>\n"
    "</container>\n"
)


@dataclass(frozen=True)
class EpubChapter:
    title: str
    timed: TimedChapter


def escape(text: str) -> str:
    """Escape XML per testo e attributi; rifiuta i caratteri che XML 1.0 non può rappresentare."""
    bad = _XML_INVALID.search(text)
    if bad:
        raise ValueError(f"carattere non ammesso in XML (U+{ord(bad.group()):04X}) in: {text[:60]!r}")
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")


def paragraph_texts(timed: TimedChapter) -> list[str]:
    """Il testo di ogni paragrafo come lo vede KOReader: frasi unite da uno spazio.

    Spazi diversi da uno spazio singolo interno (a capo, tab, doppi, in testa o in coda) crengine
    li compatterebbe e gli offset dell'XPointer non tornerebbero più col testo: si rifiutano.
    """
    texts = [" ".join(s.t for s in par) for par in timed.paragrafi]
    for t in texts:
        if _BAD_SPACE.search(t):
            raise ValueError(f"spazi non normalizzati nel paragrafo: {t[:60]!r}")
    return texts


def chapter_name(n: int) -> str:
    return f"text/{n:02d}.xhtml"


def chapter_xhtml(title: str, timed: TimedChapter, language: str) -> str:
    """Un capitolo: ``<h2>`` col titolo, poi un ``<p>`` per paragrafo e nient'altro nel body."""
    lang = escape(language)
    body = "\n".join([f"<h2>{escape(title)}</h2>", *(f"<p>{escape(t)}</p>" for t in paragraph_texts(timed))])
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE html>\n'
        f'<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="{lang}" lang="{lang}">\n'
        f'<head><meta charset="UTF-8"/><title>{escape(title)}</title></head>\n'
        f"<body>\n{body}\n</body>\n</html>\n"
    )


def nav_xhtml(titles: Sequence[str], language: str) -> str:
    lang = escape(language)
    items = "\n".join(
        f'<li><a href="{chapter_name(n)}">{escape(t)}</a></li>' for n, t in enumerate(titles, 1)
    )
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE html>\n'
        '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"'
        f' xml:lang="{lang}" lang="{lang}">\n'
        '<head><meta charset="UTF-8"/><title>Indice</title></head>\n'
        '<body>\n<nav epub:type="toc" id="toc"><h1>Indice</h1>\n'
        f"<ol>\n{items}\n</ol>\n</nav>\n</body>\n</html>\n"
    )


def content_opf(*, book_id: str, title: str, author: str, language: str, chapters: int) -> str:
    """OPF: copertina e nav solo nel manifest; nello spine soltanto i capitoli, in ordine."""
    manifest = [
        '<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>',
        '<item id="cover" href="cover.jpg" media-type="image/jpeg" properties="cover-image"/>',
        *(
            f'<item id="c{n:02d}" href="{chapter_name(n)}" media-type="application/xhtml+xml"/>'
            for n in range(1, chapters + 1)
        ),
    ]
    spine = [f'<itemref idref="c{n:02d}"/>' for n in range(1, chapters + 1)]
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid"'
        f' xml:lang="{escape(language)}">\n'
        '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">\n'
        f'<dc:identifier id="bookid">{escape(book_id)}</dc:identifier>\n'
        f"<dc:title>{escape(title)}</dc:title>\n"
        f"<dc:creator>{escape(author)}</dc:creator>\n"
        f"<dc:language>{escape(language)}</dc:language>\n"
        f'<meta property="dcterms:modified">{_MODIFIED}</meta>\n'
        # per i lettori EPUB 2: stessa copertina
        '<meta name="cover" content="cover"/>\n'
        "</metadata>\n"
        "<manifest>\n" + "\n".join(manifest) + "\n</manifest>\n"
        "<spine>\n" + "\n".join(spine) + "\n</spine>\n"
        "</package>\n"
    )


def write_epub(
    out: Path,
    *,
    book_id: str,
    title: str,
    author: str,
    language: str,
    chapters: Sequence[EpubChapter],
    cover_jpeg: bytes,
) -> None:
    """Scrive l'EPUB (prima in un file temporaneo accanto, poi rinomina)."""
    if not chapters:
        raise ValueError("nessun capitolo per l'EPUB")
    leaks = find_leaks([title, author]) + [
        x for c in chapters for x in find_leaks([c.title, *paragraph_texts(c.timed)])
    ]
    if leaks:
        raise ValueError(f"il testo contiene path di file, EPUB non scritto: {leaks[:3]}")
    files: list[tuple[str, bytes, int]] = [
        ("mimetype", b"application/epub+zip", zipfile.ZIP_STORED),
        ("META-INF/container.xml", CONTAINER.encode(), zipfile.ZIP_DEFLATED),
        (
            "OEBPS/content.opf",
            content_opf(
                book_id=book_id, title=title, author=author, language=language, chapters=len(chapters)
            ).encode(),
            zipfile.ZIP_DEFLATED,
        ),
        ("OEBPS/nav.xhtml", nav_xhtml([c.title for c in chapters], language).encode(), zipfile.ZIP_DEFLATED),
        ("OEBPS/cover.jpg", cover_jpeg, zipfile.ZIP_STORED),
        *(
            (
                f"OEBPS/{chapter_name(n)}",
                chapter_xhtml(c.title, c.timed, language).encode(),
                zipfile.ZIP_DEFLATED,
            )
            for n, c in enumerate(chapters, 1)
        ),
    ]
    tmp = out.with_name(out.name + ".tmp")
    with zipfile.ZipFile(tmp, "w") as z:
        for name, data, method in files:
            info = zipfile.ZipInfo(name, date_time=_ZIP_DATE)
            info.compress_type = method
            info.create_system = 3  # fisso: altrimenti dipende dal sistema che genera
            info.external_attr = 0o644 << 16
            z.writestr(info, data, compresslevel=9 if method == zipfile.ZIP_DEFLATED else None)
    tmp.replace(out)


# --------------------------------------------------------------------------- identità KOSync


def partial_md5(path: Path) -> str:
    """Il *partial MD5* di KOReader (``util.partialMD5`` in ``frontend/util.lua``).

    MD5 dei campioni da 1024 byte agli offset ``lshift(1024, 2*i)`` per ``i = -1…10``. In LuaJIT
    lo shift usa i 5 bit bassi del conteggio su 32 bit: ``lshift(1024, -2)`` = ``1024 << 30`` = 0,
    quindi il primo campione parte da 0. Ci si ferma al primo ``read`` che non restituisce nulla;
    un campione parziale a fine file si include.
    """
    digest = hashlib.md5(usedforsecurity=False)
    with path.open("rb") as f:
        for i in range(-1, 11):
            f.seek(0 if i < 0 else 1024 << (2 * i))
            sample = f.read(1024)
            if not sample:
                break
            digest.update(sample)
    return digest.hexdigest()
