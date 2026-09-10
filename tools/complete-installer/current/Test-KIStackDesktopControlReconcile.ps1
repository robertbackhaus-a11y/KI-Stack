[CmdletBinding()]
param([string]$PackageRoot=$PSScriptRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

# Regression suite for the Complete Installer's desktop-control reconcile decision.
#
# Test-KICompleteDesktopControlCompliant is the gate BOTH New-KICompletePlan (planning) and
# Invoke-KIStackCompleteInstaller's skip-already-compliant recheck consult. Before the fix it
# only checked version + marker + the target's OWN SHA256SUMS + required files, so an internally
# consistent OLD deployment at the same component VERSION (0.1.0 == 0.1.0) was reported compliant
# and the isolated desktop-control step was skipped entirely -- never reaching the component's
# own -SourceRoot parity check in Install-KIDesktopControl. This suite proves the gate now also
# enforces parity against THIS installer run's Payload/DesktopControl/*.zip (never the git
# working tree), and that reconcile through the isolated entry point restores the payload state
# and is a NoOp on a second run.
#
# No GUI, no winapp, no network. The desktop-control payload zip is built in-process from the
# repo source tree; the deployed target is produced by the component's own Install entry point.

$repoRoot=[IO.Path]::GetFullPath((Join-Path $PackageRoot '..\..\..'))
$dcSource=Join-Path $repoRoot 'tools\desktop-control\current'

Import-Module (Join-Path $PackageRoot 'CompleteInstaller.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $dcSource 'DesktopControl.psm1') -Force

$fail=[Collections.Generic.List[string]]::new()
$checks=[ordered]@{}
$scratch=Join-Path ([IO.Path]::GetTempPath()) ('KIStack-DCReconcile-'+[guid]::NewGuid().ToString('N').Substring(0,12))
New-Item -ItemType Directory -Path $scratch -Force|Out-Null

function New-DCPayloadPackage {
    # Minimal installer package: Payload/DesktopControl/KI-Stack-Desktop-Control-v<ver>.zip built
    # from $SourceTree, entries prefixed with the archiveRoot exactly like New-DeterministicArchive.
    param([Parameter(Mandatory)][string]$SourceTree,[Parameter(Mandatory)][string]$PackageDir,[string]$Version='0.1.0')
    $payloadDir=Join-Path $PackageDir 'Payload\DesktopControl'
    New-Item -ItemType Directory -Path $payloadDir -Force|Out-Null
    Add-Type -AssemblyName System.IO.Compression
    $zipPath=Join-Path $payloadDir "KI-Stack-Desktop-Control-v$Version.zip"
    if(Test-Path -LiteralPath $zipPath){Remove-Item -LiteralPath $zipPath -Force}
    $stream=[IO.File]::Open($zipPath,[IO.FileMode]::CreateNew)
    try{
        $archive=[IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Create,$false)
        try{
            foreach($file in Get-ChildItem -LiteralPath $SourceTree -Recurse -File){
                $rel=[IO.Path]::GetRelativePath($SourceTree,$file.FullName).Replace('\','/')
                $entry=$archive.CreateEntry("KI-Stack-Desktop-Control-v$Version/$rel",[IO.Compression.CompressionLevel]::Optimal)
                $out=$entry.Open();$in=[IO.File]::OpenRead($file.FullName)
                try{$in.CopyTo($out)}finally{$out.Dispose();$in.Dispose()}
            }
        }finally{$archive.Dispose()}
    }finally{$stream.Dispose()}
    $PackageDir
}

function Repair-DCTargetChecksums {
    # Rewrite the deployed target's own SHA256SUMS.txt so it stays internally consistent after an
    # in-place edit -- i.e. the "old but internally consistent" deployment the bug let through.
    param([Parameter(Mandatory)][string]$DeployedPackageRoot)
    $sum=Join-Path $DeployedPackageRoot 'SHA256SUMS.txt'
    $lines=Get-Content -LiteralPath $sum|ForEach-Object{
        if($_ -match '^([0-9a-fA-F]{64})\s+\*?(.+)$'){
            $f=Join-Path $DeployedPackageRoot ($Matches[2].Replace('/',[IO.Path]::DirectorySeparatorChar))
            "$((Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash.ToLowerInvariant()) *$($Matches[2])"
        }else{$_}
    }
    [IO.File]::WriteAllLines($sum,$lines,[Text.UTF8Encoding]::new($false))
}

try{
    # "Inhalt B" = the current repo source; the installer package carries it as its payload.
    $pkg=New-DCPayloadPackage -SourceTree $dcSource -PackageDir (Join-Path $scratch 'installer-package')
    $extractRoot=Join-Path $scratch 'payload-extract'
    $payloadTree=Expand-KICompletePayload -PackageRoot $pkg -PayloadName 'DesktopControl' -Destination $extractRoot
    $entry=Join-Path $payloadTree 'Invoke-KIStackDesktopControl.ps1'

    # --- Scenario A: payload and target identical => compliant, with and without the new arg ----
    $targetA=Join-Path $scratch 'target-A'
    $null=& $entry -Action Install -TargetRoot $targetA|Out-Null
    $pkgRootA=(Get-KIDesktopControlInstallPaths -TargetRoot $targetA).packageRoot
    $checks.identicalPayloadIsCompliant=[ordered]@{
        legacyGate=(Test-KICompleteDesktopControlCompliant -TargetRoot $targetA -ExpectedComponentVersion '0.1.0')
        payloadParity=(Test-KICompleteDesktopControlPayloadParity -PackageRoot $pkg -DeployedPackageRoot $pkgRootA)
        gateWithInstallerPackageRoot=(Test-KICompleteDesktopControlCompliant -TargetRoot $targetA -ExpectedComponentVersion '0.1.0' -InstallerPackageRoot $pkg)
    }
    if($checks.identicalPayloadIsCompliant.Values-contains$false){$fail.Add('identicalPayloadIsCompliant: '+($checks.identicalPayloadIsCompliant|ConvertTo-Json -Compress))}

    # --- Scenario B: internally consistent OLD deployment ("Inhalt A"), same VERSION -----------
    $targetB=Join-Path $scratch 'target-B'
    $null=& $entry -Action Install -TargetRoot $targetB|Out-Null
    $pkgRootB=(Get-KIDesktopControlInstallPaths -TargetRoot $targetB).packageRoot
    Add-Content -LiteralPath (Join-Path $pkgRootB 'DesktopControl.Policy.psm1') -Value "`n# Inhalt A -- drifted at same VERSION"
    Repair-DCTargetChecksums -DeployedPackageRoot $pkgRootB
    $versionsEqual=((Get-Content -LiteralPath (Join-Path $targetB 'tools\desktop-control\VERSION') -Raw).Trim() -eq '0.1.0') `
        -and ([string](Get-Content -LiteralPath (Join-Path $targetB 'tools\desktop-control\installation.json') -Raw|ConvertFrom-Json).version -eq '0.1.0')
    $checks.internallyConsistentOldDeploymentNotSkipped=[ordered]@{
        versionMatchesOnBothSides=$versionsEqual
        targetSelfConsistent=(Test-KIDesktopControlChecksums -PackageRoot $pkgRootB -ChecksumFile (Join-Path $pkgRootB 'SHA256SUMS.txt'))
        legacyGateWronglyReportsCompliant=(Test-KICompleteDesktopControlCompliant -TargetRoot $targetB -ExpectedComponentVersion '0.1.0')
        payloadParityDetectsDrift=(-not (Test-KICompleteDesktopControlPayloadParity -PackageRoot $pkg -DeployedPackageRoot $pkgRootB))
        gateWithInstallerPackageRootReportsNoncompliant=(-not (Test-KICompleteDesktopControlCompliant -TargetRoot $targetB -ExpectedComponentVersion '0.1.0' -InstallerPackageRoot $pkg))
    }
    if($checks.internallyConsistentOldDeploymentNotSkipped.Values-contains$false){$fail.Add('internallyConsistentOldDeploymentNotSkipped: '+($checks.internallyConsistentOldDeploymentNotSkipped|ConvertTo-Json -Compress))}

    # --- Scenario C+D: reconcile through the isolated entry point, then NoOp -------------------
    $reconcile1=& $entry -Action Upgrade -TargetRoot $targetB|ConvertFrom-Json
    $gateAfterReconcile=Test-KICompleteDesktopControlCompliant -TargetRoot $targetB -ExpectedComponentVersion '0.1.0' -InstallerPackageRoot $pkg
    $reconcile2=& $entry -Action Upgrade -TargetRoot $targetB|ConvertFrom-Json
    $checks.reconcileRestoresPayloadThenNoOp=[ordered]@{
        firstReconcileMutates=([string]$reconcile1.status -in @('Upgraded','Repaired','Installed') -and [bool]$reconcile1.mutatesTarget)
        parityRestored=([bool](Test-KICompleteDesktopControlPayloadParity -PackageRoot $pkg -DeployedPackageRoot $pkgRootB))
        gateCompliantAfterReconcile=[bool]$gateAfterReconcile
        secondReconcileIsNoOp=([string]$reconcile2.status -eq 'SkippedAlreadyCompliant' -and -not [bool]$reconcile2.mutatesTarget)
    }
    if($checks.reconcileRestoresPayloadThenNoOp.Values-contains$false){$fail.Add('reconcileRestoresPayloadThenNoOp: '+($checks.reconcileRestoresPayloadThenNoOp|ConvertTo-Json -Compress))}

    # --- Scenario E: missing / extra target file also fail the gate ---------------------------
    $targetE=Join-Path $scratch 'target-E'
    $null=& $entry -Action Install -TargetRoot $targetE|Out-Null
    $pkgRootE=(Get-KIDesktopControlInstallPaths -TargetRoot $targetE).packageRoot
    Remove-Item -LiteralPath (Join-Path $pkgRootE 'README.md') -Force
    $missingFails=-not (Test-KICompleteDesktopControlCompliant -TargetRoot $targetE -ExpectedComponentVersion '0.1.0' -InstallerPackageRoot $pkg)
    $null=& $entry -Action Repair -TargetRoot $targetE|Out-Null
    Set-Content -LiteralPath (Join-Path $pkgRootE 'rogue-extra.txt') -Value 'x' -Encoding ascii -NoNewline
    $extraFails=-not (Test-KICompleteDesktopControlCompliant -TargetRoot $targetE -ExpectedComponentVersion '0.1.0' -InstallerPackageRoot $pkg)
    $checks.missingOrExtraTargetFileFailsGate=[ordered]@{
        missingFileNoncompliant=$missingFails
        extraFileNoncompliant=$extraFails
    }
    if($checks.missingOrExtraTargetFileFailsGate.Values-contains$false){$fail.Add('missingOrExtraTargetFileFailsGate: '+($checks.missingOrExtraTargetFileFailsGate|ConvertTo-Json -Compress))}

    # --- Scenario F: both orchestrator call sites feed the installer package root in -----------
    $orchestrator=Get-Content -LiteralPath (Join-Path $PackageRoot 'CompleteInstaller.psm1') -Raw
    $checks.orchestratorPassesInstallerPackageRoot=[ordered]@{
        planningGateWired=$orchestrator.Contains("if([string]`$component.id-eq'desktop-control'-and`$null-eq`$FixtureState){`$compliant=`$compliant-and(Test-KICompleteDesktopControlCompliant -TargetRoot `$TargetRoot -ExpectedComponentVersion ([string]`$component.version) -InstallerPackageRoot `$PackageRoot)}")
        skipRecheckWired=$orchestrator.Contains("if([string]`$step.id-eq'desktop-control'){`$resumeCompliant=`$resumeCompliant-and(Test-KICompleteDesktopControlCompliant -TargetRoot `$TargetRoot -ExpectedComponentVersion ([string]`$step.version) -InstallerPackageRoot `$PackageRoot)}")
        helperDefined=$orchestrator.Contains('function Test-KICompleteDesktopControlPayloadParity')
        parityNotAgainstWorkingTree=($orchestrator.Contains('Expand-KICompletePayload -PackageRoot $PackageRoot -PayloadName ''DesktopControl''') -and -not ($orchestrator -match "DesktopControlPayloadParity[\s\S]{0,400}git"))
    }
    if($checks.orchestratorPassesInstallerPackageRoot.Values-contains$false){$fail.Add('orchestratorPassesInstallerPackageRoot: '+($checks.orchestratorPassesInstallerPackageRoot|ConvertTo-Json -Compress))}

    $passed=$fail.Count-eq0
    [pscustomobject]@{passed=$passed;checks=$checks;failures=@($fail)}|ConvertTo-Json -Depth 10
    if(-not$passed){throw 'Desktop-Control-Reconcile-Regression fehlgeschlagen.'}
}
finally{
    try{Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue}catch{}
}
