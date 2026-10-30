# Lina demo video

Target length: **2:45** (the limit is 3:00). Record at 1920×1080 or larger, then upload to YouTube as **Public**.

The story in one line: *Lina lives at your cursor in every app and speaks only when you ask, and nothing goes into your text until you press ⌘1.*

---

## Before you record

**Mac**

- [ ] Turn on Do Not Disturb, hide the Dock (`⌥⌘D`), and use a plain wallpaper.
- [ ] Quit anything that might send a notification.
- [ ] Zoom Notes and Mail to 125% so the cards and chips are readable on a phone.
- [ ] Use light appearance.

**Lina** (click her face in the menu bar → Settings)

- [ ] **Models:** Nebius Token Factory with your key. Commands should be `nvidia/nemotron-3-super-120b-a12b` and checks `nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B`. Click **Test Connection**.
- [ ] **Search:** paste a Gemini key and click **Test Search**. If Gemini is rate-limited, turn on **Look things up on Wikipedia** as a backup.
- [ ] **General:** Lina on, check each sentence on, delay about 1.2 s, hold ⌃⌥ to talk on, *Ask me a question when I pause* off.
- [ ] **Memory:** turn on **Keep what I copy and screenshot**. Save one memory: in any app, type `/lina remember my sister's name is Noor and she's getting married in June` and press Return.
- [ ] Open Lina's window once and click through the tips so none appear on camera (or leave one for the "first time" shot).
- [ ] Grant microphone and speech access by holding ⌃⌥ once before recording.

**Windows ready, in this order**

1. Notes, with a new note called *Match report*
2. Mail, with a reply to *Sam*
3. Safari, open at <https://en.wikipedia.org/wiki/Apollo_11>
4. Notes, with a note called *Grandpa's summer*
5. Lina's window, on **What she's good at**

**Do one full dry run.** Model wording changes between runs, so if an answer lands flat, record that part again.

---

## Script

Voiceover is in quotes. On-screen actions are in brackets.

### 0:00–0:12 · The hook

[Lina's window, *Meet Lina*: her face cycling through moods.]

> "Most AI writing tools interrupt you. Lina waits until you ask. She lives at your cursor, in every app on your Mac."

### 0:12–0:45 · Ask the web mid-sentence

[Notes, *Match report*. Type: `The 2022 World Cup final ended /lina who won and how` and press Return.]

> "I type /lina and my question right where the fact belongs. Lina marks it as hers. She runs NVIDIA Nemotron on Nebius Token Factory, with Google search for live facts."

[The card appears under the line with the answer and sources. Press `⌘1`.]

> "Nothing goes into my text until I press Command-1. Then the answer takes the question's place, worded to fit my sentence."

### 0:45–1:05 · Catching typos

[On a new line, type: `Thank you for you're help, I realy apreciate it.` and stop.]

> "When I finish a sentence and pause, she checks it. The right word sits right above each mistake."

[Chips appear. Press `⌘A`.]

> "Command-A takes them all."

### 1:05–1:30 · A question, and a rewrite

[Mail, reply to Sam. Type: `I think I should take the new offer, even though I love my team.` then `/lina` and Return.]

> "On its own, /lina reads what I wrote and asks one question, the kind a good friend would ask."

[The question card appears. Read it. Press `esc`.]

[Type on a new line: `send me the report now` then ` /lina rewrite polite` and Return. Three options appear. Press `⌘2`.]

> "Or three rewrites in the tone I want. I pick one with a number."

### 1:30–1:50 · Talk to her, and she remembers

[Still in Mail, on a new line. Hold `⌃⌥` and say: *"write two warm lines congratulating my sister on her wedding"*. Let go.]

> "I can just say it. Hold Control-Option and talk."

[The command types itself in and runs. The choices card names Noor. Press `⌘1`.]

> "And she knows my sister is Noor, because I asked her to remember."

### 1:50–2:15 · Writing from research

[Safari, Apollo 11 page. Copy the sentence about the landing date. Press `⌃⇧⌘4` and screenshot the infobox.]

> "While I research, Lina keeps what I copy and reads my screenshots, on my Mac."

[Notes, *Grandpa's summer*. Type: `The summer my grandfather turned twelve,` then `/lina gathered` and Return. Press `⌘1`.]

> "Then /lina gathered writes from my real research instead of guessing."

### 2:15–2:30 · A picture

[New line: `/lina image a boy watching the moon landing on a small TV, 1969` and Return. The picture appears. Press `⌘1`.]

> "She can draw too, with FLUX on the same Token Factory key."

### 2:30–2:45 · Close

[Browser: <https://sppdd.github.io/lina/>, scroll to the Download button.]

> "Lina. She speaks only when you ask. Free and open source at sppdd.github.io/lina."

---

## Text to type (or paste most of, then type the end)

Lina reacts to what you type, so paste the start if you like, but type the `/lina …` part and the Return on camera.

```
The 2022 World Cup final ended /lina who won and how
```

```
Thank you for you're help, I realy apreciate it.
```

```
I think I should take the new offer, even though I love my team. /lina
```

```
send me the report now /lina rewrite polite
```

```
The summer my grandfather turned twelve, /lina gathered
```

```
/lina image a boy watching the moon landing on a small TV, 1969
```

---

## Recording tips

- **Tooling:** QuickTime (`⇧⌘5` → Record Selected Portion) is enough. Screen Studio or CleanShot add automatic cursor zoom, which helps because cards and chips are small.
- **Record each section as its own clip** and cut them together.
- **Zoom in** on cards and chips while editing (150–200%).
- **Voiceover after.** Record the screen first, then read the script over it.
- **Captions:** upload the script as YouTube subtitles.
- **Thumbnail:** Lina's face next to the answer card, with the words "Speaks only when you ask".

## If something goes wrong on camera

| Problem | Fix |
|---|---|
| The command isn't tinted | Lina needs Accessibility: click her face → **Grant Access**, then click back into the field. |
| "Lina isn't connected yet" | Add the Nebius key in Settings → Models and click **Test Connection**. |
| Search says it's busy | Gemini is rate-limited. Wait a minute, or turn on Wikipedia in Settings → Search. |
| No chips after a sentence | End it with `.` `?` or `!` and stop typing for the delay you set. Each sentence is checked once. |
| Talking does nothing | Hold ⌃⌥ alone for half a second before speaking. Check microphone access in System Settings. |
| `/lina gathered` says nothing's gathered | Gathering starts when you turn it on. Copy the quote again. |
| Anything else | Type `/lina bug` and a few words, and the report lands in `~/Library/Logs/Lina/reports`. |
