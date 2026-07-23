[CmdletBinding()]param([string]$PackageRoot=$PSScriptRoot)
$w=Get-Content(Join-Path $PackageRoot 'Workflow/FLUX2-Klein-9B-OpenWebUI-API-FLAT.json')-Raw|ConvertFrom-Json -AsHashtable
$expected=@{'92'='CLIPTextEncode';'84'='PrimitiveInt';'85'='PrimitiveInt';'86'='RandomNoise';'87'='UNETLoader';'88'='CLIPLoader';'89'='VAELoader'};$fail=@($expected.Keys|Where-Object{$w[$_].class_type-ne$expected[$_]})
@{version='1.9.2';passed=($fail.Count-eq 0);nodes=$expected.Count;failures=$fail}|ConvertTo-Json;if($fail.Count){throw'Workflow-Fixture fehlgeschlagen.'}
