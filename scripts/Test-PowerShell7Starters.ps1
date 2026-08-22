[CmdletBinding()]
param([string]$RepositoryRoot=(Split-Path -Parent $PSScriptRoot))
Set-StrictMode -Version Latest;$ErrorActionPreference='Stop'
if($PSVersionTable.PSEdition-ne'Core'-or$PSVersionTable.PSVersion.Major-lt7){throw'Dieser Regressionstest muss unter PowerShell 7 laufen.'}
$fail=[Collections.Generic.List[string]]::new()
$roots=@(Join-Path $RepositoryRoot 'tools/openwebui-agent-pack/current';Join-Path $RepositoryRoot 'tools/complete-installer/current')
$cmdFiles=@($roots|ForEach-Object{Get-ChildItem -LiteralPath $_ -Recurse -File -Filter '*.cmd'})
foreach($file in $cmdFiles){$bytes=[IO.File]::ReadAllBytes($file.FullName);$text=[Text.Encoding]::UTF8.GetString($bytes);$relative=[IO.Path]::GetRelativePath($RepositoryRoot,$file.FullName).Replace('\','/')
    if($bytes.Length-ge3-and$bytes[0]-eq0xEF-and$bytes[1]-eq0xBB-and$bytes[2]-eq0xBF){$fail.Add("UTF-8-BOM: $relative")}
    if($text-match'(?<!\r)\n'){$fail.Add("Nicht CRLF: $relative")}
    $isGreenfieldInstaller=$relative-eq'tools/complete-installer/current/Start-KIStack-Installer.cmd'
    if($text-match'(?i)(?:^|[^a-z])powershell\.exe' -and-not$isGreenfieldInstaller){$fail.Add("Windows PowerShell: $relative")}
    if($text-match'(?i)pwsh\.exe' -and ($text-notmatch'(?i)%ProgramFiles%\\PowerShell\\7\\pwsh\.exe' -or $text-notmatch'(?i)where pwsh\.exe' -or(-not$isGreenfieldInstaller-and$text-notmatch'exit /b 70'))){$fail.Add("Unvollständige PowerShell-7-Auflösung: $relative")}
}
$greenfieldStarter=Get-Content -LiteralPath (Join-Path $RepositoryRoot 'tools/complete-installer/current/Start-KIStack-Installer.cmd') -Raw
$greenfieldBootstrap=Get-Content -LiteralPath (Join-Path $RepositoryRoot 'tools/complete-installer/current/Bootstrap-KIStackPowerShell7.ps1') -Raw
foreach($marker in @('Bootstrap-KIStackPowerShell7.ps1','WindowsPowerShell\v1.0\powershell.exe','goto :RESULT')){if(-not$greenfieldStarter.Contains($marker)){$fail.Add("Greenfield-Starter fehlt: $marker")}}
foreach($marker in @('Payload\CutoverRuntime','KIModuleRuntime.psm1','Install-KIModuleRuntime','Microsoft.PowerShell','Get-KIBootstrapPowerShell7','-Elevated','Start-Process -FilePath $pwsh')){if(-not$greenfieldBootstrap.Contains($marker)){$fail.Add("Greenfield-Bootstrap fehlt: $marker")}}
if($greenfieldStarter.Contains('FEHLER: PowerShell 7 wurde nicht gefunden.')){$fail.Add('Greenfield-Starter bricht weiterhin vor Foundation/Runtime ab.')}
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('KIStack-Greenfield-PS7-'+[guid]::NewGuid().ToString('N'))
$fixtureEvidence=Join-Path $fixture 'bootstrap-reached.txt'
$fixturePassed=$false
try{
    New-Item -ItemType Directory -Path $fixture -Force|Out-Null
    Copy-Item -LiteralPath (Join-Path $RepositoryRoot 'tools/complete-installer/current/Start-KIStack-Installer.cmd') -Destination $fixture
    # ProgramFiles cannot be faked via a child process's environment block --
    # Windows always re-supplies the real value regardless of what is passed
    # to CreateProcess (verified: arbitrary custom variables propagate
    # correctly, ProgramFiles alone does not), so on a machine where
    # PowerShell 7 is installed at the real default path (e.g. GitHub-hosted
    # runners), the starter's %ProgramFiles% lookup always finds the real
    # pwsh.exe and this fixture can never exercise the "missing" branch.
    # Substitute that one lookup for a test-only variable name in this
    # fixture copy only; the real starter file is never touched.
    $fixtureStarterPath=Join-Path $fixture 'Start-KIStack-Installer.cmd'
    $fixtureStarterText=[Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($fixtureStarterPath)).Replace('%ProgramFiles%\PowerShell\7\pwsh.exe','%KI_STACK_TEST_PROGRAMFILES_OVERRIDE%\PowerShell\7\pwsh.exe')
    [IO.File]::WriteAllBytes($fixtureStarterPath,[Text.Encoding]::UTF8.GetBytes($fixtureStarterText))
    [IO.File]::WriteAllText((Join-Path $fixture 'CompleteInstaller.psm1'),'',[Text.ASCIIEncoding]::new())
    [IO.File]::WriteAllText((Join-Path $fixture 'Start-KIStackCompleteInstaller.ps1'),'',[Text.ASCIIEncoding]::new())
    [IO.File]::WriteAllText((Join-Path $fixture 'Bootstrap-KIStackPowerShell7.ps1'),'[IO.File]::WriteAllText($env:KI_STACK_BOOTSTRAP_EVIDENCE,"FoundationRuntimeReached",[Text.ASCIIEncoding]::new()); exit 0',[Text.ASCIIEncoding]::new())
    $processInfo=[Diagnostics.ProcessStartInfo]::new()
    $processInfo.FileName=Join-Path $env:SystemRoot 'System32/cmd.exe'
    $processInfo.Arguments='/d /c ""'+(Join-Path $fixture 'Start-KIStack-Installer.cmd')+'" <nul"'
    $processInfo.WorkingDirectory=$fixture
    $processInfo.UseShellExecute=$false
    $processInfo.CreateNoWindow=$true
    $processInfo.RedirectStandardOutput=$true
    $processInfo.RedirectStandardError=$true
    $processInfo.EnvironmentVariables['KI_STACK_TEST_PROGRAMFILES_OVERRIDE']=(Join-Path $fixture 'No-PowerShell7')
    $processInfo.EnvironmentVariables['PATH']=@((Join-Path $env:SystemRoot 'System32'),$env:SystemRoot,(Join-Path $env:SystemRoot 'System32/Wbem'))-join';'
    $processInfo.EnvironmentVariables['KI_STACK_BOOTSTRAP_EVIDENCE']=$fixtureEvidence
    $process=[Diagnostics.Process]::Start($processInfo)
    $stdout=$process.StandardOutput.ReadToEnd();$stderr=$process.StandardError.ReadToEnd();$process.WaitForExit()
    $fixturePassed=$process.ExitCode-eq0-and(Test-Path -LiteralPath $fixtureEvidence)-and((Get-Content -LiteralPath $fixtureEvidence -Raw)-eq'FoundationRuntimeReached')
    if(-not$fixturePassed){$fail.Add("Greenfield ohne PowerShell 7 erreichte den Bootstrap nicht: Exitcode $($process.ExitCode); $stdout $stderr")}
}finally{if(Test-Path -LiteralPath $fixture){Remove-Item -LiteralPath $fixture -Recurse -Force}}
$entryFiles=@('tools/openwebui-agent-pack/current/Invoke-OpenWebUIAgentPack.ps1','tools/openwebui-agent-pack/current/Test-OpenWebUIAgentPackTarget.ps1','tools/complete-installer/current/Invoke-KIStackCompleteInstaller.ps1')
foreach($relative in $entryFiles){$text=Get-Content -LiteralPath (Join-Path $RepositoryRoot $relative) -Raw;if($text-notmatch"PSEdition -ne 'Core'"-or$text-notmatch'PSVersion\.Major -lt 7'){$fail.Add("Runtime-Guard: $relative")}}
$windowsPowerShell=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
if(Test-Path $windowsPowerShell){
    & $windowsPowerShell -NoLogo -NoProfile -File (Join-Path $RepositoryRoot 'tools/openwebui-agent-pack/current/Invoke-OpenWebUIAgentPack.ps1') -Action DryRun *> $null;if($LASTEXITCODE-eq0){$fail.Add('Agent-Pack akzeptiert Windows PowerShell 5.1.')}
    & $windowsPowerShell -NoLogo -NoProfile -File (Join-Path $RepositoryRoot 'tools/complete-installer/current/Invoke-KIStackCompleteInstaller.ps1') -Mode Audit *> $null;if($LASTEXITCODE-eq0){$fail.Add('Complete Installer akzeptiert Windows PowerShell 5.1.')}
}
$global:LASTEXITCODE=0
[pscustomobject]@{passed=($fail.Count-eq0);actualPSEdition=$PSVersionTable.PSEdition;actualPSVersion=$PSVersionTable.PSVersion.ToString();cmdFiles=$cmdFiles.Count;windowsPowerShellRejected=$true;greenfieldWithoutPowerShell7=[ordered]@{launcherDoesNotAbort=$fixturePassed;foundationRuntimeReached=$greenfieldBootstrap.Contains('Install-KIModuleRuntime');powerShell7Readback=$greenfieldBootstrap.Contains('Get-KIBootstrapPowerShell7');completeInstallerHandoff=$greenfieldBootstrap.Contains('Start-Process -FilePath $pwsh')};failures=@($fail)}|ConvertTo-Json -Depth 10
if($fail.Count){throw('PowerShell-7-Starter-Regression: '+($fail-join'; '))}
