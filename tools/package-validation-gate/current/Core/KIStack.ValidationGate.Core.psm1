Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-KIStackPwsh7 {
    [CmdletBinding()]
    param()

    $candidates = [System.Collections.Generic.List[string]]::new()
    if ($PSVersionTable.PSEdition -eq 'Core' -and $PSVersionTable.PSVersion.Major -ge 7) {
        $candidates.Add((Get-Process -Id $PID).Path)
    }

    $cmd = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if ($cmd) { $candidates.Add($cmd.Source) }

    foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA)) {
        if ([string]::IsNullOrWhiteSpace($base)) { continue }
        foreach ($relative in @('PowerShell\7\pwsh.exe', 'Microsoft\PowerShell\7\pwsh.exe')) {
            $candidates.Add((Join-Path $base $relative))
        }
    }

    foreach ($candidate in $candidates | Select-Object -Unique) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            try {
                $versionText = & $candidate -NoProfile -NonInteractive -Command '$PSVersionTable.PSVersion.Major' 2>$null
                if ([int]$versionText -ge 7) { return (Resolve-Path -LiteralPath $candidate).Path }
            } catch { }
        }
    }
    throw 'PowerShell 7 (pwsh.exe) wurde nicht gefunden.'
}

function Resolve-KIStackPython {
    [CmdletBinding()]
    param()

    $candidates = [System.Collections.Generic.List[object]]::new()
    foreach ($name in @('python.exe', 'python3.exe', 'py.exe')) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd) {
            $args = if ($name -eq 'py.exe') { @('-3') } else { @() }
            $candidates.Add([pscustomobject]@{ Path = $cmd.Source; PrefixArgs = $args })
        }
    }
    foreach ($candidate in $candidates) {
        try {
            $result = & $candidate.Path @($candidate.PrefixArgs) -c 'import sys; print(sys.version_info.major)' 2>$null
            if ([int]$result -eq 3) { return $candidate }
        } catch { }
    }
    throw 'Python 3 wurde nicht gefunden.'
}

function Invoke-KIStackProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter()][string[]]$ArgumentList = @(),
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][string]$StdOutPath,
        [Parameter(Mandatory)][string]$StdErrPath,
        [Parameter()][int]$TimeoutSeconds = 900
    )

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FilePath
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    foreach ($argument in $ArgumentList) {
        $null = $psi.ArgumentList.Add([string]$argument)
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $psi
    if (-not $process.Start()) { throw "Prozess konnte nicht gestartet werden: $FilePath" }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        try { $process.Kill($true) } catch { }
        throw "Prozess-Timeout nach $TimeoutSeconds Sekunden: $FilePath"
    }
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    [System.IO.File]::WriteAllText($StdOutPath, $stdout, [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($StdErrPath, $stderr, [System.Text.UTF8Encoding]::new($false))
    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        StdOut = $stdout
        StdErr = $stderr
    }
}

function Test-KIStackPowerShellFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RootPath,
        [Parameter(Mandatory)][string[]]$ForbiddenCommands
    )

    $results = [System.Collections.Generic.List[object]]::new()
    $parseErrors = [System.Collections.Generic.List[string]]::new()
    $forbidden = [System.Collections.Generic.List[string]]::new()
    $knownPatterns = [System.Collections.Generic.List[string]]::new()

    $files = Get-ChildItem -LiteralPath $RootPath -Recurse -File | Where-Object { $_.Extension -in @('.ps1', '.psm1', '.psd1') }
    foreach ($file in $files) {
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
        foreach ($error in $errors) {
            $parseErrors.Add("$($file.FullName):$($error.Extent.StartLineNumber): $($error.Message)")
        }

        $commandAsts = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true)
        foreach ($commandAst in $commandAsts) {
            $name = $commandAst.GetCommandName()
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            if ($ForbiddenCommands -contains $name.ToLowerInvariant()) {
                $forbidden.Add("$($file.FullName):$($commandAst.Extent.StartLineNumber): $name")
            }
        }

        $text = Get-Content -LiteralPath $file.FullName -Raw
        $patterns = @(
            @{ Id = 'REG-004-HASHTABLE-KEYS'; Regex = '\$expected\.Key\b' },
            @{ Id = 'REG-005-DOUBLE-BACKSLASH-PREFIX'; Regex = '\.TrimEnd\(\s*[''"]\\\\[''"]\s*\)\s*\+\s*[''"]\\\\[''"]' },
            @{ Id = 'REG-006-BROAD-GIT-TEXT-SCAN'; Regex = '-notmatch\s+[''"][^''"]*\\bgit\\b[^''"]*[''"]' }
        )
        foreach ($pattern in $patterns) {
            if ($text -match $pattern.Regex) {
                $knownPatterns.Add("$($pattern.Id): $($file.FullName)")
            }
        }
    }

    $results.Add([pscustomobject]@{ name = 'PowerShell parser and AST'; passed = ($parseErrors.Count -eq 0); detail = ($parseErrors -join ' | ') })
    $results.Add([pscustomobject]@{ name = 'Forbidden repository commands absent'; passed = ($forbidden.Count -eq 0); detail = ($forbidden -join ' | ') })
    $results.Add([pscustomobject]@{ name = 'Known PowerShell regression patterns absent'; passed = ($knownPatterns.Count -eq 0); detail = ($knownPatterns -join ' | ') })
    return $results
}

function Expand-KIStackZipSafely {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ZipPath,
        [Parameter(Mandatory)][string]$DestinationPath
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
    $destFull = [System.IO.Path]::GetFullPath($DestinationPath)
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in $archive.Entries) {
            $name = $entry.FullName.Replace('\', '/')
            if ([string]::IsNullOrWhiteSpace($name)) { throw 'Leerer ZIP-Pfad.' }
            if (-not $seen.Add($name)) { throw "Doppelter ZIP-Pfad: $name" }
            if ($name.StartsWith('/') -or $name.StartsWith('//') -or $name -match '^[A-Za-z]:' -or $name.Contains(':')) {
                throw "Unsicherer ZIP-Pfad: $name"
            }
            $parts = $name.Split('/', [System.StringSplitOptions]::RemoveEmptyEntries)
            if ($parts -contains '..' -or $parts -contains '.') { throw "ZIP-Traversal: $name" }
            if ($entry.FullName.EndsWith('/')) { continue }

            $target = [System.IO.Path]::GetFullPath((Join-Path $DestinationPath ($parts -join [System.IO.Path]::DirectorySeparatorChar)))
            $relative = [System.IO.Path]::GetRelativePath($destFull, $target)
            if ([System.IO.Path]::IsPathRooted($relative) -or $relative -eq '..' -or $relative.StartsWith("..$([System.IO.Path]::DirectorySeparatorChar)")) {
                throw "ZIP-Pfad verlässt das Ziel: $name"
            }
            $parent = Split-Path -Parent $target
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
            $source = $entry.Open()
            $destination = [System.IO.File]::Create($target)
            try { $source.CopyTo($destination) } finally { $destination.Dispose(); $source.Dispose() }
        }
    } finally {
        $archive.Dispose()
    }
}

function Get-KIStackPackageRoot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ExtractedPath)

    $items = Get-ChildItem -LiteralPath $ExtractedPath -Force
    $directories = @($items | Where-Object { $_.PSIsContainer })
    $files = @($items | Where-Object { -not $_.PSIsContainer })
    if ($directories.Count -ne 1 -or $files.Count -ne 0) {
        throw "ZIP muss genau einen Wurzelordner enthalten. Ordner=$($directories.Count), Dateien=$($files.Count)"
    }
    return $directories[0].FullName
}

function ConvertTo-KIStackMarkdownReport {
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$Report)

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("# KI-Stack Package Validation Report")
    $lines.Add('')
    $lines.Add("- Paket: ``$($Report.packageName)``")
    $lines.Add("- SHA256: ``$($Report.sha256)``")
    $lines.Add("- Status: **$($Report.status)**")
    $lines.Add("- Native PowerShell: $($Report.nativePowerShellValidationExecuted)")
    $lines.Add("- Selbsttest: $($Report.packageSelfTestExecuted)")
    $lines.Add('')
    $lines.Add('## Prüfungen')
    $lines.Add('')
    foreach ($check in $Report.checks) {
        $mark = if ($check.passed) { 'PASS' } else { 'FAIL' }
        $detail = if ([string]::IsNullOrWhiteSpace([string]$check.detail)) { '' } else { " — $($check.detail)" }
        $lines.Add("- **$mark** — $($check.name)$detail")
    }
    if ($Report.notExecuted.Count -gt 0) {
        $lines.Add('')
        $lines.Add('## Nicht ausgeführt')
        $lines.Add('')
        foreach ($item in $Report.notExecuted) { $lines.Add("- $item") }
    }
    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

Export-ModuleMember -Function @(
    'Resolve-KIStackPwsh7',
    'Resolve-KIStackPython',
    'Invoke-KIStackProcess',
    'Test-KIStackPowerShellFiles',
    'Expand-KIStackZipSafely',
    'Get-KIStackPackageRoot',
    'ConvertTo-KIStackMarkdownReport'
)
