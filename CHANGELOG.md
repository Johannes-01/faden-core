# Changelog

The `public` API of `FadenCore` and `FadenTranscription` is the contract with the Faden app. Versions follow [semantic versioning](https://semver.org); until 1.0, a minor version may change that API, and a patch version never does.

## Unreleased

## 0.1.0 - 2026-10-29

First release as its own package, split out of the Faden app.

- Library products `FadenCore` (pipeline, prompts and styles, Anthropic API and `claude` CLI clients, Keychain, verification and output) and `FadenTranscription` (on-device transcription with WhisperKit).
- New `faden` command-line tool: `faden process`, `faden retry` and `faden styles` run the whole pipeline without the app.
- The resource bundle is now `faden-core_FadenCore.bundle` (it was `Faden_FadenCore.bundle`); `FadenCore.resourceBundleName` is public, so an app can find it.
