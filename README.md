# faden-core

The open-source core of Faden: it turns a lecture recording, your slide PDFs and your own shorthand notes into study notes with Claude. Every statement in the notes is labelled with its source, so you can see what the lecturer said and what the model added.

Pipeline: transcribe on-device (WhisperKit) → write notes (Claude Opus 5.5, with your slides and notes) → check them against the sources (Claude Haiku 5.5) → `notes.md` in a lecture folder.

This repository holds the whole pipeline: the recording session handling, transcription, the prompts and note styles, the Anthropic API client, the `claude` CLI client, verification and output. It includes the `faden` command-line tool, so you can run everything end to end without the Faden app. The Faden macOS app is built on top of it.

## Requirements

- macOS 26 on Apple silicon
- Xcode Command Line Tools (full Xcode is not needed)
- An [Anthropic API key](https://console.anthropic.com), or a Claude subscription with [Claude Code](https://claude.com/claude-code) installed (`--subscription`)

## Build and test

```sh
swift build -c release          # builds .build/release/faden
scripts/test.sh                 # runs the unit tests
```

Run the tests through `scripts/test.sh`, not plain `swift test`: with only the Command Line Tools, `swift test` cannot find the Testing framework, and the script adds the framework and rpath flags it needs. Arguments pass through (`scripts/test.sh --filter LectureFolderTests`).

Integration tests (real Keychain, audio and WhisperKit) are skipped unless enabled:

```sh
FADEN_INTEGRATION=1 scripts/test.sh                    # uses the small speech model
FADEN_INTEGRATION=1 FADEN_ACCURATE=1 scripts/test.sh   # also the large model (big download)
```

## The `faden` CLI

```sh
export ANTHROPIC_API_KEY=sk-ant-...
faden process lecture.m4a --slides 03-sorting.pdf --notes my-notes.md --out ~/Lectures/Algorithms --style C
```

This creates `~/Lectures/Algorithms/<date> <title>/`, named after the first slide PDF (or, without slides, after the notes' title), with `notes.md`, `transcript.md`, the copied audio and the run's state in `.faden/`. The path of the notes file is printed on stdout, and progress goes to stderr.

- `faden process <audio…> --out <course folder>`: several audio files are joined in the order given. Options: `--slides <pdf…>`, `--notes <file>` (Markdown, text or PDF), `--style <id or letter>` (default `C`), `--no-additions` (no 💡 lines), `--language de|en` (detected otherwise), `--model fast|accurate` (speech model), `--retranscribe`.
- `faden retry <lecture folder>`: continues a failed or interrupted run (a network error, Ctrl-C) from the stage where it stopped. Stages that were already paid for are not paid for again.
- `faden styles`: lists the note styles.
- `--subscription`: sends the calls through the local `claude` CLI on your Claude subscription instead of the API. For personal use; the notes header then shows how much of the session and weekly limit the run used.

The API key comes from `ANTHROPIC_API_KEY`, or else from the Keychain item the Faden app stores (service `io.github.johannes-01.faden`, account `anthropic-api-key`). macOS may ask once to let `faden` read it.

The first transcription downloads the WhisperKit model into `~/Documents/huggingface`; `accurate` is much larger than `fast`. Run `faden help process` for all options.

## Note styles and prompts

The prompts are plain Markdown and are meant to be improved:

- `Sources/FadenCore/Resources/prompts/`: the shared system prompts for writing the notes and for the check
- `Sources/FadenCore/Resources/styles/`: the note styles. Four ship: A (slide by slide, falls back to B without slides), B (by topic), C (red line first, then detail; the default) and D (each slide as an image with only what the lecturer added under it, falls back to B without slides).

A style is a Markdown file whose front matter sets `name`, and optionally `requires_slides`, `fallback` and `slide_images`; the body is the style's part of the prompt. On first use, the styles are copied to `~/Library/Application Support/Faden/styles/`, where users can edit them or add their own. Files already there are never overwritten, so to try changes to the shipped styles, point the CLI at the repository:

```sh
faden process lecture.m4a --out /tmp/try --styles-dir Sources/FadenCore/Resources/styles --style D
```

Changes to the system prompts take effect with the next build.

## The labels

- 📄 from the slides, with the slide number
- 🗣 said in the lecture, with a transcript timestamp such as `[00:23:14]`
- 💡 added by the model (only with additions on)
- ✍️ taken from your own shorthand notes
- ⚠️ the check found no support for the statement in the sources

Unclear passages go into an "Unclear in recording" section instead of being filled in.

## Where files go

```
<course folder>/
  2026-10-23 <Title>/
    notes.md                    the notes; the header lists models, sources, tokens and cost
    transcript.md               timestamped, for checking 🗣 lines
    audio.m4a
    notes (re-run <stamp>).md   processing again never overwrites
    slide-images/               style D's slide images
    .faden/                     processing state and transcript data
```

Slide PDFs are referenced, not copied. Each paid call is also appended to `~/Library/Application Support/Faden/costs.jsonl`, with its step (notes or verify), provider, model, billing (API key or subscription), tokens, what it cost and what it costs at API prices; `swift scripts/cost-report.swift [costs.jsonl …]` summarises ledgers into the cost per lecture.

## Costs

Expect about $0.50–1 per lecture with a ~50-page deck at API prices, and about $2 for very large decks; the check adds a few cents. Every notes header records the run's tokens and cost.

## Privacy

Audio never leaves the Mac: transcription runs on-device. Only the transcript text, your notes and the slides (their text, plus images of their figures) are sent to the Anthropic API, or to the `claude` CLI with `--subscription`. Recording someone's spoken words can need their consent (in Germany, §201 StGB); that is your responsibility.

## Using the library

Add the package and depend on the `FadenCore` and `FadenTranscription` products:

```swift
.package(url: "https://github.com/Johannes-01/faden-core", .upToNextMinor(from: "0.1.0")),
```

`FadenCore` has no UI code; it uses Foundation, AVFAudio, PDFKit, Security and Accelerate. Load prompts and styles through `FadenCore.resources`, not `Bundle.module`: an app that bundles FadenCore copies `faden-core_FadenCore.bundle` into its `Contents/Resources`, and `FadenCore.resources` looks there first. The public API is the contract with the app and follows semantic versioning; see [CHANGELOG.md](CHANGELOG.md). Until 1.0, a minor version may break it.

## Contributing

Bug reports, fixes and prompt improvements are welcome; see [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE)
