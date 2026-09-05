[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# LM Studio Runtime Baseline (2.15 Phase 7, Section 9). Read-only acceptance/validation check
# for "Max Concurrent Predictions" (LM Studio config key llm.load.numParallelSessions), the real,
# root-caused fix for the sporadic 10-35s+ chat latency documented in
# C:\KI-Stack\logs\latency-diagnostics\REPORT.md (numParallelSessions=1 serializes every request
# behind whichever one is already running). This script NEVER sets the value -- `lms load
# --parallel` is a real, user-facing runtime change with its own tradeoffs (VRAM/throughput),
# never something a Complete-Installer acceptance check should silently apply. Read-only, exit
# code always 0 (a low parallel value is a WARN, not a hard failure -- the stack still functions,
# just serialized) unless `lms` itself cannot be invoked at all.
#
# Classification (validated empirically during the original latency diagnosis, current 27B model):
#   3        -> PASS      (validated recommended baseline)
#   2        -> WARN      (functional, some serialization risk under real concurrent load)
#   1        -> WARN      (known, reproduced queue-latency regression -- see REPORT.md)
#   unreadable -> WARN    (`lms` missing/errored -- NOT VERIFIED, not a failure)

function Get-KILMStudioParallelSetting {
    try {
        $raw = & lms ps --json 2>$null
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($raw -join ''))) {
            return [pscustomobject]@{ readable = $false; reason = "lms ps --json Exitcode $LASTEXITCODE oder leere Ausgabe."; models = @() }
        }
        $parsed = ($raw -join [Environment]::NewLine) | ConvertFrom-Json -Depth 20
        $models = @($parsed | Where-Object { $_.type -eq 'llm' })
        [pscustomobject]@{ readable = $true; reason = $null; models = $models }
    } catch {
        [pscustomobject]@{ readable = $false; reason = $_.Exception.Message; models = @() }
    }
}

$probe = Get-KILMStudioParallelSetting
if (-not $probe.readable) {
    $result = [pscustomobject]@{
        passed = $true
        classification = 'WARN_NOT_VERIFIED'
        detail = "lms ps --json nicht auswertbar: $($probe.reason)"
        loadedModels = @()
        mutatesTarget = $false
    }
    $result | ConvertTo-Json -Depth 10
    exit 0
}

if (@($probe.models).Count -eq 0) {
    $result = [pscustomobject]@{
        passed = $true
        classification = 'WARN_NOT_VERIFIED'
        detail = 'Kein geladenes LLM in LM Studio gefunden -- Parallel-Einstellung derzeit nicht ablesbar (kein Fehler, kein Modell aktuell geladen).'
        loadedModels = @()
        mutatesTarget = $false
    }
    $result | ConvertTo-Json -Depth 10
    exit 0
}

$perModel = foreach ($model in $probe.models) {
    $parallel = if ($model.PSObject.Properties['parallel']) { [int]$model.parallel } else { $null }
    $classification = switch ($parallel) {
        3 { 'PASS' }
        2 { 'WARN_FUNCTIONAL' }
        1 { 'WARN_KNOWN_QUEUE_LATENCY' }
        default { 'WARN_NOT_VERIFIED' }
    }
    [pscustomobject]@{
        identifier = [string]$model.identifier
        parallel = $parallel
        classification = $classification
    }
}

$worst = if (@($perModel | Where-Object classification -eq 'WARN_KNOWN_QUEUE_LATENCY').Count -gt 0) { 'WARN_KNOWN_QUEUE_LATENCY' }
    elseif (@($perModel | Where-Object classification -eq 'WARN_NOT_VERIFIED').Count -gt 0) { 'WARN_NOT_VERIFIED' }
    elseif (@($perModel | Where-Object classification -eq 'WARN_FUNCTIONAL').Count -gt 0) { 'WARN_FUNCTIONAL' }
    else { 'PASS' }

$result = [pscustomobject]@{
    passed = $true
    classification = $worst
    detail = switch ($worst) {
        'PASS' { 'Max Concurrent Predictions = 3 auf allen geladenen Modellen -- validierte Baseline.' }
        'WARN_FUNCTIONAL' { 'Max Concurrent Predictions = 2 -- funktional, aber nicht die validierte Baseline von 3.' }
        'WARN_KNOWN_QUEUE_LATENCY' { 'Max Concurrent Predictions = 1 -- bekannte, real reproduzierte Queue-Latenz (siehe logs/latency-diagnostics/REPORT.md). Keine automatische Korrektur; manuell in LM Studio auf 3 anheben.' }
        default { 'Parallel-Wert nicht eindeutig auswertbar fuer mindestens ein geladenes Modell.' }
    }
    loadedModels = @($perModel)
    mutatesTarget = $false
}
$result | ConvertTo-Json -Depth 10
exit 0
