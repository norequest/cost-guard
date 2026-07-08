#!/usr/bin/env bash
# cost-guard :: GitHub Copilot cloud-agent install smoke test (integration).
#
# Installs the cloud-agent wiring into a throwaway project via install.sh, then
# fires the hooks the way the Copilot cloud agent does: the `bash` command from
# .github/hooks/cost-guard.json, run with cwd = the repo root, the Copilot-shaped
# payload on stdin. The cloud agent DROPS sessionStart/sessionEnd, so the key
# case is lazy bootstrap: a first pre-tool with no prior session-start must still
# gate. Also checks the full lifecycle (ledger), the installer's no-clobber guard
# + FORCE override, and uninstall.
#
# This drives the real adapter + real core at the real cwd the cloud agent uses.
# It cannot cover the cloud runtime's own parse of cost-guard.json; everything
# from "the agent invokes the command" onward is verified.
#
# Requires bash + jq. Usage, from the repo root:
#   bash plugins/cost-guard/tests/smoke-copilot.sh
set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(dirname "$SCRIPT_DIR")           # plugins/cost-guard
INSTALL="$REPO/install/install.sh"

PROJ=$(mktemp -d 2>/dev/null || mktemp -d -t cgproj)
STATE=$(mktemp -d 2>/dev/null || mktemp -d -t cgstate)
LOG=$(mktemp -d 2>/dev/null || mktemp -d -t cglog)
trap 'rm -rf "$PROJ" "$STATE" "$LOG"' EXIT

printf '{\n  "name": "demo-repo"\n}\n' > "$PROJ/package.json"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  \xe2\x9c\x93 %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  \xe2\x9c\x97 %s  (%s)\n' "$1" "$2"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }
has() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "missing [$2] in [$3]" ;; esac; }
isfile() { if [ -f "$2" ]; then ok "$1"; else bad "$1" "missing $2"; fi; }

MAN="$PROJ/.github/hooks/cost-guard.json"

echo "=== 1. install the cloud-agent wiring ==="
"$INSTALL" copilot "$PROJ" >/dev/null
isfile ".github/hooks/cost-guard.json written" "$MAN"
if jq -e . "$MAN" >/dev/null 2>&1; then ok "cost-guard.json is valid JSON"; else bad "valid JSON" "jq failed"; fi
if [ -x "$PROJ/.github/hooks/cost-guard/adapter.sh" ]; then ok "adapter.sh installed +x"; else bad "adapter.sh +x" "missing"; fi
isfile "core/guard.sh bundled" "$PROJ/.github/hooks/cost-guard/core/guard.sh"

# Fire a hook the way the cloud agent does: the `bash` command from the manifest,
# cwd = repo root, payload on stdin. $1 = event key, $2 = sessionId, $3 = payload.
fire() {
  cmd=$(jq -r ".hooks.$1[0].bash" "$MAN")
  ( cd "$PROJ" && printf '%s' "$3" | env \
      COST_GUARD_STATE_DIR="$STATE" COST_GUARD_LOG_DIR="$LOG" COST_GUARD_MAX_REPEATS=2 \
      sh -c "$cmd" )
}

echo "=== 2. cloud lazy bootstrap: first pre-tool with NO session-start still gates ==="
A="cop-cloud"
la=$(fire preToolUse "$A" "$(jq -nc --arg s "$A" '{sessionId:$s, toolName:"Read", toolArgs:{path:"a"}}')")
eq "lazy-bootstrap pre-tool allows" allow "$(printf '%s' "$la" | jq -r '.permissionDecision')"
LOOP=$(jq -nc --arg s "$A" '{sessionId:$s, toolName:"Bash", toolArgs:{command:"npm test"}}')
fire preToolUse "$A" "$LOOP" >/dev/null
fire preToolUse "$A" "$LOOP" >/dev/null
ld=$(fire preToolUse "$A" "$LOOP")     # 3rd in a row, MAX_REPEATS=2 -> deny
eq  "lazy-bootstrap loop denies"          deny   "$(printf '%s' "$ld" | jq -r '.permissionDecision')"
has "deny reason is instructive"          "Loop" "$(printf '%s' "$ld" | jq -r '.permissionDecisionReason')"

echo "=== 3. full lifecycle (start + end) writes the session ledger ==="
B="cop-full"
fire sessionStart "$B" "$(jq -nc --arg s "$B" '{sessionId:$s, cwd:"/repo", source:"cloud"}')" >/dev/null
fb=$(fire preToolUse "$B" "$(jq -nc --arg s "$B" '{sessionId:$s, toolName:"Read", toolArgs:{path:"a"}}')")
eq "full-lifecycle allow" allow "$(printf '%s' "$fb" | jq -r '.permissionDecision')"
BL=$(jq -nc --arg s "$B" '{sessionId:$s, toolName:"Bash", toolArgs:{command:"x"}}')
fire preToolUse "$B" "$BL" >/dev/null
fire preToolUse "$B" "$BL" >/dev/null
fire preToolUse "$B" "$BL" >/dev/null
fire sessionEnd "$B" "$(jq -nc --arg s "$B" '{sessionId:$s, reason:"completed"}')" >/dev/null
if [ -f "$LOG/sessions.jsonl" ]; then
  rec=$(grep '"cop-full"' "$LOG/sessions.jsonl" | tail -1)
  eq "ledger platform = copilot" copilot "$(printf '%s' "$rec" | jq -r '.platform')"
  eq "ledger recorded a denial"  true    "$(printf '%s' "$rec" | jq -r '(.denials >= 1)')"
  eq "ledger flagged the loop"   true    "$(printf '%s' "$rec" | jq -r '(.loops >= 1)')"
else
  bad "sessions.jsonl written" "not found"
fi

echo "=== 4. installer no-clobber guard + FORCE override ==="
"$INSTALL" copilot "$PROJ" >/dev/null 2>&1
eq "second install refuses (exit 3)" 3 "$?"
FORCE=1 "$INSTALL" copilot "$PROJ" >/dev/null 2>&1
eq "FORCE=1 re-install succeeds (exit 0)" 0 "$?"

echo "=== 5. uninstall cleans up ==="
"$INSTALL" uninstall copilot "$PROJ" >/dev/null 2>&1
if [ -e "$MAN" ] || [ -d "$PROJ/.github/hooks/cost-guard" ]; then
  bad "uninstall removed cloud wiring" "still present"
else
  ok "uninstall removed cost-guard.json + cost-guard/"
fi

printf '\n---------------------------------------------\n'
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
