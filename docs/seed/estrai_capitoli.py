"""Estrae dall'EPUB il testo da leggere, diviso per capitoli secondo il toc.ncx.

Uso: python estrai_capitoli.py <cartella_epub_scompattato> <cartella_uscita>
Tiene da Prologo a Epilogo (incluso); le intestazioni di Parte confluiscono nel capitolo successivo.
"""
import html
import json
import re
import sys
import unicodedata
from html.parser import HTMLParser
from pathlib import Path

PRIMO, ULTIMO_ESCLUSO = "Prologo", "Ringraziamenti"


class Testo(HTMLParser):
    BLOCCHI = {"p", "div", "h1", "h2", "h3", "h4", "br", "li"}
    SALTA = {"title", "style", "script"}  # calibre mette il path del PDF sorgente nel <title> di ogni pagina

    def __init__(self):
        super().__init__()
        self.parti: list[str] = []
        self.in_sup = 0
        self.salta = 0

    def handle_starttag(self, tag, attrs):
        if tag in self.BLOCCHI:
            self.parti.append("\n")
        if tag == "sup":
            self.in_sup += 1
        if tag in self.SALTA:
            self.salta += 1

    def handle_endtag(self, tag):
        if tag in self.BLOCCHI:
            self.parti.append("\n")
        if tag == "sup" and self.in_sup:
            self.in_sup -= 1
        if tag in self.SALTA and self.salta:
            self.salta -= 1

    def handle_data(self, data):
        if not self.in_sup and not self.salta:
            self.parti.append(data)


def norm(s: str) -> str:
    s = unicodedata.normalize("NFKC", s).replace("’", "'").lower()
    s = re.sub(r"\[\d+\]", "", s)
    return re.sub(r"\s+", " ", s).strip()


def pulisci(t: str) -> str:
    t = t.replace("­", "")
    t = re.sub(r"\[\d+\]", "", t)
    righe = [r.strip() for r in t.split("\n")]
    righe = [r for r in righe if r and not re.fullmatch(r"\d{1,3}", r)]
    paragrafi, buf = [], []
    for i, r in enumerate(righe):
        buf.append(r)
        # la prima riga è il titolo del capitolo: sta da sola anche se lunga e senza punto
        if i == 0 or re.search(r"[.!?…:»”\"]$", r) or len(r) < 60:
            paragrafi.append(" ".join(buf))
            buf = []
    if buf:
        paragrafi.append(" ".join(buf))
    t = "\n\n".join(paragrafi)
    t = re.sub(r"(\w)- (\w)", r"\1\2", t)
    return re.sub(r"[ \t]+", " ", t)


def main() -> None:
    src, out = Path(sys.argv[1]), Path(sys.argv[2])
    out.mkdir(parents=True, exist_ok=True)
    ncx = (src / "toc.ncx").read_text(encoding="utf-8")
    titoli = [html.unescape(t).strip() for t in re.findall(r"<text>([^<]*)</text>", ncx)][1:]
    titoli = titoli[titoli.index(PRIMO): titoli.index(ULTIMO_ESCLUSO)]

    file_html = sorted(src.glob("index_split_*.html"))
    p = Testo()
    for f in file_html:
        p.feed(f.read_text(encoding="utf-8", errors="replace"))
    testo = "".join(p.parti)

    # Trova l'inizio di ogni titolo cercando riga per riga, in ordine.
    righe = testo.split("\n")
    offs, pos = [], 0
    for r in righe:
        offs.append(pos)
        pos += len(r) + 1
    inizi, i = [], 0
    for t in titoli:
        bersaglio = norm(t)
        trovato = None
        for j in range(i, len(righe)):
            if norm(righe[j]) and norm(righe[j]).startswith(bersaglio[: max(12, min(len(bersaglio), 40))]):
                trovato = j
                break
        if trovato is None:
            sys.exit(f"titolo non trovato: {t}")
        inizi.append(offs[trovato])
        i = trovato + 1
    fine = testo.find("\nRingraziamenti", inizi[-1])
    inizi.append(fine if fine > 0 else len(testo))

    capitoli, sospese = [], ""
    for k, t in enumerate(titoli):
        pezzo = testo[inizi[k]: inizi[k + 1]]
        corpo = pulisci(pezzo)
        if len(corpo.split()) < 40:  # intestazione di Parte o sottotitolo: va col capitolo dopo
            sospese += corpo + ".\n\n"
            continue
        capitoli.append({"titolo": t, "testo": sospese + corpo})
        sospese = ""

    indice = []
    for n, c in enumerate(capitoli, 1):
        nome = f"{n:02d}.txt"
        (out / nome).write_text(c["testo"], encoding="utf-8")
        indice.append({"file": nome, "titolo": re.sub(r"\[\d+\]", "", c["titolo"]), "parole": len(c["testo"].split())})
    (out / "indice.json").write_text(json.dumps(indice, ensure_ascii=False, indent=1), encoding="utf-8")
    for c in indice:
        print(c["file"], c["parole"], c["titolo"])


if __name__ == "__main__":
    main()
