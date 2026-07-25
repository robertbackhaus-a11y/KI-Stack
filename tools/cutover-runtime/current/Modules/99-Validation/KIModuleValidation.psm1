Set-StrictMode -Version Latest

function Get-KIValidationPropertyValue {
    param(
        [AllowNull()][object]$InputObject,
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()][object]$DefaultValue = $null
    )
    if ($null -eq $InputObject) { return $DefaultValue }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $DefaultValue }
    return $property.Value
}

function Get-KIValidationTextValue {
    param(
        [AllowNull()][object]$InputObject,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$DefaultValue
    )
    $value = [string](Get-KIValidationPropertyValue -InputObject $InputObject -Name $Name -DefaultValue $DefaultValue)
    if ([string]::IsNullOrWhiteSpace($value)) { return $DefaultValue }
    return $value
}

function Test-KIModuleValidation {
    param([Parameter(Mandatory)][object]$Context)
    return [pscustomobject][ordered]@{success=$true;skipped=$false;message='Abschluss- und Transaktionsvalidierung ist verfügbar.';data=$null}
}

function Install-KIModuleValidation {
    param([Parameter(Mandatory)][object]$Context)
    return [pscustomobject][ordered]@{success=$true;skipped=$true;message='Validierungsmodul führt keine Installation durch.';data=$null}
}

function Validate-KIModuleValidation {
    param([Parameter(Mandatory)][object]$Context)

    $transactionProperty = $Context.PSObject.Properties['Transaction']
    if ($null -eq $transactionProperty -or $null -eq $transactionProperty.Value) {
        throw 'Validation-Kontext enthält keine Transaktion.'
    }
    $transaction = $transactionProperty.Value
    $modulesValue = Get-KIValidationPropertyValue -InputObject $transaction -Name 'modules' -DefaultValue @()
    $transactionModules = @($modulesValue)
    $transactionId = Get-KIValidationTextValue -InputObject $transaction -Name 'transactionId' -DefaultValue 'UNSPECIFIED'
    $mode = Get-KIValidationTextValue -InputObject $transaction -Name 'mode' -DefaultValue 'Unknown'

    $failedModuleIds = [System.Collections.Generic.List[string]]::new()
    $invalidModuleEntries = [System.Collections.Generic.List[string]]::new()
    $incompleteModuleIds = [System.Collections.Generic.List[string]]::new()
    $reportModules = [System.Collections.Generic.List[object]]::new()

    foreach ($moduleEntry in $transactionModules) {
        if ($null -eq $moduleEntry) {
            [void]$invalidModuleEntries.Add('<null>')
            [void]$reportModules.Add([pscustomobject][ordered]@{id='<null>';status='Invalid'})
            continue
        }

        $idProperty = $moduleEntry.PSObject.Properties['id']
        $statusProperty = $moduleEntry.PSObject.Properties['status']
        if ($null -eq $idProperty -or $null -eq $statusProperty) {
            [void]$invalidModuleEntries.Add(($moduleEntry | ConvertTo-Json -Depth 10 -Compress))
            $safeId = if ($null -ne $idProperty) { [string]$idProperty.Value } else { '<missing>' }
            $safeStatus = if ($null -ne $statusProperty) { [string]$statusProperty.Value } else { 'Invalid' }
            [void]$reportModules.Add([pscustomobject][ordered]@{id=$safeId;status=$safeStatus})
            continue
        }

        $id = [string]$idProperty.Value
        $status = [string]$statusProperty.Value
        [void]$reportModules.Add([pscustomobject][ordered]@{id=$id;status=$status})
        if ($status -eq 'Failed') { [void]$failedModuleIds.Add($id) }
        if ($id -ne 'KIModuleValidation' -and $status -notin @('Validated','Completed','Disabled')) {
            [void]$incompleteModuleIds.Add($id)
        }
    }

    $passed = (
        $failedModuleIds.Count -eq 0 -and
        $invalidModuleEntries.Count -eq 0 -and
        $incompleteModuleIds.Count -eq 0
    )

    $report = [pscustomobject][ordered]@{
        schemaVersion = '1.0'
        generatedAt = (Get-Date).ToString('o')
        transactionId = $transactionId
        mode = $mode
        status = if ($passed) { 'Accepted' } else { 'Rejected' }
        failedModuleIds = @($failedModuleIds)
        incompleteModuleIds = @($incompleteModuleIds)
        invalidModuleEntries = @($invalidModuleEntries)
        modules = @($reportModules)
    }

    $reportPaths = [System.Collections.Generic.List[string]]::new()
    $transactionDirectory = [string](Get-KIValidationPropertyValue -InputObject $Context -Name 'TransactionDirectory' -DefaultValue '')
    if (-not [string]::IsNullOrWhiteSpace($transactionDirectory)) {
        if (-not (Test-Path -LiteralPath $transactionDirectory -PathType Container)) {
            New-Item -ItemType Directory -Path $transactionDirectory -Force | Out-Null
        }
        $transactionReportPath = Join-Path $transactionDirectory 'acceptance-report.json'
        $report | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $transactionReportPath -Encoding UTF8
        [void]$reportPaths.Add($transactionReportPath)
    }

    $config = Get-KIValidationPropertyValue -InputObject $Context -Name 'Config' -DefaultValue $null
    $validationConfig = Get-KIValidationPropertyValue -InputObject $config -Name 'validation' -DefaultValue $null
    $latestPath = [string](Get-KIValidationPropertyValue -InputObject $validationConfig -Name 'latestReportPath' -DefaultValue '')
    if (-not [string]::IsNullOrWhiteSpace($latestPath)) {
        $parent = Split-Path -Parent $latestPath
        if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        $report | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $latestPath -Encoding UTF8
        [void]$reportPaths.Add($latestPath)
    }

    $message = if ($passed) {
        'Alle freigegebenen Module sind abgeschlossen; Abnahmebericht wurde erzeugt.'
    }
    elseif ($invalidModuleEntries.Count -gt 0) {
        'Ungültige Modulstatus-Einträge erkannt.'
    }
    elseif ($failedModuleIds.Count -gt 0) {
        'Mindestens ein Modul ist fehlgeschlagen.'
    }
    else {
        'Mindestens ein Modul ist nicht abgeschlossen.'
    }

    return [pscustomobject][ordered]@{
        success = $passed
        skipped = $false
        message = $message
        data = [pscustomobject][ordered]@{
            transactionId = $transactionId
            mode = $mode
            failedModuleIds = @($failedModuleIds)
            incompleteModuleIds = @($incompleteModuleIds)
            invalidModuleEntries = @($invalidModuleEntries)
            checkedModuleCount = $transactionModules.Count
            reportPaths = @($reportPaths)
            report = $report
        }
    }
}

Export-ModuleMember -Function *
