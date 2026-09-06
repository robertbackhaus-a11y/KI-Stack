[CmdletBinding()]
param([string]$PythonPath='python',[string]$SolverRoot)
$ErrorActionPreference='Stop';$fail=[Collections.Generic.List[string]]::new()
foreach($file in @('OpenWebUIBallisticsPack.psm1','Invoke-OpenWebUIBallisticsPack.ps1','Test-OpenWebUIBallisticsPackTarget.ps1','New-OpenWebUIBallisticsPackArchive.ps1','Tool/BallisticsCalculator.py','Definitions/ki-stack-18bravo.json','Contracts/PAYLOADS.json','Schemas/input.schema.json','Schemas/output.schema.json','Schemas/csv.schema.json','Schemas/profile.schema.json','MANIFEST.json','VERSION')){if(-not(Test-Path (Join-Path $PSScriptRoot $file))){$fail.Add("Fehlt: $file")}}
foreach($json in Get-ChildItem $PSScriptRoot -Recurse -Filter *.json){try{$null=Get-Content $json.FullName -Raw|ConvertFrom-Json -Depth 100}catch{$fail.Add("JSON: $($json.FullName)")}}
foreach($script in Get-ChildItem $PSScriptRoot -Recurse -Include *.ps1,*.psm1){$tok=$null;$err=$null;$null=[Management.Automation.Language.Parser]::ParseFile($script.FullName,[ref]$tok,[ref]$err);if($err){$fail.Add("Parser: $($script.Name)")}}
foreach($cmd in Get-ChildItem $PSScriptRoot -Filter *.cmd){$bytes=[IO.File]::ReadAllBytes($cmd.FullName);if($bytes.Length-ge3-and$bytes[0]-eq0xEF-and$bytes[1]-eq0xBB-and$bytes[2]-eq0xBF){$fail.Add("CMD BOM: $($cmd.Name)")};$text=[Text.Encoding]::ASCII.GetString($bytes);if($text-replace"`r`n",''-match"`n"){$fail.Add("CMD LF: $($cmd.Name)")}}
$contract=Get-Content (Join-Path $PSScriptRoot 'Contracts/PAYLOADS.json') -Raw|ConvertFrom-Json;if([string]$contract.payloads[0].sha256-ne'6a17eb8c40f9606ac5878b0a5d30575f7cc83cc549375e1371c100e2bdab36a4'){$fail.Add('Wheel SHA-Vertrag')}

# 2.16 Phase 3A regression guard: a real Ballistics-Pack Execute reconcile against production was
# found to silently drop the profile's own "server:mcp:ki-stack-mcp-runtime" MCP binding, because
# New-BallisticsModelForm hardcoded toolIds to exactly one entry. Proves, purely offline (no live
# target needed -- New-BallisticsModelForm only reads the local Definitions/ki-stack-18bravo.json),
# that: (1) the ballistics tool AND the MCP binding both survive form construction, (2) no duplicate
# entry appears, and (3) this holds identically on a second, independent call -- simulating a
# repeated reconcile -- proving the fix is deterministic, not merely accidental on a first run.
Import-Module (Join-Path $PSScriptRoot 'OpenWebUIBallisticsPack.psm1') -Force
foreach($pass in 1,2){
    $form=New-BallisticsModelForm $PSScriptRoot 'fixture-base-model'
    $toolIds=@($form.meta.toolIds)
    if($toolIds-notcontains'ki_stack_ballistics_calculator'){$fail.Add("MCP-Bindungs-Regression (Pass $pass): Ballistikrechner-Tool fehlt")}
    if($toolIds-notcontains'server:mcp:ki-stack-mcp-runtime'){$fail.Add("MCP-Bindungs-Regression (Pass $pass): server:mcp:ki-stack-mcp-runtime fehlt")}
    if($toolIds.Count-ne(@($toolIds|Select-Object -Unique).Count)){$fail.Add("MCP-Bindungs-Regression (Pass $pass): doppelter Tool-Eintrag")}
    if($toolIds.Count-ne2){$fail.Add("MCP-Bindungs-Regression (Pass $pass): unerwartete Tool-Anzahl $($toolIds.Count)")}
}
if($SolverRoot){$old=$env:PYTHONPATH;$oldBytecode=$env:PYTHONDONTWRITEBYTECODE;$env:PYTHONPATH=$SolverRoot;$env:PYTHONDONTWRITEBYTECODE='1';try{&$PythonPath (Join-Path $PSScriptRoot 'Tests/test_ballistics_calculator.py');if($LASTEXITCODE-ne0){$fail.Add('Solver-Fixtures')}}finally{$env:PYTHONPATH=$old;$env:PYTHONDONTWRITEBYTECODE=$oldBytecode}}
$result=[pscustomobject]@{version='1.0.0';passed=($fail.Count-eq0);failures=@($fail);fixtures=@('G1','G7','metric','imperial','MRAD','MOA','wind-0','wind-90','wind-180','temperature','pressure','missing','invalid-BC','negative-range','zero-velocity','unit-conflict','click','CSV','JSON','profile-confirmation','rollback-contract')};$result;if(-not$result.passed){exit 1}
