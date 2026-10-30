import SwiftUI
import UIKit

/// Il testo di un capitolo con la frase in lettura evidenziata.
///
/// `UITextView` non editabile e non selezionabile, in **TextKit 1**: serve il
/// `NSLayoutManager` per passare da punto a carattere (tap, prima frase
/// visibile) e da range a rettangolo (autoscroll) con API sincrone e stabili, e
/// per modificare gli attributi del solo range della frase via `NSTextStorage`
/// con invalidazione incrementale. Il layout non contiguo tiene leggeri i
/// capitoli lunghi. TextKit 2 (default da iOS 16) qui non darebbe vantaggi e
/// accedere a `layoutManager` lo farebbe comunque ricadere su TextKit 1.
///
/// Comportamento:
/// - tap su una frase → `onTapSentence(indice)`; pressione lunga →
///   `onLongPressSentence(indice)`;
/// - quando cambia `currentSentence`, se la frase non e' interamente visibile la
///   porta nel terzo alto dello schermo, con animazione; mai mentre l'utente
///   scorre o nei 5 s successivi;
/// - riporta la prima frase visibile (`onFirstVisibleSentenceChange`) con un
///   debounce di 200 ms, solo quando cambia.
struct SentenceTextView: UIViewRepresentable {
    let content: SentenceIndex
    let currentSentence: Int?
    var fontSize: CGFloat = 19
    var theme: ReadingTheme = .light
    var onTapSentence: @MainActor (Int) -> Void = { _ in }
    var onLongPressSentence: @MainActor (Int) -> Void = { _ in }
    var onFirstVisibleSentenceChange: @MainActor (Int) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> ReaderTextView {
        let textView = ReaderTextView(usingTextLayoutManager: false)
        let coordinator = context.coordinator
        textView.delegate = coordinator
        textView.isEditable = false
        textView.isSelectable = false
        textView.alwaysBounceVertical = true
        textView.textContainer.lineFragmentPadding = 0
        textView.layoutManager.allowsNonContiguousLayout = true
        textView.adjustsFontForContentSizeCategory = false
        textView.onLayout = { [weak coordinator] in coordinator?.textViewDidLayout() }

        let tap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleTap(_:)))
        let longPress = UILongPressGestureRecognizer(
            target: coordinator,
            action: #selector(Coordinator.handleLongPress(_:))
        )
        tap.require(toFail: longPress)
        textView.addGestureRecognizer(tap)
        textView.addGestureRecognizer(longPress)

        coordinator.textView = textView
        return textView
    }

    func updateUIView(_ textView: ReaderTextView, context: Context) {
        context.coordinator.update(with: self)
    }

    static func dismantleUIView(_ textView: ReaderTextView, coordinator: Coordinator) {
        coordinator.cancelPendingReport()
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        weak var textView: ReaderTextView?
        private(set) var chapterText: ChapterAttributedText?
        private var parent: SentenceTextView?
        private var gate = AutoscrollGate()
        /// Scroll da fare appena la vista ha una dimensione (primo caricamento).
        private var pendingInitialScroll = false
        private var lastReportedFirstVisible: Int?
        private var reportTask: Task<Void, Never>?

        func update(with view: SentenceTextView) {
            parent = view
            guard let textView else { return }
            textView.backgroundColor = view.theme.backgroundColor
            textView.indicatorStyle = view.theme.scrollIndicatorStyle

            if let chapterText, chapterText.content == view.content {
                chapterText.setStyle(fontSize: view.fontSize, theme: view.theme)
                if chapterText.highlight(sentence: view.currentSentence) {
                    scrollToCurrentSentenceIfAllowed(animated: true)
                }
            } else {
                // Capitolo nuovo: testo ricostruito, si riparte dall'alto o dalla frase corrente.
                let chapterText = ChapterAttributedText(
                    content: view.content,
                    fontSize: view.fontSize,
                    theme: view.theme,
                    textStorage: textView.textStorage
                )
                chapterText.highlight(sentence: view.currentSentence)
                self.chapterText = chapterText
                gate = AutoscrollGate()
                lastReportedFirstVisible = nil
                textView.setContentOffset(CGPoint(x: 0, y: -textView.adjustedContentInset.top), animated: false)
                pendingInitialScroll = true
                textViewDidLayout()
            }
        }

        /// Chiamata a ogni `layoutSubviews`: adatta i margini alla larghezza e
        /// completa lo scroll iniziale quando la vista ha una dimensione.
        func textViewDidLayout() {
            guard let textView, textView.bounds.height > 0 else { return }
            let inset = Self.containerInset(forWidth: textView.bounds.width)
            if textView.textContainerInset != inset {
                textView.textContainerInset = inset
            }
            if pendingInitialScroll {
                pendingInitialScroll = false
                scrollToCurrentSentenceIfAllowed(animated: false)
                scheduleFirstVisibleReport()
            }
        }

        // MARK: Autoscroll

        private func scrollToCurrentSentenceIfAllowed(animated: Bool) {
            guard
                let textView, textView.bounds.height > 0,
                let chapterText, let current = chapterText.highlightedSentence,
                let range = chapterText.content.characterRange(of: current),
                gate.allowsAutoscroll(now: .now)
            else { return }
            let rect = Self.rect(ofCharacterRange: range, in: textView)
            if let target = Self.autoscrollTarget(for: rect, in: textView) {
                textView.setContentOffset(target, animated: animated)
            }
        }

        // MARK: Scroll dell'utente

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            gate.userDidBeginScrolling()
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate {
                gate.userDidEndScrolling(at: .now)
            }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            gate.userDidEndScrolling(at: .now)
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            scheduleFirstVisibleReport()
        }

        // MARK: Prima frase visibile

        private func scheduleFirstVisibleReport() {
            reportTask?.cancel()
            reportTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                self?.reportFirstVisibleSentence()
            }
        }

        func cancelPendingReport() {
            reportTask?.cancel()
            reportTask = nil
        }

        private func reportFirstVisibleSentence() {
            guard let textView, let chapterText, textView.bounds.height > 0 else { return }
            let top = CGPoint(
                x: textView.textContainerInset.left,
                y: textView.contentOffset.y + textView.adjustedContentInset.top
            )
            guard
                let offset = Self.characterIndex(at: top, in: textView),
                let sentence = chapterText.content.sentenceIndex(atCharacterOffset: offset),
                sentence != lastReportedFirstVisible
            else { return }
            lastReportedFirstVisible = sentence
            parent?.onFirstVisibleSentenceChange(sentence)
        }

        // MARK: Gesti

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let sentence = sentence(at: recognizer) else { return }
            parent?.onTapSentence(sentence)
        }

        @objc func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began, let sentence = sentence(at: recognizer) else { return }
            parent?.onLongPressSentence(sentence)
        }

        private func sentence(at recognizer: UIGestureRecognizer) -> Int? {
            guard let textView, let chapterText else { return nil }
            let point = recognizer.location(in: textView)
            return Self.characterIndex(at: point, in: textView)
                .flatMap { chapterText.content.sentenceIndex(atCharacterOffset: $0) }
        }

        // MARK: Geometria (statiche, testabili)

        /// Larghezza massima della colonna di testo: righe troppo lunghe si leggono male (iPad).
        static let maxColumnWidth: CGFloat = 680

        static func containerInset(forWidth width: CGFloat) -> UIEdgeInsets {
            let horizontal = max(20, (width - maxColumnWidth) / 2)
            return UIEdgeInsets(top: 24, left: horizontal, bottom: 48, right: horizontal)
        }

        /// Indice UTF-16 del carattere piu' vicino a `point` (coordinate della
        /// `textView`, cioe' del suo contenuto). `nil` se il testo e' vuoto.
        static func characterIndex(at point: CGPoint, in textView: UITextView) -> Int? {
            guard textView.textStorage.length > 0 else { return nil }
            let inContainer = CGPoint(
                x: point.x - textView.textContainerInset.left,
                y: point.y - textView.textContainerInset.top
            )
            let index = textView.layoutManager.characterIndex(
                for: inContainer,
                in: textView.textContainer,
                fractionOfDistanceBetweenInsertionPoints: nil
            )
            return min(index, max(textView.textStorage.length - 1, 0))
        }

        /// Rettangolo che contiene il range, in coordinate della `textView`.
        static func rect(ofCharacterRange range: NSRange, in textView: UITextView) -> CGRect {
            let layoutManager = textView.layoutManager
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textView.textContainer)
            return rect.offsetBy(dx: textView.textContainerInset.left, dy: textView.textContainerInset.top)
        }

        /// Dove scorrere per mostrare `rect`, o `nil` se e' gia' a posto: una frase
        /// interamente visibile non si muove; altrimenti il suo inizio va al
        /// 20% dell'altezza visibile (terzo alto). Una frase piu' alta dello
        /// schermo non si muove se il suo inizio e' gia' nel terzo alto.
        static func autoscrollTarget(for rect: CGRect, in scrollView: UIScrollView) -> CGPoint? {
            let insets = scrollView.adjustedContentInset
            let visibleTop = scrollView.contentOffset.y + insets.top
            let visibleHeight = scrollView.bounds.height - insets.top - insets.bottom
            guard visibleHeight > 0 else { return nil }
            let visibleBottom = visibleTop + visibleHeight

            let fullyVisible = rect.minY >= visibleTop && rect.maxY <= visibleBottom
            let tallButAnchored = rect.height > visibleHeight
                && rect.minY >= visibleTop && rect.minY <= visibleTop + visibleHeight / 3
            if fullyVisible || tallButAnchored { return nil }

            let minOffset = -insets.top
            let maxOffset = max(minOffset, scrollView.contentSize.height + insets.bottom - scrollView.bounds.height)
            let desired = rect.minY - visibleHeight * 0.2 - insets.top
            let y = min(max(desired, minOffset), maxOffset)
            guard abs(y - scrollView.contentOffset.y) > 0.5 else { return nil }
            return CGPoint(x: scrollView.contentOffset.x, y: y)
        }
    }
}

/// La `UITextView` del lettore: avvisa a ogni layout, per completare lo scroll
/// iniziale quando la vista ha finalmente una dimensione.
final class ReaderTextView: UITextView {
    var onLayout: (@MainActor () -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}

/// Regola "non autoscrollare mentre l'utente scorre o nei 5 s successivi".
/// Tempo iniettato, per i test.
struct AutoscrollGate: Sendable {
    static let quietPeriod: Duration = .seconds(5)

    private(set) var isUserScrolling = false
    private(set) var lastUserScrollEnd: ContinuousClock.Instant?

    mutating func userDidBeginScrolling() {
        isUserScrolling = true
    }

    mutating func userDidEndScrolling(at instant: ContinuousClock.Instant) {
        isUserScrolling = false
        lastUserScrollEnd = instant
    }

    func allowsAutoscroll(now: ContinuousClock.Instant) -> Bool {
        if isUserScrolling { return false }
        guard let lastUserScrollEnd else { return true }
        return now - lastUserScrollEnd >= Self.quietPeriod
    }
}

// MARK: - Capitolo sintetico (anteprime e test)

#if DEBUG
enum SyntheticChapter {
    /// Capitolo di `sentenceCount` frasi da `wordsPerSentence` parole, in
    /// paragrafi di `sentencesPerParagraph` frasi; ogni frase dura 3 s.
    static func make(
        chapter: Int = 1,
        sentenceCount: Int,
        wordsPerSentence: Int = 14,
        sentencesPerParagraph: Int = 5
    ) -> SentenceIndex {
        let words = ["il", "lettore", "ascolta", "mentre", "la", "voce", "scorre", "sul", "testo",
                     "evidenziato", "frase", "dopo", "frase", "senza", "perdere", "il", "segno", "àncora", "più"]
        let sentences = (0..<sentenceCount).map { number in
            let body = (0..<max(wordsPerSentence - 1, 1))
                .map { words[(number * 7 + $0 * 3) % words.count] }
                .joined(separator: " ")
            return Sentence(text: "Frase \(number + 1): \(body).", start: Double(number) * 3, end: Double(number) * 3 + 2.8)
        }
        let paragraphs = stride(from: 0, to: sentences.count, by: sentencesPerParagraph).map {
            Array(sentences[$0..<min($0 + sentencesPerParagraph, sentences.count)])
        }
        return SentenceIndex(
            chapter: chapter,
            content: ChapterContent(duration: Double(sentenceCount) * 3, paragraphs: paragraphs)
        )
    }
}

/// Anteprima per T6: la frase avanza da sola ogni 0,4 s; tap salta alla frase
/// toccata; la barra in basso mostra la prima frase visibile.
private struct SentenceTextViewPreview: View {
    let content = SyntheticChapter.make(sentenceCount: 200)
    @State private var current = 0
    @State private var firstVisible = 0
    @State private var theme: ReadingTheme = .light

    var body: some View {
        SentenceTextView(
            content: content,
            currentSentence: current,
            fontSize: 19,
            theme: theme,
            onTapSentence: { current = $0 },
            onLongPressSentence: { _ in theme = ReadingTheme.allCases[(theme.index + 1) % ReadingTheme.allCases.count] },
            onFirstVisibleSentenceChange: { firstVisible = $0 }
        )
        .ignoresSafeArea(edges: .bottom)
        .safeAreaInset(edge: .bottom) {
            Text("In lettura \(current + 1) · prima visibile \(firstVisible + 1) · \(theme.displayName)")
                .font(.footnote.monospacedDigit())
                .padding(8)
                .frame(maxWidth: .infinity)
                .background(.bar)
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                current = (current + 1) % content.count
            }
        }
    }
}

private extension ReadingTheme {
    var index: Int { ReadingTheme.allCases.firstIndex(of: self) ?? 0 }
}

#Preview("Capitolo sintetico") {
    SentenceTextViewPreview()
}
#endif
