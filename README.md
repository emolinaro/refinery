# Refinery

A native macOS menu-bar app that polishes selected text through your own
OpenAI-compatible endpoint or your OpenAI subscription (the codex CLI's
ChatGPT login) via a global hotkey. Select a sentence anywhere, press the
hotkey, get the refined version on your clipboard - no browser round-trip.

## How it works

1. Select text in any app.
2. Press the global hotkey (default ⌥⌘P).
3. Refinery reads the selection (Accessibility API, or a guarded clipboard
   probe for apps without AX text surfaces - see Permissions), sends it to
   the selected provider (your OpenAI-compatible endpoint or your OpenAI
   subscription) with the chosen preset, and writes the polished text to the
   clipboard, ready to paste over the original.

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
preset, then choose **Settings…** to configure the endpoint and record the
hotkey.

To build the release app bundle for Apple silicon:

```sh
./Scripts/build-app.sh
```

The script writes one ad-hoc-signed app to `.build/Refinery.app`. It replaces
the previous bundle at that path and includes the MIT license.

## Permissions

Refinery needs the **Accessibility** permission to read selected text in other
apps and record a global hotkey. On first use the app surfaces this and macOS
shows its standard permission prompt: grant Refinery (or your terminal, when
running from one) access under System Settings -> Privacy & Security ->
Accessibility.

Refinery reads native Accessibility-backed text controls directly. When the
focused app exposes no AX text surface at all (its menu bar aside), as with
Sublime Text's custom editor rendering, Refinery falls back to a guarded copy
probe: it snapshots every current pasteboard representation, synthesizes
Command-C, reads the copied text, and restores the snapshot before making any
endpoint request. macOS exposes no pasteboard writer identity, so in such apps
the non-empty clipboard read plus the tightly focused acceptance window is the
strongest available verification that selected text was copied. One accepted
residual: in these apps, pressing the hotkey with no selection can polish the
current line, because apps like Sublime Text copy the current line on
Command-C with nothing selected. If the clipboard cannot be snapshotted or
restored safely, the run stops and surfaces an error instead of silently
losing clipboard data. Quitting while a probe owns the clipboard defers
termination until restoration finishes; only Force Quit can interrupt that
restore, and a failed restore cancels the quit. Native apps such as TextEdit,
Mail, and Safari stay on the primary AX path.

## Settings

From the menu-bar icon you can configure:

- **Provider** - which backend serves polish requests. **None** is the
  default; choose **Custom OpenAI-compatible endpoint** (the v0.1.x mode) or
  **OpenAI subscription (ChatGPT login)**. The provider picker also shows in
  the dropdown, which reports the provider that served the last polish.
- **Base URL** - your OpenAI-compatible endpoint. The first-run value
  `https://api.ucloud-ai.com/v1` is a private-deployment example; replace it
  with your own HTTPS endpoint. Plain HTTP is accepted only for localhost
- **Model** - model name sent to chat completions. The first-run value
  `ucloud-ai` matches that private-deployment example; replace it as needed
- **API Key** - stored only in the macOS Keychain, never in plain files, and
  kept separately for each endpoint URL
- **Hotkey** - record a ⌘/⌥/⌃-based combination, except common Command
  shortcuts C, V, X, Z, A, Space, and Tab. Refinery requests exclusive
  registration, but macOS cannot report an existing non-exclusive owner of the
  same shortcut. Refinery may accept that collision and receive the shortcut
  while the other app is suppressed, so verify a new shortcut after recording

Refinery sends `POST {baseURL}/chat/completions` and accepts the first choice
only when its `finish_reason` is `stop`. Incomplete or malformed responses are
not copied to the clipboard.

## OpenAI subscription mode

Selecting **OpenAI subscription (ChatGPT login)** as the provider rides the
codex CLI's login, the same way quota readers do:

- **Sign-in**: run `codex login` in a terminal once. Refinery reads the CLI's
  token store (`~/.codex/auth.json`) read-only and shows the signed-in email,
  plan, and last refresh in Settings - never the tokens themselves. Sign-out
  in Settings clears only Refinery's reference; the codex CLI's own login
  file is never touched.
- **Refresh**: when the stored access token is expired, Refinery refreshes
  through the same OAuth endpoint the codex CLI uses and persists the rotated
  tokens back to the store, so the CLI and the app share one login session.
  Refresh is only attempted on definitive expiry - the refresh token is
  single-use, so a running codex session is never invalidated speculatively.
- **Requests**: polish requests go to the ChatGPT backend-api surface the
  codex CLI itself uses (`chatgpt.com/backend-api/codex/responses`) with the
  account's bearer tokens and a subscription-eligible model from the gpt-5.6
  family, streaming the response and preserving the model's formatting.
- **Security**: tokens never appear in logs or error messages, and never
  leave the machine except to OpenAI's auth and ChatGPT-backend endpoints.

## Development

```sh
swift build     # build
swift test      # unit tests for the core app components
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
