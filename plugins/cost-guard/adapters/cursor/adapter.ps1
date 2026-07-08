#!/usr/bin/env pwsh
#Requires -Version 7
# cost-guard :: Cursor adapter (PowerShell 7+)
#
# Usage (wired in .cursor/hooks.json): adapter.ps1 <canonical-event>
#   session-start | pre-tool | post-tool | error | session-end
#
# Cursor hook payload fields:
#   conversation_id (stable session id), tool_name, tool_input (preToolUse),
#   tool_output (postToolUse), reason (sessionEnd), source/composer_mode,
#   workspace_roots[0] (fallback cwd).
#
# Decision output uses Cursor's `permission` (allow|deny|ask). `agent_message`
# is fed to the model; `user_message` is shown to the human. We emit BOTH
# snake_case and camelCase message keys because Cursor renamed them once already.
# Only pre-tool writes to stdout; a minimal {permission:"allow"} on allow.
$ErrorActionPreference = 'Stop'

$eventName = if ($args.Count -ge 1) { [string]$args[0] } else { '' }

function Emit-Allow { [Console]::Out.Write('{"permission":"allow"}') }
function Def($v, $d) { if ($null -ne $v) { $v } else { $d } }
function ToStr($v) {
  if ($null -eq $v) { return '' }
  if ($v -is [string]) { return $v }
  if ($v -is [bool]) { if ($v) { return 'true' } else { return 'false' } }
  if ($v -is [ValueType]) { return [string]$v }
  return ($v | ConvertTo-Json -Depth 20 -Compress)
}

try {
  $core = $null
  foreach ($c in @($env:COST_GUARD_CORE, (Join-Path $PSScriptRoot 'core' 'guard.ps1'), (Join-Path $PSScriptRoot '..' '..' 'core' 'guard.ps1'))) {
    if ($c -and (Test-Path -LiteralPath $c)) { $core = $c; break }
  }
  if (-not $core) {
    if ($eventName -eq 'pre-tool') { Emit-Allow }
    exit 0
  }

  $raw = [Console]::In.ReadToEnd()
  $payload = $null
  if ($raw -and $raw.Trim().Length -gt 0) { $payload = $raw | ConvertFrom-Json }
  if ($null -eq $payload) { $payload = [pscustomobject]@{} }

  $sid = [string](Def $payload.conversation_id (Def $payload.session_id 'unknown'))
  $canonObj = $null
  switch ($eventName) {
    'session-start' {
      $wr0 = $null
      if ($null -ne $payload.workspace_roots) { $wr0 = @($payload.workspace_roots)[0] }
      $cwd = [string](Def $payload.cwd (Def $wr0 ''))
      $src = [string](Def $payload.source (Def $payload.composer_mode ''))
      $canonObj = [ordered]@{ event = 'session-start'; sessionId = $sid; cwd = $cwd; source = $src; platform = 'cursor' }
    }
    'pre-tool' {
      $canonObj = [ordered]@{ event = 'pre-tool'; sessionId = $sid; tool = [string](Def $payload.tool_name ''); args = (Def $payload.tool_input @{}); platform = 'cursor' }
    }
    'post-tool' {
      $val = Def $payload.tool_output $payload.output
      $canonObj = [ordered]@{ event = 'post-tool'; sessionId = $sid; resultText = (ToStr $val); platform = 'cursor' }
    }
    'error' {
      $canonObj = [ordered]@{ event = 'error'; sessionId = $sid; platform = 'cursor' }
    }
    'session-end' {
      $canonObj = [ordered]@{ event = 'session-end'; sessionId = $sid; endReason = [string](Def $payload.reason 'unknown'); platform = 'cursor' }
    }
    default { exit 0 }
  }

  $canon = $canonObj | ConvertTo-Json -Depth 20 -Compress
  # Invoke the core as a child pwsh so its `exit` never terminates this adapter.
  # Prefer the pwsh on PATH (how this adapter itself was launched); fall back to
  # the current process image, then $PSHOME, then a bare 'pwsh'.
  $pwshExe = $null
  try { $gc = Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1; if ($gc) { $pwshExe = $gc.Source } } catch { $pwshExe = $null }
  if (-not $pwshExe) {
    try { $pp = (Get-Process -Id $PID).Path; if ($pp -and ($pp -match 'pwsh')) { $pwshExe = $pp } } catch { $pwshExe = $null }
  }
  if (-not $pwshExe) {
    $exe = if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' }
    $cand = Join-Path $PSHOME $exe
    $pwshExe = if (Test-Path -LiteralPath $cand) { $cand } else { 'pwsh' }
  }
  $out = $canon | & $pwshExe -NoProfile -File $core

  if ($eventName -eq 'pre-tool') {
    $decision = 'allow'; $reasonTxt = ''
    try {
      $j = if ($out) { (@($out) -join "`n") | ConvertFrom-Json } else { $null }
      if ($j) {
        if ($j.decision) { $decision = [string]$j.decision }
        if ($null -ne $j.reason) { $reasonTxt = [string]$j.reason }
      }
    } catch { $decision = 'allow'; $reasonTxt = '' }
    if ($decision -eq 'allow') {
      Emit-Allow
    } else {
      $obj = [ordered]@{ permission = $decision; 'continue' = $true; user_message = $reasonTxt; agent_message = $reasonTxt; userMessage = $reasonTxt; agentMessage = $reasonTxt }
      [Console]::Out.Write( ($obj | ConvertTo-Json -Compress) + "`n" )
    }
  }
}
catch {
  if ($eventName -eq 'pre-tool') { Emit-Allow }
}
exit 0
