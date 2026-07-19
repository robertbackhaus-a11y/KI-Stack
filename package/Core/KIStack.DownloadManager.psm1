Set-StrictMode -Version Latest

function Get-KIDownloadCachePath {
    param(
        [Parameter(Mandatory)][object]$Context,
        [Parameter(Mandatory)][string]$FileName
    )

    return Join-Path ([string]$Context.Config.cacheRoot) $FileName
}

function Test-KIFileHash {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExpectedSha256
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }

    $actualHash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    return $actualHash.Equals(
        $ExpectedSha256,
        [System.StringComparison]::OrdinalIgnoreCase
    )
}

function Invoke-KIDownload {
    param(
        [Parameter(Mandatory)][object]$Context,
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$FileName,
        [string]$ExpectedSha256
    )

    $destination = Get-KIDownloadCachePath -Context $Context -FileName $FileName

    if ($Context.Mode -eq 'DryRun') {
        return [pscustomobject][ordered]@{
            success = $true
            skipped = $false
            message = 'Dry-Run: Download wurde geplant.'
            data = [pscustomobject][ordered]@{
                uri = $Uri
                destination = $destination
                expectedSha256 = $ExpectedSha256
            }
        }
    }

    if (-not [bool]$Context.Config.defaults.allowNetworkDownloads) {
        throw 'Netzwerkdownloads sind in der Kernel-Konfiguration nicht freigegeben.'
    }

    $parent = Split-Path -Parent $destination
    New-Item -ItemType Directory -Path $parent -Force | Out-Null

    Invoke-WebRequest -Uri $Uri -OutFile $destination -UseBasicParsing

    if ($ExpectedSha256 -and -not (
        Test-KIFileHash -Path $destination -ExpectedSha256 $ExpectedSha256
    )) {
        Remove-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue
        throw "SHA256-Prüfung fehlgeschlagen: $FileName"
    }

    return [pscustomobject][ordered]@{
        success = $true
        skipped = $false
        message = 'Download abgeschlossen.'
        data = [pscustomobject][ordered]@{
            uri = $Uri
            destination = $destination
            sha256 = if (Test-Path -LiteralPath $destination) {
                (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
            } else {
                $null
            }
        }
    }
}

Export-ModuleMember -Function *
