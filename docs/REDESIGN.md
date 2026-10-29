# Lina 2: the redesign

This is the plan behind the second version of Lina, written from the owner's notes on the first one.
Each section says what was asked, what Lina does now, and where the gaps were filled.

> **Update:** corrections now sit as small chips right above each mistake (⌘1, ⌘2… one, ⌘A all), after a pause
> you set in Settings. `/lina` stays in your own text but is marked as Lina's (tinted and underlined, with a small
> "↩ run" tag); Return runs it and never reaches the app, and the answer takes the command's place. It works in any
> field, including ones Lina can't read, like some web search boxes. People sign in with an emailed code; see
> [PRODUCTION.md](PRODUCTION.md).

## The idea in one line

Lina is a character who lives at your cursor in every app and **speaks only when you ask**.
You ask by typing `/lina …` and moving on with `,` `.` `?` `!` or Return, or by finishing a sentence.
Her answer appears in a small card under your line. **Nothing enters your text until you press ⌘1, ⌘2 or ⌘3.**

## 1. No companion window, no automatic reading

Asked: drop the floating companion and its "What I hear / Why you're writing it / A question / A thread"
reflections. Lina should never trigger herself; she should read only when asked, and when she does,
be short and direct, and "bother" the writer with meaningful questions.

Now:
- The companion window, its reflections and its auto-reading on every pause are gone.
- `/lina` on its own asks **one** question (under 20 words) about what you just wrote: a gap, an unstated
  reason, an assumption, an objection. No praise, no summary, no rewriting.
- The ⌥ Space shortcut does the same without typing.

Gaps filled:
- *When does `/lina` fire?* When you type the terminator and pause: 0.65 s after `.` `?` `!`, 0.9 s after `,`,
  almost at once after Return. Keep typing and it waits, so `/lina what is 3.5 percent of 80?` doesn't fire at `3.`.
- *What happens to the `/lina` text?* Commands that only control Lina (`/lina`, `/lina model`, `/lina help`,
  `/lina saved`) remove themselves when they run. Commands that produce text (search, rewrite, edit, fix, image)
  stay until you choose, and your choice replaces them.

## 2. No autocomplete; corrections instead

Asked: remove Tab-to-complete ghost text. Instead, show correction suggestions in a ghost-style view that highlights
typos, spelling and grammar mistakes, and lets the writer pick a fix with ⌘ + number.

Now:
- Autocomplete is removed entirely.
- When a sentence ends with `.` `?` or `!`, Lina checks that one sentence with the fast model (Nemotron 3 Nano).
  If it's clean she says nothing. If not, a card shows your sentence with each mistake colored and underlined
  (red spelling, amber grammar, blue punctuation), plus:
  - **⌘1 Fix**: only the mistakes fixed;
  - **⌘2 Smoother**: fixed and a little clearer, same meaning.
- Where the app reports text positions, Lina also draws wavy underlines **on your own text** under each mistake.
- `/lina fix` checks the whole paragraph on demand.

Gaps filled: one check per sentence (never repeated); checks don't interrupt a card you're still deciding on;
sentence checks can be switched off in the menu bar ("Check sentences").

## 3. Teaching with a caret under your text

Asked: teach the user how to use the app with a caret symbol under their original text.

Now: one-time tips appear under your words with a `^` pointing up at them:
- the first time you type `/` → how to ask Lina;
- the first time you type `/lina` → "I'm listening. End with . , ? or Return.";
- after your first finished sentence → that Lina checks sentences when you type a dot;
- after the first time something goes into your text → ⌘Z undoes it, and Saved keeps a copy.

Gaps filled: each tip shows once, at most one every few seconds, fades after 7 s, and can be turned off
or replayed (Settings → General, or Lina's window).

## 4. The Desk becomes Lina's window

Asked: remove the editor, pages and streak counter. Make the window show how to use the app with animated
demonstrations of wide use cases, show saved information, and later manage model providers, skills and plug-ins.
Make it interactive and focused on what makes Lina cool, not everything.

Now the Desk is gone (editor, pages, word goal, streak). The window called **Lina** has four pages:
- **Meet Lina**: her face cycling through moods, the "your words stay yours" rule, what each hair color means,
  every command, and buttons to open a practice page in TextEdit or replay the tips.
- **What she's good at**: six looping animated demos built from the real cards: catching typos, asking the web
  mid-sentence, a question that makes you think, rewriting in a tone, switching models, making a picture.
  Each says who it's for and what to type.
- **Saved**: every search (with sources), question, rewrite, edit, fix you applied, and picture. Searchable,
  filterable, copyable, deletable. Stored as one JSON file on the Mac.
- **Models & skills**: the providers in use (Token Factory, Gemini search, local), and a preview of skills and
  plug-ins planned for later (`/lina cite`, `/lina translate`, a style guide, Notion and Google Docs).

Onboarding is now: meet Lina → Accessibility → keys (Nebius, optional Gemini, each with a Connect check) →
three live demos → try it (opens a practice page in TextEdit).

## 5. Commands replace the rewrite palette

Asked: remove the palette and use command-style prompting like `/lina edit`, `/lina rewrite`.

| Command | What it does |
|---|---|
| `/lina.` | One question about what you just wrote. |
| `/lina fix.` | Checks the paragraph; ⌘1/⌘2 to apply. |
| `/lina rewrite [how].` | Three rewrites of the paragraph, e.g. `/lina rewrite warmer.`; ⌘1–⌘3. |
| `/lina edit <what to change>.` | One edited version, e.g. `/lina edit make it formal.` |
| `/lina model` | Lists Token Factory models (writing and image); ⌘1–⌘9 or ↑↓ ↩ to switch. |
| `/lina image <description>.` | A picture from FLUX; ⌘1 inserts it, ⌘2 copies it. |
| `/lina saved` | Opens Saved. |
| `/lina help` | Lists the commands in a card. |
| `/lina <anything else>,` | A web search, answered to fit your sentence. |

Gaps filled: rewrite and edit work on the text before the command on the same line, or, if the command is on
its own line, the paragraph above it. Synonyms are accepted (`imagine`, `draw`, `rephrase`, `proofread`, `history`).

## 6. Everything else is a search

Asked: `/lina what's happening with that football club,` is a search using Gemini's Google Search grounding
(key in `.env`), answered as ghost text that can replace the question and fits the surrounding words, triggered
after a comma or dot, and saved in history locally.

Now:
- Any `/lina …` that isn't a command word is a question. Lina sends Gemini the question plus the words before and
  after it, with Google Search grounding on, and asks for two things: a **fit** (words that can stand in place of
  the question) and a plain one-sentence **answer** for Saved.
- The card shows the fit and the source sites. **⌘1** replaces `/lina …` with it, keeping your comma or dot;
  **⌘2** adds the source in parentheses.
- Signed in, searches go through Lina's server. In development, the key comes from Settings, the environment, or
  `.env`: `GEMINI_API_KEY` (or `GOOGLE_API_KEY`). The model defaults to `gemini-3.5-flash-lite` with thinking kept low.
- Google's Search Suggestions are shown under every grounded answer, as Google's terms require.
- Without a Gemini key, the Nebius model answers from memory and the card says it wasn't checked against the web.

## 7. `/lina model`, including image models

Asked: `/lina model` lists Token Factory's models and switches between them, including text-to-image.

Now the card lists writing models (NVIDIA first) and image models separately. Picking a writing model changes the
model that answers commands; picking an image model changes what `/lina image` uses. Embedding, guard and speech
models are left out. `/lina model flux` filters the list. Sentence checks keep their own fast model (Settings → Models).

## 8. Lina, the character

Asked: redesign around a character called Lina with a realistic face in a Notion-style illustration, whose hair
color and expression act as signs for different states, especially in the menu bar and while listening.

Now Lina is drawn in code (black outlines, flat fills, side-swept bob) so she scales from 18 pt in the menu bar
to the hero in her window, and changes face and hair color with what she's doing:

| Mood | Hair | Face | When |
|---|---|---|---|
| Ready | ink violet | soft smile | On and quiet |
| Listening | blue | wide eyes, raised brows | You're typing `/lina …` |
| Thinking | lavender | eyes up, flat mouth | Checking, searching, writing options |
| Found something | amber | surprised "o" | A card is waiting for ⌘1/⌘2/⌘3 |
| Done | green | eyes closed, grin | Your choice went in |
| Needs you | red | worried | No access, no key, or a failed request |
| Paused | grey | asleep | Off, or paused in this app |

She appears in the menu bar, on every card, in tips, in onboarding and in her window.

## Not done yet

- The illustration is vector art drawn in code. A hand-drawn set by an illustrator would raise the quality further.
- Skills and plug-ins are shown as planned, not built.
- The images in `docs/screenshots` show the first version; regenerate them with `--snapshots` on a Mac.
- The app icon is now Lina's face (`scripts/make-icon.swift`). In an existing checkout, delete `build/AppIcon.icns` so the build script draws it again.
- Nothing here has been compiled yet: this environment has no Swift toolchain, and the macOS GitHub Actions job couldn't get a runner. Run `swift build && swift test` on a Mac first.
