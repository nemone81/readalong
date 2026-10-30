import Foundation
import Testing
@testable import ReadAlong

@Suite("Indice delle frasi")
struct SentenceIndexTests {
    /// Capitolo 1 della fixture: paragrafi [[0.0, 0.8], [1.6, 2.3]] (gli `s` delle frasi).
    private func chapterOne() throws -> SentenceIndex {
        let reader = try RABookReader(url: Fixture.url("mini"))
        return try reader.sentenceIndex(of: reader.book.chapters[0])
    }

    private func sentence(_ text: String, _ start: Double, _ end: Double) -> Sentence {
        Sentence(text: text, start: start, end: end)
    }

    // MARK: - Tempo → frase

    @Test("Frase al secondo: inizio, meta', confini, oltre la fine")
    func sentenceAtTime() throws {
        let index = try chapterOne()
        #expect(index.chapter == 1)
        #expect(index.count == 4)
        #expect(index.sentenceIndex(at: 0) == 0) // inizio
        #expect(index.sentenceIndex(at: 0.79) == 0)
        #expect(index.sentenceIndex(at: 0.8) == 1) // esattamente sull'inizio della seconda
        #expect(index.sentenceIndex(at: 1.55) == 1) // pausa tra paragrafi: resta la precedente
        #expect(index.sentenceIndex(at: 2.0) == 2) // meta' capitolo
        #expect(index.sentenceIndex(at: 2.3) == 3)
        #expect(index.sentenceIndex(at: 99) == 3) // oltre la fine → ultima
        #expect(index.sentenceIndex(at: -1) == 0) // prima dell'inizio → prima
        #expect(index.sentenceID(at: 2.0) == SentenceID(chapter: 1, index: 2))
        #expect(index.startTime(of: 2) == 1.6)
        #expect(index.startTime(of: 4) == nil)
    }

    @Test("Ricerca binaria coerente con la ricerca lineare su un capitolo lungo")
    func binarySearchMatchesLinear() {
        let sentences = (0..<1000).map { sentence("Frase \($0).", Double($0) * 1.5, Double($0) * 1.5 + 1.2) }
        let paragraphs = stride(from: 0, to: sentences.count, by: 7).map {
            Array(sentences[$0..<min($0 + 7, sentences.count)])
        }
        let index = SentenceIndex(chapter: 10, content: ChapterContent(duration: 1500, paragraphs: paragraphs))
        for time in stride(from: -2.0, through: 1510.0, by: 0.37) {
            let linear = sentences.lastIndex { $0.start <= time } ?? 0
            #expect(index.sentenceIndex(at: time) == linear)
        }
    }

    @Test("Capitolo vuoto: nessuna frase")
    func emptyChapter() {
        let index = SentenceIndex(chapter: 1, content: ChapterContent(duration: 0, paragraphs: [[], []]))
        #expect(index.isEmpty)
        #expect(index.text.isEmpty)
        #expect(index.sentenceIndex(at: 1) == nil)
        #expect(index.sentenceIndex(atCharacterOffset: 0) == nil)
    }

    // MARK: - Testo ↔ frase

    @Test("Testo concatenato: spazio tra frasi, riga vuota tra paragrafi")
    func concatenatedText() throws {
        let index = try chapterOne()
        #expect(index.text == """
            Il faro di Punta Lunga si accendeva ogni sera alle sette. \
            Lo custodiva Ernesta, che non aveva mai visto il mare in tempesta.

            Quella sera la lanterna tremò. Ernesta salì le scale con la candela in mano.
            """)
        #expect(index.paragraphOfSentence == [0, 0, 1, 1])
        let text = index.text as NSString
        for (position, sentence) in index.sentences.enumerated() {
            let range = try #require(index.characterRange(of: position))
            #expect(text.substring(with: range) == sentence.text)
        }
        #expect(index.characterRange(of: 4) == nil)
    }

    @Test("Offset carattere → frase, separatori e limiti compresi")
    func sentenceAtCharacterOffset() throws {
        let index = try chapterOne()
        let ranges = index.characterRanges
        #expect(index.sentenceIndex(atCharacterOffset: 0) == 0)
        #expect(index.sentenceIndex(atCharacterOffset: NSMaxRange(ranges[0]) - 1) == 0) // ultimo carattere
        #expect(index.sentenceIndex(atCharacterOffset: NSMaxRange(ranges[0])) == 0) // lo spazio dopo
        #expect(index.sentenceIndex(atCharacterOffset: ranges[1].location) == 1)
        #expect(index.sentenceIndex(atCharacterOffset: NSMaxRange(ranges[1]) + 1) == 1) // dentro "\n\n"
        #expect(index.sentenceIndex(atCharacterOffset: ranges[2].location + 5) == 2)
        #expect(index.sentenceIndex(atCharacterOffset: (index.text as NSString).length) == 3) // fine testo
        #expect(index.sentenceIndex(atCharacterOffset: 10_000) == 3)
        #expect(index.sentenceIndex(atCharacterOffset: -3) == 0)
        #expect(index.sentenceID(atCharacterOffset: ranges[3].location) == SentenceID(chapter: 1, index: 3))
    }

    @Test("Offset in unita' UTF-16, come NSString e UITextView")
    func utf16Offsets() throws {
        // L'emoji vale 2 unita' UTF-16: gli offset successivi devono tenerne conto.
        let content = ChapterContent(duration: 3, paragraphs: [
            [sentence("Ciao 👋 mondo.", 0, 1), sentence("Seconda.", 1, 2)],
            [sentence("Terza è qui.", 2, 3)],
        ])
        let index = SentenceIndex(chapter: 1, content: content)
        let text = index.text as NSString
        #expect(index.characterRanges[0] == NSRange(location: 0, length: 14))
        for (position, sentence) in index.sentences.enumerated() {
            let range = try #require(index.characterRange(of: position))
            #expect(text.substring(with: range) == sentence.text)
            #expect(index.sentenceIndex(atCharacterOffset: range.location) == position)
            #expect(index.sentenceIndex(atCharacterOffset: NSMaxRange(range) - 1) == position)
        }
    }

    @Test("SentenceID: lookup nel capitolo giusto e ordinamento")
    func sentenceIDs() throws {
        let index = try chapterOne()
        #expect(index.sentence(SentenceID(chapter: 1, index: 1))?.start == 0.8)
        #expect(index.sentence(SentenceID(chapter: 2, index: 1)) == nil)
        #expect(index.sentence(SentenceID(chapter: 1, index: 9)) == nil)
        #expect(SentenceID(chapter: 1, index: 9) < SentenceID(chapter: 2, index: 0))
        #expect(SentenceID(chapter: 2, index: 0) < SentenceID(chapter: 2, index: 1))
    }

    @Test("Progress: round-trip JSON e merge per updatedAt")
    func progressMerge() throws {
        let old = Progress(chapter: 1, sentence: 2, seconds: 1.7, updatedAt: Date(timeIntervalSince1970: 100))
        let new = Progress(chapter: 2, sentence: 0, seconds: 0.1, updatedAt: Date(timeIntervalSince1970: 200))
        #expect(old.merged(with: new) == new)
        #expect(new.merged(with: old) == new)
        let tie = Progress(chapter: 9, sentence: 9, seconds: 9, updatedAt: old.updatedAt)
        #expect(old.merged(with: tie) == old) // a parita' vince il locale
        #expect(new.sentenceID == SentenceID(chapter: 2, index: 0))
        let decoded = try JSONDecoder().decode(Progress.self, from: JSONEncoder().encode(old))
        #expect(decoded == old)
    }
}
