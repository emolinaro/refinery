# Project agent memory

This file is the project's committed home for project-intrinsic agent knowledge: build, test, release, architecture, and sharp-edge notes that should travel with the code.

- Add durable project-specific notes here as they are discovered through real work.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.

## Build, test, release

- `swift build` / `swift test` (SwiftPM, macOS 13+, swift-tools 6.1). Unit
  tests run headless; the AppModel hotkey tests need `NSApplication.shared`.
- `Scripts/e2e-smoke.sh` runs the RefineryE2E harness against a mock
  endpoint (endpoint provider path only).
- `Scripts/build-app.sh` builds the release `Refinery.app` (arm64, ad-hoc
  signed, LSUIElement). Bump `CFBundleShortVersionString` +
  `CFBundleVersion` in it, `CHANGELOG.md`, and tag per the v0.1.x
  procedure when cutting a release.

## Architecture notes

- Providers: `AppSettings.provider` selects the polish backend
  (`ProviderSelection`: none / custom endpoint / OpenAI subscription).
  Routing lives in `PolishService` + `AppModel.handle`. The endpoint path
  (v0.1.x) and the subscription path are siblings; keep the endpoint path
  untouched when changing the subscription provider.
- Subscription mode rides the codex CLI's ChatGPT login: `CodexAuthStore`
  reads `~/.codex/auth.json` (read-only discipline, writes only to persist
  OAuth rotation), `ChatGPTSession` gates refresh on definitive expiry
  (refresh token is single-use - never refresh speculatively),
  `SubscriptionClient` speaks the `chatgpt.com/backend-api/codex/responses`
  SSE wire format. Token material must never appear in logs, errors, or UI.
- `AppSettings` decodes with `decodeIfPresent` defaults for fields added
  after v0.1.x so older persisted settings keep loading (see
  `testV01xSettingsWithoutProviderDecodeAsNone`). Preserve that when
  adding new persisted fields.
