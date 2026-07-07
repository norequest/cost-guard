# cost-guard — per-IDE live-CLI smoke-test runbook

Manual checks a maintainer runs **on a machine that has the target CLI installed**,
before announcing a native install for that IDE. The static/offline verification
(JSON validity, cross-references, schema shape, path variables, behavior) already
passed on the build machine — see the results block below. What is **not** yet
proven is that each real CLI actually loads the manifest, fires the hook, and
honors the deny. That is what this runbook exercises.

---

## Static verification results (build machine, `bash + jq + git`, read-only)

Run on 2026-07-08 against the repo as-is (2 modified + several untracked manifests).

| # | Check | Result | Notes |
|---|-------|--------|-------|
| 1 | JSON validity (`jq -e` over all 35 `*.json`) | **PASS** | every manifest, wiring file, and test payload parses |
| 2 | Manifest → hooks path resolves | **PASS** | claude→`adapters/claude-code/hooks.json`, codex→`adapters/codex/hooks.json`, cursor→`adapters/cursor/hooks.json`, copilot(root)→`adapters/copilot/hooks.json`, gemini convention→`hooks/hooks.json` all EXIST |
| 2 | Marketplace `source` → repo-root plugin manifest | **PASS** | claude `"./"`, codex `{local,"./"}`, cursor `"./"` — root holds each IDE's plugin manifest. NOTE: `gemini-extension.json` has **no** `hooks` field by design; Gemini relies on the `hooks/hooks.json` convention (implicit link, see risk #1) |
| 3 | Schema sanity per IDE | **PASS** | Claude/Codex: PascalCase events + `hookSpecificOutput.permissionDecision`; Copilot: `version:1` + camelCase + `bash`/`powershell` keys; Gemini: `SessionStart/BeforeTool/AfterTool/SessionEnd` + `${extensionPath}`; Cursor: camelCase (`sessionStart/preToolUse/postToolUse/postToolUseFailure/sessionEnd`) + relative adapter path. Codex uses `Stop` (not `SessionEnd`) — matches doc. |
| 4 | Path-variable correctness | **PASS** | Claude `${CLAUDE_PLUGIN_ROOT}`; Codex `${CLAUDE_PLUGIN_ROOT:-.}`; Gemini `${extensionPath}`; Copilot/Cursor plugin-root-relative (no var). Consistent. |
| 5 | Behavior unchanged (`bash tests/run.sh`) | **PASS** | **106 passed, 0 failed** |
| 6 | Collision: distinct manifest paths | **PASS** | `.claude-plugin/plugin.json`, `.codex-plugin/plugin.json`, `.cursor-plugin/plugin.json`, root `plugin.json` are 4 distinct files; only Gemini uses bare `hooks/hooks.json`; only Copilot-CLI uses bare root `plugin.json`. No manifest hard-references `hooks/hooks.json`. **Residual risk #1 below.** |
| 7 | gitignore | **PASS** | `git check-ignore` on all 15 manifest/wiring files → none ignored. (`.gitignore` does ignore `*.jsonl`, so runtime session logs are correctly untracked; no manifest is `.jsonl`.) |

**Live end-to-end also exercised on the build machine** (core + all 4 gating adapters,
isolated `COST_GUARD_STATE_DIR`/`COST_GUARD_LOG_DIR`): allow, loop-deny, ceiling-deny,
and the per-IDE deny JSON shapes all emit correctly, and `session-end` writes
`sessions.jsonl` (+ `wasted-sessions.jsonl` on `error`/`timeout`/`abort`). Confirmed
real, not assumed. The one thing no build machine can prove is that each vendor CLI
*loads* the manifest — hence this runbook.

**Honest gaps to keep in mind while smoke-testing**

- The four native install commands (`/plugin …`, `codex plugin …`, `gemini extensions
  install`, `copilot plugin install`) are **documented against 2026 vendor docs, never
  run** — the CLIs are not on the build machine and these are bleeding-edge features
  (Codex `plugin marketplace` ≥ ~v0.121 + `features.hooks`; Copilot CLI plugins preview;
  Gemini extensions+hooks ≥ v0.26.0). Version drift is the most likely failure.
- Cosmetic nit (not a bug): the loop-deny reason reads "already made 1 times".

---

## Ground truth these tests rely on (from `core/guard.sh`)

- **State:** `${COST_GUARD_STATE_DIR:-$TMPDIR/cost-guard}/<sessionId>.json` (per live session).
- **Log:** `${COST_GUARD_LOG_DIR:-~/.cost-guard}/sessions.jsonl` — **one line appended per `session-end`**.
  Wasted runs (`endReason` ∈ `error|timeout|abort`) are **also** appended to
  `~/.cost-guard/wasted-sessions.jsonl`.
- **Deny ladder (pre-tool):** 1) loop (identical call `> COST_GUARD_MAX_REPEATS`, default 3)
  → 2) failure streak (`≥ COST_GUARD_MAX_FAIL_STREAK`, default 5) → 3) hard ceiling
  (`count ≥ COST_GUARD_MAX_CALLS`, default 120) → 4) time (`≥ COST_GUARD_MAX_MINUTES`, default 30)
  → 5) soft checkpoint (`count == COST_GUARD_SOFT_CALLS`, default 50, action `COST_GUARD_SOFT_ACTION`, default `ask`).
- **Forcing a deny fast (set these in the CLI's environment before you start it):**
  - Loop deny: `export COST_GUARD_MAX_REPEATS=1` → the **2nd identical** tool call denies.
  - Ceiling deny: `export COST_GUARD_MAX_CALLS=2 COST_GUARD_MAX_REPEATS=999` → the **2nd tool call
    of any kind** denies (raise `MAX_REPEATS` so the loop rule doesn't fire first).
- The environment must have **`bash` + `jq`** on `PATH` (Windows: PowerShell 7 + the `.ps1` adapters).
  Without `jq` the guard **fails OPEN** (always allows) — so if nothing ever denies, check `jq` first.

**Confirmed per-IDE deny JSON (build-machine, real output):**

| IDE | allow | deny |
|---|---|---|
| Claude / Codex | `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow",…}}` | same with `"permissionDecision":"deny"` + `permissionDecisionReason` |
| Copilot | `{"permissionDecision":"allow"}` | `{"permissionDecision":"deny","permissionDecisionReason":"…"}` |
| Cursor | `{"permission":"allow"}` | `{"permission":"deny","continue":true,"user_message":…,"agent_message":…,"userMessage":…,"agentMessage":…}` |
| Gemini | *(nothing printed)* | `{"decision":"deny","reason":"…","continue":false}` |

---

## Known risks — smoke-test these explicitly (from the design doc)

- [ ] **Risk #1 — Claude double-loading `hooks/hooks.json`.** Claude Code is wired via the
  explicit `.claude-plugin/plugin.json → adapters/claude-code/hooks.json`. But the repo root
  ALSO carries the bare `hooks/hooks.json` (Gemini's convention file). Confirm Claude Code
  does **not** auto-load that convention file in addition. If it does: its events differ
  (`BeforeTool/AfterTool` never match Claude's `PreToolUse/PostToolUse`, so no gating
  double-fire), and only `SessionStart`/`SessionEnd` names overlap. Under Claude,
  `${extensionPath}` is unset → the command becomes `"/adapters/gemini/adapter.sh …"`
  (nonexistent absolute path) → it should fail silently as a no-op. **Verify there is no
  double-fire and no spurious deny/error surfaced to the user.**
- [ ] **Risk #2 — Copilot CLI / Cursor plugin cwd.** Both use **plugin-root-relative**
  paths (`adapters/<ide>/adapter.sh`), which assume the hook command runs with **cwd = the
  installed plugin dir**. Confirm the CLI actually invokes hooks from that dir (not the
  user's project cwd). Symptom of failure: "adapter.sh: No such file or directory", so
  the guard silently never fires.
- [ ] **Risk #3 — Codex `${CLAUDE_PLUGIN_ROOT}` set.** Codex's `hooks.json` uses
  `${CLAUDE_PLUGIN_ROOT:-.}`. Confirm Codex sets `CLAUDE_PLUGIN_ROOT` on plugin hook
  execution. If it is unset, the `:-.` fallback makes the path project-cwd-relative — the
  adapter is found only when cwd = plugin dir (same failure mode as Risk #2). Verify a
  deny still fires when the Codex session's cwd is an arbitrary project.

---

## Per-IDE runbooks

### ☐ Claude Code

- [ ] **Install:** in Claude Code run
  `/plugin marketplace add norequest/cost-guard` then `/plugin install cost-guard@cost-guard`; restart.
  (Local dev: `/plugin marketplace add ./cost-guard`.)
- [ ] **Trigger a tool call:** ask Claude to run a shell command (e.g. "run `ls`"). It should proceed normally (allow is silent to the user).
- [ ] **Correct allow:** the tool runs; nothing about cost-guard is shown; a `<session>.json` appears under `$TMPDIR/cost-guard/`.
- [ ] **Force a loop deny:** start Claude with `COST_GUARD_MAX_REPEATS=1` in its env, then ask it to run the **same** command twice. The 2nd call must be **denied** with the "Loop detected…" reason surfaced to the model.
- [ ] **Force a ceiling deny:** start Claude with `COST_GUARD_MAX_CALLS=2 COST_GUARD_MAX_REPEATS=999`; the 2nd tool call of the session must be denied with "Session tool budget exhausted (2/2 calls)".
- [ ] **End + check log:** end the session, then `cat ~/.cost-guard/sessions.jsonl` — the last line has `"platform":"claude-code"`, a numeric `count`, `denials ≥ 1` (if you forced a deny), and `endReason`.
- [ ] **Also run Risk #1** above (no double-fire from `hooks/hooks.json`).

### ☐ OpenAI Codex

- [ ] **Preconditions:** Codex build with `plugin marketplace` support (≥ ~v0.121) **and `features.hooks` enabled** in Codex config; `bash + jq` on PATH.
- [ ] **Install:** `codex plugin marketplace add norequest/cost-guard` then `codex plugin install cost-guard@cost-guard`.
- [ ] **Trigger:** have Codex run a Bash tool call (PreToolUse interception is solid for Bash; uneven for `apply_patch`/MCP — test **Bash**).
- [ ] **Correct allow:** command runs; `$TMPDIR/cost-guard/<session>.json` created.
- [ ] **Force loop deny:** `COST_GUARD_MAX_REPEATS=1`, repeat one identical Bash call → 2nd denies.
- [ ] **Force ceiling deny:** `COST_GUARD_MAX_CALLS=2 COST_GUARD_MAX_REPEATS=999` → 2nd call denies.
- [ ] **End + check log:** Codex finalizes on **`Stop`** (wired to `session-end`). After the session, `~/.cost-guard/sessions.jsonl` last line has `"platform":"codex"` and `endReason` (`"stop"` default).
- [ ] **Also run Risk #3** (deny still fires when the Codex cwd is an arbitrary project dir, proving `${CLAUDE_PLUGIN_ROOT}` is set).

### ☐ Google Gemini

- [ ] **Preconditions:** Gemini CLI ≥ v0.26.0 (hooks GA); `bash + jq` on PATH.
- [ ] **Install:** `gemini extensions install https://github.com/norequest/cost-guard`. This loads `gemini-extension.json` and Gemini auto-loads `hooks/hooks.json` by convention (uses `${extensionPath}`).
- [ ] **Trigger:** have Gemini call a tool (its `BeforeTool` fires the guard).
- [ ] **Correct allow:** on allow the adapter prints **nothing** (Gemini requires pure-JSON stdout) — the tool just proceeds. Confirm `$TMPDIR/cost-guard/<session>.json` exists.
- [ ] **Force loop deny:** `COST_GUARD_MAX_REPEATS=1`, repeat an identical tool call → 2nd emits `{"decision":"deny","reason":"…","continue":false}` and the tool is blocked. (Gemini has no "ask"; a soft checkpoint degrades to allow.)
- [ ] **Force ceiling deny:** `COST_GUARD_MAX_CALLS=2 COST_GUARD_MAX_REPEATS=999` → 2nd call denies.
- [ ] **End + check log:** `~/.cost-guard/sessions.jsonl` last line has `"platform":"gemini"`. Verify `${extensionPath}` resolved (no "No such file" errors in Gemini's hook output).

### ☐ GitHub Copilot (CLI)

- [ ] **Preconditions:** Copilot CLI build with plugin support; `bash + jq` on PATH.
- [ ] **Install:** `copilot plugin install norequest/cost-guard`. Root `plugin.json` → `adapters/copilot/hooks.json` (`version:1`, camelCase events, `bash`/`powershell` keys).
- [ ] **Trigger:** have Copilot run a tool.
- [ ] **Correct allow:** tool runs; adapter returns `{"permissionDecision":"allow"}`; `$TMPDIR/cost-guard/<session>.json` created.
- [ ] **Force loop deny:** `COST_GUARD_MAX_REPEATS=1`, repeat identical call → 2nd returns `{"permissionDecision":"deny","permissionDecisionReason":"…"}` and blocks.
- [ ] **Force ceiling deny:** `COST_GUARD_MAX_CALLS=2 COST_GUARD_MAX_REPEATS=999` → 2nd call denies.
- [ ] **End + check log:** `~/.cost-guard/sessions.jsonl` last line has `"platform":"copilot"`.
- [ ] **Also run Risk #2** (hook command's cwd = plugin dir; deny still fires from an arbitrary project cwd).

### ☐ Cursor (individuals — file install)

- [ ] **Install:** from the repo, `install/install.sh cursor <target-project-dir>`. It writes `<target>/.cursor/hooks/cost-guard/{adapter.sh,core/guard.sh}` and `<target>/.cursor/hooks.json` (project-root-relative paths, `preToolUse` runs `failClosed:false`). If `.cursor/hooks.json` already exists it prints a block to merge instead of overwriting. Reload Cursor.
- [ ] **Trigger:** have the Cursor agent run a tool.
- [ ] **Correct allow:** tool runs; adapter returns `{"permission":"allow"}`; `$TMPDIR/cost-guard/<conversation_id>.json` created.
- [ ] **Force loop deny:** `COST_GUARD_MAX_REPEATS=1`, repeat identical call → 2nd returns `{"permission":"deny","continue":true,…}` with both `user_message`/`agent_message` (and camelCase twins). Cursor honors allow/deny (ask is accepted but not enforced).
- [ ] **Force ceiling deny:** `COST_GUARD_MAX_CALLS=2 COST_GUARD_MAX_REPEATS=999` → 2nd call denies.
- [ ] **End + check log:** `~/.cost-guard/sessions.jsonl` last line has `"platform":"cursor"`. (The session id is Cursor's `conversation_id`.)
- [ ] **Also run Risk #2** for Cursor's cwd assumption.
- [ ] **Note (test separately if using the `.cursor-plugin/` marketplace path):** the reviewed-marketplace/Teams-import manifests (`.cursor-plugin/{marketplace,plugin}.json` → `adapters/cursor/hooks.json`) are **forward-compatible and unverified**; the file install above is the real individual path today.

### ☐ GitHub Copilot (cloud agent — repo hooks)

- [ ] **Install:** from the repo, `install/install.sh copilot <target-project-dir>`. It writes `<target>/.github/hooks/cost-guard.json` + `<target>/.github/hooks/cost-guard/{adapter.sh,core/guard.sh}` (the cloud manifest uses `./.github/hooks/cost-guard/adapter.sh`). **Commit `.github/hooks/`** — the cloud agent only reads repo `.github/hooks/*.json`. (`.gitignore` does not block `.github/`.)
- [ ] **Trigger:** open a Copilot cloud-agent task in that repo that runs tools.
- [ ] **Correct allow:** tools run; the agent's environment has a `$TMPDIR/cost-guard/<session>.json`.
- [ ] **Force loop deny:** commit `COST_GUARD_MAX_REPEATS=1` into the agent env (or repo config), then drive an identical repeated call → 2nd denies with `{"permissionDecision":"deny",…}`.
- [ ] **Force ceiling deny:** `COST_GUARD_MAX_CALLS=2 COST_GUARD_MAX_REPEATS=999` in the agent env → 2nd call denies.
- [ ] **Check log:** in the agent's environment, `~/.cost-guard/sessions.jsonl` shows `"platform":"copilot"`. Note the cloud agent may drop `sessionStart`/`sessionEnd` — the core bootstraps state lazily on first `pre-tool`, so gating still works even if the end-of-run record is skipped.
- [ ] **Verify `bash + jq` are present** in the cloud agent's container (most common cloud failure — without `jq` the guard silently fails OPEN).
