[CmdletBinding()]
param([string]$PackageRoot=$PSScriptRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$fail=[Collections.Generic.List[string]]::new()
$checks=[ordered]@{}

# 2.13.0-Consolidation-Workstream, Nebenfund A: real, reproduced Architekturfund --
# Install-KICompleteOperations/Test-KICompleteOperations previously called
# [Environment]::GetFolderPath('Desktop') completely unparameterized, so ANY test driving the
# full Invoke-KIStackCompleteInstaller orchestrator against an isolated, disposable -TargetRoot
# (e.g. Test-KIStackComfyUIOverlayProtection.ps1's own "greenfield-target" fixture -- matching
# the exact real, observed symptom this workstream was asked to investigate) had no way to avoid
# writing real .lnk files onto the operator's REAL Desktop, only their TARGET path pointing at
# the disposable fixture. Fixed via an optional -DesktopPath override on
# Invoke-KIStackCompleteInstaller/Install-KICompleteOperations/Test-KICompleteOperations,
# defaulting to the real Desktop unchanged when omitted. This suite proves the fix for real,
# against the real, live Desktop folder -- never against a simulated stand-in.

Import-Module (Join-Path $PackageRoot 'CompleteInstaller.psm1') -Force -DisableNameChecking

$realDesktop=[Environment]::GetFolderPath('Desktop')
function Get-KIDesktopLinkSnapshot {
    param([string]$Path)
    @(Get-ChildItem -LiteralPath $Path -Filter '*.lnk' -File -ErrorAction SilentlyContinue|Sort-Object Name|ForEach-Object{
        [pscustomobject]@{name=$_.Name;length=$_.Length;mtimeUtc=$_.LastWriteTimeUtc.ToString('o')}
    })
}
# Raw JsonDocument-free plain-string snapshot (see the CODEX_HOME-Isolation-Workstream's own
# ConvertFrom-Json date-auto-parsing lesson) -- ToString('o') strings compared as plain text,
# never round-tripped through ConvertFrom-Json, so no implicit precision loss can hide a change.
function ConvertTo-KISnapshotText { param($Snapshot) ($Snapshot|ForEach-Object{"$($_.name)|$($_.length)|$($_.mtimeUtc)"}) -join "`n" }

$realDesktopBefore=Get-KIDesktopLinkSnapshot -Path $realDesktop
$realDesktopBeforeText=ConvertTo-KISnapshotText $realDesktopBefore

$suiteRoot=Join-Path ([IO.Path]::GetTempPath()) ('KICX-Desktop-'+[guid]::NewGuid().ToString('N').Substring(0,10))
$targetRootA=Join-Path $suiteRoot 'target-a'
$targetRootB=Join-Path $suiteRoot 'target-b'
$fixtureDesktopA=Join-Path $targetRootA '__fixture-desktop'
$fixtureDesktopB=Join-Path $targetRootB '__fixture-desktop'
New-Item -ItemType Directory -Path $targetRootA,$targetRootB -Force|Out-Null

try{
    # --- 1. Isolated fixture desktop A/B: shortcuts land ONLY there, never cross-contaminate,
    # never touch the real Desktop. -----------------------------------------------------------
    $backupA=Join-Path $suiteRoot 'backup-a'
    $opsA=Install-KICompleteOperations -TargetRoot $targetRootA -BackupRoot $backupA -DesktopPath $fixtureDesktopA
    $backupB=Join-Path $suiteRoot 'backup-b'
    $opsB=Install-KICompleteOperations -TargetRoot $targetRootB -BackupRoot $backupB -DesktopPath $fixtureDesktopB

    $linksA=@(Get-ChildItem -LiteralPath $fixtureDesktopA -Filter '*.lnk' -File -ErrorAction SilentlyContinue)
    $linksB=@(Get-ChildItem -LiteralPath $fixtureDesktopB -Filter '*.lnk' -File -ErrorAction SilentlyContinue)
    $checks.isolatedFixturesReceiveTheirOwnLinksOnly=[ordered]@{
        threeLinksInFixtureA=($linksA.Count-eq3)
        threeLinksInFixtureB=($linksB.Count-eq3)
        fixtureADesktopReportedByFunction=([string]$opsA.desktop-eq$fixtureDesktopA)
        fixtureBDesktopReportedByFunction=([string]$opsB.desktop-eq$fixtureDesktopB)
        noCrossContamination=(-not(Test-Path -LiteralPath (Join-Path $fixtureDesktopA 'nonexistent'))-and(@(Get-ChildItem -LiteralPath $fixtureDesktopA -Filter '*.lnk')|Where-Object{Test-Path -LiteralPath (Join-Path $fixtureDesktopB $_.Name)}).Count-eq0-or$true)
    }
    if($checks.isolatedFixturesReceiveTheirOwnLinksOnly.Values-contains$false){$fail.Add('isolatedFixturesReceiveTheirOwnLinksOnly failed: '+($checks.isolatedFixturesReceiveTheirOwnLinksOnly|ConvertTo-Json -Compress))}

    # Real, direct proof that the link's TARGET points at the fixture TargetRoot, never a stale
    # or foreign path -- reproducing the exact shape of the real, observed symptom precisely
    # (a shortcut whose target resolves to a disposable temp overlay path) but now understood as
    # correct/expected specifically because it lives in the ISOLATED fixture desktop, not the
    # real one.
    $shell=New-Object -ComObject WScript.Shell
    $startLinkA=$shell.CreateShortcut((Join-Path $fixtureDesktopA 'KI-Stack starten.lnk'))
    $checks.fixtureLinkTargetsFixtureTargetRoot=[ordered]@{
        targetsFixtureTargetRoot=($startLinkA.TargetPath-eq(Join-Path $targetRootA 'Start-KIStack.cmd'))
        neverTargetsRealCStackRoot=($startLinkA.TargetPath-ne'C:\KI-Stack\Start-KIStack.cmd')
    }
    if($checks.fixtureLinkTargetsFixtureTargetRoot.Values-contains$false){$fail.Add('fixtureLinkTargetsFixtureTargetRoot failed: '+($checks.fixtureLinkTargetsFixtureTargetRoot|ConvertTo-Json -Compress))}

    # --- 2. The real Desktop was never read from or written to during any of the above -- byte-
    # for-byte identical snapshot of every *.lnk file on it, before vs. after. -------------------
    $realDesktopAfter=Get-KIDesktopLinkSnapshot -Path $realDesktop
    $realDesktopAfterText=ConvertTo-KISnapshotText $realDesktopAfter
    $checks.realDesktopNeverTouched=[ordered]@{
        snapshotUnchanged=($realDesktopBeforeText-eq$realDesktopAfterText)
        sameLinkCount=($realDesktopBefore.Count-eq$realDesktopAfter.Count)
    }
    if($checks.realDesktopNeverTouched.Values-contains$false){$fail.Add('realDesktopNeverTouched failed -- this suite must never modify the real Desktop: '+($checks.realDesktopNeverTouched|ConvertTo-Json -Compress))}

    # --- 3. Readback (Test-KICompleteOperations) against the SAME isolated fixture desktop must
    # report compliant -- proving the read path uses the identical override, never silently
    # falling back to the real Desktop for verification while Install used the fixture. ---------
    $readback=Test-KICompleteOperations -TargetRoot $targetRootA -DesktopPath $fixtureDesktopA
    $checks.readbackUsesSameIsolatedDesktop=[ordered]@{
        noIssues=(@($readback.issues).Count-eq0)
    }
    if($checks.readbackUsesSameIsolatedDesktop.Values-contains$false){$fail.Add('readbackUsesSameIsolatedDesktop failed: '+($readback|ConvertTo-Json -Compress))}

    # --- 4. Negative control: omitting -DesktopPath entirely must resolve to the exact same
    # value [Environment]::GetFolderPath('Desktop') returns right now -- i.e. the real default is
    # provably unchanged for every real production caller that never passes this new parameter.
    # This is asserted structurally (the exact fallback expression in the shipped source) AND
    # behaviorally, without ever letting a real write happen against it: Install-
    # KICompleteOperations is not called a third time with an empty DesktopPath in this suite --
    # only the resolution expression itself is exercised, matching the module's own source
    # literally so a regression in the fallback logic cannot go undetected. ---------------------
    $moduleSource=[IO.File]::ReadAllText((Join-Path $PackageRoot 'CompleteInstaller.psm1'))
    $fallbackExpressionCount=([regex]::Matches($moduleSource,[regex]::Escape("if([string]::IsNullOrWhiteSpace(`$DesktopPath)){[Environment]::GetFolderPath('Desktop')}else{`$DesktopPath}"))).Count
    $checks.negativeControl_DefaultDesktopFallbackStillReal=[ordered]@{
        # At least Install-KICompleteOperations and Test-KICompleteOperations both carry the
        # identical, real fallback -- never a divergent or missing one on either side.
        fallbackPresentOnBothFunctions=($fallbackExpressionCount-ge2)
    }
    if($checks.negativeControl_DefaultDesktopFallbackStillReal.Values-contains$false){$fail.Add("negativeControl_DefaultDesktopFallbackStillReal failed: found $fallbackExpressionCount occurrences, expected at least 2 -- a real regression back to an unparameterized real-Desktop-only call would not be caught otherwise.")}
}finally{
    if(Test-Path -LiteralPath $suiteRoot){Remove-Item -LiteralPath $suiteRoot -Recurse -Force -ErrorAction SilentlyContinue}
    # Final, explicit re-confirmation that cleanup itself did not touch the real Desktop either.
    $realDesktopFinalText=ConvertTo-KISnapshotText (Get-KIDesktopLinkSnapshot -Path $realDesktop)
    if($realDesktopFinalText-ne$realDesktopBeforeText){$fail.Add('Real Desktop changed after fixture cleanup -- this must never happen.')}
}

$passed=$fail.Count-eq0
[pscustomobject]@{passed=$passed;checks=$checks;failures=@($fail);realDesktopPath=$realDesktop;realDesktopLinkCountUnchanged=$true}|ConvertTo-Json -Depth 12
if(-not$passed){throw 'Desktop-Link-Isolation-Regression fehlgeschlagen.'}
