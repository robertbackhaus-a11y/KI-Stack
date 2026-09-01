Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:KICompleteDefaultTargetRoot = 'C:\KI-Stack'
$script:KICompletePathContractVersion = '1.0'

function ConvertTo-KICompleteCanonicalPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { throw "$Name darf nicht leer sein." }
    if (-not [IO.Path]::IsPathFullyQualified($Path)) { throw "$Name muss ein absoluter Pfad sein: $Path" }

    try { $fullPath = [IO.Path]::GetFullPath($Path) }
    catch { throw "$Name ist kein gültiger Pfad: $Path", $_.Exception }

    $root = [IO.Path]::GetPathRoot($fullPath)
    if (-not [string]::Equals($fullPath,$root,[StringComparison]::OrdinalIgnoreCase)) {
        $fullPath = $fullPath.TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    }
    $fullPath
}

function Test-KICompletePathContainsReparsePoint {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $candidate = $Path
    while (-not [string]::IsNullOrWhiteSpace($candidate)) {
        if (Test-Path -LiteralPath $candidate) {
            $item = Get-Item -LiteralPath $candidate -Force -ErrorAction Stop
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $true }
        }
        $parent = Split-Path -Parent $candidate
        if ([string]::IsNullOrWhiteSpace($parent) -or [string]::Equals($parent,$candidate,[StringComparison]::OrdinalIgnoreCase)) { break }
        $candidate = $parent
    }
    $false
}

function Assert-KICompleteSafeTransactionId {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TransactionId)

    if ([string]::IsNullOrWhiteSpace($TransactionId)) { throw 'TransactionId darf nicht leer sein.' }
    if ($TransactionId -in @('.','..') -or
        [IO.Path]::IsPathRooted($TransactionId) -or
        $TransactionId -match '[:\\/]' -or
        $TransactionId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$') {
        throw "TransactionId muss ein einzelnes sicheres Pfadsegment sein: $TransactionId"
    }
}

function Test-KICompleteSameRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$First,
        [Parameter(Mandatory)][string]$Second
    )

    $firstCanonical = ConvertTo-KICompleteCanonicalPath -Path $First -Name 'First'
    $secondCanonical = ConvertTo-KICompleteCanonicalPath -Path $Second -Name 'Second'
    [string]::Equals($firstCanonical,$secondCanonical,[StringComparison]::OrdinalIgnoreCase)
}

function New-KICompletePathContext {
    [CmdletBinding()]
    param(
        [string]$TargetRoot = $script:KICompleteDefaultTargetRoot,
        [string]$PackageRoot = (Split-Path -Parent $PSScriptRoot),
        [string]$DesktopPath = ([Environment]::GetFolderPath('Desktop')),
        [string]$TransactionId,
        [switch]$Mutating
    )

    $canonicalTargetRoot = ConvertTo-KICompleteCanonicalPath -Path $TargetRoot -Name 'TargetRoot'
    $canonicalPackageRoot = ConvertTo-KICompleteCanonicalPath -Path $PackageRoot -Name 'PackageRoot'
    $canonicalDesktopPath = if ([string]::IsNullOrWhiteSpace($DesktopPath)) { '' } else { ConvertTo-KICompleteCanonicalPath -Path $DesktopPath -Name 'DesktopPath' }

    if ($Mutating) {
        if ($canonicalTargetRoot.StartsWith('\\',[StringComparison]::Ordinal)) {
            throw "UNC-Pfade werden für mutierende Complete-Installer-Kontexte nicht unterstützt: $canonicalTargetRoot"
        }
        $targetPathRoot = [IO.Path]::GetPathRoot($canonicalTargetRoot)
        if ([string]::Equals($canonicalTargetRoot,$targetPathRoot,[StringComparison]::OrdinalIgnoreCase)) {
            throw "Eine Laufwerkswurzel ist als mutierendes TargetRoot nicht zulässig: $canonicalTargetRoot"
        }
        if (Test-KICompletePathContainsReparsePoint -Path $canonicalTargetRoot) {
            throw "TargetRoot oder ein vorhandener Elternpfad ist ein Junction-, symbolischer oder anderer Reparse-Punkt: $canonicalTargetRoot"
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($TransactionId)) { Assert-KICompleteSafeTransactionId -TransactionId $TransactionId }

    # Path calculation must remain pure even when the target drive is not mounted yet.
    # Join-Path consults the PowerShell drive provider; Path.Combine does not.
    $stateRoot = [IO.Path]::Combine($canonicalTargetRoot,'state','complete-installer')
    $transactionBaseRoot = [IO.Path]::Combine($stateRoot,'transactions')
    $backupRoot = [IO.Path]::Combine($canonicalTargetRoot,'backups','complete-installer')
    $logRoot = [IO.Path]::Combine($canonicalTargetRoot,'logs','complete-installer')
    $transactionRoot = $null
    $transactionBackupRoot = $null
    $transactionLogRoot = $null
    $payloadRoot = $null
    $tempRoot = $null
    if (-not [string]::IsNullOrWhiteSpace($TransactionId)) {
        $transactionRoot = [IO.Path]::Combine($transactionBaseRoot,$TransactionId)
        $transactionBackupRoot = [IO.Path]::Combine($backupRoot,$TransactionId)
        $transactionLogRoot = [IO.Path]::Combine($logRoot,$TransactionId)
        $payloadRoot = [IO.Path]::Combine($transactionRoot,'payload')
        $tempRoot = [IO.Path]::Combine($transactionRoot,'staging')
    }

    [pscustomobject][ordered]@{
        PathContractVersion = $script:KICompletePathContractVersion
        IsMutating = [bool]$Mutating
        TargetRoot = $canonicalTargetRoot
        StateRoot = $stateRoot
        TransactionBaseRoot = $transactionBaseRoot
        BackupRoot = $backupRoot
        LogRoot = $logRoot
        ModuleRoot = [IO.Path]::Combine($canonicalTargetRoot,'modules')
        PythonRoot = [IO.Path]::Combine($canonicalTargetRoot,'python')
        DataRoot = [IO.Path]::Combine($canonicalTargetRoot,'data')
        TransactionId = if ([string]::IsNullOrWhiteSpace($TransactionId)) { $null } else { $TransactionId }
        TransactionRoot = $transactionRoot
        TransactionBackupRoot = $transactionBackupRoot
        TransactionLogRoot = $transactionLogRoot
        PayloadRoot = $payloadRoot
        TempRoot = $tempRoot
        PackageRoot = $canonicalPackageRoot
        DesktopPath = $canonicalDesktopPath
    }
}

function Initialize-KICompletePathContextDirectories {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][object]$Context)

    if (-not [bool]$Context.IsMutating) { throw 'Verzeichnisse dürfen nur für einen mutierenden Path-Kontext erzeugt werden.' }
    $paths = [Collections.Generic.List[string]]::new()
    foreach ($propertyName in @('TargetRoot','StateRoot','TransactionBaseRoot','BackupRoot','LogRoot','ModuleRoot','PythonRoot','DataRoot','TransactionRoot','TransactionBackupRoot','TransactionLogRoot','PayloadRoot','TempRoot')) {
        $property = $Context.PSObject.Properties[$propertyName]
        if ($null -eq $property -or [string]::IsNullOrWhiteSpace([string]$property.Value)) { continue }
        $path = [string]$property.Value
        if (-not (Test-Path -LiteralPath $path) -and $PSCmdlet.ShouldProcess($path,'Create directory')) {
            New-Item -ItemType Directory -Path $path -Force | Out-Null
            $paths.Add($path)
        }
    }
    @($paths)
}

Export-ModuleMember -Function New-KICompletePathContext,Test-KICompleteSameRoot,Initialize-KICompletePathContextDirectories
