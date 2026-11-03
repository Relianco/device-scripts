$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
function Assert($Condition, $Label) { if (-not $Condition) { throw "FAIL $Label" } }
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$path = Join-Path $root 'windows/packages/diagnose-feature-upgrade/Invoke-DiagnoseFeatureUpgrade.ps1'
$env:RELIAN_DEPLOY_TEST = '1'
. $path
Assert ((Protect-DiagnosticText 'password=secret 0x80070057') -eq '[sensitive line omitted]') 'password omitted'
Assert ((Protect-DiagnosticText 'https://example.com/file?sig=private') -notmatch 'private|https') 'URL omitted'
Assert ((Protect-DiagnosticText 'C:\Users\person\setup.log failed 0x80070057') -notmatch 'person') 'user profile redacted'
$tmp = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('n'))
$null = New-Item -ItemType Directory -Path $tmp
try {
    $log = Join-Path $tmp 'setupact.log'
    [IO.File]::WriteAllText($log, "before`nCAddCbsPackage KB5043080 failed 0x80070057`nafter`n" + ((1..100 | ForEach-Object { "later $_" }) -join "`n"))
    $r = Read-DiagnosticLog -Path $log -MaxBytes 4096
    Assert (($r.matches -join ' ') -match 'before.*KB5043080.*after') 'historical failure with adjacent context'
    Assert (($r.tail -join ' ') -match 'later 100') 'latest tail retained'
    [IO.File]::WriteAllText($log, "KB5043080 underlying package failure`n" + ((1..20 | ForEach-Object { "generic 0x80070057 $_" }) -join "`n"))
    $r = Read-DiagnosticLog -Path $log -MaxBytes 4096
    Assert (($r.matches -join ' ') -match 'KB5043080 underlying') 'package context survives repeated generic errors'
    [IO.File]::WriteAllText($log, ('x' * 5000) + "`n0x20003 tail`n")
    $r = Read-DiagnosticLog -Path $log -MaxBytes 512
    Assert ($r.sampledBytes -le 512 -and $r.truncated) 'large file byte cap'
    Assert (($r.tail -join ' ') -match '0x20003') 'tail after byte cap'
    [IO.File]::WriteAllText($log, "old`n0x80070057 unicode failure`n", [Text.Encoding]::Unicode)
    $r = Read-DiagnosticLog -Path $log -MaxBytes 512
    Assert (($r.matches -join ' ') -match 'unicode failure') 'UTF16 log decoded'
    $r = Read-DiagnosticLog -Path (Join-Path $tmp 'missing.log')
    Assert ($r.status -eq 'missing') 'missing log explicit'
    $state = Join-Path $tmp 'state.json'
    [IO.File]::WriteAllText($state, '{"status":"failed","exitHex":"0x80070057","secret":"do-not-print","message":"password=hidden"}')
    $r = Read-DiagnosticState -Path $state
    Assert ($r.exitHex -eq '0x80070057' -and -not $r.Contains('secret')) 'state allowlist'
    Assert ($r.message -eq '[sensitive line omitted]') 'state text sanitized'
    $huge = [ordered]@{ status='collected'; logs=@([ordered]@{label='test';tail=@(('unicodeé' * 10000));matches=@()}); notes=@() }
    $json = ConvertTo-BoundedDiagnosticJson $huge -MaxBytes 1000
    Assert ([Text.Encoding]::UTF8.GetByteCount($json) -le 1000) 'output byte cap includes unicode'
    Assert (($json | ConvertFrom-Json).truncated) 'output truncation explicit'
} finally { Remove-Item -LiteralPath $tmp -Recurse -Force }
# Exercise the complete report with unavailable logs and mocked Windows probes.
# Collecting evidence must leave the existing upgrade state unchanged.
$runtimeTemp = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('n'))
$null = New-Item -ItemType Directory -Path $runtimeTemp
$oldEnv = @($env:SystemRoot, $env:SystemDrive, $env:ProgramData)
function Get-ItemProperty { param($LiteralPath, $ErrorAction); [pscustomobject]@{CurrentBuild='22631';FailureDetails='0x80070057-0x20003';UEFISecureBootEnabled=0} }
function Get-CimInstance {
    param($ClassName, $Namespace, $Filter, $OperationTimeoutSec, $ErrorAction)
    Assert ($OperationTimeoutSec -eq 5) 'CIM request timeout'
    if ($ClassName -eq 'Win32_OperatingSystem') { return [pscustomobject]@{LastBootUpTime=[datetime]::UtcNow} }
    if ($ClassName -eq 'Win32_Process') { return [pscustomobject]@{Name='setuphost.exe';ProcessId=12;CreationDate=[datetime]::UtcNow;CommandLine='password=hidden'} }
    [pscustomobject]@{Name='test';Size=100;FreeSpace=80;SpecVersion='2.0'}
}
try {
    $env:SystemRoot=$runtimeTemp; $env:SystemDrive=$runtimeTemp; $env:ProgramData=$runtimeTemp
    $stateDir = Join-Path $runtimeTemp 'Relian/FeatureUpgrade'
    $null = New-Item -ItemType Directory -Path $stateDir -Force
    $stateFile = Join-Path $stateDir 'state.json'
    $stateText = '{"status":"started","isoBuild":26300}'
    [IO.File]::WriteAllText($stateFile, $stateText)
    $output = Invoke-FeatureUpgradeDiagnostic
    $report = $output | ConvertFrom-Json
    Assert ($report.status -eq 'collected') 'whole collector succeeds'
    Assert ([IO.File]::ReadAllText($stateFile) -eq $stateText) 'running worker state untouched'
    Assert ($report.state.status -eq 'started') 'running worker state collected'
    Assert ($report.logs.Count -eq 11) 'all fixed log sections present'
    Assert (($report.logs.label -contains 'newos-cbs') -and ($report.logs.label -contains 'newos-dism')) 'offline servicing logs included'
    Assert ($output -notmatch 'password|hidden|CommandLine') 'process command line excluded'
    Assert ($report.setupDiag.FailureDetails -eq '0x80070057-0x20003') 'full SetupDiag data retained'
} finally {
    $env:SystemRoot=$oldEnv[0];$env:SystemDrive=$oldEnv[1];$env:ProgramData=$oldEnv[2]
    Remove-Item -LiteralPath $runtimeTemp -Recurse -Force
}

# Runtime has no field writes, installs, service mutations or executable launches.
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
Assert ($errors.Count -eq 0) 'PowerShell parser'
$commands=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst]},$true) | ForEach-Object { $_.GetCommandName() })
foreach ($forbidden in @('Set-ItemProperty','New-ItemProperty','Remove-Item','Start-Process','Restart-Computer','Set-Service','Start-Service','Stop-Service','Ninja-Property-Set')) { Assert ($commands -notcontains $forbidden) "no $forbidden" }
Write-Output 'diagnose-feature-upgrade tests passed'
