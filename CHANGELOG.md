# Changelog

The `public` API of `FadenCore` and `FadenTranscription` is the contract with the Faden app. Versions follow [semantic versioning](https://semver.org); until 1.0, a minor version may change that API, and a patch version never does.

## Unreleased

## 0.3.0 - 2026-10-30

- Each `costs.jsonl` line now also records the pipeline `step` (`notes` or `verify`), the `provider` (`anthropic`), the `billing` (`api` or `subscription`) and `apiUSD`, what the call costs with an API key even when it ran on the subscription. `usd` still holds what was paid. Older lines decode with these fields as nil.
- `CostRecord(date:lecture:step:call:)` builds a record from a `PaidCall`; `CostLedger.apiTotal(since:)` sums the API prices, pricing older lines from their tokens; `Pricing.provider(model:)` names a model's provider.
- Ledger lines have their keys sorted, so every line has the same order.
- `scripts/cost-report.swift` counts runs by `step` where a line has it.

## 0.2.0 - 2026-10-29

- `Library` scans course folders and their subfolders into lectures with status, notes, transcript, slides, length, cost and iCloud state; `CourseList` keeps the course folders as bookmarks.

## 0.1.0 - 2026-10-29

First release as its own package, split out of the Faden app.

- Library products `FadenCore` (pipeline, prompts and styles, Anthropic API and `claude` CLI clients, Keychain, verification and output) and `FadenTranscription` (on-device transcription with WhisperKit).
- New `faden` command-line tool: `faden process`, `faden retry` and `faden styles` run the whole pipeline without the app.
- The resource bundle is now `faden-core_FadenCore.bundle` (it was `Faden_FadenCore.bundle`); `FadenCore.resourceBundleName` is public, so an app can find it.
