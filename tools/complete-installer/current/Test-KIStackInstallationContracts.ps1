[CmdletBinding()]
param([string]$PackageRoot=$PSScriptRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

$required=@('README.md','README.de.md','LICENSE','NOTICE','THIRD_PARTY_NOTICES.md','MODEL_LICENSES.md','Start-KIStack-Installer.cmd','Start-KIStackCompleteInstaller.ps1','Resume-KIStack-Installer.cmd','Status-KIStack.cmd','Lifecycle/Status-KIStack-Interactive.cmd')
$missing=@($required|Where-Object{-not(Test-Path -LiteralPath (Join-Path $PackageRoot $_))})
$startCmd=Get-Content -LiteralPath (Join-Path $PackageRoot 'Start-KIStack-Installer.cmd') -Raw
$resumeCmd=Get-Content -LiteralPath (Join-Path $PackageRoot 'Resume-KIStack-Installer.cmd') -Raw
$statusCmd=Get-Content -LiteralPath (Join-Path $PackageRoot 'Status-KIStack.cmd') -Raw
$startScript=Get-Content -LiteralPath (Join-Path $PackageRoot 'Start-KIStackCompleteInstaller.ps1') -Raw
$core=Get-Content -LiteralPath (Join-Path $PackageRoot 'CompleteInstaller.psm1') -Raw
$cmdFiles=@('Start-KIStack-Installer.cmd','Resume-KIStack-Installer.cmd','Status-KIStack.cmd')
$cmdContract=@($cmdFiles|ForEach-Object{$bytes=[IO.File]::ReadAllBytes((Join-Path $PackageRoot $_));[pscustomobject]@{name=$_;crlf=(([Text.Encoding]::ASCII.GetString($bytes))-match"`r`n");bom=($bytes.Length-ge3-and$bytes[0]-eq0xEF-and$bytes[1]-eq0xBB-and$bytes[2]-eq0xBF)}})
$apiPrompts=[regex]::Matches($startScript,"Read-Host 'Temporären OpenWebUI-Administrator-API-Key eingeben'").Count
$passed=$missing.Count-eq0-and$startCmd.Contains('Start-KIStackCompleteInstaller.ps1')-and$resumeCmd.Contains('-Resume -TransactionId')-and$statusCmd.Contains('Lifecycle\Status-KIStack-Interactive.cmd')-and$startScript.Contains('-Verb RunAs')-and$startScript.Contains('if($needsOpenWebUI.Count)')-and$apiPrompts-eq1-and$core.Contains('OpenWebUIApiToken')-and$core.Contains('apiKeyStored=$false')-and(@($cmdContract|Where-Object{-not$_.crlf-or$_.bom}).Count-eq0)
[pscustomobject]@{passed=$passed;version='2.3.0-rc15';checks=[ordered]@{requiredFiles=($missing.Count-eq0);licenseFiles=(@(@('LICENSE','NOTICE','THIRD_PARTY_NOTICES.md','MODEL_LICENSES.md')|Where-Object{-not(Test-Path -LiteralPath (Join-Path $PackageRoot $_))}).Count-eq0);powershell7=($startCmd.Contains('PowerShell 7')-and$resumeCmd.Contains('PowerShell 7'));uacSingleElevation=($startScript.Contains('-Verb RunAs')-and$startScript.Contains('if($Elevated)'));resumeContract=($resumeCmd.Contains('-Resume -TransactionId')-and$core.Contains('Resume erfordert TransactionId.'));statusReadOnly=$statusCmd.Contains('Lifecycle\Status-KIStack-Interactive.cmd');apiKeyFixture=[ordered]@{alreadyCompliantPrompts=0;agentAndVisualPrompts=$apiPrompts;storedInReportsOrResume=$false};cmdFiles=$cmdContract};missing=$missing}|ConvertTo-Json -Depth 20
if(-not$passed){exit 1}
