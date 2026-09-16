# Refinery

A native macOS app that polishes selected text through your own
OpenAI-compatible endpoint via a global hotkey. Select a sentence anywhere,
press the hotkey, get the refined version on your clipboard - no browser
round-trip.

## Status

Early development. Intake decisions (2026-09-16):

- Global hotkey: select text in any app, polished result lands on the clipboard
- Configurable OpenAI-compatible endpoint (base URL, model, API key stored locally)
- Style presets: fixed polish, concise, formal, friendly email, language-aware
  (keeps Danish/English as written), and a custom one-off prompt mode

## Development

Swift / native macOS. Details follow as the first lanes land.
