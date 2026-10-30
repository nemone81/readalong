import Foundation
import Testing
@testable import ReadAlong

/// Regola di ripresa (funzione pura) e `ReaderModel` collegato a un
/// `PlayerEngine` vero con la fixture Pinocchio (2 capitoli, audio reale:
/// 177,4 s con 34 frasi e 122,9 s con 24 frasi).
@Suite("ReaderModel", .serialized)
@MainActor
struct ReaderModelTests {
    // MARK: - Regola di ripresa (pura)

    private let current = SentenceID(chapter: 1, index: 5)
    private let other = SentenceID(chapter: 1, index: 12)

    @Test("Nessuno scroll: riparte da dove era")
    func resumeWithoutScroll() {
        #expect(ReaderModel.resumeTarget(current: current, firstVisible: other, userScrolledWhilePaused: false) == nil)
        #expect(ReaderModel.resumeTarget(current: current, firstVisible: nil, userScrolledWhilePaused: false) == nil)
    }

    @Test("Scroll in pausa su un'altra frase: riparte dalla prima visibile")
    func resumeAfterScrollToOtherSentence() {
        #expect(ReaderModel.resumeTarget(current: current, firstVisible: other, userScrolledWhilePaused: true) == other)
        // Anche all'indietro.
        let earlier = SentenceID(chapter: 1, index: 1)
        #expect(ReaderModel.resumeTarget(current: current, firstVisible: earlier, userScrolledWhilePaused: true) == earlier)
    }

    @Test("Scroll in pausa ma in cima c'e' la frase corrente: nessun salto")
    func resumeAfterScrollToSameSentence() {
        #expect(ReaderModel.resumeTarget(current: current, firstVisible: current, userScrolledWhilePaused: true) == nil)
        // Prima frase visibile non ancora riportata: nessun salto.
        #expect(ReaderModel.resumeTarget(current: current, firstVisible: nil, userScrolledWhilePaused: true) == nil)
    }

    @Test("Scroll durante la riproduzione: play dopo la pausa non cambia frase", .timeLimit(.minutes(1)))
    func scrollWhilePlayingDoesNotMoveResume() async throws {
        let model = try await startedModel()
        await model.tapSentence(3) // seek + play
        try await waitUntil { model.isPlaying && model.currentSentence == SentenceID(chapter: 1, index: 3) }

        model.userDidScroll()
        model.firstVisibleSentenceChanged(20)
        #expect(model.userScrolledWhilePaused == false)

        await model.pause()
        try await waitUntil { !model.isPlaying }
        let pausedAt = try #require(model.currentSentence)
        let pausedTime = model.chapterTime

        await model.play()
        try await waitUntil { model.isPlaying }
        // Non deve saltare alla frase in vista (20): resta attorno alla frase di
        // pausa (una di tolleranza per lato: le posizioni arrivano a 10 Hz e la
        // frase letta alla pausa puo' essere indietro di un tick sul motore).
        let resumed = try #require(model.currentSentence)
        #expect(resumed.chapter == pausedAt.chapter)
        #expect(
            abs(resumed.index - pausedAt.index) <= 1,
            "ripreso da \(resumed) dopo pausa a \(pausedAt) (t=\(pausedTime), ora \(model.chapterTime))"
        )
        #expect(model.chapterTime >= pausedTime - 0.05)
        #expect(model.chapterTime < pausedTime + 1)
        await model.stop()
    }

    // MARK: - Modello con il motore vero

    @Test("Dopo start: capitolo 1, prima frase, testo caricato, in pausa")
    func startsAtBeginning() async throws {
        let model = try await startedModel()
        #expect(model.chapterNumber == 1)
        #expect(model.chapterContent?.chapter == 1)
        #expect(model.chapterContent?.count == 34)
        #expect(model.currentSentence == SentenceID(chapter: 1, index: 0))
        #expect(model.currentSentenceIndex == 0)
        #expect(model.isPlaying == false)
        #expect(abs(model.chapterDuration - 177.4) < 0.01)
        #expect(model.coverData != nil)
    }

    @Test("In riproduzione tempo e frase avanzano dal flusso di posizioni", .timeLimit(.minutes(1)))
    func followsPositions() async throws {
        let model = try await startedModel()
        await model.tapSentence(1) // "IV." dura 0,65 s: si parte dalla seconda frase
        try await waitUntil { model.isPlaying }
        let startTime = model.chapterTime
        try await waitUntil(timeout: .seconds(5)) { model.chapterTime > startTime + 0.5 }
        #expect(model.currentSentence?.chapter == 1)
        #expect((model.currentSentence?.index ?? -1) >= 1)
        await model.pause()
        try await waitUntil { !model.isPlaying }
        await model.stop()
    }

    @Test("Pausa, scroll su un'altra frase, play: riparte dalla frase in vista", .timeLimit(.minutes(1)))
    func resumesFromFirstVisibleAfterScroll() async throws {
        let model = try await startedModel()
        model.userDidScroll()
        model.firstVisibleSentenceChanged(10)
        #expect(model.userScrolledWhilePaused)

        await model.play()
        try await waitUntil { model.isPlaying && model.currentSentence == SentenceID(chapter: 1, index: 10) }
        #expect(model.userScrolledWhilePaused == false)
        await model.pause()
        await model.stop()
    }

    @Test("Pausa e scroll senza cambiare frase in cima: riparte da dove era", .timeLimit(.minutes(1)))
    func resumesInPlaceWhenFirstVisibleIsCurrent() async throws {
        let model = try await startedModel()
        await model.goToChapter(2)
        try await waitUntil { model.chapterNumber == 2 }
        model.userDidScroll()
        model.firstVisibleSentenceChanged(0)

        await model.play()
        try await waitUntil { model.isPlaying }
        #expect(model.currentSentence == SentenceID(chapter: 2, index: 0))
        #expect(model.chapterTime < 1)
        await model.pause()
        await model.stop()
    }

    @Test("Tap su una frase: salta li' e suona", .timeLimit(.minutes(1)))
    func tapSeeksAndPlays() async throws {
        let model = try await startedModel()
        await model.tapSentence(7)
        try await waitUntil { model.isPlaying && model.currentSentence == SentenceID(chapter: 1, index: 7) }
        let start = try #require(model.chapterContent?.startTime(of: 7))
        #expect(abs(model.chapterTime - start) < 0.5)
        await model.pause()
        await model.stop()
    }

    @Test("Cambio di capitolo: si carica il testo nuovo e si azzera la prima frase visibile")
    func changesChapter() async throws {
        let model = try await startedModel()
        model.firstVisibleSentenceChanged(4)
        await model.goToChapter(2)
        try await waitUntil { model.chapterNumber == 2 }
        #expect(model.chapterContent?.chapter == 2)
        #expect(model.chapterContent?.count == 24)
        #expect(model.currentSentence == SentenceID(chapter: 2, index: 0))
        #expect(model.firstVisibleSentence == nil)
        #expect(model.chapter?.title.hasPrefix("VI.") == true)
    }

    @Test("±15 s attraversano il confine di capitolo in entrambe le direzioni")
    func skipCrossesChapters() async throws {
        let model = try await startedModel()
        await model.goToChapter(2)
        try await waitUntil { model.chapterNumber == 2 }

        await model.skip(by: -ReaderModel.skipInterval)
        try await waitUntil { model.chapterNumber == 1 }
        // 15 s prima dell'inizio del capitolo 2 = 15 s prima della fine del capitolo 1.
        #expect(abs(model.chapterTime - (177.4 - 15)) < 0.5)
        #expect(model.chapterContent?.chapter == 1)

        await model.skip(by: ReaderModel.skipInterval + 1)
        try await waitUntil { model.chapterNumber == 2 }
        #expect(abs(model.chapterTime - 1) < 0.5)
    }

    @Test("Un comando di posizione annulla lo scroll in pausa")
    func positionCommandClearsScroll() async throws {
        let model = try await startedModel()
        model.userDidScroll()
        model.firstVisibleSentenceChanged(10)
        await model.skip(by: ReaderModel.skipInterval)
        #expect(model.userScrolledWhilePaused == false)
    }

    // MARK: - Prima frase visibile

    @Test("Offset su un separatore dopo una frase: la prima visibile e' la frase seguente")
    func separatorMapsToNextSentence() throws {
        let content = SyntheticChapter.make(sentenceCount: 6, sentencesPerParagraph: 3)
        let first = try #require(content.characterRange(of: 0))
        let endOfParagraph = try #require(content.characterRange(of: 2))
        typealias Coordinator = SentenceTextView.Coordinator
        // Dentro una frase: quella frase.
        #expect(Coordinator.sentence(startingAtOrAfter: first.location + 3, in: content) == 0)
        // Sullo spazio dopo la frase 0: la frase 1.
        #expect(Coordinator.sentence(startingAtOrAfter: NSMaxRange(first), in: content) == 1)
        // Sull'a capo tra due paragrafi: la prima frase del paragrafo dopo.
        #expect(Coordinator.sentence(startingAtOrAfter: NSMaxRange(endOfParagraph) + 1, in: content) == 3)
        // Oltre l'ultima frase: resta l'ultima.
        #expect(Coordinator.sentence(startingAtOrAfter: (content.text as NSString).length + 5, in: content) == 5)
    }

    // MARK: - Aiuti

    private final class BundleToken {}

    /// Pinocchio importato in una libreria temporanea, modello avviato e
    /// prima posizione ricevuta.
    private func startedModel() async throws -> ReaderModel {
        let fixture = try #require(
            Bundle(for: BundleToken.self).url(forResource: "pinocchio", withExtension: "rabook")
        )
        let importer = RABookImporter(libraryDirectory: try Fixture.temporaryDirectory())
        let book = try importer.importBook(from: fixture)
        let model = ReaderModel(book: book, reader: try importer.reader(for: book.id))
        try await model.start()
        try await waitUntil { model.chapterContent != nil && model.currentSentence != nil }
        return model
    }

    private struct Timeout: Error {}

    /// Aspetta che `condition` sia vera, controllando ogni 20 ms.
    private func waitUntil(
        timeout: Duration = .seconds(3),
        _ condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { throw Timeout() }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
