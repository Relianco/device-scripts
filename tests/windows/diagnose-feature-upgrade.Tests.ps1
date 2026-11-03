$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
function Assert($Condition, $Label) { if (-not $Condition) { throw "FAIL $Label" } }
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$path = Join-Path $root 'windows/packages/diagnose-feature-upgrade/Invoke-DiagnoseFeatureUpgrade.ps1'
$env:RELIAN_DEPLOY_TEST = '1'
. $path
$script:sensitiveValue = [guid]::NewGuid().ToString('n')
$profileName = [guid]::NewGuid().ToString('n')
$profilePath = [string]::Join([char]92, @('C:', 'Users', $profileName, 'setup.log'))
Assert ((Protect-DiagnosticText ('password=' + $script:sensitiveValue + ' 0x80070057')) -eq '[sensitive line omitted]') 'password omitted'
Assert ((Protect-DiagnosticText ("https://example.invalid/file?sig=$script:sensitiveValue")) -notmatch ([regex]::Escape($script:sensitiveValue) + '|https')) 'URL omitted'
Assert ((Protect-DiagnosticText ($profilePath + ' failed 0x80070057')) -notmatch [regex]::Escape($profileName)) 'user profile redacted'
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
    [IO.File]::WriteAllText($log, "before access failure`nOffline file operation failed 0x80070005`nafter access failure`n" + ((1..100 | ForEach-Object { "later $_" }) -join "`n"))
    $r = Read-DiagnosticLog -Path $log -MaxBytes 4096
    Assert (($r.matches -join ' ') -match 'before access failure.*0x80070005.*after access failure') 'access-denied operation context retained'
    [IO.File]::WriteAllText($log, "first offline file operation failed 0x80070005`nERROR_ACCESS_DENIED opening offline item`nSTATUS_CANNOT_DELETE deleting offline item`n" + ((1..100 | ForEach-Object { "later $_" }) -join "`n") + "`n" + ((1..12 | ForEach-Object { "abandoning 0x80070005 $_" }) -join "`n"))
    $r = Read-DiagnosticLog -Path $log -MaxBytes 8192
    Assert (($r.matches -join ' ') -match 'first offline file operation.*abandoning 0x80070005') 'first access failure survives trailing summaries'
    Assert (($r.matches -join ' ') -match 'ERROR_ACCESS_DENIED.*STATUS_CANNOT_DELETE') 'named underlying access/delete errors retained'
    # Rollback completion and diagnostic timeout are not the upgrade outcome.
    # Space the outcome markers apart so each needs its own matcher category.
    $outcomes=@('Current phase: SafeOS','Current op: Boot','Current result: 0xC1900101','Setup360: result recorded','PostRebootInstall: upgrade failed')
    $history=@()
    foreach ($outcome in $outcomes) { $history += $outcome; $history += @(1..8 | ForEach-Object { "ordinary progress $_" }) }
    $history += @(1..100 | ForEach-Object { "later rollback work $_" })
    $history += @('Rollback completed successfully','Diagnostics timed out 0x800705B4')
    [IO.File]::WriteAllText($log, ($history -join "`n"))
    $r=Read-DiagnosticLog -Path $log -MaxBytes 8192
    foreach ($outcome in $outcomes) { Assert (($r.matches -join ' ').Contains($outcome)) "rollback outcome retained: $outcome" }
    Assert (($r.tail -join ' ') -match 'Diagnostics timed out') 'diagnostic timeout retained separately from upgrade result'
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
    [IO.File]::WriteAllText($state, (@{status='failed';exitHex='0x80070057';secret=$script:sensitiveValue;message=('password=' + $script:sensitiveValue)} | ConvertTo-Json -Compress))
    $r = Read-DiagnosticState -Path $state
    Assert ($r.exitHex -eq '0x80070057' -and -not $r.Contains('secret')) 'state allowlist'
    Assert ($r.message -eq '[sensitive line omitted]') 'state text sanitized'
    $huge = [ordered]@{ status='collected'; logs=@([ordered]@{label='test';tail=@(('unicodeé' * 10000));matches=@()}); notes=@() }
    $json = ConvertTo-BoundedDiagnosticJson $huge -MaxBytes 1000
    Assert ([Text.Encoding]::UTF8.GetByteCount($json) -le 1000) 'output byte cap includes unicode'
    Assert (($json | ConvertFrom-Json).truncated) 'output truncation explicit'
} finally { Remove-Item -LiteralPath $tmp -Recurse -Force }
# Ninja truncates stdout around 10,000 characters. Budget the serialized UTF-8
# JSON (including escaping), retaining failure/state evidence before verbose logs.
$fixturePath = [string]::Join([char]92, @('C:', 'WINDOWS', 'SoftwareDistribution', 'Download', ([guid]::NewGuid().ToString('n')), 'Package_for_RollupFix'))
$failure = ('Invalid package "' + $fixturePath + '" for GetPackageListFromFolder (hr:0x80070057). ') * 8
$transport = [ordered]@{version='2';status='collected';section='Summary';state=[ordered]@{status='running';time='2026-01-01T01:00:00Z';exitHex='0x80070057'};setupDiag=[ordered]@{FailureData=$failure;FailureDetails=$failure};logs=@();notes=@()}
$json = ConvertTo-BoundedDiagnosticJson $transport
Assert ([Text.Encoding]::UTF8.GetByteCount($json) -le 8000) 'serialized transport budget'
$r = $json | ConvertFrom-Json
Assert ($r.setupDiag.FailureData -eq $failure -and $r.setupDiag.FailureDetails -eq $failure) 'realistic failure details retained whole'
$transport.setupDiag.FailureData = ('é\"' * 10000)
$json = ConvertTo-BoundedDiagnosticJson $transport
$r = $json | ConvertFrom-Json
Assert ([Text.Encoding]::UTF8.GetByteCount($json) -le 8000) 'pathological escaped Unicode capped'
Assert ($r.state.exitHex -eq '0x80070057' -and $r.state.status -eq 'running' -and $r.truncated) 'oversize still retains state evidence'

$endError = [ordered]@{status='collected';state=@{status='running'};logs=@(@{label='servicing';matches=@(('context ' * 1000) + ' hr:0x800f081f');tail=@()});notes=@()}
$json = ConvertTo-BoundedDiagnosticJson $endError -MaxBytes 1000
Assert ($json -match '0x800f081f' -and [Text.Encoding]::UTF8.GetByteCount($json) -le 1000) 'clipping retains trailing servicing HRESULT'

# Exercise the complete report with unavailable logs and mocked Windows probes.
# Collecting evidence must leave the existing upgrade state unchanged.
$runtimeTemp = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('n'))
$null = New-Item -ItemType Directory -Path $runtimeTemp
$oldEnv = @($env:SystemRoot, $env:SystemDrive, $env:ProgramData)
function Get-ItemProperty { param($LiteralPath, $ErrorAction); [pscustomobject]@{CurrentBuild='22631';FailureDetails='0x80070057-0x20003';UpgradeStartTime='2026-01-01T01:00:00Z';TargetOSBuildString='26300';UEFISecureBootEnabled=0} }
$script:bitLockerQueries=0
function Invoke-CimMethod { param($InputObject,$MethodName,$OperationTimeoutSec,$ErrorAction); Assert ($MethodName -eq 'GetLockStatus' -and $OperationTimeoutSec -eq 5) 'read-only BitLocker lock probe'; [pscustomobject]@{ReturnValue=0;LockStatus=0} }
function Get-CimInstance {
    param($ClassName, $Namespace, $Filter, $Property, $OperationTimeoutSec, $ErrorAction)
    Assert ($OperationTimeoutSec -eq 5) 'CIM request timeout'
    if ($ClassName -eq 'Win32_EncryptableVolume') { $script:bitLockerQueries++; return [pscustomobject]@{ConversionStatus=1;ProtectionStatus=1;VolumeType=0} }
    if ($ClassName -eq 'Win32_OperatingSystem') { return [pscustomobject]@{LastBootUpTime=[datetime]::UtcNow} }
    if ($ClassName -eq 'Win32_Process') { return [pscustomobject]@{Name='setuphost.exe';ProcessId=12;CreationDate=[datetime]::UtcNow;CommandLine=('password=' + $script:sensitiveValue)} }
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
    Assert ($report.version -eq '4') 'report identifies rollback outcome matcher revision'
    Assert ([IO.File]::ReadAllText($stateFile) -eq $stateText) 'running worker state untouched'
    Assert ($report.state.status -eq 'started') 'running worker state collected'
    Assert ($report.bitLocker.encryptionStatus -eq 'FullyEncrypted' -and $report.bitLocker.protectionStatus -eq 'On') 'Summary includes BitLocker status'
    Assert ($report.section -eq 'Summary' -and $report.logs.Count -eq 0) 'default summary contains metadata without logs'
    Assert ($output.Contains('"UpgradeStartTime":"2026-01-01T01:00:00Z"') -and $report.setupDiag.TargetOSBuildString -eq '26300') 'prior attempt timing and target retained'
    Assert ($output.IndexOf('"setupDiag":') -lt $output.IndexOf('"logs":')) 'metadata serialized before logs'
    foreach ($file in @('CBS/CBS.log','DISM/dism.log')) {
        $logPath = Join-Path $runtimeTemp ('$WINDOWS.~BT/NewOS/Windows/Logs/' + $file)
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $logPath) -Force
        [IO.File]::WriteAllText($logPath, ((1..12 | ForEach-Object { (('0x80070057 KB5043080 ' + $fixturePath + ' ') * 15) }) -join "`n"))
    }
    $expected = @{Rollback=@('rollback-errors','rollback-actions');Servicing=@('newos-cbs','newos-dism','host-cbs','host-dism');Setup=@('panther-errors','panther-actions','windows-panther-errors','windows-panther-actions','mosetup')}
    foreach ($section in $expected.Keys) {
        $partJson = Invoke-FeatureUpgradeDiagnostic -Section $section
        Assert ([Text.Encoding]::UTF8.GetByteCount($partJson) -le 8000) "transport budget for $section"
        $part = $partJson | ConvertFrom-Json
        Assert (($part.logs.label -join ',') -eq ($expected[$section] -join ',')) "fixed paths for $section"
        if ($section -eq 'Servicing') { Assert ($part.truncated -and (($part.logs | Where-Object { $_.status -eq 'read' } | ForEach-Object { $_.matches }) -join ' ') -match '0x80070057') 'verbose servicing logs clipped with evidence retained' }
        Assert ($part.state.status -eq 'started') "state retained in $section"
    }
    Assert ($script:bitLockerQueries -eq 1) 'BitLocker collected only in Summary'
    Assert ($output -notmatch ('password|CommandLine|' + [regex]::Escape($script:sensitiveValue))) 'process command line excluded'
    Assert ($report.setupDiag.FailureDetails -eq '0x80070057-0x20003') 'full SetupDiag data retained'
} finally {
    $env:SystemRoot=$oldEnv[0];$env:SystemDrive=$oldEnv[1];$env:ProgramData=$oldEnv[2]
    Remove-Item -LiteralPath $runtimeTemp -Recurse -Force
}

$invalidRejected=$false
try { Invoke-FeatureUpgradeDiagnostic -Section 'Invalid' } catch { $invalidRejected=$true }
Assert $invalidRejected 'invalid report section rejected'

# Runtime has no field writes, installs, service mutations or executable launches.
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
Assert ($errors.Count -eq 0) 'PowerShell parser'
$commands=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst]},$true) | ForEach-Object { $_.GetCommandName() })
foreach ($forbidden in @('Set-ItemProperty','New-ItemProperty','Remove-Item','Start-Process','Restart-Computer','Set-Service','Start-Service','Stop-Service','Ninja-Property-Set')) { Assert ($commands -notcontains $forbidden) "no $forbidden" }
Write-Output 'diagnose-feature-upgrade tests passed'
