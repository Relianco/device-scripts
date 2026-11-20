$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$scriptPath = Join-Path $repoRoot 'windows/packages/gsa-private-access/Invoke-GsaPrivateAccess.ps1'

function Fail {
    param([string]$Message)
    [Console]::Error.WriteLine("FAIL $Message")
    exit 1
}

$env:RELIAN_DEPLOY_TEST = '1'
Set-StrictMode -Off
. $scriptPath
Set-StrictMode -Version Latest

$SidA = 'S-1-12-1-1-2-3-4'
$SidB = 'S-1-5-21-1-2-3-1001'
function Reset-Fake {
    param([bool]$RestartFails = $false)
    $script:values = @{}
    $script:calls = New-Object System.Collections.Generic.List[string]
    $script:restartFails = $RestartFails
}
$script:GpaGetHives = { @([pscustomobject]@{ Sid = $SidA; Upn = 'user.one@example.invalid' }, [pscustomobject]@{ Sid = $SidB; Upn = '' }) }
$script:GpaGetValue = { param([string]$Sid) if ($script:values.ContainsKey($Sid)) { return $script:values[$Sid] }; return $null }
$script:GpaSetValue = { param([string]$Sid) $script:values[$Sid] = 1; $script:calls.Add("set $Sid") }
$script:GpaRemoveValue = { param([string]$Sid) $script:values.Remove($Sid); $script:calls.Add("remove $Sid") }
$script:GpaGetServices = { @([pscustomobject]@{ Name = 'GlobalSecureAccessEngineService'; Status = 'Running' }, [pscustomobject]@{ Name = 'GlobalSecureAccessPolicyRetrieverService'; Status = 'Stopped' }) }
$script:GpaRestartService = { param([string]$Name) if ($script:restartFails) { throw 'nope' }; $script:calls.Add("restart $Name") }
$script:GpaResolve = { param([string]$Name) if ($Name -eq 'pa.example.invalid') { @('6.6.0.5') } else { @('192.0.2.5') } }

# Modes.
if ((Get-GpaMode -Action 'Install' -Mode '' -User '') -ne 'Report') { Fail 'default Report' }
if ((Get-GpaMode -Action 'Install' -Mode 'Disable' -User 'a@example.invalid') -ne 'Disable') { Fail 'Disable' }
if ((Get-GpaMode -Action 'Uninstall' -Mode 'Disable' -User 'a@example.invalid') -ne 'Report') { Fail 'Uninstall reports' }
if ((Get-GpaMode -Action 'Install' -Mode 'Disable' -User '' -PinVersion '') -ne 'none') { Fail 'empty pin off' }
foreach ($bad in @(@('Disable', ''), @('Disable', 'nobody'), @('disable', 'a@example.invalid'), @('Wipe', 'a@example.invalid'))) {
    $threw = $false; try { Get-GpaMode -Action 'Install' -Mode $bad[0] -User $bad[1] } catch { $threw = $true }
    if (-not $threw) { Fail "accepted $($bad -join ' ')" }
}
if (-not (Test-GpaSynthetic -Ip '6.6.1.2') -or (Test-GpaSynthetic -Ip '66.6.1.2') -or (Test-GpaSynthetic -Ip '192.0.2.1')) { Fail 'synthetic range' }

# Report changes nothing and shows DNS interception.
Reset-Fake
$r = Invoke-GpaRun -Mode 'Report' -User '' -DnsName 'pa.example.invalid'
if ($script:calls.Count) { Fail 'Report changed something' }
if (-not $r.record.report.dns.privateAccessIntercepts -or $r.record.report.users.Count -ne 2) { Fail 'Report content' }
$r = Invoke-GpaRun -Mode 'Report' -User '' -DnsName 'host.example.invalid'
if ($r.record.report.dns.privateAccessIntercepts) { Fail 'non-synthetic address' }

# Disable: only the named user's hive, then only running services restart.
Reset-Fake
$r = Invoke-GpaRun -Mode 'Disable' -User 'USER.ONE@example.invalid' -DnsName ''
if ($r.exitCode -ne 0) { Fail "Disable exit: $($r.record.errors -join ';')" }
if (($script:calls -join ';') -ne "set $SidA;restart GlobalSecureAccessEngineService") { Fail "Disable calls: $($script:calls -join ';')" }
if (-not ($r.record.report.users | Where-Object { $_.sid -eq $SidA }).privateAccessDisabled) { Fail 'read-back in report' }
if (($r.record.report.users | Where-Object { $_.sid -eq $SidB }).privateAccessDisabled) { Fail 'other user touched' }

# Enable is the undo.
$r = Invoke-GpaRun -Mode 'Enable' -User 'user.one@example.invalid' -DnsName ''
if ($r.exitCode -ne 0 -or $script:values.ContainsKey($SidA)) { Fail 'Enable' }

# A user who is not signed in, or a failed restart, fails.
Reset-Fake
$r = Invoke-GpaRun -Mode 'Disable' -User 'someone@example.invalid' -DnsName ''
if ($r.exitCode -ne 1 -or $script:calls.Count) { Fail 'unknown user must change nothing' }
Reset-Fake -RestartFails $true
$r = Invoke-GpaRun -Mode 'Disable' -User 'user.one@example.invalid' -DnsName ''
if ($r.exitCode -ne 1) { Fail 'restart failure must fail' }
# The entry point prints Format-GpaOutput; it must be one line that parses back.
$line = Format-GpaOutput -Record $r.record
if (([string]$line -split "`r?`n").Count -ne 1) { Fail 'one line of JSON' }
if ((($line | ConvertFrom-Json).mode) -ne 'Disable') { Fail 'output does not parse back' }
if ((Get-Content -LiteralPath $scriptPath -Raw) -notmatch 'Write-Output \(Format-GpaOutput -Record \$run\.record\)') { Fail 'entry point must print Format-GpaOutput' }

# Enable's read-back needs the value gone: a value left at 0 fails.
Reset-Fake
$script:values[$SidA] = 0
$script:GpaRemoveValue = { param([string]$Sid) $script:calls.Add("remove $Sid") }  # pretends, leaves the value
$r = Invoke-GpaRun -Mode 'Enable' -User 'user.one@example.invalid' -DnsName ''
if ($r.exitCode -ne 1) { Fail 'Enable must fail when the value is still there' }
$script:GpaRemoveValue = { param([string]$Sid) throw 'access denied' }
$r = Invoke-GpaRun -Mode 'Enable' -User 'user.one@example.invalid' -DnsName ''
if ($r.exitCode -ne 1 -or @($r.record.errors) -notcontains 'write failed') { Fail 'a removal error must fail' }

Write-Output 'gsa-private-access tests passed'
