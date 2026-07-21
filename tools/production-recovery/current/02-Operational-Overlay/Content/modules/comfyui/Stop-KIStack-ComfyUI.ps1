# KI-STACK-COMFYUI-MANAGED
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$rootNeedle = 'C:\KI-Stack\ComfyUI'.ToLowerInvariant()
$mainNeedle = 'main.py'
$matchingProcesses = @(
    Get-CimInstance Win32_Process -ErrorAction Stop |
    Where-Object {
        $commandLine = [string]$_.CommandLine
        $commandLine -and
        $commandLine.ToLowerInvariant().Contains($rootNeedle) -and
        $commandLine.ToLowerInvariant().Contains($mainNeedle)
    }
)
if ($matchingProcesses.Count -eq 0) {
    Write-Host 'Kein laufender KI-Stack-ComfyUI-Prozess gefunden.'
    exit 0
}
foreach ($processEntry in $matchingProcesses) {
    $processId = [int]$processEntry.ProcessId
    $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
    if ($null -eq $process) {
        Write-Host ('ComfyUI-Prozess bereits beendet: PID {0}' -f $processId)
        continue
    }
    Stop-Process -InputObject $process -Force -ErrorAction SilentlyContinue
    if (Get-Process -Id $processId -ErrorAction SilentlyContinue) {
        throw ('ComfyUI-Prozess konnte nicht beendet werden: PID {0}' -f $processId)
    }
    Write-Host ('ComfyUI-Prozess beendet: PID {0}' -f $processId)
}
