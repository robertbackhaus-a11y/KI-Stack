[CmdletBinding()]
param(
    [string]$PackageRoot=$PSScriptRoot,
    [switch]$RequireAllDeclared,
    [switch]$ThrowOnFailure
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$contract=Get-Content -LiteralPath (Join-Path $PackageRoot 'Contracts/REQUIRED-PAYLOADS.json') -Raw|ConvertFrom-Json -Depth 30
$components=Get-Content -LiteralPath (Join-Path $PackageRoot 'Contracts/COMPONENTS.json') -Raw|ConvertFrom-Json -Depth 30
$failures=[Collections.Generic.List[string]]::new()
$checked=[Collections.Generic.List[object]]::new()
$selected=@($contract.payloads|Where-Object{$RequireAllDeclared-or[bool]$_.required})

foreach($payload in $selected){
    $directory=Join-Path $PackageRoot ('Payload/'+[string]$payload.key)
    $expected=Join-Path $directory ([string]$payload.file)
    $archives=@(if(Test-Path -LiteralPath $directory -PathType Container){Get-ChildItem -LiteralPath $directory -File -Filter '*.zip'})
    $valid=(Test-Path -LiteralPath $expected -PathType Leaf)-and(Get-Item -LiteralPath $expected).Length-gt0-and$archives.Count-eq1-and$archives[0].Name-eq[string]$payload.file
    if(-not$valid){$failures.Add("Payload $($payload.key) fehlt oder ist nicht eindeutig: Payload/$($payload.key)/$($payload.file)")}
    $checked.Add([pscustomobject]@{key=[string]$payload.key;file=[string]$payload.file;required=[bool]$payload.required;valid=$valid})|Out-Null
}

$declaredKeys=@($contract.payloads|ForEach-Object{[string]$_.key})
foreach($component in @($components.components|Where-Object{
    [bool]$_.installable-and(
        -not($_.PSObject.Properties.Name-contains'optional')-or-not[bool]$_.optional
    )
})){
    $source=[string]$component.source
    if($source-notmatch'^Payload/([^/]+)$'){$failures.Add("Installierbare Komponente $($component.id) besitzt keinen eindeutigen Payload-Pfad: $source");continue}
    if($declaredKeys-notcontains$Matches[1]){$failures.Add("Installierbare Komponente $($component.id) fehlt im Pflicht-Payloadvertrag: $source")}
}

$result=[pscustomobject]@{passed=($failures.Count-eq0);checked=$checked.Count;failures=@($failures);payloads=@($checked)}
if($ThrowOnFailure-and-not$result.passed){throw('Pflicht-Payloadprüfung fehlgeschlagen: '+($result.failures-join'; '))}
$result
