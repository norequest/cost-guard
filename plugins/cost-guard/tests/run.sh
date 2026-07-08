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
# Usage (from the repo root): bash plugins/cost-guard/tests/run.sh
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

# ================================================================ core suite
# These exercise core/guard.sh directly with its own canonical event shape
# (event/sessionId/tool/args/platform) rather than through an adapter, since
# state-dir hardening, corrupt-state repair, the loop streak, time-budget
# sanity, env validation, and locking are all platform-neutral core behavior.
core_start() { jq -nc --arg s "$1" '{event:"session-start", sessionId:$s, cwd:"/repo", source:"cli", platform:"core-test"}'; }
core_pre()   { jq -nc --arg s "$1" --arg t "$2" --argjson a "$3" '{event:"pre-tool", sessionId:$s, tool:$t, args:$a, platform:"core-test"}'; }

test_core_hardening() {
  printf '\n=== core hardening ===\n'

  # ---- (i) state dir hardening: per-uid default, real dir, mode 700, not a symlink ----
  DEFAULT_STATE_DIR="${TMPDIR:-/tmp}"
  case "$DEFAULT_STATE_DIR" in */) : ;; *) DEFAULT_STATE_DIR="$DEFAULT_STATE_DIR/" ;; esac
  DEFAULT_STATE_DIR="${DEFAULT_STATE_DIR}cost-guard-$(id -u)"
  rm -rf "$DEFAULT_STATE_DIR" 2>/dev/null
  ( unset COST_GUARD_STATE_DIR
    COST_GUARD_LOG_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t cgdeflog)" \
      bash "$REPO/core/guard.sh" >/dev/null <<< "$(core_start cg-defaultdir)" )
  check "(i) default state dir is created" 1 "$([ -d "$DEFAULT_STATE_DIR" ] && echo 1 || echo 0)"
  check "(i) default state dir is not a symlink" 1 "$([ ! -L "$DEFAULT_STATE_DIR" ] && echo 1 || echo 0)"
  # shellcheck disable=SC2012 # single known path, not a filename listing
  perm=$(ls -ld "$DEFAULT_STATE_DIR" 2>/dev/null | cut -c1-10)
  check "(i) default state dir mode is 700 (drwx------)" "drwx------" "$perm"
  rm -rf "$DEFAULT_STATE_DIR" 2>/dev/null

  # ---- (ii) corrupt state file: pre-tool succeeds, stderr mentions reset, state resumes fresh ----
  CS_STATE=$(mktemp -d 2>/dev/null || mktemp -d -t cgcorrupt)
  CS_LOG=$(mktemp -d 2>/dev/null || mktemp -d -t cgcorruptlog)
  env COST_GUARD_STATE_DIR="$CS_STATE" COST_GUARD_LOG_DIR="$CS_LOG" \
    bash "$REPO/core/guard.sh" >/dev/null <<< "$(core_start cg-corrupt)"
  printf 'THIS IS NOT JSON {{{' > "$CS_STATE/cg-corrupt.json"
  CS_ERR=$(mktemp 2>/dev/null || mktemp -t cgcorrupterr)
  cs_out=$(env COST_GUARD_STATE_DIR="$CS_STATE" COST_GUARD_LOG_DIR="$CS_LOG" \
    bash "$REPO/core/guard.sh" 2>"$CS_ERR" <<< "$(core_pre cg-corrupt Bash '{"command":"ls"}')")
  check "(ii) corrupt-state pre-tool -> allow" allow "$(printf '%s' "$cs_out" | jq -r '.decision // "none"')"
  contains "(ii) corrupt-state stderr mentions reset" "state was corrupt, reset" "$(cat "$CS_ERR")"
  check "(ii) corrupt-state repaired: count resumes at 1" 1 "$(jq -r '.count' "$CS_STATE/cg-corrupt.json" 2>/dev/null)"
  rm -f "$CS_ERR"; rm -rf "$CS_STATE" "$CS_LOG"

  # ---- (iii) empty state file: same contract as corrupt ----
  ES_STATE=$(mktemp -d 2>/dev/null || mktemp -d -t cgempty)
  ES_LOG=$(mktemp -d 2>/dev/null || mktemp -d -t cgemptylog)
  env COST_GUARD_STATE_DIR="$ES_STATE" COST_GUARD_LOG_DIR="$ES_LOG" \
    bash "$REPO/core/guard.sh" >/dev/null <<< "$(core_start cg-empty)"
  : > "$ES_STATE/cg-empty.json"
  ES_ERR=$(mktemp 2>/dev/null || mktemp -t cgemptyerr)
  es_out=$(env COST_GUARD_STATE_DIR="$ES_STATE" COST_GUARD_LOG_DIR="$ES_LOG" \
    bash "$REPO/core/guard.sh" 2>"$ES_ERR" <<< "$(core_pre cg-empty Bash '{"command":"ls"}')")
  check "(iii) empty-state pre-tool -> allow" allow "$(printf '%s' "$es_out" | jq -r '.decision // "none"')"
  contains "(iii) empty-state stderr mentions reset" "state was corrupt, reset" "$(cat "$ES_ERR")"
  check "(iii) empty-state repaired: count resumes at 1" 1 "$(jq -r '.count' "$ES_STATE/cg-empty.json" 2>/dev/null)"
  rm -f "$ES_ERR"; rm -rf "$ES_STATE" "$ES_LOG"

  # ---- (iv) consecutive-streak loop rule (defaults: MAX_REPEATS=3) ----
  LP_STATE=$(mktemp -d 2>/dev/null || mktemp -d -t cgloop)
  LP_LOG=$(mktemp -d 2>/dev/null || mktemp -d -t cglooplog)

  env COST_GUARD_STATE_DIR="$LP_STATE" COST_GUARD_LOG_DIR="$LP_LOG" \
    bash "$REPO/core/guard.sh" >/dev/null <<< "$(core_start cg-streak4)"
  for _ in 1 2 3; do
    env COST_GUARD_STATE_DIR="$LP_STATE" COST_GUARD_LOG_DIR="$LP_LOG" \
      bash "$REPO/core/guard.sh" >/dev/null <<< "$(core_pre cg-streak4 Bash '{"command":"same"}')"
  done
  loop4=$(env COST_GUARD_STATE_DIR="$LP_STATE" COST_GUARD_LOG_DIR="$LP_LOG" \
    bash "$REPO/core/guard.sh" <<< "$(core_pre cg-streak4 Bash '{"command":"same"}')")
  check "(iv) 4x identical calls in a row deny on the 4th (default MAX_REPEATS)" deny "$(printf '%s' "$loop4" | jq -r '.decision')"
  contains "(iv) loop deny uses the new phrasing" "attempted 4 times in a row" "$(printf '%s' "$loop4" | jq -r '.reason')"

  env COST_GUARD_STATE_DIR="$LP_STATE" COST_GUARD_LOG_DIR="$LP_LOG" \
    bash "$REPO/core/guard.sh" >/dev/null <<< "$(core_start cg-aabaa)"
  seq_denied=allow
  for spec in A A B A A; do
    out=$(env COST_GUARD_STATE_DIR="$LP_STATE" COST_GUARD_LOG_DIR="$LP_LOG" \
      bash "$REPO/core/guard.sh" <<< "$(core_pre cg-aabaa Bash "$(jq -nc --arg c "$spec" '{command:$c}')")")
    [ "$(printf '%s' "$out" | jq -r '.decision')" = deny ] && seq_denied=deny
  done
  check "(iv) A,A,B,A,A with default MAX_REPEATS never denies" allow "$seq_denied"
  rm -rf "$LP_STATE" "$LP_LOG"

  # ---- (v) MAX_MINUTES time budget with a crafted stale startedAt ----
  TB_STATE=$(mktemp -d 2>/dev/null || mktemp -d -t cgtime)
  TB_LOG=$(mktemp -d 2>/dev/null || mktemp -d -t cgtimelog)
  env COST_GUARD_STATE_DIR="$TB_STATE" COST_GUARD_LOG_DIR="$TB_LOG" \
    bash "$REPO/core/guard.sh" >/dev/null <<< "$(core_start cg-timebudget)"
  TWO_H_AGO=$(( $(date +%s) - 7200 ))
  jq --argjson t "$TWO_H_AGO" '.startedAt = $t' "$TB_STATE/cg-timebudget.json" > "$TB_STATE/cg-timebudget.json.tmp" \
    && mv "$TB_STATE/cg-timebudget.json.tmp" "$TB_STATE/cg-timebudget.json"
  tb_out=$(env COST_GUARD_STATE_DIR="$TB_STATE" COST_GUARD_LOG_DIR="$TB_LOG" COST_GUARD_MAX_MINUTES=1 \
    bash "$REPO/core/guard.sh" <<< "$(core_pre cg-timebudget Bash '{"command":"x"}')")
  check "(v) MAX_MINUTES=1 with a 2h-old startedAt -> deny" deny "$(printf '%s' "$tb_out" | jq -r '.decision')"
  contains "(v) time-budget deny names the budget" "time budget exhausted" "$(printf '%s' "$tb_out" | jq -r '.reason')"

  # ---- (vi) startedAt in the future resets instead of denying ----
  env COST_GUARD_STATE_DIR="$TB_STATE" COST_GUARD_LOG_DIR="$TB_LOG" \
    bash "$REPO/core/guard.sh" >/dev/null <<< "$(core_start cg-futurestart)"
  FUTURE=$(( $(date +%s) + 100000 ))
  jq --argjson t "$FUTURE" '.startedAt = $t' "$TB_STATE/cg-futurestart.json" > "$TB_STATE/cg-futurestart.json.tmp" \
    && mv "$TB_STATE/cg-futurestart.json.tmp" "$TB_STATE/cg-futurestart.json"
  fut_out=$(env COST_GUARD_STATE_DIR="$TB_STATE" COST_GUARD_LOG_DIR="$TB_LOG" COST_GUARD_MAX_MINUTES=1 \
    bash "$REPO/core/guard.sh" <<< "$(core_pre cg-futurestart Bash '{"command":"x"}')")
  check "(vi) future startedAt resets instead of denying" allow "$(printf '%s' "$fut_out" | jq -r '.decision')"
  new_started=$(jq -r '.startedAt' "$TB_STATE/cg-futurestart.json" 2>/dev/null)
  now_ts=$(date +%s)
  check "(vi) startedAt reset to <= now" 1 "$( [ -n "$new_started" ] && [ "$new_started" -le "$now_ts" ] 2>/dev/null && echo 1 || echo 0)"
  rm -rf "$TB_STATE" "$TB_LOG"

  # ---- (vii) invalid numeric env falls back to the default, no crash ----
  BE_STATE=$(mktemp -d 2>/dev/null || mktemp -d -t cgbadenv)
  BE_LOG=$(mktemp -d 2>/dev/null || mktemp -d -t cgbadenvlog)
  env COST_GUARD_STATE_DIR="$BE_STATE" COST_GUARD_LOG_DIR="$BE_LOG" \
    bash "$REPO/core/guard.sh" >/dev/null <<< "$(core_start cg-badenv)"
  BE_ERR=$(mktemp 2>/dev/null || mktemp -t cgbadenverr)
  be_out=$(env COST_GUARD_STATE_DIR="$BE_STATE" COST_GUARD_LOG_DIR="$BE_LOG" COST_GUARD_MAX_CALLS=banana \
    bash "$REPO/core/guard.sh" 2>"$BE_ERR" <<< "$(core_pre cg-badenv Bash '{"command":"x"}')")
  check "(vii) COST_GUARD_MAX_CALLS=banana falls back, still allow" allow "$(printf '%s' "$be_out" | jq -r '.decision // "none"')"
  contains "(vii) invalid numeric env is noted on stderr" "COST_GUARD_MAX_CALLS" "$(cat "$BE_ERR")"
  rm -f "$BE_ERR"; rm -rf "$BE_STATE" "$BE_LOG"

  # ---- (viii) concurrency: 10 parallel pre-tool calls -> lock keeps count exact ----
  CC_STATE=$(mktemp -d 2>/dev/null || mktemp -d -t cgconc)
  CC_LOG=$(mktemp -d 2>/dev/null || mktemp -d -t cgconclog)
  env COST_GUARD_STATE_DIR="$CC_STATE" COST_GUARD_LOG_DIR="$CC_LOG" \
    bash "$REPO/core/guard.sh" >/dev/null <<< "$(core_start cg-conc)"
  for i in 1 2 3 4 5 6 7 8 9 10; do
    ( env COST_GUARD_STATE_DIR="$CC_STATE" COST_GUARD_LOG_DIR="$CC_LOG" \
        bash "$REPO/core/guard.sh" >/dev/null <<< "$(core_pre cg-conc Bash "$(jq -nc --arg c "step$i" '{command:$c}')")" ) &
  done
  wait
  check "(viii) 10 parallel pre-tool calls record exactly 10 (lock)" 10 "$(jq -r '.count' "$CC_STATE/cg-conc.json" 2>/dev/null)"
  rm -rf "$CC_STATE" "$CC_LOG"
}

test_core_hardening

printf '\n---------------------------------------------\n'
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
