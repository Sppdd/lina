# Lina: hackathon submission

Nebius × NVIDIA Global AI Hackathon · **Personal AI** track

## Rules checklist

| Requirement | Where | Status |
|---|---|---|
| Runs on Nebius Token Factory | Commands, sentence checks, `/lina model` and `/lina image` call `https://api.tokenfactory.nebius.com/v1` (`Sources/Lina/Core/Settings.swift`) | ✅ |
| Uses at least one NVIDIA open model | `nvidia/nemotron-3-super-120b-a12b` (commands), `nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B` (sentence checks) | ✅ |
| Fits a track | Personal AI | ✅ |
| Functional and installable | [Lina.zip on GitHub Releases](https://github.com/Sppdd/lina/releases/latest/download/Lina.zip), or `scripts/build-app.sh --open` | ✅ once the release is published |
| Live demo / test build link | Website: <https://sppdd.github.io/lina/> · Build: the release above | ✅ once Pages is on |
| Description of the app | Below, and the README | ✅ |
| Public repo | <https://github.com/Sppdd/lina> | ✅ |
| Open-source license visible | [`LICENSE`](../LICENSE) (MIT) | ✅ |
| README with setup and run steps | [`README.md`](../README.md#install) | ✅ |
| Video under 3 minutes, public on YouTube | Script in [`DEMO.md`](DEMO.md) | ⬜ record and upload |
| Track selection | Personal AI | ⬜ choose on Devpost |
| Feedback on Nebius and NVIDIA tools | Below | ✅ paste into Devpost |

**For judges testing the build:** install with `curl -fsSL https://sppdd.github.io/lina/install.sh | zsh` (Lina isn't notarized yet, and this skips macOS's "could not verify" warning), then sign in during onboarding with your email and the code Lina sends you. No keys are needed; Lina's server holds them and counts each person's daily use. If the code email doesn't arrive (the sender is rate-limited), skip sign-in and paste a free Nebius Token Factory key instead; a Gemini key is optional.

---

## Devpost fields (ready to paste)

**Name:** Lina

**Tagline:** Most AI writing tools interrupt you. Lina waits until you ask. Type `/lina` in any app on your Mac.

**Links**

- Website: https://sppdd.github.io/lina/
- Download: https://github.com/Sppdd/lina/releases/latest/download/Lina.zip
- Source: https://github.com/Sppdd/lina
- Video: *(YouTube link)*

### Inspiration

The writing that matters most to people happens everywhere: a journal entry in Notes, a hard email in Mail, a message in Slack, a search box in the middle of research. AI writing tools either live in their own editor or pop up suggestions all the time. We wanted the opposite: a helper that lives at your cursor in every app, stays quiet until you call her, and never puts a word into your text without your say-so.

### What it does

Lina is a menu bar app with a character: her hair color and face show what she's doing. You ask her by typing `/lina` and what you want, in any text field, then pressing Return:

- `The 2022 final ended /lina who won and how` ↩ searches the web. `⌘1` swaps the question for an answer worded to fit your sentence: *"…ended with Argentina beating France on penalties after a 3–3 draw"*. `⌘2` adds the source.
- `/lina` on its own asks one short question about what you just wrote, the kind a good editor or friend would ask.
- `/lina rewrite polite` gives three rewrites of the paragraph. `/lina edit make it shorter` changes it the way you say.
- `/lina image a reading nook at dusk` draws a picture with FLUX and puts it where the command was.
- `/lina remember my sister is Noor` (or `⌃⌥ M` on highlighted text) keeps a note on your Mac that Lina uses in every answer.
- `/lina gathered` writes the next lines from the quotes you copied and the screenshots you took while researching (opt-in, read on your Mac).
- **Hold `⌃⌥` and talk** to say any command instead of typing it.
- **Corrections without asking:** when you finish a sentence and pause, Lina checks it. The right word appears in a small chip right above each mistake. `⌘1`, `⌘2`… takes one and `⌘A` takes them all.

The command is tinted and underlined so it reads as hers, Return never reaches the app (so a search box won't submit), and nothing enters your text until you press `⌘1`. Then the answer takes the command's place and `⌘Z` undoes it. Lina's window has animated demos of each use case and a **Saved** history of every answer, with sources.

### How we built it

Lina is a native Swift and SwiftUI app.

- **Reading:** the macOS Accessibility API (`AXUIElement`) gives Lina the focused field's text, selection and the screen position of any range. That's how fix chips sit on top of the exact word. In fields that can't be read (some web search boxes), Lina follows the keystrokes and pastes at the caret instead.
- **Listening for `/lina`:** a `CGEventTap` notices `/lina` as it's typed, marks it with an overlay, runs it on Return or a pause after `,` `.` `?`, and swallows keys only while a card is waiting for a choice.
- **Models:** **NVIDIA Nemotron 3 Super** on **Nebius Token Factory** answers commands. **Nemotron 3 Nano** proofreads each finished sentence and returns exact spans as JSON, so each fix can be placed over its word. **FLUX schnell** on the same key draws pictures. `/lina model` lists every Token Factory model and switches with a keystroke.
- **Search:** Google Gemini with Search grounding returns the answer, its sources and Google's required Search Suggestions. The model then rewrites the answer to fit the writer's sentence. Without Gemini, Lina can answer from Wikipedia's REST API in the question's language.
- **On-device pieces:** Apple's Speech framework for hold-to-talk, Vision OCR for screenshots, Spotlight's `kMDItemIsScreenCapture` to notice new screenshots, and Ollama's API to recommend, download and switch local models.
- **Server:** Supabase Auth with emailed codes, and a `lina-ai` Edge Function that holds provider keys, enforces per-user daily quotas in Postgres and allowlists models.

### Challenges we ran into

- **Writing into any app safely.** Every app treats Accessibility differently. Lina replaces exact ranges where it can and falls back to keystrokes where it can't. Return is swallowed only while a command is pending, so it never submits a form by accident.
- **Putting a fix on top of the right word.** We ask Nemotron Nano for the smallest possible spans, then match them back to the writer's text so a chip can sit over each mistake. When an app won't report word positions, Lina lists the fixes in a card instead.
- **Answers that fit a sentence.** A raw search answer rarely reads well mid-sentence. We ask for two lines, a replacement that fits the words around it and a standalone answer, and show both.
- **Reasoning models in a real-time tool.** Nemotron's reasoning is turned off (`/no_think`, `enable_thinking: false`) and any `<think>` spans are filtered from the stream, so checks land within about a second of a pause.
- **macOS permissions during development.** Ad-hoc signatures change on every build, which reset the Accessibility grant. The build script pins the code requirement to the bundle ID.

### Accomplishments we're proud of

- A helper that works in any text field on the Mac, including ones it can't read.
- The rule that nothing enters your text without a `⌘` keystroke, kept everywhere.
- A character whose face tells you her state at a glance.
- 37 unit tests over command parsing, sentence finding, proofreading spans, answer parsing and prompts, a CI workflow, and an end-to-end live test that drives TextEdit.

### What we learned

Restraint is the feature. Asking Nemotron for exactly one question under 20 words gave far better prompts to think with than asking for "feedback", and checking only finished sentences keeps corrections useful instead of noisy.

### What's next for Lina

- Skills: `/lina cite`, `/lina translate`, a team style guide, Notion and Google Docs search
- Signed and notarized releases, and a Homebrew cask
- Intel Mac support

### Built with

`swift` `swiftui` `appkit` `macos-accessibility` `nvidia-nemotron` `nebius-token-factory` `flux` `gemini` `google-search-grounding` `ollama` `apple-vision` `speech-framework` `supabase` `wikipedia-api`

---

## Feedback on Nebius and NVIDIA tools

**What worked well**

- **Token Factory's OpenAI-compatible API** meant one client for the cloud and local servers. Switching between Nemotron on Nebius and Ollama is a base URL change.
- **Nemotron 3 Nano** is fast enough to proofread every finished sentence, and it reliably returns strict JSON with exact spans, which is what lets fixes sit on top of their words.
- **Nemotron 3 Super** follows tight output rules well: one question under 20 words, or exactly three rewrites, with no preamble.
- **One key for text and images.** FLUX on the same Token Factory key made `/lina image` a small addition.
- **`/models`** let us build `/lina model`, which lists everything on Token Factory inside the writer's own text field.

**What could be better**

- **Turning reasoning off.** We send both `/no_think` and `enable_thinking: false`, and still filter `<think>` tags to be safe. One documented switch that works the same for every Nemotron model would help.
- **Model IDs** mix cases (`nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B` and `nvidia/nemotron-3-super-120b-a12b`). A stable alias such as `nemotron-nano-latest` would make app defaults last longer.
- **Capabilities in `/models`.** The list doesn't say which models make images, take tools or reason. Flags would let apps build pickers without hard-coding names.
- **Rate-limit headers.** Returning the remaining quota on each response would let a real-time app back off before it hits a 429.
