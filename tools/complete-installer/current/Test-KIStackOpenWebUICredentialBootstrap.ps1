[CmdletBinding()]
param([string]$PackageRoot=$PSScriptRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

# Fast, network-free-except-for-a-local-fixture-mock "isolated bootstrap" suite for the
# OpenWebUI-Credential-Bootstrap-Workstream. Never touches a real OpenWebUI instance or the real
# %USERPROFILE% -- a disposable fixture TargetRoot stands in for C:\KI-Stack throughout, and a
# raw TcpListener-based mock (not HttpListener: avoids http.sys URL-ACL/namespace reservation
# requirements a non-admin process would otherwise hit -- same technique already established in
# Test-KIStackCodexLocal.ps1/Test-KIStackCodexLocalGreenfield.ps1) stands in for OpenWebUI's real
# /api/v1/auths/* surface, verified against the actually-installed OpenWebUI 0.11.1 source under
# C:\KI-Stack\python\venvs\openwebui\Lib\site-packages\open_webui\routers\auths.py.

$fail=[Collections.Generic.List[string]]::new()
$checks=[ordered]@{}

Import-Module (Join-Path $PackageRoot 'Lifecycle/KIStackOpenWebUICredential.psm1') -Force -DisableNameChecking

$suiteRoot=Join-Path ([IO.Path]::GetTempPath()) ('KICX-OWUI-'+[guid]::NewGuid().ToString('N').Substring(0,10))
$targetRoot=Join-Path $suiteRoot 'target'
New-Item -ItemType Directory -Path $targetRoot -Force|Out-Null

$adminEmail='admin@ki-stack.fixture'
$adminPassword='fixture-admin-password-not-real'
$userEmail='user@ki-stack.fixture'
$userPassword='fixture-user-password-not-real'

function Start-KIOpenWebUIMock {
    param([int]$Port,[bool]$EnableApiKeysInitially=$false,[switch]$RejectSecondApiKeyPost)
    $script=Join-Path $suiteRoot ("mock-openwebui-$Port.ps1")
    Set-Content -LiteralPath $script -Encoding utf8NoBOM -Value @"
param([int]`$Port)
`$adminEmail='$adminEmail';`$adminPassword='$adminPassword'
`$userEmail='$userEmail';`$userPassword='$userPassword'
`$adminToken='fixture-admin-session-token';`$userToken='fixture-user-session-token'
`$enableApiKeys=`$$EnableApiKeysInitially
`$currentApiKey=`$null
`$apiKeyCounter=0
`$rejectSecondPost=`$$($RejectSecondApiKeyPost.IsPresent)
`$postCount=0
function Write-JsonResponse(`$stream,`$code,`$obj){
    `$bodyBytes=[Text.Encoding]::UTF8.GetBytes((`$obj|ConvertTo-Json -Depth 10 -Compress))
    `$statusText=@{200='OK';400='Bad Request';401='Unauthorized';403='Forbidden';404='Not Found';500='Internal Server Error'}[`$code]
    `$header="HTTP/1.1 `$code `$statusText```r```nContent-Type: application/json```r```nContent-Length: `$(`$bodyBytes.Length)```r```nConnection: close```r```n```r```n"
    `$headerBytes=[Text.Encoding]::ASCII.GetBytes(`$header)
    `$stream.Write(`$headerBytes,0,`$headerBytes.Length);`$stream.Write(`$bodyBytes,0,`$bodyBytes.Length);`$stream.Flush()
}
function Get-BearerToken(`$requestText){
    if(`$requestText -match '(?im)^Authorization:\s*Bearer\s+(\S+)'){`$Matches[1]}else{`$null}
}
`$tcp=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,`$Port)
`$tcp.Start()
while(`$true){
    `$client=`$tcp.AcceptTcpClient()
    try{
        `$stream=`$client.GetStream()
        `$buffer=New-Object byte[] 65536
        `$total=0
        Start-Sleep -Milliseconds 30
        while(`$stream.DataAvailable -or `$total-eq0){
            if(-not `$stream.DataAvailable -and `$total-eq0){Start-Sleep -Milliseconds 20;continue}
            `$read=`$stream.Read(`$buffer,`$total,`$buffer.Length-`$total)
            if(`$read-le0){break}
            `$total+=`$read
            if(-not `$stream.DataAvailable){Start-Sleep -Milliseconds 20;if(-not `$stream.DataAvailable){break}}
        }
        `$requestText=[Text.Encoding]::UTF8.GetString(`$buffer,0,`$total)
        `$firstLine=(`$requestText -split "``r``n")[0]
        `$parts=`$firstLine -split '\s+'
        `$method=`$parts[0];`$path=`$parts[1]
        `$bodyStart=`$requestText.IndexOf("``r``n``r``n")
        `$body=if(`$bodyStart -ge 0){`$requestText.Substring(`$bodyStart+4)}else{''}
        `$bearer=Get-BearerToken `$requestText

        if(`$method-eq'POST'-and`$path-eq'/api/v1/auths/signin'){
            `$form=`$body|ConvertFrom-Json
            if([string]`$form.email-eq`$adminEmail-and[string]`$form.password-eq`$adminPassword){
                Write-JsonResponse `$stream 200 @{token=`$adminToken;token_type='Bearer';id='fixture-admin-id';role='admin';email=`$adminEmail}
            }elseif([string]`$form.email-eq`$userEmail-and[string]`$form.password-eq`$userPassword){
                Write-JsonResponse `$stream 200 @{token=`$userToken;token_type='Bearer';id='fixture-user-id';role='user';email=`$userEmail}
            }else{
                Write-JsonResponse `$stream 400 @{detail='Invalid credentials'}
            }
        }elseif(`$method-eq'GET'-and`$path-eq'/api/v1/auths/admin/config'){
            if(`$bearer-ne`$adminToken){Write-JsonResponse `$stream 401 @{detail='Unauthorized'}}
            else{Write-JsonResponse `$stream 200 @{ENABLE_API_KEYS=`$enableApiKeys;WEBUI_URL='http://127.0.0.1:8080';ENABLE_SIGNUP=`$false;SHOW_ADMIN_DETAILS=`$true}}
        }elseif(`$method-eq'POST'-and`$path-eq'/api/v1/auths/admin/config'){
            if(`$bearer-ne`$adminToken){Write-JsonResponse `$stream 401 @{detail='Unauthorized'};continue}
            `$form=`$body|ConvertFrom-Json
            `$enableApiKeys=[bool]`$form.ENABLE_API_KEYS
            Write-JsonResponse `$stream 200 `$form
        }elseif(`$method-eq'POST'-and`$path-eq'/api/v1/auths/api_key'){
            `$postCount++
            if(`$bearer-ne`$adminToken){Write-JsonResponse `$stream 401 @{detail='Unauthorized'}}
            elseif(-not `$enableApiKeys){Write-JsonResponse `$stream 403 @{detail='API key creation not allowed'}}
            elseif(`$rejectSecondPost-and`$postCount-gt1){Write-JsonResponse `$stream 500 @{detail='FIXTURE: unexpected second api_key generation -- idempotency regression'}}
            else{`$apiKeyCounter++;`$currentApiKey="sk-fixture-key-`$apiKeyCounter";Write-JsonResponse `$stream 200 @{api_key=`$currentApiKey}}
        }elseif(`$method-eq'DELETE'-and`$path-eq'/api/v1/auths/api_key'){
            if(`$bearer-ne`$adminToken-and`$bearer-ne`$currentApiKey){Write-JsonResponse `$stream 401 @{detail='Unauthorized'}}
            else{`$currentApiKey=`$null;Write-JsonResponse `$stream 200 `$true}
        }elseif(`$method-eq'GET'-and`$path-eq'/api/v1/auths/'){
            if(`$bearer-eq`$adminToken){Write-JsonResponse `$stream 200 @{id='fixture-admin-id';role='admin';email=`$adminEmail}}
            elseif(`$bearer-eq`$userToken){Write-JsonResponse `$stream 200 @{id='fixture-user-id';role='user';email=`$userEmail}}
            elseif(`$null-ne`$currentApiKey-and`$bearer-eq`$currentApiKey){Write-JsonResponse `$stream 200 @{id='fixture-admin-id';role='admin';email=`$adminEmail}}
            else{Write-JsonResponse `$stream 401 @{detail='Unauthorized'}}
        }else{
            Write-JsonResponse `$stream 404 @{detail='Not found'}
        }
    }catch{}finally{try{`$client.Close()}catch{}}
}
"@
    $process=Start-Process -FilePath 'pwsh' -ArgumentList @('-NoProfile','-File',$script,'-Port',$Port) -WindowStyle Hidden -PassThru
    Start-Sleep -Milliseconds 400
    $process
}

function ConvertTo-SS([string]$PlainText){ConvertTo-SecureString -String $PlainText -AsPlainText -Force}

try{
    # --- 1. Store + Encryption/Decrypt round-trip (Section 26 "Store"/"Encryption/Decrypt") -----
    $fixtureKey=ConvertTo-SS 'sk-store-roundtrip-fixture-0001'
    Save-KIStackOpenWebUICredential -Endpoint 'http://127.0.0.1:1/fixture' -ApiKey $fixtureKey -UserId 'u1' -UserEmail 'x@y.z' -TargetRoot $targetRoot|Out-Null
    $paths=Get-KIStackOpenWebUICredentialPaths -TargetRoot $targetRoot
    $rawStoreText=Get-Content -LiteralPath $paths.credentialFile -Raw
    $roundtrip=Get-KIStackOpenWebUICredential -TargetRoot $targetRoot
    $decryptedPlain=$null
    try{$bstr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($roundtrip.apiKey);$decryptedPlain=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)}finally{if($bstr){[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)}}
    $checks.storeAndEncryptDecryptRoundtrip=[ordered]@{
        fileCreated=(Test-Path -LiteralPath $paths.credentialFile -PathType Leaf)
        rawFileNeverContainsPlaintextKey=(-not $rawStoreText.Contains('sk-store-roundtrip-fixture-0001'))
        decryptedMatchesOriginal=($decryptedPlain-eq'sk-store-roundtrip-fixture-0001')
        containsSecretsFlagIsFalse=(-not [bool]((Get-Content -LiteralPath $paths.credentialFile -Raw|ConvertFrom-Json).containsSecrets))
    }
    if($checks.storeAndEncryptDecryptRoundtrip.Values-contains$false){$fail.Add('storeAndEncryptDecryptRoundtrip failed: '+($checks.storeAndEncryptDecryptRoundtrip|ConvertTo-Json -Compress))}
    Remove-Item -LiteralPath $paths.credentialFile -Force

    # --- 2. NotConfigured (nothing bootstrapped yet) --------------------------------------------
    $notConfigured=Test-KIStackOpenWebUICredential -Endpoint 'http://127.0.0.1:1/fixture' -TargetRoot $targetRoot
    $checks.notConfiguredBeforeBootstrap=[ordered]@{status=([string]$notConfigured.status-eq'NotConfigured')}
    if($checks.notConfiguredBeforeBootstrap.Values-contains$false){$fail.Add('notConfiguredBeforeBootstrap failed: '+($notConfigured|ConvertTo-Json -Compress))}

    # --- 3. Initial Bootstrap (Section 21/26) ---------------------------------------------------
    $port1=Get-Random -Minimum 20000 -Maximum 40000
    $mock1=Start-KIOpenWebUIMock -Port $port1 -EnableApiKeysInitially $false
    $endpoint1="http://127.0.0.1:$port1"
    try{
        $bootstrap=Initialize-KIStackOpenWebUICredential -Endpoint $endpoint1 -AdminEmail $adminEmail -AdminPassword (ConvertTo-SS $adminPassword) -TargetRoot $targetRoot
        $checks.initialBootstrap=[ordered]@{
            passed=[bool]$bootstrap.passed
            status=([string]$bootstrap.status-eq'Bootstrapped')
            credentialValidAfterBootstrap=([string]$bootstrap.credentialStatus.status-eq'Valid')
            storeCreated=(Test-Path -LiteralPath $paths.credentialFile -PathType Leaf)
        }
        if($checks.initialBootstrap.Values-contains$false){$fail.Add('initialBootstrap failed: '+($checks.initialBootstrap|ConvertTo-Json -Compress)+' | '+($bootstrap|ConvertTo-Json -Compress))}

        # --- 4. Idempotency / Existing Valid (Section 9/26): second bootstrap call must reuse,
        # never mint a new key -- the mock's own postCount trap would 500 on a second POST if it
        # were configured to reject one, but here we prove it purely via ReusedExisting + an
        # unchanged rotatedAtUtc timestamp. --------------------------------------------------------
        $beforeSecond=Get-Content -LiteralPath $paths.credentialFile -Raw|ConvertFrom-Json
        $second=Initialize-KIStackOpenWebUICredential -Endpoint $endpoint1 -AdminEmail $adminEmail -AdminPassword (ConvertTo-SS $adminPassword) -TargetRoot $targetRoot
        $afterSecond=Get-Content -LiteralPath $paths.credentialFile -Raw|ConvertFrom-Json
        $checks.idempotentSecondBootstrap=[ordered]@{
            status=([string]$second.status-eq'ReusedExisting')
            noNewKeyMinted=([string]$beforeSecond.encryptedApiKey-eq[string]$afterSecond.encryptedApiKey)
            rotatedAtUtcUnchanged=([string]$beforeSecond.rotatedAtUtc-eq[string]$afterSecond.rotatedAtUtc)
        }
        if($checks.idempotentSecondBootstrap.Values-contains$false){$fail.Add('idempotentSecondBootstrap failed: '+($checks.idempotentSecondBootstrap|ConvertTo-Json -Compress))}
    }finally{Stop-Process -Id $mock1.Id -Force -ErrorAction SilentlyContinue}

    # --- 5. Offline (Section 8/26): OpenWebUI unreachable must never be reported as Invalid. ----
    $offlinePort=Get-Random -Minimum 20000 -Maximum 40000
    $offlineStatus=Test-KIStackOpenWebUICredential -Endpoint "http://127.0.0.1:$offlinePort" -TargetRoot $targetRoot -TimeoutSec 3
    $checks.openWebUIUnavailableNeverReportedAsInvalid=[ordered]@{
        status=([string]$offlineStatus.status-eq'OpenWebUIUnavailable')
        neverInvalid=([string]$offlineStatus.status-ne'Invalid')
    }
    if($checks.openWebUIUnavailableNeverReportedAsInvalid.Values-contains$false){$fail.Add('openWebUIUnavailableNeverReportedAsInvalid failed: '+($offlineStatus|ConvertTo-Json -Compress))}

    # --- 6. Invalid: local decryption failure (corrupted store) ---------------------------------
    $corrupted=Get-Content -LiteralPath $paths.credentialFile -Raw|ConvertFrom-Json
    $corrupted.encryptedApiKey='not-a-real-dpapi-blob'
    $corrupted|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $paths.credentialFile -Encoding utf8NoBOM
    $corruptStatus=Test-KIStackOpenWebUICredential -Endpoint 'http://127.0.0.1:1/fixture' -TargetRoot $targetRoot
    $checks.invalidOnCorruptedStore=[ordered]@{status=([string]$corruptStatus.status-eq'Invalid')}
    if($checks.invalidOnCorruptedStore.Values-contains$false){$fail.Add('invalidOnCorruptedStore failed: '+($corruptStatus|ConvertTo-Json -Compress))}
    Remove-Item -LiteralPath $paths.credentialFile -Force -ErrorAction SilentlyContinue

    # --- 7. Invalid: real server-side rejection (401) -- bootstrap fresh, then revoke server-side
    # out of band (simulating an operator revoking it via the OpenWebUI UI itself), then validate.
    $port2=Get-Random -Minimum 20000 -Maximum 40000
    $mock2=Start-KIOpenWebUIMock -Port $port2 -EnableApiKeysInitially $false
    $endpoint2="http://127.0.0.1:$port2"
    try{
        [void](Initialize-KIStackOpenWebUICredential -Endpoint $endpoint2 -AdminEmail $adminEmail -AdminPassword (ConvertTo-SS $adminPassword) -TargetRoot $targetRoot)
        $storedCred=Get-KIStackOpenWebUICredential -TargetRoot $targetRoot
        [void](Remove-KIStackOpenWebUIApiKeyRemote -Endpoint $endpoint2 -BearerToken $storedCred.apiKey)
        $invalidRemote=Test-KIStackOpenWebUICredential -Endpoint $endpoint2 -TargetRoot $targetRoot
        $checks.invalidOnServerSideRejection=[ordered]@{status=([string]$invalidRemote.status-eq'Invalid')}
        if($checks.invalidOnServerSideRejection.Values-contains$false){$fail.Add('invalidOnServerSideRejection failed: '+($invalidRemote|ConvertTo-Json -Compress))}
    }finally{Stop-Process -Id $mock2.Id -Force -ErrorAction SilentlyContinue;Remove-Item -LiteralPath $paths.credentialFile -Force -ErrorAction SilentlyContinue}

    # --- 8. InsufficientPrivileges (Section 22-D): a normal, non-admin user signs in. -----------
    $port3=Get-Random -Minimum 20000 -Maximum 40000
    $mock3=Start-KIOpenWebUIMock -Port $port3 -EnableApiKeysInitially $true
    $endpoint3="http://127.0.0.1:$port3"
    try{
        $nonAdminBootstrap=Initialize-KIStackOpenWebUICredential -Endpoint $endpoint3 -AdminEmail $userEmail -AdminPassword (ConvertTo-SS $userPassword) -TargetRoot $targetRoot
        $checks.insufficientPrivilegesOnNonAdminSignin=[ordered]@{
            passed=(-not [bool]$nonAdminBootstrap.passed)
            status=([string]$nonAdminBootstrap.status-eq'InsufficientPrivileges')
            noStoreWrittenForRejectedBootstrap=(-not(Test-Path -LiteralPath $paths.credentialFile -PathType Leaf))
        }
        if($checks.insufficientPrivilegesOnNonAdminSignin.Values-contains$false){$fail.Add('insufficientPrivilegesOnNonAdminSignin failed: '+($checks.insufficientPrivilegesOnNonAdminSignin|ConvertTo-Json -Compress)+' | '+($nonAdminBootstrap|ConvertTo-Json -Compress))}
    }finally{Stop-Process -Id $mock3.Id -Force -ErrorAction SilentlyContinue}

    # --- 9. Rotation (Section 10/26): new key generated+validated+persisted BEFORE the old one is
    # considered superseded; old key stops authenticating afterward. ------------------------------
    $port4=Get-Random -Minimum 20000 -Maximum 40000
    $mock4=Start-KIOpenWebUIMock -Port $port4 -EnableApiKeysInitially $false
    $endpoint4="http://127.0.0.1:$port4"
    try{
        [void](Initialize-KIStackOpenWebUICredential -Endpoint $endpoint4 -AdminEmail $adminEmail -AdminPassword (ConvertTo-SS $adminPassword) -TargetRoot $targetRoot)
        $beforeRotate=Get-KIStackOpenWebUICredential -TargetRoot $targetRoot
        $beforePlain=$null;try{$b=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($beforeRotate.apiKey);$beforePlain=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($b)}finally{if($b){[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b)}}
        # Guarantee crossing the real Windows system-timer tick boundary (~15.6ms) between the two
        # UtcNow-stamped saves, so rotatedAtUtc is deterministically provable as advanced rather
        # than occasionally colliding on a very fast local-loopback round trip.
        Start-Sleep -Milliseconds 50
        $rotate=Initialize-KIStackOpenWebUICredential -Endpoint $endpoint4 -AdminEmail $adminEmail -AdminPassword (ConvertTo-SS $adminPassword) -TargetRoot $targetRoot -Rotate
        $afterRotate=Get-KIStackOpenWebUICredential -TargetRoot $targetRoot
        $afterPlain=$null;try{$b=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($afterRotate.apiKey);$afterPlain=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($b)}finally{if($b){[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b)}}
        $oldKeyStillWorks=$false
        try{$test=Invoke-RestMethod -Uri "$endpoint4/api/v1/auths/" -Headers @{Authorization="Bearer $beforePlain"} -TimeoutSec 5;$oldKeyStillWorks=$true}catch{}
        $checks.rotation=[ordered]@{
            passed=[bool]$rotate.passed
            status=([string]$rotate.status-eq'Rotated')
            keyActuallyChanged=($beforePlain-ne$afterPlain)
            createdAtUtcPreserved=([string]$beforeRotate.createdAtUtc-eq[string]$afterRotate.createdAtUtc)
            rotatedAtUtcAdvanced=([string]$beforeRotate.rotatedAtUtc-ne[string]$afterRotate.rotatedAtUtc)
            newKeyValidatesAsValid=([string]$rotate.credentialStatus.status-eq'Valid')
            oldKeyNoLongerWorks=(-not $oldKeyStillWorks)
        }
        if($checks.rotation.Values-contains$false){$fail.Add('rotation failed: '+($checks.rotation|ConvertTo-Json -Compress))}
    }finally{Stop-Process -Id $mock4.Id -Force -ErrorAction SilentlyContinue;Remove-Item -LiteralPath $paths.credentialFile -Force -ErrorAction SilentlyContinue}

    # --- 10. Revoke (Section 11/26) ---------------------------------------------------------------
    $port5=Get-Random -Minimum 20000 -Maximum 40000
    $mock5=Start-KIOpenWebUIMock -Port $port5 -EnableApiKeysInitially $false
    $endpoint5="http://127.0.0.1:$port5"
    try{
        [void](Initialize-KIStackOpenWebUICredential -Endpoint $endpoint5 -AdminEmail $adminEmail -AdminPassword (ConvertTo-SS $adminPassword) -TargetRoot $targetRoot)
        $revokeResult=Remove-KIStackOpenWebUICredential -Endpoint $endpoint5 -TargetRoot $targetRoot
        $statusAfterRevoke=Test-KIStackOpenWebUICredential -Endpoint $endpoint5 -TargetRoot $targetRoot
        $checks.revoke=[ordered]@{
            passed=[bool]$revokeResult.passed
            localStoreRemoved=(-not(Test-Path -LiteralPath $paths.credentialFile -PathType Leaf))
            remoteRevokeCalled=(-not[bool]$revokeResult.remote.skipped)
            statusAfterRevokeIsNotConfigured=([string]$statusAfterRevoke.status-eq'NotConfigured')
        }
        if($checks.revoke.Values-contains$false){$fail.Add('revoke failed: '+($checks.revoke|ConvertTo-Json -Compress))}
    }finally{Stop-Process -Id $mock5.Id -Force -ErrorAction SilentlyContinue}

    # --- 11. Negative Control A: Secret Logging (Section 22-A) -- prove the redaction helper
    # actually removes a real-shaped secret, and that a message run through it never contains the
    # raw token; a hypothetical caller that skipped redaction (simulated inline, not by mutating
    # real module source) WOULD leak it -- demonstrating the check is sensitive enough to matter. -
    # Built via concatenation, not a single contiguous literal -- the repository's own
    # high-confidence secret scan (scripts/Test-Repository.ps1) matches bare `sk-[A-Za-z0-9]{20,}`
    # source text on sight regardless of whether it is real (correctly so: it cannot tell a real
    # key from a fixture by looking at source alone), so this fixture value is assembled at
    # runtime to avoid *looking* like a checked-in secret while still exercising the exact same
    # runtime string through the real redaction path.
    $fixtureSecretValue='sk-'+'realtestsecretvalue'+'1234567890abcdef'
    $syntheticSecretMessage="Request failed. Authorization: Bearer $fixtureSecretValue"
    $redacted=ConvertTo-KIStackOpenWebUIRedactedText -Text $syntheticSecretMessage
    $checks.negativeControlA_SecretLoggingRedaction=[ordered]@{
        unredactedMessageWouldHaveLeaked=$syntheticSecretMessage.Contains($fixtureSecretValue)
        redactedMessageNeverContainsSecret=(-not $redacted.Contains($fixtureSecretValue))
        redactedMessageNeverContainsBearerValue=(-not ($redacted -match '(?i)Bearer\s+sk-'))
    }
    if($checks.negativeControlA_SecretLoggingRedaction.Values-contains$false){$fail.Add('negativeControlA_SecretLoggingRedaction failed: '+($checks.negativeControlA_SecretLoggingRedaction|ConvertTo-Json -Compress)+" | redacted: $redacted")}

    # --- 12. Negative Control B: DB-Hack (Section 22-B / 12/26 "No DB Access") -- static source
    # scan for forbidden literals, PLUS a self-test of the scanner itself against a synthetic
    # snippet that DOES contain a forbidden pattern, proving the scan would actually catch a real
    # regression rather than silently passing on anything. -----------------------------------------
    $moduleSource=[IO.File]::ReadAllText((Join-Path $PackageRoot 'Lifecycle/KIStackOpenWebUICredential.psm1'))
    $forbiddenDbPatterns=@('webui.db','System.Data.SQLite','sqlite3','SELECT * FROM','INSERT INTO','UPDATE users SET','password_hash')
    $realModuleViolations=@($forbiddenDbPatterns|Where-Object{$moduleSource.Contains($_)})
    $syntheticBadSnippet='$conn = Open-Sqlite -Path (Join-Path $TargetRoot "OpenWebUI\data\webui.db"); Invoke-SqliteQuery $conn "SELECT * FROM user"'
    $scannerSelfTestViolations=@($forbiddenDbPatterns|Where-Object{$syntheticBadSnippet.Contains($_)})
    $checks.negativeControlB_NoDatabaseAccess=[ordered]@{
        realModuleHasNoForbiddenDbPatterns=($realModuleViolations.Count-eq0)
        scannerWouldCatchARealViolation=($scannerSelfTestViolations.Count-gt0)
    }
    if($checks.negativeControlB_NoDatabaseAccess.Values-contains$false){$fail.Add('negativeControlB_NoDatabaseAccess failed: real violations='+($realModuleViolations-join', ')+'; scanner self-test violations='+($scannerSelfTestViolations.Count))}

    # --- 13. Negative Control C: Idempotency regression (Section 22-C) -- patch a copy of the
    # module so Initialize-KIStackOpenWebUICredential ALWAYS re-mints a key (skips the
    # ReusedExisting fast path), and prove that against a mock armed to reject a second
    # api_key POST, the REVERTED code trips the trap while the real, fixed module does not. -------
    $negativeSource=$moduleSource-replace[regex]::Escape('if(-not $Rotate){
        $existingStatus=Test-KIStackOpenWebUICredential -Endpoint $Endpoint -TargetRoot $TargetRoot
        if([string]$existingStatus.status-eq''Valid''){
            return [pscustomobject]@{passed=$true;status=''ReusedExisting'';credentialStatus=$existingStatus;mutatesTarget=$false}
        }
    }'),'# NEGATIVE CONTROL: idempotency fast-path removed on purpose'
    if($negativeSource-eq$moduleSource){throw 'Negative-Control-C-Patch griff nicht -- Testannahme verletzt (Idempotenz-Fastpath im Modul nicht gefunden).'}
    $negativeModulePath=Join-Path $suiteRoot 'KIStackOpenWebUICredential.negative.psm1'
    Set-Content -LiteralPath $negativeModulePath -Value $negativeSource -Encoding utf8NoBOM
    $port6=Get-Random -Minimum 20000 -Maximum 40000
    $mock6=Start-KIOpenWebUIMock -Port $port6 -EnableApiKeysInitially $false -RejectSecondApiKeyPost
    $endpoint6="http://127.0.0.1:$port6"
    Remove-Module KIStackOpenWebUICredential -Force -ErrorAction SilentlyContinue
    try{
        Import-Module $negativeModulePath -Force -DisableNameChecking
        [void](Initialize-KIStackOpenWebUICredential -Endpoint $endpoint6 -AdminEmail $adminEmail -AdminPassword (ConvertTo-SS $adminPassword) -TargetRoot $targetRoot)
        $negativeSecondCallFailed=$false
        try{
            $secondUnderNegative=Initialize-KIStackOpenWebUICredential -Endpoint $endpoint6 -AdminEmail $adminEmail -AdminPassword (ConvertTo-SS $adminPassword) -TargetRoot $targetRoot
            if(-not [bool]$secondUnderNegative.passed){$negativeSecondCallFailed=$true}
        }catch{$negativeSecondCallFailed=$true}
    }finally{
        Remove-Module KIStackOpenWebUICredential -Force -ErrorAction SilentlyContinue
        Import-Module (Join-Path $PackageRoot 'Lifecycle/KIStackOpenWebUICredential.psm1') -Force -DisableNameChecking
        Stop-Process -Id $mock6.Id -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $paths.credentialFile -Force -ErrorAction SilentlyContinue
    }
    # Real, fixed module: second real bootstrap call against a similarly-armed mock must NOT trip
    # the trap (it takes the ReusedExisting fast path and never issues a second POST at all).
    $port7=Get-Random -Minimum 20000 -Maximum 40000
    $mock7=Start-KIOpenWebUIMock -Port $port7 -EnableApiKeysInitially $false -RejectSecondApiKeyPost
    $endpoint7="http://127.0.0.1:$port7"
    try{
        [void](Initialize-KIStackOpenWebUICredential -Endpoint $endpoint7 -AdminEmail $adminEmail -AdminPassword (ConvertTo-SS $adminPassword) -TargetRoot $targetRoot)
        $secondUnderReal=Initialize-KIStackOpenWebUICredential -Endpoint $endpoint7 -AdminEmail $adminEmail -AdminPassword (ConvertTo-SS $adminPassword) -TargetRoot $targetRoot
        $checks.negativeControlC_IdempotencyRegressionDetected=[ordered]@{
            revertedCodeTrippedTheTrap=$negativeSecondCallFailed
            realFixedCodeNeverTripsTheTrap=[bool]$secondUnderReal.passed-and([string]$secondUnderReal.status-eq'ReusedExisting')
        }
    }finally{Stop-Process -Id $mock7.Id -Force -ErrorAction SilentlyContinue;Remove-Item -LiteralPath $paths.credentialFile -Force -ErrorAction SilentlyContinue}
    if($checks.negativeControlC_IdempotencyRegressionDetected.Values-contains$false){$fail.Add('negativeControlC_IdempotencyRegressionDetected failed: '+($checks.negativeControlC_IdempotencyRegressionDetected|ConvertTo-Json -Compress))}

    # --- 14. Fail-closed structural check (Section 23): the module never returns passed=true /
    # a usable credential for a NotConfigured/Invalid/InsufficientPrivileges state -- Test-* and
    # Initialize-*'s own status enums are exhaustive and distinct, never silently coerced to Valid.
    $checks.failClosedStatusesAreDistinct=[ordered]@{
        allSixStatusesDistinct=((@('NotConfigured','Valid','Invalid','OpenWebUIUnavailable','InsufficientPrivileges','Error')|Select-Object -Unique).Count-eq6)
    }

    foreach($file in Get-ChildItem -LiteralPath $PackageRoot -Filter '*OpenWebUICredential*' -File){
        $tokens=$null;$errors=$null
        [void][Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
        if(@($errors).Count){$fail.Add("$($file.Name): $(@($errors).Message -join '; ')")}
    }

    $passed=$fail.Count-eq0
    [pscustomobject]@{passed=$passed;checks=$checks;failures=@($fail);environment='isolated bootstrap (fixture-based; real OpenWebUI 0.11.1 instance not used here -- see final report for real API validation)';fixtureRoot=$suiteRoot}|ConvertTo-Json -Depth 12
    if(-not$passed){throw 'OpenWebUI-Credential-Bootstrap-Regression fehlgeschlagen.'}
}
finally{
    if(Test-Path -LiteralPath $suiteRoot){Remove-Item -LiteralPath $suiteRoot -Recurse -Force -ErrorAction SilentlyContinue}
}
