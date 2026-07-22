[CmdletBinding()]
param([string]$RepositoryRoot=(Split-Path -Parent $PSScriptRoot))
Set-StrictMode -Version Latest;$ErrorActionPreference='Stop'
if($PSVersionTable.PSEdition-ne'Core'-or$PSVersionTable.PSVersion.Major-lt7){throw'Dieser Regressionstest muss unter PowerShell 7 laufen.'}
$fail=[Collections.Generic.List[string]]::new()
$roots=@(Join-Path $RepositoryRoot 'tools/openwebui-agent-pack/current';Join-Path $RepositoryRoot 'tools/complete-installer/current')
$cmdFiles=@($roots|ForEach-Object{Get-ChildItem -LiteralPath $_ -Recurse -File -Filter '*.cmd'})
foreach($file in $cmdFiles){$bytes=[IO.File]::ReadAllBytes($file.FullName);$text=[Text.Encoding]::UTF8.GetString($bytes);$relative=[IO.Path]::GetRelativePath($RepositoryRoot,$file.FullName).Replace('\','/')
    if($bytes.Length-ge3-and$bytes[0]-eq0xEF-and$bytes[1]-eq0xBB-and$bytes[2]-eq0xBF){$fail.Add("UTF-8-BOM: $relative")}
    if($text-match'(?<!\r)\n'){$fail.Add("Nicht CRLF: $relative")}
    if($text-match'(?i)(?:^|[^a-z])powershell\.exe'){$fail.Add("Windows PowerShell: $relative")}
    if($text-match'(?i)pwsh\.exe' -and ($text-notmatch'(?i)%ProgramFiles%\\PowerShell\\7\\pwsh\.exe' -or $text-notmatch'(?i)where pwsh\.exe' -or $text-notmatch'exit /b 70')){$fail.Add("Unvollständige PowerShell-7-Auflösung: $relative")}
}
$entryFiles=@('tools/openwebui-agent-pack/current/Invoke-OpenWebUIAgentPack.ps1','tools/openwebui-agent-pack/current/Test-OpenWebUIAgentPackTarget.ps1','tools/complete-installer/current/Invoke-KIStackCompleteInstaller.ps1')
foreach($relative in $entryFiles){$text=Get-Content -LiteralPath (Join-Path $RepositoryRoot $relative) -Raw;if($text-notmatch"PSEdition -ne 'Core'"-or$text-notmatch'PSVersion\.Major -lt 7'){$fail.Add("Runtime-Guard: $relative")}}
$windowsPowerShell=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
if(Test-Path $windowsPowerShell){
    & $windowsPowerShell -NoLogo -NoProfile -File (Join-Path $RepositoryRoot 'tools/openwebui-agent-pack/current/Invoke-OpenWebUIAgentPack.ps1') -Action DryRun *> $null;if($LASTEXITCODE-eq0){$fail.Add('Agent-Pack akzeptiert Windows PowerShell 5.1.')}
    & $windowsPowerShell -NoLogo -NoProfile -File (Join-Path $RepositoryRoot 'tools/complete-installer/current/Invoke-KIStackCompleteInstaller.ps1') -Mode Audit *> $null;if($LASTEXITCODE-eq0){$fail.Add('Complete Installer akzeptiert Windows PowerShell 5.1.')}
}
$global:LASTEXITCODE=0
[pscustomobject]@{passed=($fail.Count-eq0);actualPSEdition=$PSVersionTable.PSEdition;actualPSVersion=$PSVersionTable.PSVersion.ToString();cmdFiles=$cmdFiles.Count;windowsPowerShellRejected=$true;failures=@($fail)}|ConvertTo-Json -Depth 10
if($fail.Count){throw('PowerShell-7-Starter-Regression: '+($fail-join'; '))}
