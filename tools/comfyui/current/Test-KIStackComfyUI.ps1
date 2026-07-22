[CmdletBinding()]param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=$PSScriptRoot; $fail=@()
$required=@('VERSION','MANIFEST.json','Payload/PAYLOAD-CONTRACT.json','ComfyUIPackage.psm1','Invoke-KIStackComfyUI.ps1','New-KIStackComfyUIArchive.ps1','Start-KIStack-ComfyUI-Audit.cmd','Start-KIStack-ComfyUI-Execute.cmd','Start-KIStack-ComfyUI-DryRun.cmd','Start-KIStack-ComfyUI-Repair.cmd','Start-KIStack-ComfyUI-Rollback.cmd')
foreach ($file in $required) { if (-not (Test-Path (Join-Path $root $file))) { $fail += "missing $file" } }
$text=(Get-Content (Join-Path $root 'ComfyUIPackage.psm1') -Raw)+(Get-Content (Join-Path $root 'Invoke-KIStackComfyUI.ps1') -Raw)
foreach ($pattern in @('(?i)\bgit(?:\.exe)?\b','(?i)\bclone\b','(?i)\bcheckout\b','(?i)\bpull\b','(?i)origin','(?i)\.git(?:[\\/]|\b)')) { if ($text -match $pattern) { $fail += "forbidden runtime pattern $pattern" } }
$contract=Get-Content (Join-Path $root 'Payload/PAYLOAD-CONTRACT.json') -Raw|ConvertFrom-Json
if ($contract.sha256 -notmatch '^[0-9a-f]{64}$' -or $contract.sizeBytes -le 0) { $fail += 'payload contract' }
$cmds=Get-ChildItem $root -Filter '*.cmd'
foreach ($cmd in $cmds) {
    $bytes=[IO.File]::ReadAllBytes($cmd.FullName)
    if ($bytes.Length-ge3 -and $bytes[0]-eq239 -and $bytes[1]-eq187 -and $bytes[2]-eq191) { $fail += "BOM $($cmd.Name)" }
    for ($i=0;$i-lt$bytes.Length;$i++) { if ($bytes[$i]-eq10 -and ($i-eq0 -or $bytes[$i-1]-ne13)) { $fail += "LF $($cmd.Name)"; break } }
}
$fixture=Join-Path $env:TEMP ('comfy-fixture-'+[guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $fixture|Out-Null
try {
    $copy=Join-Path $fixture 'package'; Copy-Item $root $copy -Recurse
    New-Item -ItemType Directory (Join-Path $copy 'Payload') -Force|Out-Null
    Set-Content (Join-Path $copy ('Payload/'+$contract.fileName)) 'broken'
    Import-Module (Join-Path $root 'ComfyUIPackage.psm1') -Force
    if ((Test-ComfyPayload $copy).passed) { $fail += 'bad payload accepted' }
}
finally { Remove-Item $fixture -Recurse -Force }
$result=[ordered]@{passed=($fail.Count-eq0);version='1.2.2';checks=10;failures=$fail};$result|ConvertTo-Json -Depth 10
if ($fail.Count) { throw ($fail-join'; ') }
