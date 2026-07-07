# cost-guard

Platform-neutral cost and runaway control for AI coding agents — Claude Code,
GitHub Copilot, Cursor, OpenAI Codex, and Google Gemini CLI. It watches each
session in the **free, observational pre-tool hook path** — so it adds **no token
usage of its own** — and denies or checkpoints tool calls before a loop, a
failure streak, or a runaway budget turns into spend. One neutral core holds all
the escalation logic; each agent gets a thin adapter that only translates JSON in
and out, so no ladder logic is ever duplicated per platform.

## Install — pick your IDE

Each supported IDE has its **own marketplace / extension entry in this one repo**,
so you install with a single command from your own CLI. Pick your row:

| IDE | Install command | Install method | Status |
|---|---|---|---|
| **Claude Code** | `/plugin marketplace add norequest/cost-guard` → `/plugin install cost-guard@cost-guard` | native marketplace | native ✅ |
| **OpenAI Codex** | `codex plugin marketplace add norequest/cost-guard` → `codex plugin install cost-guard@cost-guard` | native marketplace | native ✅ |
| **Google Gemini** | `gemini extensions install https://github.com/norequest/cost-guard` | native extension | native ✅ |
| **GitHub Copilot (CLI)** | `copilot plugin install norequest/cost-guard` | native plugin | native ✅ |
| **Cursor** | `install/install.sh cursor .` (writes `.cursor/hooks.json`) | installer / config file | file-based ⚠️ |
| **GitHub Copilot (cloud agent)** | `install/install.sh copilot .` → commit `.github/hooks/cost-guard.json` | config file | file-based ⚠️ |

**Requirements (all IDEs):** **bash + jq** on macOS/Linux (`brew install jq` /
`apt install jq`), or **PowerShell 7+** on Windows. Every adapter ships a `.sh`
and a `.ps1` sibling over one shared core (`core/guard.sh` / `core/guard.ps1`);
the two engines are behaviorally identical and share one state schema.

### Claude Code

```
/plugin marketplace add norequest/cost-guard      # or a local path: /plugin marketplace add ./cost-guard
/plugin install cost-guard@cost-guard             # plugin@marketplace
```

Both the marketplace and the plugin are named `cost-guard`. The repo root **is**
the plugin: `.claude-plugin/plugin.json` points `hooks` at
`adapters/claude-code/hooks.json`, whose commands resolve via
`${CLAUDE_PLUGIN_ROOT}`, so it works wherever it's installed from.

### OpenAI Codex

```
codex plugin marketplace add norequest/cost-guard
codex plugin install cost-guard@cost-guard
```

Requires a recent Codex (`plugin marketplace` support, **≥ ~v0.121**) with
**`features.hooks` enabled** in your Codex config. `.codex-plugin/plugin.json`
points `hooks` at `adapters/codex/hooks.json` (SessionStart / PreToolUse /
PostToolUse / **Stop** → session end; Codex has no SessionEnd).

### Google Gemini

```
gemini extensions install https://github.com/norequest/cost-guard
```

Requires **Gemini CLI ≥ v0.26.0** (hooks GA). The extension is defined by
`gemini-extension.json`; Gemini auto-loads `hooks/hooks.json` by convention,
which wires `SessionStart` / `BeforeTool` / `AfterTool` / `SessionEnd` via
`${extensionPath}`.

### GitHub Copilot (CLI)

```
copilot plugin install norequest/cost-guard
```

Requires a recent Copilot CLI with plugin support. The root `plugin.json` points
`hooks` at `adapters/copilot/hooks.json`, which wires
`sessionStart` / `preToolUse` / `postToolUse` / `errorOccurred` / `sessionEnd`.

### Cursor

Cursor has **no remote install for individuals yet**, so this path is file-based.
The installer writes a ready-to-use hooks block:

```bash
install/install.sh cursor .        # writes .cursor/hooks.json + bundles core/ + adapter
```

It wires `sessionStart` / `preToolUse` / `postToolUse` / `postToolUseFailure` /
`sessionEnd`. The pre-tool hook ships **`failClosed: false`** (fail-open, matching
the project philosophy — a slow or broken guard *allows* the tool rather than
bricking the session); flip it to `"failClosed": true` on the `preToolUse` entry
for strict enforcement. When Cursor's reviewed official marketplace / Teams import
lands, importing this repo (via `.cursor-plugin/`) becomes the native path.

### GitHub Copilot (cloud coding agent)

The cloud agent reads only repo-committed config, so this path is file-based:

```bash
install/install.sh copilot .       # writes .github/hooks/cost-guard.json (+ core/ + adapter)
```

Commit `.github/hooks/cost-guard.json` — hooks then apply whenever the Copilot
cloud agent runs in the repo. The wiring declares both a `bash` and a
`powershell` command per event; **the cloud agent runs on Linux**, so the bash
path executes there.

## How the marketplaces work

This is **one repo that exposes a separate committed marketplace / extension
manifest per IDE**. Each IDE reads a differently-named file, so there is no
collision — the repo root is *simultaneously* a Claude plugin, a Codex plugin, a
Gemini extension, and a Copilot plugin. You add only your own IDE's manifest.

| IDE | Manifest you add | Points hooks at |
|---|---|---|
| Claude Code | `.claude-plugin/` (`marketplace.json` + `plugin.json`) | `adapters/claude-code/hooks.json` |
| OpenAI Codex | `.agents/plugins/marketplace.json` + `.codex-plugin/plugin.json` | `adapters/codex/hooks.json` |
| Google Gemini | `gemini-extension.json` + `hooks/hooks.json` (convention) | `adapters/gemini/adapter.sh` (via `${extensionPath}`) |
| GitHub Copilot (CLI) | root `plugin.json` | `adapters/copilot/hooks.json` |
| Cursor | `.cursor-plugin/` (`marketplace.json` + `plugin.json`) — Teams/official import | `adapters/cursor/hooks.json` |

The **repo root is the plugin** in every case; each IDE's manifest points at its
own hooks file because the hook schemas differ (event names, decision shape, path
variable). All of them invoke `adapters/<ide>/adapter.sh <canonical-event>`,
which self-resolves `core/` regardless of cwd — the tested core/adapter logic is
identical across IDEs.

> **Verification status.** The manifests are **schema-verified against the current
> IDE docs** (JSON validates; every marketplace→source and manifest→hooks
> reference resolves), and the core + adapters are runtime-tested (106-check suite
> green). But the **native install paths on the non-Claude CLIs are new/preview**
> (Codex `plugin marketplace` ~v0.121, Copilot CLI plugins preview-era, Gemini
> extensions+hooks ≥ v0.26.0) and were not runtime-tested on the build machine —
> treat them as "documented and wired," and do a local smoke test with each CLI
> before relying on it. Full details:
> [`docs/plans/2026-07-08-multi-marketplace.md`](docs/plans/2026-07-08-multi-marketplace.md).

## What it does

Per session (keyed by the platform's session id), the guard tracks tool calls,
identical-call repeats, failure streaks, wall-clock time, and tool-output volume,
then enforces a 5-rung escalation ladder in the pre-tool hook — evaluated in this
order, first match wins:

1. **Loop** — the same `{tool, args}` fingerprint repeated more than `MAX_REPEATS`
   times → **deny**, with an instructive reason that un-sticks the agent.
2. **Failure streak** — `MAX_FAIL_STREAK` or more consecutive tool errors →
   **deny**, force a summary.
3. **Hard ceiling** — `MAX_CALLS` tool calls or `MAX_MINUTES` wall-clock →
   **deny** everything (kill switch).
4. **Soft checkpoint** — at `SOFT_CALLS`, then every 25 calls → **ask** the human
   (or **deny** in CI via `COST_GUARD_SOFT_ACTION`).
5. otherwise → **allow**.

State is one JSON file per session under `COST_GUARD_STATE_DIR`. On session end
the core writes one JSONL record (who, platform, duration, call count, denials,
asks, loops, end reason) to `sessions.jsonl` in `COST_GUARD_LOG_DIR`, additionally
flags `error` / `timeout` / `abort` sessions into `wasted-sessions.jsonl`, and —
only here, never in the hot path — optionally POSTs the record to a central
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
| **OpenAI Codex** | FULL (≥ ~v0.117, `features.hooks`) | native marketplace | PreToolUse interception is solid for Bash but **uneven for `apply_patch` / MCP** — a guardrail, not a sandbox. Finalizes on `Stop` (no SessionEnd). **Older Codex** has only fire-and-forget `notify` → notify-only fallback. |
| **Google Gemini** | FULL (≥ v0.26.0) | native extension | `BeforeTool` gate + `AfterTool` + lifecycle. Gemini has **no `ask`**, so the soft checkpoint degrades to **allow**. **Below v0.26.0**, only static `coreTools`/`excludeTools` allowlists exist. |

The guard governs CLI / agent hook surfaces only — **not** IDE inline completions
or IDE chat. Use your provider's usage-metrics API for those surfaces.

## Configuration

Every threshold is an environment variable with a sane default. On the file-based
installs you can also set these per-hook via the wiring file's `env` field.

| Variable | Default | Meaning |
|---|---|---|
| `COST_GUARD_MAX_CALLS` | `120` | Hard ceiling on tool calls per session |
| `COST_GUARD_SOFT_CALLS` | `50` | Soft-checkpoint threshold (then every 25 calls) |
| `COST_GUARD_MAX_REPEATS` | `3` | Identical `{tool,args}` repeats before a loop deny |
| `COST_GUARD_MAX_MINUTES` | `30` | Wall-clock budget per session |
| `COST_GUARD_MAX_FAIL_STREAK` | `5` | Consecutive tool errors before deny |
| `COST_GUARD_SOFT_ACTION` | `ask` | Soft-checkpoint action; set to `deny` for CI / pipe mode where no interactive prompt exists |
| `COST_GUARD_STATE_DIR` | system temp (`$TMPDIR/cost-guard`) | Where per-session state files live |
| `COST_GUARD_LOG_DIR` | `~/.cost-guard` | Where `sessions.jsonl` / `wasted-sessions.jsonl` are written |
| `COST_GUARD_COLLECTOR_URL` | unset | If set, session end POSTs the record here |
| `COST_GUARD_CORE` | unset | Explicit path to `core/guard.sh` (adapters otherwise auto-resolve it) |

## Central collector (optional)

A zero-dependency collector ships in `collector/`:

```bash
python3 collector/collector.py --port 8787 --data-dir ./data
export COST_GUARD_COLLECTOR_URL=http://your-host:8787/
```

- `GET /stats` — totals and per-user aggregates (sessions, tool calls, denials,
  loops, wasted sessions, avg duration).
- Records carry `user`, `gitEmail`, and `host` (captured locally at session
  start, since hook payloads contain no identity) and a **`platform`** field, so a
  single collector can aggregate across all five agents.

For production, put it behind TLS/auth or swap it for your observability stack —
the hooks just POST one small JSON object per session.

## Reconciling with real cost

Hooks never see tokens or credits. To turn tool-call counts into money, join
`sessions.jsonl` (by `gitEmail` + date, optionally split by `platform`) with your
provider's per-user usage report — e.g. GitHub's `ai_credits_used` per user per
day, available ~2–3 days later. After a week you'll have a calibration like
"~X credits per 100 tool calls," which makes the real-time counter a usable live
cost estimate.

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
permission shape — the only real per-platform difference:

| Platform | session id field | decision output |
|---|---|---|
| Claude Code | `session_id` | `hookSpecificOutput.permissionDecision` (allow/deny/ask) |
| Copilot | `sessionId` | `permissionDecision` (allow/deny/ask) |
| Cursor | `conversation_id` | `permission` (+ `agent_message`/`user_message`, camelCase twins) |
| Codex | `session_id` | `hookSpecificOutput.permissionDecision` (Claude-compatible) |
| Gemini | `session_id` / `$GEMINI_SESSION_ID` | top-level `{decision:"deny", reason, continue:false}`; silent on allow |

Adapters resolve the core across layouts: `$COST_GUARD_CORE`, a bundled `core/`
next to the adapter, or the repo-relative `../../core`.

## Gotchas (read before trusting it)

- **Fail-open on the gate.** A missing `jq`, a missing core, or a slow guard
  silently **allows** the tool — never brick a session on our account. That's why
  the guard is local-filesystem only in the hot path; the network call happens on
  session end, after the session is over. (Cursor's `failClosed` defaults to
  `false` for the same reason; flip it to `true` for strict enforcement.)
- **Crashes fail-closed.** A broken guard script could deny everything. The
  scripts wrap their work and fall back to `allow`, but test changes before
  committing. Escape hatch: disable hooks in your CLI settings.
- **Deny reasons are fed to the model.** Keep them instructive ("stop and
  summarize"), not merely prohibitive — a bare deny can make the agent thrash.
- **Don't add cost control to a "stop"/"block" that forces another billed turn.**
  That's the opposite of the goal.
- **Redact before centralizing.** These hooks deliberately log counts and
  metadata only — no prompts, no tool args, no tool output content.
- **Per-platform hook coverage varies** — see the support-tier matrix. The soft
  checkpoint degrades to `allow` on Cursor and Gemini (no enforced `ask`); Cursor
  cloud and Codex skip the end-of-session record; Codex PreToolUse is uneven for
  `apply_patch`/MCP.
- **CLI/agent hooks only.** The guard does not see — and cannot govern — IDE
  inline completions.

## Files / layout

The repo root **is** the plugin/extension. Each IDE reads its own manifest; all of
them point at one shared `core/` through a thin per-IDE adapter.

```
cost-guard/                            # repo root == the plugin / extension
├── .claude-plugin/
│   ├── marketplace.json               # Claude Code marketplace (plugin source "./")
│   └── plugin.json                    # hooks → adapters/claude-code/hooks.json
├── .agents/plugins/marketplace.json   # Codex marketplace
├── .codex-plugin/plugin.json          # hooks → adapters/codex/hooks.json
├── .cursor-plugin/
│   ├── marketplace.json               # Cursor marketplace (Teams / official import)
│   └── plugin.json                    # hooks → adapters/cursor/hooks.json
├── gemini-extension.json              # Gemini extension manifest
├── hooks/hooks.json                   # Gemini hooks (convention path; ${extensionPath})
├── plugin.json                        # Copilot CLI plugin  (hooks → adapters/copilot/hooks.json)
├── core/{guard.sh, guard.ps1}         # the neutral engine (bash+jq / PowerShell 7+)
├── adapters/
│   ├── claude-code/{adapter.sh, adapter.ps1, hooks.json}
│   ├── codex/{adapter.sh, adapter.ps1, hooks.json}
│   ├── copilot/{adapter.sh, adapter.ps1, hooks.json, cost-guard.json}   # cost-guard.json = .github cloud wiring
│   ├── cursor/{adapter.sh, adapter.ps1, hooks.json}
│   └── gemini/{adapter.sh, adapter.ps1, settings.hooks.json}
├── install/install.sh                 # Cursor individuals + Copilot cloud + native-command printer
├── collector/collector.py             # zero-dependency central collector
├── tests/{run.sh, payloads/}          # 106-check verification harness
└── docs/plans/                        # design + multi-marketplace docs
```

## License

MIT.
