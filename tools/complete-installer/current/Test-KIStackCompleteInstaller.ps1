[CmdletBinding()]
param([string]$PackageRoot=$PSScriptRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PackageRoot 'CompleteInstaller.psm1') -Force
$fail=[Collections.Generic.List[string]]::new()
$required=@('VERSION','MANIFEST.json','SHA256SUMS.txt','CompleteInstaller.psm1','Invoke-KIStackCompleteInstaller.ps1','Test-KIStackCompleteInstaller.ps1','Test-KIStackCompleteInstallerTarget.ps1','New-KIStackCompleteInstallerArchive.ps1','README.md','BUILD-REPORT.json','VALIDATION-REPORT.json','Contracts/COMPONENTS.json','Contracts/PAYLOADS.json','Contracts/TRANSACTION.schema.json','Contracts/RESUME.schema.json','Contracts/ROLLBACK.md','Config/complete-installer.config.json','Start-KIStack-Installer.cmd','Start-KIStack-Audit.cmd','Start-KIStack-Repair.cmd','Start-KIStack-Validate.cmd','Start-KIStack-Rollback.cmd','Start-KIStack.cmd','Stop-KIStack.cmd')
foreach($file in $required){if(-not(Test-Path -LiteralPath (Join-Path $PackageRoot $file))){$fail.Add("Fehlt: $file")}}
$components=Get-Content (Join-Path $PackageRoot 'Contracts/COMPONENTS.json') -Raw|ConvertFrom-Json
if(([string]($components.components|Where-Object id -eq 'comfyui').version)-ne'1.2.2'){$fail.Add('ComfyUI-Version')}
if(([string]($components.components|Where-Object id -eq 'integration').version)-ne'1.5.9'){$fail.Add('Integration-Version')}
if(([string]($components.components|Where-Object id -eq 'openwebui-ballistics-pack').version)-ne'1.0.0'){$fail.Add('Ballistics-Version')}
$fixtures=@{FreshInstall=@{};Upgrade=@{'foundation-runtime'='1.0.9';'comfyui'='1.2.1';'integration'='1.5.8'};Repair=@{'foundation-runtime'='1.0.9';'comfyui'='damaged';'integration'='1.5.9'};Current=@{'foundation-runtime'='1.0.9';'python-git'='1.1.5';'comfyui'='1.2.2';'models-workflows'='1.3.7';'applications'='1.4.10';'integration'='1.5.9';'cutover-runtime'='1.6.3';'production-recovery'='1.7.0-r7';'validation-gate'='1.0.2';'target-acceptance'='1.0.10';'openwebui-agent-pack'='1.8.2';'openwebui-image-pack'='1.9.0'}}
$plans=[ordered]@{}
foreach($name in $fixtures.Keys){$mode=if($name-eq'Repair'){'Repair'}else{'Upgrade'};$plans[$name]=New-KICompletePlan -Mode $mode -PackageRoot $PackageRoot -TargetRoot 'C:\fixture' -FixtureState $fixtures[$name]}
if(-not$plans.Current.alreadyCompliant){$fail.Add('AlreadyCompliant-Fixture')}
if(@($plans.FreshInstall.steps|Where-Object plannedMode -ne 'Install').Count){$fail.Add('FreshInstall-Plan')}
if(([string]($plans.Upgrade.steps|Where-Object id -eq 'comfyui').plannedMode)-ne'Upgrade'){$fail.Add('Upgrade-Plan')}
if(([string]($plans.Repair.steps|Where-Object id -eq 'comfyui').plannedMode)-ne'Repair'){$fail.Add('Repair-Plan')}
$source=Get-ChildItem $PackageRoot -Recurse -File|Where-Object{$_.Extension-in'.ps1','.psm1','.cmd'}|ForEach-Object{Get-Content $_.FullName -Raw}
$forbidden=('(?im)\b'+'git'+'\s+(?:cl'+'one|check'+'out|pu'+'ll|fetch|rev-parse|describe)\b|\.'+'git'+'(?:[/\\]|\b)|\bor'+'igin\b|comm'+'it[- ]hash|tr'+'ee[- ]hash')
if(($source-join"`n")-match$forbidden){$fail.Add('Git-Laufzeitvertrag')}
$cmd=Get-ChildItem $PackageRoot -Recurse -Filter '*.cmd' -File
foreach($file in $cmd){$bytes=[IO.File]::ReadAllBytes($file.FullName);if($bytes.Length-ge3-and$bytes[0]-eq239-and$bytes[1]-eq187-and$bytes[2]-eq191){$fail.Add("CMD BOM: $($file.Name)")};if(-not([Text.Encoding]::ASCII.GetString($bytes).Contains("`r`n"))){$fail.Add("CMD CRLF: $($file.Name)")}}
$ballisticsPlan=New-KICompletePlan -Mode Upgrade -PackageRoot $PackageRoot -TargetRoot 'C:\fixture' -FixtureState $fixtures.Current -EnableOpenWebUIBallistics
if(([string]($ballisticsPlan.steps|Where-Object id -eq 'openwebui-ballistics-pack').plannedMode)-ne'Install'){$fail.Add('Optional-Ballistics-Plan')}
[pscustomobject]@{passed=($fail.Count-eq0);version='2.1.0';checks=22;fixtures=$plans.Keys;failures=$fail}|ConvertTo-Json -Depth 20
if($fail.Count){exit 1}
