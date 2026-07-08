#!/usr/bin/env pwsh
#Requires -Version 7
# cost-guard :: OpenAI Codex CLI adapter (PowerShell 7+)
#
# Usage (wired in .codex/hooks.json): adapter.ps1 <canonical-event>
#   session-start | pre-tool | post-tool | session-end
#
# Codex's hook contract is Claude-Code-compatible: PreToolUse/PostToolUse/
# SessionStart/Stop, payload fields session_id/tool_name/tool_input/tool_response,
# and the same hookSpecificOutput.permissionDecision {allow,deny,ask} output.
# Codex has no SessionEnd — it finalizes on Stop (wire Stop -> session-end).
#
# Only pre-tool writes to stdout. Fail OPEN on the gate.
$ErrorActionPreference = 'Stop'

$eventName = if ($args.Count -ge 1) { [string]$args[0] } else { '' }

function Emit-Allow { [Console]::Out.Write('{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}') }
function Def($v, $d) { if ($null -ne $v) { $v } else { $d } }
function ToStr($v) {
  if ($null -eq $v) { return '' }
  if ($v -is [string]) { return $v }
  if ($v -is [bool]) { if ($v) { return 'true' } else { return 'false' } }
  if ($v -is [ValueType]) { return [string]$v }
  return ($v | ConvertTo-Json -Depth 20 -Compress)
}
function Is-Obj($v) {
  if ($null -eq $v) { return $false }
  if ($v -is [string] -or $v -is [bool] -or $v -is [ValueType]) { return $false }
  if ($v -is [System.Collections.IDictionary]) { return $true }
  if ($v -is [System.Array] -or $v -is [System.Collections.IList]) { return $false }
  if ($v -is [System.Management.Automation.PSCustomObject]) { return $true }
  return ($null -ne $v.PSObject -and @($v.PSObject.Properties).Count -gt 0)
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

  $sid = [string](Def $payload.session_id 'unknown')
  $canonObj = $null
  switch ($eventName) {
    'session-start' {
      $canonObj = [ordered]@{ event = 'session-start'; sessionId = $sid; cwd = [string](Def $payload.cwd ''); source = [string](Def $payload.source ''); platform = 'codex' }
    }
    'pre-tool' {
      $canonObj = [ordered]@{ event = 'pre-tool'; sessionId = $sid; tool = [string](Def $payload.tool_name ''); args = (Def $payload.tool_input @{}); platform = 'codex' }
    }
    'post-tool' {
      $r = $payload.tool_response
      $isErr = $false
      if (Is-Obj $r) {
        if (($r.is_error -eq $true) -or ($null -ne $r.error)) { $isErr = $true }
      }
      if ($isErr) {
        $canonObj = [ordered]@{ event = 'error'; sessionId = $sid; platform = 'codex' }
      } else {
        $val = if ($null -ne $r) { $r } else { $payload.tool_output }
        $canonObj = [ordered]@{ event = 'post-tool'; sessionId = $sid; resultText = (ToStr $val); platform = 'codex' }
      }
    }
    'session-end' {
      $canonObj = [ordered]@{ event = 'session-end'; sessionId = $sid; endReason = [string](Def $payload.reason 'stop'); platform = 'codex' }
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
    $obj = [ordered]@{ hookSpecificOutput = [ordered]@{ hookEventName = 'PreToolUse'; permissionDecision = $decision; permissionDecisionReason = $reasonTxt } }
    [Console]::Out.Write( ($obj | ConvertTo-Json -Depth 5 -Compress) + "`n" )
  }
}
catch {
  if ($eventName -eq 'pre-tool') { Emit-Allow }
}
exit 0
