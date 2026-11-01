"""EPUB per il Kindle (T18a): struttura che crengine legge come serve a KOSync, partial MD5."""

from __future__ import annotations

import hashlib
import json
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

import pytest

import makebook.cli as cli
from makebook.epub import EpubChapter, chapter_xhtml, partial_md5, write_epub
from makebook.package import validate_rabook
from makebook.synth import ChapterJob, TimedChapter, TimedSentence, plan_sentences

from .conftest import make_epub, xhtml

OPF = "{http://www.idpf.org/2007/opf}"
DC = "{http://purl.org/dc/elements/1.1/}"
XH = "{http://www.w3.org/1999/xhtml}"


def md5(data: bytes) -> str:
    return hashlib.md5(data).hexdigest()


def timed(*paragraphs: list[str]) -> TimedChapter:
    out: list[list[TimedSentence]] = []
    k = 0
    for par in paragraphs:
        row = []
        for s in par:
            row.append(TimedSentence(s, k * 1.0, (k + 1) * 1.0))
            k += 1
        out.append(row)
    return TimedChapter(durata=float(k), paragrafi=out)


CHAPTERS = [
    EpubChapter("I. Primo", timed(["I.", "Primo"], ["L'albero è «grande».", "Sì & no <forse>."])),
    EpubChapter("II. Secondo", timed(["II.", "Secondo"], ['Disse: "basta"…'], ["Fine."])),
]


def write(path: Path, chapters: list[EpubChapter] = CHAPTERS, **kw: str) -> Path:
    args = {"book_id": "a" * 64, "title": "Libro & co.", "author": "Autrice", "language": "it"} | kw
    write_epub(path, chapters=chapters, cover_jpeg=b"\xff\xd8jpeg", **args)
    return path


# --------------------------------------------------------------------------- partial MD5


def test_partial_md5_of_a_short_file_is_the_md5_of_the_file(tmp_path: Path) -> None:
    for size in (0, 1, 700, 1024):
        f = tmp_path / f"f{size}"
        data = bytes(range(256)) * 5
        f.write_bytes(data[:size])
        assert partial_md5(f) == md5(data[:size]), size


def test_partial_md5_samples_0_1024_4096_with_a_partial_last_one(tmp_path: Path) -> None:
    data = bytes((i * 7 + 3) % 256 for i in range(5000))
    f = tmp_path / "f"
    f.write_bytes(data)
    expected = md5(data[0:1024] + data[1024:2048] + data[4096:5000])
    assert partial_md5(f) == expected
    assert partial_md5(f) != md5(data)

    # i byte fra un campione e l'altro (2048…4095) non contano
    changed = bytearray(data)
    changed[3000] ^= 0xFF
    f.write_bytes(bytes(changed))
    assert partial_md5(f) == expected
    # quelli dentro l'ultimo campione parziale sì
    changed[4999] ^= 0xFF
    f.write_bytes(bytes(changed))
    assert partial_md5(f) != expected


def test_partial_md5_stops_at_the_first_offset_past_the_end(tmp_path: Path) -> None:
    data = bytes((i * 13) % 251 for i in range(20_000))
    f = tmp_path / "f"
    f.write_bytes(data)
    samples = [data[o : o + 1024] for o in (0, 1024, 4096, 16_384)]  # 65 536 è oltre la fine
    assert partial_md5(f) == md5(b"".join(samples))


def test_kindle_id_command_prints_the_partial_md5(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    f = write(tmp_path / "l.epub")
    assert cli.main(["kindle-id", str(f)]) == 0
    assert capsys.readouterr().out.strip() == partial_md5(f)
    assert cli.main(["kindle-id", str(tmp_path / "manca.epub")]) == 2


# --------------------------------------------------------------------------- struttura EPUB


def test_epub_container_and_mimetype(tmp_path: Path) -> None:
    with zipfile.ZipFile(write(tmp_path / "l.epub")) as z:
        infos = z.infolist()
        assert infos[0].filename == "mimetype"
        assert infos[0].compress_type == zipfile.ZIP_STORED and not infos[0].extra
        assert z.read("mimetype") == b"application/epub+zip"
        assert z.testzip() is None
        container = ET.fromstring(z.read("META-INF/container.xml"))
        rootfile = container.find(".//{urn:oasis:names:tc:opendocument:xmlns:container}rootfile")
        assert rootfile is not None and rootfile.get("full-path") == "OEBPS/content.opf"
    # i primi byte del file sono quelli che i lettori controllano
    assert (tmp_path / "l.epub").read_bytes()[30:58] == b"mimetypeapplication/epub+zip"


def test_opf_spine_is_exactly_the_chapters_in_order(tmp_path: Path) -> None:
    with zipfile.ZipFile(write(tmp_path / "l.epub", book_id="b" * 64)) as z:
        opf = ET.fromstring(z.read("OEBPS/content.opf"))
        names = set(z.namelist())
    assert opf.get("version") == "3.0"
    meta = opf.find(f"{OPF}metadata")
    assert meta is not None
    assert meta.findtext(f"{DC}identifier") == "b" * 64
    assert meta.findtext(f"{DC}title") == "Libro & co."
    assert meta.findtext(f"{DC}creator") == "Autrice"
    assert meta.findtext(f"{DC}language") == "it"
    modified = [m.text for m in meta.findall(f"{OPF}meta") if m.get("property") == "dcterms:modified"]
    assert modified == ["2026-01-01T00:00:00Z"]

    items = {i.get("id"): i for i in opf.iter(f"{OPF}item")}
    assert all(f"OEBPS/{i.get('href')}" in names for i in items.values())
    assert items["nav"].get("properties") == "nav"
    assert items["cover"].get("properties") == "cover-image"
    spine = [r.get("idref") for r in opf.iter(f"{OPF}itemref")]
    # crengine fa un DocFragment per ogni itemref, anche linear="no": nav e copertina restano fuori
    assert [items[i].get("href") for i in spine] == ["text/01.xhtml", "text/02.xhtml"]
    assert all(r.get("linear") is None for r in opf.iter(f"{OPF}itemref"))


def test_nav_lists_the_chapters(tmp_path: Path) -> None:
    with zipfile.ZipFile(write(tmp_path / "l.epub")) as z:
        nav = ET.fromstring(z.read("OEBPS/nav.xhtml"))
    links = [(a.get("href"), a.text) for a in nav.iter(f"{XH}a")]
    assert links == [("text/01.xhtml", "I. Primo"), ("text/02.xhtml", "II. Secondo")]


def body_of(xml: bytes | str) -> ET.Element:
    body = ET.fromstring(xml).find(f"{XH}body")
    assert body is not None
    return body


def test_chapter_body_is_only_one_p_per_paragraph() -> None:
    ch = CHAPTERS[0]
    body = body_of(chapter_xhtml(ch.title, ch.timed, "it"))
    kids = list(body)
    assert [k.tag for k in kids] == [f"{XH}p", f"{XH}p"]  # niente h2: il primo paragrafo è il titolo
    assert [k.text for k in kids] == ["I. Primo", "L'albero è «grande». Sì & no <forse>."]
    assert all(len(k) == 0 for k in kids)  # niente span né altro dentro
    assert (body.text or "").strip() == "" and all((k.tail or "").strip() == "" for k in kids)


def test_xml_escaping_and_invalid_characters() -> None:
    xml = chapter_xhtml('a < b & "c"', timed(["x > y & z"]), "it")
    assert "<p>x &gt; y &amp; z</p>" in xml
    assert body_of(xml)[0].text == "x > y & z"
    assert ET.fromstring(xml).findtext(f"{XH}head/{XH}title") == 'a < b & "c"'
    with pytest.raises(ValueError, match="non ammesso"):
        chapter_xhtml("T", timed(["campanello\x07"]), "it")
    with pytest.raises(ValueError, match="spazi"):
        chapter_xhtml("T", timed(["a  b"]), "it")


def test_same_input_gives_identical_bytes(tmp_path: Path) -> None:
    a = write(tmp_path / "a.epub").read_bytes()
    b = write(tmp_path / "b.epub").read_bytes()
    assert a == b
    assert write(tmp_path / "c.epub", title="Altro").read_bytes() != a
    assert {i.date_time for i in zipfile.ZipFile(tmp_path / "a.epub").infolist()} == {(2026, 1, 1, 0, 0, 0)}


def test_refuses_user_paths(tmp_path: Path) -> None:
    with pytest.raises(ValueError, match="path"):
        write(tmp_path / "l.epub", title="/Users/qualcuno/libro.pdf")
    assert not (tmp_path / "l.epub").exists()


def test_fixture_text_survives_character_by_character(fixture_rabook: Path, tmp_path: Path) -> None:
    with zipfile.ZipFile(fixture_rabook) as z:
        book = json.loads(z.read("book.json"))
        chapters = [
            EpubChapter(c["titolo"], TimedChapter.from_json(json.loads(z.read(c["file"]))))
            for c in book["capitoli"]
        ]
        raw = [json.loads(z.read(c["file"])) for c in book["capitoli"]]
    epub = write(tmp_path / "p.epub", chapters, book_id=book["id"], title=book["titolo"])
    with zipfile.ZipFile(epub) as z:
        for n, data in enumerate(raw, 1):
            body = body_of(z.read(f"OEBPS/text/{n:02d}.xhtml"))
            assert body[0].text == book["capitoli"][n - 1]["titolo"]  # primo paragrafo = titolo
            expected = [" ".join(s["t"] for s in par) for par in data["paragrafi"]]
            assert [p.text for p in body] == expected


# --------------------------------------------------------------------------- CLI con --epub


@pytest.fixture
def fake_synthesis(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    """Niente Piper né ffmpeg: frasi da 1 s, audio finto, copertina finta."""

    def synth(model: Path, jobs: list[ChapterJob], workers: int = 1, on_done: object = None):
        out = {}
        for j in jobs:
            j.m4a.write_bytes(b"audio finto")
            out[j.n] = timed(*plan_sentences(j.paragraphs))
        return out

    voice = tmp_path / "it_IT-paola-medium.onnx"
    monkeypatch.setattr(cli, "resolve_voice", lambda v, d: voice)
    monkeypatch.setattr(cli, "synthesize_chapters", synth)
    monkeypatch.setattr(cli, "probe_duration", lambda p: 1e9)
    monkeypatch.setattr(cli, "prepare_cover", lambda image: b"\xff\xd8jpeg")


def source_epub(tmp_path: Path) -> Path:
    body = " ".join(["Una frase di prova, con l'apostrofo."] * 20)
    return make_epub(
        tmp_path / "l.epub",
        {
            "a.xhtml": xhtml(f"<h1>Uno</h1><p>{body}</p>"),
            "b.xhtml": xhtml(f"<h1>Due</h1><p>{body}</p><p>Fine.</p>"),
        },
        [("Uno", "a.xhtml"), ("Due", "b.xhtml")],
    )


def book_json(rabook: Path) -> dict:
    with zipfile.ZipFile(rabook) as z:
        return json.loads(z.read("book.json"))


@pytest.mark.usefixtures("fake_synthesis")
def test_cli_epub_writes_kindle_document_and_keeps_the_id(tmp_path: Path) -> None:
    src = source_epub(tmp_path)
    plain, withk, kindle = tmp_path / "a.rabook", tmp_path / "b.rabook", tmp_path / "k" / "l.epub"
    assert cli.main([str(src), "-o", str(plain)]) == 0
    assert cli.main([str(src), "-o", str(withk), "--epub", str(kindle)]) == 0
    a, b = book_json(plain), book_json(withk)

    assert "kindle" not in a
    assert b["id"] == a["id"]
    assert b["kindle"] == {"documento": partial_md5(kindle)}
    assert {k: v for k, v in b.items() if k != "kindle"} == a
    assert validate_rabook(withk) == []

    with zipfile.ZipFile(kindle) as z:
        opf = ET.fromstring(z.read("OEBPS/content.opf"))
        assert opf.findtext(f"{OPF}metadata/{DC}identifier") == a["id"]
        spine = [r.get("idref") for r in opf.iter(f"{OPF}itemref")]
        assert len(spine) == len(a["capitoli"])
        with zipfile.ZipFile(withk) as r:
            for n, ch in enumerate(a["capitoli"], 1):
                data = json.loads(r.read(ch["file"]))
                body = body_of(z.read(f"OEBPS/text/{n:02d}.xhtml"))
                assert all(k.tag == f"{XH}p" for k in body)
                assert [p.text for p in body] == [" ".join(s["t"] for s in p) for p in data["paragrafi"]]

    # stesso input, stesso EPUB e quindi stesso documento
    again = tmp_path / "again.epub"
    assert cli.main([str(src), "-o", str(tmp_path / "c.rabook"), "--epub", str(again)]) == 0
    assert again.read_bytes() == kindle.read_bytes()


def test_validate_rejects_a_bad_kindle_document(tmp_path: Path) -> None:
    from makebook.package import PackChapter, write_rabook

    audio = tmp_path / "a.m4a"
    audio.write_bytes(b"audio")
    pack = [PackChapter("Uno", timed(["Uno"], ["Testo."]), audio)]
    args = {"title": "L", "author": "A", "language": "it", "voice": "v", "chapters": pack, "cover_jpeg": b"j"}
    with pytest.raises(ValueError, match="MD5"):
        write_rabook(tmp_path / "x.rabook", kindle_document="ABC", **args)
    out = tmp_path / "ok.rabook"
    write_rabook(out, kindle_document="0" * 32, **args)
    assert validate_rabook(out) == []
