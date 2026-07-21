[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$stopScripts = @(
    [pscustomobject]@{ name = 'Applications'; path = 'C:\KI-Stack\modules\applications\Stop-KIStack-Applications.ps1' },
    [pscustomobject]@{ name = 'ComfyUI'; path = 'C:\KI-Stack\modules\comfyui\Stop-KIStack-ComfyUI.ps1' },
    [pscustomobject]@{ name = 'SearXNG'; path = 'C:\KI-Stack\modules\integration\Stop-KIStack-SearXNG.ps1' }
)

$pwsh = $null
foreach ($candidate in @(
    $(if ($env:ProgramW6432) { Join-Path $env:ProgramW6432 'PowerShell\7\pwsh.exe' }),
    $(if ($env:ProgramFiles) { Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe' })
)) {
    if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        $pwsh = $candidate
        break
    }
}
if (-not $pwsh) {
    try { $pwsh = (Get-Command pwsh.exe -ErrorAction Stop).Source } catch {}
}
if (-not $pwsh) {
    Write-Error 'PowerShell 7 wurde nicht gefunden.'
    exit 1
}

$failures = [Collections.Generic.List[string]]::new()
foreach ($entry in $stopScripts) {
    if (-not (Test-Path -LiteralPath $entry.path -PathType Leaf)) {
        [void]$failures.Add("Stopskript fehlt: $($entry.path)")
        continue
    }
    Write-Host ("Stoppe {0}" -f $entry.name)
    & $pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File $entry.path
    if ($LASTEXITCODE -ne 0) {
        [void]$failures.Add("$($entry.name): Exitcode $LASTEXITCODE")
    }
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error $_ }
    exit 1
}
exit 0
