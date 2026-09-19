# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.1] - 2026-09-19

### Fixed

- Sublime/AX-hostile fallback: pressing the hotkey with the wanted text already
  on the clipboard (copy, select, hotkey - the natural flow) no longer reports
  "no text selected"; a probe copy that equals the pre-probe clipboard text is
  accepted as a valid selection.
- The accessibility permission prompt now fires at most once per launch with a
  quiet menu-bar status line, instead of popping System Settings on every
  hotkey press; a rebuilt app gets an honest re-grant message instead of a
  silent mismatch.
- The hotkey-recording prompt rides the same once-per-launch gate.
- New installs start with blank endpoint fields instead of a dead default
  endpoint URL.

## [0.2.0] - 2026-09-19

### Added

- OpenAI subscription auth mode: Refinery can now polish through your
  ChatGPT account using the codex CLI's login (`codex login`). The provider
  picker in Settings selects between the custom OpenAI-compatible endpoint
  and "OpenAI subscription (ChatGPT login)"; none is selected by default,
  so nothing changes for existing installs until you choose one.
- Shared login session: Refinery reads the codex CLI's `~/.codex/auth.json`
  read-only, refreshes the OAuth tokens through the same endpoint the CLI
  uses when the access token is expired, and persists the refreshed tokens
  back so the CLI and Refinery stay signed in together.
- Subscription requests ride the same ChatGPT backend-api surface the codex
  CLI uses (`chatgpt.com/backend-api/codex/responses`) with a
  subscription-eligible model from the gpt-5.6 family, streaming SSE and
  preserving the model's formatting in the polished result.
- Settings account state for the subscription provider: signed-in email,
  plan, and last refresh (from the login's identity claims - never token
  material), plus a sign-out affordance that clears only Refinery's
  reference and never the codex CLI's own login file.
- The menu-bar dropdown now shows the active provider, or which provider
  served the most recent polish.

### Security

- Tokens from the codex CLI store never appear in logs, error messages, or
  the UI, and never leave the machine except to OpenAI's auth and
  ChatGPT-backend endpoints. Refresh-token rotation is only attempted when
  the access token is definitively expired, never speculatively, so a
  running codex CLI session is never invalidated.

### Fixed

- The in-app Sign Out button now actually gates polishing: the hotkey's
  credential fetch routes through the account controller, so a sign-out
  blocks subscription polish even though the codex CLI's own login remains
  on disk.
- The provider is captured when the hotkey fires: switching the provider in
  Settings while a polish is in flight no longer misroutes the request to
  a provider whose credentials were never gathered.
- Removed dead scaffolding introduced with the subscription mode: an unused
  parallel routing method in PolishService, an unused account-state struct
  and file-presence hook in CodexAuthStore, and an unused clock parameter
  plus no-op URLSession wrapper in OAuthTokenRefresher.
- The subscription client's default transport now derives its URLSession
  timeouts from the request itself, matching the endpoint client's
  established pattern.

## [0.1.1] - 2026-09-19

### Fixed

- Selection capture in AX-hostile editors such as Sublime Text: a guarded
  clipboard fallback now snapshots the clipboard, synthesizes Command-C,
  reads the copied text, and restores the clipboard before the polish
  request, so selected text can be polished in apps that hide their
  selection from accessibility APIs.
- Clipboard safety hardening: clipboard contents survive every adversarial
  capture path, quitting mid-probe defers termination until restoration
  finishes, and a failed restore cancels the quit instead of losing data.
- Focus-continuity checks so the fallback never pastes into the wrong app,
  with fail-closed guards when focus or selection cannot be proven.
- Removed an unreachable clipboard-restore status flag and its menu branch
  (dead code left over from the fallback hardening rounds).

## [0.1.0] - 2026-09-18

### Added

- Native macOS menu-bar app for polishing selected text through a configurable
  OpenAI-compatible endpoint.
- System-wide hotkey flow that reads the selection from the frontmost app and
  places the polished result on the clipboard, ready to paste.
- Endpoint URL and model settings with API keys stored only in the macOS
  Keychain.
- Six style presets: Polish, Concise, Formal, Friendly Email, Language-Aware
  Danish or English polishing, and a custom one-off prompt.
- MIT license for Refinery contributors.

### Fixed

- Prevented the menu-bar dropdown from collapsing to zero height.
- Moved editable settings into a keyboard-focusable popover and hardened
  selected-text capture against focus changes and transient Accessibility API
  failures.

[Unreleased]: https://github.com/emolinaro/refinery/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/emolinaro/refinery/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/emolinaro/refinery/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/emolinaro/refinery/releases/tag/v0.1.0
