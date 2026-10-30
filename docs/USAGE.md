# How to use Lina

Lina lives in your menu bar and works in almost any app you write in: Notes, Mail, Pages, TextEdit, Safari, Obsidian and Lina's own **Desk**. This guide walks through every feature, with examples you can try straight away.

- [Before you start](#before-you-start)
- [The ink drop](#the-ink-drop)
- [Three modes: Understand, Edit, Auto](#three-modes-understand-edit-auto)
- [Talking back to Lina](#talking-back-to-lina)
- [`/lina` commands](#lina-commands)
- [Memory](#memory)
- [Other tools](#other-tools)
- [Reporting a problem](#reporting-a-problem)
- [Shortcuts](#shortcuts)
- [Good to know](#good-to-know)

---

## Before you start

1. **Build and open Lina.**
   ```sh
   scripts/build-app.sh --open
   ```
   If an older Lina is already running, quit it from the menu bar first (**Quit Lina**, `⌘Q`). Then run `open build/Lina.app`.
2. **Grant Accessibility access** when the welcome screen asks. Lina uses it to read the text field you're typing in and to find your cursor. If Lina keeps saying access is missing, click **Grant Access** in the menu bar.
3. **Add a model.** Paste your Nebius Token Factory API key in **Settings → Model**, or pick **On this Mac** and point Lina at Ollama or LM Studio.

Check that it works: open TextEdit, click into a new document and start typing. A small drop of ink should appear just above your cursor.

---

## The ink drop

The drop is how Lina is present while you write. It follows your text cursor, not your mouse.

| What you see | What it means |
|---|---|
| The drop breathing | Lina is resting and reading along. |
| A spinning swirl | Lina is thinking, rewriting or working on a command. |
| Moving bars | Lina is listening to you speak. |
| The drop flies to your words and underlines them | That's the thread Lina thinks you should follow. |
| A dark card above the drop | What Lina has to say: its reading of your draft, a rewrite, or progress on a command. |

The card steps aside as soon as you type or press `esc`. Near the top of the screen it appears below your cursor instead.

To switch the drop off, use **Settings → General → Presence**. Lina then shows its thoughts in a popup instead.

---

## Three modes: Understand, Edit, Auto

Press `⇧⌥ Space` to cycle through the modes. The drop types the new mode's name beside your cursor so you know which one you're in.

### Understand (the default)

Lina reads along and thinks with you. **It never changes your document.**

**Try it.** In TextEdit, write a few sentences and then stop for a couple of seconds:

> I keep meaning to call my dad. Every Sunday I tell myself I will, and every Sunday I find something else to do. The shop has been busy and mom says he's tired.

A card appears above your cursor:

> **LINA HEARS**
> You keep circling the call but filling the space with reasons — the shop, your mom, his tiredness.
> **What would you say in the first ten seconds if he picked up?**

Keep typing and the card disappears. To answer, press `⌥ Space` to open a reply box, or [hold `⌃⌥` and say it](#talking-back-to-lina).

### Edit

Lina offers a cleaner version of each sentence you finish. **You decide whether to use it.**

**Try it.** Switch to Edit (`⇧⌥ Space` until the drop says *edit*), then type a sentence with mistakes and end it with a period:

> i dont know why i keep putting off calling him, its not like hes going anywhere.

After a short pause, a card shows your sentence crossed out and Lina's rewrite under it:

> ~~i dont know why i keep putting off calling him, its not like hes going anywhere.~~
> I don't know why I keep putting off calling him; it's not as if he's going anywhere.

- Press `⇥` (Tab) to use the rewrite.
- Press `esc` to keep yours.
- Press `⌥ Space` to rewrite the sentence at your cursor right away, even an unfinished one.

### Auto

Lina rewrites each sentence you finish **by itself**, in place. `⌘Z` undoes it like any other edit. Use Auto when you want to write fast and messy and tidy up as you go.

> Lina only rewrites a sentence it can find exactly as it read it. If you've already typed more, it leaves the text alone.

---

## Talking back to Lina

**Hold `⌃⌥` (Control + Option), speak, then let go.** The drop turns into moving bars while it listens.

| Mode | What your voice does | Example |
|---|---|---|
| Understand | Answers Lina's question | *"I'd tell him I'm sorry I've been distant."* |
| Edit / Auto | Says how to rewrite the sentence at your cursor | *"make it warmer"*, *"shorter"*, *"more formal"* |

The first time, macOS asks for microphone and speech recognition permission. Speech is recognized on your Mac when your language supports it.

To have Lina's questions read aloud, turn on **Settings → General → Read Lina's questions aloud**.

---

## `/lina` commands

Type `/lina` followed by what you want, anywhere you write, then press **Return**. Lina does it right there, in your document.

### What "this" means

Lina works on:

- **The text before the command on the same line**, if there is any:
  ```
  their going too the park tomorow /lina fix this
  ```
- **Otherwise, the paragraph just above the command:**
  ```
  We got to the cabin late. The road was washed out and we walked the last mile in the dark.
  /lina make this more vivid
  ```

### Edit text in place

| You type | What happens |
|---|---|
| `their going too the park tomorow /lina fix this` | The line becomes *They're going to the park tomorrow.* |
| *(paragraph)* then `/lina edit this paragraph` on the next line | The paragraph is rewritten and the command disappears. |
| `/lina make this shorter` | The paragraph above is tightened. |
| `/lina translate this to Spanish` | The paragraph above is replaced by its translation. |
| `/lina turn this into a bullet list` | The paragraph becomes a list. |

### Write something new

When the instruction asks for new writing, Lina puts it **where the command was**:

| You type | What happens |
|---|---|
| `/lina write a closing line for this email` | A closing line appears in place of the command. |
| `/lina give me three title ideas` | Three titles appear. |
| `/lina write a haiku about rain` *(in an empty document)* | A haiku appears. |
| `/lina continue this story for two sentences` | Two new sentences follow your paragraph. |

### Turn words into a picture

Describe a scene, then ask for a picture:

```
A narrow kitchen at dawn. Steam rises from the kettle and the window is fogged, with a cat asleep on the sill.
/lina turn this description to a photo
```

Lina writes an image prompt from your description, draws it with Token Factory (FLUX schnell by default) and pastes the picture where the command was. Words like *photo, picture, image, drawing, sketch, illustration* and *draw* all trigger this.

- Every picture is also saved in `~/Pictures/Lina`.
- Apps that can't hold pictures, such as plain-text fields and the Desk, get a link to the file instead.
- You can change the image model in **Settings → Model → Pictures**.

> **Right now:** Token Factory answers `404` for image generation on this account. Lina shows *"Token Factory isn't serving pictures … right now"* until Nebius turns it back on or you pick a model that works.

### Remember something

| You type | What Lina saves |
|---|---|
| *(paragraph)* then `/lina remember this` | The paragraph above |
| `/lina remember that I write in British English` | *"I write in British English"* |
| `/lina save this to memory` | The paragraph above |

### While a command runs

- The card above the drop shows what Lina is working on.
- Press `esc` to stop it.
- When it's done, the drop says *done · ⌘Z undoes*. Press `⌘Z` if you don't like the result.
- If you changed that part of the text in the meantime, Lina leaves it alone and tells you.

> **Tip:** to start a normal new line without running the command, press `⇧ Return` or `⌥ Return`.

---

## Memory

Lina can remember things about you and your writing, and uses them every time it thinks or writes for you.

**Highlight text in any app and press `⌃⌥ M`.** The drop says *saved to my memory*.

Examples worth saving:

- *"My sister's name is Noor. She lives in Lisbon."*
- *"I'm writing a memoir about my grandmother's bakery."*
- *"Never use the word 'delve'."*

Then a command like `/lina write a short birthday message for my sister` already knows her name.

To review or delete what Lina remembers, open **Settings → Memory**. Each memory shows where it came from and when. Memories are stored only on your Mac, in `~/Library/Application Support/Lina/memory.json`.

---

## Other tools

| Tool | How to open it | What it's for |
|---|---|---|
| **Rewrite palette** | Menu bar → **Rewrite with Lina…** | Keep going, Find the word, Fix grammar, Say it clearer, Give it feeling, Tighten, I'm stuck, Look it up, or your own instruction. `↩` replaces, `⌘↩` inserts after. |
| **Ghost text** | **Settings → General → Ghost text at the cursor** (off by default) | A short continuation in grey after you pause. `⇥` keeps it, `⌥⇥` keeps one word, `esc` dismisses it. |
| **The Desk** | Menu bar → **Open Desk** | A calm writing space with typewriter scrolling and a focus mode. Everything above works here too. |
| **Show me where** | The `⌥ Space` reply box, under a reflection | Flies the drop back to the words Lina thinks matter. |

---

## Reporting a problem

When something goes wrong, you don't have to explain it well. Lina writes the report for you.

### Option 1: right where it happened (best)

Type `/lina bug` and a few words, then press Return:

```
/lina bug the drop disappeared when I clicked into the subject line
/lina bug it rewrote the sentence before the one I meant
/lina bug nothing happened when I pressed return
```

Lina takes out the command and records that exact moment.

### Option 2: from the menu bar

1. Click Lina's menu bar icon, then **Report a Problem…**
2. Pick what's closest, for example *"It changed the wrong text"*.
3. Add a few words if you like. They're optional.
4. Click **Create Report**.

### Then

The report is copied to your clipboard and saved to `~/Library/Logs/Lina/reports/latest.md`. It is also sent to the Lina team, so you don't have to paste it anywhere. To keep reports on your Mac only, untick **Also send it to the Lina team** in the report window, or switch off **Settings → General → Problem reports**.

In Claude Code, you can also just say:

> read my latest Lina report

The report contains your setup, the shape of the text field you were in (the app, the kind of field, whether Lina could find the cursor) and Lina's last decisions and errors. **It never contains what you wrote.**

---

## Shortcuts

| Shortcut | What it does |
|---|---|
| `⌥ Space` | Open the reply box (Understand), or rewrite the sentence at the cursor now (Edit, Auto) |
| `⇧⌥ Space` | Switch mode: Understand → Edit → Auto |
| Hold `⌃⌥` | Talk to Lina |
| `⌃⌥ M` | Remember the highlighted text |
| `/lina …` then `↩` | Run a command where you write |
| `⇥` | Use Lina's rewrite, or keep ghost text |
| `⌥⇥` | Keep one word of ghost text |
| `esc` | Dismiss the card or stop a command |
| `⌘Z` | Undo anything Lina wrote |

If `⌥ Space` clashes with another app, change it in **Settings → General → Shortcuts** to `⌃ Space` or `⇧⌘ L`. The mode shortcut follows the change.

---

## Good to know

- **Return in chat apps:** in Slack, Messages and similar apps, Return after a `/lina …` command runs the command instead of sending the message.
- **Paused apps:** Lina stays out of password managers, Keychain Access, Terminal and iTerm by default. You can change the list in **Settings → Apps**. It never reads password fields.
- **Apps where the drop doesn't appear:** some apps don't tell macOS where the cursor is, so the drop can't follow it there. File a `/lina bug` and the report will show it.
- **`⌃⌥` shortcuts:** holding `⌃⌥` with another key (such as `⌃⌥→`) is treated as a shortcut, not talking, so your existing shortcuts keep working.
- **Privacy:** with **On this Mac**, nothing leaves your Mac except picture requests, which always go to Token Factory, and problem reports you create, which go to the Lina team unless you switch that off. Reports never contain what you wrote. Your API key, memory and logs are stored in files only your user account can read.
