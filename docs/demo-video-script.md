# Demo video voiceover script — 1.0 (3)

Written for the 2026-08-12 recording (pair from the Mac → open a codebase
→ pick a model → run a prompt). Two minutes at a normal 150 words-a-minute
pace; the spoken text below is ~300 words, so there is room to breathe.

Read it slowly and flatly. This is evidence for a reviewer, not marketing —
every sentence exists to answer a question they would otherwise have to ask.

Say the words **iPhone**, **physical device**, and **permission** out loud.
The rejection was about all three, and a reviewer skimming at 1.5× should
still hear them.

---

## The script

**0:00 — 0:15 · What this is**
> *On screen: the iPhone in hand, or the app's home screen, status bar visible.*

Hello. This is Remote for OpenCode, version 1.0, build 3, recorded on a
physical iPhone. It's a remote control for OpenCode — a coding agent that
runs on the user's own Mac. The phone doesn't run any code. It sends
prompts to the Mac and shows what comes back.

**0:15 — 0:40 · Pairing, and the Local Network prompt**
> *On screen: Mac menu bar → "Pair iPhone…", then cut to the iPhone.*

The Mac runs a free companion app, in the menu bar. I choose Pair iPhone.
On the phone, iOS asks for Local Network permission — that's the only
required permission, and it's the phone talking to my Mac and nothing
else. Both screens now show the same six-digit code. I confirm it, and
they're paired. There's no account and no server in between; the two
devices exchange keys through my own iCloud and talk directly,
end-to-end encrypted.

**0:40 — 1:00 · The codebase**
> *On screen: the repository list, then one repository opened.*

Now the phone can see the code projects on that Mac. I'll open one. Every
file stays on the Mac — the phone is only ever showing me text it sends.

**1:00 — 1:15 · Choosing a model**
> *On screen: the model menu in the composer.*

Here I pick which AI model to use. These are the user's own providers,
configured on their Mac with their own credentials. Those keys never leave
the Mac, and the phone never sees them.

**1:15 — 1:35 · The prompt**
> *On screen: typing, sending, the reply streaming in.*

I type a prompt and send it. The agent works on the Mac, and the answer
streams back to the phone as it's generated — the reasoning, each step,
and the result.

**1:35 — 1:50 · Approval**
> *On screen: the approval card, with the exact command visible.*

When the agent wants to run a command, it has to ask. I see the exact
command before anything happens, and I choose: allow once, always, or
reject. Nothing runs on the Mac without this, and nothing runs on the
phone at all.

**1:50 — 2:00 · Review and close**
> *On screen: the per-file diff view, then hold on the home screen.*

And this is the review screen — every change the agent made, file by file,
so you can read it before you accept it. That's the whole app: pair, ask,
approve, review. Thank you.

---

## Optional extra beat (if you re-record and want the runtime)

Slot after the approval beat, ~12 seconds. It covers the three optional
permissions Apple asked to see documented; if it doesn't fit in the video,
the Notes field already lists them in writing.

> *On screen: tap the microphone in the composer, then the attach button.*

Two optional permissions, both off unless you use them. Dictation asks for
the microphone and speech recognition — the transcription happens on the
phone, and the audio never leaves it. Attaching a photo asks for the
camera; the picture goes to my Mac and nowhere else.

---

## Recording notes

- **Don't crop the status bar or the corners.** They are what distinguishes
  a physical iPhone from a simulator, which is the entire point of the
  resubmission. Opening on a shot of the phone in your hand settles it in
  three seconds.
- **Delete the app before recording** so the Local Network prompt actually
  fires. It only appears on the first pair.
- **Keep the iPhone as the main frame.** Mac footage belongs in the pairing
  beat only. If the video is mostly a Mac screen, it does not answer the
  request.
- **Don't cut the permission dialogs**, even though they're dead air. Apple
  asked for them explicitly.
- Real repository, real prompt, real output. A prompt that produces both a
  command approval *and* a file edit exercises the whole flow in one turn.
- No music. A reviewer may be watching muted with captions, so the on-screen
  actions have to carry the story on their own.
