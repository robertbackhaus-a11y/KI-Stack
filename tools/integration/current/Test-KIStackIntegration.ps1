[CmdletBinding()]param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=$PSScriptRoot; $fail=@()
$executables=@('IntegrationPackage.psm1','Invoke-KIStackIntegration.ps1','Linux/install-searxng-payload.sh')
$text=($executables|ForEach-Object{Get-Content(Join-Path $root $_)-Raw})-join"`n"
foreach ($pattern in @('(?i)\bgit(?:\.exe)?\b','(?i)\bclone\b','(?i)\bcheckout\b','(?i)\bpull\b','(?i)origin','(?i)\.git(?:[\\/]|\b)','(?i)ki-stack-searxng\.service')) { if ($text -match $pattern) { $fail += "forbidden runtime pattern $pattern" } }
foreach ($required in @('valkey-server','uwsgi','nginx','wsl.exe','sha256sum','CONTENT-MANIFEST.json')) { if ($text -notmatch [regex]::Escape($required)) { $fail += "missing $required" } }
$contract=Get-Content (Join-Path $root 'Payload/PAYLOAD-CONTRACT.json') -Raw|ConvertFrom-Json
if ($contract.sha256 -notmatch '^[0-9a-f]{64}$' -or $contract.sizeBytes -le 0) { $fail += 'payload contract' }
$result=[ordered]@{passed=($fail.Count-eq0);version='1.5.9';checks=12;failures=$fail};$result|ConvertTo-Json -Depth 10
if ($fail.Count) { throw ($fail-join'; ') }
