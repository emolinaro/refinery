# Refinery

A native macOS menu-bar app that polishes selected text through your own
OpenAI-compatible endpoint via a global hotkey. Select a sentence anywhere,
press the hotkey, get the refined version on your clipboard - no browser
round-trip.

## How it works

1. Select text in any app.
2. Press the global hotkey (default ⌥⌘P).
3. Refinery reads the selection (Accessibility API), sends it to your
   configured OpenAI-compatible endpoint with the chosen preset, and writes
   the polished text to the clipboard, ready to paste over the original.

Six presets, picked from the menu-bar icon:

- **Polish** - fix grammar, spelling and clarity, keep meaning and language
- **Concise** - same message, fewer words
- **Formal** - neutral, professional register
- **Friendly Email** - warm, conversational email tone
- **Language-Aware** - auto-detect Danish or English and polish in that language
- **Custom…** - type a one-off instruction for this run

## Requirements

- macOS 13 or later
- Xcode command-line tools (Swift 6.1 or later)

## Building and running

```sh
swift build
swift run Refinery
```

The app runs as a menu-bar item (wand-and-stars icon). Open it to pick a
preset, configure the endpoint, and record the hotkey.

## Permissions

Refinery needs the **Accessibility** permission to read selected text in other
apps and record a global hotkey. On first use the app surfaces this and macOS
shows its standard permission prompt: grant Refinery (or your terminal, when
running from one) access under System Settings -> Privacy & Security ->
Accessibility.

## Settings

From the menu-bar icon you can configure:

- **Base URL** - OpenAI-compatible endpoint (default suggestion:
  `https://api.ucloud-ai.com/v1`)
- **Model** - model name sent to chat completions (default suggestion:
  `ucloud-ai`)
- **API Key** - stored only in the macOS Keychain, never in plain files
- **Hotkey** - record a ⌘/⌥/⌃-based combination, except common Command
  shortcuts C, V, X, Z, A, Space, and Tab

## Development

```sh
swift build     # build
swift test      # unit tests for presets and the endpoint client
```

End-to-end smoke test (mock endpoint, dummy key):

```sh
./Scripts/e2e-smoke.sh polish
./Scripts/e2e-smoke.sh languageAware
./Scripts/e2e-smoke.sh customOneOff "translate to pirate speak"
```

The smoke test starts a local mock OpenAI-compatible server, runs the real
request/parse/clipboard pipeline against it, and prints what landed on the
clipboard. It never contacts a real endpoint and never uses a real API key.

## License

MIT - see [LICENSE](LICENSE).
