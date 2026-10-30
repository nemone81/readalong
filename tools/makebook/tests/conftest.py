"""Aiuti comuni: un EPUB minimo costruito al volo e il percorso della fixture."""

from __future__ import annotations

import zipfile
from pathlib import Path

import pytest

FIXTURES = Path(__file__).parent / "fixtures"
VOICE = Path(__file__).resolve().parents[1] / "voices" / "it_IT-paola-medium.onnx"

CONTAINER = """<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>"""


def make_epub(
    path: Path,
    docs: dict[str, str],
    toc: list[tuple[str, str]],
    *,
    title: str = "Libro",
    metadata: str = "",
) -> Path:
    """EPUB 2 minimo: ``docs`` nome → XHTML (in ordine di spine), ``toc`` (titolo, href).

    ``metadata`` è XML in più dentro ``<metadata>`` (es. le righe che vi scrive calibre).
    """
    items = "\n".join(
        f'<item id="d{i}" href="{name}" media-type="application/xhtml+xml"/>' for i, name in enumerate(docs)
    )
    spine = "\n".join(f'<itemref idref="d{i}"/>' for i in range(len(docs)))
    opf = f"""<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>{title}</dc:title><dc:creator>Autrice Prova</dc:creator><dc:language>it-IT</dc:language>
    <meta name="cover" content="cov"/>
    {metadata}
  </metadata>
  <manifest>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
    <item id="cov" href="cover.png" media-type="image/png"/>
    {items}
  </manifest>
  <spine toc="ncx">{spine}</spine>
</package>"""
    points = "\n".join(
        f'<navPoint id="n{i}"><navLabel><text>{t}</text></navLabel><content src="{href}"/></navPoint>'
        for i, (t, href) in enumerate(toc)
    )
    ncx = f"""<?xml version="1.0"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><navMap>{points}</navMap></ncx>"""
    with zipfile.ZipFile(path, "w") as z:
        z.writestr("mimetype", "application/epub+zip")
        z.writestr("META-INF/container.xml", CONTAINER)
        z.writestr("OEBPS/content.opf", opf)
        z.writestr("OEBPS/toc.ncx", ncx)
        z.writestr("OEBPS/cover.png", b"\x89PNG finto")
        for name, html in docs.items():
            z.writestr(f"OEBPS/{name}", html)
    return path


def xhtml(body: str, title: str = "", head: str = "") -> str:
    return (
        '<?xml version="1.0" encoding="utf-8"?><html xmlns="http://www.w3.org/1999/xhtml">'
        f"<head><title>{title}</title>{head}</head><body>{body}</body></html>"
    )


# Ciò che calibre scrive davvero quando converte un PDF (verificato su un EPUB di calibre 9.17):
# contributor "bkp" e meta calibre:* nell'OPF, path del PDF nel <title> e generator di pdftohtml.
CALIBRE_OPF_METADATA = (
    '<dc:contributor xmlns:opf="http://www.idpf.org/2007/opf" opf:role="bkp">'
    "calibre (9.17.0) [https://calibre-ebook.com]</dc:contributor>"
    '<meta name="calibre:timestamp" content="2026-10-29T20:19:42+00:00"/>'
)
PDF_PAGE_TITLE = "/Users/qualcuno/libri/Un libro.pdf"
PDF_PAGE_HEAD = '<meta content="PDF Reflow conversion" name="generator"/>'


def pytest_configure(config: pytest.Config) -> None:
    # registrato anche qui: lanciando pytest dalla radice del repo il pyproject non viene letto
    config.addinivalue_line("markers", "slow: sintesi reale con Piper (salta se la voce non c'è)")


@pytest.fixture
def fixture_rabook() -> Path:
    path = FIXTURES / "pinocchio.rabook"
    if not path.is_file():
        pytest.fail("manca tests/fixtures/pinocchio.rabook: rigenerala come da README")
    return path
