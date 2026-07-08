#!/usr/bin/env bash
# cost-guard :: OpenAI Codex marketplace WIRING smoke test (integration).
#
# Codex installs only through its native plugin marketplace (there is no file
# install to run, and the Codex CLI is not on the build machine), so this cannot
# drive a real `codex plugin install`. What it DOES verify, end to end:
#   1. the marketplace wiring chain resolves: marketplace.json -> source path ->
#      .codex-plugin/plugin.json -> hooks -> adapters/codex/hooks.json -> adapter.
#   2. the installer prints the correct native commands.
#   3. the wired hook command actually gates, run the way Codex runs it (the
#      command string from hooks.json, payload on stdin), BOTH with
#      ${CLAUDE_PLUGIN_ROOT} set and via the "." fallback (cwd = plugin root).
#   4. Stop -> session-end writes the ledger (Codex has no SessionEnd).
#
# Not covered (needs the actual Codex CLI): whether Codex loads the marketplace,
# exports CLAUDE_PLUGIN_ROOT, and passes the documented payload fields.
#
# Requires bash + jq. Usage, from the repo root:
#   bash plugins/cost-guard/tests/smoke-codex.sh
set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(dirname "$SCRIPT_DIR")                 # plugins/cost-guard (the plugin root)
MARKET_ROOT=$(cd "$REPO/../.." && pwd)        # the marketplace repo root
INSTALL="$REPO/install/install.sh"
HOOKS="$REPO/adapters/codex/hooks.json"

PROJ=$(mktemp -d 2>/dev/null || mktemp -d -t cgproj)
STATE=$(mktemp -d 2>/dev/null || mktemp -d -t cgstate)
LOG=$(mktemp -d 2>/dev/null || mktemp -d -t cglog)
FSTATE=$(mktemp -d 2>/dev/null || mktemp -d -t cgfstate)
trap 'rm -rf "$PROJ" "$STATE" "$LOG" "$FSTATE"' EXIT

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  \xe2\x9c\x93 %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  \xe2\x9c\x97 %s  (%s)\n' "$1" "$2"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }
has() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "missing [$2] in [$3]" ;; esac; }
isfile() { if [ -f "$2" ]; then ok "$1"; else bad "$1" "missing $2"; fi; }

echo "=== 1. marketplace wiring chain resolves ==="
MP="$MARKET_ROOT/.agents/plugins/marketplace.json"
PJ="$REPO/.codex-plugin/plugin.json"
isfile "marketplace.json present" "$MP"
if jq -e . "$MP" >/dev/null 2>&1; then ok "marketplace.json valid JSON"; else bad "marketplace.json JSON" "jq failed"; fi
SRC=$(jq -r '.plugins[0].source.path' "$MP")
eq "marketplace source path is ./plugins/cost-guard" "./plugins/cost-guard" "$SRC"
if [ -d "$MARKET_ROOT/$SRC" ]; then ok "source path resolves to a directory"; else bad "source resolves" "no dir $MARKET_ROOT/$SRC"; fi
isfile "plugin manifest present at source" "$MARKET_ROOT/$SRC/.codex-plugin/plugin.json"
if jq -e . "$PJ" >/dev/null 2>&1; then ok ".codex-plugin/plugin.json valid JSON"; else bad "plugin.json JSON" "jq failed"; fi
HK=$(jq -r '.hooks' "$PJ")
eq "plugin.json hooks -> ./adapters/codex/hooks.json" "./adapters/codex/hooks.json" "$HK"
isfile "hooks file resolves" "$REPO/$(printf '%s' "$HK" | sed 's#^\./##')"
if jq -e . "$HOOKS" >/dev/null 2>&1; then ok "hooks.json valid JSON"; else bad "hooks.json JSON" "jq failed"; fi
if [ -x "$REPO/adapters/codex/adapter.sh" ]; then ok "codex adapter.sh present +x"; else bad "adapter +x" "missing"; fi

echo "=== 2. installer prints the correct native commands ==="
out=$("$INSTALL" codex 2>&1)
has "prints marketplace add" "codex plugin marketplace add norequest/plugins" "$out"
has "prints plugin install"  "codex plugin install cost-guard@norequest"      "$out"

# Run the wired hook command the way Codex does: the command string from
# hooks.json (it already embeds the canonical event arg), payload on stdin.
# $1 = Codex event key, $2 = payload. cwd = project root, CLAUDE_PLUGIN_ROOT set.
codex_cmd() { jq -r ".hooks.$1[0].hooks[0].command" "$HOOKS"; }
fire() {
  cmd=$(codex_cmd "$1")
  ( cd "$PROJ" && printf '%s' "$2" | env \
      CLAUDE_PLUGIN_ROOT="$REPO" COST_GUARD_STATE_DIR="$STATE" COST_GUARD_LOG_DIR="$LOG" COST_GUARD_MAX_REPEATS=2 \
      sh -c "$cmd" )
}

echo "=== 3. wired command gates (CLAUDE_PLUGIN_ROOT set) + Stop writes the ledger ==="
SID="cdx-1"
fire SessionStart "$(jq -nc --arg s "$SID" '{session_id:$s, cwd:"/repo", source:"startup"}')" >/dev/null
a=$(fire PreToolUse "$(jq -nc --arg s "$SID" '{session_id:$s, tool_name:"Read", tool_input:{path:"a"}}')")
eq "allow -> hookSpecificOutput.permissionDecision=allow" allow "$(printf '%s' "$a" | jq -r '.hookSpecificOutput.permissionDecision')"
LOOP=$(jq -nc --arg s "$SID" '{session_id:$s, tool_name:"Bash", tool_input:{command:"npm test"}}')
fire PreToolUse "$LOOP" >/dev/null
fire PreToolUse "$LOOP" >/dev/null
d=$(fire PreToolUse "$LOOP")
eq  "loop deny -> permissionDecision=deny" deny  "$(printf '%s' "$d" | jq -r '.hookSpecificOutput.permissionDecision')"
has "deny reason is instructive"           "Loop" "$(printf '%s' "$d" | jq -r '.hookSpecificOutput.permissionDecisionReason')"
fire Stop "$(jq -nc --arg s "$SID" '{session_id:$s, reason:"stop"}')" >/dev/null
if [ -f "$LOG/sessions.jsonl" ]; then
  rec=$(tail -1 "$LOG/sessions.jsonl")
  eq "ledger platform = codex"   codex "$(printf '%s' "$rec" | jq -r '.platform')"
  eq "ledger recorded a denial"  true  "$(printf '%s' "$rec" | jq -r '(.denials >= 1)')"
  eq "ledger flagged the loop"   true  "$(printf '%s' "$rec" | jq -r '(.loops >= 1)')"
else
  bad "sessions.jsonl written" "not found"
fi

echo '=== 4. "." fallback: CLAUDE_PLUGIN_ROOT unset, cwd = plugin root, still gates ==='
cmd=$(codex_cmd PreToolUse)
fb=$( cd "$REPO" && printf '%s' "$(jq -nc '{session_id:"fb1", tool_name:"Read", tool_input:{path:"a"}}')" | env -u CLAUDE_PLUGIN_ROOT \
      COST_GUARD_STATE_DIR="$FSTATE" COST_GUARD_LOG_DIR="$FSTATE" COST_GUARD_MAX_REPEATS=2 sh -c "$cmd" )
eq "fallback (var unset, cwd = plugin root) resolves and allows" allow "$(printf '%s' "$fb" | jq -r '.hookSpecificOutput.permissionDecision')"

printf '\n---------------------------------------------\n'
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
