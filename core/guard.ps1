#!/usr/bin/env pwsh
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
# Only `pre-tool` writes to stdout — the escalation-ladder decision:
#   {"decision":"allow|deny|ask","reason":"..."}
# Adapters translate that into each agent's native permission format.
#
# This is a behavioural port of core/guard.sh (the source of truth). It uses no
# jq; PowerShell's built-in ConvertFrom-Json/ConvertTo-Json do the JSON work.
# The state-file JSON schema matches guard.sh so the two engines are
# interchangeable. The loop fingerprint hash is SHA1 over a compact JSON of
# @{t=tool; a=args}; it is stable within PowerShell (identical {tool,args} ->
# identical hash) but is NOT required to byte-match the bash sha1.
#
# Fail policy (mirrors guard.sh): a bookkeeping error on `pre-tool` -> emit the
# canonical ALLOW ({"decision":"allow","reason":""}); passive events do nothing.
$ErrorActionPreference = 'Stop'

function Write-CanonAllow { [Console]::Out.Write('{"decision":"allow","reason":""}') }

# Faithful equivalent of jq's `x // default` for the null/absent case.
function Def($v, $d) { if ($null -ne $v) { $v } else { $d } }

# Build a fresh state object. Identity (user/gitEmail/host) is captured locally
# because hook payloads carry none. Key order matches guard.sh's jq -n object.
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
    startedAt   = [int]$Now
    count       = 0
    hashes      = @{}
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

  $stateDir = if ($env:COST_GUARD_STATE_DIR) { $env:COST_GUARD_STATE_DIR } else { Join-Path ([IO.Path]::GetTempPath()) 'cost-guard' }
  $logDir   = if ($env:COST_GUARD_LOG_DIR)   { $env:COST_GUARD_LOG_DIR }   else { Join-Path $HOME '.cost-guard' }
  try { New-Item -ItemType Directory -Force -Path $stateDir | Out-Null } catch { }
  $statePath = Join-Path $stateDir ("{0}.json" -f $SID)
  $NOW = [int][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

  # ---- Tunables (env-overridable) ----
  $MAX_CALLS   = if ($env:COST_GUARD_MAX_CALLS)       { [int]$env:COST_GUARD_MAX_CALLS }       else { 120 }
  $SOFT_CALLS  = if ($env:COST_GUARD_SOFT_CALLS)      { [int]$env:COST_GUARD_SOFT_CALLS }      else { 50 }
  $MAX_REPEATS = if ($env:COST_GUARD_MAX_REPEATS)     { [int]$env:COST_GUARD_MAX_REPEATS }     else { 3 }
  $MAX_MINUTES = if ($env:COST_GUARD_MAX_MINUTES)     { [int]$env:COST_GUARD_MAX_MINUTES }     else { 30 }
  $MAX_FAILS   = if ($env:COST_GUARD_MAX_FAIL_STREAK) { [int]$env:COST_GUARD_MAX_FAIL_STREAK } else { 5 }
  $SOFT_ACTION = if ($env:COST_GUARD_SOFT_ACTION)     { [string]$env:COST_GUARD_SOFT_ACTION }  else { 'ask' }

  switch ($EVENT) {

    # ------------------------------------------------------------ session-start
    'session-start' {
      $st = New-CgState -Cwd (Def $payload.cwd '') -Src (Def $payload.source '') -Sid $SID -Platform $PLATFORM -Now $NOW
      try { $st | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $statePath -Encoding utf8 } catch { }
      exit 0
    }

    # ----------------------------------------------------------------- pre-tool
    'pre-tool' {
      try {
        if (Test-Path -LiteralPath $statePath) {
          $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
        } else {
          $state = New-CgState -Cwd '' -Src '' -Sid $SID -Platform $PLATFORM -Now $NOW
        }
        # Fingerprint = tool name + args. Stable within PowerShell.
        $tool = [string](Def $payload.tool '')
        $toolArgs = Def $payload.args @{}
        $fp = [ordered]@{ t = $tool; a = $toolArgs } | ConvertTo-Json -Depth 20 -Compress
        $sha = [System.Security.Cryptography.SHA1]::Create()
        $hb  = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($fp))
        $hash = -join ($hb | ForEach-Object { $_.ToString('x2') })

        $state['count'] = [int](Def $state['count'] 0) + 1
        if (-not $state['hashes']) { $state['hashes'] = @{} }
        $state['hashes'][$hash] = [int](Def $state['hashes'][$hash] 0) + 1

        $state | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $statePath -Encoding utf8

        $count   = [int]$state['count']
        $repeats = [int]$state['hashes'][$hash]
        $fails   = [int](Def $state['failStreak'] 0)
        $started = [int](Def $state['startedAt'] $NOW)
        $elapsedMin = [int][math]::Floor( (($NOW - $started) / 60) )
      } catch {
        Write-CanonAllow
        exit 0
      }

      function Invoke-Decide([string]$decision, [string]$reason) {
        if ($decision -eq 'ask') { $state['asks'] = [int](Def $state['asks'] 0) + 1 }
        else { $state['denials'] = [int](Def $state['denials'] 0) + 1 }
        try { $state | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $statePath -Encoding utf8 } catch { }
        [Console]::Out.Write( ([ordered]@{ decision = $decision; reason = $reason } | ConvertTo-Json -Compress) )
        exit 0
      }

      # 1. Loop detection — catches runaways earliest
      if ($repeats -gt $MAX_REPEATS) {
        Invoke-Decide 'deny' ("Loop detected: this exact tool call was already made {0} times. Do NOT retry it again. Explain what is blocking you and either try a genuinely different approach or summarize and stop." -f ($repeats - 1))
      }
      # 2. Failure streak — agent fighting the environment
      if ($fails -ge $MAX_FAILS) {
        Invoke-Decide 'deny' ("{0} consecutive tool failures. Stop retrying. Summarize the errors encountered and report the blocker instead of attempting further tool calls." -f $fails)
      }
      # 3. Hard ceilings — kill switch
      if ($count -ge $MAX_CALLS) {
        Invoke-Decide 'deny' ("Session tool budget exhausted ({0}/{1} calls). Stop all further work immediately and produce a final summary of what was completed and what remains." -f $count, $MAX_CALLS)
      }
      if ($elapsedMin -ge $MAX_MINUTES) {
        Invoke-Decide 'deny' ("Session time budget exhausted ({0} min / {1} min). Stop all further work and produce a final summary." -f $elapsedMin, $MAX_MINUTES)
      }
      # 4. Soft threshold — human checkpoint (interactive) or early stop (CI)
      if (($count -eq $SOFT_CALLS) -or (($count -gt $SOFT_CALLS) -and ((($count - $SOFT_CALLS) % 25) -eq 0))) {
        Invoke-Decide $SOFT_ACTION ("Cost checkpoint: {0} tool calls used in this session (soft limit {1}, hard limit {2}). Confirm to continue." -f $count, $SOFT_CALLS, $MAX_CALLS)
      }
      # 5. Default
      Write-CanonAllow
      exit 0
    }

    # ---------------------------------------------------------------- post-tool
    'post-tool' {
      if (-not (Test-Path -LiteralPath $statePath)) { exit 0 }
      try {
        $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
        $rt = [string](Def $payload.resultText '')
        $state['failStreak'] = 0
        $state['outputBytes'] = [int](Def $state['outputBytes'] 0) + $rt.Length
        $state | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $statePath -Encoding utf8
      } catch { }
      exit 0
    }

    # -------------------------------------------------------------------- error
    'error' {
      if (-not (Test-Path -LiteralPath $statePath)) { exit 0 }
      try {
        $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
        $state['failStreak'] = [int](Def $state['failStreak'] 0) + 1
        $state | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $statePath -Encoding utf8
      } catch { }
      exit 0
    }

    # -------------------------------------------------------------- session-end
    'session-end' {
      $reason = [string](Def $payload.endReason 'unknown')
      try { New-Item -ItemType Directory -Force -Path $logDir | Out-Null } catch { }
      $record = $null
      if (Test-Path -LiteralPath $statePath) {
        try {
          $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
          $repeatCounts = @()
          if ($state['hashes']) { $repeatCounts = @($state['hashes'].Values | ForEach-Object { [int]$_ }) }
          $maxRepeats = 0
          if ($repeatCounts.Count -gt 0) { $maxRepeats = [int]($repeatCounts | Measure-Object -Maximum).Maximum }
          $loops = @($repeatCounts | Where-Object { $_ -gt 1 }).Count
          $startedAt = [int](Def $state['startedAt'] $NOW)
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
            failStreak  = $state['failStreak']
            outputBytes = $state['outputBytes']
            denials     = $state['denials']
            asks        = $state['asks']
            endReason   = $reason
            endedAt     = $NOW
            durationSec = $NOW - $startedAt
            loops       = $loops
            maxRepeats  = $maxRepeats
          }
        } catch { $record = $null }
      }
      if ($null -eq $record) {
        $record = [ordered]@{ sessionId = $SID; platform = $PLATFORM; endReason = $reason; endedAt = $NOW; note = 'no state found' }
      }

      $line = $record | ConvertTo-Json -Depth 20 -Compress
      try { Add-Content -LiteralPath (Join-Path $logDir 'sessions.jsonl') -Value $line -Encoding utf8 } catch { }
      if ($reason -in @('error','timeout','abort')) {
        try { Add-Content -LiteralPath (Join-Path $logDir 'wasted-sessions.jsonl') -Value $line -Encoding utf8 } catch { }
      }
      if ($env:COST_GUARD_COLLECTOR_URL) {
        try { Invoke-RestMethod -Method Post -Uri $env:COST_GUARD_COLLECTOR_URL -ContentType 'application/json' -Body $line -TimeoutSec 10 | Out-Null } catch { }
      }
      try { Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue } catch { }
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
