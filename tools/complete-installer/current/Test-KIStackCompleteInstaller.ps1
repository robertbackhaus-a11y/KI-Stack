[CmdletBinding()]
param([string]$PackageRoot=$PSScriptRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if($PSVersionTable.PSEdition -ne 'Core' -or $PSVersionTable.PSVersion.Major -lt 7){throw 'PowerShell 7 ist erforderlich; Windows PowerShell wird nicht unterstützt.'}
Import-Module (Join-Path $PackageRoot 'CompleteInstaller.psm1') -Force
$fail=[Collections.Generic.List[string]]::new()
$required=@('VERSION','MANIFEST.json','SHA256SUMS.txt','CompleteInstaller.psm1','Invoke-KIStackCompleteInstaller.ps1','Import-KIStackExternalModels.ps1','Start-KIStack-Model-Import.cmd','ExternalModels/README.md','Test-KIStackCompleteInstaller.ps1','Test-KIStackCompleteInstallerTarget.ps1','New-KIStackCompleteInstallerArchive.ps1','README.md','BUILD-REPORT.json','VALIDATION-REPORT.json','Contracts/COMPONENTS.json','Contracts/PAYLOADS.json','Contracts/TRANSACTION.schema.json','Contracts/RESUME.schema.json','Contracts/ROLLBACK.md','Config/complete-installer.config.json','Lifecycle/Stop-KIStack-Managed.ps1','Lifecycle/Get-KIStackStatus.ps1','Lifecycle/Show-KIStackStatus.ps1','Lifecycle/Status-KIStack-Interactive.cmd','Operations/Remove-KIStackKnowledgeExperiment.ps1','Operations/Set-KIStackCodeInterpreter.ps1','Operations/Restore-KIStackCodeInterpreter.ps1','Start-KIStack-Installer.cmd','Start-KIStack-Audit.cmd','Start-KIStack-Repair.cmd','Start-KIStack-Validate.cmd','Start-KIStack-Rollback.cmd','Start-KIStack.cmd','Stop-KIStack.cmd')
foreach($file in $required){if(-not(Test-Path -LiteralPath (Join-Path $PackageRoot $file))){$fail.Add("Fehlt: $file")}}
$components=Get-Content (Join-Path $PackageRoot 'Contracts/COMPONENTS.json') -Raw|ConvertFrom-Json
if(([string]($components.components|Where-Object id -eq 'comfyui').version)-ne'1.2.2'){$fail.Add('ComfyUI-Version')}
if(([string]($components.components|Where-Object id -eq 'integration').version)-ne'1.5.9'){$fail.Add('Integration-Version')}
if(([string]($components.components|Where-Object id -eq 'openwebui-ballistics-pack').version)-ne'1.0.0'){$fail.Add('Ballistics-Version')}
if(([string]($components.components|Where-Object id -eq 'models-workflows').version)-ne'1.4.3'){$fail.Add('Models-Workflows-Version')}
$fixtures=@{FreshInstall=@{};Upgrade=@{'foundation-runtime'='1.0.9';'comfyui'='1.2.1';'integration'='1.5.8'};ModelsUpgrade=@{'foundation-runtime'='1.0.9';'python-git'='1.1.5';'comfyui'='1.2.2';'models-workflows'='1.4.1';'applications'='1.4.10';'integration'='1.5.9';'cutover-runtime'='1.6.3';'production-recovery'='1.7.0-r7';'validation-gate'='1.0.2';'target-acceptance'='1.0.10';'openwebui-agent-pack'='1.8.3';'openwebui-image-pack'='1.9.1'};Repair=@{'foundation-runtime'='1.0.9';'comfyui'='damaged';'integration'='1.5.9'};Current=@{'foundation-runtime'='1.0.9';'python-git'='1.1.5';'comfyui'='1.2.2';'models-workflows'='1.4.3';'applications'='1.4.10';'integration'='1.5.9';'cutover-runtime'='1.6.3';'production-recovery'='1.7.0-r7';'validation-gate'='1.0.2';'target-acceptance'='1.0.10';'openwebui-agent-pack'='1.8.3';'openwebui-image-pack'='1.9.1'}}
$plans=[ordered]@{}
foreach($name in $fixtures.Keys){$mode=if($name-eq'Repair'){'Repair'}else{'Upgrade'};$plans[$name]=New-KICompletePlan -Mode $mode -PackageRoot $PackageRoot -TargetRoot 'C:\fixture' -FixtureState $fixtures[$name]}
if(-not$plans.Current.alreadyCompliant){$fail.Add('AlreadyCompliant-Fixture')}
if(@($plans.FreshInstall.steps|Where-Object plannedMode -ne 'Install').Count){$fail.Add('FreshInstall-Plan')}
if(([string]($plans.Upgrade.steps|Where-Object id -eq 'comfyui').plannedMode)-ne'Upgrade'){$fail.Add('Upgrade-Plan')}
if(([string]($plans.Repair.steps|Where-Object id -eq 'comfyui').plannedMode)-ne'Repair'){$fail.Add('Repair-Plan')}
$modelsUpgradeSteps=@($plans.ModelsUpgrade.steps|Where-Object plannedMode -ne 'Skip')
if($modelsUpgradeSteps.Count-ne 1-or[string]$modelsUpgradeSteps[0].id-ne'models-workflows'-or[string]$modelsUpgradeSteps[0].plannedMode-ne'Upgrade'){$fail.Add('Models-1.4.1-to-1.4.3-Plan')}
$payloads=Get-Content (Join-Path $PackageRoot 'Contracts/PAYLOADS.json') -Raw|ConvertFrom-Json
$workflowModels=@($payloads.external|Where-Object{$_.PSObject.Properties.Name-contains'category'-and[string]$_.category-eq'models-workflows-1.4.3'})
$manualIds=@($payloads.externalManualDependencies)
if($workflowModels.Count-ne 8-or[long]($workflowModels|Measure-Object sizeBytes -Sum).Sum-ne47356936991-or[bool]$payloads.offline-or$manualIds.Count-ne7-or'flux-ae'-notin$manualIds){$fail.Add('Models-1.4.3-External-Payload-Contract')}
$source=Get-ChildItem $PackageRoot -Recurse -File|Where-Object{$_.Extension-in'.ps1','.psm1','.cmd'}|ForEach-Object{Get-Content $_.FullName -Raw}
$operationSource=Get-Content (Join-Path $PackageRoot 'CompleteInstaller.psm1') -Raw
foreach($contract in @('electron.app.LM Studio','systemctl disable','KI-Stack starten.lnk','KI-Stack stoppen.lnk','KI-Stack Status.lnk','operations.backup.json','Restore-KICompleteOperations')){if(-not$operationSource.Contains($contract)){$fail.Add("Operations-Vertrag: $contract")}}
$statusCore=Get-Content (Join-Path $PackageRoot 'Lifecycle/Get-KIStackStatus.ps1') -Raw
$statusInteractive=Get-Content (Join-Path $PackageRoot 'Lifecycle/Show-KIStackStatus.ps1') -Raw
$validateCmd=Get-Content (Join-Path $PackageRoot 'Lifecycle/Validate-KIStack.cmd') -Raw
foreach($contract in @('LM Studio /v1/models','OpenWebUI','SearXNG HTML','SearXNG JSON-Suche','ComfyUI Health','WSL-Keeper','valkey-server','uwsgi','nginx','Gesamtstatus','Zeitstempel')){if(-not$statusCore.Contains($contract)){$fail.Add("Status-Vertrag: $contract")}}
if($statusCore-match'(?i)Start-Process|Start-Service|Set-Service|Repair-KIStack|Stop-Process|Stop-Service' -or $validateCmd-match'(?i)pause|ReadKey|Read-Host'){$fail.Add('Statuskern oder Validator ist nicht strikt pausierfrei/read-only.')}
if(-not$statusInteractive.Contains('Console]::ReadKey')-or-not$statusInteractive.Contains('Tatsächlicher Exitcode')){$fail.Add('Interaktiver Status-Starter')}
$codeSource=Get-Content (Join-Path $PackageRoot 'Operations/Set-KIStackCodeInterpreter.ps1') -Raw
foreach($contract in @('ENABLE_CODE_INTERPRETER','CODE_INTERPRETER_ENGINE','pyodide','code_interpreter','ki_stack_generate_image','ki_stack_ballistics_calculator')){if(-not$codeSource.Contains($contract)){$fail.Add("Code-Interpreter-Vertrag: $contract")}}
$forbidden=('(?im)\b'+'git'+'\s+(?:cl'+'one|check'+'out|pu'+'ll|fetch|rev-parse|describe)\b|\.'+'git'+'(?:[/\\]|\b)|\bor'+'igin\b|comm'+'it[- ]hash|tr'+'ee[- ]hash')
if(($source-join"`n")-match$forbidden){$fail.Add('Git-Laufzeitvertrag')}
$cmd=Get-ChildItem $PackageRoot -Recurse -Filter '*.cmd' -File
foreach($file in $cmd){$bytes=[IO.File]::ReadAllBytes($file.FullName);if($bytes.Length-ge3-and$bytes[0]-eq239-and$bytes[1]-eq187-and$bytes[2]-eq191){$fail.Add("CMD BOM: $($file.Name)")};if(-not([Text.Encoding]::ASCII.GetString($bytes).Contains("`r`n"))){$fail.Add("CMD CRLF: $($file.Name)")}}
$ballisticsPlan=New-KICompletePlan -Mode Upgrade -PackageRoot $PackageRoot -TargetRoot 'C:\fixture' -FixtureState $fixtures.Current -EnableOpenWebUIBallistics
if(([string]($ballisticsPlan.steps|Where-Object id -eq 'openwebui-ballistics-pack').plannedMode)-ne'Install'){$fail.Add('Optional-Ballistics-Plan')}
[pscustomobject]@{passed=($fail.Count-eq0);version='2.2.3';checks=34;fixtures=$plans.Keys;failures=$fail}|ConvertTo-Json -Depth 20
if($fail.Count){exit 1}
