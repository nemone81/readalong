import Foundation
import Testing
@testable import ReadAlong

/// XPointer di crengine (T18): parsing tollerante, forma testuale, traduzione
/// verso la frase e ritorno, offset in scalari Unicode.
@Suite("XPointer")
struct XPointerTests {
    private let book = KindleFixture.book()
    private let chapter2 = KindleFixture.chapter2

    private func index(_ string: String) throws -> Int? {
        try #require(XPointer.parse(string)).sentenceIndex(in: chapter2)
    }

    // MARK: - Parsing e forma

    @Test("La forma canonica si legge e si riscrive identica")
    func canonicalRoundTrip() throws {
        let string = "/body/DocFragment[2]/body/p[3]/text().12"
        let pointer = try #require(XPointer.parse(string))
        #expect(pointer == XPointer(fragment: 2, paragraph: 3, offset: 12))
        #expect(pointer.string == string)
    }

    @Test("Forma senza offset e senza paragrafo")
    func partialForms() {
        #expect(XPointer(fragment: 4, paragraph: 2).string == "/body/DocFragment[4]/body/p[2]")
        #expect(XPointer(fragment: 4).string == "/body/DocFragment[4]/body")
        #expect(XPointer.parse("/body/DocFragment[4]/body/p[2]") == XPointer(fragment: 4, paragraph: 2))
        #expect(XPointer.parse("/body/DocFragment[4]/body") == XPointer(fragment: 4))
    }

    @Test("Varianti tollerate", arguments: [
        ("/body/DocFragment[2]/body/p[3]/text()[1].12", XPointer(fragment: 2, paragraph: 3, offset: 12)),
        ("/body/DocFragment[2]/body/p[3]/text()[2].12", XPointer(fragment: 2, paragraph: 3)),
        ("/body/DocFragment[2]/body/p[3]/text()", XPointer(fragment: 2, paragraph: 3, offset: 0)),
        ("/body/DocFragment[2]/body/h2/text().4", XPointer(fragment: 2)),
        ("/body/DocFragment[2]/body/h2", XPointer(fragment: 2)),
        ("/body/DocFragment[2]/body/div/p[3]/text().5", XPointer(fragment: 2, paragraph: 3, offset: 5)),
        ("/body/DocFragment[2]/body/p[3]/span/text().5", XPointer(fragment: 2, paragraph: 3)),
        ("/body/DocFragment[2]/body/p/text().5", XPointer(fragment: 2, paragraph: 1, offset: 5)),
        ("  /body/DocFragment[2]/body/p[3]/text().5\n", XPointer(fragment: 2, paragraph: 3, offset: 5)),
        ("/body/DocFragment[2]/body/text().3", XPointer(fragment: 2)),
    ])
    func tolerantVariants(string: String, expected: XPointer) {
        #expect(XPointer.parse(string) == expected)
    }

    @Test("Non e' un XPointer di un EPUB", arguments: ["", "abc", "#_doc_fragment_3", "/body/p[2]/text().1", "/body/DocFragment[0]/body"])
    func rejectsGarbage(string: String) {
        #expect(XPointer.parse(string) == nil)
    }

    // MARK: - XPointer -> frase

    @Test("Offset dentro le frasi, sullo spazio e oltre la fine del paragrafo")
    func offsets() throws {
        // «L’albero era là.» = 16 scalari (apostrofo tipografico e «à» contano uno).
        #expect(try index("/body/DocFragment[2]/body/p[1]/text().0") == 0)
        #expect(try index("/body/DocFragment[2]/body/p[1]/text().15") == 0)
        #expect(try index("/body/DocFragment[2]/body/p[1]/text().16") == 0) // lo spazio va alla frase prima
        #expect(try index("/body/DocFragment[2]/body/p[1]/text().17") == 1)
        #expect(try index("/body/DocFragment[2]/body/p[1]/text().999") == 1)
        #expect(try index("/body/DocFragment[2]/body/p[3]/text().12") == 3)
    }

    @Test("Offset in scalari Unicode, non in grafemi: accenti combinanti")
    func unicodeScalars() throws {
        // «Perche´ si`.» decomposto: 10 grafemi, 12 scalari. «Ok.» parte dallo scalare 13.
        #expect(KindleFixture.decomposed.count == 10)
        #expect(XPointer.length(KindleFixture.decomposed) == 12)
        #expect(try index("/body/DocFragment[2]/body/p[4]/text().11") == 4) // in grafemi sarebbe gia' «Ok.»
        #expect(try index("/body/DocFragment[2]/body/p[4]/text().13") == 5)
    }

    @Test("Paragrafo vuoto, oltre l'ultimo, assente; titolo; text()[k]")
    func paragraphFallbacks() throws {
        #expect(try index("/body/DocFragment[2]/body/p[2]/text().0") == 2) // vuoto: la frase che segue
        #expect(try index("/body/DocFragment[2]/body/p[9]/text().0") == 5) // oltre: l'ultima del capitolo
        #expect(try index("/body/DocFragment[2]/body/h2/text().3") == 0)
        #expect(try index("/body/DocFragment[2]/body") == 0)
        #expect(try index("/body/DocFragment[2]/body/p[3]/text()[2].7") == 2) // inizio del paragrafo
        #expect(try index("/body/DocFragment[2]/body/p[3]") == 2)
    }

    @Test("Capitolo senza frasi: nessuna frase")
    func emptyChapter() {
        let empty = ChapterContent(duration: 0, paragraphs: [[]])
        #expect(XPointer(fragment: 1, paragraph: 1, offset: 0).sentenceIndex(in: empty) == nil)
    }

    @Test("Nel libro: DocFragment[N] e' il capitolo N dello spine, letto a richiesta")
    func inBook() throws {
        var requested: [Int] = []
        let sentence = try #require(XPointer.parse("/body/DocFragment[2]/body/p[3]/text().12"))
            .sentence(in: book) { chapter in
                requested.append(chapter.number)
                return try KindleFixture.content(of: chapter)
            }
        #expect(sentence == SentenceID(chapter: 2, index: 3))
        #expect(requested == [2])
        #expect(XPointer(fragment: 3).sentence(in: book, contentOf: KindleFixture.content) == nil)
    }

    // MARK: - Frase -> XPointer

    @Test("Ogni frase: XPointer all'inizio, e ritorno alla stessa frase")
    func sentenceRoundTrip() throws {
        let expected = [
            "/body/DocFragment[2]/body/p[1]/text().0",
            "/body/DocFragment[2]/body/p[1]/text().17",
            "/body/DocFragment[2]/body/p[3]/text().0",
            "/body/DocFragment[2]/body/p[3]/text().12",
            "/body/DocFragment[2]/body/p[4]/text().0",
            "/body/DocFragment[2]/body/p[4]/text().13",
        ]
        for (index, string) in expected.enumerated() {
            let pointer = try #require(XPointer.pointer(for: SentenceID(chapter: 2, index: index), in: book, content: chapter2))
            #expect(pointer.string == string)
            #expect(XPointer.parse(pointer.string)?.sentenceIndex(in: chapter2) == index)
        }
        let first = try #require(XPointer.pointer(for: SentenceID(chapter: 1, index: 0), in: book, content: KindleFixture.chapter1))
        #expect(first.string == "/body/DocFragment[1]/body/p[1]/text().0")
    }

    @Test("Frase o capitolo inesistenti: nessun XPointer")
    func missingSentence() {
        #expect(XPointer.pointer(for: SentenceID(chapter: 2, index: 6), in: book, content: chapter2) == nil)
        #expect(XPointer.pointer(for: SentenceID(chapter: 7, index: 0), in: book, content: chapter2) == nil)
    }
}
