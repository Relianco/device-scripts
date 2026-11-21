$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$scriptPath = Join-Path $repoRoot 'windows/packages/hybrid-join/Invoke-HybridJoin.ps1'

function Fail {
    param([string]$Message)
    [Console]::Error.WriteLine("FAIL $Message")
    exit 1
}

$env:RELIAN_DEPLOY_TEST = '1'
Set-StrictMode -Off
. $scriptPath
Set-StrictMode -Version Latest
$realBackup = $script:HjWriteBackup

$Tid = '00000000-0000-0000-0000-000000000000'
$Tname = 'contoso.onmicrosoft.com'

# Fakes: a domain-joined device, not yet Entra joined, no client-side SCP.
function Reset-Fake {
    param([string]$Domain = 'YES', [string]$Aad = 'NO', $Scp = $null, [bool]$Task = $true, [string]$AadAfter = 'YES', [bool]$BackupFails = $false, [string]$ReadBackName = '')
    $script:calls = New-Object System.Collections.Generic.List[string]
    $script:fDomain = $Domain; $script:fAad = $Aad; $script:fScp = $Scp; $script:fTask = $Task
    $script:fAadAfter = $AadAfter; $script:fBackupFails = $BackupFails; $script:fReadBackName = $ReadBackName
    $script:fStarted = $false
}
$script:HjDsreg = {
    $aad = if ($script:fStarted) { $script:fAadAfter } else { $script:fAad }
    @('+----+', '| Device State |', "             AzureAdJoined : $aad", '          EnterpriseJoined : NO', "              DomainJoined : $($script:fDomain)", '                DomainName : CONTOSO', '  Some Unknown Field : x')
}
$script:HjReadAad = {
    if ($null -eq $script:fScp) { return [ordered]@{ keyExists = $false; TenantId = $null; TenantName = $null } }
    $name = if ($script:fReadBackName -and $script:calls -contains 'write') { $script:fReadBackName } else { $script:fScp.TenantName }
    return [ordered]@{ keyExists = $true; TenantId = $script:fScp.TenantId; TenantName = $name }
}
$script:HjWriteAad = { param([string]$TenantId, [string]$TenantName) $script:calls.Add('write'); $script:fScp = @{ TenantId = $TenantId; TenantName = $TenantName } }
$script:HjWriteBackup = { param([string]$Json) if ($script:fBackupFails) { throw 'disk full' }; $script:calls.Add("backup $Json"); 'C:\ProgramData\Relian\hybrid-join\cdj-aad-x.json' }
$script:HjGetTask = { if (-not $script:fTask) { return $null }; [ordered]@{ state = 'Ready'; lastRun = $null; lastResult = '0x00000000' } }
$script:HjStartTask = { $script:calls.Add('start'); $script:fStarted = $true }
$script:HjDomain = { [ordered]@{ name = 'contoso.example.com'; reachable = $true } }

function Assert-Same { param($Actual, $Expected, [string]$What) if ($Actual -ne $Expected) { Fail "$($What): got '$Actual', want '$Expected'" } }
function Assert-Throws { param([scriptblock]$Block, [string]$What) $t = $false; try { & $Block } catch { $t = $true }; if (-not $t) { Fail "$($What) did not throw" } }

# Modes and validation.
Assert-Same (Get-HjMode -Action 'Install' -Mode '') 'Report' 'default mode'
Assert-Same (Get-HjMode -Action 'Uninstall' -Mode 'Join') 'Report' 'Uninstall reports only'
Assert-Same (Get-HjMode -Action 'Install' -Mode 'Join' -PinVersion '') 'none' 'empty pin is off'
Assert-Same (Get-HjMode -Action 'Install' -Mode 'Scp' -TenantId $Tid -TenantName $Tname) 'Scp' 'Scp'
Assert-Same (Get-HjMode -Action 'Install' -Mode 'Join') 'Join' 'Join without SCP'
Assert-Same (Get-HjMode -Action 'Install' -Mode 'Join' -TenantId $Tid -TenantName $Tname) 'Join' 'Join with SCP'
Assert-Throws { Get-HjMode -Action 'Bogus' -Mode '' } 'bad action'
Assert-Throws { Get-HjMode -Action 'Install' -Mode 'join' } 'mode is case-sensitive'
Assert-Throws { Get-HjMode -Action 'Install' -Mode 'Scp' } 'Scp without tenant'
Assert-Throws { Get-HjMode -Action 'Install' -Mode 'Scp' -TenantId $Tid } 'Scp without TenantName'
Assert-Throws { Get-HjMode -Action 'Install' -Mode 'Join' -TenantName $Tname } 'Join with TenantName only'
foreach ($bad in @('not-a-guid', "$Tid ", '{00000000-0000-0000-0000-000000000000}x', '00000000-0000-0000-0000-00000000000g')) {
    Assert-Throws { Get-HjMode -Action 'Install' -Mode 'Scp' -TenantId $bad -TenantName $Tname } "TenantId '$bad'"
}
foreach ($bad in @('contoso', 'contoso..com', '-contoso.com', 'contoso.com;x', 'a b.com', 'contoso.com`n', ('a' * 64) + '.com')) {
    Assert-Throws { Get-HjMode -Action 'Install' -Mode 'Scp' -TenantId $Tid -TenantName $bad } "TenantName '$bad'"
}

# dsregcmd parsing keeps known fields only.
Reset-Fake
$d = ConvertFrom-HjDsreg -Lines @(& $script:HjDsreg)
Assert-Same $d['DomainJoined'] 'YES' 'parsed DomainJoined'
if ($d.Contains('Some Unknown Field')) { Fail 'unknown dsregcmd field kept' }

# Report is read-only, also on a device that is not domain-joined.
Reset-Fake
$r = Invoke-HjRun -Mode 'Report'
Assert-Same $r.exitCode 0 'Report exit'
Assert-Same $script:calls.Count 0 'Report calls'
Assert-Same $r.record.status 'report' 'Report status'
Assert-Same $r.record.device.AzureAdJoined 'NO' 'Report device'
Assert-Same $r.record.aad.keyExists $false 'Report aad'
Assert-Same $r.record.task.state 'Ready' 'Report task'
Assert-Same $r.record.domain.reachable $true 'Report domain'
Reset-Fake -Domain 'NO'
$r = Invoke-HjRun -Mode 'Report'
if ($r.exitCode -ne 0 -or $script:calls.Count -ne 0) { Fail 'Report on a workgroup device' }

# Scp and Join refuse a device that is not domain-joined, writing nothing.
foreach ($m in 'Scp', 'Join') {
    Reset-Fake -Domain 'NO'
    $r = Invoke-HjRun -Mode $m -TenantId $Tid -TenantName $Tname
    Assert-Same $r.exitCode 1 "$m refusal exit"
    Assert-Same $r.record.status 'refused' "$m refusal status"
    Assert-Same $script:calls.Count 0 "$m refusal calls"
}

# Scp: back up, write, read back. No task start.
Reset-Fake -Scp @{ TenantId = '99999999-9999-9999-9999-999999999999'; TenantName = 'old.example.com' }
$r = Invoke-HjRun -Mode 'Scp' -TenantId $Tid -TenantName $Tname
Assert-Same $r.exitCode 0 "Scp exit ($($r.record.error))"
Assert-Same $r.record.status 'scp-written' 'Scp status'
Assert-Same $script:calls.Count 2 'Scp call count'
if ($script:calls[0] -notlike 'backup *' -or $script:calls[0] -notlike '*old.example.com*' -or $script:calls[0] -notlike '*"keyExists":true*') { Fail "backup first, with old values: $($script:calls[0])" }
Assert-Same $script:calls[1] 'write' 'then write'
Assert-Same $r.record.aadAfter.TenantName $Tname 'Scp read-back'
Assert-Same $r.record.backup 'C:\ProgramData\Relian\hybrid-join\cdj-aad-x.json' 'backup path reported'

# Scp with the same values already set changes nothing.
Reset-Fake -Scp @{ TenantId = $Tid; TenantName = $Tname }
$r = Invoke-HjRun -Mode 'Scp' -TenantId $Tid -TenantName $Tname
if ($r.exitCode -ne 0 -or $r.record.status -ne 'scp-unchanged' -or $script:calls.Count -ne 0) { Fail "Scp unchanged: $($r.record.status) $($script:calls -join ';')" }

# A failed backup writes nothing; a read-back mismatch fails.
Reset-Fake -BackupFails $true
$r = Invoke-HjRun -Mode 'Scp' -TenantId $Tid -TenantName $Tname
if ($r.exitCode -ne 1 -or $script:calls -contains 'write') { Fail 'backup failure must not write' }
Reset-Fake -Scp @{ TenantId = $Tid; TenantName = 'old.example.com' } -ReadBackName 'other.example.com'
$r = Invoke-HjRun -Mode 'Scp' -TenantId $Tid -TenantName $Tname
if ($r.exitCode -ne 1 -or $r.record.status -ne 'error') { Fail 'read-back mismatch must fail' }

# Join: SCP, then the task, then the result.
Reset-Fake
$r = Invoke-HjRun -Mode 'Join' -TenantId $Tid -TenantName $Tname
Assert-Same $r.exitCode 0 "Join exit ($($r.record.error))"
Assert-Same (@($script:calls | ForEach-Object { ($_ -split ' ')[0] }) -join ';') 'backup;write;start' 'Join call order'
Assert-Same $r.record.status 'joined' 'Join status'
Assert-Same $r.record.after.AzureAdJoined 'YES' 'Join after'
if ($null -eq $r.record.taskAfter) { Fail 'Join reports the task after' }

# Join without tenant values only starts the task.
Reset-Fake -AadAfter 'NO'
$r = Invoke-HjRun -Mode 'Join'
Assert-Same ($script:calls -join ';') 'start' 'Join without SCP calls'
Assert-Same $r.record.status 'pending' 'Join not yet joined'
Assert-Same $r.exitCode 0 'pending exit'

# Join is idempotent on an Entra-joined device.
Reset-Fake -Aad 'YES'
$r = Invoke-HjRun -Mode 'Join' -TenantId $Tid -TenantName $Tname
if ($r.exitCode -ne 0 -or $r.record.status -ne 'already-joined' -or $script:calls.Count -ne 0) { Fail "already joined: $($r.record.status) $($script:calls -join ';')" }

# A missing join task fails without writing the SCP.
Reset-Fake -Task $false
$r = Invoke-HjRun -Mode 'Join' -TenantId $Tid -TenantName $Tname
if ($r.exitCode -ne 1 -or $script:calls.Count -ne 0) { Fail "missing task: $($script:calls -join ';')" }

# One line of JSON within 8,000 UTF-8 bytes, even with long dsregcmd values.
$script:HjDsreg = { @('AzureAdJoined : NO', 'DomainJoined : YES') + @('Server Message', 'Error', 'Attempt Status', 'DRS Discovery Test', 'AD Connectivity Test', 'Client ErrorCode', 'Server ErrorCode', 'TenantName', 'DeviceAuthStatus', 'AD Configuration Test', 'DRS Connectivity Test', 'Token acquisition Test', 'Fallback to Sync-Join', 'Previous Registration', 'Registration Type', 'ErrorPhase', 'KeySignTest', 'AzureAdPrt', 'WorkplaceJoined', 'EnterpriseJoined', 'DomainName', 'TenantId', 'DeviceId' | ForEach-Object { "$_ : " + ('x' * 2000) }) }
Reset-Fake -AadAfter 'NO'
$r = Invoke-HjRun -Mode 'Join'
$line = Format-HjLine $r.record
if (($line -split "`n").Count -ne 1) { Fail 'one line of JSON' }
if ([Text.Encoding]::UTF8.GetByteCount($line) -gt 8000) { Fail "line is $([Text.Encoding]::UTF8.GetByteCount($line)) bytes" }
if (($line | ConvertFrom-Json).device.DomainJoined -ne 'YES') { Fail 'trimmed line keeps the join facts' }

# Long registry values are bounded too; the line stays within the cap.
Reset-Fake -Scp @{ TenantId = ('y' * 30000); TenantName = ('z' * 30000) }
$r = Invoke-HjRun -Mode 'Report'
$line = Format-HjLine $r.record
if ([Text.Encoding]::UTF8.GetByteCount($line) -gt 8000) { Fail "long SCP values: line is $([Text.Encoding]::UTF8.GetByteCount($line)) bytes" }
if (($line | ConvertFrom-Json).status -ne 'report') { Fail 'bounded line keeps the status' }

# The real backup writer never overwrites: two backups in the same second are two files.
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('hj-test-' + [guid]::NewGuid().ToString('N'))
$script:HjBackupDir = $tmp
try {
    $a = & $realBackup '{"n":1}'
    $b = & $realBackup '{"n":2}'
    if ($a -eq $b) { Fail 'two backups share a path' }
    if ([IO.File]::ReadAllText($a) -ne '{"n":1}' -or [IO.File]::ReadAllText($b) -ne '{"n":2}') { Fail 'backup content' }
} finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force } }

# The source holds no tenant default and the param block is the runner's.
$source = [IO.File]::ReadAllText($scriptPath)
foreach ($need in @('[string]$DeploymentType', '[string]$Action', '[string]$PinVersion', "[string]`$Mode = ''", "[string]`$TenantId = ''", "[string]`$TenantName = ''")) {
    if ($source.IndexOf($need, [StringComparison]::Ordinal) -lt 0) { Fail "param block lacks $need" }
}
if ($source -match 'Mandatory\s*=') { Fail 'Mandatory parameter' }
# Code only (help block and comments removed): it never leaves Entra or restarts.
$code = (($source -replace '(?s)<#.*?#>', '') -split "`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
foreach ($bad in @('/leave', 'Restart-Computer')) {
    if ($code.IndexOf($bad, [StringComparison]::OrdinalIgnoreCase) -ge 0) { Fail "code contains $bad" }
}

# The pin record's example decodes, through the runner's parser, to valid arguments.
$release = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'windows/releases/hybrid-join.json') | ConvertFrom-Json
Assert-Same $release.installsSoftware $false 'pin record installsSoftware'
if ($release.packageArguments.IndexOf('eyJNb2RlIjoiSm9pbiIsIlRlbmFudElkIjoiMDAwMDAwMDAtMDAwMC0wMDAwLTAwMDAtMDAwMDAwMDAwMDAwIiwiVGVuYW50TmFtZSI6ImNvbnRvc28ub25taWNyb3NvZnQuY29tIn0=', [StringComparison]::Ordinal) -lt 0) { Fail 'pin record lacks the base64 example' }
Set-StrictMode -Off
. (Join-Path $repoRoot 'windows/runner/Invoke-RelianRunner.ps1')
Set-StrictMode -Version Latest
$pairs = @{}
$list = ConvertFrom-RelianPackageArguments -PackageArguments 'eyJNb2RlIjoiSm9pbiIsIlRlbmFudElkIjoiMDAwMDAwMDAtMDAwMC0wMDAwLTAwMDAtMDAwMDAwMDAwMDAwIiwiVGVuYW50TmFtZSI6ImNvbnRvc28ub25taWNyb3NvZnQuY29tIn0='
foreach ($p in $list) { $pairs[$p.Name] = $p.Value }
Assert-Same (Get-HjMode -Action 'Install' -Mode $pairs['Mode'] -TenantId $pairs['TenantId'] -TenantName $pairs['TenantName']) 'Join' 'runner pairs'

Write-Output 'hybrid-join tests passed'
exit 0
