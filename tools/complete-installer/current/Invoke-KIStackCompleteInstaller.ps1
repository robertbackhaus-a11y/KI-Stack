# -Mode RollbackOperations (Mode-Rollback-P1): restores ONLY the operating-system-level changes
# InstallOperations itself makes -- LM Studio competing-autostart registry values, the three
# KI-Stack Desktop shortcuts, and any KI-Stack-owned Docker container restart policy -- from the
# most recent operations-latest backup. It is NOT, and has never been, a full installation
# rollback: no installed component, no OpenWebUI/ComfyUI/Integration/RAG/Agent-Visual-Ballistics
# packs/Codex Local/Foundation Runtime/Python-Git, no WSL/winget state, no user data, models,
# Knowledge, or Code-Interpreter configuration is touched. 'Rollback' remains a deprecated
# alias calling the exact same Restore-KICompleteOperations, but -- since it is a pre-existing
# public CLI surface, unlike this new name -- deliberately keeps its historical flat return
# shape and its historical non-throwing, exit-0 behavior when no backup state exists (neither
# is a security boundary); 'RollbackOperations' gets the new structured, fail-closed contract
# instead. See Contracts/ROLLBACK.md for the exact table.
[CmdletBinding()]
param([ValidateSet('Audit','Install','Upgrade','Repair','Validate','Rollback','RollbackOperations','Start','Stop')][string]$Mode='Audit',[string]$TargetRoot='C:\KI-Stack',[string]$TransactionId,[switch]$Resume,[switch]$DryRun,[switch]$EnableOpenWebUIBallistics,[Security.SecureString]$OpenWebUIApiToken,[string[]]$ReplayComponent=@())
Set-StrictMode -Version Latest;$ErrorActionPreference='Stop'
if($PSVersionTable.PSEdition -ne 'Core' -or $PSVersionTable.PSVersion.Major -lt 7){throw 'PowerShell 7 ist erforderlich; Windows PowerShell wird nicht unterstützt.'}
Import-Module (Join-Path $PSScriptRoot 'CompleteInstaller.psm1') -Force
Invoke-KIStackCompleteInstaller -Mode $Mode -PackageRoot $PSScriptRoot -TargetRoot $TargetRoot -TransactionId $TransactionId -Resume:$Resume -DryRun:$DryRun -EnableOpenWebUIBallistics:$EnableOpenWebUIBallistics -OpenWebUIApiToken $OpenWebUIApiToken -ReplayComponent $ReplayComponent | ConvertTo-Json -Depth 100
