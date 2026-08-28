[CmdletBinding()]
param([string]$PackageRoot=$PSScriptRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PackageRoot 'CompleteInstaller.psm1') -Force

$fail=[Collections.Generic.List[string]]::new()
$checks=[ordered]@{}
$fixtureRoot=Join-Path ([IO.Path]::GetTempPath()) ('KIStack-PayloadHygiene-'+[guid]::NewGuid().ToString('N'))
try{
    New-Item -ItemType Directory -Path $fixtureRoot -Force|Out-Null

    function New-KIFixturePackage {
        param([string]$Root,[string]$CutoverRuntimeFileName,[string]$ComfyUIFileName)
        if(Test-Path -LiteralPath $Root){Remove-Item -LiteralPath $Root -Recurse -Force}
        New-Item -ItemType Directory -Path (Join-Path $Root 'Payload/CutoverRuntime'),(Join-Path $Root 'Payload/ComfyUI') -Force|Out-Null
        Set-Content -LiteralPath (Join-Path $Root "Payload/CutoverRuntime/$CutoverRuntimeFileName") -Value 'current-cutover-content' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $Root "Payload/ComfyUI/$ComfyUIFileName") -Value 'current-comfyui-content' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $Root 'CompleteInstaller.psm1') -Value '# fixture' -Encoding UTF8
    }

    $packageRoot=Join-Path $fixtureRoot 'package'
    New-KIFixturePackage -Root $packageRoot -CutoverRuntimeFileName 'KI-Stack-Cutover-Execute-v1.6.10-core.zip' -ComfyUIFileName 'KI-Stack-ComfyUI-v1.2.4.zip'

    # 1. Empty/nonexistent destination -> current payload gets installed cleanly.
    $targetRoot1=Join-Path $fixtureRoot 'target-empty'
    $backupRoot1=Join-Path $fixtureRoot 'backup-empty'
    New-Item -ItemType Directory -Path $targetRoot1 -Force|Out-Null
    Install-KICompleteOrchestrator -PackageRoot $packageRoot -TargetRoot $targetRoot1 -BackupRoot $backupRoot1|Out-Null
    $cutoverFiles1=@(Get-ChildItem -LiteralPath (Join-Path $targetRoot1 'installer/complete/Payload/CutoverRuntime') -File)
    $checks.emptyDestination=[ordered]@{
        exactlyOneFile=$cutoverFiles1.Count-eq1
        correctFile=$cutoverFiles1.Count-gt0-and$cutoverFiles1[0].Name-eq'KI-Stack-Cutover-Execute-v1.6.10-core.zip'
    }
    if($checks.emptyDestination.Values-contains$false){$fail.Add('Scenario EmptyDestination failed: '+(($cutoverFiles1.Name)-join', '))}

    # 2. Destination holds stale same-type version(s) -> only the current payload remains afterward.
    $targetRoot2=Join-Path $fixtureRoot 'target-stale'
    $backupRoot2=Join-Path $fixtureRoot 'backup-stale'
    $stalePath2=Join-Path $targetRoot2 'installer/complete/Payload/CutoverRuntime'
    New-Item -ItemType Directory -Path $stalePath2 -Force|Out-Null
    Set-Content -LiteralPath (Join-Path $stalePath2 'KI-Stack-Cutover-Execute-v1.6.3-core.zip') -Value 'stale-v1.6.3' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $stalePath2 'KI-Stack-Cutover-Execute-v1.6.5-core.zip') -Value 'stale-v1.6.5' -Encoding UTF8
    Install-KICompleteOrchestrator -PackageRoot $packageRoot -TargetRoot $targetRoot2 -BackupRoot $backupRoot2|Out-Null
    $cutoverFiles2=@(Get-ChildItem -LiteralPath (Join-Path $targetRoot2 'installer/complete/Payload/CutoverRuntime') -File)
    $backedUpStale=@(Get-ChildItem -LiteralPath (Join-Path $backupRoot2 'installer/complete/Payload/CutoverRuntime') -File -ErrorAction SilentlyContinue)
    $checks.staleVersionsRemoved=[ordered]@{
        exactlyOneFileRemains=$cutoverFiles2.Count-eq1
        correctFileRemains=$cutoverFiles2.Count-gt0-and$cutoverFiles2[0].Name-eq'KI-Stack-Cutover-Execute-v1.6.10-core.zip'
        staleFilesGone=(@($cutoverFiles2.Name)-notcontains'KI-Stack-Cutover-Execute-v1.6.3-core.zip')-and(@($cutoverFiles2.Name)-notcontains'KI-Stack-Cutover-Execute-v1.6.5-core.zip')
        preCleanupStateWasBackedUp=$backedUpStale.Count-eq2
    }
    if($checks.staleVersionsRemoved.Values-contains$false){$fail.Add('Scenario StaleVersionsRemoved failed: remaining='+(($cutoverFiles2.Name)-join', ')+'; backedUp='+$backedUpStale.Count)}

    # 3. A foreign, misplaced payload (wrong type entirely) inside the CutoverRuntime folder is also removed.
    $targetRoot3=Join-Path $fixtureRoot 'target-foreign'
    $backupRoot3=Join-Path $fixtureRoot 'backup-foreign'
    $foreignPath3=Join-Path $targetRoot3 'installer/complete/Payload/CutoverRuntime'
    New-Item -ItemType Directory -Path $foreignPath3 -Force|Out-Null
    Set-Content -LiteralPath (Join-Path $foreignPath3 'KI-Stack-Models-Workflows-Execute-v1.3.8.zip') -Value 'foreign-misplaced' -Encoding UTF8
    # A sibling payload type folder must be left alone by the CutoverRuntime-scoped cleanup.
    $comfyPath3=Join-Path $targetRoot3 'installer/complete/Payload/ComfyUI'
    New-Item -ItemType Directory -Path $comfyPath3 -Force|Out-Null
    Set-Content -LiteralPath (Join-Path $comfyPath3 'KI-Stack-ComfyUI-v1.2.4.zip') -Value 'current-comfyui-content' -Encoding UTF8
    Install-KICompleteOrchestrator -PackageRoot $packageRoot -TargetRoot $targetRoot3 -BackupRoot $backupRoot3|Out-Null
    $cutoverFiles3=@(Get-ChildItem -LiteralPath $foreignPath3 -File)
    $comfyFiles3=@(Get-ChildItem -LiteralPath $comfyPath3 -File)
    $checks.foreignPayloadRemoved=[ordered]@{
        foreignFileGone=(@($cutoverFiles3.Name)-notcontains'KI-Stack-Models-Workflows-Execute-v1.3.8.zip')
        currentFilePresent=(@($cutoverFiles3.Name)-contains'KI-Stack-Cutover-Execute-v1.6.10-core.zip')
        siblingTypeUnaffected=$comfyFiles3.Count-eq1-and$comfyFiles3[0].Name-eq'KI-Stack-ComfyUI-v1.2.4.zip'
    }
    if($checks.foreignPayloadRemoved.Values-contains$false){$fail.Add('Scenario ForeignPayloadRemoved failed: cutover='+(($cutoverFiles3.Name)-join', ')+'; comfy='+(($comfyFiles3.Name)-join', '))}

    # 4. Repeating the same deployment run is idempotent.
    $targetRoot4=Join-Path $fixtureRoot 'target-idempotent'
    $backupRoot4=Join-Path $fixtureRoot 'backup-idempotent'
    New-Item -ItemType Directory -Path $targetRoot4 -Force|Out-Null
    Install-KICompleteOrchestrator -PackageRoot $packageRoot -TargetRoot $targetRoot4 -BackupRoot $backupRoot4|Out-Null
    $firstRunFiles=@(Get-ChildItem -LiteralPath (Join-Path $targetRoot4 'installer/complete/Payload/CutoverRuntime') -File|ForEach-Object Name)
    Install-KICompleteOrchestrator -PackageRoot $packageRoot -TargetRoot $targetRoot4 -BackupRoot $backupRoot4|Out-Null
    $secondRunFiles=@(Get-ChildItem -LiteralPath (Join-Path $targetRoot4 'installer/complete/Payload/CutoverRuntime') -File|ForEach-Object Name)
    $checks.idempotentRerun=[ordered]@{
        sameFileSetBothRuns=(@($firstRunFiles)-join',')-eq(@($secondRunFiles)-join',')
        stillExactlyOneFile=$secondRunFiles.Count-eq1
    }
    if($checks.idempotentRerun.Values-contains$false){$fail.Add('Scenario IdempotentRerun failed: first='+($firstRunFiles-join', ')+'; second='+($secondRunFiles-join', '))}

    $passed=$fail.Count-eq0
    [pscustomobject]@{passed=$passed;checks=$checks;failures=@($fail)}|ConvertTo-Json -Depth 10
    if(-not$passed){throw 'Payload-Deployment-Hygiene-Regression fehlgeschlagen.'}
}
finally{if(Test-Path $fixtureRoot){Remove-Item -LiteralPath $fixtureRoot -Recurse -Force}}
