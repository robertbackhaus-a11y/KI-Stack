[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference='Continue'
if($PSVersionTable.PSEdition -ne 'Core' -or $PSVersionTable.PSVersion.Major -lt 7){throw 'PowerShell 7 ist erforderlich; Windows PowerShell wird nicht unterstützt.'}
& (Join-Path $PSScriptRoot 'Get-KIStackStatus.ps1')
$statusExit=$LASTEXITCODE
Write-Host ''
Write-Host ("Tatsächlicher Exitcode: {0}" -f $statusExit) -ForegroundColor Cyan
Write-Host ''
Write-Host 'Zum Schließen eine beliebige Taste drücken . . .'
[void][Console]::ReadKey($true)
exit $statusExit
