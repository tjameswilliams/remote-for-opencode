# Marketing strategy: Remote for OpenCode

Written 2026-08-15, from market research across HN, Reddit, Discord, X, and
competitor sites. Style rule for everything here and everything derived from
it: no em dashes, ever.

## The one-line position

**"No server. Not even ours."**

Every competitor is attackable on exactly one axis, and it is the axis we
own. The market's loudest, most repeated objection (verbatim from HN threads
on Omnara and Happy Coder) is "why does my code go through your server?"

- Happy Coder: E2EE, but through their relay; a community security review
  found API keys stored via `happy connect` are readable by the server
  operator (slopus/happy discussion #680). Users on HN call it abandoned.
- Omnara: founders admitted on HN that "all the messages are stored in our
  DB." $9 to $20 a month. HN comments: "No way I'm sending my code to your
  central servers."
- Anthropic Remote Control (Claude Code only): transcripts stored on
  Anthropic servers, paid subscription required.
- Codex mobile (OpenAI): relay through OpenAI, Codex only.
- Every other OpenCode mobile client (WhisperCode, OpenCoderMan, OpenCodeM,
  opencode-webui, and a dozen more): thin clients that require the user to
  expose `opencode serve` themselves via LAN, Tailscale, or a tunnel, with
  the OpenCode docs warning the server is unsecured without a password.
- Paseo (closest competitor: free, OSS, supports OpenCode): defaults to an
  E2EE relay service and positions as a multi-agent orchestration platform,
  not a polished single-purpose iPhone remote.

We are the only product where there is no third party in the loop at all:
iPhone and Mac pair through the user's own iCloud account, then talk
directly, end-to-end encrypted. No relay, no account, no telemetry, nothing
to subscribe to, nothing to get breached. The App Store privacy label
("does not collect any data") and the public source make the claim
checkable, which is exactly what HN and lobste.rs demand.

### Message pillars, in order

1. **No server, not even ours.** Pair through your own iCloud, then direct
   E2EE between your two devices. (The security story; wins HN.)
2. **Zero network setup.** No Tailscale, no tunnels, no `--hostname
   0.0.0.0`, no password env vars. Confirm a six-digit code, done. (The
   practical story; wins the OpenCode Discord and subreddit.)
3. **Native Swift on both ends.** Not Expo, not Flutter, not a PWA that iOS
   kills in the background. The 1.5 MB App Store download is a concrete
   proof point.
4. **Built for supervising an agent, not a terminal in your pocket.**
   Risk-graded approvals with Face ID, plan mode, line-by-line diff review,
   push notifications whose payloads contain no content.
5. **Free with no catch.** State the license up front to pre-empt the
   "what's the hidden business model" suspicion that hit Happy and Omnara.

### Claims discipline

- Do NOT claim "the only mobile client for OpenCode." The field is crowded
  and the audience knows it. The defensible superlative: **the only one
  with no server anywhere in the path and nothing to configure.**
- Do NOT claim "open source" while the license is PolyForm Noncommercial.
  Say "free and source-available." HN will check the LICENSE file within
  minutes and a corrected claim costs more credibility than the weaker
  word. If we want the "completely open source" position (and it is a
  genuinely stronger one in this market: Happy is MIT, Paseo and Omnara are
  OSS), the move is to relicense to MIT or Apache 2.0 first. Decision
  pending.
- Against Paseo specifically: "orchestration platform with an optional
  relay and Hub" versus "a premium, single-purpose remote that works in 60
  seconds with nothing but your Apple ID."

## Channels, in launch order

1. **r/opencodeCLI** (the proven launchpad; WhisperCode's launch post did
   156 upvotes / 66 comments). Format that works: "I built..." plus what is
   different, screenshots or a short video, GitHub link, and stay in the
   comments all day. There is also r/opencode; post to one, crosspost
   carefully a day later.
2. **OpenCode Discord** (discord.gg/opencode, ~75k members, ~9.6k online).
   Post in the showcase/community channel, frame as "I built a native iOS
   remote for OpenCode, free, no server involved," answer questions, do not
   drive-by link-drop.
3. **Show HN.** Title: "Show HN: Remote for OpenCode – drive the coding
   agent on your Mac from your iPhone (no servers)". First comment explains
   the architecture and motivation and answers the relay objection before
   anyone raises it. Norms: factual title, no marketing language.
4. **X/Twitter.** Short demo video. Tag @opencode; @thdxr (Dax, OpenCode
   creator) and @adamdotdev actively amplify ecosystem tools. OpenCode
   claims ~650k MAU, so the ecosystem press cycle is warm.
5. **Product Hunt.** Omnara did 452 upvotes there; the category works.
   Needs gallery assets and launch-day presence. Schedule after the
   Reddit/HN/Discord wave so momentum and reviews exist.
6. **console.dev** (free weekly devtools newsletter, reviews 2 or 3 tools a
   week, public selection criteria that we meet). Submit the site.
7. **lobste.rs.** Anti-hype crowd; what lands is a technical blog post on
   the transport (how CloudKit-brokered pairing plus direct E2EE works),
   tagged `show`, not a product pitch. Write the post first, then submit.
8. **YouTube reviewers.** The OpenCode tutorial scene has six-figure view
   counts; Theo and ThePrimeagen both cover agent GUIs. A tight 60-second
   demo video is the asset that makes coverage likely.

## Post drafts

### Show HN first comment (post immediately after submitting)

> Author here. I built this because every way I found to steer OpenCode
> from a phone involved trusting somebody's relay server or doing
> networking homework (Tailscale, tunnels, exposing `opencode serve` and
> hoping).
>
> Remote for OpenCode has no server, including ours. The Mac companion and
> the iPhone app pair through your own iCloud account (CloudKit stores only
> public keys and device names), then the devices talk directly,
> end-to-end encrypted with keys only they hold. The companion keeps
> `opencode serve` bound to localhost and is the only gateway to it.
>
> The phone side is built for supervising an agent rather than being a
> terminal: risk-graded command approvals (an `rm -rf` looks louder than a
> `git status`) with Face ID, plan mode, line-by-line diff review against
> your last commit or default branch, and push notifications whose
> payloads deliberately contain no content.
>
> Both ends are native Swift; the iOS app is a 1.5 MB download. Free, no
> account, no telemetry, source is public: [repo link]. Happy to answer
> anything about the transport.

### r/opencodeCLI launch post

Title: "I built a native iPhone remote for OpenCode. No server, no
Tailscale, no tunnels: your phone and Mac pair through your own iCloud and
talk directly, E2EE"

Body: what it does in three bullets, the 60-second setup (install cask,
install app, confirm six-digit code), screenshots of approvals and diff
review, App Store and GitHub links, and an honest "what it does not do yet"
section (invites contribution instead of nitpicks).

### Discord showcase blurb

> Built a native iOS remote for OpenCode and it just cleared App Store
> review. The different part: there is no server involved, not even mine.
> Phone and Mac pair through your own iCloud, then talk directly, E2EE.
> Zero network setup: no Tailscale, no exposing `opencode serve`. Free,
> source on GitHub. Would love feedback from people who drive OpenCode
> away from their desk. [links]

### X post

> Your Mac writes the code. Your phone holds the leash.
>
> Remote for OpenCode is out on the App Store: a native iPhone remote for
> the @opencode agent on your Mac. No servers (not even ours), no setup:
> pair through your own iCloud, talk directly, E2EE. Free.
> [demo video] [link]

## Share metadata (implemented 2026-08-15)

- og:image is a generated 1200x630 card (tools/mark/generate_og.py, 79 KB
  PNG, under WhatsApp's 600 KB limit, text inside the center safe area):
  wordmark lockup, tagline, phone screenshot bleeding off the bottom right.
  The genre-standard dev-tool card (Raycast, Linear pattern).
- Head tags shipped in Base.astro: og:title (site name kept out, per Apple
  TN3156), og:site_name, og:description, og:url, og:type, absolute
  og:image with width/height/alt, twitter:card summary_large_image,
  theme-color (Discord embed accent), apple-touch-icon 180px (iMessage
  icon), apple-itunes-app smart banner (app-id=6797660779, Safari shows a
  native App Store banner; Raycast does the same).
- After each deploy touching the card, re-scrape: Facebook Sharing
  Debugger (developers.facebook.com/tools/debug), LinkedIn Post Inspector
  (linkedin.com/post-inspector), Telegram @WebpageBot, paste in X composer
  to eyeball, paste in a private Discord/Slack to eyeball. Bluesky bakes
  the card into the post at compose time, so verify before announcing.

## First moves: the open threads (added 2026-08-15)

Do the launch post on r/opencodeCLI first, so every reply elsewhere has a
canonical thread to point at. Then, same day, answer the standing question
threads below. Etiquette for all of them: answer the actual question first,
acknowledge the alternatives honestly (WhisperCode and friends are known
quantities there), disclose "I built this," keep the pitch to two
sentences, and never paste the same comment twice (Reddit's spam filter and
the humans both notice). Use your real account, not a fresh one. Skim each
thread before posting in case someone already mentioned us.

Open asks worth answering, roughly newest first:

- "Official mobile remote control for opencode?"
  reddit.com/r/opencodeCLI/comments/1txewa0/ (exactly our pitch; the answer
  is "no official one, here is what exists, here is mine and why it is
  different")
- "I built a self-hosted mobile UI for OpenCode" (remotty)
  reddit.com/r/opencodeCLI/comments/1u3uuwq/ (fellow-builder thread; the
  OP's own complaint list about SSH on a phone is our pitch. Be collegial,
  not competitive: comment as a fellow traveler comparing approaches)
- "Remote Mobile Coding - Opencode Web, OpenChamber, Paseo"
  reddit.com/r/opencodeCLI/comments/1tg8dai/ (a comparison thread we
  belong in)
- "How to control opencode via mobile?"
  reddit.com/r/opencodeCLI/comments/1r8qohv/ (top answer is "expose the
  web UI and use Tailscale"; ours removes both steps)
- "Any opencode native mobile apps?"
  reddit.com/r/opencodeCLI/comments/1r1xhjy/ (asked for "Happy Coder but
  OpenCode-native through iOS," which is literally this product)
- "Best way to setup opencode on phone?"
  reddit.com/r/opencodeCLI/comments/1q5oaoa/
- r/codex: "Are there any actually usable remote control mobile apps?"
  reddit.com/r/codex/comments/1rgkl9y/ (OP also uses OpenCode; answer for
  the OpenCode half of their workflow, no overclaiming on Codex)

Do NOT jump into: dead HN threads (commenting closes after about two
weeks; the Omnara and Happy threads are long closed), and Happy's GitHub
security discussion #680 (marketing in a competitor's vulnerability thread
reads as an ambush and would deservedly backfire). Those threads are
ammunition for positioning, not venues.

These old threads compound: people googling "opencode iphone app" land on
them for months, so a good answer keeps selling long after the thread dies.

### Reply drafts

"Official mobile remote control?" thread:

> No official one. The web UI over Tailscale works if you don't mind the
> setup and the browser killing the tab. I got tired of both, so I built
> Remote for OpenCode: native iOS app plus a Mac companion, and there's no
> server or tunnel anywhere: the two devices pair through your own iCloud
> (a six-digit code, like AirPods) and then talk directly, end-to-end
> encrypted. Approvals with Face ID, diff review, push notifications.
> Free on the App Store, source on GitHub: [links]. I built it, so ask me
> anything.

"How to control via mobile?" thread:

> The Tailscale + web UI route works, but you're maintaining a tunnel and
> the mobile browser will kill the tab mid-session. I built an alternative
> because of exactly that: Remote for OpenCode, a native iOS app that
> pairs with a Mac companion through your own iCloud account. No Tailscale,
> no exposed server, no accounts; the devices talk directly, E2EE. Free,
> source public: [links]. (I'm the author.)

r/codex thread (answer the OpenCode half only):

> For the OpenCode side of your workflow: I built Remote for OpenCode, a
> native iOS remote where the phone and your Mac pair through your own
> iCloud and talk directly, E2EE, no relay server or tunnel involved.
> Approvals, plan mode, diff review from the phone. Free, source public:
> [links]. Codex isn't supported, so this only covers the OpenCode part.

## Open decisions

1. **License.** Keep PolyForm Noncommercial and say "source-available," or
   relicense MIT/Apache and own "completely open source." The competitors
   we beat on architecture all hold the open-source card; matching it
   removes their last talking point.
2. **Demo video.** The single highest-leverage missing asset for Reddit,
   X, Product Hunt, and YouTube outreach. docs/demo-video-script.md exists;
   record it before the launch wave.
3. **Launch timing.** Reddit and Discord any day; Show HN on a weekday
   morning US time; Product Hunt after the first wave proves the pitch.
