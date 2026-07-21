[CmdletBinding()]
param([Parameter(Mandatory)][string]$ProjectRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$results=[Collections.Generic.List[object]]::new()
function Add-Check([string]$Name,[bool]$Passed,[string]$Detail){[void]$results.Add([pscustomobject][ordered]@{name=$Name;passed=$Passed;detail=$Detail})}
function Read-Text([string]$Relative){return Get-Content -LiteralPath (Join-Path $ProjectRoot $Relative) -Raw -ErrorAction Stop}
try{
 $matrix=Read-Text 'Tests\HISTORICAL-REGRESSION-MATRIX.json'|ConvertFrom-Json -Depth 100
 Add-Check 'Matrix policy' ([bool]$matrix.policy.historicalRegressionGateRequired -and [bool]$matrix.policy.nativePowerShellParserRequired) 'Historische Regressionen und nativer Parser sind Pflichtgates.'

 $config=Read-Text 'Config\kernel-config.json'|ConvertFrom-Json -Depth 100
 $manifest=Read-Text 'Modules\08-Cutover\module.json'|ConvertFrom-Json -Depth 30
 $core=Read-Text 'Core\KIStack.BuilderKernel.Core.psm1'
 $bootstrap=Read-Text 'Bootstrap-KIStack-Cutover.cmd'
 $readmeFirst=(Get-Content -LiteralPath (Join-Path $ProjectRoot 'README.md') -TotalCount 1)
 $versionsOk=([string]$config.kernelVersion -eq '1.6.3' -and [string]$config.executeRelease.releaseId -eq 'CUTOVER-1.6.3' -and [string]$manifest.version -eq '1.6.3' -and $core.Contains("kernelVersion = '1.6.3'") -and $bootstrap.Contains('KI-Stack Cutover v1.6.3') -and $readmeFirst -eq '# KI-Stack Cutover Execute v1.6.3')
 Add-Check 'Authoritative version consistency' $versionsOk 'Config, release, core, cutover module, bootstrap and README title are 1.6.3.'

 $entryNames=@('Start-Nur-Selbsttest.cmd','Start-KIStack-Cutover-DryRun.cmd','Start-KIStack-Cutover-Execute.cmd')
 $entryOk=$true
 foreach($entryName in $entryNames){$entry=Read-Text $entryName;if(-not $entry.Contains('%~dp0Bootstrap-KIStack-Cutover.cmd') -or -not $entry.Contains(' /D /C ')){$entryOk=$false}}
 $finishMatch=[regex]::Match($bootstrap,'(?ms)^:Finish\s*\r?\n.*?(?=^:[A-Za-z0-9_]+\s*$|\z)')
 $finish=if($finishMatch.Success){$finishMatch.Value}else{''}
 $finishBlockPrecise=($finishMatch.Success -and -not $finish.Contains(':EnsureElevation') -and -not $finish.Contains(':FindPowerShell') -and -not $finish.Contains(':Log'))
 $entryOk=$entryOk -and $finishBlockPrecise -and $finish.Contains('Vorgang erfolgreich abgeschlossen. Exitcode: 0') -and $finish.Contains('Vorgang fehlgeschlagen. Exitcode: %EXITCODE%') -and $finish.Contains('pause >nul') -and $finish.Contains('exit /b %EXITCODE%') -and -not $finish.Contains('exit /b 0') -and -not [regex]::IsMatch($finish,'(?im)^\s*exit\s+%EXITCODE%\s*$')
 Add-Check 'Acknowledged CMD lifecycle' $entryOk 'The exact :Finish label block displays status/logs, waits for one key and returns with exit /b.'
 Add-Check 'CMD finish-block precision' $finishBlockPrecise 'Lifecycle checks stop at the next CMD label and never inspect helper-function returns.'

 $cmdEncodingOk=$true
 foreach($file in Get-ChildItem -LiteralPath $ProjectRoot -Recurse -File -Filter '*.cmd'){
  $bytes=[IO.File]::ReadAllBytes($file.FullName)
  if($bytes.Length-ge 3 -and $bytes[0]-eq 0xEF -and $bytes[1]-eq 0xBB -and $bytes[2]-eq 0xBF){$cmdEncodingOk=$false}
  for($i=0;$i-lt $bytes.Length;$i++){if($bytes[$i]-eq 10 -and ($i-eq 0 -or $bytes[$i-1]-ne 13)){$cmdEncodingOk=$false;break}}
 }
 Add-Check 'CMD BOM and CRLF' $cmdEncodingOk 'All CMD files are BOM-free and CRLF encoded.'

 $starterModule=Read-Text 'Core\KIStack.Starter.psm1'
 $starterFilesOk=$starterModule.Contains('Bootstrap-KIStack-Cutover.cmd') -and $starterModule.Contains('Start-KIStack-Cutover.ps1') -and -not $starterModule.Contains('Bootstrap-KIStack-Applications.cmd') -and -not $starterModule.Contains('Start-KIStack-Applications.ps1')
 Add-Check 'Cutover starter identity' $starterFilesOk 'No inherited Applications starter filenames remain.'

 $preflightRelative=[string]$config.starter.embeddedPreflightRelativePath
 Add-Check 'Embedded preflight' (Test-Path -LiteralPath (Join-Path $ProjectRoot $preflightRelative) -PathType Leaf) $preflightRelative

 $psFiles=@(Get-ChildItem -LiteralPath $ProjectRoot -Recurse -File|Where-Object{$_.Extension-in @('.ps1','.psm1') -and $_.FullName-notlike (Join-Path $ProjectRoot 'State\*')})
 $automaticCollisions=[Collections.Generic.List[string]]::new()
 $invalidCmdletChains=[Collections.Generic.List[string]]::new()
 foreach($file in $psFiles){
  $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
  foreach($assignment in @($ast.FindAll({param($node)$node -is [Management.Automation.Language.AssignmentStatementAst]},$true))){
   if($assignment.Left -is [Management.Automation.Language.VariableExpressionAst]){$name=$assignment.Left.VariablePath.UserPath.ToLowerInvariant();if($name -in @('matches','input')){[void]$automaticCollisions.Add("$($file.Name):`$$name")}}
  }
  foreach($commandAst in @($ast.FindAll({param($node)$node -is [Management.Automation.Language.CommandAst]},$true))){
   $commandName=$commandAst.GetCommandName()
   if(-not [string]::IsNullOrWhiteSpace($commandName) -and $commandName.Equals('Test-Path',[StringComparison]::OrdinalIgnoreCase)){
    if([regex]::IsMatch($commandAst.Extent.Text,'(?i)(?:^|\s)-and(?:\s|$)')){
     [void]$invalidCmdletChains.Add(('{0}:{1}' -f $file.Name,$commandAst.Extent.StartLineNumber))
    }
   }
  }
 }
 Add-Check 'Automatic variable collisions' ($automaticCollisions.Count-eq 0) ($automaticCollisions-join ', ')
 Add-Check 'Cmdlet boolean chaining' ($invalidCmdletChains.Count-eq 0) ($invalidCmdletChains-join ', ')
 $safeTokens=$null;$safeErrors=$null
 $safeAst=[Management.Automation.Language.Parser]::ParseInput('$ok = (Test-Path -LiteralPath $path -PathType Leaf) -and $true',[ref]$safeTokens,[ref]$safeErrors)
 $safeFalsePositive=$false
 foreach($safeCommand in @($safeAst.FindAll({param($node)$node -is [Management.Automation.Language.CommandAst]},$true))){
  if($safeCommand.GetCommandName()-eq'Test-Path' -and [regex]::IsMatch($safeCommand.Extent.Text,'(?i)(?:^|\s)-and(?:\s|$)')){$safeFalsePositive=$true}
 }
 Add-Check 'Cmdlet boolean detector precision' ($safeErrors.Count-eq 0 -and -not $safeFalsePositive) 'Parenthesized Test-Path boolean expressions are valid and must not be reported.'

 $moduleSource=Read-Text 'Modules\07-Integration\KIModuleIntegration.psm1'
 $unsafeNul=[regex]::IsMatch($moduleSource,'\.Replace\(\s*\[char\]\s*0\s*,\s*[''\"]{2}\s*\)')
 $moduleInfo=Import-Module (Join-Path $ProjectRoot 'Modules\07-Integration\KIModuleIntegration.psm1') -Force -PassThru -DisableNameChecking -ErrorAction Stop
 try{$sample='Debian'+[char]0;$normalized = & (Get-Command Remove-KIIntegrationNullCharacters -Module $moduleInfo.Name) -Value $sample;$nulOk=($normalized-eq'Debian')}finally{Remove-Module -ModuleInfo $moduleInfo -Force -ErrorAction SilentlyContinue}
 Add-Check 'NUL removal overload' (-not $unsafeNul -and $nulOk) 'String/String Replace removes NUL without Char conversion.'

 $selfTest=Read-Text 'Tests\Test-KIStackBuilderKernel.ps1'
 $missingTests=@($matrix.requiredSelfTests|Where-Object{-not $selfTest.Contains("Add-Result -Name '$_'")})
 Add-Check 'Inherited self-test inventory' ($missingTests.Count-eq 0) ($missingTests-join ', ')
 $aggregationOk=$selfTest.Contains('$failedResults |') -and $selfTest.Contains('ForEach-Object { [string]$_.name }') -and -not [regex]::IsMatch($selfTest,'\$(?:failed|failedResults)\.name',[Text.RegularExpressions.RegexOptions]::IgnoreCase)
 Add-Check 'StrictMode failure aggregation' $aggregationOk 'Explicit enumeration supports an empty failure list.'

 $launcher=Read-Text 'Start-KIStack-Cutover.ps1'
 $syntaxIndex=$launcher.IndexOf('Test-KIStackPowerShellSyntax.ps1');$importIndex=$launcher.IndexOf('Import-Module $starterModulePath');$historyIndex=$launcher.IndexOf('Test-KIStackHistoricalRegressions.ps1')
 Add-Check 'Gate ordering' ($syntaxIndex-ge 0 -and $importIndex-gt $syntaxIndex -and $historyIndex-gt $importIndex) 'Syntax, module import, path and historical gates execute in controlled order.'

$cutoverManifest=Read-Text 'Modules\08-Cutover\module.json'|ConvertFrom-Json -Depth 30
$validationManifest=Read-Text 'Modules\99-Validation\module.json'|ConvertFrom-Json -Depth 30
$cutoverSource=Read-Text 'Modules\08-Cutover\KIModuleCutover.psm1'
$cutoverOk=([bool]$cutoverManifest.enabled -and [string]$cutoverManifest.version -eq '1.6.3' -and [bool]$validationManifest.enabled -and @($validationManifest.dependencies)-contains'KIModuleCutover' -and $cutoverSource.Contains('Start-KIStack.ps1') -and $cutoverSource.Contains('Test-KIStack-Health.ps1') -and $cutoverSource.Contains('Readiness-latest.json'))
Add-Check 'Cutover and final validation contract' $cutoverOk 'Cutover and final validation are enabled with master lifecycle and report artifacts.'


$validationSource=Read-Text 'Modules\99-Validation\KIModuleValidation.psm1'
$selfTestSource=Read-Text 'Tests\Test-KIStackBuilderKernel.ps1'
$validationStrictModeOk=(
 $validationSource.Contains("Get-KIValidationTextValue") -and
 $validationSource.Contains("DefaultValue 'UNSPECIFIED'") -and
 $validationSource.Contains("DefaultValue 'Unknown'") -and
 $validationSource.Contains("reportModules") -and
 -not $validationSource.Contains('$Context.Transaction.transactionId') -and
 -not $validationSource.Contains('$Context.Transaction.mode') -and
 -not $validationSource.Contains('[string]$_.id')
)
Add-Check 'Validation optional metadata and invalid entries' $validationStrictModeOk 'Validation reads optional transaction metadata and invalid module entries without unsafe StrictMode property access.'
$cutoverDiagnosticsOk=(
 $selfTestSource.Contains('KI-Stack-Cutover-Bootstrap.log') -and
 $selfTestSource.Contains('KI-Stack-Cutover-Starter.log') -and
 $selfTestSource.Contains('KI-Stack-Cutover-Elevation.log') -and
 $selfTestSource.Contains('KI-Stack-Cutover-SelfTest-latest.json') -and
 -not $selfTestSource.Contains('KI-Stack-Integration-Bootstrap.log') -and
 -not $selfTestSource.Contains('KI-Stack-Integration-Starter.log') -and
 -not $selfTestSource.Contains('KI-Stack-Integration-Elevation.log') -and
 -not $selfTestSource.Contains('KI-Stack-Integration-SelfTest-latest.json')
)
Add-Check 'Cutover diagnostic log identities' $cutoverDiagnosticsOk 'All starter and self-test diagnostics use the Cutover package identity.'
$acceptanceExecutionOk=(
 $selfTestSource.Contains("'KI-Validation-Acceptance-'") -and
 $selfTestSource.Contains("TEST-VALIDATION-ACCEPTANCE") -and
 $selfTestSource.Contains("ConvertFrom-Json -Depth 50") -and
 -not $selfTestSource.Contains('$validationSource.Contains("status=if($passed)')
)
Add-Check 'Executable validation acceptance contract' $acceptanceExecutionOk 'Acceptance reporting is verified through generated JSON files instead of expandable source literals.'


 $failed = @($results | Where-Object { -not [bool]$_.passed })
 $report=[pscustomobject][ordered]@{generatedAt=(Get-Date).ToString('o');release='CUTOVER-1.6.3';passed=($failed.Count-eq 0);failedNames = @($failed | ForEach-Object { [string]$_.name });results=@($results)}
 $state=Join-Path $ProjectRoot 'State\Regression';New-Item -ItemType Directory -Path $state -Force|Out-Null
 $json=$report|ConvertTo-Json -Depth 20;Set-Content -LiteralPath (Join-Path $state 'Historical-Regressions-latest.json') -Value $json -Encoding UTF8
 $json
 if ($failed.Count -gt 0) { throw ('Historical regression gate failed: ' + (($failed | ForEach-Object { [string]$_.name }) -join ', ')) }
 exit 0
}catch{
 Write-Host ('HISTORICAL REGRESSION GATE FAILED: '+$_.Exception.Message) -ForegroundColor Red
 exit 1
}
