[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$config='{"moduleRoot":"C:\\KI-Stack\\modules\\cutover","installationMarker":"C:\\KI-Stack\\modules\\cutover\\installation.json","reportRoot":"C:\\KI-Stack\\reports\\cutover","healthReportPath":"C:\\KI-Stack\\reports\\cutover\\Health-latest.json","acceptanceReportPath":"C:\\KI-Stack\\reports\\cutover\\Acceptance-latest.json","healthTimeoutSeconds":45,"startupGraceSeconds":5,"requireLiveEndpointsDuringExecute":false,"endpoints":[{"name":"SearXNG","kind":"searxng","url":"http://localhost/searxng/search?q=ki-stack&format=json"},{"name":"Open WebUI","kind":"web","url":"http://127.0.0.1:8080"},{"name":"LM Studio","kind":"openai","url":"http://127.0.0.1:1234/v1/models"},{"name":"ComfyUI","kind":"json","url":"http://127.0.0.1:8188/system_stats"}],"startScripts":{"searxng":"C:\\KI-Stack\\modules\\integration\\Start-KIStack-SearXNG.cmd","lmStudio":"C:\\KI-Stack\\modules\\applications\\Start-KIStack-LMStudio.cmd","openWebUI":"C:\\KI-Stack\\modules\\integration\\Start-KIStack-OpenWebUI-WithSearch.cmd","comfyUI":"C:\\KI-Stack\\modules\\comfyui\\Start-KIStack-ComfyUI.cmd"},"stopScripts":{"applications":"C:\\KI-Stack\\modules\\applications\\Stop-KIStack-Applications.cmd","searxng":"C:\\KI-Stack\\modules\\integration\\Stop-KIStack-SearXNG.cmd","comfyUI":"C:\\KI-Stack\\modules\\comfyui\\Stop-KIStack-ComfyUI.cmd"}}'|ConvertFrom-Json -Depth 50
function Start-Managed([string]$Name,[string]$Path){
 if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){throw "Startskript fehlt: $Path"}
 Write-Host ("Starte {0}: {1}" -f $Name,$Path)
 Start-Process -FilePath $env:ComSpec -ArgumentList @('/D','/C','call',('"'+$Path+'"')) -WindowStyle Minimized|Out-Null
}
Start-Managed 'SearXNG' ([string]$config.startScripts.searxng)
Start-Sleep -Seconds 2
Start-Managed 'ComfyUI' ([string]$config.startScripts.comfyUI)
Start-Managed 'LM Studio' ([string]$config.startScripts.lmStudio)
Start-Sleep -Seconds 3
Start-Managed 'Open WebUI' ([string]$config.startScripts.openWebUI)
Start-Sleep -Seconds ([int]$config.startupGraceSeconds)
$healthScript=Join-Path $PSScriptRoot 'Test-KIStack-Health.ps1'
& $healthScript -TimeoutSeconds 10