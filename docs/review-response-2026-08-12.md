# Review response — 2.1 Information Needed (2026-08-12)

Submission `a7b3e147-49d0-4b86-ac6c-20a91c96d211`, version 1.0 (3),
reviewed on iPad Air 11-inch (M3).

Two asks, both answerable without a code change:

1. A demo video of 1.0 running on a **physical** iOS device, linked from
   App Review Information → Notes.
2. A written answer to: *"is the app designed to teach, develop, or test
   executable code?"* — the standard 2.5.2 / 4.7 screening question.

Note the review device: the app is iPhone-only
(`TARGETED_DEVICE_FAMILY: "1"`), so it ran in iPhone compatibility mode on
an iPad. That is not itself a problem, but it means the reviewer saw a
scaled window with no Mac in the room and nothing to pair to — which is
exactly the failure mode `app-store.md` predicted. The video is the fix.

---

## A. App Review Information → Notes — **already live in ASC**

Written into App Review Information → Notes on the 1.0 version page and
saved on 2026-08-12. Reproduced here as the record; you should not need to
paste it. **3,963 of the 4,000 characters are used** — 37 to spare, so any
edit has to trade, and the field's counter shows *remaining*, not used.

Two things shaped it beyond Apple's asks:

- The previous notes carried a **"NO VPN" paragraph** explaining why the
  binary contains the strings `utun` and `ipsec` (the app *excludes* VPN
  interfaces when choosing which address to advertise). That plainly
  answered an earlier reviewer concern, so it was merged forward rather
  than overwritten. Do not drop it to make room.
- The video link is still a placeholder:
  `[VIDEO URL - TO BE ADDED BEFORE SUBMITTING]`. It must be replaced with
  an unlisted, no-login, no-expiry link before resubmitting. Apple will not
  create accounts or follow links behind a sign-in wall.

```text
DEMO VIDEO (version 1.0, build 3): [VIDEO URL - TO BE ADDED BEFORE SUBMITTING]

Recorded 12 August 2026 as a screen recording on a PHYSICAL iPhone running the exact build submitted here - no simulator footage. This video is valid for all storefronts: the app has no region-specific content, behaviour, or pricing, and is free everywhere.

WHAT THE VIDEO SHOWS
0:00 Mac companion in the menu bar; choose "Pair iPhone"
0:20 iPhone: Local Network permission prompt, then the 6-digit code confirmed on both screens
0:40 iPhone: the list of code repositories on the paired Mac; one is opened
1:00 iPhone: choosing which AI model to use (the user's own providers, configured on their Mac)
1:15 iPhone: typing a prompt and sending it; the reply streams back from the Mac
1:35 iPhone: an approval card - the exact command shown, with Allow Once / Always / Reject
1:50 iPhone: the per-file diff view for reviewing the agent's changes

IS THE APP DESIGNED TO TEACH, DEVELOP, OR TEST EXECUTABLE CODE?
No. The app is a remote control and a viewer, closest in kind to a remote-desktop or SSH client. It contains no interpreter, compiler, runtime, console, or scripting engine. It never downloads, installs, or executes code on the iOS device, and nothing it displays can change its own features. On the iPhone it only: sends the user's typed or dictated text to their own Mac; renders text, Markdown and diffs the Mac sends back; and shows approval prompts and returns the user's yes/no answer. The OpenCode agent on the user's Mac may edit files in that user's own project, and the user may run them there, in software they installed and control. That is the Mac's behaviour, not the app's, and it happens only after the user reads the exact command and taps Allow.

WHY A DEMO VIDEO IS NEEDED
This app is a remote control for OpenCode (opencode.ai), a coding agent the user installs and runs on their own Mac. Without a paired Mac it can only show its pairing screen. Using it requires (1) a Mac running our free companion app (remoteforopencode.com), (2) OpenCode installed there with the user's own model-provider credentials, and (3) both devices signed into the same iCloud account, which is how they find each other with no network configuration. We cannot supply a demo account because there are no accounts and no servers of ours: pairing exchanges public keys through the user's own iCloud private database and confirms a 6-digit code on both screens, and all traffic is end-to-end encrypted directly between the two devices. If the review team has a Mac available, we are glad to arrange a live walkthrough. Please ask.

PERMISSIONS AND WHY THEY APPEAR
Local Network - required, at first pairing: the phone connecting to the user's own Mac. Camera - optional, only to attach a photo to a prompt; the image goes to the user's Mac and nowhere else. Microphone and Speech Recognition - optional, only to dictate a prompt; recognition is on-device and the audio never leaves the phone. Face ID - optional, to confirm identity before approving a command. Notifications - optional, to be told when the agent needs an approval.

No account, login, or subscription is required. The app collects no data of any kind: no analytics, no telemetry, no third-party SDKs. The only network destinations are the user's own Mac and their own iCloud.

NO VPN: This app contains no VPN functionality - no NetworkExtension framework, no NEVPNManager/NEPacketTunnelProvider code, no VPN entitlements, no configuration profiles, and no routing or proxying of device traffic. It connects the iPhone directly to the user's own Mac via Bonjour on the local network, or UDP hole punching with STUN address discovery when the devices are apart. The binary contains interface-name strings such as "utun" and "ipsec" solely because the app EXCLUDES VPN tunnel interfaces when selecting which of its own addresses to advertise to the paired Mac. The app never creates, configures, or joins a VPN.
```

## B. Reply to send in App Store Connect

```text
Thank you for the review.

We have added a demo video link to the Notes field in App Review
Information. It was recorded on 12 August 2026 as a screen recording on a
physical iPhone running version 1.0, build 3 — no simulator footage — and
it shows the full flow: pairing with the Mac companion, the Local Network
permission prompt, opening a code repository, choosing a model, sending a
prompt and receiving the streamed reply, the command-approval card, and
the diff review screen. The Notes field also lists every permission the
app requests and why. The video is valid for all storefronts; the app has
no region-specific content, behaviour, or pricing.

On your question about executable code: no, the app is not designed to
teach, develop, or test executable code on the device. It is a remote
control for OpenCode, a coding agent the user installs and runs on their
own Mac — the same relationship a remote-desktop or SSH client has with
the computer it connects to. The iPhone app contains no interpreter,
compiler, runtime, console, or scripting engine; it never downloads,
installs, or executes code; and nothing it displays can alter its own
features. It sends the user's typed text to their Mac and renders the text
and diffs that come back, plus approval prompts the user must answer
before the Mac runs any command.

Work on the code itself happens on the user's Mac, in software they
installed and control, under their own model-provider account. The app has
no ability to execute anything, and no server of ours sits in between —
the two devices talk directly, end-to-end encrypted.

We would also note that the app was reviewed on an iPad Air. It is an
iPhone-only app, and it requires a paired Mac running our free companion
(https://remoteforopencode.com) to do anything at all, which is why the
pairing screen is as far as it can get on its own. If your team has a Mac
available we are happy to arrange a live walkthrough — setup takes about
five minutes.

Please let us know if anything further would help.
```

---

## Standing obligation

Apple's note is explicit: *"if the app can only be reviewed with a demo
video, updated demo videos will need to be provided for every app
submission."* Re-record, or re-confirm validity in the Notes field, on
every submission from now on. If nothing user-visible changed, the
one-line form is:

```text
The demo video linked above remains accurate for this build and is valid
for all storefronts. No user-facing changes since the previously reviewed
version.
```

## Before pasting — check the video

The rejection is specifically about *physical device* evidence, so the
recording has to look like one:

- **The iPhone screen must be the spine of the video.** Mac footage is
  fine for the pairing step, but if the majority of the runtime is a Mac
  window, this reads as "not demonstrated on iOS" and comes back again.
- **Show it is real hardware.** An iPhone screen recording carries the
  status bar, real battery and carrier, rounded corners and the Dynamic
  Island — a simulator does not. Do not crop those away. A few seconds of
  camera footage of the phone in hand at the top removes all doubt.
- **Permission prompts must be on screen**, not edited out. Apple asked
  for them by name. The Local Network prompt only appears on first pair,
  so record from a fresh install or after deleting the app.
- Unlisted link, no login, no expiry. Keep it live for the whole review.

---

## Listing fields, verified in ASC on 2026-08-12

Checked field by field while updating the notes. Most of the checklist in
`app-store.md` had already been done and was still marked open there:

| Field | State |
|---|---|
| App name | `Remote for OpenCode Agents` — rename propagated |
| Subtitle | `Remote for your coding agent` — post-5.2.5 wording, intact |
| Primary category | Developer Tools; no secondary |
| Keywords | `opencode, coding agent, ai, remote, developer, cli, code, automation, agent, open source` — no `mac`, as intended |
| Support URL | `github.com/tjameswilliams/remote-for-opencode` |
| Marketing URL | `remoteforopencode.com` — off the old domain |
| Privacy Policy URL | `remoteforopencode.com/privacy` — off the old domain |
| App Privacy | Published, **Data Not Collected** |
| Screenshots / previews | Uploaded, showing the post-rename wordmark |
| Build attached | **3** — the build Apple reviewed |
| Release | Manual |
| App Review notes | **Rewritten and saved** (3,963 / 4,000 chars) |

Nothing needed changing except the notes. No new build is required: this
is an information-only rejection against build 3, so the same build is
resubmitted with new notes.

## What is deliberately NOT done

- **The video URL is a placeholder.** Replace
  `[VIDEO URL - TO BE ADDED BEFORE SUBMITTING]` in the notes.
- **The reply to Apple has not been sent.** Text is in section B; it
  should go out *after* the URL is in, since it claims the link is there.
- **"Update Review" has not been clicked.** Resubmitting is the last step,
  after both of the above.
