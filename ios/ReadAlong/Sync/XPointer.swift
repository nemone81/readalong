import Foundation

/// Una posizione di KOReader in un EPUB: l'XPointer di crengine che KOSync
/// trasporta nel campo `progress` (T18, SPEC «Kindle via KOReader e KOSync»).
///
/// La forma che conta e' `/body/DocFragment[N]/body/p[M]/text().C`:
/// - `N` = capitolo, 1-based, nell'ordine dello spine (l'EPUB di
///   `makebook --epub` ha nello spine solo i capitoli, nello stesso ordine di
///   `book.json`, quindi `N` e' la posizione in `Book.chapters` piu' uno);
/// - `M` = paragrafo, 1-based, tra i `<p>` del `body` del capitolo; l'`<h2>`
///   del titolo non e' un `p` e non conta. Corrisponde a
///   `ChapterContent.paragraphs[M - 1]`, contando anche gli eventuali
///   paragrafi vuoti (un `<p></p>` e' comunque un elemento del DOM);
/// - `C` = offset nel testo del paragrafo, cioe' nelle frasi del paragrafo
///   unite da uno spazio (identico al `<p>` dell'EPUB).
///
/// **Unita' di `C`: scalari Unicode** (`String.unicodeScalars`). crengine
/// tiene il testo in `lString32` (un `lChar32` per code point, UTF-8 gia'
/// decodificato) e conta l'offset li': ne' byte UTF-8 ne' unita' UTF-16 ne'
/// grafemi (`String.count`). Per l'italiano coincidono quasi sempre: la
/// differenza c'e' solo con caratteri composti (lettera + accento combinante)
/// o emoji, ed e' proprio li' che contare grafemi sbaglierebbe.
///
/// Il parsing e' tollerante (`parse(_:)`): ogni variante che non indica un
/// punto preciso (`/h2`, `text()[k]` con k > 1, `/body` senza `p`, un
/// elemento dentro il `p`) torna all'inizio del paragrafo o del capitolo.
struct XPointer: Sendable, Equatable {
    /// Capitolo nello spine, da 1 (`DocFragment[N]`).
    var fragment: Int
    /// Paragrafo nel capitolo, da 1 (`p[M]`); `nil` = inizio del capitolo.
    var paragraph: Int?
    /// Offset in scalari Unicode nel testo del paragrafo; `nil` = inizio del
    /// paragrafo.
    var offset: Int?

    init(fragment: Int, paragraph: Int? = nil, offset: Int? = nil) {
        self.fragment = fragment
        self.paragraph = paragraph
        self.offset = offset
    }

    /// La forma testuale, quella che si manda a KOSync:
    /// `/body/DocFragment[N]/body/p[M]/text().C`; senza offset il nodo `p[M]`,
    /// senza paragrafo il `body` del capitolo.
    var string: String {
        var result = "/body/DocFragment[\(fragment)]/body"
        guard let paragraph else { return result }
        result += "/p[\(paragraph)]"
        guard let offset else { return result }
        return result + "/text().\(offset)"
    }

    /// Legge un XPointer di crengine; `nil` solo se manca `DocFragment[N]`
    /// (non e' un XPointer di un EPUB: si ripiega sulla percentuale).
    static func parse(_ string: String) -> XPointer? {
        let parts = string.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard let fragmentIndex = parts.firstIndex(where: { elementName($0) == "DocFragment" }) else { return nil }
        // Senza indice tra parentesi un passo XPath vale il primo elemento.
        let fragment = bracketIndex(parts[fragmentIndex]) ?? 1
        guard fragment >= 1 else { return nil }

        var pointer = XPointer(fragment: fragment)
        var index = parts.index(after: fragmentIndex)
        // Si scende fino al primo `p`; un titolo (`h1`…`h6`) vale l'inizio del capitolo.
        while index < parts.endIndex {
            let name = elementName(parts[index])
            if name == "p" { break }
            if name.count == 2, name.hasPrefix("h"), name.last?.isNumber == true { return pointer }
            if name.hasPrefix("text()") { return pointer }
            index = parts.index(after: index)
        }
        guard index < parts.endIndex else { return pointer }
        let paragraph = bracketIndex(parts[index]) ?? 1
        guard paragraph >= 1 else { return pointer }
        pointer.paragraph = paragraph

        // Solo `text()` subito dopo il `p` da' un offset nel paragrafo.
        let next = parts.index(after: index)
        guard next == parts.index(before: parts.endIndex) else { return pointer }
        pointer.offset = textOffset(parts[next])
        return pointer
    }

    // MARK: - Interni del parsing

    /// Il nome dell'elemento di un passo: `p[3]` → `p`, `text().12` → `text()`.
    private static func elementName(_ step: String) -> String {
        if step.hasPrefix("text()") { return "text()" }
        let end = step.firstIndex(where: { $0 == "[" || $0 == "." }) ?? step.endIndex
        return String(step[..<end])
    }

    /// L'indice tra parentesi quadre di un passo (`p[3]` → 3), `nil` se manca.
    private static func bracketIndex(_ step: String) -> Int? {
        guard let open = step.firstIndex(of: "["),
              let close = step[open...].firstIndex(of: "]")
        else { return nil }
        return Int(step[step.index(after: open)..<close])
    }

    /// L'offset di `text().C` o `text()[1].C`; `nil` per `text()[k]` con
    /// k > 1 (un nodo di testo dopo un elemento in linea: offset non
    /// riconducibile al paragrafo) o per un passo che non e' `text()`.
    private static func textOffset(_ step: String) -> Int? {
        guard step.hasPrefix("text()") else { return nil }
        var rest = step.dropFirst("text()".count)
        if rest.hasPrefix("[") {
            guard let close = rest.firstIndex(of: "]"),
                  let k = Int(rest[rest.index(after: rest.startIndex)..<close]),
                  k == 1
            else { return nil }
            rest = rest[rest.index(after: close)...]
        }
        guard rest.hasPrefix(".") else { return 0 }
        guard let offset = Int(rest.dropFirst()), offset >= 0 else { return 0 }
        return offset
    }
}

// MARK: - Traduzione XPointer <-> frase

extension XPointer {
    /// Lunghezza di un testo nell'unita' di `offset`: scalari Unicode.
    static func length(_ text: String) -> Int {
        text.unicodeScalars.count
    }

    /// Il capitolo del libro a cui punta (`DocFragment[N]` = `chapters[N-1]`).
    func chapter(in book: Book) -> Chapter? {
        book.chapters.indices.contains(fragment - 1) ? book.chapters[fragment - 1] : nil
    }

    /// La frase a cui punta nel libro. `contentOf` legge il testo del
    /// capitolo richiesto (in app `RABookReader.content(of:)`: il capitolo
    /// puo' non essere quello aperto nel lettore). `nil` se il capitolo non
    /// esiste, non si legge o non ha frasi.
    func sentence(in book: Book, contentOf: (Chapter) throws -> ChapterContent) -> SentenceID? {
        guard let chapter = chapter(in: book),
              let content = try? contentOf(chapter),
              let index = sentenceIndex(in: content)
        else { return nil }
        return SentenceID(chapter: chapter.number, index: index)
    }

    /// L'indice (`SentenceID.index`) della frase a cui punta, nel capitolo
    /// `content` (si ignora `fragment`).
    /// - nessun paragrafo: prima frase del capitolo;
    /// - paragrafo oltre l'ultimo: ultima frase del capitolo;
    /// - paragrafo vuoto: prima frase del paragrafo successivo che ne ha;
    /// - nessun offset: prima frase del paragrafo;
    /// - offset: la frase il cui intervallo lo contiene (lo spazio dopo una
    ///   frase appartiene a lei); oltre la fine del paragrafo, l'ultima.
    /// `nil` solo se il capitolo non ha frasi.
    func sentenceIndex(in content: ChapterContent) -> Int? {
        let paragraphs = content.paragraphs
        let total = paragraphs.reduce(0) { $0 + $1.count }
        guard total > 0 else { return nil }
        guard let paragraph else { return 0 }
        guard paragraph <= paragraphs.count else { return total - 1 }

        var first = 0 // indice della prima frase del paragrafo
        for earlier in paragraphs[..<(paragraph - 1)] {
            first += earlier.count
        }
        let sentences = paragraphs[paragraph - 1]
        // Paragrafo vuoto: la frase che segue (o l'ultima, se e' in fondo).
        guard !sentences.isEmpty else { return min(first, total - 1) }
        guard let offset else { return first }

        var start = 0
        var found = 0
        for (position, sentence) in sentences.enumerated() {
            if start > offset { break }
            found = position
            start += Self.length(sentence.text) + Self.length(SentenceIndex.sentenceSeparator)
        }
        return first + found
    }

    /// L'XPointer dell'inizio della frase `sentence`: capitolo nello spine,
    /// paragrafo che la contiene, offset del suo primo carattere. `content`
    /// e' il testo del capitolo `sentence.chapter`. `nil` se il capitolo non
    /// e' nel libro o la frase non c'e'.
    static func pointer(for sentence: SentenceID, in book: Book, content: ChapterContent) -> XPointer? {
        guard let position = book.chapters.firstIndex(where: { $0.number == sentence.chapter }),
              sentence.index >= 0
        else { return nil }
        var first = 0
        for (paragraphIndex, paragraph) in content.paragraphs.enumerated() {
            if sentence.index < first + paragraph.count {
                let offset = paragraph[..<(sentence.index - first)].reduce(0) {
                    $0 + length($1.text) + length(SentenceIndex.sentenceSeparator)
                }
                return XPointer(fragment: position + 1, paragraph: paragraphIndex + 1, offset: offset)
            }
            first += paragraph.count
        }
        return nil
    }
}
