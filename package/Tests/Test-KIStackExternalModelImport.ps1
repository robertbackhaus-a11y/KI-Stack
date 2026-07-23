[CmdletBinding()]
param([string]$ImporterPath=(Join-Path (Split-Path -Parent $PSScriptRoot) 'Import-KIStackExternalModels.ps1'))
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=Join-Path ([IO.Path]::GetTempPath()) ('KIStack-ModelImport-Fixture-'+[guid]::NewGuid().ToString('N'))
function Invoke-FixtureImport {
    param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$Target,[Parameter(Mandatory)][string]$State,[string]$TransactionId,[switch]$Resume,[switch]$Rollback,[switch]$Audit)
    $args=@('-NoLogo','-NoProfile','-File',$ImporterPath,'-SourcePath',$Source,'-TargetRoot',$Target,'-StateRoot',$State,'-ManifestPath',(Join-Path $root 'manifest.json'),'-DisableNetwork')
    if($TransactionId){$args+=@('-TransactionId',$TransactionId)}
    if($Resume){$args+='-Resume'};if($Rollback){$args+='-Rollback'};if($Audit){$args+='-Audit'}
    $text=(& (Get-Command pwsh.exe).Source @args 2>&1)-join"`n";$exitCode=$LASTEXITCODE
    [pscustomobject]@{exitCode=$exitCode;result=($text|ConvertFrom-Json -Depth 30)}
}
try{
    New-Item -ItemType Directory -Path $root|Out-Null
    $definitions=@(
        @('m1.bin','diffusion_models','krea-realism'),@('m2.bin','text_encoders','krea-realism'),
        @('m3.bin','text_encoders','krea-realism'),@('m4.bin','vae','krea-realism'),
        @('m5.bin','checkpoints','pony-sdxl'),@('m6.bin','text_encoders','wan22-5b'),
        @('m7.bin','diffusion_models','wan22-5b'),@('m8.bin','vae','wan22-5b')
    )
    $models=@();$bytes=@{}
    for($i=0;$i-lt$definitions.Count;$i++){
        $data=[byte[]]@((10+$i),(20+$i),(30+$i),(40+$i));$bytes[$definitions[$i][0]]=$data
        $hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($data)).ToLowerInvariant()
        $models+=[ordered]@{id="fixture-$i";profile=$definitions[$i][2];fileName=$definitions[$i][0];sizeBytes=$data.Length;sha256=$hash;targetDirectory=$definitions[$i][1];source=if($i-eq4){'https://civitai.com/api/download/models/290640'}else{$null};manualExternal=($i-ne4)}
    }
    [ordered]@{schemaVersion='fixture';models=$models}|ConvertTo-Json -Depth 20|Set-Content (Join-Path $root 'manifest.json') -Encoding UTF8
    $source=Join-Path $root 'source';$target=Join-Path $root 'target';$state=Join-Path $root 'state'
    New-Item -ItemType Directory -Path $source,$target,$state|Out-Null
    foreach($name in $bytes.Keys){[IO.File]::WriteAllBytes((Join-Path $source $name),$bytes[$name])}
    $preexisting=Join-Path $target 'diffusion_models\m1.bin';New-Item -ItemType Directory -Path (Split-Path $preexisting -Parent)|Out-Null;[IO.File]::WriteAllBytes($preexisting,$bytes['m1.bin'])
    $correct=Invoke-FixtureImport -Source $source -Target $target -State $state
    $correctHash=(Get-FileHash $preexisting -Algorithm SHA256).Hash
    $audit=Invoke-FixtureImport -Source $source -Target $target -State $state -Audit
    $rollback=Invoke-FixtureImport -Source $source -Target $target -State $state -TransactionId $correct.result.transactionId -Rollback
    $preexistingPreserved=((Get-FileHash $preexisting -Algorithm SHA256).Hash-eq$correctHash)
    $importedRemoved=-not(Test-Path (Join-Path $target 'vae\m8.bin'))

    $missingSource=Join-Path $root 'missing-source';$missingTarget=Join-Path $root 'missing-target';$missingState=Join-Path $root 'missing-state'
    New-Item -ItemType Directory -Path $missingSource,$missingTarget,$missingState|Out-Null
    foreach($name in $bytes.Keys|Where-Object{$_-ne'm8.bin'}){[IO.File]::WriteAllBytes((Join-Path $missingSource $name),$bytes[$name])}
    $missing=Invoke-FixtureImport -Source $missingSource -Target $missingTarget -State $missingState
    [IO.File]::WriteAllBytes((Join-Path $missingSource 'm8.bin'),$bytes['m8.bin'])
    $resume=Invoke-FixtureImport -Source $missingSource -Target $missingTarget -State $missingState -TransactionId $missing.result.transactionId -Resume

    $wrongSource=Join-Path $root 'wrong-source';$wrongTarget=Join-Path $root 'wrong-target';$wrongState=Join-Path $root 'wrong-state'
    New-Item -ItemType Directory -Path $wrongSource,$wrongTarget,$wrongState|Out-Null
    foreach($name in $bytes.Keys){[IO.File]::WriteAllBytes((Join-Path $wrongSource $name),$bytes[$name])}
    [IO.File]::WriteAllBytes((Join-Path $wrongSource 'm4.bin'),[byte[]]@(1,2,3,4))
    $wrong=Invoke-FixtureImport -Source $wrongSource -Target $wrongTarget -State $wrongState
    $passed=($correct.exitCode-eq0-and$correct.result.status-eq'Completed'-and$audit.result.status-eq'AlreadyCompliant'-and$missing.exitCode-eq20-and$missing.result.status-eq'WaitingForUserAction'-and$wrong.exitCode-eq20-and$wrong.result.requirements[0].reason-eq'InvalidSource'-and$resume.exitCode-eq0-and$resume.result.status-eq'Completed'-and$rollback.exitCode-eq0-and$preexistingPreserved-and$importedRemoved)
    [pscustomobject]@{passed=$passed;correct=$correct.result.status;missing=$missing.result.status;wrongHash=$wrong.result.requirements[0].reason;resume=$resume.result.status;rollback=$rollback.result.status;preexistingPreserved=$preexistingPreserved;transactionFilesRemoved=$importedRemoved}|ConvertTo-Json -Depth 10
    if(-not$passed){exit 1}
}finally{
    if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}
}
