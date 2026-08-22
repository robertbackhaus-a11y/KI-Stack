[CmdletBinding()]
param([string]$ProjectRoot=(Split-Path -Parent $PSScriptRoot))

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$temp=Join-Path ([IO.Path]::GetTempPath()) ('KIStack-VCRuntime-'+[guid]::NewGuid().ToString('N'))
$oldWinget=$env:KI_TEST_WINGET
$oldSource=$env:KI_TEST_VC_SOURCE
$oldTargetA=$env:KI_TEST_VC_TARGET_A
$oldTargetB=$env:KI_TEST_VC_TARGET_B
try{
    New-Item -ItemType Directory -Path $temp -Force|Out-Null
    $sourceDll=Join-Path $temp 'vc-runtime-source.dll'
    Add-Type -TypeDefinition @'
using System.Reflection;
[assembly: AssemblyVersion("14.40.33810.0")]
[assembly: AssemblyFileVersion("14.40.33810.0")]
public sealed class KIStackVCRuntimeFixture { }
'@ -OutputAssembly $sourceDll -OutputType Library
    $targetA=Join-Path $temp 'System32/vcruntime140.dll'
    $targetB=Join-Path $temp 'System32/msvcp140.dll'
    New-Item -ItemType Directory -Path (Split-Path -Parent $targetA) -Force|Out-Null
    $winget=Join-Path $temp 'winget.cmd'
    [IO.File]::WriteAllText($winget,"@echo off`r`ncopy /y `"%KI_TEST_VC_SOURCE%`" `"%KI_TEST_VC_TARGET_A%`" >nul`r`ncopy /y `"%KI_TEST_VC_SOURCE%`" `"%KI_TEST_VC_TARGET_B%`" >nul`r`nexit /b 0`r`n",[Text.ASCIIEncoding]::new())
    $env:KI_TEST_WINGET=$winget;$env:KI_TEST_VC_SOURCE=$sourceDll;$env:KI_TEST_VC_TARGET_A=$targetA;$env:KI_TEST_VC_TARGET_B=$targetB

    $modulePath=Join-Path $ProjectRoot 'Modules/02-Runtime/KIModuleRuntime.psm1'
    $module=Import-Module $modulePath -Force -PassThru
    & $module { function script:Get-Command { param([string]$Name,[object]$ErrorAction) if($Name-eq'winget.exe'){return [pscustomobject]@{Source=$env:KI_TEST_WINGET}}; Microsoft.PowerShell.Core\Get-Command -Name $Name -ErrorAction $ErrorAction } }
    $component=[pscustomobject]@{id='VisualCppRuntimeX64';displayName='Microsoft Visual C++ Redistributable x64';requiredFiles=@($targetA,$targetB);minimumVersion='14.0.0.0';packageManager='winget';packageId='Microsoft.VCRedist.2015+.x64'}
    $context=[pscustomobject]@{Config=[pscustomobject]@{runtime=[pscustomobject]@{components=@($component)};executeRelease=[pscustomobject]@{allowWingetInstall=$true}};Mode='Execute'}
    $before=Test-KIModuleRuntime -Context $context
    $installed=Install-KIModuleRuntime -Context $context
    $after=Validate-KIModuleRuntime -Context $context
    $reused=Install-KIModuleRuntime -Context $context
    $config=Get-Content -LiteralPath (Join-Path $ProjectRoot 'Config/kernel-config.json') -Raw|ConvertFrom-Json
    $realContract=@($config.runtime.components|Where-Object id -eq 'VisualCppRuntimeX64')
    $runtimeOrder=[array]::IndexOf(@($config.executeRelease.enabledModules),'KIModuleRuntime')
    $comfyOrder=[array]::IndexOf(@($config.executeRelease.enabledModules),'KIModuleComfyUI')
    $passed=$before.success-and($before.data.missingComponentIds-contains'VisualCppRuntimeX64')-and$installed.success-and($installed.data.installedByTransaction-contains'VisualCppRuntimeX64')-and(Test-Path $targetA)-and(Test-Path $targetB)-and$after.success-and$reused.skipped-and$realContract.Count-eq1-and$realContract[0].packageId-eq'Microsoft.VCRedist.2015+.x64'-and$runtimeOrder-ge0-and$runtimeOrder-lt$comfyOrder
    [pscustomobject]@{passed=$passed;initiallyMissing=$true;plannedPackage='Microsoft.VCRedist.2015+.x64';installedThroughRuntime=[bool]$installed.success;requiredDllsPresentAfterInstall=((Test-Path $targetA)-and(Test-Path $targetB));reusedWhenCompliant=[bool]$reused.skipped;runtimeBeforeComfyUI=($runtimeOrder-lt$comfyOrder);targetSystemAccessed=$false}|ConvertTo-Json -Depth 10
    if(-not$passed){throw'VC++-Runtime-Regression fehlgeschlagen.'}
}finally{
    Remove-Module KIModuleRuntime -Force -ErrorAction SilentlyContinue
    $env:KI_TEST_WINGET=$oldWinget;$env:KI_TEST_VC_SOURCE=$oldSource;$env:KI_TEST_VC_TARGET_A=$oldTargetA;$env:KI_TEST_VC_TARGET_B=$oldTargetB
    if(Test-Path $temp){Remove-Item $temp -Recurse -Force}
}
