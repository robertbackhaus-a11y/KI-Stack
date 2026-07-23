[CmdletBinding()]
param([string]$ImporterPath=(Join-Path (Split-Path -Parent $PSScriptRoot) 'Import-KIStackExternalModels.ps1'))
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=Join-Path ([IO.Path]::GetTempPath()) ('KIStack-ModelImport-Fixture-'+[guid]::NewGuid().ToString('N'))
function Invoke-FixtureImport {
    param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$Target,[Parameter(Mandatory)][string]$LmStudioTarget,[Parameter(Mandatory)][string]$State,[string]$TransactionId,[switch]$Resume,[switch]$Rollback,[switch]$Audit)
    $args=@('-NoLogo','-NoProfile','-File',$ImporterPath,'-SourcePath',$Source,'-TargetRoot',$Target,'-LmStudioTargetRoot',$LmStudioTarget,'-StateRoot',$State,'-ManifestPath',(Join-Path $root 'manifest.json'),'-DisableNetwork')
    if($TransactionId){$args+=@('-TransactionId',$TransactionId)}
    if($Resume){$args+='-Resume'};if($Rollback){$args+='-Rollback'};if($Audit){$args+='-Audit'}
    $text=(& (Get-Command pwsh.exe).Source @args 2>&1)-join"`n";$exitCode=$LASTEXITCODE
    [pscustomobject]@{exitCode=$exitCode;result=($text|ConvertFrom-Json -Depth 30)}
}
function Write-FixtureSource {param([string]$Path,[hashtable]$Bytes,[string]$Omit,[string]$Wrong)
    New-Item -ItemType Directory -Path $Path,(Join-Path $Path 'LMStudio') -Force|Out-Null
    foreach($name in $Bytes.Keys){if($name-eq$Omit){continue};$destination=if($name-like'lm-*'){Join-Path $Path ('LMStudio\'+$name)}else{Join-Path $Path $name};$data=if($name-eq$Wrong){[byte[]]@(1,2,3,4)}else{$Bytes[$name]};[IO.File]::WriteAllBytes($destination,$data)}
}
try{
    New-Item -ItemType Directory -Path $root|Out-Null
    $definitions=@(@('m1.bin','diffusion_models','krea-realism'),@('m2.bin','text_encoders','krea-realism'),@('m3.bin','text_encoders','krea-realism'),@('m4.bin','vae','krea-realism'),@('m5.bin','checkpoints','pony-sdxl'),@('m6.bin','text_encoders','wan22-5b'),@('m7.bin','diffusion_models','wan22-5b'),@('m8.bin','vae','wan22-5b'))
    $models=@();$bytes=@{}
    for($i=0;$i-lt$definitions.Count;$i++){$data=[byte[]]@((10+$i),(20+$i),(30+$i),(40+$i));$bytes[$definitions[$i][0]]=$data;$models+=[ordered]@{id="fixture-$i";profile=$definitions[$i][2];fileName=$definitions[$i][0];sizeBytes=$data.Length;sha256=([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($data))).ToLowerInvariant();targetDirectory=$definitions[$i][1];source=if($i-eq4){'https://civitai.com/api/download/models/290640'}else{$null};manualExternal=($i-ne4)}}
    foreach($name in 'lm-heretic.gguf','lm-mmproj.gguf'){$count=[int]$bytes.Count;$data=[byte[]]@((50+$count),(60+$count),(70+$count),(80+$count));$bytes[$name]=$data}
    $lmFiles=@('lm-heretic.gguf','lm-mmproj.gguf'|ForEach-Object{[ordered]@{id=('lm-'+$_);fileName=$_;sizeBytes=$bytes[$_].Length;sha256=([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes[$_]))).ToLowerInvariant()}})
    [ordered]@{schemaVersion='fixture';models=$models;lmStudioModel=[ordered]@{id='heretic';relativeTargetDirectory='fixture/heretic';files=$lmFiles}}|ConvertTo-Json -Depth 20|Set-Content (Join-Path $root 'manifest.json') -Encoding UTF8
    $source=Join-Path $root 'source';$target=Join-Path $root 'target';$lmTarget=Join-Path $root 'lmstudio';$state=Join-Path $root 'state';Write-FixtureSource $source $bytes
    New-Item -ItemType Directory -Path $target,$lmTarget,$state|Out-Null
    $preexisting=Join-Path $target 'diffusion_models\m1.bin';New-Item -ItemType Directory -Path (Split-Path $preexisting -Parent)|Out-Null;[IO.File]::WriteAllBytes($preexisting,$bytes['m1.bin'])
    $correct=Invoke-FixtureImport $source $target $lmTarget $state;$correctHash=(Get-FileHash $preexisting -Algorithm SHA256).Hash
    $audit=Invoke-FixtureImport $source $target $lmTarget $state -Audit
    $rollback=Invoke-FixtureImport $source $target $lmTarget $state -TransactionId $correct.result.transactionId -Rollback
    $preexistingPreserved=((Get-FileHash $preexisting -Algorithm SHA256).Hash-eq$correctHash);$importedRemoved=(-not(Test-Path (Join-Path $lmTarget 'fixture\heretic\lm-heretic.gguf')))
    $missingSource=Join-Path $root 'missing-source';$missingTarget=Join-Path $root 'missing-target';$missingLmTarget=Join-Path $root 'missing-lmstudio';$missingState=Join-Path $root 'missing-state';Write-FixtureSource $missingSource $bytes 'lm-mmproj.gguf';New-Item -ItemType Directory -Path $missingTarget,$missingLmTarget,$missingState|Out-Null
    $missing=Invoke-FixtureImport $missingSource $missingTarget $missingLmTarget $missingState;[IO.File]::WriteAllBytes((Join-Path $missingSource 'LMStudio\lm-mmproj.gguf'),$bytes['lm-mmproj.gguf']);$resume=Invoke-FixtureImport $missingSource $missingTarget $missingLmTarget $missingState -TransactionId $missing.result.transactionId -Resume
    $wrongSource=Join-Path $root 'wrong-source';$wrongTarget=Join-Path $root 'wrong-target';$wrongLmTarget=Join-Path $root 'wrong-lmstudio';$wrongState=Join-Path $root 'wrong-state';Write-FixtureSource $wrongSource $bytes $null 'lm-heretic.gguf';New-Item -ItemType Directory -Path $wrongTarget,$wrongLmTarget,$wrongState|Out-Null
    $wrong=Invoke-FixtureImport $wrongSource $wrongTarget $wrongLmTarget $wrongState
    $passed=($correct.exitCode-eq0-and$correct.result.status-eq'Completed'-and$audit.result.status-eq'AlreadyCompliant'-and$missing.exitCode-eq20-and$missing.result.status-eq'WaitingForUserAction'-and$wrong.exitCode-eq20-and$wrong.result.requirements[0].reason-eq'InvalidSource'-and$resume.exitCode-eq0-and$resume.result.status-eq'Completed'-and$rollback.exitCode-eq0-and$preexistingPreserved-and$importedRemoved)
    [pscustomobject]@{passed=$passed;correct=$correct.result.status;missing=$missing.result.status;wrongHash=$wrong.result.requirements[0].reason;resume=$resume.result.status;rollback=$rollback.result.status;preexistingPreserved=$preexistingPreserved;transactionFilesRemoved=$importedRemoved}|ConvertTo-Json -Depth 10
    if(-not$passed){exit 1}
}finally{if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}}
