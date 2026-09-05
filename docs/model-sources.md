# Model sources

The Mac companion can keep OpenCode's model list in step with local
OpenAI-style endpoints: a vLLM or llama.cpp server, LM Studio, or a proxy
in front of several. Added 2026-09-04.

## Why this exists

OpenCode has no discovery for an OpenAI-compatible provider. The
`provider.<id>.models` block in its config is the whole truth about which
models exist and what their limits are. Two things follow from that, both
verified against OpenCode 1.18.15 rather than from memory:

- A model listed without a `limit` runs with a context window of zero.
  That switches off automatic compaction (`isOverflow` returns false when
  `limit.context` is 0) and leaves the context meter with no denominator.
- Unknown keys are dropped silently. A config that says `contextWindow`,
  `maxOutputTokens`, or `force` is not wrong, it is just ignored, and every
  model in it runs at zero. The keys OpenCode reads are `limit.context`,
  `limit.output`, `modalities.input`, `modalities.output`, `attachment`,
  `reasoning`, `tool_call`, `temperature`, and `name`.

OpenCode also reads its global config only at startup. Editing the file
does nothing to a running server, and neither `/instance/dispose` nor
`/global/dispose` reloads it. The companion owns `opencode serve`, so an
apply ends with a restart.

## What the Mac does

Each source is a base URL (with `/v1`), an optional API key, a provider
id, a display name, and the adapter package (default
`@ai-sdk/openai-compatible`). Several sources can coexist; each one owns
exactly one provider block.

A check fetches `<base>/models` from every enabled source and plans what
that provider's block would become. Limits and capabilities are read from
wherever the server puts them: OpenCode's own `limit` and `modalities`
shapes first, then vLLM's `max_model_len` and `max_output_tokens`, then an
OpenRouter-style `architecture` block. The merge rules are:

- Discovered fields win.
- Curated fields the endpoint did not mention survive: a display name, a
  cost table, hand-written modalities from a server that publishes none.
- Models the endpoint no longer serves are removed.
- The three dead keys above are cleaned out.
- `limit` needs both halves; a context without an output falls back to the
  curated output, then 4096.

A check never writes. Changes wait as a plan the user reviews: added,
updated, and removed models with the field differences spelled out, plus
the block exactly as it will be written. Applying rewrites only the
planned provider blocks, keeps the previous file as
`opencode.json.bak-remote`, and restarts OpenCode, or offers the restart
if a turn is running.

Checks run manually, at launch (the default), hourly, or daily. The
setting and the sources live in the companion's defaults, not in the
config file, so the file carries nothing but what OpenCode reads.

## Where the file is

`$XDG_CONFIG_HOME/opencode/opencode.json`, or `~/.config/opencode/opencode.json`.
OpenCode merges `opencode.jsonc` from the same directory on top; the pane
warns when one exists, since a provider defined there overrides what the
Mac writes. Project-level configs override the global one too and are not
managed. A global file that is not plain JSON is refused rather than
rewritten.

## Endpoint side

The listing only needs `id` per model. To get real limits the server has
to publish them; the proxy in front of the home vLLM does so in OpenCode's
own shape:

```json
{"id": "GLM-5.3-Flash",
 "limit": {"context": 65536, "output": 16384},
 "modalities": {"input": ["text", "image"], "output": ["text"]},
 "attachment": true, "reasoning": false, "tool_call": true, "temperature": true}
```

`tool_call: false` is honored as written, and OpenCode runs such a model
with no tools, so a server should only say it when it means it.

## Code

- `packages/RemoteKit/Sources/RemoteKit/ModelSources/` holds the pure
  parts: the source and discovered-model types, the listing parser, the
  merge and plan, and the config file reader and writer. All unit-tested
  in `ModelSourcesTests`.
- `app/MacCompanion/ModelSourceStore.swift` runs the checks, holds the
  pending plan, applies it, and restarts OpenCode.
- `app/MacCompanion/Workspace/ModelSourcesView.swift` is the pane, the
  source editor, and the review sheet. The sidebar entry is local-Mac
  only; the menu bar item surfaces a pending review.
