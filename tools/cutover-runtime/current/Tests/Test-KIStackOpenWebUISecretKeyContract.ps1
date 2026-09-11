[CmdletBinding()]
param([string]$ProjectRoot=(Split-Path -Parent $PSScriptRoot))

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$failures=[Collections.Generic.List[string]]::new()

Import-Module (Join-Path $ProjectRoot 'Modules/06-Applications/KIModuleApplications.psm1') -Force -DisableNameChecking

function New-KISecretKeyFixtureRoot {
    $root=Join-Path ([IO.Path]::GetTempPath()) ('KIStack-SecretKeyFixture-'+[guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Path $root -Force|Out-Null
    $root
}

# A real, reproduced defect: open-webui==0.11.3's own `serve` entrypoint
# (open_webui/__init__.py) falls back to `Path.cwd() / '.webui_secret_key'`
# whenever WEBUI_SECRET_KEY is not already set as an environment variable, and
# nothing in the KI-Stack starter chain ever changed directory -- so an
# elevated shell opened the usual Windows way (CWD=C:\Windows\System32) made
# Open WebUI try, and without admin rights fail, to write its persistent
# secret key there. This suite proves: (B) first start generates and persists
# a key, (C) a repeat start reuses it unchanged, (E) a legitimate pre-existing
# key (from the Desktop shortcut's WorkingDirectory=$TargetRoot convention) is
# migrated and reused rather than replaced, and (A+D) the actually generated
# starter script -- executed for real, launched with CWD=System32 -- resolves
# WEBUI_SECRET_KEY from the persistent, TargetRoot-scoped file regardless of
# caller CWD, never attempts to write under System32, and never prints the
# secret value to stdout/stderr.

# --- B: First start -- key is generated once and persisted ------------------
$rootB=New-KISecretKeyFixtureRoot
try{
    $resultB=Install-KIOpenWebUISecretKey -TargetRoot $rootB
    if(-not [bool]$resultB.created){$failures.Add('Szenario B (First Start): created wurde nicht als true gemeldet.')}
    if($null -ne $resultB.migratedFrom){$failures.Add('Szenario B (First Start): migratedFrom war fälschlich gesetzt (kein Legacy-Key vorhanden).')}
    $expectedPath=Join-Path $rootB 'state\openwebui\.webui_secret_key'
    if(([string]$resultB.path).Replace('/','\') -ne $expectedPath){$failures.Add("Szenario B (First Start): erwarteter Pfad $expectedPath, erhalten $($resultB.path).")}
    if(-not(Test-Path -LiteralPath $resultB.path -PathType Leaf)){$failures.Add('Szenario B (First Start): Key-Datei wurde nicht angelegt.')}
    $keyContentB=(Get-Content -LiteralPath $resultB.path -Raw)
    if([string]::IsNullOrWhiteSpace($keyContentB)){$failures.Add('Szenario B (First Start): Key-Datei ist leer.')}
    if($keyContentB.Length -lt 40){$failures.Add("Szenario B (First Start): Key wirkt zu kurz/nicht kryptographisch zufällig (Länge $($keyContentB.Length)).")}
    $bytesB=[Text.Encoding]::UTF8.GetBytes($rootB)
}finally{
    if(Test-Path -LiteralPath $rootB){Remove-Item -LiteralPath $rootB -Recurse -Force -ErrorAction SilentlyContinue}
}

# --- C: Repeat start -- identical key is reused, never regenerated ----------
$rootC=New-KISecretKeyFixtureRoot
try{
    $resultC1=Install-KIOpenWebUISecretKey -TargetRoot $rootC
    $keyC1=(Get-Content -LiteralPath $resultC1.path -Raw)
    $resultC2=Install-KIOpenWebUISecretKey -TargetRoot $rootC
    $keyC2=(Get-Content -LiteralPath $resultC2.path -Raw)
    if([bool]$resultC2.created){$failures.Add('Szenario C (Repeat Start): created wurde beim zweiten Aufruf fälschlich als true gemeldet.')}
    if($keyC1 -ne $keyC2){$failures.Add('Szenario C (Repeat Start): Key wurde beim zweiten Start neu erzeugt statt wiederverwendet.')}
    # A third call after simulating a later Repair/Upgrade run must still be stable.
    $resultC3=Install-KIOpenWebUISecretKey -TargetRoot $rootC
    if((Get-Content -LiteralPath $resultC3.path -Raw) -ne $keyC1){$failures.Add('Szenario C (Repeat Start): Key ist über einen dritten Aufruf hinweg nicht stabil.')}
}finally{
    if(Test-Path -LiteralPath $rootC){Remove-Item -LiteralPath $rootC -Recurse -Force -ErrorAction SilentlyContinue}
}

# --- E: Existing legitimate key (Desktop-shortcut CWD=$TargetRoot legacy) ---
# is migrated and reused, never replaced with a fresh random one. ------------
$rootE=New-KISecretKeyFixtureRoot
try{
    $legacyPathE=Join-Path $rootE '.webui_secret_key'
    [IO.File]::WriteAllText($legacyPathE,'legacy-secret-abcdefghijklmnop',[Text.UTF8Encoding]::new($false))
    $resultE=Install-KIOpenWebUISecretKey -TargetRoot $rootE
    if(-not [bool]$resultE.created){$failures.Add('Szenario E (Existing Key/Migration): created wurde nicht als true gemeldet (Migration ist eine Erstanlage am neuen Pfad).')}
    if(([string]$resultE.migratedFrom).Replace('/','\') -ne $legacyPathE){$failures.Add("Szenario E (Existing Key/Migration): migratedFrom erwartet $legacyPathE, erhalten $($resultE.migratedFrom).")}
    $migratedContentE=(Get-Content -LiteralPath $resultE.path -Raw)
    if($migratedContentE -ne 'legacy-secret-abcdefghijklmnop'){$failures.Add("Szenario E (Existing Key/Migration): Inhalt wurde nicht unverändert übernommen, erhalten '$migratedContentE'.")}
    if(-not(Test-Path -LiteralPath $legacyPathE -PathType Leaf)){$failures.Add('Szenario E (Existing Key/Migration): der alte, legitime Key wurde entfernt statt nur übernommen zu werden.')}
    # A later call must keep reusing the migrated key, not the legacy file again.
    $resultE2=Install-KIOpenWebUISecretKey -TargetRoot $rootE
    if([bool]$resultE2.created){$failures.Add('Szenario E (Existing Key/Migration): ein Folgeaufruf hat den migrierten Key fälschlich neu angelegt.')}
}finally{
    if(Test-Path -LiteralPath $rootE){Remove-Item -LiteralPath $rootE -Recurse -Force -ErrorAction SilentlyContinue}
}

# --- A+D: real generated starter, executed with CWD=System32 ---------------
$rootA=New-KISecretKeyFixtureRoot
$system32=Join-Path $env:SystemRoot 'System32'
$system32KeyPath=Join-Path $system32 '.webui_secret_key'
$system32KeyExistedBefore=Test-Path -LiteralPath $system32KeyPath -PathType Leaf
$system32KeyStampBefore=if($system32KeyExistedBefore){(Get-Item -LiteralPath $system32KeyPath).LastWriteTimeUtc}else{$null}
try{
    $secretResultA=Install-KIOpenWebUISecretKey -TargetRoot $rootA
    $expectedSecretA=(Get-Content -LiteralPath $secretResultA.path -Raw)

    $fakePythonA=Join-Path $rootA 'fake-python.cmd'
    Set-Content -LiteralPath $fakePythonA -Encoding ascii -Value @(
        '@echo off'
        '(echo SECRET=%WEBUI_SECRET_KEY%'
        ' echo CWD=%CD%) > "%KI_TEST_RESULT_FILE%"'
        'exit /b 0'
    )
    $dataRootA=Join-Path $rootA 'OpenWebUI\data'
    $starterContentA=Get-KIOpenWebUIStarterScriptContent -DataRoot $dataRootA -OpenAIBaseUrl 'http://127.0.0.1:1234/v1' -OpenAIKey 'lm-studio' -VenvPython $fakePythonA -BindAddress '127.0.0.1' -Port '8080' -TargetRoot $rootA -SecretKeyFilePath $secretResultA.path
    if(-not $starterContentA.Contains('cd /d "'+$rootA+'"')){$failures.Add('Szenario A (System32-Start): generierter Starter setzt kein explizites, stabiles Arbeitsverzeichnis.')}
    if(-not $starterContentA.Contains('set /p WEBUI_SECRET_KEY=<"'+$secretResultA.path.Replace('/','\')+'"')){$failures.Add('Szenario A (System32-Start): generierter Starter liest WEBUI_SECRET_KEY nicht aus dem persistenten Pfad.')}

    $starterPathA=Join-Path $rootA 'Start-KIStack-OpenWebUI.cmd'
    Set-Content -LiteralPath $starterPathA -Encoding ascii -Value $starterContentA

    $resultFileA=Join-Path $rootA 'result.txt'
    $stdoutA=Join-Path $rootA 'stdout.txt'
    $stderrA=Join-Path $rootA 'stderr.txt'
    $emptyStdinA=Join-Path $rootA 'empty-stdin.txt'
    New-Item -ItemType File -Path $emptyStdinA -Force|Out-Null
    $previousResultFileEnv=$env:KI_TEST_RESULT_FILE
    $env:KI_TEST_RESULT_FILE=$resultFileA
    try{
        $procA=Start-Process -FilePath 'cmd.exe' -ArgumentList @('/D','/C','call',"`"$starterPathA`"") -WorkingDirectory $system32 -RedirectStandardInput $emptyStdinA -RedirectStandardOutput $stdoutA -RedirectStandardError $stderrA -Wait -PassThru -NoNewWindow
    }finally{
        if($previousResultFileEnv){$env:KI_TEST_RESULT_FILE=$previousResultFileEnv}else{Remove-Item Env:\KI_TEST_RESULT_FILE -ErrorAction SilentlyContinue}
    }
    if($procA.ExitCode -ne 0){$failures.Add("Szenario A (System32-Start): erwarteter Exitcode 0, erhalten $($procA.ExitCode).")}
    if(-not(Test-Path -LiteralPath $resultFileA -PathType Leaf)){$failures.Add('Szenario A (System32-Start): Fake-Python wurde nicht erreicht (Ergebnisdatei fehlt) -- Starter ist vorzeitig abgebrochen.')}
    else{
        $resultLinesA=Get-Content -LiteralPath $resultFileA
        $secretLineA=@($resultLinesA|Where-Object{$_ -like 'SECRET=*'})|Select-Object -First 1
        $cwdLineA=@($resultLinesA|Where-Object{$_ -like 'CWD=*'})|Select-Object -First 1
        $observedSecretA=if($secretLineA){$secretLineA.Substring(7)}else{''}
        $observedCwdA=if($cwdLineA){$cwdLineA.Substring(4)}else{''}
        if($observedSecretA -ne $expectedSecretA){$failures.Add('Szenario A (System32-Start): WEBUI_SECRET_KEY im Kindprozess weicht vom persistenten Key ab -- CWD-Abhaengigkeit besteht weiterhin.')}
        if($observedCwdA.TrimEnd('\') -ne $rootA.TrimEnd('\')){$failures.Add("Szenario A (System32-Start): Arbeitsverzeichnis beim Python-Aufruf war '$observedCwdA', erwartet '$rootA' -- cd /d greift nicht.")}
    }
    if(Test-Path -LiteralPath $system32KeyPath -PathType Leaf){
        $system32KeyStampAfter=(Get-Item -LiteralPath $system32KeyPath).LastWriteTimeUtc
        if(-not $system32KeyExistedBefore){$failures.Add('Szenario A (System32-Start): unter System32 wurde eine neue .webui_secret_key-Datei angelegt.')}
        elseif($system32KeyStampAfter -ne $system32KeyStampBefore){$failures.Add('Szenario A (System32-Start): eine bereits vorhandene Datei unter System32 wurde durch den Testlauf veraendert.')}
    }elseif($system32KeyExistedBefore){
        $failures.Add('Szenario A (System32-Start): eine vor dem Testlauf vorhandene Datei unter System32 ist verschwunden.')
    }
    # D: no secret leakage into stdout/stderr of the whole process tree.
    $stdoutRawA=Get-Content -LiteralPath $stdoutA -Raw -ErrorAction SilentlyContinue
    $stderrRawA=Get-Content -LiteralPath $stderrA -Raw -ErrorAction SilentlyContinue
    $stdoutTextA=if($null -eq $stdoutRawA){''}else{$stdoutRawA}
    $stderrTextA=if($null -eq $stderrRawA){''}else{$stderrRawA}
    if($expectedSecretA -and ($stdoutTextA.Contains($expectedSecretA) -or $stderrTextA.Contains($expectedSecretA))){$failures.Add('Szenario D (No Secret Leakage): der Secret-Key-Wert erschien in stdout/stderr des Starters.')}
}finally{
    if(Test-Path -LiteralPath $rootA){Remove-Item -LiteralPath $rootA -Recurse -Force -ErrorAction SilentlyContinue}
}

# --- Static contract: no unguarded WEBUI_SECRET_KEY echo, migration comment present ---
$modulePath=Join-Path $ProjectRoot 'Modules/06-Applications/KIModuleApplications.psm1'
$moduleText=[IO.File]::ReadAllText($modulePath)
foreach($marker in @('function Get-KIOpenWebUISecretKeyPath','function Install-KIOpenWebUISecretKey','function Get-KIOpenWebUIStarterScriptContent','set /p WEBUI_SECRET_KEY=<"__SECRET_KEY_FILE__"','cd /d "__TARGET_ROOT__"')){
    if(-not $moduleText.Contains($marker)){$failures.Add("Statischer Vertrag fehlt: $marker")}
}
if($moduleText -match 'echo\s+.*%WEBUI_SECRET_KEY%'){$failures.Add('Statischer Vertrag: eine Zeile scheint WEBUI_SECRET_KEY per echo auszugeben (Leak-Risiko).')}

$result=[pscustomobject]@{passed=($failures.Count-eq0);checks=17;failures=@($failures)}
$result|ConvertTo-Json -Depth 10
if(-not $result.passed){exit 1}
