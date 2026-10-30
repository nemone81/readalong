from __future__ import annotations

from pathlib import Path

import pytest

from makebook.extract import (
    Block,
    chapter_from_blocks,
    clean_blocks,
    clean_text,
    fix_pdf_blocks,
    html_to_blocks,
    is_page_number,
    join_broken_lines,
    looks_like_path,
    parse_selection,
    read_epub,
    split_chapters,
    split_sentences,
    text_for_synthesis,
)

from .conftest import make_epub, xhtml

# --------------------------------------------------------------------------- pulizia


def test_clean_text_removes_soft_hyphens_note_marks_and_extra_spaces() -> None:
    assert clean_text("  bur\u00adat\u00adtino[12]  di\n legno ,  ") == "burattino di legno,"


@pytest.mark.parametrize("text", ["12", "- 12 -", "[12]", "Pag. 12", "— 7 —", "345"])
def test_page_numbers_are_recognised(text: str) -> None:
    assert is_page_number(text)


@pytest.mark.parametrize("text", ["12 maggio", "Capitolo 12", "I.", "1984 fu un anno"])
def test_text_with_numbers_is_not_a_page_number(text: str) -> None:
    assert not is_page_number(text)


@pytest.mark.parametrize(
    "text",
    [
        "/Users/fabio/Dropbox/libri/Il Cigno nero.pdf",
        "~/Documents/libro.pdf",
        "C:\\Users\\fabio\\libro.pdf",
        "file:///tmp/x.pdf",
        "Il_Cigno_nero_-_Taleb.pdf",
        "index_split_003.html",
    ],
)
def test_paths_and_file_names_are_recognised(text: str) -> None:
    assert looks_like_path(text)


@pytest.mark.parametrize("text", ["e/o", "Mangiò 1/2 pera.", "Pinocchio e Geppetto.", "Il 3.5% dei casi."])
def test_ordinary_text_is_not_a_path(text: str) -> None:
    assert not looks_like_path(text)


def test_clean_blocks_drops_page_numbers_paths_and_punctuation_only_lines() -> None:
    blocks = [Block("Testo vero."), Block("17"), Block("/Users/x/libro.pdf"), Block("* * *"), Block("  ")]
    assert clean_blocks(blocks) == [Block("Testo vero.")]


# --------------------------------------------------------------------------- HTML


def test_html_skips_title_with_calibre_pdf_path() -> None:
    blocks, _ = html_to_blocks(xhtml("<p>Inizio del capitolo.</p>", title="/Users/fabio/Dropbox/libro.pdf"))
    assert [b.text for b in blocks] == ["Inizio del capitolo."]


def test_html_skips_footnote_sup_page_spans_and_captions() -> None:
    html = xhtml(
        '<p>Una frase<sup><a href="#n1">1</a></sup> con nota.<span class="x-pageno" title="[5]">5</span></p>'
        '<div class="figcenter"><img src="a.jpg"/><p class="caption">Didascalia ripetuta.</p></div>'
        '<aside epub:type="footnote"><p>Testo della nota.</p></aside>'
        "<p>Seconda.</p>"
    )
    blocks = clean_blocks(html_to_blocks(html)[0])
    assert [b.text for b in blocks] == ["Una frase con nota.", "Seconda."]


def test_html_headings_are_marked_and_anchor_positions_recorded() -> None:
    html = xhtml('<p>Prima.</p><h2 id="cap2">II.<span> Il titolo</span></h2><p>Dopo.</p>')
    blocks, anchors = html_to_blocks(html)
    assert [(b.text.strip(), b.heading) for b in blocks] == [
        ("Prima.", False),
        ("II. Il titolo", True),
        ("Dopo.", False),
    ]
    assert anchors["cap2"] == 1


def test_html_collapses_source_line_breaks_inside_paragraph() -> None:
    blocks = clean_blocks(html_to_blocks(xhtml("<p>\nNon era un legno\ndi lusso.\n</p>"))[0])
    assert [b.text for b in blocks] == ["Non era un legno di lusso."]


# --------------------------------------------------------------------------- PDF


def test_join_broken_lines_rebuilds_paragraphs_and_dehyphenates() -> None:
    lines = [
        Block("Capitolo primo, un titolo lungo che non finisce con un punto fermo e va avanti"),
        Block("C'era una volta un pezzo di legno che stava nella bottega di un vec-"),
        Block("chio falegname, il quale aveva nome mastr'Antonio, se non che tutti"),
        Block("lo chiamavano maestro Ciliegia."),
        Block("Breve riga"),
        Block("Nuovo paragrafo."),
    ]
    out = [b.text for b in join_broken_lines(lines)]
    assert out[0].startswith("Capitolo primo")  # il titolo resta da solo anche se lungo e senza punto
    assert out[1] == (
        "C'era una volta un pezzo di legno che stava nella bottega di un vecchio falegname, "
        "il quale aveva nome mastr'Antonio, se non che tutti lo chiamavano maestro Ciliegia."
    )
    assert out[2:] == ["Breve riga", "Nuovo paragrafo."]


def test_fix_pdf_blocks_drops_running_heads_and_keeps_title_alone() -> None:
    head = Block("IL CIGNO NERO")  # testatina: in cima a ogni pagina

    def page(i: int) -> list[Block]:
        return [
            head,
            Block(f"Riga {i} di testo abbastanza lunga da non chiudere il paragrafo, e"),
            Block("fine."),
        ]

    blocks = [Block("Prologo"), *[b for i in range(5) for b in page(i)], Block("Capitolo uno"), *page(9)]
    fixed, starts = fix_pdf_blocks(blocks, [("Prologo", 0), ("Capitolo uno", 16)])
    texts = [b.text for b in fixed]
    assert "IL CIGNO NERO" not in texts
    assert texts[0] == "Prologo"
    assert texts[1] == "Riga 0 di testo abbastanza lunga da non chiudere il paragrafo, e fine."
    assert texts[starts[1][1]] == "Capitolo uno"
    assert texts[-1].startswith("Riga 9")


# --------------------------------------------------------------------------- capitoli


def test_chapter_title_is_first_paragraph_and_not_duplicated() -> None:
    ch = chapter_from_blocks("I. Il titolo", [Block("I. Il titolo", heading=True), Block("Testo.")])
    assert ch.paragraphs == ["I. Il titolo", "Testo."]


def test_chapter_title_is_added_when_missing_from_text() -> None:
    ch = chapter_from_blocks("Prologo", [Block("Il testo comincia subito.")])
    assert ch.paragraphs == ["Prologo", "Il testo comincia subito."]


def test_short_toc_entries_merge_into_next_chapter() -> None:
    words = " ".join(["parola"] * 50) + "."
    blocks = [Block("Parte prima"), Block("Capitolo 1"), Block(words), Block("Capitolo 2"), Block(words)]
    chapters = split_chapters(blocks, [("Parte prima", 0), ("Capitolo 1", 1), ("Capitolo 2", 3)])
    assert [c.title for c in chapters] == ["Capitolo 1", "Capitolo 2"]
    assert chapters[0].paragraphs[:2] == ["Parte prima", "Capitolo 1"]


def test_parse_selection() -> None:
    assert parse_selection("2,5-7", 10) == [2, 5, 6, 7]
    assert parse_selection("3, 3", 10) == [3]
    for bad in ("0", "11", "x", "5-2", ""):
        with pytest.raises(ValueError):
            parse_selection(bad, 10)


# --------------------------------------------------------------------------- frasi


@pytest.mark.parametrize(
    ("paragraph", "sentences"),
    [
        ("Uno. Due! Tre? Quattro…", ["Uno.", "Due!", "Tre?", "Quattro…"]),
        ("Disse: «Vieni qui.» Poi andò via.", ["Disse: «Vieni qui.»", "Poi andò via."]),
        (
            "— C'era una volta.... — Un re! — diranno subito i miei piccoli lettori.",
            ["— C'era una volta....", "— Un re! — diranno subito i miei piccoli lettori."],
        ),
        (
            "Il sig. Rossi arrivò alle 3.30 in punto. Era tardi.",
            ["Il sig. Rossi arrivò alle 3.30 in punto.", "Era tardi."],
        ),
        ("Lo scrisse C. Collodi nel 1881. Fine.", ["Lo scrisse C. Collodi nel 1881.", "Fine."]),
        ("Aspettò… e poi se ne andò.", ["Aspettò… e poi se ne andò."]),
        ("Titolo senza punto", ["Titolo senza punto"]),
        ("Ah! ... Oh!", ["Ah! ...", "Oh!"]),
        ("", []),
    ],
)
def test_split_sentences(paragraph: str, sentences: list[str]) -> None:
    assert split_sentences(paragraph) == sentences


def test_split_sentences_keeps_every_character() -> None:
    p = "— Chi è? — gridò. Nessuno rispose… Allora (pensò) era il vento! «Davvero?» Sì."
    assert " ".join(split_sentences(p)) == p


def test_ellipsis_becomes_period_only_for_synthesis() -> None:
    assert text_for_synthesis("Aspetta… dunque…") == "Aspetta. dunque."


# --------------------------------------------------------------------------- EPUB intero


def test_read_epub_follows_toc_and_cleans_text(tmp_path: Path) -> None:
    long_text = " ".join(["Pinocchio corre."] * 30)
    epub = make_epub(
        tmp_path / "libro.epub",
        {
            "front.xhtml": xhtml("<p>Frontespizio da saltare.</p>"),
            "c1.xhtml": xhtml(
                f'<h2 id="c1">I. Il primo</h2><p>{long_text}</p><p>12</p><p>Nota<sup>3</sup> finita.</p>',
                title="/Users/fabio/Dropbox/libri/pinocchio.pdf",
            ),
            "c2.xhtml": xhtml(f'<p>Coda del primo.</p><h2 id="c2">II. Il secondo</h2><p>{long_text}</p>'),
        },
        [("I. Il primo", "c1.xhtml#c1"), ("II. Il secondo", "c2.xhtml#c2")],
    )
    book = read_epub(epub)
    assert (book.title, book.author, book.language) == ("Libro", "Autrice Prova", "it")
    assert book.cover == b"\x89PNG finto"
    assert [c.title for c in book.chapters] == ["I. Il primo", "II. Il secondo"]
    first = book.chapters[0].paragraphs
    assert first[0] == "I. Il primo"
    assert first[-2:] == ["Nota finita.", "Coda del primo."]
    assert book.chapters[1].paragraphs[0] == "II. Il secondo"
    everything = " ".join(p for c in book.chapters for p in c.paragraphs)
    assert "/Users" not in everything and ".pdf" not in everything and "Frontespizio" not in everything
    assert " 12 " not in f" {everything} "
