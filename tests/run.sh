#!/usr/bin/env bash
# cost-guard :: verification test harness
#
# Drives every platform adapter end-to-end through the neutral core and asserts
# the full escalation ladder in that platform's native decision shape. Each
# platform runs in an isolated mktemp state+log dir with deliberately low
# thresholds so the ladder is easy to trip:
#
#   MAX_REPEATS=2  SOFT_CALLS=4  MAX_CALLS=6  MAX_FAIL_STREAK=3  SOFT_ACTION=ask
#
# Only bash + jq are required (both are hard deps of cost-guard itself).
#
# Usage: bash tests/run.sh
set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(dirname "$SCRIPT_DIR")
PAYLOADS="$SCRIPT_DIR/payloads"

PLATFORMS="claude-code copilot cursor codex gemini"

PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); printf '  \xe2\x9c\x93 %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  \xe2\x9c\x97 %s\n' "$1"; }

# check <desc> <expected> <actual>
check() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1  (expected [$2] got [$3])"; fi
}
# contains <desc> <needle> <haystack>
contains() {
  case "$3" in
    *"$2"*) ok "$1" ;;
    *)      bad "$1  (missing [$2] in [$3])" ;;
  esac
}

# ------------------------------------------------------------------ invocation
# run_adapter <platform> <event> <raw-json>  -> adapter stdout
run_adapter() {
  printf '%s' "$3" | env \
    COST_GUARD_STATE_DIR="$STATE_DIR" \
    COST_GUARD_LOG_DIR="$LOG_DIR" \
    COST_GUARD_MAX_CALLS=6 \
    COST_GUARD_SOFT_CALLS=4 \
    COST_GUARD_MAX_REPEATS=2 \
    COST_GUARD_MAX_FAIL_STREAK=3 \
    COST_GUARD_MAX_MINUTES=999 \
    COST_GUARD_SOFT_ACTION=ask \
    bash "$REPO/adapters/$1/adapter.sh" "$2"
}

# ------------------------------------------------------- raw payload builders
# Each platform's REAL field names live here and nowhere else.
build_start() { # <platform> <sid>
  case "$1" in
    copilot) jq -nc --arg s "$2" '{sessionId:$s, cwd:"/repo", source:"cli"}' ;;
    cursor)  jq -nc --arg s "$2" '{conversation_id:$s, workspace_roots:["/repo"], composer_mode:"agent"}' ;;
    *)       jq -nc --arg s "$2" '{session_id:$s, cwd:"/repo", source:"startup"}' ;;
  esac
}
build_pre() { # <platform> <sid> <tool> <args-json>
  case "$1" in
    copilot) jq -nc --arg s "$2" --arg t "$3" --argjson a "$4" '{sessionId:$s, toolName:$t, toolArgs:$a}' ;;
    cursor)  jq -nc --arg s "$2" --arg t "$3" --argjson a "$4" '{conversation_id:$s, tool_name:$t, tool_input:$a}' ;;
    *)       jq -nc --arg s "$2" --arg t "$3" --argjson a "$4" '{session_id:$s, tool_name:$t, tool_input:$a}' ;;
  esac
}
build_end() { # <platform> <sid> <reason>
  case "$1" in
    copilot) jq -nc --arg s "$2" --arg r "$3" '{sessionId:$s, reason:$r}' ;;
    cursor)  jq -nc --arg s "$2" --arg r "$3" '{conversation_id:$s, reason:$r}' ;;
    *)       jq -nc --arg s "$2" --arg r "$3" '{session_id:$s, reason:$r}' ;;
  esac
}
# Push ONE failure into the streak. copilot/cursor have a native error event;
# claude-code/codex/gemini infer failure from a post-tool with an error payload.
push_error() { # <platform> <sid>
  case "$1" in
    copilot) run_adapter copilot error "$(jq -nc --arg s "$2" '{sessionId:$s}')" >/dev/null ;;
    cursor)  run_adapter cursor  error "$(jq -nc --arg s "$2" '{conversation_id:$s}')" >/dev/null ;;
    *)       run_adapter "$1" post-tool \
               "$(jq -nc --arg s "$2" '{session_id:$s, tool_name:"Bash", tool_response:{is_error:true, error:"boom"}}')" >/dev/null ;;
  esac
}

# ----------------------------------------------------- decision interpretation
# classify <platform> <adapter-stdout> -> allow|deny|ask|silent|none
classify() {
  case "$1" in
    gemini)
      [ -z "$2" ] && { printf 'silent'; return; }
      printf '%s' "$2" | jq -r '.decision // "none"' 2>/dev/null || printf 'none' ;;
    cursor)
      printf '%s' "$2" | jq -r '.permission // "none"' 2>/dev/null || printf 'none' ;;
    copilot)
      printf '%s' "$2" | jq -r '.permissionDecision // "none"' 2>/dev/null || printf 'none' ;;
    claude-code|codex)
      printf '%s' "$2" | jq -r '.hookSpecificOutput.permissionDecision // "none"' 2>/dev/null || printf 'none' ;;
  esac
}
# reason_of <platform> <adapter-stdout> -> the human/agent reason string
reason_of() {
  case "$1" in
    gemini)            printf '%s' "$2" | jq -r '.reason // ""' 2>/dev/null ;;
    cursor)            printf '%s' "$2" | jq -r '.agent_message // .user_message // ""' 2>/dev/null ;;
    copilot)           printf '%s' "$2" | jq -r '.permissionDecisionReason // ""' 2>/dev/null ;;
    claude-code|codex) printf '%s' "$2" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' 2>/dev/null ;;
  esac
}
# For a plain ALLOW, gemini stays silent; everyone else says "allow".
allow_label() { [ "$1" = gemini ] && printf 'silent' || printf 'allow'; }

# =========================================================== per-platform suite
test_platform() {
  P="$1"
  STATE_DIR=$(mktemp -d 2>/dev/null || mktemp -d -t cgstate)
  LOG_DIR=$(mktemp -d 2>/dev/null || mktemp -d -t cglog)

  printf '\n=== %s ===\n' "$P"

  # (a) first pre-tool call -> ALLOW
  out=$(run_adapter "$P" pre-tool "$(build_pre "$P" cg-allow Bash '{"command":"ls"}')")
  check "(a) first pre-tool ALLOW ($(allow_label "$P"))" "$(allow_label "$P")" "$(classify "$P" "$out")"
  if [ "$P" = gemini ]; then
    check "(a) gemini ALLOW emits EMPTY stdout" "" "$out"
  fi

  # (b) same {tool,args} repeated past MAX_REPEATS -> loop DENY
  LOOP_ARGS='{"command":"grep -r TODO ."}'
  b1=$(run_adapter "$P" pre-tool "$(build_pre "$P" cg-loop Bash "$LOOP_ARGS")")
  run_adapter "$P" pre-tool "$(build_pre "$P" cg-loop Bash "$LOOP_ARGS")" >/dev/null
  b3=$(run_adapter "$P" pre-tool "$(build_pre "$P" cg-loop Bash "$LOOP_ARGS")")
  check "(b) loop call#1 ALLOW" "$(allow_label "$P")" "$(classify "$P" "$b1")"
  check "(b) loop call#3 DENY" deny "$(classify "$P" "$b3")"
  contains "(b) loop DENY reason names the loop" "Loop detected" "$(reason_of "$P" "$b3")"

  # (c) distinct calls crossing SOFT_CALLS -> soft checkpoint (ask; gemini silent)
  for n in 1 2 3; do
    run_adapter "$P" pre-tool "$(build_pre "$P" cg-soft Bash "$(jq -nc --arg c "echo $n" '{command:$c}')")" >/dev/null
  done
  c4=$(run_adapter "$P" pre-tool "$(build_pre "$P" cg-soft Bash '{"command":"echo four"}')")
  if [ "$P" = gemini ]; then
    check "(c) soft checkpoint -> silent (ask degrades to allow)" silent "$(classify "$P" "$c4")"
    check "(c) gemini soft checkpoint EMPTY stdout" "" "$c4"
  else
    check "(c) soft checkpoint -> ask" ask "$(classify "$P" "$c4")"
    contains "(c) soft checkpoint reason mentions checkpoint" "Cost checkpoint" "$(reason_of "$P" "$c4")"
  fi

  # (d) distinct calls crossing MAX_CALLS -> ceiling DENY
  for n in 1 2 3 4 5; do
    run_adapter "$P" pre-tool "$(build_pre "$P" cg-ceil Bash "$(jq -nc --arg c "step $n" '{command:$c}')")" >/dev/null
  done
  d6=$(run_adapter "$P" pre-tool "$(build_pre "$P" cg-ceil Bash '{"command":"step six"}')")
  check "(d) ceiling DENY at MAX_CALLS" deny "$(classify "$P" "$d6")"
  contains "(d) ceiling DENY reason names budget" "budget exhausted" "$(reason_of "$P" "$d6")"

  # (e) MAX_FAIL_STREAK errors then a pre-tool -> failure-streak DENY
  run_adapter "$P" session-start "$(build_start "$P" cg-streak)" >/dev/null
  push_error "$P" cg-streak
  push_error "$P" cg-streak
  push_error "$P" cg-streak
  e=$(run_adapter "$P" pre-tool "$(build_pre "$P" cg-streak Read '{"path":"x.txt"}')")
  check "(e) failure-streak DENY" deny "$(classify "$P" "$e")"
  contains "(e) failure-streak reason names failures" "consecutive tool failures" "$(reason_of "$P" "$e")"

  # (f) session-end -> JSONL record with correct platform + endReason;
  #     error/timeout/abort also land in wasted-sessions.jsonl
  run_adapter "$P" session-start "$(build_start "$P" cg-endok)"  >/dev/null
  run_adapter "$P" session-end   "$(build_end   "$P" cg-endok logout)"  >/dev/null
  run_adapter "$P" session-start "$(build_start "$P" cg-endbad)" >/dev/null
  run_adapter "$P" session-end   "$(build_end   "$P" cg-endbad timeout)" >/dev/null

  sess="$LOG_DIR/sessions.jsonl"
  wasted="$LOG_DIR/wasted-sessions.jsonl"
  check "(f) sessions.jsonl normal .platform"  "$P"    "$(jq -r 'select(.sessionId=="cg-endok")|.platform'  "$sess"   2>/dev/null | head -1)"
  check "(f) sessions.jsonl normal .endReason" logout  "$(jq -r 'select(.sessionId=="cg-endok")|.endReason' "$sess"   2>/dev/null | head -1)"
  check "(f) wasted-sessions.jsonl .platform"  "$P"    "$(jq -r 'select(.sessionId=="cg-endbad")|.platform'  "$wasted" 2>/dev/null | head -1)"
  check "(f) wasted-sessions.jsonl .endReason" timeout "$(jq -r 'select(.sessionId=="cg-endbad")|.endReason' "$wasted" 2>/dev/null | head -1)"
  check "(f) normal (logout) end NOT in wasted" "" "$(jq -r 'select(.sessionId=="cg-endok")|.sessionId' "$wasted" 2>/dev/null | head -1)"

  # (g) fail-open: with jq absent the gate still ALLOWs (gemini stays silent).
  #     Build a PATH with the fail-open path's tools but deliberately NO jq.
  NOJQ="$LOG_DIR/nojq-bin"
  mkdir -p "$NOJQ"
  for t in bash sh env dirname pwd cat tr grep printf ln readlink basename expr; do
    rp=$(command -v "$t" 2>/dev/null) && ln -sf "$rp" "$NOJQ/$t"
  done
  fo=$(printf '%s' "$(build_pre "$P" cg-failopen Bash '{"command":"ls"}')" \
        | PATH="$NOJQ" bash "$REPO/adapters/$P/adapter.sh" pre-tool 2>/dev/null)
  check "(g) fail-open (no jq) still ALLOWs" "$(allow_label "$P")" "$(classify "$P" "$fo")"

  # (h) sample payload files parse cleanly through the adapter
  SM_STATE=$(mktemp -d 2>/dev/null || mktemp -d -t cgsmoke)
  for ev in session-start pre-tool post-tool session-end; do
    f="$PAYLOADS/$P-$ev.json"
    if [ ! -f "$f" ]; then bad "(h) sample payload missing: $P-$ev.json"; continue; fi
    sout=$(env COST_GUARD_STATE_DIR="$SM_STATE" COST_GUARD_LOG_DIR="$SM_STATE" \
             bash "$REPO/adapters/$P/adapter.sh" "$ev" < "$f"); rc=$?
    check "(h) sample $P-$ev.json exits 0" 0 "$rc"
    if [ "$ev" = pre-tool ]; then
      check "(h) sample $P-$ev.json -> $(allow_label "$P")" "$(allow_label "$P")" "$(classify "$P" "$sout")"
    fi
  done
}

for P in $PLATFORMS; do
  test_platform "$P"
done

printf '\n---------------------------------------------\n'
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
