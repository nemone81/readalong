# ReadAlong

*English* · [Italiano](README.it.md)

An iOS app for reading and listening to the same book from the same spot. The text is split into sentences, each with its start and end time in the audio: while you listen, the sentence being read is highlighted; tap a sentence and the audio restarts from there; pause and keep reading. Position and bookmarks sync between iPhone and iPad through iCloud and, via KOReader and a KOSync server, with a jailbroken Kindle too.

It started from a single question: "can you build an audio player for this book that stays in sync with my reading position on the Kindle, and vice versa?". The Kindle does not expose the reading position to anyone, so the app became the reader, and the Kindle joined later through the back door.

A personal project, built with Claude Code: the spec, the plan and the task log live in `docs/` (in Italian).

## How it is built

```
tools/makebook/   generator for the Mac (Python 3.12, uv): PDF/EPUB → .rabook (+ an EPUB for the Kindle)
ios/              SwiftUI app (iOS 26, Swift 6, XcodeGen, Swift Testing, zero dependencies)
docs/             SPEC, PLAN, TASKS, ADRs, manual test checklist
scripts/check.sh  xcodegen + iOS build + tests + pytest, in one go
```

**The `.rabook` package** is a zip with `book.json` (metadata), one JSON per chapter with the sentences and their timings, one AAC audio file per chapter and the cover. The format is described in `docs/SPEC.md`.

**The audio** is generated locally by [Piper](https://github.com/rhasspy/piper) (Italian voice `it_IT-paola-medium`); per-sentence timings come out of the synthesis itself, with no forced alignment afterwards.

**The Kindle** reads an EPUB produced by the same generator (`makebook --epub`) in KOReader, which exchanges the position with the app through the KOSync protocol (`docs/adr/0003-kindle-kosync.md`).

## Trying it

Generator:

```sh
uv run --project tools/makebook makebook book.pdf -o book.rabook --title "Title" --author "Author" --language it
```

App: `cd ios && xcodegen generate`, then open `ReadAlong.xcodeproj`; `ios/Tools/build-device.sh` signs and installs on a connected device (an Apple Developer account is required). The whole repo is checked with `scripts/check.sh`.

## Status

Personal use, distributed through TestFlight; not an App Store product. Task status is in `docs/TASKS.md`.

## License

MIT, see `LICENSE`.
