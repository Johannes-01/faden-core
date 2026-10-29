# Contributing to faden-core

Thanks for helping. Bug reports, fixes and better prompts are all welcome.

## Before you open an issue

- **Never attach real lecture material** you have no right to share: recordings, transcripts, other people's slides or full notes. A short excerpt that shows the problem, with names removed, is enough.
- For a failed run, the error the CLI printed and the stage it stopped at help most. The unified log has more (file names and timings, never lecture content):

  ```sh
  /usr/bin/log show --last 1h --predicate 'subsystem == "io.github.johannes-01.faden"' --info
  ```

## Changing code

1. Build with `swift build` and run the tests with `scripts/test.sh` (not plain `swift test`; see the README).
2. Add or update tests for what you change. The tests use Swift Testing (`import Testing`, `@Test`, `#expect`).
3. Match the surrounding code: its naming, comment style and structure. Comments say why, in full sentences.
4. Keep `FadenCore` free of UI frameworks (no AppKit, UIKit or SwiftUI).
5. Code that touches the real Keychain, audio or WhisperKit goes into `FadenIntegrationTests`; run those with `FADEN_INTEGRATION=1 scripts/test.sh` if you changed that code.

### The public API

The Faden app depends on `FadenCore` and `FadenTranscription` through their `public` API, by version. If your change adds, changes or removes anything `public`, say so in the pull request and add a line under "Unreleased" in [CHANGELOG.md](CHANGELOG.md).

## Changing prompts and styles

The prompts live in `Sources/FadenCore/Resources/prompts/` and the note styles in `Sources/FadenCore/Resources/styles/`.

1. Try your change on a real lecture of your own with the CLI. `--styles-dir` uses the styles in the repository instead of the installed copies:

   ```sh
   swift build -c release
   .build/release/faden process lecture.m4a --slides slides.pdf --out /tmp/try \
       --styles-dir Sources/FadenCore/Resources/styles --style C
   ```

2. Compare the notes before and after on at least two lectures, ideally of different kinds (slide-heavy, discussion, another language).
3. In the pull request, describe what got better and what you checked: the labels (🗣 lines really said, 📄 lines really on the slides), the ⚠️ count, and the token count and cost from the notes header. Short excerpts are welcome; whole notes of someone else's lecture are not.

The labels are the point of Faden: a change that makes the notes nicer but puts 🗣 on things the lecturer didn't say is a regression.

## Pull requests

- One topic per pull request, with a description of what changed and why.
- CI runs the unit tests on macOS; it has to pass.
- By contributing, you agree that your contribution is licensed under the [MIT License](LICENSE).

Please follow the [code of conduct](CODE_OF_CONDUCT.md).
