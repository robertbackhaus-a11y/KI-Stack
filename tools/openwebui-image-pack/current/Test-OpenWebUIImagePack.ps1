[CmdletBinding()]param([string]$PackageRoot=$PSScriptRoot)
Set-StrictMode -Version Latest;$ErrorActionPreference='Stop';$f=[Collections.Generic.List[string]]::new()
$required=@('VERSION','Config/image-pack.config.json','Workflow/FLUX2-Klein-9B-OpenWebUI-API-FLAT.json','Tool/ki-stack-generate-image.py','Tests/test_image_adapter.py','OpenWebUIImagePack.psm1','Invoke-OpenWebUIImagePack.ps1','Test-OpenWebUIImagePackTarget.ps1','New-OpenWebUIImagePackArchive.ps1','README.md','MANIFEST.json','SHA256SUMS.txt')
foreach($r in $required){if(-not(Test-Path -LiteralPath(Join-Path $PackageRoot $r)-PathType Leaf)){$f.Add("Fehlt: $r")}}
$v=(Get-Content(Join-Path $PackageRoot VERSION)-Raw).Trim();$c=Get-Content(Join-Path $PackageRoot 'Config/image-pack.config.json')-Raw|ConvertFrom-Json;$m=Get-Content(Join-Path $PackageRoot MANIFEST.json)-Raw|ConvertFrom-Json
if($v-ne'1.9.2'-or$c.version-ne$v-or$m.version-ne$v){$f.Add('Versionskonsistenz')};if($m.managedTool.id-ne'ki-stack-generate-image'-or$m.managedTool.openWebUIId-ne'ki_stack_generate_image'-or$m.managedTool.managedBy-ne'KI-STACK-OPENWEBUI-IMAGE-PACK'){$f.Add('Toolvertrag')}
$w=Get-Content(Join-Path $PackageRoot 'Workflow/FLUX2-Klein-9B-OpenWebUI-API-FLAT.json')-Raw|ConvertFrom-Json -AsHashtable;if($w['87'].inputs.unet_name-ne'flux-2-klein-9b-fp8.safetensors'-or$w['92'].class_type-ne'CLIPTextEncode'){$f.Add('FLUX2-Workflow')}
$text=Get-ChildItem $PackageRoot -Recurse -File|Where-Object Extension -in '.ps1','.psm1','.py','.json','.md','.txt'|ForEach-Object{Get-Content $_.FullName -Raw};if(($text-join"`n")-match'(?i)sk-[a-z0-9]{20,}|C:\\Users\\[A-Za-z0-9._-]+'){$f.Add('Secret oder persönlicher Pfad')}
$python=Get-Command python -ErrorAction SilentlyContinue;if($null-eq$python){$f.Add('Python fehlt')}else{& $python.Source -B -m unittest (Join-Path $PackageRoot 'Tests/test_image_adapter.py') 2>&1|Out-Null;if($LASTEXITCODE-ne 0){$f.Add('Workflowadapter-Synthetiktests')}}
$moduleText=Get-Content (Join-Path $PackageRoot 'OpenWebUIImagePack.psm1') -Raw
if(-not $moduleText.Contains('Tool-ID-Kollision') -or -not $moduleText.Contains('profileBindings')){$f.Add('Kollisions-/Rollbackvertrag')}
@{version='1.9.2';action='SelfTest';passed=($f.Count-eq 0);checks=9;failures=@($f)}|ConvertTo-Json -Depth 10;if($f.Count){throw($f-join'; ')}
