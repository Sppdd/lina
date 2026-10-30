# Lina: hackathon submission

Nebius × NVIDIA Global AI Hackathon · **Personal AI** track

## Rules checklist

| Requirement | Where | Status |
|---|---|---|
| Runs on Nebius Token Factory | Companion, ghost text and rewrites call `https://api.tokenfactory.nebius.com/v1` (`Sources/Lina/Core/Settings.swift`) | ✅ |
| Uses at least one NVIDIA open model | `nvidia/nemotron-3-super-120b-a12b` (companion), `nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B` (ghost text, rewrites) | ✅ |
| Fits a track | Personal AI | ✅ |
| Functional and installable | [Lina.zip on GitHub Releases](https://github.com/Sppdd/lina/releases/latest/download/Lina.zip), or `scripts/build-app.sh --open` | ✅ |
| Live demo / test build link | Website: <https://sppdd.github.io/lina/> · Build: the release above | ✅ once Pages is on |
| Description of the app | Below, and the README | ✅ |
| Public repo | <https://github.com/Sppdd/lina> | ✅ |
| Open-source license visible | [`LICENSE`](../LICENSE) (MIT) | ✅ |
| README with setup and run steps | [`README.md`](../README.md#install) | ✅ |
| Video under 3 minutes, public on YouTube | Script in [`DEMO.md`](DEMO.md) | ⬜ record and upload |
| Track selection | Personal AI | ⬜ choose on Devpost |
| Feedback on Nebius and NVIDIA tools | Below | ✅ paste into Devpost |

---

## Devpost fields (ready to paste)

**Name:** Lina

**Tagline:** Write with someone beside you. An open-source writing companion for macOS that reads along in any app and thinks with you, in ink above your cursor.

**Links**

- Website: https://sppdd.github.io/lina/
- Download: https://github.com/Sppdd/lina/releases/latest/download/Lina.zip
- Source: https://github.com/Sppdd/lina
- Video: *(YouTube link)*

### Inspiration

People write to think through the things that matter most to them: a journal entry, a letter to a parent, a hard email, an essay they keep putting off. Most AI writing tools answer with a paragraph to paste in. That's quick, but it isn't your writing and it doesn't help you think. We wanted a companion that sits beside you while you write and asks the question a good friend would ask. And it should work in the apps people already use, not in a new editor.

### What it does

Lina is a menu bar app that reads along in any macOS app: Notes, Mail, Journal, Safari, Obsidian. When you pause, a drop of ink above your cursor writes back what Lina hears you saying, why you might be writing it, one question that takes you deeper and a thread worth following. The drop then flies to those words in your draft and underlines them.

- **Three modes** (`⇧⌥ Space`). **Understand** never touches your document: you answer its question in a reply box (`⌥ Space`) or by holding `⌃⌥` and speaking. **Edit** offers a cleaner version of each sentence you finish, which you take with `⇥`. **Auto** rewrites each sentence in place, and `⌘Z` undoes it.
- **`/lina` anywhere.** Type `/lina edit this paragraph`, `/lina write a closing line`, `/lina turn this into a photo` or `/lina remember this` in any text field and press return.
- **Memory.** Highlight text and press `⌃⌥ M`. Lina keeps notes about you on your Mac and uses them whenever it writes.
- **Writing from research.** If you opt in, Lina keeps the quotes you copy and reads your screenshots with on-device OCR. Then **Use what I gathered** writes from your real research, and **Look it up** answers from Wikipedia with a citation.
- **A rewrite palette, a calm Desk, optional ghost text, and a daily goal and streak.**
- **Private by design.** Lina never reads password fields, can be turned off per app, has no account and no analytics, and can run fully on your Mac with a local model. It recommends and downloads one for you.

### How we built it

Lina is a native Swift and SwiftUI app with no Electron and no backend for your writing.

- **Reading:** the macOS Accessibility API (`AXUIElement`) gives Lina the focused field's text, selection and caret bounds in any app.
- **Timing:** a `CGEventTap` watches typing, waits for a natural pause after a finished word, and cancels any request in flight the moment you type again.
- **Thinking:** **NVIDIA Nemotron 3 Super** on **Nebius Token Factory** reads the whole draft and returns a structured reflection (HEARING / WHY / ASK / NEXT / QUOTE), which Lina parses while it streams. **Nemotron 3 Nano** handles fast ghost text and sentence rewrites. **FLUX schnell** on the same Token Factory key draws pictures for `/lina … photo`.
- **Showing:** click-through, non-activating `NSPanel`s follow the caret, so Lina never steals focus. Accepted text is typed as key events, so it lands in the host app's own undo stack.
- **Local mode:** any OpenAI-compatible server (Ollama, LM Studio, llama.cpp). Lina talks to Ollama's API to recommend, download, switch and delete models.
- **Research context:** Apple Vision OCR for screenshots, Spotlight's `kMDItemIsScreenCapture` to spot new ones, and Wikipedia's REST API in the question's language.
- **Problem reports:** `/lina bug` writes a diagnostic report (never your text) and can send it to an insert-only Supabase table.

### Challenges we ran into

- **Reasoning models and live writing.** Nemotron's reasoning is great for depth but too slow for something that answers a pause. We turn it off (`/no_think`, `enable_thinking: false`) and strip any `<think>` spans from the stream, so text appears in under a couple of seconds.
- **Being in every app without breaking any of them.** Tab and Esc are swallowed only while a suggestion is on screen. Lina skips secure input, and its synthesized keystrokes are tagged so its own event tap ignores them.
- **Placing ink at the caret.** Every app reports caret bounds a little differently, and many return nothing for an empty range. When that happens, Lina measures the character just before the caret and puts the ink at its right edge.
- **macOS permissions during development.** Ad-hoc signatures change on every build, so the Accessibility permission kept resetting. The build script pins the code requirement to the bundle ID, so the grant survives rebuilds.

### Accomplishments we're proud of

- A companion that asks instead of writes, and still feels fast.
- It works in any app with a text field, from Notes to Gmail in Safari.
- Everything can run on the writer's own Mac, and nothing is collected.
- 36 unit tests covering the reflection parser, `/lina` command parsing, sentence detection, suggestion cleanup and prompts.

### What we learned

Small, structured prompts beat long ones for this job. Asking Nemotron for exactly one question, plus a short quote from the writer's own words, gave better reflections than asking for "feedback". We also learned that the hardest part of a system-wide assistant is restraint: knowing when to stay quiet.

### What's next for Lina

- Signed and notarized releases, and a Homebrew cask
- Memory across days, so Lina can follow a theme through a month of journaling
- Lina's questions spoken back in a natural voice
- Intel Mac support

### Built with

`swift` `swiftui` `appkit` `macos-accessibility` `nvidia-nemotron` `nebius-token-factory` `flux` `ollama` `apple-vision` `speech-framework` `supabase` `wikipedia-api`

---

## Feedback on Nebius and NVIDIA tools

**What worked well**

- **Token Factory's OpenAI-compatible API** meant one client for the cloud and local servers. Switching between Nemotron on Nebius and Ollama is a base URL change.
- **Streaming latency on Nemotron 3 Nano** is low enough for ghost text at the caret, which is the most demanding case: suggestions have to land within a pause.
- **Nemotron 3 Super** follows a strict output format (tagged lines, a single question, a verbatim quote) reliably, so Lina can parse reflections while they stream.
- **One key for text and images.** FLUX on the same Token Factory key let us add `/lina … photo` without another account.

**What could be better**

- **Turning reasoning off.** We send both `/no_think` and `enable_thinking: false`, and still filter `<think>` tags to be safe. One documented switch that's the same for every Nemotron model would help.
- **Model IDs** mix cases (`nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B` and `nvidia/nemotron-3-super-120b-a12b`). A stable alias such as `nemotron-nano-latest` would make app defaults last longer.
- **The `/models` list** doesn't say which models support images, tools or reasoning. Capability flags would let apps build pickers without hard-coding names.
- **Rate-limit headers.** Returning remaining quota on each response would let a real-time app back off before it hits a 429.
