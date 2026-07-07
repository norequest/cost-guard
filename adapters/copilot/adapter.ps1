#!/usr/bin/env pwsh
# cost-guard :: GitHub Copilot CLI / cloud-agent adapter (PowerShell 7+)
#
# Usage (wired in cost-guard.json): adapter.ps1 <canonical-event>
#   session-start | pre-tool | post-tool | error | session-end
#
# Job: translate Copilot's hook payload -> canonical, call the neutral core, and
# (for pre-tool only) translate the core's decision back into Copilot's
# {permissionDecision, permissionDecisionReason} format.
#
# Copilot hook payload fields:
#   sessionId, cwd, source, toolName, toolArgs,
#   toolResult.textResultForLlm | toolResult, reason
#
# Fail OPEN: if the core is missing or ANY error occurs on pre-tool, emit an
# allow decision. Never brick a session on our account.
$ErrorActionPreference = 'Stop'

$eventName = if ($args.Count -ge 1) { [string]$args[0] } else { '' }

function Emit-Allow { [Console]::Out.Write('{"permissionDecision":"allow"}') }
function Def($v, $d) { if ($null -ne $v) { $v } else { $d } }
function ToStr($v) {
  if ($null -eq $v) { return '' }
  if ($v -is [string]) { return $v }
  if ($v -is [bool]) { if ($v) { return 'true' } else { return 'false' } }
  if ($v -is [ValueType]) { return [string]$v }
  return ($v | ConvertTo-Json -Depth 20 -Compress)
}

try {
  # Locate the neutral core across repo layout and self-contained install.
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

  $sid = [string](Def $payload.sessionId 'unknown')
  $canonObj = $null
  switch ($eventName) {
    'session-start' {
      $canonObj = [ordered]@{ event = 'session-start'; sessionId = $sid; cwd = [string](Def $payload.cwd ''); source = [string](Def $payload.source ''); platform = 'copilot' }
    }
    'pre-tool' {
      $canonObj = [ordered]@{ event = 'pre-tool'; sessionId = $sid; tool = [string](Def $payload.toolName ''); args = (Def $payload.toolArgs @{}); platform = 'copilot' }
    }
    'post-tool' {
      $tr = $payload.toolResult
      $rt = ''
      if ($tr -and ($null -ne $tr.textResultForLlm)) { $rt = ToStr $tr.textResultForLlm }
      elseif ($null -ne $tr) { $rt = ToStr $tr }
      $canonObj = [ordered]@{ event = 'post-tool'; sessionId = $sid; resultText = $rt; platform = 'copilot' }
    }
    'error' {
      $canonObj = [ordered]@{ event = 'error'; sessionId = $sid; platform = 'copilot' }
    }
    'session-end' {
      $canonObj = [ordered]@{ event = 'session-end'; sessionId = $sid; endReason = [string](Def $payload.reason 'unknown'); platform = 'copilot' }
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
    [Console]::Out.Write( (([ordered]@{ permissionDecision = $decision; permissionDecisionReason = $reasonTxt } | ConvertTo-Json -Compress)) + "`n" )
  }
}
catch {
  if ($eventName -eq 'pre-tool') { Emit-Allow }
}
exit 0
