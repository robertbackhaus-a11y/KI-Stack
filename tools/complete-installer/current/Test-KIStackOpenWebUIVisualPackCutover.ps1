[CmdletBinding()]
param([string]$PackageRoot=$PSScriptRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$temp=Join-Path ([IO.Path]::GetTempPath()) ('KIStack-VisualCutover-'+[guid]::NewGuid().ToString('N'))
try{
    New-Item -ItemType Directory -Path $temp -Force|Out-Null
    Copy-Item -LiteralPath (Join-Path $PackageRoot 'CompleteInstaller.psm1') -Destination $temp
    $source=Get-Content -LiteralPath (Join-Path $PackageRoot 'Start-KIStackCompleteInstaller.ps1') -Raw
    $source=$source.Replace('if(-not(Test-KICompleteAdministrator)){','if($false){')
    $source=$source.Replace('$plan=New-KICompletePlan -Mode Upgrade -PackageRoot $PSScriptRoot -TargetRoot ''C:\KI-Stack'' -ReplayComponent $ReplayComponent','$plan=[pscustomobject]@{steps=@([pscustomobject]@{id=''openwebui-visual-pack'';plannedMode=''Upgrade''})}')
    $source=$source.Replace('try{Start-Process ''http://127.0.0.1:8080''}catch{Write-Host "OpenWebUI konnte nicht automatisch im Browser geoeffnet werden: $($_.Exception.Message)" -ForegroundColor Yellow}','Write-Host ''FIXTURE:BROWSER-OPENED''')
    $source=$source.Replace('Read-Host ''Enter druecken, sobald der API-Key erzeugt wurde und bereitsteht''','''FIXTURE-CONFIRM-READY''')
    $source=$source.Replace('Read-Host ''Enter druecken, sobald beide Tests erfolgreich abgeschlossen wurden''','''FIXTURE-CONFIRM-TESTS-DONE''')
    $source=$source.Replace('$result=Invoke-KIStackCompleteInstaller -Mode Upgrade -PackageRoot $PSScriptRoot -TargetRoot ''C:\KI-Stack'' -TransactionId $TransactionId -Resume:$Resume -OpenWebUIApiToken $apiToken -ReplayComponent $ReplayComponent','$result=if($null-eq$apiToken){[pscustomobject]@{status=''WaitingForUserAction'';transactionId=''TEST-NOAPIKEY'';steps=@()}}else{[pscustomobject]@{status=''Completed'';transactionId=''TEST-VISUAL'';steps=@([pscustomobject]@{id=''openwebui-visual-pack'';status=''Completed''})}}')

    $owuiLine="`$config=Invoke-WebRequest -Uri 'http://127.0.0.1:8080/api/config' -UseBasicParsing -TimeoutSec 5"
    $comfyLine="`$comfy=Invoke-WebRequest -Uri 'http://127.0.0.1:8188/system_stats' -UseBasicParsing -TimeoutSec 5"
    $apiTokenPromptLine="`$enteredApiToken=Read-Host 'Temporären OpenWebUI-Administrator-API-Key eingeben' -AsSecureString"

    # Scenario 1: OpenWebUI and ComfyUI both reachable, but no API key entered -> clean WaitingForUserAction (the only legitimate use of that status).
    $noApiKeySource=$source.Replace($owuiLine,'$config=[pscustomobject]@{StatusCode=200}').Replace($comfyLine,'$comfy=[pscustomobject]@{StatusCode=200}').Replace($apiTokenPromptLine,'$enteredApiToken=(New-Object Security.SecureString)')
    $noApiKeyScript=Join-Path $temp 'noapikey.ps1';[IO.File]::WriteAllText($noApiKeyScript,$noApiKeySource,[Text.UTF8Encoding]::new($false))
    $noApiKeyLog=Join-Path $temp 'noapikey.log'; & (Get-Command pwsh.exe).Source -NoLogo -NoProfile -File $noApiKeyScript -Elevated -LogPath $noApiKeyLog *> $null;$noApiKeyCode=$LASTEXITCODE
    $noApiKeyJson=Get-Content -LiteralPath $noApiKeyLog -Raw|ConvertFrom-Json
    $noApiKeyTranscript=Get-Content -LiteralPath ($noApiKeyLog+'.transcript.txt') -Raw

    # Scenario 2: OpenWebUI never becomes reachable within its readiness budget -> genuine error, not WaitingForUserAction. Budget shrunk to 1 attempt/0s for a deterministic, fast test.
    $openWebUIDownSource=$source.Replace('$openWebUIWaitMaxAttempts=15','$openWebUIWaitMaxAttempts=1').Replace('$openWebUIWaitIntervalSeconds=2','$openWebUIWaitIntervalSeconds=0').Replace($owuiLine,"throw 'fixture: OpenWebUI unreachable'")
    $openWebUIDownScript=Join-Path $temp 'openwebuidown.ps1';[IO.File]::WriteAllText($openWebUIDownScript,$openWebUIDownSource,[Text.UTF8Encoding]::new($false))
    $openWebUIDownLog=Join-Path $temp 'openwebuidown.log'; & (Get-Command pwsh.exe).Source -NoLogo -NoProfile -File $openWebUIDownScript -Elevated -LogPath $openWebUIDownLog *> $null;$openWebUIDownCode=$LASTEXITCODE
    $openWebUIDownStderr=Get-Content -LiteralPath ($openWebUIDownLog+'.stderr.txt') -Raw

    # Scenario 3: OpenWebUI reachable but ComfyUI not -> genuine error, not WaitingForUserAction.
    $comfyDownSource=$source.Replace($owuiLine,'$config=[pscustomobject]@{StatusCode=200}').Replace($comfyLine,"throw 'fixture: ComfyUI unreachable'")
    $comfyDownScript=Join-Path $temp 'comfydown.ps1';[IO.File]::WriteAllText($comfyDownScript,$comfyDownSource,[Text.UTF8Encoding]::new($false))
    $comfyDownLog=Join-Path $temp 'comfydown.log'; & (Get-Command pwsh.exe).Source -NoLogo -NoProfile -File $comfyDownScript -Elevated -LogPath $comfyDownLog *> $null;$comfyDownCode=$LASTEXITCODE
    $comfyDownStderr=Get-Content -LiteralPath ($comfyDownLog+'.stderr.txt') -Raw

    # Scenario 4: OpenWebUI and ComfyUI reachable, a real API key is entered -> existing (mocked) Visual-Pack Install/Validate path succeeds.
    $successSource=$source.Replace($owuiLine,'$config=[pscustomobject]@{StatusCode=200}').Replace($comfyLine,'$comfy=[pscustomobject]@{StatusCode=200}').Replace($apiTokenPromptLine,'$enteredApiToken=(ConvertTo-SecureString ''fixture-token'' -AsPlainText -Force)')
    $successScript=Join-Path $temp 'success.ps1';[IO.File]::WriteAllText($successScript,$successSource,[Text.UTF8Encoding]::new($false))
    $successLog=Join-Path $temp 'success.log'; & (Get-Command pwsh.exe).Source -NoLogo -NoProfile -File $successScript -Elevated -LogPath $successLog *> $null;$successCode=$LASTEXITCODE
    $successJson=Get-Content -LiteralPath $successLog -Raw|ConvertFrom-Json
    $successTranscript=Get-Content -LiteralPath ($successLog+'.transcript.txt') -Raw

    $checkNoApiKey=[ordered]@{
        exitCodeZero=$noApiKeyCode-eq0
        statusWaitingForUserAction=[string]$noApiKeyJson.status-eq'WaitingForUserAction'
        guidedFlowWasAttempted=$noApiKeyTranscript.Contains('FIXTURE:BROWSER-OPENED')
        noKeyWarningShown=$noApiKeyTranscript.Contains('Kein API-Key eingegeben')
    }
    $checkOpenWebUIDown=[ordered]@{
        exitCodeNonZero=$openWebUIDownCode-eq1
        realErrorNotWaitingForUserAction=$openWebUIDownStderr.Contains('OpenWebUI ist unter http://127.0.0.1:8080')-and$openWebUIDownStderr.Contains('nicht erreichbar')
    }
    $checkComfyDown=[ordered]@{
        exitCodeNonZero=$comfyDownCode-eq1
        realErrorNotWaitingForUserAction=$comfyDownStderr.Contains('ComfyUI ist unter http://127.0.0.1:8188 nicht erreichbar')
    }
    $checkSuccess=[ordered]@{
        exitCodeZero=$successCode-eq0
        statusCompleted=[string]$successJson.status-eq'Completed'
        browserOpened=$successTranscript.Contains('FIXTURE:BROWSER-OPENED')
        guidanceBannerShown=$successTranscript.Contains('OpenWebUI Visual-Pack-Cutover')
        postInstallTestGateShown=$successTranscript.Contains('abschliessender manueller Funktionstest')
    }

    $passed=(@($checkNoApiKey.Values)-notcontains$false)-and(@($checkOpenWebUIDown.Values)-notcontains$false)-and(@($checkComfyDown.Values)-notcontains$false)-and(@($checkSuccess.Values)-notcontains$false)
    [pscustomobject]@{passed=$passed;version='2.10.1';checks=[ordered]@{noApiKeyPath=$checkNoApiKey;openWebUIUnreachablePath=$checkOpenWebUIDown;comfyUnreachablePath=$checkComfyDown;successPath=$checkSuccess};targetSystemAccessed=$false}|ConvertTo-Json -Depth 10
    if(-not$passed){throw 'OpenWebUI-Visual-Pack-Cutover-Regression fehlgeschlagen.'}
}finally{if(Test-Path $temp){Remove-Item $temp -Recurse -Force}}
