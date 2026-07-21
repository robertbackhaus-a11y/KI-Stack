[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$lmsCli = 'C:\Users\okami\.lmstudio\bin\lms.exe'
if (-not [string]::IsNullOrWhiteSpace($lmsCli) -and (Test-Path -LiteralPath $lmsCli -PathType Leaf)) {
    & $lmsCli server stop 2>$null | Out-Null
}
$venvToken = 'C:\KI-Stack\python\venvs\openwebui'.ToLowerInvariant()
$matchingProcesses = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
    $commandLine = [string]$_.CommandLine
    -not [string]::IsNullOrWhiteSpace($commandLine) -and
    $commandLine.ToLowerInvariant().Contains($venvToken) -and
    $commandLine.ToLowerInvariant().Contains('open_webui')
})
foreach ($processEntry in $matchingProcesses) {
    Stop-Process -Id ([int]$processEntry.ProcessId) -Force -ErrorAction SilentlyContinue
}
Write-Host ('Open-WebUI-Prozesse beendet: {0}' -f $matchingProcesses.Count)