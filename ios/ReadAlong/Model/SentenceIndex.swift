import Foundation

/// Indice di un capitolo per passare da frase a tempo audio e a posizione nel
/// testo, e ritorno.
///
/// Il testo del capitolo (`text`) e' la concatenazione delle frasi: frasi dello
/// stesso paragrafo separate da uno spazio, paragrafi separati da `"\n\n"`.
/// Gli offset e i range sono in unita' UTF-16 (`NSRange`), cioe' quelli di
/// `NSString`/`NSAttributedString`/`UITextView`.
///
/// Si costruisce una volta per capitolo; le ricerche sono binarie (O(log n)).
struct SentenceIndex: Sendable, Equatable {
    static let sentenceSeparator = " "
    static let paragraphSeparator = "\n\n"

    /// Numero del capitolo (`Chapter.number`).
    let chapter: Int
    /// Frasi in ordine; l'indice nell'array e' `SentenceID.index`.
    let sentences: [Sentence]
    /// Testo concatenato del capitolo.
    let text: String
    /// Range di ciascuna frase in `text`, in unita' UTF-16, stesso ordine di `sentences`.
    let characterRanges: [NSRange]
    /// Per ogni frase, l'indice del paragrafo (in `ChapterContent.paragraphs`) che la contiene.
    let paragraphOfSentence: [Int]

    init(chapter: Int, content: ChapterContent) {
        var sentences: [Sentence] = []
        var ranges: [NSRange] = []
        var paragraphOf: [Int] = []
        var text = ""
        var length = 0 // lunghezza UTF-16 di `text`, tenuta a mano per non ricalcolarla

        for (paragraphIndex, paragraph) in content.paragraphs.enumerated() where !paragraph.isEmpty {
            if !sentences.isEmpty {
                text += Self.paragraphSeparator
                length += Self.paragraphSeparator.utf16.count
            }
            for (position, sentence) in paragraph.enumerated() {
                if position > 0 {
                    text += Self.sentenceSeparator
                    length += Self.sentenceSeparator.utf16.count
                }
                let sentenceLength = sentence.text.utf16.count
                ranges.append(NSRange(location: length, length: sentenceLength))
                text += sentence.text
                length += sentenceLength
                sentences.append(sentence)
                paragraphOf.append(paragraphIndex)
            }
        }

        self.chapter = chapter
        self.sentences = sentences
        self.text = text
        self.characterRanges = ranges
        self.paragraphOfSentence = paragraphOf
    }

    var count: Int { sentences.count }
    var isEmpty: Bool { sentences.isEmpty }

    /// L'identificativo della frase `index` di questo capitolo.
    func id(of index: Int) -> SentenceID {
        SentenceID(chapter: chapter, index: index)
    }

    /// La frase identificata da `id`, se appartiene a questo capitolo.
    func sentence(_ id: SentenceID) -> Sentence? {
        guard id.chapter == chapter, sentences.indices.contains(id.index) else { return nil }
        return sentences[id.index]
    }

    // MARK: - Tempo

    /// Indice della frase in corso al secondo `time`: l'ultima con `start <= time`.
    /// Prima della prima frase restituisce 0, oltre la fine l'ultima.
    /// `nil` solo se il capitolo non ha frasi.
    func sentenceIndex(at time: Double) -> Int? {
        guard !sentences.isEmpty else { return nil }
        // Primo indice con start > time, poi uno indietro.
        var low = 0
        var high = sentences.count
        while low < high {
            let mid = (low + high) / 2
            if sentences[mid].start <= time {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return max(low - 1, 0)
    }

    /// Come `sentenceIndex(at:)`, ma restituisce l'identificativo completo.
    func sentenceID(at time: Double) -> SentenceID? {
        sentenceIndex(at: time).map(id(of:))
    }

    /// Secondo di inizio della frase `index`, se esiste.
    func startTime(of index: Int) -> Double? {
        sentences.indices.contains(index) ? sentences[index].start : nil
    }

    // MARK: - Testo

    /// Range UTF-16 della frase `index` in `text`, se esiste.
    func characterRange(of index: Int) -> NSRange? {
        characterRanges.indices.contains(index) ? characterRanges[index] : nil
    }

    /// Indice della frase che contiene l'offset UTF-16 `offset` di `text`.
    /// Un offset su un separatore appartiene alla frase che lo precede; gli
    /// offset fuori dal testo vanno alla prima o all'ultima frase.
    /// `nil` solo se il capitolo non ha frasi.
    func sentenceIndex(atCharacterOffset offset: Int) -> Int? {
        guard !characterRanges.isEmpty else { return nil }
        var low = 0
        var high = characterRanges.count
        while low < high {
            let mid = (low + high) / 2
            if characterRanges[mid].location <= offset {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return max(low - 1, 0)
    }

    /// Come `sentenceIndex(atCharacterOffset:)`, ma restituisce l'identificativo completo.
    func sentenceID(atCharacterOffset offset: Int) -> SentenceID? {
        sentenceIndex(atCharacterOffset: offset).map(id(of:))
    }
}
