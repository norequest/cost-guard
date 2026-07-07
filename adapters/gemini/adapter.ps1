#!/usr/bin/env pwsh
# cost-guard :: Google Gemini CLI adapter (PowerShell 7+)
#
# Usage (wired in settings.json hooks block): adapter.ps1 <canonical-event>
#   session-start | pre-tool | post-tool | session-end
#
# Gemini hook contract: events BeforeTool/AfterTool/SessionStart/SessionEnd;
# snake_case tool_name/tool_input/tool_response; the decision is TOP-LEVEL
# {"decision":"deny","reason":"...","continue":false}. There is no "ask" — a
# soft checkpoint degrades to allow. Gemini requires stdout to be PURE JSON, so
# we print NOTHING on allow/ask and only the deny object on deny.
#
# jq/core missing: fail OPEN by staying silent (no decision == proceed).
$ErrorActionPreference = 'Stop'

$eventName = if ($args.Count -ge 1) { [string]$args[0] } else { '' }

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
  # Core missing: stay silent (fail open) regardless of event.
  if (-not $core) { exit 0 }

  $raw = [Console]::In.ReadToEnd()
  $payload = $null
  if ($raw -and $raw.Trim().Length -gt 0) { $payload = $raw | ConvertFrom-Json }
  if ($null -eq $payload) { $payload = [pscustomobject]@{} }

  $sid = [string](Def $payload.session_id (Def $env:GEMINI_SESSION_ID 'unknown'))
  $canonObj = $null
  switch ($eventName) {
    'session-start' {
      $canonObj = [ordered]@{ event = 'session-start'; sessionId = $sid; cwd = [string](Def $payload.cwd ''); source = [string](Def $payload.source ''); platform = 'gemini' }
    }
    'pre-tool' {
      $canonObj = [ordered]@{ event = 'pre-tool'; sessionId = $sid; tool = [string](Def $payload.tool_name ''); args = (Def $payload.tool_input @{}); platform = 'gemini' }
    }
    'post-tool' {
      $r = $payload.tool_response
      $isErr = $false
      if (Is-Obj $r) {
        if (($r.is_error -eq $true) -or ($null -ne $r.error)) { $isErr = $true }
      }
      if ($isErr) {
        $canonObj = [ordered]@{ event = 'error'; sessionId = $sid; platform = 'gemini' }
      } else {
        $canonObj = [ordered]@{ event = 'post-tool'; sessionId = $sid; resultText = (ToStr $r); platform = 'gemini' }
      }
    }
    'session-end' {
      $canonObj = [ordered]@{ event = 'session-end'; sessionId = $sid; endReason = [string](Def $payload.reason 'unknown'); platform = 'gemini' }
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
    # Gemini only understands deny/block. allow and ask both proceed -> emit nothing.
    $decision = 'allow'; $reasonTxt = ''
    try {
      $j = if ($out) { (@($out) -join "`n") | ConvertFrom-Json } else { $null }
      if ($j) {
        if ($j.decision) { $decision = [string]$j.decision }
        if ($null -ne $j.reason) { $reasonTxt = [string]$j.reason }
      }
    } catch { $decision = 'allow'; $reasonTxt = '' }
    if ($decision -eq 'deny') {
      [Console]::Out.Write( ([ordered]@{ decision = 'deny'; reason = $reasonTxt; 'continue' = $false } | ConvertTo-Json -Compress) )
    }
  }
}
catch {
  # Fail open: emit nothing.
}
exit 0
