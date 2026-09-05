# Mobile protocol v1 — verified OpenCode mapping

Status: M0 complete. Everything below was exercised live against
**OpenCode 1.18.10** (`opencode serve`, localhost) by `spikes/adapter/spike.ts`
on 2026-08-02. Raw event samples: `spikes/adapter/events/`.

The phone speaks protocol v1 over Wire; the Mac adapter translates to the
installed OpenCode HTTP+SSE API. This file is the contract's ground truth:
every v1 kind lists the OpenCode call(s) behind it and any version skew we
have already observed.

## Conventions

- Instance-scoped endpoints take `?directory=<absolute worktree path>`
  (URL-encoded). The global server multiplexes per-directory instances.
- Async errors do NOT surface on the HTTP call. `prompt_async` returns
  **204 with an empty body** (observed live; the adapter must not JSON-parse
  empty responses) and failures arrive later as `session.error` events /
  server log lines. Never treat prompt_async's success status as "the turn
  is running fine."
- All list/reply calls verified return JSON; SSE is standard
  `data: {json}\n\n` framing with `{id, type, properties}` envelopes.

## v1 kinds → OpenCode calls (all verified)

### `hello` — capabilities
- `GET /global/health` → `{healthy, version}`
- `GET /config/providers` → configured providers + default models
- Capability detection: fetch `GET /doc` (OpenAPI) once and probe
  `components.schemas.Event*` for event-name skew (see below).

### `projects`
- `GET /project` → `[{id, worktree, vcs?, name?, icon?, time{created,updated}, sandboxes}]`
  - Includes a synthetic `id: "global"` entry (worktree `/`) — filter it out.
  - Only projects previously opened with OpenCode; Mac-side git discovery
    supplements this for never-opened repos.

### `project.add` / `project.remove`
- `{kind: "project.add", project: "<path>"}` pins a folder as a project
  source on the Mac. No OpenCode call: the Mac expands a tilde,
  standardizes the path, verifies it is an existing directory (a readable
  `failed` otherwise), and persists it in the companion's defaults
  (`projectFolders`). Duplicates are a silent success.
- `{kind: "project.remove", project: "<path>"}` unpins one. Only paths
  added this way are stored, so removing anything else is a no-op.
- Both answer with a fresh `projects` event (the merged list: known, then
  pinned folders, then discovered repos), so the client replaces its list
  rather than patching it. Pinned entries carry `id: "folder:<path>"` and
  `added: true`; once OpenCode opens the folder it appears as a known
  project instead and the stored pin goes quiet.

### `sessions`
- `GET /experimental/session?limit=N` → cross-project, recency-sorted
  `[{id, title, directory, ...}]`. Supports `search`, `cursor`, `archived`.

### `prompt`
- `POST /session?directory=…` body `{title?, agent?, model?, permission?: PermissionRule[]}`
  - `permission: [{permission: "bash", pattern: "*", action: "ask"}]` forces
    the approval flow per-session — the phone's "always ask me" toggle.
- `POST /session/{id}/prompt_async?directory=…` body
  `{model: {providerID, modelID}, parts: [{type: "text", text}]}` → 200 immediately.
- Stream: `GET /event?directory=…` (SSE). One subscription per instance;
  `/global/event` exists for all-instance coverage.
- Abort: `POST /session/{id}/abort`.

### `permission`
- Event `permission.asked` → properties are the request itself:
  `{id, sessionID, permission, patterns, metadata: {command}, always, tool: {messageID, callID}}`
  - `always` carries the pattern(s) an "always allow" reply would whitelist —
    show it in the approval sheet.
- Poll fallback (survives missed events): `GET /permission?directory=…` lists
  pending requests. **This is what push-notification handling should read on
  wake** — no event replay needed.
- Reply: `POST /permission/{requestID}/reply` body
  `{reply: "once" | "always" | "reject", message?}`. The blocked tool call
  (state `running`) proceeds immediately on approval.
- Questions are the same shape: `question.asked`, `GET /question`,
  `POST /question/{requestID}/reply` | `/reject`.

### `commands` / slash commands
- v1 request `{kind: "commands"}` → `{kind: "commands", commands: [AgentCommand]}`
  from `GET /command`. Returns built-ins, the user's own
  `.opencode/command/*.md`, MCP prompts and skills, each with
  `{name, description?, agent?, model?, source, template, subtask?, hints}`.
- **The adapter drops `template`.** OpenCode expands it server-side when the
  command runs, so the phone never parses a template, never substitutes
  `$ARGUMENTS`, and has no opinion about template syntax — the coupling that
  would break on an upstream release. Templates are also multi-KB each.
- To run one: v1 `prompt` with `{command, arguments}` instead of `text` →
  `POST /session/{id}/command` body `{command, arguments, model?, agent?,
  parts?}`. Note `model` here is a **"provider/model" string**, unlike
  `prompt_async`'s object — an adapter difference, not a phone one.
- **`POST /command` is synchronous**: it blocks for the whole command
  (a `/review` runs for minutes), where `prompt_async` returns at once.
  Verified live. TurnRunner therefore fires the invocation in its own task
  and starts consuming SSE immediately, or nothing would stream until the
  command had already finished.
- Commands with `subtask: true` emit `subtask` message parts, not `tool`
  parts. Observed live against `/review`; without mapping them a subagent
  command looks like nothing happening.

### Session operations offered as commands
`GET /command` lists prompt *templates* only. Operations like summarize
and share are endpoints, and OpenCode's TUI implements them client-side —
which is why `/summarize` isn't in the list and answers a bare 500 if you
POST it as a command. The adapter offers them in the same palette
(`source: "session"`), only when the name isn't already taken by a user's
own command, and dispatches them to their endpoints:

| Command | Endpoint | Streams |
|---|---|---|
| `/summarize` | `POST /session/{id}/summarize {providerID, modelID}` | yes — runs a model |
| `/share` | `POST /session/{id}/share` → `share.url` | no |
| `/unshare` | `DELETE /session/{id}/share` | no |
| `/undo` | `POST /session/{id}/revert {messageID}` (last user message) | no |
| `/redo` | `POST /session/{id}/unrevert` | no |

All verified live. The non-streaming ones must NOT go through the turn
event loop — no `session.idle` ever arrives for them, so the turn would
hang forever.

### Agents, todos, session management, working tree

| v1 kind | OpenCode |
|---|---|
| `agents` | `GET /agent`, filtered to primary + non-hidden. `plan` = "Plan mode. Disallows all edit tools." |
| prompt `agent` | passed to `prompt_async` / `POST /command` as `agent` |
| `todos` | `todo.updated` event → `[{content, status}]`; `GET /session/{id}/todo` for a cold read |
| `session.delete` | `DELETE /session/{id}` |
| `session.rename` | `PATCH /session/{id} {title}` |
| `changes` | `GET /vcs` (branch) + `GET /vcs/diff?mode=git\|branch` |

`/vcs/diff` **requires** `mode`: `git` is the working tree against HEAD,
`branch` is against the default branch — what a reviewer sees in a pull
request. Its rows are already `FileDiff`-shaped
(`{file, patch, additions, deletions, status}`). All verified live.

### `mcp`: per-conversation MCP tool toggles
- `{kind: "mcp", project, session?}` → one event
  `{kind: "mcp", mcp: [{name, status, enabled}]}`. Servers from
  `GET /mcp?directory=…` (name → `{status}`); `enabled` is read from the
  named session's permission ruleset (`GET /session/{id}`), so the session
  is the durable truth and every client shows the same switches. No
  session (a fresh conversation) means everything `enabled`.
- prompt `mcp: {name: bool}`: the complete map, keyed by server name. The
  Mac applies it with `PATCH /session/{id} {permission: [...]}` after
  ensuring the session and before invoking anything: one wildcard rule
  `{permission: "<server>_*", pattern: "*", action: "deny"}` per
  switched-off server, nothing for the rest.
- Why PATCH rather than `prompt_async`'s own `tools` field: `POST
  /session/{id}/command` has no such field, and the session keeping the
  rules is what lets a thread configured from the phone keep its toolset
  in the TUI. OpenCode does the same replacement itself when a prompt
  carries `tools`, so the semantics match.
- Tool names are `<server>_<tool>` with both halves sanitized
  (`[^a-zA-Z0-9_-]` → `_`, their `McpCatalog.sanitize`); the rules must
  use the sanitized spelling. A denied server's tools are **removed from
  what the model sees** (`Permission.visibleTools`), not merely blocked,
  which is the point: context decluttering, not access control.
- Clients only send `mcp` when the conversation has something to say
  (user touched the switches, or loaded rules say something is off), so a
  client that never opened the menu can't erase rules another one set.
  All verified live against 1.18.15, including that the model's visible
  tool list shrinks (48 → 14 with four servers denied).

### `watch` — live view of a session this client didn't prompt
- `{kind: "watch", session, project}` subscribes to the session's live
  events, translated exactly like a prompt turn's (same event loop on the
  Mac — TurnRunner's pump, shared, not forked): `part`, `todos`, `diff` +
  `idle` at each turn boundary, `permission`/`question` asks. This is how
  a turn driven from the OpenCode TUI (or another device) animates an
  open session view in the GUI.
- Differences from a prompt turn's stream:
  - **User parts are forwarded** (type `"user"`), because the watching
    client never saw the words typed in the TUI. Clients drop them while
    their own turn is in flight, since the prompt is already on screen.
  - **`idle` is a lap marker, not an ending** — no `done` follows; the
    watch keeps going across turns. `done` only arrives when the Mac
    declined the watch (older companion), which the client treats as
    "don't retry".
  - **`permission.replied` becomes a bare `permission` event** (no
    payload): the ask was answered elsewhere, take the card down.
  - Failures never end the watch: a `session.error` is relayed as
    `failed` without `done` and the watch continues.
- Lifetime: one connection per watch; the client ends it by closing the
  transport, which cancels the Mac-side task. The Mac resubscribes to the
  SSE feed if it drops (OpenCode restart) for as long as the connection
  lives. Clients reload the transcript when (re)starting a watch — parts
  dedupe by id, so overlap is safe and gaps are filled.

### `pending` (added for M3 push)
- v1 request `{kind: "pending", project}` → one event
  `{kind: "pending", permissions: [PermissionRequest]}` from
  `GET /permission?directory=…`. What a push-woken phone asks first.

### `schedule.*`: tasks the Mac runs later
- Four kinds, every one answering with the complete regenerated list
  `{kind: "schedules", tasks: [ScheduledTask], timeZone}` plus `done`:
  - `{kind: "schedule.list"}`
  - `{kind: "schedule.save", task}`: create or replace, matched by
    `task.id` (client-minted UUID). Validation happens on the Mac (cron
    parses, exactly one of `cron`/`runAt`, non-empty prompt); a rejected
    save is a readable `failed`.
  - `{kind: "schedule.delete", taskID}`
  - `{kind: "schedule.run", taskID}`: fire now, outside the schedule; the
    next cron beat is untouched.
- Nothing here touches OpenCode: the list lives in the companion
  (UserDefaults), and these kinds are served even while OpenCode is down
  or restarting, before the adapter guard. `capabilities.schedules` on
  `ready`/`status` is the feature gate; an older Mac answers with its
  usual "older version" failure and clients surface that as the error.
- `ScheduledTask` carries the definition (name, project worktree, prompt,
  `providerID`/`modelID` with absent meaning the Mac's default exactly
  like a prompt, optional `agent`, `cron` XOR `runAt`, `enabled`) and
  Mac-written history (`lastRun`, `lastOutcome`
  running/succeeded/failed/missed, `lastError`, `lastSessionID`,
  `lastTurnID`, `nextFire`). Clients read history and never write it; an
  edit preserves it on the Mac. A fired one-shot is disabled, not
  deleted.
- Cron is 5 fields in the Mac's local time (`timeZone` on the event is
  how clients render fire times honestly), vixie day-OR rule, no name
  tokens or macros. Parsing and next-fire math live in RemoteKit
  (`Scheduling/CronSchedule.swift`), unit-tested including the DST
  edges: a spring-forward gap skips, a fall-back repeat fires once.
- A fire is an ordinary headless prompt turn: the scheduler mints a turn
  id and runs TurnRunner through LiveTurns with **no sink**, so
  permissions, questions, failures, and completion escalate to the
  CloudKit push exactly as they do for a backgrounded phone, and a
  client can `resume` the turn by id while it lingers. Each fire starts
  a fresh session; `lastSessionID` is how the transcript is read later.
- Retry: transient failures (`transient: true` on the `failed` event:
  OpenCode restarting or absent, a lost SSE stream, provider
  rate-limit/overload wording in `session.error`) retry up to 3 times on
  a 30s/2m/8m backoff (`Scheduling/RetryPolicy.swift`), reusing the
  session the first attempt created. A swallowed transient failure never
  reaches the turn's event buffer, so no premature push goes out and a
  resuming client never sees a failure that was about to be retracted.
  Anything unrecognized classifies as NOT transient on purpose.
- Missed fires: on launch and on wake the Mac resolves anything that
  came due while it was off; less than an hour late runs anyway, later
  is recorded `missed` and published as a `missed` Attention kind (the
  shipped phone's `kind != "permission"` subscription already delivers
  it with the generic alert).

## Push (M3, no relay)

Mac writes an `Attention` record (kind, sessionID, directory) to the user's
private CloudKit DB when a turn emits `permission`/`failed`/`idle` with no
live sink — i.e. the phone's socket is gone, which is what backgrounding
does. The phone holds a `CKQuerySubscription` (id `opencodego-attention`)
whose alert is generic text; the payload carries only the record ID. On tap
the phone fetches + deletes the record, then asks the Mac for `pending`
over the authenticated channel. Content never rides a push. The subscribe
path seeds the record type first (Development-env schema creation).

### `diff`
Two sources with different lifetimes:
- **Live**: `GET /session/{id}/diff` + `session.diff` events — the pending
  diff while the turn runs; **empties once the session settles**. Use for the
  in-flight "what is it changing right now" view.
- **Durable per-turn**: the *user* message's `info.summary.diffs` from
  `GET /session/{id}/message` →
  `[{file, patch (unified), additions, deletions, status}]`. This is the
  review screen's source.
- `GET /vcs/diff` requires a `mode` query param (working-tree level; not
  needed for v1).

### `usage`: context occupancy and cost
- `message.updated` events for assistant messages carry `info.tokens`
  ({total, input, output, reasoning, cache{read, write}}) for that one
  step. A step's input covers the whole conversation, so its tokens read
  as "how full is the model's context window", the number that says when
  to `/summarize`. The session record's `info.tokens` is *not* that: it
  is summed over every step the session has ever run (1.2M on a 30-step
  thread whose last step was 64k), so only `info.cost` is read from it.
- The pump maps assistant `message.updated` events to
  `{kind: "usage", usage: TurnUsage}` on both prompt turns and watches,
  emitted only when the numbers change (the same event fires several
  times per step, and LiveTurns buffers everything for replay). An
  all-zero record, which is what an aborted step leaves behind, is
  dropped, not sent as an empty meter.
- `usage.contextLimit` is resolved on the Mac from `GET /config/providers`
  (`limit.context` per model, fetched once per pump), because a
  default-model prompt means the client can't name the model it would be
  dividing by. Clients render a raw token count when it's absent.
- Cold load: a `transcript` answer appends one `usage` event after the
  parts and diff, read from the last assistant message with non-zero
  tokens in `GET /session/{id}/message` (cost from `GET /session/{id}`),
  so an opened session shows its meter before anything new runs.

### `resume` / transcript
- v1 request `{kind: "transcript", session, project, newestFirst?}` →
  `part` events, then one `diff`, then one `usage`, then `done`. The Mac
  reads `GET /session/{id}/message` once and derives all three from it
  (on a long thread that document is megabytes; it used to be fetched
  three times).
- `newestFirst: true` asks for the parts in reverse order behind a
  header `{kind: "transcript", newestFirst: true, count}`. This is how a
  client opens a long thread on its newest turn at once: it paints the
  first screen's worth as soon as it lands and merges the rest in
  doubling batches above it (`TranscriptLoad` in RemoteKit), never one
  part at a time. An older Mac ignores the flag and sends reading order
  with no header; a client that asked treats "no header" as reading
  order and paints once at the end. An older client never asks, so it
  never sees reversed parts.
- `GET /session/{id}/message?directory=…` → full transcript:
  `[{info: {id, role, time, summary?, agent, model}, parts: [...]}]`
  - Part types observed: `text`, `reasoning`, `tool` (with
    `state.status: pending|running|completed` + `state.input/output`),
    `step-start`, `step-finish`, `patch`.
- Reconnect strategy (LiveTurns on the Mac): replay transcript, then live
  events. Message/part IDs are stable — dedupe on them.
- **Tool parts carry a code preview.** A `tool` part whose `state.input`
  has code in it (write: `{filePath, content}`; edit:
  `{filePath, oldString, newString}` — both verified against 1.18-era
  storage) maps to a v1 part with `file` and `preview`, so the chat can
  show the code as it is written, the way OpenCode's TUI does. The preview
  is capped at 16K characters, cut at a line boundary; the full change
  still arrives as the turn's diff. Input appears when the tool part
  reaches `running`, so the preview is per-snapshot, not per-token; the
  token-level version would need the `session.next.tool.input.delta`
  family plus partial-JSON accumulation (deliberately deferred).
- **`message.part.updated` carries no role**, and the user's own message
  streams back through the same channel as the agent's. The adapter builds
  a messageID→role map from `message.updated` and drops parts belonging to
  user messages, or the prompt appears twice — once as the user's turn and
  again full-width as though the agent had written it. Verified live that
  `message.updated` for a message always precedes its parts.

## Streaming: the tokens are in `message.part.delta`

`message.part.updated` carries **snapshots**, not a token stream. For a
reasoning part it fires exactly twice — once empty at the start, once
complete at the end — so a UI built on it shows a blank thinking block
that snaps to finished text. The tokens are in
`message.part.delta`: `{sessionID, messageID, partID, field, delta}`,
where `field == "text"` and `delta` is the increment.

Measured live on 1.18.10, same prompt:

| Model | reasoning deltas | answer deltas |
|---|---|---|
| gemini-3.5-flash | 1 (whole thought in one chunk) | 14 |
| deepseek-v4-flash | **125** (4 → 7 → 9 → 17 → 22 chars…) | 55 |

So how granular thinking looks is a property of the provider, not of this
app. The adapter accumulates deltas per partID, learns the part's kind
from the snapshot that precedes them, and re-emits accumulated text.

Two things it must do:
- **Throttle to ~10/sec.** Each protocol event carries the whole
  accumulated text, so forwarding every delta is quadratic in bytes on a
  link where bytes are seconds — and LiveTurns buffers them all for
  replay. Measured: 50% fewer bytes, still reads as live typing.
- **Flush on `session.idle`.** The last tokens of a thought must not be
  the ones the throttle drops.

## Event catalog (observed on 1.18.10)

Coarse (message-level snapshots, fine for v1):
`server.connected`, `server.heartbeat`, `session.created`, `session.updated`,
`session.status`, `session.idle`, `session.diff`, `session.error`,
`message.updated`, `message.part.updated`, `message.part.delta`,
`permission.asked`, `permission.replied`, `question.asked`,
`file.edited`, `file.watcher.updated`, `todo.updated`, `project.updated`.

Fine-grained delta family (token-level streaming — the right thing to
forward over Wire for typing-effect UX): `session.next.text.delta`,
`session.next.reasoning.delta`, `session.next.tool.input.delta`,
`session.next.tool.called/progress/success/failed`,
`session.next.step.started/ended/failed`, plus compaction/revert/shell
variants. Full list: probe `/doc` `Event*` schemas.

Turn lifecycle as observed: `session.status` → parts stream →
(`permission.asked` → blocked tool `running` → `permission.replied`) →
`session.idle`.

## Version skew already observed (why the adapter exists)

| Concern | Older (≤1.16-era / fork) | 1.18.10 |
|---|---|---|
| Permission ask event | `permission.updated` | `permission.asked` (+ `permission.v2.asked` variant) |
| Question events | `question.*` | `question.*` + `question.v2.*` variants |
| Storage schema | — | 1.16.2 binary + newer DB → `SQLiteError: no such column: replacement_seq`; every prompt dies as an opaque async `prompt_async failed`. Adapter must health-check with a real prompt path, not just `/global/health` (which reported healthy). |

Adapter rule: subscribe to both old and new event names; detect once via
`/doc` and cache per server version.

## Gotchas for the Mac companion

- Start `opencode serve` with `OPENCODE_SERVER_PASSWORD` set (it warns
  "server is unsecured" otherwise) even though it's localhost-only —
  defense in depth against other local processes.
- Session create + prompt are two calls; a session with no prompt is an
  empty shell that still appears in session lists (clean up on abandon).
- `GET /project` ordering is not recency — sort by `time.updated` client-side.
- The model for a prompt comes from the phone's pick of
  `GET /config/providers`; there is no server-side "default model for this
  project" the adapter can rely on across versions.
