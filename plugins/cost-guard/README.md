# cost-guard

Platform-neutral cost and runaway control for AI coding agents: Claude Code,
GitHub Copilot, Cursor, OpenAI Codex, and Google Gemini CLI. It watches each
session in the **free, observational pre-tool hook path** (so it adds **no token
usage of its own**) and denies or checkpoints tool calls before a loop, a
failure streak, or a runaway budget turns into spend. One neutral core holds all
the escalation logic; each agent gets a thin adapter that only translates JSON in
and out, so no ladder logic is ever duplicated per platform.

cost-guard is a plugin in the [norequest marketplace](../../README.md); this
directory, `plugins/cost-guard/`, is the plugin root.

## Install: pick your IDE

Each supported IDE has its **own marketplace / extension entry in this one repo**,
so you install with a single command from your own CLI. Pick your row:

| IDE | Install command | Install method | Status |
|---|---|---|---|
| **Claude Code** | `/plugin marketplace add norequest/plugins` → `/plugin install cost-guard@norequest` | native marketplace | native ✅ |
| **OpenAI Codex** | `codex plugin marketplace add norequest/plugins` → `codex plugin install cost-guard@norequest` | native marketplace | native ✅ |
| **Google Gemini** | `gemini extensions link ./plugins/cost-guard/gemini` (from a repo clone) | linked extension | native ✅ |
| **GitHub Copilot (CLI)** | `copilot plugin install norequest/plugins:plugins/cost-guard` | native plugin (subdir) | native ✅ |
| **Cursor** | `plugins/cost-guard/install/install.sh cursor .` (writes `.cursor/hooks.json`) | installer / config file | file-based ⚠️ |
| **GitHub Copilot (cloud agent)** | `plugins/cost-guard/install/install.sh copilot .` → commit `.github/hooks/cost-guard.json` | config file | file-based ⚠️ |

**Requirements (all IDEs):** **bash + jq** on macOS/Linux (`brew install jq` /
`apt install jq`). Every adapter ships a `.sh` and a `.ps1` sibling over one
shared core (`core/guard.sh` / `core/guard.ps1`), the two engines share one
state schema, and a PowerShell parity suite runs in CI on Windows. As shipped
today, though, the native hook manifests for Claude Code, Codex, Gemini, and
Cursor invoke the `.sh` adapter, so on Windows those IDEs need bash on PATH
(Git Bash or WSL). Copilot wires bash and PowerShell command pairs, and the
file-based installs ship both engines.

### Claude Code

```
/plugin marketplace add norequest/plugins      # or a local clone: /plugin marketplace add ./plugins
/plugin install cost-guard@norequest              # plugin@marketplace
```

The marketplace is named `norequest`; the plugin is named `cost-guard`. The
marketplace manifest at the repo root lists the plugin source as
`./plugins/cost-guard`, and the plugin's `.claude-plugin/plugin.json` points
`hooks` at `adapters/claude-code/hooks.json`, whose commands resolve via
`${CLAUDE_PLUGIN_ROOT}`, so it works wherever it's installed from.

### OpenAI Codex

```
codex plugin marketplace add norequest/plugins
codex plugin install cost-guard@norequest
```

Requires a recent Codex (`plugin marketplace` support, **≥ ~v0.121**) with
**`features.hooks` enabled** in your Codex config. The repo root's
`.agents/plugins/marketplace.json` lists the plugin at `./plugins/cost-guard`;
the plugin's `.codex-plugin/plugin.json` points `hooks` at
`adapters/codex/hooks.json` (SessionStart / PreToolUse / PostToolUse /
**Stop** → session end; Codex has no SessionEnd).

### Google Gemini

```
git clone https://github.com/norequest/plugins
gemini extensions link ./plugins/cost-guard/gemini
```

Requires **Gemini CLI ≥ v0.26.0** (hooks GA). Gemini has no marketplace concept
and cannot install from a repo subdirectory, so the extension is **linked** from
a local clone (link does not copy; edits to the clone apply live). The extension
root is `plugins/cost-guard/gemini/`, deliberately separate from the plugin root
so its `hooks/hooks.json` never collides with the plugin-root `hooks/hooks.json`
convention that Claude Code, Codex, and Cursor all auto-scan. `gemini-extension.json`
and `hooks/hooks.json` sit at that extension root; the hooks call
`${extensionPath}/hooks/entry.sh`, a shim that resolves the shared
`adapters/gemini/adapter.sh` and fails open. It wires `SessionStart` /
`BeforeTool` / `AfterTool` / `SessionEnd`.

### GitHub Copilot (CLI)

```
copilot plugin install norequest/plugins:plugins/cost-guard
```

Requires a recent Copilot CLI with plugin support. Copilot has no marketplace
concept but installs a plugin from a repo subdirectory via the `OWNER/REPO:PATH`
form, so the `:plugins/cost-guard` subpath is required (a bare `norequest/plugins`
looks only at the repo root). The plugin's `plugin.json` points `hooks` at
`adapters/copilot/hooks.json` (paths relative to the plugin root), which wires
`sessionStart` / `preToolUse` / `postToolUse` / `errorOccurred` / `sessionEnd`.

### Cursor

Cursor has **no remote install for individuals yet**, so this path is file-based.
From a clone of this repo, the installer writes a ready-to-use hooks block:

```bash
plugins/cost-guard/install/install.sh cursor .   # writes .cursor/hooks.json + bundles core/ + adapter
```

It wires `sessionStart` / `preToolUse` / `postToolUse` / `postToolUseFailure` /
`sessionEnd`. The pre-tool hook ships **`failClosed: false`** (fail-open,
matching the project philosophy: a slow or broken guard *allows* the tool rather
than bricking the session); flip it to `"failClosed": true` on the `preToolUse`
entry for strict enforcement. When Cursor's reviewed official marketplace /
Teams import lands, importing this repo (via the root `.cursor-plugin/`) becomes
the native path. Those native plugin hooks (`adapters/cursor/hooks.json`)
reference the adapter via `${CLAUDE_PLUGIN_ROOT}` (a plugin-root variable Cursor
supports; Cursor runs plugin hooks with the project root as cwd), so they resolve
wherever the plugin is installed.

### GitHub Copilot (cloud coding agent)

The cloud agent reads only repo-committed config, so this path is file-based:

```bash
plugins/cost-guard/install/install.sh copilot .  # writes .github/hooks/cost-guard.json (+ core/ + adapter)
```

Commit `.github/hooks/cost-guard.json`; hooks then apply whenever the Copilot
cloud agent runs in the repo. The wiring declares both a `bash` and a
`powershell` command per event; **the cloud agent runs on Linux**, so the bash
path executes there.

## How the marketplaces work

This is **one repo that exposes a separate committed marketplace / extension
manifest per IDE**. Each IDE reads a differently-named file, so there is no
collision. The repo root holds only the marketplace-level manifests; everything
else, including the Copilot CLI manifest and the Gemini extension (those two CLIs
have no marketplace concept and install the plugin straight from its
subdirectory), lives inside `plugins/cost-guard/`. You add only your own IDE's
manifest.

| IDE | Manifest you add | Points hooks at |
|---|---|---|
| Claude Code | root `.claude-plugin/marketplace.json` + `plugins/cost-guard/.claude-plugin/plugin.json` | `adapters/claude-code/hooks.json` |
| OpenAI Codex | root `.agents/plugins/marketplace.json` + `plugins/cost-guard/.codex-plugin/plugin.json` | `adapters/codex/hooks.json` |
| Google Gemini | `plugins/cost-guard/gemini/gemini-extension.json` + `gemini/hooks/hooks.json` (linked extension root) | `gemini/hooks/entry.sh` shim → `adapters/gemini/adapter.sh` |
| GitHub Copilot (CLI) | `plugins/cost-guard/plugin.json` (subdir install) | `adapters/copilot/hooks.json` |
| Cursor | root `.cursor-plugin/marketplace.json` + `plugins/cost-guard/.cursor-plugin/plugin.json` (Teams / official import) | `adapters/cursor/hooks.json` |

For the marketplace-aware CLIs (Claude Code, Codex, Cursor) the root manifest
lists the plugin source as `./plugins/cost-guard`, and the plugin manifest
points at its own hooks file because the hook schemas differ (event names,
decision shape, path variable). Copilot CLI installs the plugin from the
`plugins/cost-guard` subdirectory; Gemini links the isolated
`plugins/cost-guard/gemini` extension folder (its `hooks/hooks.json` is kept out
of the plugin root, which Claude, Codex, and Cursor all auto-scan). All of them
ultimately invoke `adapters/<ide>/adapter.sh <canonical-event>`, which
self-resolves `core/` regardless of cwd; the tested core/adapter logic is
identical across IDEs.

> **Verification status.** The manifests are **schema-verified against the
> current IDE docs** (JSON validates; every marketplace→source and
> manifest→hooks reference resolves), and the core + adapters are runtime-tested
> (130-check bash suite green, plus a PowerShell parity suite). But the **native install paths on the non-Claude CLIs
> are new/preview** (Codex `plugin marketplace` ~v0.121, Copilot CLI plugins
> preview-era, Gemini extensions+hooks ≥ v0.26.0) and were not runtime-tested on
> the build machine. Treat them as "documented and wired," and do a local smoke
> test with each CLI before relying on it.

## What it does

Per session (keyed by the platform's session id), the guard tracks tool calls,
consecutive identical-call repeats, failure streaks, wall-clock time, and tool-output volume,
then enforces a 5-rung escalation ladder in the pre-tool hook, evaluated in this
order, first match wins:

1. **Loop**: the same `{tool, args}` fingerprint attempted more than
   `MAX_REPEATS` times **in a row** → **deny**, with an instructive reason that
   un-sticks the agent. Only consecutive repeats count: re-running a command
   later in the session does not trip it.
2. **Failure streak**: `MAX_FAIL_STREAK` or more consecutive tool errors →
   **deny**, force a summary.
3. **Hard ceiling**: `MAX_CALLS` tool calls or `MAX_MINUTES` wall-clock →
   **deny** everything (kill switch).
4. **Soft checkpoint**: at `SOFT_CALLS`, then every 25 calls → **ask** the human
   (or **deny** in CI via `COST_GUARD_SOFT_ACTION`).
5. otherwise → **allow**.

State is one JSON file per session under `COST_GUARD_STATE_DIR` (by default a
per-user directory under the system temp dir). On session end
the core writes one JSONL record (who, platform, duration, call count, denials,
asks, loops, end reason) to `sessions.jsonl` in `COST_GUARD_LOG_DIR`, additionally
flags `error` / `timeout` / `abort` sessions into `wasted-sessions.jsonl`, and,
only here, never in the hot path, optionally POSTs the record to a central
collector. Identity (user / gitEmail / host) is captured locally at session start
because hook payloads carry none.

## Why it matters

Agent cost is not evenly distributed: most sessions are cheap, and the money
is lost in the small fraction that go rogue, a retry loop, a failure spiral,
an unattended CI run. cost-guard puts a hard ceiling on that tail rather than
shaving the average.

- **Kills runaways at the earliest signal.** Loop detection is rung 1 of the
  ladder, so a tight retry loop dies in about 4 iterations, before the
  call-count or wall-clock ceilings are even reached.
- **Fails open, always.** Missing `jq`, a missing core, or a slow guard
  resolves to allow, never deny. It can annoy by blocking one legitimate
  call; it can never brick a session.
- **Zero cost in the hot path.** The gate is local file I/O plus `jq`; the
  only network call is one POST at session end.
- **Denials teach, not just block.** Reasons are instructive ("do not retry,
  try a different approach, or stop and summarize"), so agents course-correct
  instead of thrashing.
- **Leaves a ledger for free.** Every session lands in `sessions.jsonl`;
  sessions ending in `error`, `timeout`, or `abort` are also flagged into
  `wasted-sessions.jsonl`.

### How it controls token spend

To be precise: this guards runaway token spend, LLM tokens burning as money
through waste, not secrets or credential leaks.

It is also a proxy. The guard cannot see the model's token counter, only tool
calls. Each tool call implies another expensive round-trip: the model reads
the result, re-reasons over the growing context, and emits the next call. N
calls means roughly N round-trips over an ever-larger context, where the
tokens actually go. Capping calls, killing identical-call loops, and stopping
failure spirals caps those round-trips: a loop that would have made 400
identical calls, and 400 full-context re-reads, is stopped at about 4.

The limits are real: it does not count or cap tokens or dollars, thresholds
are calls and minutes. A call that stuffs a huge file into context is one
"count" to the guard despite the large token hit (the core logs `outputBytes`
but never gates on it). It governs the tool boundary only, not what the model
writes back.

cost-guard bounds runaway agent spend by governing the tool-call loop that
drives token consumption, failing open so it never breaks a session. A
circuit breaker, not a meter.

## Supported platforms

All five are **FULL for guard behavior**; read the caveats before trusting
enforcement.

| Platform | Tier | Install method | Notes |
|---|---|---|---|
| **Claude Code** | FULL (flagship) | native marketplace | loop / streak / ceiling / checkpoint + logging. Failure streak is best-effort: no dedicated tool-failure event, so it is inferred from `tool_response`. |
| **GitHub Copilot** | FULL | native plugin (CLI) / config file (cloud) | The original target. Governs the Copilot CLI and the cloud agent; **cloud drops `sessionStart`/`sessionEnd`** so the core bootstraps state lazily on first pre-tool and only the end record is skipped. |
| **Cursor** | FULL | installer / config file (native marketplace when available) | `preToolUse` gate + `postToolUseFailure` + lifecycle. **Cloud agents drop lifecycle** → state bootstraps lazily on first pre-tool; only the end record is skipped. **`ask` not enforced on `preToolUse`** → soft checkpoint degrades to **allow**. |
| **OpenAI Codex** | FULL (≥ ~v0.117, `features.hooks`) | native marketplace | PreToolUse interception is solid for Bash but **uneven for `apply_patch` / MCP** (a guardrail, not a sandbox). Finalizes on `Stop` (no SessionEnd). **Older Codex** has only fire-and-forget `notify` → notify-only fallback. |
| **Google Gemini** | FULL (≥ v0.26.0) | native extension | `BeforeTool` gate + `AfterTool` + lifecycle. Gemini has **no `ask`**, so the soft checkpoint degrades to **allow**. **Below v0.26.0**, only static `coreTools`/`excludeTools` allowlists exist. |

The guard governs CLI / agent hook surfaces only, **not** IDE inline completions
or IDE chat. Use your provider's usage-metrics API for those surfaces.

## Configuration

Every threshold is an environment variable with a sane default. On the file-based
installs you can also set these per-hook via the wiring file's `env` field.

| Variable | Default | Meaning |
|---|---|---|
| `COST_GUARD_MAX_CALLS` | `120` | Hard ceiling on tool calls per session |
| `COST_GUARD_SOFT_CALLS` | `50` | Soft-checkpoint threshold (then every 25 calls) |
| `COST_GUARD_MAX_REPEATS` | `3` | Consecutive identical `{tool,args}` attempts before a loop deny (a repeat later in the session does not count) |
| `COST_GUARD_MAX_MINUTES` | `30` | Wall-clock budget per session |
| `COST_GUARD_MAX_FAIL_STREAK` | `5` | Consecutive tool errors before deny |
| `COST_GUARD_SOFT_ACTION` | `ask` | Soft-checkpoint action; set to `deny` for CI / pipe mode where no interactive prompt exists |
| `COST_GUARD_STATE_DIR` | per-user temp dir | Where per-session state files live. Default: `cost-guard-<uid>` under the system temp dir on macOS/Linux, `cost-guard-<username>` under `%TEMP%` on Windows |
| `COST_GUARD_LOG_DIR` | `~/.cost-guard` | Where `sessions.jsonl` / `wasted-sessions.jsonl` are written |
| `COST_GUARD_COLLECTOR_URL` | unset | If set, session end POSTs the record here |
| `COST_GUARD_CORE` | unset | Explicit path to `core/guard.sh` (adapters otherwise auto-resolve it) |

## Central collector (optional)

A zero-dependency collector ships in `collector/`:

```bash
python3 plugins/cost-guard/collector/collector.py --port 8787 --data-dir ./data
export COST_GUARD_COLLECTOR_URL=http://your-host:8787/
```

- `GET /stats`: totals and per-user aggregates (sessions, tool calls, denials,
  loops, wasted sessions, avg duration).
- Records carry `user`, `gitEmail`, and `host` (captured locally at session
  start, since hook payloads contain no identity) and a **`platform`** field, so a
  single collector can aggregate across all five agents.

For production, put it behind TLS/auth or swap it for your observability stack;
the hooks just POST one small JSON object per session.

## Reconciling with real cost

Hooks never see tokens or credits. To turn tool-call counts into money, join
`sessions.jsonl` (by `gitEmail` + date, optionally split by `platform`) with your
provider's per-user usage report, e.g. GitHub's `ai_credits_used` per user per
day, available about 2 to 3 days later. After a week you'll have a calibration
like "~X credits per 100 tool calls," which makes the real-time counter a usable
live cost estimate.

## Architecture

One idea: a frozen **canonical contract** between adapters and the core. Adapters
only translate; all shared logic lives in the core, once.

```
adapter (per platform)                  core (once)
  platform payload ──normalize──▶  canonical JSON ──▶ escalation ladder + state
  platform decision ◀─denormalize── {decision, reason}      + logging
```

**Canonical input** (adapter → `core/guard.sh` on stdin):

```json
{
  "event": "session-start | pre-tool | post-tool | error | session-end",
  "sessionId": "string",
  "tool": "string",        // pre-tool: for the loop fingerprint
  "args": {},              // pre-tool: for the loop fingerprint
  "resultText": "string",  // post-tool: bytes proxy for context growth
  "cwd": "string",         // session-start
  "source": "string",      // session-start
  "endReason": "string",   // session-end
  "platform": "claude-code | copilot | cursor | codex | gemini"
}
```

**Canonical output** (core → adapter, **pre-tool only**, on stdout):

```json
{ "decision": "allow | deny | ask", "reason": "string" }
```

Every other event produces no stdout; the core does its bookkeeping/logging and
exits 0. The adapter denormalizes `{decision, reason}` into each agent's native
permission shape, the only real per-platform difference:

| Platform | session id field | decision output |
|---|---|---|
| Claude Code | `session_id` | `hookSpecificOutput.permissionDecision` (allow/deny/ask) |
| Copilot | `sessionId` | `permissionDecision` (allow/deny/ask) |
| Cursor | `conversation_id` | `permission` (+ `agent_message`/`user_message`, camelCase twins) |
| Codex | `session_id` | `hookSpecificOutput.permissionDecision` (Claude-compatible) |
| Gemini | `session_id` / `$GEMINI_SESSION_ID` | top-level `{decision:"deny", reason, continue:false}`; silent on allow |

Adapters resolve the core across layouts: `$COST_GUARD_CORE`, a bundled `core/`
next to the adapter, or the plugin-relative `../../core`.

## Gotchas (read before trusting it)

- **Fail-open on the gate.** A missing `jq`, a missing core, or a slow guard
  silently **allows** the tool; never brick a session on our account. That's why
  the guard is local-filesystem only in the hot path; the network call happens on
  session end, after the session is over. (Cursor's `failClosed` defaults to
  `false` for the same reason; flip it to `true` for strict enforcement.)
- **Crashes fail-closed.** A broken guard script could deny everything. The
  scripts wrap their work and fall back to `allow`, but test changes before
  committing. Escape hatch: disable hooks in your CLI settings.
- **Deny reasons are fed to the model.** Keep them instructive ("stop and
  summarize"), not merely prohibitive: a bare deny can make the agent thrash.
- **Don't add cost control to a "stop"/"block" that forces another billed turn.**
  That's the opposite of the goal.
- **Redact before centralizing.** These hooks deliberately log counts and
  metadata only: no prompts, no tool args, no tool output content.
- **Per-platform hook coverage varies**: see the support-tier matrix. The soft
  checkpoint degrades to `allow` on Cursor and Gemini (no enforced `ask`); Cursor
  cloud and Codex skip the end-of-session record; Codex PreToolUse is uneven for
  `apply_patch`/MCP.
- **CLI/agent hooks only.** The guard does not see, and cannot govern, IDE
  inline completions.

## Files / layout

The plugin lives at `plugins/cost-guard/` inside the norequest marketplace repo.
The repo root holds only the marketplace manifests; everything the plugin needs,
including the Copilot CLI manifest and the Gemini extension, lives under
`plugins/cost-guard/`. Each IDE reads its own manifest; all of them point at one
shared `core/` through a thin per-IDE adapter.

```
cost-guard/                                # the norequest marketplace repo
├── .claude-plugin/marketplace.json        # Claude Code marketplace (plugin source ./plugins/cost-guard)
├── .agents/plugins/marketplace.json       # Codex marketplace
├── .cursor-plugin/marketplace.json        # Cursor marketplace (Teams / official import)
├── LICENSE
├── README.md                              # marketplace-level README
└── plugins/cost-guard/                    # this plugin, fully self-contained
    ├── .claude-plugin/plugin.json         # Claude hooks → adapters/claude-code/hooks.json
    ├── .codex-plugin/plugin.json          # Codex hooks → adapters/codex/hooks.json
    ├── .cursor-plugin/plugin.json         # Cursor hooks → adapters/cursor/hooks.json
    ├── plugin.json                        # Copilot CLI manifest → adapters/copilot/hooks.json
    ├── gemini/                            # Gemini extension root (linked from a clone)
    │   ├── gemini-extension.json
    │   └── hooks/{hooks.json, entry.sh}   # hooks.json → ${extensionPath}/hooks/entry.sh shim → adapters/gemini
    ├── core/{guard.sh, guard.ps1}         # the neutral engine (bash+jq / PowerShell 7+)
    ├── adapters/
    │   ├── claude-code/{adapter.sh, adapter.ps1, hooks.json}
    │   ├── codex/{adapter.sh, adapter.ps1, hooks.json}
    │   ├── copilot/{adapter.sh, adapter.ps1, hooks.json, cost-guard.json}   # cost-guard.json = .github cloud wiring
    │   ├── cursor/{adapter.sh, adapter.ps1, hooks.json}
    │   └── gemini/{adapter.sh, adapter.ps1, settings.hooks.json}
    ├── install/install.sh                 # Cursor individuals + Copilot cloud + native-command printer
    ├── collector/collector.py             # zero-dependency central collector
    └── tests/{run.sh, run.ps1, payloads/} # verification harness (bash + PowerShell parity)
```

## Tests

Run the 130-check harness with `plugins/cost-guard/tests/run.sh` from the repo
root, or `tests/run.sh` from this plugin directory.

Two install integration smoke tests exercise the file-based paths against a
throwaway project, driving each hook lifecycle the way the agent does (the wired
command, its real cwd, payload on stdin):

- `tests/smoke-cursor.sh`: allow/deny gating, the session ledger, and the native
  `${CLAUDE_PLUGIN_ROOT}` marketplace wiring.
- `tests/smoke-copilot.sh`: the cloud-agent wiring, including lazy bootstrap (a
  first pre-tool with no session-start still gates, matching the cloud dropping
  lifecycle events), the ledger, the installer's no-clobber guard + FORCE
  override, and uninstall.

All suites run in CI on Ubuntu and macOS.

## License

MIT.
