#!/usr/bin/env pwsh
#Requires -Version 7
# cost-guard :: PowerShell verification test harness
#
# Mirror of tests/run.sh for the PowerShell engine: drives every platform
# adapter.ps1 end-to-end through core/guard.ps1 and asserts the escalation
# ladder in each platform's native decision shape, plus the hardening paths
# (corrupt/empty state repair, tunable fallback, time budget, locking under
# 10-way parallel pre-tool fire).
#
# Each scenario runs in an isolated temp state+log dir via COST_GUARD_STATE_DIR
# so the suite is hermetic. Requires only PowerShell 7+ (Windows, macOS, Linux).
#
# Usage (from the repo root): pwsh -File plugins/cost-guard/tests/run.ps1
$ErrorActionPreference = 'Continue'

$ScriptDir = $PSScriptRoot
$Repo      = Split-Path -Parent $ScriptDir
$Payloads  = Join-Path $ScriptDir 'payloads'

$PwshExe = $null
try { $PwshExe = (Get-Process -Id $PID).Path } catch { $PwshExe = $null }
if (-not $PwshExe) { $PwshExe = 'pwsh' }

$script:Pass = 0
$script:Fail = 0
$script:LastAdapterExit = 0

function Ok([string]$Msg)  { $script:Pass++; Write-Host ('  [ok]   ' + $Msg) }
function Bad([string]$Msg) { $script:Fail++; Write-Host ('  [FAIL] ' + $Msg) }

function Check([string]$Desc, $Expected, $Actual) {
  if ("$Expected" -eq "$Actual") { Ok $Desc }
  else { Bad ($Desc + '  (expected [' + "$Expected" + '] got [' + "$Actual" + '])') }
}
function AssertContains([string]$Desc, [string]$Needle, [string]$Haystack) {
  if ($null -ne $Haystack -and $Haystack.Contains($Needle)) { Ok $Desc }
  else { Bad ($Desc + '  (missing [' + $Needle + '] in [' + "$Haystack" + '])') }
}

function New-TempDir([string]$Tag) {
  $d = Join-Path ([System.IO.Path]::GetTempPath()) ('cg-ps-' + $Tag + '-' + [System.IO.Path]::GetRandomFileName())
  New-Item -ItemType Directory -Force -Path $d | Out-Null
  return $d
}

# Set the FULL cost-guard env surface for the child processes: every listed
# name is either set from $Vars or removed, so scenarios never leak into each
# other and the suite is immune to the caller's environment.
$CgEnvNames = @(
  'COST_GUARD_STATE_DIR', 'COST_GUARD_LOG_DIR', 'COST_GUARD_MAX_CALLS',
  'COST_GUARD_SOFT_CALLS', 'COST_GUARD_MAX_REPEATS', 'COST_GUARD_MAX_FAIL_STREAK',
  'COST_GUARD_MAX_MINUTES', 'COST_GUARD_SOFT_ACTION', 'COST_GUARD_COLLECTOR_URL',
  'COST_GUARD_CORE'
)
function Set-CgEnv([hashtable]$Vars) {
  foreach ($n in $CgEnvNames) {
    $v = $null
    if ($Vars.ContainsKey($n)) { $v = [string]$Vars[$n] }
    [Environment]::SetEnvironmentVariable($n, $v)
  }
}

# ------------------------------------------------------------------ invocation
function Invoke-Adapter([string]$Platform, [string]$Event, [string]$Json) {
  $adapter = Join-Path $Repo 'adapters' $Platform 'adapter.ps1'
  $out = $Json | & $PwshExe -NoProfile -File $adapter $Event 2>$null
  $script:LastAdapterExit = $LASTEXITCODE
  return ((@($out) | Where-Object { $null -ne $_ }) -join "`n")
}

# ------------------------------------------------------- raw payload builders
# Each platform's REAL field names live here and nowhere else (same as run.sh).
function Build-Start([string]$P, [string]$Sid) {
  switch ($P) {
    'copilot' { return ('{"sessionId":"' + $Sid + '","cwd":"/repo","source":"cli"}') }
    'cursor'  { return ('{"conversation_id":"' + $Sid + '","workspace_roots":["/repo"],"composer_mode":"agent"}') }
    default   { return ('{"session_id":"' + $Sid + '","cwd":"/repo","source":"startup"}') }
  }
}
function Build-Pre([string]$P, [string]$Sid, [string]$Tool, [string]$ArgsJson) {
  switch ($P) {
    'copilot' { return ('{"sessionId":"' + $Sid + '","toolName":"' + $Tool + '","toolArgs":' + $ArgsJson + '}') }
    'cursor'  { return ('{"conversation_id":"' + $Sid + '","tool_name":"' + $Tool + '","tool_input":' + $ArgsJson + '}') }
    default   { return ('{"session_id":"' + $Sid + '","tool_name":"' + $Tool + '","tool_input":' + $ArgsJson + '}') }
  }
}
# Push ONE failure into the streak. copilot/cursor have a native error event;
# claude-code/codex/gemini infer failure from a post-tool with an error payload.
function Push-CgError([string]$P, [string]$Sid) {
  switch ($P) {
    'copilot' { $null = Invoke-Adapter 'copilot' 'error' ('{"sessionId":"' + $Sid + '"}') }
    'cursor'  { $null = Invoke-Adapter 'cursor' 'error' ('{"conversation_id":"' + $Sid + '"}') }
    default   { $null = Invoke-Adapter $P 'post-tool' ('{"session_id":"' + $Sid + '","tool_name":"Bash","tool_response":{"is_error":true,"error":"boom"}}') }
  }
}

# ----------------------------------------------------- decision interpretation
# Get-Decision <platform> <adapter-stdout> -> allow|deny|ask|silent|none
function Get-Decision([string]$P, [string]$Out) {
  try {
    if ($P -eq 'gemini') {
      if ([string]::IsNullOrWhiteSpace($Out)) { return 'silent' }
      $j = $Out | ConvertFrom-Json
      return [string]$(if ($j.decision) { $j.decision } else { 'none' })
    }
    $j = $Out | ConvertFrom-Json
    if ($P -eq 'cursor')  { return [string]$(if ($j.permission) { $j.permission } else { 'none' }) }
    if ($P -eq 'copilot') { return [string]$(if ($j.permissionDecision) { $j.permissionDecision } else { 'none' }) }
    if ($j.hookSpecificOutput -and $j.hookSpecificOutput.permissionDecision) {
      return [string]$j.hookSpecificOutput.permissionDecision
    }
    return 'none'
  } catch { return 'none' }
}
function Get-Reason([string]$P, [string]$Out) {
  try {
    $j = $Out | ConvertFrom-Json
    if ($P -eq 'gemini')  { return [string]$j.reason }
    if ($P -eq 'cursor')  { return [string]$(if ($j.agent_message) { $j.agent_message } else { $j.user_message }) }
    if ($P -eq 'copilot') { return [string]$j.permissionDecisionReason }
    return [string]$j.hookSpecificOutput.permissionDecisionReason
  } catch { return '' }
}
function Get-AllowLabel([string]$P) { if ($P -eq 'gemini') { return 'silent' }; return 'allow' }

# =========================================================== per-platform suite
$Platforms = @('claude-code', 'copilot', 'cursor', 'codex', 'gemini')

foreach ($P in $Platforms) {
  Write-Host ''
  Write-Host ('=== ' + $P + ' ===')
  $StateDir = New-TempDir ($P + '-state')
  $LogDir   = New-TempDir ($P + '-log')
  $allowLbl = Get-AllowLabel $P

  # (a) first pre-tool from the REAL sample payload file -> ALLOW, exit 0
  Set-CgEnv @{ COST_GUARD_STATE_DIR = $StateDir; COST_GUARD_LOG_DIR = $LogDir; COST_GUARD_MAX_MINUTES = '999' }
  $sample = Get-Content -LiteralPath (Join-Path $Payloads ($P + '-pre-tool.json')) -Raw
  $a = Invoke-Adapter $P 'pre-tool' $sample
  Check "(a) [$P] first pre-tool (sample payload) -> $allowLbl" $allowLbl (Get-Decision $P $a)
  Check "(a) [$P] adapter exits 0" '0' ([string]$script:LastAdapterExit)
  if ($P -eq 'gemini') { Check "(a) [$P] allow emits EMPTY stdout" '' $a }

  # (b) consecutive loop: with default MAX_REPEATS=3 the 4th identical call denies
  $loopPre = Build-Pre $P 'cg-loop' 'Bash' '{"command":"grep -r TODO ."}'
  $b1 = Invoke-Adapter $P 'pre-tool' $loopPre
  $null = Invoke-Adapter $P 'pre-tool' $loopPre
  $b3 = Invoke-Adapter $P 'pre-tool' $loopPre
  $b4 = Invoke-Adapter $P 'pre-tool' $loopPre
  Check "(b) [$P] loop call#1 $allowLbl" $allowLbl (Get-Decision $P $b1)
  Check "(b) [$P] loop call#3 still $allowLbl" $allowLbl (Get-Decision $P $b3)
  Check "(b) [$P] loop call#4 DENY" 'deny' (Get-Decision $P $b4)
  AssertContains "(b) [$P] loop reason names the loop" 'Loop detected' (Get-Reason $P $b4)
  AssertContains "(b) [$P] loop reason counts the streak" '4 times in a row' (Get-Reason $P $b4)

  # (c) distinct calls crossing SOFT_CALLS -> soft checkpoint (ask; gemini silent)
  Set-CgEnv @{ COST_GUARD_STATE_DIR = $StateDir; COST_GUARD_LOG_DIR = $LogDir; COST_GUARD_MAX_MINUTES = '999'; COST_GUARD_SOFT_CALLS = '4'; COST_GUARD_SOFT_ACTION = 'ask' }
  for ($n = 1; $n -le 3; $n++) {
    $null = Invoke-Adapter $P 'pre-tool' (Build-Pre $P 'cg-soft' 'Bash' ('{"command":"echo ' + $n + '"}'))
  }
  $c4 = Invoke-Adapter $P 'pre-tool' (Build-Pre $P 'cg-soft' 'Bash' '{"command":"echo four"}')
  if ($P -eq 'gemini') {
    Check "(c) [$P] soft checkpoint -> silent (ask degrades to allow)" 'silent' (Get-Decision $P $c4)
    Check "(c) [$P] soft checkpoint EMPTY stdout" '' $c4
  } else {
    Check "(c) [$P] soft checkpoint -> ask" 'ask' (Get-Decision $P $c4)
    AssertContains "(c) [$P] checkpoint reason" 'Cost checkpoint' (Get-Reason $P $c4)
  }

  # (d) distinct calls crossing MAX_CALLS -> hard ceiling DENY
  Set-CgEnv @{ COST_GUARD_STATE_DIR = $StateDir; COST_GUARD_LOG_DIR = $LogDir; COST_GUARD_MAX_MINUTES = '999'; COST_GUARD_MAX_CALLS = '3' }
  $null = Invoke-Adapter $P 'pre-tool' (Build-Pre $P 'cg-ceil' 'Bash' '{"command":"step 1"}')
  $null = Invoke-Adapter $P 'pre-tool' (Build-Pre $P 'cg-ceil' 'Bash' '{"command":"step 2"}')
  $d3 = Invoke-Adapter $P 'pre-tool' (Build-Pre $P 'cg-ceil' 'Bash' '{"command":"step 3"}')
  Check "(d) [$P] ceiling DENY at MAX_CALLS" 'deny' (Get-Decision $P $d3)
  AssertContains "(d) [$P] ceiling reason names budget" 'budget exhausted' (Get-Reason $P $d3)

  # (e) MAX_FAIL_STREAK errors then a pre-tool -> failure-streak DENY
  Set-CgEnv @{ COST_GUARD_STATE_DIR = $StateDir; COST_GUARD_LOG_DIR = $LogDir; COST_GUARD_MAX_MINUTES = '999'; COST_GUARD_MAX_FAIL_STREAK = '3' }
  $null = Invoke-Adapter $P 'session-start' (Build-Start $P 'cg-streak')
  Push-CgError $P 'cg-streak'
  Push-CgError $P 'cg-streak'
  Push-CgError $P 'cg-streak'
  $e = Invoke-Adapter $P 'pre-tool' (Build-Pre $P 'cg-streak' 'Read' '{"path":"x.txt"}')
  Check "(e) [$P] failure-streak DENY" 'deny' (Get-Decision $P $e)
  AssertContains "(e) [$P] failure reason" 'consecutive tool failures' (Get-Reason $P $e)
}

# ==================================================== core-hardening scenarios
# These exercise engine internals once, through the claude-code adapter.
Write-Host ''
Write-Host '=== core hardening (via claude-code adapter) ==='
$CP = 'claude-code'
$StateDir = New-TempDir 'core-state'
$LogDir   = New-TempDir 'core-log'
Set-CgEnv @{ COST_GUARD_STATE_DIR = $StateDir; COST_GUARD_LOG_DIR = $LogDir; COST_GUARD_MAX_MINUTES = '999' }

# (f) A,A,B,A,A never denies under default MAX_REPEATS=3 (streak resets on B)
$pa = Build-Pre $CP 'cg-aabaa' 'Bash' '{"command":"alpha"}'
$pb = Build-Pre $CP 'cg-aabaa' 'Bash' '{"command":"beta"}'
$seq = @()
foreach ($pl in @($pa, $pa, $pb, $pa, $pa)) {
  $seq += (Get-Decision $CP (Invoke-Adapter $CP 'pre-tool' $pl))
}
Check '(f) A,A,B,A,A never denies (streak is consecutive-only)' 'allow,allow,allow,allow,allow' ($seq -join ',')

# (g) corrupt state file -> reset and allow, then bookkeeping continues
$sidC = 'cg-corrupt'
$null = Invoke-Adapter $CP 'session-start' (Build-Start $CP $sidC)
$stFileC = Join-Path $StateDir ($sidC + '.json')
Set-Content -LiteralPath $stFileC -Value '{ this is >>> not json <<<' -NoNewline
$g = Invoke-Adapter $CP 'pre-tool' (Build-Pre $CP $sidC 'Bash' '{"command":"after corrupt"}')
Check '(g) corrupt state resets and ALLOWS' 'allow' (Get-Decision $CP $g)
$gCount = 'unreadable'
try { $gCount = [string]((Get-Content -LiteralPath $stFileC -Raw | ConvertFrom-Json).count) } catch { $gCount = 'unreadable' }
Check '(g) corrupt state re-bootstrapped (count=1)' '1' $gCount

# (h) empty state file -> reset and allow
$sidE = 'cg-empty'
$stFileE = Join-Path $StateDir ($sidE + '.json')
Set-Content -LiteralPath $stFileE -Value '' -NoNewline
$h = Invoke-Adapter $CP 'pre-tool' (Build-Pre $CP $sidE 'Bash' '{"command":"after empty"}')
Check '(h) empty state resets and ALLOWS' 'allow' (Get-Decision $CP $h)
$hCount = 'unreadable'
try { $hCount = [string]((Get-Content -LiteralPath $stFileE -Raw | ConvertFrom-Json).count) } catch { $hCount = 'unreadable' }
Check '(h) empty state re-bootstrapped (count=1)' '1' $hCount

# (i) bad numeric env falls back to the default instead of crashing the engine.
#     MAX_CALLS=banana must be ignored (default 120), while the VALID
#     MAX_REPEATS=1 must still be enforced. A crash would fail open on both.
Set-CgEnv @{ COST_GUARD_STATE_DIR = $StateDir; COST_GUARD_LOG_DIR = $LogDir; COST_GUARD_MAX_MINUTES = '999'; COST_GUARD_MAX_CALLS = 'banana'; COST_GUARD_MAX_REPEATS = '1' }
$i1 = Invoke-Adapter $CP 'pre-tool' (Build-Pre $CP 'cg-badenv' 'Bash' '{"command":"same"}')
$i2 = Invoke-Adapter $CP 'pre-tool' (Build-Pre $CP 'cg-badenv' 'Bash' '{"command":"same"}')
Check '(i) bad MAX_CALLS ignored, call#1 ALLOWS (fallback default)' 'allow' (Get-Decision $CP $i1)
Check '(i) valid MAX_REPEATS=1 still enforced, call#2 DENIES' 'deny' (Get-Decision $CP $i2)

# (j) MAX_MINUTES deny with an old startedAt
Set-CgEnv @{ COST_GUARD_STATE_DIR = $StateDir; COST_GUARD_LOG_DIR = $LogDir; COST_GUARD_MAX_MINUTES = '30' }
$sidT = 'cg-time'
$null = Invoke-Adapter $CP 'session-start' (Build-Start $CP $sidT)
$stFileT = Join-Path $StateDir ($sidT + '.json')
$stT = Get-Content -LiteralPath $stFileT -Raw | ConvertFrom-Json -AsHashtable
$stT['startedAt'] = [long]$stT['startedAt'] - 3600
($stT | ConvertTo-Json -Depth 20) | Set-Content -LiteralPath $stFileT -NoNewline
$j = Invoke-Adapter $CP 'pre-tool' (Build-Pre $CP $sidT 'Bash' '{"command":"tick"}')
Check '(j) time budget DENY with old startedAt' 'deny' (Get-Decision $CP $j)
AssertContains '(j) time budget reason' 'time budget exhausted' (Get-Reason $CP $j)

# (j2) startedAt in the FUTURE is sanitized to now and treated as elapsed 0
$sidF = 'cg-future'
$null = Invoke-Adapter $CP 'session-start' (Build-Start $CP $sidF)
$stFileF = Join-Path $StateDir ($sidF + '.json')
$stF = Get-Content -LiteralPath $stFileF -Raw | ConvertFrom-Json -AsHashtable
$stF['startedAt'] = [long]$stF['startedAt'] + 86400
($stF | ConvertTo-Json -Depth 20) | Set-Content -LiteralPath $stFileF -NoNewline
$f2 = Invoke-Adapter $CP 'pre-tool' (Build-Pre $CP $sidF 'Bash' '{"command":"tock"}')
Check '(j2) future startedAt -> elapsed 0 -> ALLOW' 'allow' (Get-Decision $CP $f2)
$saNow = [long]0
try { $saNow = [long](Get-Content -LiteralPath $stFileF -Raw | ConvertFrom-Json).startedAt } catch { $saNow = [long]0 }
$nowRef = [long][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
Check '(j2) future startedAt was reset to now' 'True' ([string](($saNow -gt 0) -and ($saNow -le ($nowRef + 5))))

# (k) 10 parallel pre-tool calls record count EXACTLY 10 (mutex + atomic write)
Set-CgEnv @{ COST_GUARD_STATE_DIR = $StateDir; COST_GUARD_LOG_DIR = $LogDir; COST_GUARD_MAX_MINUTES = '999' }
$sidP = 'cg-parallel'
$null = Invoke-Adapter $CP 'session-start' (Build-Start $CP $sidP)
$adapterPath = Join-Path $Repo 'adapters' $CP 'adapter.ps1'
$jobSb = {
  param($Exe, $Adapter, $Json)
  $Json | & $Exe -NoProfile -File $Adapter 'pre-tool' 2>$null | Out-Null
}
$useThreadJob = $null -ne (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue)
$jobs = @()
for ($n = 1; $n -le 10; $n++) {
  $pl = Build-Pre $CP $sidP 'Bash' ('{"command":"par ' + $n + '"}')
  if ($useThreadJob) {
    $jobs += Start-ThreadJob -ScriptBlock $jobSb -ArgumentList $PwshExe, $adapterPath, $pl -ThrottleLimit 10
  } else {
    $jobs += Start-Job -ScriptBlock $jobSb -ArgumentList $PwshExe, $adapterPath, $pl
  }
}
$null = Wait-Job -Job $jobs -Timeout 180
Receive-Job -Job $jobs -ErrorAction SilentlyContinue | Out-Null
Remove-Job -Job $jobs -Force -ErrorAction SilentlyContinue
$pCount = 'unreadable'
try { $pCount = [string]((Get-Content -LiteralPath (Join-Path $StateDir ($sidP + '.json')) -Raw | ConvertFrom-Json).count) } catch { $pCount = 'unreadable' }
Check '(k) 10 parallel pre-tool calls record count exactly 10' '10' $pCount

# Clean the cost-guard env surface behind us.
Set-CgEnv @{}

Write-Host ''
Write-Host '---------------------------------------------'
Write-Host ("{0} passed, {1} failed" -f $script:Pass, $script:Fail)
if ($script:Fail -gt 0) { exit 1 }
exit 0
