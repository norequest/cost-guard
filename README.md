# cost-guard

Platform-neutral cost and runaway control for AI coding agents — Claude Code,
GitHub Copilot, Cursor, OpenAI Codex, and Google Gemini CLI. All guard logic runs
in the free, observational **pre-tool** hook path, so it adds **no token usage**
of its own. One neutral core holds the escalation logic; each agent gets a thin
adapter that only translates JSON in and out. No ladder logic is ever duplicated
per platform.

> Started life as `copilot-cost-guard` (GitHub Copilot only). This rework freezes
> a single canonical contract so the same engine governs every supported agent.

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

## Supported platforms

Honest support tiers — read the caveats before trusting enforcement.

| Platform | Tier | Notes |
|---|---|---|
| **Claude Code** | FULL (flagship) | loop / streak / ceiling / checkpoint + logging. Failure streak is best-effort: there is no dedicated tool-failure event, so it is inferred from `tool_response`. |
| **GitHub Copilot** | FULL | The original target. Governs the Copilot CLI and the cloud agent. |
| **Cursor** | FULL | `preToolUse` gate + `postToolUseFailure` + lifecycle. **Cloud agents drop `sessionStart`/`sessionEnd`** → the core bootstraps state lazily on the first pre-tool, so gating still works; only the end-of-session record is skipped in cloud. **`ask` is not enforced on `preToolUse`**, so the soft checkpoint degrades to **allow**. |
| **OpenAI Codex** | FULL (≥ ~v0.117, `features.hooks`) | PreToolUse interception is solid for Bash but **uneven for `apply_patch` / MCP** — a guardrail, not a sandbox. Finalizes on `Stop` (Codex has no SessionEnd). **Older Codex** has only fire-and-forget `notify` → notify-only fallback. |
| **Google Gemini** | FULL (≥ v0.26.0) | `BeforeTool` gate + `AfterTool` + lifecycle. Gemini has **no `ask`**, so the soft checkpoint degrades to **allow**. **Below v0.26.0**, only static `coreTools`/`excludeTools` allowlists exist. |

The guard governs CLI / agent hook surfaces only — **not** IDE inline completions
or IDE chat. Use your provider's usage-metrics API for those surfaces.

## Install

Requirements for every platform: **bash + jq** on macOS/Linux
(`brew install jq` / `apt install jq`), or **PowerShell 7+** on Windows. Two
engines ship — `core/guard.sh` (bash + jq; also what the Copilot cloud agent runs
on Linux) and `core/guard.ps1` (PowerShell 7+, Windows) — and every adapter has a
`.sh` and a `.ps1` sibling. The two are behaviorally identical and share one state
schema.

For the copy-based platforms (everything except Claude Code) a helper is provided:

```bash
install/install.sh <platform> <target-dir>   # e.g. install/install.sh cursor .
```

It wraps the manual copy + wiring steps below. The manual steps are the
authoritative reference.

### Claude Code

The repo root is itself a Claude Code plugin **and** a single-plugin marketplace,
so no copying is required:

```
/plugin marketplace add prixioge/cost-guard      # or a local path: /plugin marketplace add ./cost-guard
/plugin install cost-guard@cost-guard            # plugin@marketplace
```

Both the marketplace and the plugin are named `cost-guard`. `plugin.json` points
`hooks` at `adapters/claude-code/hooks.json`, whose commands resolve via
`${CLAUDE_PLUGIN_ROOT}`, so it works wherever the plugin is installed from.

### GitHub Copilot

Copy the neutral core and the Copilot adapter into your repo's `.github/hooks/`,
then commit:

```
.github/hooks/cost-guard.json          # from adapters/copilot/cost-guard.json (the wiring)
.github/hooks/cost-guard/adapter.sh    # from adapters/copilot/adapter.sh
.github/hooks/cost-guard/core/guard.sh # from core/guard.sh
```

Or run `install/install.sh copilot <dir>`. The wiring config
declares both a `bash` and a `powershell` command per event, so the same file
works on macOS, Linux, and Windows. **The cloud agent runs on Linux**, so the
bash path is what executes there. Commit — hooks apply whenever the Copilot CLI
or cloud agent runs in the repo.

### Cursor

Copy the core and the Cursor adapter into `.cursor/hooks/cost-guard/`, then add
the wiring block:

```
.cursor/hooks/cost-guard/adapter.sh    # from adapters/cursor/adapter.sh
.cursor/hooks/cost-guard/core/guard.sh # from core/guard.sh
```

Merge the block from `adapters/cursor/hooks.json` into your `.cursor/hooks.json`
(it wires `sessionStart`, `preToolUse`, `postToolUse`, `postToolUseFailure`,
`sessionEnd`). The pre-tool hook ships with **`failClosed: false`** (fail-open,
matching the project philosophy — a slow or broken guard allows the tool rather
than bricking the session). Cursor users who want strict enforcement can flip it
to `"failClosed": true` on the `preToolUse` entry.

### OpenAI Codex

Requires Codex **≥ ~v0.117** with `features.hooks` enabled. Copy the core and the
Codex adapter into `.codex/hooks/cost-guard/`:

```
.codex/hooks/cost-guard/adapter.sh     # from adapters/codex/adapter.sh
.codex/hooks/cost-guard/core/guard.sh  # from core/guard.sh
```

Merge the block from `adapters/codex/hooks.json` into your `.codex/hooks.json`
(SessionStart / PreToolUse / PostToolUse / **Stop** → session end), and make sure
`features.hooks` is turned on in your Codex config.

### Google Gemini

Requires Gemini CLI **≥ v0.26.0** (hooks GA). Copy the core and the Gemini
adapter into `.gemini/hooks/cost-guard/`:

```
.gemini/hooks/cost-guard/adapter.sh    # from adapters/gemini/adapter.sh
.gemini/hooks/cost-guard/core/guard.sh # from core/guard.sh
```

Merge the `hooks` block from `adapters/gemini/settings.hooks.json` into your
Gemini `settings.json` (`~/.gemini/settings.json` or `<project>/.gemini/settings.json`).
It wires `SessionStart`, `BeforeTool`, `AfterTool`, and `SessionEnd`.

## Configuration

Every threshold is an environment variable with a sane default. On the copy-based
platforms you can also set these per-hook via the wiring file's `env` field.

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
  start, since hook payloads contain no identity) and now also a **`platform`**
  field, so a single collector can aggregate across all five agents.

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

```
.claude-plugin/{plugin.json, marketplace.json}   # Claude Code plugin + single-plugin marketplace
core/{guard.sh, guard.ps1}                        # the neutral engine (bash+jq / PowerShell 7+)
adapters/claude-code/{adapter.sh, adapter.ps1, hooks.json}   # per-platform adapters + wiring
adapters/copilot/{adapter.sh, adapter.ps1, cost-guard.json}
adapters/cursor/{adapter.sh, adapter.ps1, hooks.json}
adapters/codex/{adapter.sh, adapter.ps1, hooks.json}
adapters/gemini/{adapter.sh, adapter.ps1, settings.hooks.json}
collector/collector.py                            # zero-dependency central collector
install/install.sh                                # assembles a self-contained install per platform
tests/{run.sh, payloads/}                         # 106-check verification harness
docs/plans/                                        # design docs
```

## License

MIT.
