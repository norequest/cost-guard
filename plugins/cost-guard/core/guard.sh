#!/usr/bin/env bash
# cost-guard :: platform-neutral core engine (bash + jq)
#
# Reads ONE canonical JSON object on stdin and dispatches on `.event`:
#
#   session-start  {event,sessionId,cwd,source,platform,user?,gitEmail?,host?}
#   pre-tool       {event,sessionId,tool,args,platform}   -> emits {decision,reason}
#   post-tool      {event,sessionId,resultText,platform}
#   error          {event,sessionId,platform}
#   session-end    {event,sessionId,endReason,platform}
#
# Only `pre-tool` writes to stdout — the escalation-ladder decision:
#   {"decision":"allow|deny|ask","reason":"..."}
# Adapters translate that into each agent's native permission format.
#
# All agent-specific field names live in the adapters; this file never sees
# them. Keep it fast and local-only: the network call happens on session-end,
# never in the pre-tool hot path.
#
# Fail policy (mirrors the original hook): missing jq, an unsafe state dir, a
# corrupt state file, or a bookkeeping error on pre-tool -> ALLOW (never brick
# a session on our account). State writes are atomic (write-temp + mv) and
# best-effort locked with an mkdir lock (no flock dependency, macOS-safe); if
# the lock can't be acquired the guard proceeds without it rather than block.
set -u

emit_allow() { printf '{"decision":"allow","reason":""}'; }

# jq is our only hard dependency. Without it we cannot do bookkeeping — for the
# gating event, fail OPEN; for passive events, do nothing.
if ! command -v jq >/dev/null 2>&1; then
  INPUT=$(cat 2>/dev/null || true)
  case "$(printf '%s' "$INPUT" | tr -dc 'a-z-' | grep -o 'pre-tool' 2>/dev/null || true)" in
    pre-tool) emit_allow ;;
  esac
  exit 0
fi

# ---- best-effort mkdir lock: released automatically on any exit ----
LOCK_DIR=""
# shellcheck disable=SC2329 # invoked indirectly via the EXIT trap below
release_lock() {
  if [ -n "$LOCK_DIR" ]; then
    rm -rf "$LOCK_DIR" 2>/dev/null
    LOCK_DIR=""
  fi
}
trap release_lock EXIT

is_uint() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

INPUT=$(cat)
EVENT=$(printf '%s' "$INPUT" | jq -r '.event // ""')
SID=$(printf '%s' "$INPUT" | jq -r '.sessionId // "unknown"')
PLATFORM=$(printf '%s' "$INPUT" | jq -r '.platform // "unknown"')

# ---- State dir: per-uid by default so a shared /tmp can't be pre-seeded or
# symlink-swapped by another user. Verify it after creation; if it doesn't
# check out, disable the guard for this session rather than trust it. ----
STATE_DIR="${COST_GUARD_STATE_DIR:-${TMPDIR:-/tmp}/cost-guard-$(id -u)}"
LOG_DIR="${COST_GUARD_LOG_DIR:-$HOME/.cost-guard}"

mkdir -p "$STATE_DIR" 2>/dev/null || true
chmod 700 "$STATE_DIR" 2>/dev/null || true

state_dir_safe() {
  [ -L "$STATE_DIR" ] && return 1
  [ -d "$STATE_DIR" ] || return 1
  local line owner_uid
  line=$(ls -ldn "$STATE_DIR" 2>/dev/null) || return 1
  read -r _ _ owner_uid _ <<EOF
$line
EOF
  [ "$owner_uid" = "$(id -u)" ]
}

if ! state_dir_safe; then
  printf 'cost-guard: state dir unsafe, guard disabled for this session\n' >&2
  [ "$EVENT" = "pre-tool" ] && emit_allow
  exit 0
fi

STATE="$STATE_DIR/$SID.json"
NOW=$(date +%s)

# ---- Tunables (env-overridable). A value that is set but not ^[0-9]+$ falls
# back to the default silently, batched into a single stderr note. ----
BAD_ENV_VARS=""

if [ -n "${COST_GUARD_MAX_CALLS+x}" ] && is_uint "$COST_GUARD_MAX_CALLS"; then
  MAX_CALLS="$COST_GUARD_MAX_CALLS"
elif [ -n "${COST_GUARD_MAX_CALLS+x}" ]; then
  MAX_CALLS=120
  BAD_ENV_VARS="${BAD_ENV_VARS:+$BAD_ENV_VARS }COST_GUARD_MAX_CALLS"
else
  MAX_CALLS=120
fi

if [ -n "${COST_GUARD_SOFT_CALLS+x}" ] && is_uint "$COST_GUARD_SOFT_CALLS"; then
  SOFT_CALLS="$COST_GUARD_SOFT_CALLS"
elif [ -n "${COST_GUARD_SOFT_CALLS+x}" ]; then
  SOFT_CALLS=50
  BAD_ENV_VARS="${BAD_ENV_VARS:+$BAD_ENV_VARS }COST_GUARD_SOFT_CALLS"
else
  SOFT_CALLS=50
fi

if [ -n "${COST_GUARD_MAX_REPEATS+x}" ] && is_uint "$COST_GUARD_MAX_REPEATS"; then
  MAX_REPEATS="$COST_GUARD_MAX_REPEATS"
elif [ -n "${COST_GUARD_MAX_REPEATS+x}" ]; then
  MAX_REPEATS=3
  BAD_ENV_VARS="${BAD_ENV_VARS:+$BAD_ENV_VARS }COST_GUARD_MAX_REPEATS"
else
  MAX_REPEATS=3
fi

if [ -n "${COST_GUARD_MAX_MINUTES+x}" ] && is_uint "$COST_GUARD_MAX_MINUTES"; then
  MAX_MINUTES="$COST_GUARD_MAX_MINUTES"
elif [ -n "${COST_GUARD_MAX_MINUTES+x}" ]; then
  MAX_MINUTES=30
  BAD_ENV_VARS="${BAD_ENV_VARS:+$BAD_ENV_VARS }COST_GUARD_MAX_MINUTES"
else
  MAX_MINUTES=30
fi

if [ -n "${COST_GUARD_MAX_FAIL_STREAK+x}" ] && is_uint "$COST_GUARD_MAX_FAIL_STREAK"; then
  MAX_FAIL_STREAK="$COST_GUARD_MAX_FAIL_STREAK"
elif [ -n "${COST_GUARD_MAX_FAIL_STREAK+x}" ]; then
  MAX_FAIL_STREAK=5
  BAD_ENV_VARS="${BAD_ENV_VARS:+$BAD_ENV_VARS }COST_GUARD_MAX_FAIL_STREAK"
else
  MAX_FAIL_STREAK=5
fi

SOFT_ACTION="${COST_GUARD_SOFT_ACTION:-ask}"      # set to "deny" for CI / pipe mode

if [ -n "$BAD_ENV_VARS" ]; then
  printf 'cost-guard: ignoring invalid numeric env value(s) [%s], using defaults\n' "$BAD_ENV_VARS" >&2
fi

# ---- mkdir-based lock (no flock dependency; safe on macOS). Best-effort:
# never blocks the host agent — if it can't be acquired we proceed without it. ----
acquire_lock() { # $1 = state file path; lock dir is "$1.lock"
  local target="$1.lock" tries=0 created age
  while [ "$tries" -lt 50 ]; do
    if mkdir "$target" 2>/dev/null; then
      printf '%s' "$NOW" > "$target/created" 2>/dev/null || true
      LOCK_DIR="$target"
      return 0
    fi
    tries=$((tries + 1))
    if [ -d "$target" ]; then
      created=$(cat "$target/created" 2>/dev/null || printf '')
      is_uint "$created" || created=""
      if [ -n "$created" ]; then
        age=$((NOW - created))
        if [ "$age" -ge 5 ]; then
          rm -rf "$target" 2>/dev/null
          continue
        fi
      fi
    fi
    sleep 0.02
  done
  return 1
}

# ---- Corrupt/empty state repair: never permanent-deny, never permanent-allow.
state_is_valid() {
  local f="$1" started
  [ -s "$f" ] || return 1
  started=$(jq -r '.startedAt // "null"' "$f" 2>/dev/null) || return 1
  case "$started" in
    ''|null) return 1 ;;
  esac
  is_uint "$started"
}

repair_if_corrupt() { # assumes $STATE exists; re-bootstraps in place if invalid
  if ! state_is_valid "$STATE"; then
    printf 'cost-guard: state was corrupt, reset\n' >&2
    bootstrap_state "" ""
  fi
}

bootstrap_state() { # $1=cwd $2=source ; capture local identity (hooks carry none)
  local cwd="${1:-}" src="${2:-}"
  local git_email os_user host_val tmp
  git_email=$(git config user.email 2>/dev/null || echo "")
  os_user="${USER:-${USERNAME:-unknown}}"
  host_val=$(hostname 2>/dev/null || echo "unknown")
  tmp="$STATE.tmp.$$.boot"
  jq -n \
    --arg sid "$SID" --arg cwd "$cwd" --arg src "$src" --arg plat "$PLATFORM" \
    --arg user "$os_user" --arg email "$git_email" --arg host "$host_val" \
    --argjson now "$NOW" \
    '{sessionId:$sid, platform:$plat, cwd:$cwd, source:$src,
      user:$user, gitEmail:$email, host:$host, startedAt:$now,
      count:0, lastHash:"", streak:0, failStreak:0, outputBytes:0, denials:0, asks:0}' \
    > "$tmp" && mv "$tmp" "$STATE"
}

case "$EVENT" in

# ---------------------------------------------------------------- session-start
session-start)
  CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // ""')
  SRC=$(printf '%s' "$INPUT" | jq -r '.source // ""')
  acquire_lock "$STATE" || true
  bootstrap_state "$CWD" "$SRC"
  exit 0
  ;;

# -------------------------------------------------------------------- pre-tool
pre-tool)
  acquire_lock "$STATE" || true

  # State may be missing (sessionStart hook skipped, or platform has none) — bootstrap.
  # Or present but corrupt/empty — repair in place and keep going.
  if [ -f "$STATE" ]; then
    repair_if_corrupt
  else
    bootstrap_state "" ""
  fi

  # Fingerprint = tool name + normalized args (sorted keys for stability).
  HASH_INPUT=$(printf '%s' "$INPUT" | jq -cS '{t:(.tool // ""), a:(.args // {})}')
  if command -v sha1sum >/dev/null 2>&1; then
    HASH=$(printf '%s' "$HASH_INPUT" | sha1sum | cut -d' ' -f1)
  else
    HASH=$(printf '%s' "$HASH_INPUT" | shasum | cut -d' ' -f1)   # macOS
  fi

  TMP="$STATE.tmp.$$"
  jq --arg h "$HASH" '
      if (.lastHash // "") == $h
      then .streak = ((.streak // 0) + 1)
      else .streak = 1
      end
      | .lastHash = $h
      | .count += 1
    ' "$STATE" > "$TMP" \
    && mv "$TMP" "$STATE" || { emit_allow; exit 0; }

  COUNT=$(jq -r '.count' "$STATE")
  STREAK=$(jq -r '.streak // 0' "$STATE")
  FAILS=$(jq -r '.failStreak // 0' "$STATE")
  STARTED=$(jq -r '.startedAt // 0' "$STATE")
  is_uint "$STARTED" || STARTED=0
  if [ "$STARTED" -le 0 ] || [ "$STARTED" -gt "$NOW" ]; then
    T3="$STATE.tmp3.$$"
    jq --argjson now "$NOW" '.startedAt = $now' "$STATE" > "$T3" && mv "$T3" "$STATE"
    STARTED="$NOW"
  fi
  ELAPSED_MIN=$(( (NOW - STARTED) / 60 ))

  decide() { # $1=allow|deny|ask $2=reason ; record it in state, emit, exit
    local key="denials"; [ "$1" = "ask" ] && key="asks"
    local t2="$STATE.tmp2.$$"
    jq ".$key += 1" "$STATE" > "$t2" && mv "$t2" "$STATE"
    jq -cn --arg d "$1" --arg r "$2" '{decision:$d, reason:$r}'
    exit 0
  }

  # 1. Loop detection — catches runaways earliest
  if [ "$STREAK" -gt "$MAX_REPEATS" ]; then
    decide deny "Loop detected: the same tool call has now been attempted ${STREAK} times in a row. Do NOT retry it again. Explain what is blocking you and either try a genuinely different approach or summarize and stop."
  fi
  # 2. Failure streak — agent fighting the environment
  if [ "$FAILS" -ge "$MAX_FAIL_STREAK" ]; then
    decide deny "$FAILS consecutive tool failures. Stop retrying. Summarize the errors encountered and report the blocker instead of attempting further tool calls."
  fi
  # 3. Hard ceilings — kill switch
  if [ "$COUNT" -ge "$MAX_CALLS" ]; then
    decide deny "Session tool budget exhausted ($COUNT/$MAX_CALLS calls). Stop all further work immediately and produce a final summary of what was completed and what remains."
  fi
  if [ "$ELAPSED_MIN" -ge "$MAX_MINUTES" ]; then
    decide deny "Session time budget exhausted (${ELAPSED_MIN} min / ${MAX_MINUTES} min). Stop all further work and produce a final summary."
  fi
  # 4. Soft threshold — human checkpoint (interactive) or early stop (CI)
  if [ "$COUNT" -eq "$SOFT_CALLS" ] || { [ "$COUNT" -gt "$SOFT_CALLS" ] && [ $(( (COUNT - SOFT_CALLS) % 25 )) -eq 0 ]; }; then
    decide "$SOFT_ACTION" "Cost checkpoint: $COUNT tool calls used in this session (soft limit $SOFT_CALLS, hard limit $MAX_CALLS). Confirm to continue."
  fi
  # 5. Default
  emit_allow
  exit 0
  ;;

# -------------------------------------------------------------------- post-tool
post-tool)
  [ -f "$STATE" ] || exit 0
  acquire_lock "$STATE" || true
  repair_if_corrupt
  BYTES=$(printf '%s' "$INPUT" | jq -r '(.resultText // "") | tostring | length')
  TMP="$STATE.tmp.$$"
  jq --argjson b "${BYTES:-0}" '.failStreak = 0 | .outputBytes += $b' "$STATE" > "$TMP" \
    && mv "$TMP" "$STATE"
  exit 0
  ;;

# ------------------------------------------------------------------------ error
error)
  [ -f "$STATE" ] || exit 0
  acquire_lock "$STATE" || true
  repair_if_corrupt
  TMP="$STATE.tmp.$$"
  jq '.failStreak = ((.failStreak // 0) + 1)' "$STATE" > "$TMP" && mv "$TMP" "$STATE"
  exit 0
  ;;

# ------------------------------------------------------------------ session-end
session-end)
  REASON=$(printf '%s' "$INPUT" | jq -r '.endReason // "unknown"')
  mkdir -p "$LOG_DIR" 2>/dev/null || true
  acquire_lock "$STATE" || true
  if [ -f "$STATE" ]; then
    repair_if_corrupt
    RECORD=$(jq -c --arg reason "$REASON" --argjson now "$NOW" \
      '. + {
         endReason: $reason,
         endedAt: $now,
         durationSec: ($now - (.startedAt // $now)),
         maxRepeats: (.streak // 0),
         loops: (if (.streak // 0) > 1 then 1 else 0 end)
       } | del(.lastHash)' "$STATE")
  else
    RECORD=$(jq -c -n --arg sid "$SID" --arg plat "$PLATFORM" --arg reason "$REASON" --argjson now "$NOW" \
      '{sessionId:$sid, platform:$plat, endReason:$reason, endedAt:$now, note:"no state found"}')
  fi

  printf '%s\n' "$RECORD" >> "$LOG_DIR/sessions.jsonl"
  case "$REASON" in
    error|timeout|abort)
      printf '%s\n' "$RECORD" >> "$LOG_DIR/wasted-sessions.jsonl" ;;
  esac

  if [ -n "${COST_GUARD_COLLECTOR_URL:-}" ] && command -v curl >/dev/null 2>&1; then
    printf '%s' "$RECORD" | curl -s -m 10 -X POST \
      -H 'Content-Type: application/json' \
      --data-binary @- "$COST_GUARD_COLLECTOR_URL" >/dev/null 2>&1 || true
  fi

  rm -f "$STATE" "$STATE".tmp.* "$STATE".tmp2.* "$STATE".tmp3.* 2>/dev/null
  exit 0
  ;;

*)
  # Unknown event: do nothing, succeed.
  exit 0
  ;;
esac
