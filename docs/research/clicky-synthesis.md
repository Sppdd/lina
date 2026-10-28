# Research Synthesis: What Lina can take from Clicky

**Method:** Teardown of Clicky's open-source code ([farzaa/clicky](https://github.com/farzaa/clicky), MIT, ~7.7k lines of Swift plus a Cloudflare Worker), compared with Lina.
**Participants:** None. This is a product and code teardown, not a user study.
**Date:** 2026-10-28

## Executive summary

Clicky is "an AI teacher that lives as a buddy next to your cursor". Its main idea is **presence**: a small glowing shape lives next to your pointer all the time, changes form to show what it's doing (listening, thinking, talking), and can **fly across the screen to point at things**. Voice is how you talk to it. You hold a key, speak, and it answers out loud.

Lina already has the brain for writing: it reads the draft through Accessibility, reflects on it, and rewrites sentences. What it lacks is Clicky's sense of being *beside* you. The biggest change is to move the companion from the **mouse pointer** to the **text caret**, because a writer looks at where the words are going, not where the mouse is. The shape should be Lina's own: a **drop of ink**, which matches the ink-and-paper brand and the caret bar in the wordmark.

## Key themes

### Theme 1: A buddy that lives where your attention is
**Evidence:** `OverlayWindow.swift`. Clicky draws a click-through overlay on every screen. A blue glowing triangle follows the mouse every 16 ms at an offset of (+35, +25), and a spring animation makes it trail slightly behind. It never takes focus.
**Implication:** Writers barely move the mouse while typing, so a pointer buddy would sit still in a corner. Lina's buddy should follow the **caret** (from Accessibility `kAXBoundsForRange`) and ride just above and to the right of it, like a superscript.

### Theme 2: One shape that shows every state
**Evidence:** The triangle, waveform and spinner stay in the view tree and cross-fade on `voiceState` (idle → listening → processing → responding). That way the buddy never "pops".
**Implication:** Lina's ink drop should breathe while resting, become an ink waveform while listening, and swirl while thinking. Then you can see what Lina is doing without opening anything.

### Theme 3: Pointing makes advice concrete
**Evidence:** The model adds `[POINT:x,y:label]` to its answers. The buddy flies along a quadratic Bézier arc (0.6–1.4 s, smoothstep easing, growing ~1.3× at the midpoint, turning to face its direction of travel), lands with a typed bubble ("right here!"), and flies back.
**Implication:** For writing, the thing to point at is a **phrase in the draft**. Lina's reflection already ends with "a thread to follow", so the model should quote that phrase, and the drop should fly to it and underline it in ink. Clicky points at pixel coordinates from a screenshot; Lina can use exact text ranges, so it needs no screenshot.

### Theme 4: Voice is the fastest way to answer
**Evidence:** You hold `⌃⌥` (a listen-only event tap), audio streams to AssemblyAI, and ElevenLabs speaks the reply. Replies are written "for the ear": short sentences and no lists.
**Implication:** Writers often think out loud. Holding `⌃⌥` to answer Lina's question, or to say "make this warmer" in Edit mode, fits well. To keep Lina private, use **on-device Apple Speech** instead of a cloud service, and **AVSpeechSynthesizer** for an optional read-aloud.

### Theme 5: Delight in small moments
**Evidence:** On first launch Clicky types "hey! i'm clicky" next to the cursor, one character every 30 ms. Bubbles pop in with a spring and a glow that settles.
**Implication:** A typed "hi, i'm lina" the first time, and typed one-line notes when the mode changes, cost little and make Lina feel alive.

### Theme 6: Where Clicky's choices don't fit Lina
**Evidence:** PostHog analytics, a Cloudflare key proxy, full-screen screenshots sent to the model, ElevenLabs/AssemblyAI keys, and a dark menu-bar panel.
**Implication:** Lina promises no telemetry and keeping text on your Mac when you want it to, so these are left out. Accessibility already gives Lina the exact text and its position, which is more precise than a screenshot.

## Insights → opportunities

| Insight | Opportunity | Impact | Effort |
|---|---|---|---|
| A companion feels present when it sits where you look | **Ink drop** riding above the text caret in any app and in the Desk | High | Med |
| One shape for every state reads at a glance | The drop breathes, swirls while thinking, becomes a waveform while listening | High | Low |
| Pointing turns advice into something you can see | **Show me**: the drop flies to the quoted "thread" and underlines it in ink | High | Med |
| Writers think out loud | **Hold ⌃⌥ to talk**: answer Lina (Understand) or tell it how to rewrite the sentence (Edit/Auto) | High | Med |
| Hearing a question lands differently from reading it | Optional **read Lina's question aloud**, on-device | Med | Low |
| Small typed moments create delight | Typed welcome and typed mode notes next to the drop | Med | Low |
| Analytics, cloud speech, screenshots | Leave out to keep Lina's privacy promise | — | — |

## Who this is for

| Segment | Characteristics | Needs |
|---|---|---|
| Reflective writers (journal, letters) | Long pauses, emotional material | A quiet presence, questions they can answer by voice |
| Working writers (email, docs) | Many short sentences, speed matters | Edit/Auto rewrites; a spoken instruction for one sentence |
| Privacy-minded writers | Use the "On this Mac" model | On-device speech, no screenshots, no analytics |

## Recommendations

1. **High priority: the ink drop at the caret.** This is the core of Clicky's concept, translated for writers (themes 1, 2 and 5).
2. **High priority: Show me (point and underline the thread).** This is Clicky's pointing, made exact with text ranges (theme 3).
3. **Medium priority: hold ⌃⌥ to talk, with on-device recognition.** It should also give spoken instructions in Edit and Auto (theme 4).
4. **Lower priority: read aloud.** Off by default (theme 4).

## Questions for further research
- Does a drop that is always visible distract during long writing sessions? Should it fade after a minute without typing, like Clicky's "transient cursor" mode?
- How often does the model's quote match the draft exactly? Fuzzy matching may be needed.
- Is `⌃⌥` free in writers' apps, or do any of them use it?

## Methodology notes
This comes from reading the source code (`OverlayWindow.swift`, `CompanionResponseOverlay.swift`, `CompanionManager.swift`, `GlobalPushToTalkShortcutMonitor.swift`) and the README and AGENTS.md, not from watching people use Clicky. Clicky's newest features are closed source and weren't reviewed.
