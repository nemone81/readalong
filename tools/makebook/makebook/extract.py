"""Dall'EPUB ai capitoli puliti, divisi in paragrafi.

Il lavoro è diviso in due strati:

- funzioni pure su stringhe e liste (``clean_text``, ``clean_blocks``, ``join_broken_lines``,
  ``split_chapters``, …), testabili senza file;
- ``read_epub``, che apre lo zip, segue OPF e indice e passa l'HTML al parser.

Un capitolo è una lista di paragrafi; il primo paragrafo è sempre il titolo del capitolo.
"""

from __future__ import annotations

import posixpath
import re
import unicodedata
import zipfile
from collections import Counter
from dataclasses import dataclass, field
from html import unescape
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote
from xml.etree import ElementTree

# --------------------------------------------------------------------------- modello


@dataclass(frozen=True)
class Block:
    """Un blocco di testo così come esce dall'HTML (un <p>, un <h2>, una riga dopo <br>…)."""

    text: str
    heading: bool = False


@dataclass(frozen=True)
class Chapter:
    title: str
    paragraphs: list[str]

    @property
    def words(self) -> int:
        return sum(len(p.split()) for p in self.paragraphs)


@dataclass
class Book:
    title: str
    author: str
    language: str
    chapters: list[Chapter]
    cover: bytes | None = None
    cover_media_type: str | None = None
    warnings: list[str] = field(default_factory=list)


@dataclass(frozen=True)
class TocEntry:
    title: str
    href: str  # percorso nello zip, normalizzato
    fragment: str | None


# --------------------------------------------------------------------------- pulizia (pura)

_NOTE_MARK = re.compile(r"\[\d{1,4}\]")
_INVISIBLE = re.compile("[\u00ad\u200b\u200c\u200d\u2060\ufeff]")
_PAGE_NUMBER = re.compile(r"[\s\-–—\[\](){}|.]*(?:pag\.?\s*)?\d{1,4}[\s\-–—\[\](){}|.]*", re.IGNORECASE)
_PATH = re.compile(
    r"""(?:^|[\s("'«])(?:
        file://                          # URL di file
      | ~?/(?:[^\s/]+/)+[^\s/]*          # /Users/qualcuno/… o ~/…: almeno due segmenti
      | [A-Za-z]:\\                      # C:\…
    )""",
    re.VERBOSE,
)
_FILE_NAME = re.compile(r"^\S+\.(?:pdf|epub|mobi|azw3?|docx?|html?|xhtml|txt)$", re.IGNORECASE)
_TERMINAL = re.compile(r"[.!?…:;»”\"')\]]$")


def clean_text(text: str) -> str:
    """Normalizza un blocco: NFC, niente caratteri invisibili né rimandi alle note, spazi singoli."""
    text = unicodedata.normalize("NFC", unescape(text))
    text = _INVISIBLE.sub("", text)
    text = _NOTE_MARK.sub("", text)
    text = re.sub(r"\s+", " ", text).strip()
    return re.sub(r"\s+([,.;:!?])", r"\1", text)


def is_page_number(text: str) -> bool:
    """``12``, ``- 12 -``, ``[12]``, ``Pag. 12``: righe che contengono solo un numero di pagina."""
    return bool(_PAGE_NUMBER.fullmatch(text))


def looks_like_path(text: str) -> bool:
    """Vero per path di file e nomi di file isolati (es. il PDF sorgente nel <title> di calibre)."""
    return bool(_PATH.search(text) or _FILE_NAME.match(text.strip()))


def clean_blocks(blocks: list[Block]) -> list[Block]:
    """Pulisce ogni blocco e scarta quelli vuoti, i numeri di pagina e i path di file."""
    out: list[Block] = []
    for b in blocks:
        text = clean_text(b.text)
        if not text or is_page_number(text) or looks_like_path(text):
            continue
        if not re.search(r"\w", text):
            continue
        out.append(Block(text, b.heading))
    return out


def running_heads(blocks: list[Block], min_repeats: int = 5) -> set[str]:
    """Testatine dei PDF: righe brevi, senza punteggiatura finale, ripetute molte volte."""
    counts = Counter(b.text for b in blocks if len(b.text) < 80 and not _TERMINAL.search(b.text))
    return {text for text, n in counts.items() if n >= min_repeats}


def join_broken_lines(blocks: list[Block]) -> list[Block]:
    """Ricuce le righe spezzate dei PDF in paragrafi.

    Una riga chiude il paragrafo se finisce con punteggiatura, se è corta (< 60 caratteri)
    o se è un titolo. Le parole divise a fine riga (``paro- la``) vengono riunite.
    """
    out: list[Block] = []
    buf: list[str] = []
    for i, b in enumerate(blocks):
        if b.heading:
            if buf:
                out.append(Block(_join(buf)))
                buf = []
            out.append(b)
            continue
        buf.append(b.text)
        if i == 0 or _TERMINAL.search(b.text) or len(b.text) < 60:
            out.append(Block(_join(buf)))
            buf = []
    if buf:
        out.append(Block(_join(buf)))
    return out


def _join(lines: list[str]) -> str:
    text = " ".join(lines)
    return re.sub(r"(\w)[-\u00ad] (\w)", r"\1\2", text)


def normalize_title(text: str) -> str:
    """Forma confrontabile di un titolo: minuscole, apostrofi dritti, niente punteggiatura."""
    text = unicodedata.normalize("NFKC", text).replace("\u2019", "'").lower()
    text = _NOTE_MARK.sub("", text)
    text = re.sub(r"[^\w' ]+", " ", text)
    return re.sub(r"\s+", " ", text).strip()


def titles_match(a: str, b: str) -> bool:
    na, nb = normalize_title(a), normalize_title(b)
    if not na or not nb:
        return False
    n = min(len(na), len(nb), 40)
    return na[:n] == nb[:n]


def chapter_from_blocks(title: str, blocks: list[Block]) -> Chapter:
    """Costruisce il capitolo garantendo che il primo paragrafo sia il titolo, da solo."""
    title = clean_text(title)
    paragraphs = [b.text for b in blocks]
    if not paragraphs or not titles_match(paragraphs[0], title):
        paragraphs.insert(0, title)
    return Chapter(title=title, paragraphs=paragraphs)


def split_chapters(
    blocks: list[Block], starts: list[tuple[str, int]], *, min_words: int = 40
) -> list[Chapter]:
    """Taglia i blocchi agli inizi indicati dall'indice.

    ``starts`` è una lista ``(titolo, indice del primo blocco)`` in ordine. Le voci con meno di
    ``min_words`` parole (intestazioni di Parte, frontespizi) confluiscono nel capitolo dopo.
    """
    chapters: list[Chapter] = []
    pending: list[str] = []
    for k, (title, start) in enumerate(starts):
        end = starts[k + 1][1] if k + 1 < len(starts) else len(blocks)
        chapter = chapter_from_blocks(title, blocks[start:end])
        last = k + 1 == len(starts)
        if chapter.words < min_words and not last:
            pending.extend(chapter.paragraphs)
            continue
        if pending:
            chapter = Chapter(chapter.title, pending + chapter.paragraphs)
            pending = []
        chapters.append(chapter)
    return chapters


def drop_front_matter(
    blocks: list[Block], starts: list[tuple[str, int]], *, min_words: int = 40
) -> tuple[list[tuple[str, int]], int]:
    """Toglie il materiale che precede il primo vero capitolo e dice quante parole ha tolto.

    Si scarta sempre il testo prima della prima voce dell'indice. Poi, tra le voci brevi
    (< ``min_words``) che vengono prima della prima voce lunga, sono materiale editoriale
    (copertina, colophon, frontespizio, dedica) quelle con del testo oltre al titolo: vanno via
    loro e tutto ciò che le precede. Un'intestazione nuda (``Parte prima``) che segue resta e
    confluisce nel capitolo dopo, come in ``split_chapters``. Se nessuna voce arriva a
    ``min_words`` (raccolte di testi brevi) non si scarta nessuna voce.

    Restituisce le voci rimaste e le parole scartate.
    """
    if not starts:
        return starts, 0
    first_long: int | None = None
    has_body: list[bool] = []
    for k, (title, start) in enumerate(starts):
        end = starts[k + 1][1] if k + 1 < len(starts) else len(blocks)
        chapter = chapter_from_blocks(title, blocks[start:end])
        if chapter.words >= min_words:
            first_long = k
            break
        has_body.append(len(chapter.paragraphs) > 1)
    cut = 0
    if first_long is not None:
        cut = max((k + 1 for k, body in enumerate(has_body) if body), default=0)
    kept = starts[cut:]
    dropped = sum(len(b.text.split()) for b in blocks[: kept[0][1]])
    return kept, dropped


def parse_selection(spec: str, count: int) -> list[int]:
    """``"2,5-7"`` → ``[2, 5, 6, 7]`` (numeri da 1). Errore se fuori dall'intervallo."""
    chosen: list[int] = []
    for part in spec.split(","):
        part = part.strip()
        if not part:
            continue
        m = re.fullmatch(r"(\d+)(?:\s*-\s*(\d+))?", part)
        if not m:
            raise ValueError(f"selezione di capitoli non valida: {part!r}")
        a = int(m.group(1))
        b = int(m.group(2) or a)
        if a > b:
            raise ValueError(f"intervallo al contrario: {part!r}")
        for n in range(a, b + 1):
            if not 1 <= n <= count:
                raise ValueError(f"capitolo {n} inesistente (ce ne sono {count})")
            if n not in chosen:
                chosen.append(n)
    if not chosen:
        raise ValueError("nessun capitolo selezionato")
    return chosen


# --------------------------------------------------------------------------- HTML → blocchi

_BLOCK_TAGS = {
    "p", "div", "section", "article", "blockquote", "li", "ul", "ol", "tr", "td", "th", "dd", "dt",
    "h1", "h2", "h3", "h4", "h5", "h6", "br", "hr", "pre", "figure", "body",
}  # fmt: skip
_HEADINGS = {"h1", "h2", "h3", "h4", "h5", "h6"}
_SKIP_TAGS = {"head", "title", "style", "script", "sup", "figcaption", "svg", "math", "nav"}
_SKIP_CLASS = re.compile(r"caption|pagenum|pageno|page-number|footnote|endnote|noteref", re.IGNORECASE)
_SKIP_EPUB_TYPE = re.compile(r"footnote|endnote|noteref|rearnote|pagebreak", re.IGNORECASE)
_VOID = {"br", "hr", "img", "meta", "link", "input", "col", "area", "base", "wbr", "source"}


class _BlockParser(HTMLParser):
    """Raccoglie i blocchi di testo e la posizione (indice di blocco) di ogni ``id``."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.blocks: list[Block] = []
        self.anchors: dict[str, int] = {}
        self._buf: list[str] = []
        self._stack: list[tuple[str, bool]] = []
        self._skip = 0
        self._heading = 0

    def _flush(self) -> None:
        text = "".join(self._buf)
        self._buf = []
        if text.strip():
            self.blocks.append(Block(text, heading=self._heading > 0))

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        a = {k: v or "" for k, v in attrs}
        if tag in _BLOCK_TAGS:
            self._flush()
        if "id" in a and a["id"] not in self.anchors:
            self.anchors[a["id"]] = len(self.blocks)
        if "name" in a and tag == "a" and a["name"] not in self.anchors:
            self.anchors[a["name"]] = len(self.blocks)
        if tag in _VOID:
            return
        skip = (
            tag in _SKIP_TAGS
            or bool(_SKIP_CLASS.search(a.get("class", "")))
            or bool(_SKIP_EPUB_TYPE.search(a.get("epub:type", "") + " " + a.get("role", "")))
            or (tag == "aside")
        )
        self._stack.append((tag, skip))
        self._skip += skip
        if tag in _HEADINGS:
            self._heading += 1

    def handle_startendtag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        self.handle_starttag(tag, attrs)
        if tag not in _VOID:
            self.handle_endtag(tag)

    def handle_endtag(self, tag: str) -> None:
        if tag in _VOID:
            if tag in _BLOCK_TAGS:
                self._flush()
            return
        if not any(t == tag for t, _ in self._stack):
            return
        if tag in _BLOCK_TAGS:
            self._flush()
        while self._stack:
            t, skip = self._stack.pop()
            self._skip -= skip
            if t in _HEADINGS:
                self._heading -= 1
            if t == tag:
                break

    def handle_data(self, data: str) -> None:
        if not self._skip:
            self._buf.append(data)

    def close(self) -> None:
        super().close()
        self._flush()


def html_to_blocks(html: str) -> tuple[list[Block], dict[str, int]]:
    """Blocchi di testo grezzi di un documento XHTML e posizione dei suoi ``id``."""
    p = _BlockParser()
    p.feed(html)
    p.close()
    return p.blocks, p.anchors


# --------------------------------------------------------------------------- indice (nav / ncx)


class _NavParser(HTMLParser):
    """Voci ``<a href>`` dentro ``<nav epub:type="toc">`` di un documento di navigazione EPUB 3."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.entries: list[tuple[str, str]] = []
        self._in_toc = 0
        self._nav_depth = 0
        self._href: str | None = None
        self._text: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        a = {k: v or "" for k, v in attrs}
        if tag == "nav":
            self._nav_depth += 1
            if "toc" in a.get("epub:type", "").split() and not self._in_toc:
                self._in_toc = self._nav_depth
        elif tag == "a" and self._in_toc and a.get("href"):
            self._href = a["href"]
            self._text = []

    def handle_endtag(self, tag: str) -> None:
        if tag == "a" and self._href is not None:
            self.entries.append(("".join(self._text), self._href))
            self._href = None
        elif tag == "nav":
            if self._in_toc == self._nav_depth:
                self._in_toc = 0
            self._nav_depth -= 1

    def handle_data(self, data: str) -> None:
        if self._href is not None:
            self._text.append(data)


def _local(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def _resolve(base_dir: str, href: str) -> tuple[str, str | None]:
    path, _, frag = href.partition("#")
    full = posixpath.normpath(posixpath.join(base_dir, unquote(path))) if path else ""
    return full, (unquote(frag) or None)


def parse_ncx(xml: bytes, base_dir: str) -> list[TocEntry]:
    root = ElementTree.fromstring(xml)
    entries: list[TocEntry] = []
    for el in root.iter():
        if _local(el.tag) != "navPoint":
            continue
        label = next((t for t in el.iter() if _local(t.tag) == "text"), None)
        content = next((c for c in el if _local(c.tag) == "content"), None)
        if content is None or not content.get("src"):
            continue
        href, frag = _resolve(base_dir, content.get("src", ""))
        title = clean_text("".join(label.itertext()) if label is not None else "")
        entries.append(TocEntry(title, href, frag))
    return entries


def parse_nav(html: str, base_dir: str) -> list[TocEntry]:
    p = _NavParser()
    p.feed(html)
    p.close()
    out = []
    for text, href in p.entries:
        path, frag = _resolve(base_dir, href)
        out.append(TocEntry(clean_text(text), path, frag))
    return out


# --------------------------------------------------------------------------- lettura EPUB


class EpubError(Exception):
    pass


@dataclass
class _Opf:
    title: str
    author: str
    language: str
    spine: list[str]
    ncx: str | None
    nav: str | None
    cover: str | None
    cover_type: str | None
    base_dir: str
    calibre: bool = False  # l'OPF dichiara calibre come produttore


def _read_opf(z: zipfile.ZipFile) -> _Opf:
    try:
        container = ElementTree.fromstring(z.read("META-INF/container.xml"))
    except KeyError as e:
        raise EpubError("manca META-INF/container.xml: non sembra un EPUB") from e
    rootfile = next((el for el in container.iter() if _local(el.tag) == "rootfile"), None)
    if rootfile is None or not rootfile.get("full-path"):
        raise EpubError("container.xml senza rootfile")
    opf_path = rootfile.get("full-path", "")
    base_dir = posixpath.dirname(opf_path)
    opf = ElementTree.fromstring(z.read(opf_path))

    def meta(name: str) -> str:
        el = next((e for e in opf.iter() if _local(e.tag) == name and (e.text or "").strip()), None)
        return clean_text(el.text or "") if el is not None else ""

    manifest: dict[str, tuple[str, str, str]] = {}
    for el in opf.iter():
        if _local(el.tag) == "item" and el.get("id") and el.get("href"):
            href, _ = _resolve(base_dir, el.get("href", ""))
            manifest[el.get("id", "")] = (href, el.get("media-type", ""), el.get("properties", ""))

    spine_el = next((e for e in opf.iter() if _local(e.tag) == "spine"), None)
    spine = [
        manifest[ref.get("idref", "")][0]
        for ref in (spine_el if spine_el is not None else [])
        if _local(ref.tag) == "itemref" and ref.get("idref") in manifest
    ]
    ncx_id = spine_el.get("toc") if spine_el is not None else None
    ncx = manifest[ncx_id][0] if ncx_id in manifest else None
    if ncx is None:
        ncx = next((h for h, mt, _ in manifest.values() if mt == "application/x-dtbncx+xml"), None)
    nav = next((h for h, _, props in manifest.values() if "nav" in props.split()), None)

    cover = cover_type = None
    for href, mt, props in manifest.values():
        if "cover-image" in props.split():
            cover, cover_type = href, mt
    if cover is None:
        cover_meta = next(
            (e.get("content") for e in opf.iter() if _local(e.tag) == "meta" and e.get("name") == "cover"),
            None,
        )
        if cover_meta and cover_meta in manifest and manifest[cover_meta][1].startswith("image/"):
            cover, cover_type = manifest[cover_meta][0], manifest[cover_meta][1]

    return _Opf(
        title=meta("title"),
        author=meta("creator"),
        language=meta("language"),
        spine=spine,
        ncx=ncx,
        nav=nav,
        cover=cover,
        cover_type=cover_type,
        base_dir=base_dir,
        calibre=made_by_calibre(opf),
    )


def made_by_calibre(opf: ElementTree.Element) -> bool:
    """Calibre firma l'OPF con ``<dc:contributor>calibre (…)`` e ``<meta name="calibre:…">``."""
    for el in opf.iter():
        tag = _local(el.tag)
        if tag == "contributor" and "calibre" in (el.text or "").lower():
            return True
        if tag == "meta" and (el.get("name") or "").startswith("calibre:"):
            return True
    return False


_HTML_TITLE = re.compile(r"<title[^>]*>(.*?)</title>", re.IGNORECASE | re.DOTALL)
_HTML_META = re.compile(r"<meta\b[^>]*>", re.IGNORECASE)
_HTML_ATTR = re.compile(r"""([\w:-]+)\s*=\s*(["'])(.*?)\2""", re.DOTALL)
_PDF_GENERATOR = re.compile(r"pdftohtml|pdf reflow", re.IGNORECASE)


def html_is_pdf_conversion(html: str) -> bool:
    """Una pagina prodotta da calibre a partire da un PDF.

    Calibre lascia due tracce nell'``<head>`` di ogni pagina: il path del PDF sorgente nel
    ``<title>`` e ``<meta name="generator" content="PDF Reflow conversion">`` (pdftohtml).
    """
    body = html.lower().find("<body")
    head = html if body < 0 else html[:body]
    title = _HTML_TITLE.search(head)
    if title and unescape(title.group(1)).strip().lower().endswith(".pdf"):
        return True
    for tag in _HTML_META.findall(head):
        attrs = {k.lower(): v for k, _, v in _HTML_ATTR.findall(tag)}
        if attrs.get("name", "").lower() == "generator" and _PDF_GENERATOR.search(attrs.get("content", "")):
            return True
    return False


def _decode(data: bytes) -> str:
    return data.decode("utf-8", errors="replace")


def read_epub(path: Path, *, pdf_mode: bool | None = None, min_words: int = 40) -> Book:
    """Legge un EPUB e restituisce il libro diviso in capitoli secondo l'indice.

    ``pdf_mode`` attiva le correzioni per gli EPUB ricavati da PDF con calibre: righe spezzate
    da ricucire, sillabazione, testatine ripetute. Con ``None`` si decide da sé: attivo se l'OPF
    è firmato da calibre e almeno una pagina porta le tracce di un PDF (``html_is_pdf_conversion``).

    Il materiale prima del primo capitolo (copertina, colophon, frontespizio, dedica) è scartato
    (``drop_front_matter``); le parole scartate finiscono negli avvisi.
    """
    with zipfile.ZipFile(path) as z:
        opf = _read_opf(z)
        names = set(z.namelist())

        toc: list[TocEntry] = []
        if opf.ncx and opf.ncx in names:
            toc = parse_ncx(z.read(opf.ncx), posixpath.dirname(opf.ncx))
        if not toc and opf.nav and opf.nav in names:
            toc = parse_nav(_decode(z.read(opf.nav)), posixpath.dirname(opf.nav))

        blocks: list[Block] = []
        positions: dict[tuple[str, str | None], int] = {}
        from_pdf = False
        for doc in opf.spine:
            if doc not in names or doc == opf.nav:
                continue
            html = _decode(z.read(doc))
            from_pdf = from_pdf or html_is_pdf_conversion(html)
            raw, anchors = html_to_blocks(html)
            # La pulizia si fa documento per documento, così gli indici delle ancore restano validi.
            by_pos: dict[int, list[str]] = {}
            for frag, pos in anchors.items():
                by_pos.setdefault(pos, []).append(frag)
            positions[(doc, None)] = len(blocks)
            for i in range(len(raw) + 1):
                for frag in by_pos.get(i, []):
                    positions[(doc, frag)] = len(blocks)
                if i < len(raw):
                    blocks.extend(clean_blocks([raw[i]]))

        cover = z.read(opf.cover) if opf.cover and opf.cover in names else None

    warnings: list[str] = []
    starts: list[tuple[str, int]] = []
    last = -1
    for entry in toc:
        pos = positions.get((entry.href, entry.fragment), positions.get((entry.href, None)))
        if pos is None:
            warnings.append(f"voce d'indice senza destinazione: {entry.title}")
            continue
        if pos <= last:
            continue  # sotto-voce che punta allo stesso punto o indietro
        starts.append((entry.title or f"Capitolo {len(starts) + 1}", pos))
        last = pos
    if not starts:
        warnings.append("indice assente o inutilizzabile: un solo capitolo")
        starts = [(opf.title or "Testo", 0)]

    if pdf_mode is None:
        pdf_mode = opf.calibre and from_pdf
        if pdf_mode:
            warnings.append(
                "EPUB convertito da un PDF con calibre: modalità PDF attiva (--no-pdf-mode per spegnerla)"
            )
    if pdf_mode:
        blocks, starts = fix_pdf_blocks(blocks, starts)
    kept, dropped = drop_front_matter(blocks, starts, min_words=min_words)
    if dropped:
        skipped = [title for title, _ in starts[: len(starts) - len(kept)]]
        where = f" ({', '.join(skipped)})" if skipped else ""
        warnings.append(f"scartate {dropped} parole prima del primo capitolo{where}")
    chapters = split_chapters(blocks, kept, min_words=min_words)

    return Book(
        title=opf.title,
        author=opf.author,
        language=(opf.language or "it").split("-")[0].lower(),
        chapters=chapters,
        cover=cover,
        cover_media_type=opf.cover_type,
        warnings=warnings,
    )


def fix_pdf_blocks(
    blocks: list[Block], starts: list[tuple[str, int]]
) -> tuple[list[Block], list[tuple[str, int]]]:
    """Correzioni per i testi da PDF, capitolo per capitolo: via le testatine, righe ricucite.

    Restituisce i nuovi blocchi e gli inizi dei capitoli ricalcolati sui nuovi indici.
    """
    heads = running_heads(blocks)
    fixed: list[Block] = []
    fixed_starts: list[tuple[str, int]] = []
    for k, (title, start) in enumerate(starts):
        end = starts[k + 1][1] if k + 1 < len(starts) else len(blocks)
        part = [b for b in blocks[start:end] if b.text not in heads]
        if part and titles_match(part[0].text, title):
            part[0] = Block(part[0].text, heading=True)  # il titolo non va ricucito col testo
        fixed_starts.append((title, len(fixed)))
        fixed.extend(join_broken_lines(part))
    return fixed, fixed_starts


# --------------------------------------------------------------------------- frasi (pura)

# Abbreviazioni dopo cui il punto non chiude la frase (confronto in minuscolo, senza il punto).
ABBREVIATIONS = frozenset(
    [
        "sig",
        "sigg",
        "sigra",
        "sig.ra",
        "dott",
        "dottssa",
        "prof",
        "profssa",
        "avv",
        "ing",
        "arch",
        "geom",
        "rag",
        "on",
        "sen",
        "dr",
        "mr",
        "mrs",
        "ms",
        "st",
        "ecc",
        "etc",
        "pag",
        "pagg",
        "cap",
        "capp",
        "vol",
        "voll",
        "n",
        "nn",
        "fig",
        "figg",
        "es",
        "cfr",
        "ca",
        "art",
        "par",
        "ed",
        "op",
        "cit",
        "ibid",
        "vs",
    ]
)
_END = re.compile(r"[.!?…]+[»”\"')\]’]*")
_CLOSERS = "»”\"')]’"


def split_sentences(paragraph: str) -> list[str]:
    """Divide un paragrafo in frasi.

    Si spezza dopo ``. ! ? …`` (anche ripetuti, con virgolette o parentesi di chiusura attaccate)
    se segue uno spazio e la frase dopo non comincia con una minuscola (anche dopo una lineetta
    d'inciso). Non si spezza dopo abbreviazioni note, iniziali (``C. Collodi``) e dentro i numeri
    (``3.30``). Frammenti senza lettere né cifre si attaccano alla frase vicina.
    """
    text = re.sub(r"\s+", " ", paragraph).strip()
    if not text:
        return []
    pieces: list[str] = []
    start = 0
    for m in _END.finditer(text):
        end = m.end()
        if end >= len(text) or text[end] != " ":
            continue
        # Prima lettera della frase dopo, saltando lineette e virgolette d'apertura:
        # «— Un re! — diranno subito» è un'unica frase con l'inciso del narratore.
        after = re.match(r"[\s—–\-«“\"'(]*(.)", text[end:])
        if after and after.group(1).islower():
            continue
        if m.group(0).startswith(".") and len(m.group(0).rstrip(_CLOSERS)) == 1:
            word = re.search(r"(\S+)$", text[start : m.start()])
            w = word.group(1).lstrip("(«\"“'").lower() if word else ""
            if w in ABBREVIATIONS or (len(w) == 1 and w.isalpha()):
                continue
        pieces.append(text[start:end].strip())
        start = end + 1
    pieces.append(text[start:].strip())

    sentences: list[str] = []
    for p in pieces:
        if not p:
            continue
        # un frammento senza parole (es. «—» o «...») non è una frase: si attacca alla vicina
        if sentences and not (re.search(r"\w", p) and re.search(r"\w", sentences[-1])):
            sentences[-1] = f"{sentences[-1]} {p}"
        else:
            sentences.append(p)
    return sentences


def text_for_synthesis(sentence: str) -> str:
    """Il testo che va a Piper: i puntini di sospensione diventano un punto (il testo salvato resta)."""
    return sentence.replace("…", ".")
