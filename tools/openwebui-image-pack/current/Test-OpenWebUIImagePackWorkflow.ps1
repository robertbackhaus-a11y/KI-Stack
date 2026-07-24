[CmdletBinding()]param([string]$PackageRoot=$PSScriptRoot)
$w=Get-Content(Join-Path $PackageRoot 'Workflow/FLUX2-Klein-9B-OpenWebUI-API-FLAT.json')-Raw|ConvertFrom-Json -AsHashtable
$expected=@{'92'='CLIPTextEncode';'84'='PrimitiveInt';'85'='PrimitiveInt';'86'='RandomNoise';'87'='UNETLoader';'88'='CLIPLoader';'89'='VAELoader'};$fail=@($expected.Keys|Where-Object{$w[$_].class_type-ne$expected[$_]})
$pony=Get-Content(Join-Path $PackageRoot 'Workflow/PONY-SDXL-OpenWebUI-API.json')-Raw|ConvertFrom-Json -AsHashtable
if($pony['1'].inputs.ckpt_name-ne'ponyDiffusionV6XL_v6StartWithThisOne.safetensors'){$fail+='Pony checkpoint'}
if($pony['2'].inputs.stop_at_clip_layer-ne-2){$fail+='Pony CLIP skip'}
if($pony['5'].inputs.width-ne1024-or$pony['5'].inputs.height-ne1024){$fail+='Pony resolution'}
if($pony['6'].inputs.steps-ne40-or$pony['6'].inputs.cfg-ne3.1-or$pony['6'].inputs.sampler_name-ne'euler'-or$pony['6'].inputs.scheduler-ne'normal'){$fail+='Pony sampler contract'}
@{version='1.10.0';passed=($fail.Count-eq 0);fluxNodes=$expected.Count;ponyNodes=$pony.Count;failures=$fail}|ConvertTo-Json;if($fail.Count){throw'Workflow-Fixture fehlgeschlagen.'}
