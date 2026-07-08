#!/usr/bin/env pwsh
#Requires -Version 7
# cost-guard :: platform-neutral core engine (PowerShell 7+ port of guard.sh)
#
# Reads ONE canonical JSON object on stdin and dispatches on `.event`:
#
#   session-start  {event,sessionId,cwd,source,platform,...}
#   pre-tool       {event,sessionId,tool,args,platform}   -> emits {decision,reason}
#   post-tool      {event,sessionId,resultText,platform}
#   error          {event,sessionId,platform}
#   session-end    {event,sessionId,endReason,platform}
#
# Only `pre-tool` writes a decision to stdout, the escalation-ladder result:
#   {"decision":"allow|deny|ask","reason":"..."}
# Adapters translate that into each agent's native permission format.
#
# This is a behavioural port of core/guard.sh (the source of truth). The two
# engines share ONE state schema:
#   {sessionId, platform, cwd, source, user, gitEmail, host, startedAt,
#    count, lastHash, streak, failStreak, outputBytes, denials, asks}
# Loop detection is a CONSECUTIVE-streak rule: `lastHash` is the fingerprint of
# the previous pre-tool call, `streak` is how many times in a row it repeated.
# The fingerprint is sha1 over the exact byte stream bash produces with
#   jq -cS '{t:(.tool // ""), a:(.args // {})}'
# i.e. compact JSON with object keys sorted ordinally at EVERY depth, UTF-8,
# no BOM, no trailing newline. See ConvertTo-CgCanonJson below.
#
# Hardening:
#   - state dir is verified to be a real directory (no reparse point/symlink);
#     if unsafe the guard disables itself for the session and fails OPEN.
#   - every state write is atomic (temp file in the same dir + rename over).
#   - every state read-modify-write runs under a named Local\ mutex derived
#     from the state file path; a 2s wait timeout proceeds WITHOUT the lock
#     (fail-open beats blocking).
#   - a corrupt/empty state file is re-bootstrapped in place (one stderr line),
#     never a permanent deny and never a permanently silent allow.
#
# Fail policy (mirrors guard.sh): a bookkeeping error on `pre-tool` -> emit the
# canonical ALLOW ({"decision":"allow","reason":""}); passive events do nothing.
$ErrorActionPreference = 'Stop'

function Write-CanonAllow { [Console]::Out.Write('{"decision":"allow","reason":""}') }

# Faithful equivalent of jq's `x // default` for the null/absent case.
function Def($v, $d) { if ($null -ne $v) { $v } else { $d } }

# True when $v is a real JSON-style number (as materialised by ConvertFrom-Json).
function Test-CgNumber($v) {
  return ($v -is [int] -or $v -is [long] -or $v -is [double] -or $v -is [decimal] -or
          $v -is [int16] -or $v -is [byte] -or $v -is [sbyte] -or $v -is [single] -or
          $v -is [uint16] -or $v -is [uint32] -or $v -is [uint64] -or
          $v -is [System.Numerics.BigInteger])
}

# Numeric coercion that never throws: default unless $v is a usable number.
function Num($v, $d) {
  if (Test-CgNumber $v) {
    try { return [long]$v } catch { return [long]$d }
  }
  return [long]$d
}

# Numeric tunables: use the env var only if it is all digits, else the default.
# An unguarded [int]$env:X cast can throw and take the whole engine down; this
# never does. Set-but-invalid values are collected for one batched stderr note
# (same line guard.sh prints).
$BadEnvVars = @()
function Get-CgEnvNum([string]$Name, [long]$Default) {
  $v = [Environment]::GetEnvironmentVariable($Name)
  if ($null -eq $v) { return $Default }
  if ($v -match '^[0-9]+$') {
    try { return [long]$v } catch { }
  }
  $script:BadEnvVars += $Name
  return $Default
}

# ---- canonical JSON (byte parity with `jq -cS`) -----------------------------
# jq string escaping: \" \\ \b \t \n \f \r, other C0 controls as \u00xx
# (lowercase hex), everything else emitted raw (UTF-8 on the wire).
function ConvertTo-CgJsonStr([string]$S) {
  $sb = [System.Text.StringBuilder]::new($S.Length + 8)
  [void]$sb.Append('"')
  foreach ($ch in $S.ToCharArray()) {
    $c = [int]$ch
    if ($c -eq 34)     { [void]$sb.Append('\"') }
    elseif ($c -eq 92) { [void]$sb.Append('\\') }
    elseif ($c -eq 8)  { [void]$sb.Append('\b') }
    elseif ($c -eq 9)  { [void]$sb.Append('\t') }
    elseif ($c -eq 10) { [void]$sb.Append('\n') }
    elseif ($c -eq 12) { [void]$sb.Append('\f') }
    elseif ($c -eq 13) { [void]$sb.Append('\r') }
    elseif ($c -lt 32) { [void]$sb.Append(('\u{0:x4}' -f $c)) }
    else               { [void]$sb.Append($ch) }
  }
  [void]$sb.Append('"')
  return $sb.ToString()
}

# Compact JSON with object keys sorted ORDINALLY at every depth, exactly like
# jq -cS. ConvertTo-Json cannot guarantee this (it neither sorts nor keeps
# jq's escaping), so we serialize by hand.
function ConvertTo-CgCanonJson($V) {
  if ($null -eq $V) { return 'null' }
  if ($V -is [bool]) { if ($V) { return 'true' } else { return 'false' } }
  if ($V -is [string]) { return (ConvertTo-CgJsonStr $V) }
  if ($V -is [char]) { return (ConvertTo-CgJsonStr ([string]$V)) }
  if ($V -is [int] -or $V -is [long] -or $V -is [int16] -or $V -is [byte] -or
      $V -is [sbyte] -or $V -is [uint16] -or $V -is [uint32] -or $V -is [uint64] -or
      $V -is [System.Numerics.BigInteger]) {
    return $V.ToString([System.Globalization.CultureInfo]::InvariantCulture)
  }
  if ($V -is [double] -or $V -is [single] -or $V -is [decimal]) {
    $d = [double]$V
    if ([double]::IsNaN($d) -or [double]::IsInfinity($d)) { return 'null' }
    if (($d -eq [math]::Truncate($d)) -and ([math]::Abs($d) -lt 1e15)) {
      # jq prints integral doubles without a fractional part (2.0 -> 2)
      return ([long]$d).ToString([System.Globalization.CultureInfo]::InvariantCulture)
    }
    return $d.ToString('R', [System.Globalization.CultureInfo]::InvariantCulture)
  }
  if ($V -is [System.Collections.IDictionary]) {
    $keys = [string[]]@(@($V.Keys) | ForEach-Object { [string]$_ })
    [System.Array]::Sort($keys, [System.StringComparer]::Ordinal)
    $parts = foreach ($k in $keys) { (ConvertTo-CgJsonStr $k) + ':' + (ConvertTo-CgCanonJson $V[$k]) }
    return '{' + (@($parts) -join ',') + '}'
  }
  if ($V -is [System.Management.Automation.PSCustomObject]) {
    $names = [string[]]@(@($V.PSObject.Properties) | ForEach-Object { [string]$_.Name })
    [System.Array]::Sort($names, [System.StringComparer]::Ordinal)
    $parts = foreach ($k in $names) { (ConvertTo-CgJsonStr $k) + ':' + (ConvertTo-CgCanonJson ($V.PSObject.Properties[$k].Value)) }
    return '{' + (@($parts) -join ',') + '}'
  }
  if ($V -is [System.Collections.IEnumerable]) {
    $parts = foreach ($item in $V) { ConvertTo-CgCanonJson $item }
    return '[' + (@($parts) -join ',') + ']'
  }
  # Last resort: stringize scalars we do not recognise.
  return (ConvertTo-CgJsonStr ([string]$V))
}

# Fingerprint hash, byte-identical to bash:
#   printf '%s' "$(jq -cS '{t:(.tool // ""), a:(.args // {})}')" | sha1sum
function Get-CgFingerprintHash([string]$Tool, $ToolArgs) {
  # jq's `//` swaps in the default for null AND false alike.
  $aJson = '{}'
  if ($null -ne $ToolArgs -and -not ($ToolArgs -is [bool] -and -not $ToolArgs)) {
    $aJson = ConvertTo-CgCanonJson $ToolArgs
  }
  $canon = '{"a":' + $aJson + ',"t":' + (ConvertTo-CgJsonStr $Tool) + '}'
  $sha = [System.Security.Cryptography.SHA1]::Create()
  try {
    $hb = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($canon))
  } finally { $sha.Dispose() }
  return (-join ($hb | ForEach-Object { $_.ToString('x2') }))
}

# ---- locking ----------------------------------------------------------------
# Named Local\ mutex derived from the state file path. WaitOne(2000); an
# AbandonedMutexException still means we own it. On timeout or any construction
# failure we proceed WITHOUT the lock: fail-open beats blocking an agent.
function Lock-CgState([string]$Path) {
  $m = $null
  $owned = $false
  try {
    $sha = [System.Security.Cryptography.SHA1]::Create()
    try { $hb = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Path)) }
    finally { $sha.Dispose() }
    $short = -join ($hb[0..7] | ForEach-Object { $_.ToString('x2') })
    $m = [System.Threading.Mutex]::new($false, ('Local\cost-guard-' + $short))
    try { $owned = $m.WaitOne(2000) }
    catch [System.Threading.AbandonedMutexException] { $owned = $true }
  } catch {
    if ($m) { try { $m.Dispose() } catch { } }
    $m = $null
    $owned = $false
  }
  return @{ Mutex = $m; Owned = $owned }
}

function Unlock-CgState($Lk) {
  if ($null -eq $Lk) { return }
  if ($Lk.Owned -and $Lk.Mutex) { try { $Lk.Mutex.ReleaseMutex() } catch { } }
  if ($Lk.Mutex) { try { $Lk.Mutex.Dispose() } catch { } }
}

# ---- atomic state write -----------------------------------------------------
# Write to a temp file in the SAME directory, then rename over the target.
function Write-CgStateAtomic([string]$Path, $State) {
  $json = $State | ConvertTo-Json -Depth 20
  $dir = [System.IO.Path]::GetDirectoryName($Path)
  $tmp = [System.IO.Path]::Combine($dir, ([System.IO.Path]::GetFileName($Path) + '.tmp.' + $PID + '.' + [System.IO.Path]::GetRandomFileName()))
  [System.IO.File]::WriteAllText($tmp, $json)
  [System.IO.File]::Move($tmp, $Path, $true)
}

# ---- state read with corruption detection -----------------------------------
# Returns @{ State = <hashtable or $null>; Corrupt = <bool>; Existed = <bool> }.
# Corrupt means: file exists but is empty, is not parseable JSON, is not a JSON
# object, or has a missing/non-numeric startedAt.
function Read-CgStateFile([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) {
    return @{ State = $null; Corrupt = $false; Existed = $false }
  }
  $rawState = $null
  try { $rawState = [System.IO.File]::ReadAllText($Path) } catch { $rawState = $null }
  if ($null -eq $rawState -or $rawState.Trim().Length -eq 0) {
    return @{ State = $null; Corrupt = $true; Existed = $true }
  }
  $st = $null
  try { $st = ConvertFrom-Json -InputObject $rawState -AsHashtable } catch { $st = $null }
  if ($null -eq $st -or -not ($st -is [System.Collections.IDictionary])) {
    return @{ State = $null; Corrupt = $true; Existed = $true }
  }
  if (-not (Test-CgNumber $st['startedAt'])) {
    return @{ State = $null; Corrupt = $true; Existed = $true }
  }
  return @{ State = $st; Corrupt = $false; Existed = $true }
}

# Build a fresh state object. Identity (user/gitEmail/host) is captured locally
# because hook payloads carry none. Field set matches guard.sh's bootstrap.
function New-CgState {
  param($Cwd, $Src, $Sid, $Platform, $Now)
  $gitEmail = ''
  try { $ge = (git config user.email 2>$null); if ($ge) { $gitEmail = [string]$ge } } catch { $gitEmail = '' }
  $osUser = if ($env:USER) { [string]$env:USER } elseif ($env:USERNAME) { [string]$env:USERNAME } else { 'unknown' }
  $hostVal = ''
  try { $hv = (hostname 2>$null); if ($hv) { $hostVal = [string]$hv } } catch { $hostVal = '' }
  if (-not $hostVal) { $hostVal = if ($env:COMPUTERNAME) { [string]$env:COMPUTERNAME } else { 'unknown' } }
  return [ordered]@{
    sessionId   = [string]$Sid
    platform    = [string]$Platform
    cwd         = [string](Def $Cwd '')
    source      = [string](Def $Src '')
    user        = $osUser
    gitEmail    = $gitEmail
    host        = $hostVal
    startedAt   = [long]$Now
    count       = 0
    lastHash    = ''
    streak      = 0
    failStreak  = 0
    outputBytes = 0
    denials     = 0
    asks        = 0
  }
}

# ---- read stdin (robust; handle empty) ----
$raw = ''
try { $raw = [Console]::In.ReadToEnd() } catch { $raw = '' }
$payload = $null
try { if ($raw -and $raw.Trim().Length -gt 0) { $payload = $raw | ConvertFrom-Json } } catch { $payload = $null }
if ($null -eq $payload) { exit 0 }

$EVENT = ''
try {
  $EVENT    = [string](Def $payload.event '')
  $SID      = [string](Def $payload.sessionId 'unknown')
  $PLATFORM = [string](Def $payload.platform 'unknown')

  # ---- state dir hardening ----
  $stateDir = $env:COST_GUARD_STATE_DIR
  if (-not $stateDir) { $stateDir = Join-Path ([System.IO.Path]::GetTempPath()) ('cost-guard-' + [Environment]::UserName) }
  $logDir = $env:COST_GUARD_LOG_DIR
  if (-not $logDir) { $logDir = Join-Path $HOME '.cost-guard' }

  if (-not (Test-Path -LiteralPath $stateDir)) {
    try { New-Item -ItemType Directory -Force -Path $stateDir | Out-Null } catch { }
  }
  try { $stateDir = Convert-Path -LiteralPath $stateDir -ErrorAction Stop } catch { }
  $dirOk = $false
  try {
    $di = [System.IO.DirectoryInfo]::new($stateDir)
    if ($di.Exists -and (($di.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0)) { $dirOk = $true }
  } catch { $dirOk = $false }
  if (-not $dirOk) {
    [Console]::Error.WriteLine('cost-guard: state dir unsafe, guard disabled for this session')
    if ($EVENT -eq 'pre-tool') { Write-CanonAllow }
    exit 0
  }

  $statePath = Join-Path $stateDir ($SID + '.json')
  $NOW = [long][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

  # ---- Tunables (env-overridable; a malformed value falls back to default) ----
  $MAX_CALLS   = Get-CgEnvNum 'COST_GUARD_MAX_CALLS'       120
  $SOFT_CALLS  = Get-CgEnvNum 'COST_GUARD_SOFT_CALLS'      50
  $MAX_REPEATS = Get-CgEnvNum 'COST_GUARD_MAX_REPEATS'     3
  $MAX_MINUTES = Get-CgEnvNum 'COST_GUARD_MAX_MINUTES'     30
  $MAX_FAILS   = Get-CgEnvNum 'COST_GUARD_MAX_FAIL_STREAK' 5
  $SOFT_ACTION = if ($env:COST_GUARD_SOFT_ACTION) { [string]$env:COST_GUARD_SOFT_ACTION } else { 'ask' }

  if ($BadEnvVars.Count -gt 0) {
    [Console]::Error.WriteLine('cost-guard: ignoring invalid numeric env value(s) [' + ($BadEnvVars -join ' ') + '], using defaults')
  }

  switch ($EVENT) {

    # ------------------------------------------------------------ session-start
    'session-start' {
      $lk = Lock-CgState $statePath
      try {
        $st = New-CgState -Cwd (Def $payload.cwd '') -Src (Def $payload.source '') -Sid $SID -Platform $PLATFORM -Now $NOW
        Write-CgStateAtomic $statePath $st
      } catch { } finally { Unlock-CgState $lk }
      exit 0
    }

    # ----------------------------------------------------------------- pre-tool
    'pre-tool' {
      $decided = $false
      $decision = 'allow'
      $reasonTxt = ''
      $lk = Lock-CgState $statePath
      try {
        $read = Read-CgStateFile $statePath
        $state = $read.State
        if ($read.Corrupt) {
          [Console]::Error.WriteLine('cost-guard: state was corrupt, reset')
        }
        if ($null -eq $state) {
          # Missing (sessionStart hook skipped) or corrupt: (re-)bootstrap.
          $state = New-CgState -Cwd '' -Src '' -Sid $SID -Platform $PLATFORM -Now $NOW
        }

        # Fingerprint = tool name + args, byte-parity with the bash engine.
        $tool = [string](Def $payload.tool '')
        $hash = Get-CgFingerprintHash -Tool $tool -ToolArgs $payload.args

        $state['count'] = (Num $state['count'] 0) + 1
        $lastHash = [string](Def $state['lastHash'] '')
        $streak = Num $state['streak'] 0
        if ($hash -eq $lastHash) { $streak = $streak + 1 }
        else { $streak = [long]1; $state['lastHash'] = $hash }
        $state['streak'] = $streak

        # Time-budget sanity: startedAt missing/non-positive/future -> reset to
        # now and treat elapsed as 0.
        $started = Num $state['startedAt'] 0
        if ($started -le 0 -or $started -gt $NOW) {
          $started = $NOW
          $state['startedAt'] = $NOW
        }
        $elapsedMin = [long][math]::Floor(($NOW - $started) / 60)

        # Write #1: the bookkeeping update. If THIS fails, bash fails open, so
        # do we (the outer catch emits the canonical allow).
        Write-CgStateAtomic $statePath $state

        $count = Num $state['count'] 0
        $fails = Num $state['failStreak'] 0

        # 1. Loop detection (consecutive streak), catches runaways earliest
        if ($streak -gt $MAX_REPEATS) {
          $decided = $true; $decision = 'deny'
          $reasonTxt = "Loop detected: the same tool call has now been attempted $streak times in a row. Do NOT retry it again. Explain what is blocking you and either try a genuinely different approach or summarize and stop."
        }
        # 2. Failure streak, agent fighting the environment
        elseif ($fails -ge $MAX_FAILS) {
          $decided = $true; $decision = 'deny'
          $reasonTxt = "$fails consecutive tool failures. Stop retrying. Summarize the errors encountered and report the blocker instead of attempting further tool calls."
        }
        # 3. Hard ceilings, kill switch
        elseif ($count -ge $MAX_CALLS) {
          $decided = $true; $decision = 'deny'
          $reasonTxt = "Session tool budget exhausted ($count/$MAX_CALLS calls). Stop all further work immediately and produce a final summary of what was completed and what remains."
        }
        elseif ($elapsedMin -ge $MAX_MINUTES) {
          $decided = $true; $decision = 'deny'
          $reasonTxt = "Session time budget exhausted ($elapsedMin min / $MAX_MINUTES min). Stop all further work and produce a final summary."
        }
        # 4. Soft threshold, human checkpoint (interactive) or early stop (CI)
        elseif (($count -eq $SOFT_CALLS) -or (($count -gt $SOFT_CALLS) -and ((($count - $SOFT_CALLS) % 25) -eq 0))) {
          $decided = $true; $decision = $SOFT_ACTION
          $reasonTxt = "Cost checkpoint: $count tool calls used in this session (soft limit $SOFT_CALLS, hard limit $MAX_CALLS). Confirm to continue."
        }

        if ($decided) {
          # Write #2: record the decision. Best-effort, exactly like bash: a
          # failure here must NOT cancel an already-made deny/ask.
          if ($decision -eq 'ask') { $state['asks'] = (Num $state['asks'] 0) + 1 }
          else { $state['denials'] = (Num $state['denials'] 0) + 1 }
          try { Write-CgStateAtomic $statePath $state } catch { }
        }
      } catch {
        # Never brick a session on our account: fail OPEN.
        $decided = $false
        $decision = 'allow'
        $reasonTxt = ''
      } finally {
        Unlock-CgState $lk
      }

      if (-not $decided) { Write-CanonAllow }
      else {
        [Console]::Out.Write('{"decision":' + (ConvertTo-CgJsonStr $decision) + ',"reason":' + (ConvertTo-CgJsonStr $reasonTxt) + '}')
      }
      exit 0
    }

    # ---------------------------------------------------------------- post-tool
    'post-tool' {
      if (-not (Test-Path -LiteralPath $statePath)) { exit 0 }
      $lk = Lock-CgState $statePath
      try {
        $read = Read-CgStateFile $statePath
        $state = $read.State
        if ($read.Corrupt) {
          [Console]::Error.WriteLine('cost-guard: state was corrupt, reset')
          $state = New-CgState -Cwd '' -Src '' -Sid $SID -Platform $PLATFORM -Now $NOW
        }
        if ($null -ne $state) {
          $rt = [string](Def $payload.resultText '')
          $state['failStreak'] = 0
          $state['outputBytes'] = (Num $state['outputBytes'] 0) + $rt.Length
          Write-CgStateAtomic $statePath $state
        }
      } catch { } finally { Unlock-CgState $lk }
      exit 0
    }

    # -------------------------------------------------------------------- error
    'error' {
      if (-not (Test-Path -LiteralPath $statePath)) { exit 0 }
      $lk = Lock-CgState $statePath
      try {
        $read = Read-CgStateFile $statePath
        $state = $read.State
        if ($read.Corrupt) {
          [Console]::Error.WriteLine('cost-guard: state was corrupt, reset')
          $state = New-CgState -Cwd '' -Src '' -Sid $SID -Platform $PLATFORM -Now $NOW
        }
        if ($null -ne $state) {
          $state['failStreak'] = (Num $state['failStreak'] 0) + 1
          Write-CgStateAtomic $statePath $state
        }
      } catch { } finally { Unlock-CgState $lk }
      exit 0
    }

    # -------------------------------------------------------------- session-end
    'session-end' {
      $reason = [string](Def $payload.endReason 'unknown')
      try { New-Item -ItemType Directory -Force -Path $logDir | Out-Null } catch { }
      $record = $null
      $lk = Lock-CgState $statePath
      try {
        $read = Read-CgStateFile $statePath
        $state = $read.State
        if ($read.Corrupt) {
          [Console]::Error.WriteLine('cost-guard: state was corrupt, reset')
          $state = New-CgState -Cwd '' -Src '' -Sid $SID -Platform $PLATFORM -Now $NOW
        }
        if ($null -ne $state) {
          # Field set and order mirror guard.sh: state + end fields, minus
          # lastHash only (streak stays in the record).
          $startedAt = Num $state['startedAt'] $NOW
          $streakEnd = Num $state['streak'] 0
          $loops = if ($streakEnd -gt 1) { 1 } else { 0 }
          $record = [ordered]@{
            sessionId   = $state['sessionId']
            platform    = $state['platform']
            cwd         = $state['cwd']
            source      = $state['source']
            user        = $state['user']
            gitEmail    = $state['gitEmail']
            host        = $state['host']
            startedAt   = $state['startedAt']
            count       = $state['count']
            streak      = $state['streak']
            failStreak  = $state['failStreak']
            outputBytes = $state['outputBytes']
            denials     = $state['denials']
            asks        = $state['asks']
            endReason   = $reason
            endedAt     = $NOW
            durationSec = ($NOW - $startedAt)
            maxRepeats  = $streakEnd
            loops       = $loops
          }
        }
        try { Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue } catch { }
        try {
          Get-ChildItem -LiteralPath $stateDir -Filter ($SID + '.json.tmp.*') -File -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
        } catch { }
      } catch { $record = $null } finally { Unlock-CgState $lk }

      if ($null -eq $record) {
        $record = [ordered]@{ sessionId = $SID; platform = $PLATFORM; endReason = $reason; endedAt = $NOW; note = 'no state found' }
      }

      $line = $record | ConvertTo-Json -Depth 20 -Compress
      try { Add-Content -LiteralPath (Join-Path $logDir 'sessions.jsonl') -Value $line -Encoding utf8 } catch { }
      if ($reason -in @('error', 'timeout', 'abort')) {
        try { Add-Content -LiteralPath (Join-Path $logDir 'wasted-sessions.jsonl') -Value $line -Encoding utf8 } catch { }
      }
      if ($env:COST_GUARD_COLLECTOR_URL) {
        try { Invoke-RestMethod -Method Post -Uri $env:COST_GUARD_COLLECTOR_URL -ContentType 'application/json' -Body $line -TimeoutSec 10 | Out-Null } catch { }
      }
      exit 0
    }

    default { exit 0 }
  }
}
catch {
  # Never brick a session on our account: fail OPEN on the gating event.
  if ($EVENT -eq 'pre-tool') { Write-CanonAllow }
}
exit 0
