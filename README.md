# Yaptype

Fast, private-by-default voice dictation for macOS. Hold **⌘;**, talk, release, and the cleaned-up text is pasted
wherever your cursor is.

Yaptype keeps speech recognition on your Mac with NVIDIA Parakeet. Text polishing is the only network step: the
transcript is sent to [OpenRouter](https://openrouter.ai) for cleanup, then pasted locally. If OpenRouter is
unavailable, Yaptype still pastes the deterministic rules-cleaned transcript, so a dictation is never lost.

## What runs where

| Step | Where it runs |
| --- | --- |
| Microphone capture and live waveform | This Mac |
| Speech-to-text (Parakeet TDT 0.6B, CoreML via FluidAudio) | This Mac |
| Filler removal, spoken commands, dictionary, numbers, list layout | This Mac |
| Tone and grammar polishing | OpenRouter (text only) |
| History, statistics, audio clips | This Mac |

Microphone audio is never uploaded. OpenRouter receives the transcript plus the prompt context (tone, dictionary,
memory, and optionally the text around your cursor).

## Requirements

- Apple Silicon Mac, macOS 15 or newer.
- Xcode Command Line Tools (`xcode-select --install`). Xcode itself is not required.
- An OpenRouter API key for polishing. The key is optional: without it, Yaptype runs rules-only.

The first build downloads public Swift packages and one public binary artifact from GitHub Releases. No GitHub
account, token, or keychain credential is needed.

## Build and install

1. Open Terminal and install the command line tools if you have not already:

   ```sh
   xcode-select --install
   ```

2. Go to the project folder:

   ```sh
   cd /Users/aradhya/learnings/yaptype
   ```

3. Build the release app and install it to `/Applications`:

   ```sh
   ./scripts/build.sh --install
   ```

   The first build takes a few minutes because it downloads FluidAudio and the Parakeet runtime. Later builds are
   much faster. To build without installing, run `./scripts/build.sh`; the app appears in `dist/Yaptype.app`.

4. Open Yaptype:

   ```sh
   open /Applications/Yaptype.app
   ```

5. Grant permissions when macOS asks:

   - **Microphone** — required for dictation.
   - **Accessibility** — required for the global hotkey and for pasting into other apps. Enable Yaptype in
     System Settings › Privacy & Security › Accessibility.
   - **Contacts / Calendar** — optional. When enabled, names from Contacts and today's calendar are boosted in
     speech recognition. They stay on this Mac.

   After a rebuild, macOS may ask for Accessibility again. The build script signs with a stable identifier-based
   designated requirement, which normally preserves the grant. If the hotkey stops working, toggle Yaptype off and
   back on in Accessibility settings.

6. Add your OpenRouter key. Open Yaptype's window and go to **Settings › Polishing**, paste the key into
   **OpenRouter API key**, and close the window. The key is saved in
   `~/Library/Application Support/Yaptype/config.json` as plaintext, as requested for this build.

   You can also edit the file directly:

   ```json
   "openRouterAPIKey": "sk-or-..."
   ```

   The default models are:

   - Primary: `nvidia/nemotron-3-ultra-550b-a55b:free`
   - Fallback: `google/gemma-4-26b-a4b-it:free`

   Both are free OpenRouter models. Free models can rate-limit; Yaptype tries the fallback, then pastes rules-only
   text if both fail.

7. Hold **⌘;** anywhere and start talking. Release to paste. A quick tap starts toggle mode; press again to stop.
   **Esc** cancels the current recording. **⌘⇧;** uses the alternate tone for the frontmost app.

## Models

Parakeet is downloaded automatically on first launch into:

```text
~/Library/Application Support/FluidAudio/Models/
```

- **v2** — English-only, the most accurate for English.
- **v3** — 25 European languages.

Switch between them in **Models** or **Settings**. The download is roughly 600 MB and happens once.

Text polishing uses OpenRouter only. There is no local LLM and no model file to manage.

## Configuration

Everything user-configurable lives in:

```text
~/Library/Application Support/Yaptype/config.json
```

Useful fields:

| Field | Meaning |
| --- | --- |
| `openRouterAPIKey` | OpenRouter key. Empty disables polishing. |
| `openRouterModel` | Primary polishing model. |
| `openRouterFallbackModel` | Used when the primary is rate-limited or unavailable. |
| `asrVersion` | `"v2"` (English) or `"v3"` (multilingual). |
| `dictionary` | Terms and sound-alikes, e.g. `"Yaptype: yap type, yap-type"`. |
| `tones` | Name → instruction. An empty instruction means verbatim. |
| `memory` | Background about you for the polish prompt. |
| `keepClips` | Save each dictation's audio in `clips/` for `--eval`. |

`starter-config.json` in this repository is the default configuration. To start from a clean config:

```sh
mkdir -p ~/Library/Application\ Support/Yaptype
cp starter-config.json ~/Library/Application\ Support/Yaptype/config.json
```

Then add your OpenRouter key to `openRouterAPIKey`.

### Privacy of the key

The key is stored in plaintext in `config.json`. Do not commit that file, share it, or include it in a screenshot.
The repository's `.gitignore` excludes build output, not your Application Support folder; the config lives outside
the repository.

## Data and privacy

- Audio clips are saved only when `keepClips` is on, and only under `~/Library/Application Support/Yaptype/clips/`.
- History and statistics are local JSON files in the same folder.
- Contacts and calendar names are read only when you enable that setting and grant permission.
- OpenRouter receives text, never audio. Its handling of that text is governed by OpenRouter's terms and the model
  provider's policies.

## Command-line helpers

Run the binary directly for diagnostics:

```sh
/Applications/Yaptype.app/Contents/MacOS/Yaptype --selftest
/Applications/Yaptype.app/Contents/MacOS/Yaptype --dumpconfig
/Applications/Yaptype.app/Contents/MacOS/Yaptype --dumpprompt professional
/Applications/Yaptype.app/Contents/MacOS/Yaptype --polishtest "um so we ship on thursday"
/Applications/Yaptype.app/Contents/MacOS/Yaptype --eval
/Applications/Yaptype.app/Contents/MacOS/Yaptype --context
/Applications/Yaptype.app/Contents/MacOS/Yaptype --mictest
```

- `--selftest` runs the deterministic text-rule checks.
- `--dumpconfig` prints the default config JSON.
- `--dumpprompt <tone>` prints the system and user prompt without calling OpenRouter.
- `--polishtest` runs the full polish path for one transcript.
- `--eval` replays corrected dictations that still have audio clips and scores them.
- `--context` prints what Accessibility sees for the frontmost window (sizes only, no field text).
- `--mictest` records a few seconds and reports what the selected microphone delivered.

## Troubleshooting

**The hotkey does nothing.** Grant Accessibility, then quit and reopen Yaptype. Check that another app is not
holding ⌘;.

**“Microphone gave silence.”** Pick a different input in Settings › Microphone. The built-in mic is silent while
the lid is closed; AirPods work but are narrowband.

**Text is pasted but not polished.** Add an OpenRouter key in Settings › Polishing. Check the status in the menu bar:
without a key it says “Ready (rules only…)”. Also check the OpenRouter account has access to the configured models;
free models can be rate-limited.

**The app will not open after a rebuild.** Build and install again with `./scripts/build.sh --install`. The app is
ad-hoc signed for local use, not notarized for distribution. If Gatekeeper complains, right-click the app and
choose Open.

**OpenRouter returns 429 or 5xx.** Yaptype automatically tries the fallback model, then falls back to the local
deterministic rules. You can change either model ID in Settings.

## License

Yaptype is licensed under the PolyForm Noncommercial License 1.0.0. See `LICENSE` and `NOTICE.md`.
