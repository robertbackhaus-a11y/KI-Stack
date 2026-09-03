$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if($PSVersionTable.PSEdition-ne'Core'-or$PSVersionTable.PSVersion.Major-lt7){throw'PowerShell 7 ist erforderlich; Windows PowerShell wird nicht unterstützt.'}

$targetRoot=$PSScriptRoot
$targetRootPattern=[regex]::Escape($targetRoot.TrimEnd('\')+'\')
$owned = @(Get-CimInstance Win32_Process | Where-Object {
    $_.CommandLine -and (
        ($_.CommandLine -match $targetRootPattern -and $_.CommandLine -match '(?i)open-webui|ComfyUI|Start-KIStack|LM Studio') -or
        ($_.Name -eq 'LM Studio.exe' -and $_.CommandLine -match '(?i)(?:^|\s)--run-as-service(?:\s|$)')
    )
})
foreach ($process in $owned | Sort-Object ProcessId -Descending) {
    if ($process.ProcessId -eq $PID) { continue }
    Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
}

$runKey='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run';$runName='electron.app.LM Studio'
$runItem=Get-ItemProperty -LiteralPath $runKey -Name $runName -ErrorAction SilentlyContinue
$runProperty=if($null-ne$runItem){$runItem.PSObject.Properties[$runName]}else{$null}
if($null-ne$runProperty-and[string]$runProperty.Value-match'(?i)^"?[^"\r\n]*LM Studio\.exe"?\s+--run-as-service\s*$'){Remove-ItemProperty -LiteralPath $runKey -Name $runName -Force}

if (Get-Command wsl.exe -ErrorAction SilentlyContinue) {
    & wsl.exe -d Debian -u root -- systemctl stop nginx uwsgi valkey-server 2>$null
    & wsl.exe --terminate Debian 2>$null
}

foreach ($pidFile in @(
    (Join-Path $targetRoot 'modules/integration/wsl-keeper.pid'),
    (Join-Path $targetRoot 'modules/comfyui/comfyui.pid'),
    (Join-Path $targetRoot 'modules/applications/openwebui.pid')
)) {
    if (Test-Path -LiteralPath $pidFile) { Remove-Item -LiteralPath $pidFile -Force }
}

[pscustomobject]@{ passed=$true; ownedProcessesStopped=$owned.Count; debianTerminated=$true; stalePidFilesRemoved=$true } | ConvertTo-Json -Compress
