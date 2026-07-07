# cost-guard tests

Run the verification harness with:

```sh
bash tests/run.sh
```

It requires only `bash` + `jq` (the same hard dependencies as cost-guard). For
each of the five platforms (claude-code, copilot, cursor, codex, gemini) it
drives that platform's real adapter end-to-end through the neutral core in an
isolated `mktemp` state+log dir with low thresholds (`MAX_REPEATS=2`,
`SOFT_CALLS=4`, `MAX_CALLS=6`, `MAX_FAIL_STREAK=3`, `SOFT_ACTION=ask`) and asserts
the full escalation ladder **in that platform's native decision shape**: (a) a
first pre-tool ALLOW, (b) a repeated call tripping the loop DENY, (c) distinct
calls crossing the soft checkpoint (ask — Gemini degrades to empty stdout), (d)
distinct calls crossing the hard ceiling DENY, (e) a failure-streak DENY, (f)
session-end writing the correct `platform`/`endReason` into `sessions.jsonl` with
error/timeout/abort also flagged into `wasted-sessions.jsonl`, plus (g) the
fail-open-when-jq-is-missing allow path and (h) a smoke check that every sample
payload in `payloads/` parses cleanly through its adapter. It prints a per-check
✓/✗ line, a final `N passed, M failed`, and exits non-zero if anything fails.

`payloads/<platform>-<event>.json` holds a realistic sample hook payload per
platform and event, using each platform's genuine field names (e.g. Copilot's
`sessionId`/`toolName`/`toolArgs`, Cursor's `conversation_id`/`tool_input`,
Gemini's `session_id`/`tool_response`).
