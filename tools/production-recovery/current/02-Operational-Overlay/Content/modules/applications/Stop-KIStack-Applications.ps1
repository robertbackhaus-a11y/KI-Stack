[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$lmsCli = $null
foreach ($commandName in @('lms.exe','lms.cmd','lms')) {
    $candidate = Get-Command $commandName -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $candidate -and -not [string]::IsNullOrWhiteSpace([string]$candidate.Source)) {
        $lmsCli = [string]$candidate.Source
        break
    }
}
if ([string]::IsNullOrWhiteSpace([string]$lmsCli)) {
    foreach ($candidatePath in @(
        (Join-Path $HOME '.lmstudio\bin\lms.exe'),
        (Join-Path $HOME '.lmstudio\bin\lms.cmd')
    )) {
        if (Test-Path -LiteralPath $candidatePath -PathType Leaf) {
            $lmsCli = $candidatePath
            break
        }
    }
}
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
