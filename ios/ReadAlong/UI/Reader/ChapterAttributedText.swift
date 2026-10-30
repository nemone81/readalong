import UIKit

/// Il testo di un capitolo come `NSTextStorage` stilizzato, con l'evidenziazione
/// della frase corrente.
///
/// Il testo e gli attributi di base si costruiscono una volta per capitolo
/// (e di nuovo solo se cambiano carattere o tema). Cambiare frase tocca
/// soltanto gli attributi del range vecchio e di quello nuovo, dentro un'unica
/// `beginEditing/endEditing`: il layout manager invalida solo quei range, cosi'
/// l'aggiornamento a 10 Hz resta sotto i 4 ms anche su capitoli da 10k parole
/// (rischio "evidenziazione lenta" del piano).
///
/// L'evidenziazione e' uno sfondo piu' un grassetto leggero ottenuto con il
/// contorno del glifo (`strokeWidth` negativo = riempimento + contorno): a
/// differenza di un font piu' pesante non cambia la larghezza dei glifi, quindi
/// le righe non vanno a capo in modo diverso e il testo non "salta".
@MainActor
final class ChapterAttributedText {
    /// Spessore del contorno, in percentuale della dimensione del carattere.
    /// Negativo: il glifo resta pieno e si ispessisce.
    static let highlightStrokeWidth: CGFloat = -1.5

    let content: SentenceIndex
    let textStorage: NSTextStorage
    private(set) var fontSize: CGFloat
    private(set) var theme: ReadingTheme
    /// La frase evidenziata ora, se c'e'.
    private(set) var highlightedSentence: Int?

    /// Costruisce il testo del capitolo in `textStorage`, sostituendone il
    /// contenuto. Passare il `textStorage` di una `UITextView` (TextKit 1)
    /// per mostrare il capitolo in quella vista.
    init(
        content: SentenceIndex,
        fontSize: CGFloat,
        theme: ReadingTheme,
        textStorage: NSTextStorage = NSTextStorage()
    ) {
        self.content = content
        self.textStorage = textStorage
        self.fontSize = fontSize
        self.theme = theme
        textStorage.beginEditing()
        textStorage.setAttributedString(NSAttributedString(
            string: content.text,
            attributes: Self.baseAttributes(fontSize: fontSize, theme: theme)
        ))
        textStorage.endEditing()
    }

    // MARK: - Evidenziazione

    /// Evidenzia la frase `sentence` (o nessuna con `nil`), togliendo
    /// l'evidenziazione precedente. Indici fuori dal capitolo valgono `nil`.
    /// Restituisce `true` se l'evidenziazione e' cambiata.
    @discardableResult
    func highlight(sentence: Int?) -> Bool {
        let target = sentence.flatMap { content.characterRange(of: $0) == nil ? nil : $0 }
        guard target != highlightedSentence else { return false }

        textStorage.beginEditing()
        if let old = highlightedSentence, let range = content.characterRange(of: old) {
            for key in Self.highlightKeys {
                textStorage.removeAttribute(key, range: range)
            }
        }
        if let new = target, let range = content.characterRange(of: new) {
            textStorage.addAttributes(Self.highlightAttributes(theme: theme), range: range)
        }
        textStorage.endEditing()

        highlightedSentence = target
        return true
    }

    // MARK: - Stile

    /// Cambia carattere e/o tema: riapplica gli attributi a tutto il capitolo
    /// (O(n), solo quando l'utente cambia le impostazioni) e conserva
    /// l'evidenziazione. Restituisce `true` se qualcosa e' cambiato.
    @discardableResult
    func setStyle(fontSize: CGFloat, theme: ReadingTheme) -> Bool {
        guard fontSize != self.fontSize || theme != self.theme else { return false }
        self.fontSize = fontSize
        self.theme = theme

        let fullRange = NSRange(location: 0, length: textStorage.length)
        textStorage.beginEditing()
        textStorage.setAttributes(Self.baseAttributes(fontSize: fontSize, theme: theme), range: fullRange)
        if let current = highlightedSentence, let range = content.characterRange(of: current) {
            textStorage.addAttributes(Self.highlightAttributes(theme: theme), range: range)
        }
        textStorage.endEditing()
        return true
    }

    // MARK: - Attributi

    /// Attributi che l'evidenziazione aggiunge e poi toglie.
    static let highlightKeys: [NSAttributedString.Key] = [.backgroundColor, .strokeWidth, .strokeColor]

    static func highlightAttributes(theme: ReadingTheme) -> [NSAttributedString.Key: Any] {
        [
            .backgroundColor: theme.highlightColor,
            .strokeWidth: highlightStrokeWidth,
            .strokeColor: theme.textColor,
        ]
    }

    /// Attributi di tutto il testo: carattere da lettura, colore del tema,
    /// interlinea ariosa e un po' d'aria tra i paragrafi (che nel testo sono
    /// gia' separati da una riga vuota, `"\n\n"`).
    static func baseAttributes(fontSize: CGFloat, theme: ReadingTheme) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.3
        paragraph.paragraphSpacing = fontSize * 0.2
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.hyphenationFactor = 0.2
        return [
            .font: readingFont(size: fontSize),
            .foregroundColor: theme.textColor,
            .paragraphStyle: paragraph,
        ]
    }

    /// Serif di sistema (New York) se disponibile, altrimenti il carattere di sistema.
    static func readingFont(size: CGFloat) -> UIFont {
        let system = UIFont.systemFont(ofSize: size)
        guard let serif = system.fontDescriptor.withDesign(.serif) else { return system }
        return UIFont(descriptor: serif, size: size)
    }
}
