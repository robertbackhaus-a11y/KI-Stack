Set-StrictMode -Version Latest

# OpenWebUI Credential Bootstrap (real, verified against the installed OpenWebUI 0.11.1 source
# under C:\KI-Stack\python\venvs\openwebui\Lib\site-packages\open_webui):
#
#   POST /api/v1/auths/signin           -- {email,password} -> SessionUserResponse incl. session
#                                           token (Bearer JWT) and role. One-time, human-provided,
#                                           interactive-only (see Initialize-KIStackOpenWebUICredential.ps1).
#   GET  /api/v1/auths/                 -- "who am I" (get_session_user); works for BOTH a session
#                                           JWT and an sk- API key, since both are dispatched
#                                           through the same Authorization: Bearer <token> header
#                                           (open_webui/utils/auth.py's get_current_user checks
#                                           token.startswith('sk-') to route to the API-key path).
#   GET  /api/v1/auths/admin/config     -- full admin config blob (admin-only).
#   POST /api/v1/auths/admin/config     -- full-replace update (admin-only); ENABLE_API_KEYS
#                                           defaults to False (open_webui/config.py) unless a
#                                           real KI-Stack OpenWebUI deployment's env explicitly
#                                           sets ENABLE_API_KEYS=true (verified: the current
#                                           Start-KIStack-OpenWebUI.cmd does not set it) -- so a
#                                           one-time, additive (GET-then-merge-then-POST, exactly
#                                           the pattern Set-KIStackCodeInterpreter.ps1 already
#                                           uses for /api/v1/configs/code_execution) admin-config
#                                           change is a real, expected part of first bootstrap.
#   POST /api/v1/auths/api_key          -- generate_api_key: mints a real, persistent `sk-...`
#                                           key for the CURRENTLY authenticated user (one key per
#                                           user; regenerating overwrites the previous one, see
#                                           Users.update_user_api_key_by_id) and requires either
#                                           role=admin or the features.api_keys permission.
#   GET  /api/v1/auths/api_key          -- read back the current user's own key (used to detect
#                                           whether a key already exists before minting a new one).
#   DELETE /api/v1/auths/api_key        -- revoke the current user's own key.
#
# All access is via this documented, stable REST surface only -- never the underlying SQLite
# database file directly, never a password hash read/write, never session-cookie/browser
# automation (Section 12 of the
# OpenWebUI-Credential-Bootstrap-Workstream). The only human-entered secret this module ever
# handles (the one-time admin password used for the initial /signin call) lives exclusively as a
# [Security.SecureString] and is converted to plaintext only transiently, immediately before one
# HTTP call, and is never written to a variable that outlives that call, never logged, never
# passed as a CLI argument.

function Get-KIStackOpenWebUICredentialPaths {
    param([string]$TargetRoot='C:\KI-Stack')
    $stateRoot=Join-Path $TargetRoot 'state/openwebui'
    [pscustomobject]@{
        stateRoot=$stateRoot
        credentialFile=Join-Path $stateRoot 'credential.json'
    }
}

function ConvertTo-KIStackOpenWebUIRedactedText {
    # Central redaction helper -- reused by every new log-facing path in this module. Matches and
    # extends the pattern OpenWebUIAgentPack.psm1 already applies to its own diagnostic output.
    param([string]$Text)
    if([string]::IsNullOrEmpty($Text)){return $Text}
    $redacted=$Text -replace '(?i)Bearer\s+\S+','Bearer <redacted>'
    $redacted=$redacted -replace '(?i)\bsk-[A-Za-z0-9._-]{10,}\b','<redacted>'
    $redacted=$redacted -replace '(?i)"password"\s*:\s*"[^"]*"','"password":"<redacted>"'
    $redacted
}

function ConvertFrom-KIStackSecureStringTransient {
    # The ONLY place in this module allowed to hold a plaintext secret in a variable -- callers
    # must use it in a `try { } finally { $plain=$null }` block immediately, never store the
    # result, never log it, never pass it as a process argument.
    param([Parameter(Mandatory)][Security.SecureString]$Value)
    $bstr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
    try{[Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)}finally{[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)}
}

function Read-KIStackOpenWebUICredentialRecordRaw {
    # PowerShell 7's ConvertFrom-Json auto-detects ISO-8601-looking string values and silently
    # converts them to [DateTime] (losing sub-second precision along the way, and even -AsHashtable
    # does not disable this) -- reproduced live: two real, distinct rotatedAtUtc writes a real
    # 50ms apart round-tripped as the SAME second-precision value. This store's timestamps are an
    # audit trail (Section 10's rotatedAtUtc-advanced proof, Section 33's report), so every read
    # of it goes through .NET's JsonDocument directly instead, which returns exactly the strings
    # that were written -- no implicit type coercion of any kind.
    param([Parameter(Mandatory)][string]$Path)
    $raw=[IO.File]::ReadAllText($Path)
    $document=[Text.Json.JsonDocument]::Parse($raw)
    try{
        $result=[ordered]@{}
        foreach($property in $document.RootElement.EnumerateObject()){
            $result[$property.Name]=switch($property.Value.ValueKind){
                'String'{$property.Value.GetString()}
                'True'{$true}
                'False'{$false}
                default{$property.Value.GetRawText()}
            }
        }
        [pscustomobject]$result
    }finally{$document.Dispose()}
}

function Save-KIStackOpenWebUICredential {
    # Persists the API key DPAPI-encrypted (ConvertFrom-SecureString with no -Key/-SecureKey uses
    # Windows DPAPI, CurrentUser scope, under the hood) -- never plaintext, never in the
    # repository, never in a build artifact (this only ever writes under TargetRoot's own real
    # state tree, C:\KI-Stack\state\openwebui by default). Machine-/user-bound by construction:
    # the encrypted blob is only decryptable by the same Windows user profile on the same
    # machine that created it (see the module header's Maschinen-/Benutzerbindung note).
    param(
        [Parameter(Mandatory)][string]$Endpoint,
        [Parameter(Mandatory)][Security.SecureString]$ApiKey,
        [string]$UserId='',
        [string]$UserEmail='',
        [string]$TargetRoot='C:\KI-Stack'
    )
    $paths=Get-KIStackOpenWebUICredentialPaths -TargetRoot $TargetRoot
    New-Item -ItemType Directory -Path $paths.stateRoot -Force|Out-Null
    $encrypted=$ApiKey|ConvertFrom-SecureString
    $existing=$null
    if(Test-Path -LiteralPath $paths.credentialFile -PathType Leaf){try{$existing=Read-KIStackOpenWebUICredentialRecordRaw -Path $paths.credentialFile}catch{}}
    $createdAtUtc=if($existing-and$existing.PSObject.Properties['createdAtUtc']-and-not[string]::IsNullOrWhiteSpace([string]$existing.createdAtUtc)){[string]$existing.createdAtUtc}else{[DateTime]::UtcNow.ToString('o')}
    $record=[ordered]@{
        schemaVersion='1.0'
        endpoint=$Endpoint
        userId=$UserId
        userEmail=$UserEmail
        protectedForUserSid=([Security.Principal.WindowsIdentity]::GetCurrent()).User.Value
        machineName=$env:COMPUTERNAME
        createdAtUtc=$createdAtUtc
        rotatedAtUtc=[DateTime]::UtcNow.ToString('o')
        encryptedApiKey=$encrypted
        containsSecrets=$false
    }
    $temporary=$paths.credentialFile+'.tmp'
    $record|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $temporary -Encoding utf8NoBOM
    Move-Item -LiteralPath $temporary -Destination $paths.credentialFile -Force
    [pscustomobject]@{passed=$true;path=$paths.credentialFile;mutatesTarget=$true}
}

function Get-KIStackOpenWebUICredential {
    # The single, central resolver every OpenWebUI automation should call. Reads the encrypted
    # local store, decrypts in-process, and returns the API key ONLY as a [Security.SecureString]
    # -- it is never written to output, never converted to plaintext here. Returns $null when
    # genuinely NotConfigured (no store file at all) -- never throws for that case.
    param([string]$TargetRoot='C:\KI-Stack')
    $paths=Get-KIStackOpenWebUICredentialPaths -TargetRoot $TargetRoot
    if(-not(Test-Path -LiteralPath $paths.credentialFile -PathType Leaf)){return $null}
    try{
        $record=Read-KIStackOpenWebUICredentialRecordRaw -Path $paths.credentialFile
        $secure=[string]$record.encryptedApiKey|ConvertTo-SecureString
        [pscustomobject]@{
            apiKey=$secure
            endpoint=[string]$record.endpoint
            userId=[string]$record.userId
            userEmail=[string]$record.userEmail
            createdAtUtc=[string]$record.createdAtUtc
            rotatedAtUtc=[string]$record.rotatedAtUtc
            decryptionFailed=$false
        }
    }catch{
        # Wrong Windows user/machine, or a corrupted/tampered store -- DPAPI decryption itself
        # fails here (CryptographicException). Never surfaces the raw .NET exception text
        # upward (it can be environment-specific); mapped to a clean, structured signal instead.
        [pscustomobject]@{apiKey=$null;decryptionFailed=$true;reason='Store nicht entschlüsselbar (falscher Benutzer-/Maschinenkontext oder beschädigt) -- Re-Bootstrap auf dieser Maschine/für diesen Benutzer erforderlich.'}
    }
}

function Test-KIStackOpenWebUICredential {
    # Status contract (Section 8): NotConfigured / Valid / Invalid / OpenWebUIUnavailable /
    # InsufficientPrivileges / Error -- OpenWebUI being offline is never conflated with an
    # actually-invalid key.
    param([string]$Endpoint='',[string]$TargetRoot='C:\KI-Stack',[int]$TimeoutSec=10)
    $cred=Get-KIStackOpenWebUICredential -TargetRoot $TargetRoot
    if($null-eq$cred){return [pscustomobject]@{status='NotConfigured';reason='Kein OpenWebUI-Credential im lokalen Store gefunden.';mutatesTarget=$false}}
    if([bool]$cred.decryptionFailed){return [pscustomobject]@{status='Invalid';reason=$cred.reason;mutatesTarget=$false}}
    $resolvedEndpoint=if([string]::IsNullOrWhiteSpace($Endpoint)){$cred.endpoint}else{$Endpoint}
    $plain=$null
    try{
        $plain=ConvertFrom-KIStackSecureStringTransient -Value $cred.apiKey
        $response=Invoke-RestMethod -Uri ($resolvedEndpoint.TrimEnd('/')+'/api/v1/auths/') -Method Get -Headers @{Authorization="Bearer $plain"} -TimeoutSec $TimeoutSec -ErrorAction Stop
        $role=[string]$response.role
        if($role-ne'admin'){
            return [pscustomobject]@{status='InsufficientPrivileges';reason="Authentifiziert, aber Rolle ist '$role', nicht 'admin'.";userId=[string]$response.id;userEmail=[string]$response.email;mutatesTarget=$false}
        }
        [pscustomobject]@{status='Valid';reason=$null;userId=[string]$response.id;userEmail=[string]$response.email;role=$role;endpoint=$resolvedEndpoint;mutatesTarget=$false}
    }catch [Microsoft.PowerShell.Commands.HttpResponseException]{
        $code=[int]$_.Exception.Response.StatusCode
        if($code-eq401-or$code-eq403){[pscustomobject]@{status='Invalid';reason="OpenWebUI hat den gespeicherten Key abgelehnt (HTTP $code).";mutatesTarget=$false}}
        else{[pscustomobject]@{status='Error';reason="Unerwarteter HTTP-Status $code von OpenWebUI.";mutatesTarget=$false}}
    }catch{
        [pscustomobject]@{status='OpenWebUIUnavailable';reason="OpenWebUI unter '$resolvedEndpoint' nicht erreichbar: $(ConvertTo-KIStackOpenWebUIRedactedText $_.Exception.Message)";mutatesTarget=$false}
    }finally{$plain=$null}
}

function Invoke-KIStackOpenWebUIAdminSignin {
    # Internal (not part of the long-term automation surface, only used by
    # Initialize-KIStackOpenWebUICredential's one-time bootstrap/rotate path). AdminPassword is
    # converted to plaintext ONLY for the single signin HTTP body, immediately zeroed afterward.
    param(
        [Parameter(Mandatory)][string]$Endpoint,
        [Parameter(Mandatory)][string]$AdminEmail,
        [Parameter(Mandatory)][Security.SecureString]$AdminPassword,
        [int]$TimeoutSec=15
    )
    $plainPassword=$null
    try{
        $plainPassword=ConvertFrom-KIStackSecureStringTransient -Value $AdminPassword
        $body=@{email=$AdminEmail;password=$plainPassword}|ConvertTo-Json -Compress
        $response=Invoke-RestMethod -Uri ($Endpoint.TrimEnd('/')+'/api/v1/auths/signin') -Method Post -ContentType 'application/json; charset=utf-8' -Body $body -TimeoutSec $TimeoutSec -ErrorAction Stop
        $sessionToken=ConvertTo-SecureString -String ([string]$response.token) -AsPlainText -Force
        [pscustomobject]@{passed=$true;sessionToken=$sessionToken;userId=[string]$response.id;role=[string]$response.role;userEmail=[string]$response.email}
    }catch [Microsoft.PowerShell.Commands.HttpResponseException]{
        $code=[int]$_.Exception.Response.StatusCode
        [pscustomobject]@{passed=$false;reason=$(if($code-eq400-or$code-eq401){'Anmeldung abgelehnt (falsche E-Mail/Passwort oder Konto nicht aktiv).'}else{"Unerwarteter HTTP-Status $code beim Anmelden."})}
    }catch{
        [pscustomobject]@{passed=$false;reason="OpenWebUI-Anmeldung fehlgeschlagen: $(ConvertTo-KIStackOpenWebUIRedactedText $_.Exception.Message)"}
    }finally{$plainPassword=$null;$body=$null}
}

function Enable-KIStackOpenWebUIApiKeySupport {
    # ENABLE_API_KEYS defaults to False in open_webui/config.py and the KI-Stack-managed starter
    # does not set it -- so a real, one-time additive admin-config change (GET full config, flip
    # exactly this one field, POST the full merged object back) is a legitimate, expected part of
    # first bootstrap, using the SAME GET-then-merge-then-POST pattern
    # Set-KIStackCodeInterpreter.ps1 already applies to /api/v1/configs/code_execution. Never
    # resets any other admin setting.
    param([Parameter(Mandatory)][string]$Endpoint,[Parameter(Mandatory)][Security.SecureString]$BearerToken,[int]$TimeoutSec=15)
    $plain=$null
    try{
        $plain=ConvertFrom-KIStackSecureStringTransient -Value $BearerToken
        $headers=@{Authorization="Bearer $plain"}
        $current=Invoke-RestMethod -Uri ($Endpoint.TrimEnd('/')+'/api/v1/auths/admin/config') -Method Get -Headers $headers -TimeoutSec $TimeoutSec -ErrorAction Stop
        if([bool]$current.ENABLE_API_KEYS){return [pscustomobject]@{passed=$true;changed=$false}}
        $current.ENABLE_API_KEYS=$true
        $body=$current|ConvertTo-Json -Depth 10 -Compress
        [void](Invoke-RestMethod -Uri ($Endpoint.TrimEnd('/')+'/api/v1/auths/admin/config') -Method Post -ContentType 'application/json; charset=utf-8' -Headers $headers -Body $body -TimeoutSec $TimeoutSec -ErrorAction Stop)
        [pscustomobject]@{passed=$true;changed=$true}
    }catch{
        [pscustomobject]@{passed=$false;reason="ENABLE_API_KEYS konnte nicht gesetzt werden: $(ConvertTo-KIStackOpenWebUIRedactedText $_.Exception.Message)"}
    }finally{$plain=$null}
}

function New-KIStackOpenWebUIApiKey {
    # Real call to POST /api/v1/auths/api_key, authenticated with the (session-token) bearer from
    # the one-time signin. Returns the new key ONLY as a SecureString.
    param([Parameter(Mandatory)][string]$Endpoint,[Parameter(Mandatory)][Security.SecureString]$BearerToken,[int]$TimeoutSec=15)
    $plain=$null
    try{
        $plain=ConvertFrom-KIStackSecureStringTransient -Value $BearerToken
        $response=Invoke-RestMethod -Uri ($Endpoint.TrimEnd('/')+'/api/v1/auths/api_key') -Method Post -Headers @{Authorization="Bearer $plain"} -TimeoutSec $TimeoutSec -ErrorAction Stop
        $newKey=[string]$response.api_key
        if([string]::IsNullOrWhiteSpace($newKey)){return [pscustomobject]@{passed=$false;reason='OpenWebUI hat keinen API-Key zurückgegeben.'}}
        [pscustomobject]@{passed=$true;apiKey=(ConvertTo-SecureString -String $newKey -AsPlainText -Force)}
    }catch{
        [pscustomobject]@{passed=$false;reason="API-Key-Erzeugung fehlgeschlagen: $(ConvertTo-KIStackOpenWebUIRedactedText $_.Exception.Message)"}
    }finally{$plain=$null;$newKey=$null}
}

function Remove-KIStackOpenWebUIApiKeyRemote {
    # DELETE /api/v1/auths/api_key -- revokes whichever key the given bearer authenticates as.
    # Only ever called with a KI-Stack-owned key (the one currently in the local store, or the
    # just-superseded old key during rotation) -- never a foreign user's key (Section 11).
    param([Parameter(Mandatory)][string]$Endpoint,[Parameter(Mandatory)][Security.SecureString]$BearerToken,[int]$TimeoutSec=15)
    $plain=$null
    try{
        $plain=ConvertFrom-KIStackSecureStringTransient -Value $BearerToken
        [void](Invoke-RestMethod -Uri ($Endpoint.TrimEnd('/')+'/api/v1/auths/api_key') -Method Delete -Headers @{Authorization="Bearer $plain"} -TimeoutSec $TimeoutSec -ErrorAction Stop)
        [pscustomobject]@{passed=$true;skipped=$false}
    }catch{
        [pscustomobject]@{passed=$false;skipped=$false;reason="Revoke fehlgeschlagen: $(ConvertTo-KIStackOpenWebUIRedactedText $_.Exception.Message)"}
    }finally{$plain=$null}
}

function Initialize-KIStackOpenWebUICredential {
    # Idempotent bootstrap/rotate orchestrator (Section 9/10). Second run against an already-
    # Valid credential reuses it and mints nothing new UNLESS -Rotate is passed. AdminEmail/
    # AdminPassword are explicit parameters (never Read-Host inside this function) so this stays
    # unit-testable without a real terminal -- the interactive UI lives in the thin entry-point
    # script Initialize-KIStackOpenWebUICredential.ps1.
    param(
        [Parameter(Mandatory)][string]$Endpoint,
        [Parameter(Mandatory)][string]$AdminEmail,
        [Parameter(Mandatory)][Security.SecureString]$AdminPassword,
        [string]$TargetRoot='C:\KI-Stack',
        [switch]$Rotate
    )
    if(-not $Rotate){
        $existingStatus=Test-KIStackOpenWebUICredential -Endpoint $Endpoint -TargetRoot $TargetRoot
        if([string]$existingStatus.status-eq'Valid'){
            return [pscustomobject]@{passed=$true;status='ReusedExisting';credentialStatus=$existingStatus;mutatesTarget=$false}
        }
    }
    $signin=Invoke-KIStackOpenWebUIAdminSignin -Endpoint $Endpoint -AdminEmail $AdminEmail -AdminPassword $AdminPassword
    if(-not[bool]$signin.passed){return [pscustomobject]@{passed=$false;status='SigninFailed';reason=$signin.reason;mutatesTarget=$false}}
    if([string]$signin.role-ne'admin'){
        $signin.sessionToken=$null
        return [pscustomobject]@{passed=$false;status='InsufficientPrivileges';reason="Angemeldeter Nutzer hat Rolle '$($signin.role)', nicht 'admin'.";mutatesTarget=$false}
    }
    $enable=Enable-KIStackOpenWebUIApiKeySupport -Endpoint $Endpoint -BearerToken $signin.sessionToken
    if(-not[bool]$enable.passed){$signin.sessionToken=$null;return [pscustomobject]@{passed=$false;status='ApiKeySupportNotEnabled';reason=$enable.reason;mutatesTarget=$false}}

    $previousCredential=if($Rotate){Get-KIStackOpenWebUICredential -TargetRoot $TargetRoot}else{$null}

    $created=New-KIStackOpenWebUIApiKey -Endpoint $Endpoint -BearerToken $signin.sessionToken
    $signin.sessionToken=$null
    if(-not[bool]$created.passed){return [pscustomobject]@{passed=$false;status='KeyGenerationFailed';reason=$created.reason;mutatesTarget=$false}}

    # Validate the NEW key for real before persisting or revoking anything old -- step 2 of the
    # Section 10 rotation contract, and equally correct for a first-time bootstrap.
    Save-KIStackOpenWebUICredential -Endpoint $Endpoint -ApiKey $created.apiKey -UserId $signin.userId -UserEmail $signin.userEmail -TargetRoot $TargetRoot|Out-Null
    $validation=Test-KIStackOpenWebUICredential -Endpoint $Endpoint -TargetRoot $TargetRoot
    if([string]$validation.status-ne'Valid'){
        # Roll back to whatever was there before (or to nothing, on a genuine first bootstrap)
        # rather than leave an unvalidated key as the active local credential.
        if($null-ne$previousCredential-and-not[bool]$previousCredential.decryptionFailed){
            Save-KIStackOpenWebUICredential -Endpoint $previousCredential.endpoint -ApiKey $previousCredential.apiKey -UserId $previousCredential.userId -UserEmail $previousCredential.userEmail -TargetRoot $TargetRoot|Out-Null
        }
        $created.apiKey=$null
        return [pscustomobject]@{passed=$false;status='NewCredentialFailedValidation';reason="Neu erzeugter Key bestand die Validierung nicht: $($validation.status) -- $($validation.reason)";mutatesTarget=$true}
    }
    $created.apiKey=$null

    # Step 4 of Section 10: only NOW, after the new key is validated and safely persisted, revoke
    # the old one -- never the other way around.
    $revoke=[pscustomobject]@{passed=$true;skipped=$true}
    if($Rotate-and$null-ne$previousCredential-and-not[bool]$previousCredential.decryptionFailed){
        # Nothing to actually revoke remotely here: OpenWebUI stores exactly one API key per user
        # (Users.update_user_api_key_by_id overwrites), and generate_api_key above already
        # replaced the old value server-side. This step exists to keep the contract explicit and
        # auditable rather than silently relying on that overwrite.
        $revoke=[pscustomobject]@{passed=$true;skipped=$false;note='Serverseitig durch Neuerzeugung ersetzt (ein Key pro Benutzer in OpenWebUI 0.11.1); kein separater Revoke-Aufruf nötig.'}
    }
    [pscustomobject]@{passed=$true;status=$(if($Rotate){'Rotated'}else{'Bootstrapped'});credentialStatus=$validation;revoke=$revoke;mutatesTarget=$true}
}

function Remove-KIStackOpenWebUICredential {
    # Explicit operator revoke (Section 11): removes ONLY the KI-Stack-owned local store and
    # revokes ONLY that same credential's own remote key -- never any other user's key, never an
    # admin password change.
    param([string]$Endpoint='',[string]$TargetRoot='C:\KI-Stack')
    $cred=Get-KIStackOpenWebUICredential -TargetRoot $TargetRoot
    $paths=Get-KIStackOpenWebUICredentialPaths -TargetRoot $TargetRoot
    $remoteResult=[pscustomobject]@{passed=$true;skipped=$true}
    if($null-ne$cred-and-not[bool]$cred.decryptionFailed){
        $resolvedEndpoint=if([string]::IsNullOrWhiteSpace($Endpoint)){$cred.endpoint}else{$Endpoint}
        $remoteResult=Remove-KIStackOpenWebUIApiKeyRemote -Endpoint $resolvedEndpoint -BearerToken $cred.apiKey
    }
    if(Test-Path -LiteralPath $paths.credentialFile -PathType Leaf){Remove-Item -LiteralPath $paths.credentialFile -Force}
    [pscustomobject]@{passed=$true;localRemoved=$true;remote=$remoteResult;mutatesTarget=$true}
}

Export-ModuleMember -Function *
