# Read-only report of who can read event logs, licence registry keys and installer caches. Every read is a seam.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$modulePath = Join-Path $repoRoot 'windows/jobs/inspect-secret-read-access.ps1'

function Fail { param([string]$Message) [Console]::Error.WriteLine("FAIL $Message"); exit 1 }
function Assert-True { param([bool]$Condition, [string]$Label) if (-not $Condition) { Fail $Label } }
function Assert-Same { param($Actual, $Expected, [string]$Label) if ($Actual -ne $Expected) { Fail "$Label was [$Actual] expected [$Expected]" } }

$env:RELIAN_DEPLOY_TEST = '1'
. $modulePath
$script:SrTranslateSid = { param($Sid) "name-of-$Sid" }

# Windows 11 default channelAccess of Microsoft-Windows-PowerShell/Operational (wevtutil gl): INTERACTIVE gets 0x3.
$psOp = 'O:BAG:SYD:(A;;0x2;;;S-1-15-2-1)(A;;0x7;;;BA)(A;;0x7;;;SO)(A;;0x3;;;IU)(A;;0x3;;;SU)(A;;0x3;;;S-1-5-3)(A;;0x3;;;S-1-5-33)(A;;0x1;;;S-1-5-32-573)'
$a = Get-SrAccess $psOp
Assert-Same $a.standardUserRead $true 'INTERACTIVE 0x3 is a standard-user read'
Assert-Same $a.eventLogReadersRead $true 'Event Log Readers 0x1 read'
Assert-Same (@($a.standardReaders) -join ',') 'INTERACTIVE' 'standard readers named'
$iu = @($a.aces | Where-Object { $_.sid -eq 'S-1-5-4' })[0]
Assert-Same $iu.who 'INTERACTIVE' 'IU alias translated'
Assert-Same $iu.rights '0x3' 'rights kept as written'
Assert-Same $iu.read $true 'IU read bit'
$app = @($a.aces | Where-Object { $_.sid -eq 'S-1-15-2-1' })[0]
Assert-Same $app.read $false 'write-only 0x2 is not read'

# Windows default Security channel: SYSTEM, Administrators, Event Log Readers only.
$a = Get-SrAccess 'O:BAG:SYD:(A;;0xf0005;;;SY)(A;;0x5;;;BA)(A;;0x1;;;S-1-5-32-573)'
Assert-Same $a.standardUserRead $false 'Security not readable by staff'
Assert-Same $a.eventLogReadersRead $true 'Security readable by Event Log Readers'

# Inherit-only does not apply to the object; inherited does.
Assert-Same (Get-SrAccess 'D:(A;OICIIO;GR;;;BU)').standardUserRead $false 'inherit-only ACE ignored'
Assert-Same (Get-SrAccess 'D:PAI(A;CIID;KR;;;BU)(A;CIID;KA;;;BA)').standardUserRead $true 'registry KR for Users'
Assert-Same (Get-SrAccess 'D:(A;;FX;;;BU)').standardUserRead $false 'FX has no read-data bit'
Assert-Same (Get-SrAccess 'D:(A;;0x1200a9;;;WD)').standardUserRead $true 'hex read for Everyone'
Assert-Same (Get-SrAccess 'D:(D;;0x1;;;IU)(A;;0x1;;;IU)').standardUserRead $false 'deny read wins'
Assert-Same (Get-SrAccess 'D:(A;;0x1;;;S-1-5-21-1-2-3-1001)').standardUserRead $false 'a named account is not a group of all staff'
Assert-Same @((Get-SrAccess 'D:(A;;0x1;;;S-1-5-21-1-2-3-1001)').aces)[0].who 'name-of-S-1-5-21-1-2-3-1001' 'unknown SID translated through the seam'
# Every staff token holds Everyone, Users, Authenticated Users and INTERACTIVE, so a deny on any of them blocks all.
Assert-Same (Get-SrAccess 'D:(D;;0x1;;;WD)(A;;0x1;;;BU)').standardUserRead $false 'deny for Everyone blocks a later Users grant'
# Windows reads the DACL in order: a read already granted is not taken back by a later (inherited) deny.
Assert-Same (Get-SrAccess 'D:(A;;0x1;;;BU)(D;ID;0x1;;;WD)').standardUserRead $true 'earlier grant wins over a later deny'
# A null DACL is unrestricted; an empty one grants nothing; no descriptor is unknown.
Assert-Same (Get-SrAccess 'O:BAG:SYD:NO_ACCESS_CONTROL').standardUserRead $true 'null DACL is world-readable'
Assert-Same (Get-SrAccess 'O:BAG:SYD:P').standardUserRead $false 'empty DACL grants nothing'
Assert-True ($null -eq (Get-SrAccess '').standardUserRead) 'no descriptor is unknown'
Assert-True ($null -eq (Get-SrAccess 'O:BAG:SY').standardUserRead) 'descriptor without a DACL section is unknown'
# The SACL is not parsed as access.
Assert-Same @((Get-SrAccess 'O:SYG:SYD:(A;;KA;;;SY)S:(AU;SA;KA;;;WD)').aces).Count 1 'SACL ignored'

# wevtutil gl output.
$gl = ConvertFrom-SrChannelText @('name: Microsoft-Windows-PowerShell/Operational', 'enabled: true', 'type: Operational', "channelAccess: $psOp", 'logging:', '  logFileName: %SystemRoot%\System32\Winevt\Logs\Microsoft-Windows-PowerShell%4Operational.evtx', '  retention: false', '  autoBackup: false', '  maxSize: 15728640')
Assert-Same $gl.channelAccess $psOp 'channelAccess parsed'
Assert-Same $gl.maxSize '15728640' 'maxSize parsed'
Assert-Same $gl.enabled 'true' 'enabled parsed'

# Log lines: a key-shaped token or a key assignment is withheld, its length shown.
Assert-Same (Get-SrSafeLine 'LicenseKey=ABCDEF0123456789ABCDEF01') '<withheld: 35 chars>' 'key assignment withheld'
Assert-Same (Get-SrSafeLine 'msiexec /i x.msi KEY=abc123') '<withheld: 27 chars>' 'short key assignment withheld'
Assert-Same (Get-SrSafeLine 'token Zm9vYmFyYmF6cXV4cXV1eHh4eHg=') '<withheld: 34 chars>' 'base64 token withheld'
Assert-Same (Get-SrSafeLine 'LicenseKey=<redacted>') 'LicenseKey=<redacted>' 'redacted placeholder kept'
Assert-Same (Get-SrSafeLine '2026-11-23 10:00:01 install exit 0 product {12345678-9ABC-DEF0-1234-56789ABCDEF0}') '2026-11-23 10:00:01 install exit 0 product {12345678-9ABC-DEF0-1234-56789ABCDEF0}' 'ordinary line with a GUID kept'

# Whole job through the seams.
$t1 = [datetime]::new(2026, 11, 1, 8, 0, 0, [DateTimeKind]::Utc); $t2 = [datetime]::new(2026, 11, 23, 9, 30, 0, [DateTimeKind]::Utc)
$script:SrReadChannel = { param($Name) if ($Name -like '*Sysmon*') { throw 'channel not found' }; @("name: $Name", "channelAccess: $psOp", '  maxSize: 1052672') }
$script:SrReadPolicy = { @{ Security = 'O:BAG:SYD:(A;;0x1;;;BU)' } }
$script:SrRead4104 = { @($t2, $t1, $t2) }
$script:SrReadKey = { param($Path) if ($Path -eq 'SOFTWARE\AutoElevate') { [pscustomobject]@{ Sddl = 'D:PAI(A;CIID;KR;;;BU)'; ValueNames = @('LicenseKey', 'AgentMode'); SubKeyNames = @() } } }
$script:SrReadSddl = { param($Path) if ($Path -like '*.log') { 'D:(A;;FA;;;SY)' } else { 'D:(A;OICI;0x1200a9;;;BU)' } }
$script:SrFirstFile = { param($Dir, $Filter) 'C:\Windows\Installer\1a2b.msi' }
$script:SrReadTail = { param($Path) @('a', 'KEY=secretvalue123') }
$script:SrReadMembers = { param($Sid) @('PC\admin') }
$r = Invoke-SrJob
Assert-Same $r.ExitCode 0 'exit'
$j = $r.Line | ConvertFrom-Json
Assert-Same (($j.PSObject.Properties.Name) -join ',') 'job,status,channels,customSd,ps4104,registry,installer,installLog,groups,error' 'output keys'
$ch = @($j.channels)
Assert-Same $ch.Count 4 'four channels'
Assert-Same $ch[0].name 'Microsoft-Windows-PowerShell/Operational' 'first channel'
Assert-Same $ch[0].access.standardUserRead $true 'channel access evaluated'
Assert-Same $ch[3].present $false 'missing Sysmon channel'
Assert-True ($ch[3].error -like '*not found*') 'missing channel reason'
Assert-Same @($j.customSd)[0].log 'Security' 'CustomSD policy listed'
Assert-Same @($j.customSd)[0].access.standardUserRead $true 'CustomSD evaluated'
Assert-Same $j.ps4104.count 3 '4104 count'
# Raw text: ConvertFrom-Json turns ISO strings into local DateTime.
Assert-True ($r.Line -like '*"oldest":"2026-11-01T08:00:00Z"*') 'oldest'
Assert-True ($r.Line -like '*"newest":"2026-11-23T09:30:00Z"*') 'newest'
$ae = @($j.registry | Where-Object { $_.path -eq 'HKLM\SOFTWARE\AutoElevate' })[0]
Assert-Same $ae.present $true 'AutoElevate key present'
Assert-Same (@($ae.valueNames) -join ',') 'LicenseKey,AgentMode' 'value names only'
Assert-Same $ae.access.standardUserRead $true 'AutoElevate readable by Users'
Assert-Same @($j.registry | Where-Object { $_.path -eq 'HKLM\SOFTWARE\PDF-XChange\Vault' })[0].present $false 'absent key'
Assert-Same $j.installer.directory.access.standardUserRead $true 'Installer directory listable'
Assert-Same $j.installer.sampleFile.access.standardUserRead $true 'sample msi readable'
Assert-Same $j.installLog.present $true 'install log present'
Assert-Same (@($j.installLog.tail) -join '|') 'a|<withheld: 18 chars>' 'tail redacted'
Assert-Same $j.installLog.access.standardUserRead $false 'log not readable by staff'
Assert-Same (@($j.groups.administrators) -join ',') 'PC\admin' 'administrators listed'
Assert-True ($r.Line -notmatch 'secretvalue') 'no secret in output'

# A log that is not there.
$script:SrReadTail = { param($Path) $null }
$j = (Invoke-SrJob).Line | ConvertFrom-Json
Assert-Same $j.installLog.present $false 'no install log'

Write-Output 'inspect-secret-read-access: ok'
