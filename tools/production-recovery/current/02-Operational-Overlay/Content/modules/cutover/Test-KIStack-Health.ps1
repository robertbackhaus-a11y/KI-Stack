[CmdletBinding()]
param([int]$TimeoutSeconds=10)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$config = '{"moduleRoot":"C:\\KI-Stack\\modules\\cutover","installationMarker":"C:\\KI-Stack\\modules\\cutover\\installation.json","reportRoot":"C:\\KI-Stack\\reports\\cutover","healthReportPath":"C:\\KI-Stack\\reports\\cutover\\Health-latest.json","acceptanceReportPath":"C:\\KI-Stack\\reports\\cutover\\Acceptance-latest.json","healthTimeoutSeconds":45,"startupGraceSeconds":5,"requireLiveEndpointsDuringExecute":false,"endpoints":[{"name":"SearXNG","kind":"searxng","url":"http://localhost/searxng/search?q=ki-stack&format=json"},{"name":"Open WebUI","kind":"web","url":"http://127.0.0.1:8080"},{"name":"LM Studio","kind":"openai","url":"http://127.0.0.1:1234/v1/models"},{"name":"ComfyUI","kind":"json","url":"http://127.0.0.1:8188/system_stats"}],"startScripts":{"searxng":"C:\\KI-Stack\\modules\\integration\\Start-KIStack-SearXNG.cmd","lmStudio":"C:\\KI-Stack\\modules\\applications\\Start-KIStack-LMStudio.cmd","openWebUI":"C:\\KI-Stack\\modules\\integration\\Start-KIStack-OpenWebUI-WithSearch.cmd","comfyUI":"C:\\KI-Stack\\modules\\comfyui\\Start-KIStack-ComfyUI.cmd"},"stopScripts":{"applications":"C:\\KI-Stack\\modules\\applications\\Stop-KIStack-Applications.cmd","searxng":"C:\\KI-Stack\\modules\\integration\\Stop-KIStack-SearXNG.cmd","comfyUI":"C:\\KI-Stack\\modules\\comfyui\\Stop-KIStack-ComfyUI.cmd"}}' | ConvertFrom-Json -Depth 50
$results = [System.Collections.Generic.List[object]]::new()
foreach($endpoint in @($config.endpoints)){
 $sw=[Diagnostics.Stopwatch]::StartNew();$ok=$false;$detail=''
 try{
  if([string]$endpoint.kind -in @('searxng','openai','json')){
   $response=Invoke-RestMethod -Uri ([string]$endpoint.url) -Method Get -TimeoutSec $TimeoutSeconds -ErrorAction Stop
   if([string]$endpoint.kind -eq 'searxng'){$ok=($null-ne $response.PSObject.Properties['results'])}
   elseif([string]$endpoint.kind -eq 'openai'){$ok=($null-ne $response.PSObject.Properties['data'])}
   else{$ok=($null-ne $response)}
  }else{
   $response=Invoke-WebRequest -Uri ([string]$endpoint.url) -Method Get -TimeoutSec $TimeoutSeconds -SkipHttpErrorCheck -ErrorAction Stop
   $ok=([int]$response.StatusCode-ge 200 -and [int]$response.StatusCode-lt 500)
  }
  $detail=if($ok){'Endpoint erreichbar.'}else{'Antwortvertrag nicht erfüllt.'}
 }catch{$detail=$_.Exception.Message}finally{$sw.Stop()}
 [void]$results.Add([pscustomobject][ordered]@{name=[string]$endpoint.name;kind=[string]$endpoint.kind;url=[string]$endpoint.url;reachable=$ok;durationMs=[int64]$sw.ElapsedMilliseconds;detail=$detail})
}
$report=[pscustomobject][ordered]@{generatedAt=(Get-Date).ToString('o');allReachable=(@($results|Where-Object{-not [bool]$_.reachable}).Count-eq 0);endpoints=@($results)}
$reportRoot=[string]$config.reportRoot
if(-not(Test-Path -LiteralPath $reportRoot -PathType Container)){New-Item -ItemType Directory -Path $reportRoot -Force|Out-Null}
$json=$report|ConvertTo-Json -Depth 50
Set-Content -LiteralPath ([string]$config.healthReportPath) -Value $json -Encoding UTF8
$json
if(-not [bool]$report.allReachable){exit 1}
exit 0