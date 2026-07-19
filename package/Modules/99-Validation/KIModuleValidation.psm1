Set-StrictMode -Version Latest

function Test-KIModuleValidation {
    param([Parameter(Mandatory)][object]$Context)

    return [pscustomobject][ordered]@{
        success = $true
        skipped = $false
        message = 'Kernel-Validierungsmodul ist verfügbar.'
        data = $null
    }
}

function Install-KIModuleValidation {
    param([Parameter(Mandatory)][object]$Context)

    return [pscustomobject][ordered]@{
        success = $true
        skipped = $true
        message = 'Validierungsmodul führt keine Installation durch.'
        data = $null
    }
}

function Validate-KIModuleValidation {
    param([Parameter(Mandatory)][object]$Context)

    if ($null -eq $Context.Transaction) {
        throw 'Validation-Kontext enthält keine Transaktion.'
    }

    $transactionModules = @($Context.Transaction.modules)
    $failedModuleIds = [System.Collections.Generic.List[string]]::new()
    $invalidModuleEntries = [System.Collections.Generic.List[string]]::new()

    foreach ($moduleEntry in $transactionModules) {
        if ($null -eq $moduleEntry) {
            [void]$invalidModuleEntries.Add('<null>')
            continue
        }

        $idProperty = $moduleEntry.PSObject.Properties['id']
        $statusProperty = $moduleEntry.PSObject.Properties['status']

        if ($null -eq $idProperty -or $null -eq $statusProperty) {
            [void]$invalidModuleEntries.Add(
                ($moduleEntry | ConvertTo-Json -Depth 10 -Compress)
            )
            continue
        }

        if ([string]$statusProperty.Value -eq 'Failed') {
            [void]$failedModuleIds.Add([string]$idProperty.Value)
        }
    }

    $validationPassed = (
        $failedModuleIds.Count -eq 0 -and
        $invalidModuleEntries.Count -eq 0
    )

    return [pscustomobject][ordered]@{
        success = $validationPassed
        skipped = $false
        message = if ($invalidModuleEntries.Count -gt 0) {
            'Ungültige Modulstatus-Einträge erkannt.'
        } elseif ($failedModuleIds.Count -gt 0) {
            'Mindestens ein Modul ist fehlgeschlagen.'
        } else {
            'Keine fehlgeschlagenen Module erkannt.'
        }
        data = [pscustomobject][ordered]@{
            failedModuleIds = @($failedModuleIds)
            invalidModuleEntries = @($invalidModuleEntries)
            checkedModuleCount = $transactionModules.Count
        }
    }
}

Export-ModuleMember -Function *
