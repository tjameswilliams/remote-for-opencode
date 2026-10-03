# MCP servers

The Mac companion manages the MCP servers OpenCode can reach: the roster
in the global config, which ones a new conversation starts with, and a
set of tools that let a chat do the same. Added 2026-09-22.

## Three layers

1. **The roster.** `mcp.<name>` blocks in `~/.config/opencode/opencode.json`
   (or `$XDG_CONFIG_HOME/opencode/opencode.json`). A local server is a
   command OpenCode spawns and talks to over stdio; a remote one is a URL,
   Streamable HTTP with an SSE fallback. Only the keys OpenCode reads are
   written: `type`, `command`, `cwd`, `environment`, `url`, `headers`,
   `timeout`, `enabled`, and `oauth: false`. Anything else in an existing
   block survives an edit.
2. **Defaults.** Whether a fresh conversation starts with a server's tools
   on. Kept in the companion's defaults, not in the file, so flipping one
   needs no restart. Absent means on.
3. **Per-conversation switches.** The Tools menu in the composer, backed
   by the session's permission rules (docs/protocol-v1.md, `mcp`). These
   always win: the defaults are only what a session is born with.

Servers a project's own `.opencode/opencode.json` defines show up in the
list with their status, but they are the project's business: not editable
here, not removable.

## The management tools

The companion is itself an MCP server. It listens on `127.0.0.1:8767/mcp`
(loopback only, bearer token minted once and kept in the companion's
defaults) and registers itself in the global config as `remote` before
OpenCode starts. Its tools, as the model sees them:

| Tool | Does |
|---|---|
| `remote_mcp_list` | The roster with status, type, command or URL, and each default |
| `remote_mcp_add` | Add or replace a server in the config and connect it live |
| `remote_mcp_remove` | Remove one from the config and disconnect it |
| `remote_mcp_set_default` | Set whether new conversations start with a server on |

The same registration writes `permission: {"remote_*": "deny"}`, which
hides these tools from every session, the TUI included. Sessions in the
chat folder (New Chat) get a session-level allow rule when they are
created, and OpenCode evaluates session rules after the config's, so the
global chat sees the tools and a project session does not. The switch is
in the Tools menu like any other server's, so a project conversation can
turn them on, and a chat can turn them off.

Verified against OpenCode 1.18.15 on 2026-09-22 with a scratch config
and a probe listener built on the same RemoteKit code:

- The client connects over Streamable HTTP with `initialize`,
  `notifications/initialized`, and `tools/list`; status `connected`.
- `POST /mcp {name, config}` adds and connects a server in the running
  instance and returns the status map; calling it again for the same name
  replaces the definition. `POST /mcp/{name}/disconnect` closes it and
  leaves it `disabled`; an unknown name is a 404. A server that refuses
  the token comes back `failed` with the HTTP status in `error`.
- `PATCH /session/{id} {permission: [{permission: "remote_*", pattern:
  "*", action: "allow"}]}` persists and reads back from `GET /session/{id}`.
- Session rules are evaluated last (`Permission.evaluate` uses `findLast`
  over config, agent, then session rules), so the allow re-exposes tools
  the config denied. Read from the 1.18.15 source, not tested with a
  model turn.

## What an edit does

Saving a server writes the file first, then connects it in the chat
folder's instance (or the instance the request names) so the
conversation that asked can use its tools on the next step. Removing does
the reverse. Every OpenCode instance connects its own servers, and the
global config is read only at startup, so other projects see the change
after a restart. The companion offers the restart (the page's card, the
menu bar item, or `mcp.restart` from a client) rather than forcing it,
because a restart cuts off every running turn. Removed servers are hidden
from the list until then; OpenCode's own status keeps listing a server
from its startup config as `disabled`.

A remote server that needs OAuth is signed in on the Mac with `opencode
mcp auth <name>`; the page shows `needs_auth` until then.

## Code

- `packages/RemoteKit/Sources/RemoteKit/Protocol/McpServerConfig.swift`:
  the editable definition, the config block it writes, and the pure edits
  to the `mcp` and `permission` blocks. Tested in `McpServerConfigTests`.
- `packages/RemoteKit/Sources/RemoteKit/Mcp/`: the MCP server
  (`McpToolServer`, JSON-RPC over one POST), the HTTP parser, and the
  loopback listener. Tested in `McpToolServerTests`.
- `app/MacCompanion/McpRegistry.swift`: defaults, the list, the edits,
  and the tool definitions. `ToolServer.swift` runs the listener.
- `app/Shared/McpRegistryStore.swift` and `McpViews.swift`: the client
  store and the MCP Servers page, shared by the phone and the workspace.
