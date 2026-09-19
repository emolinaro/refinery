# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/emolinaro/refinery/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/emolinaro/refinery/releases/tag/v0.1.0
