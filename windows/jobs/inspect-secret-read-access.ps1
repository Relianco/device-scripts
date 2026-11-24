# Diagnostic module, run by windows/runner/Invoke-RelianJob.ps1 as SYSTEM. Strictly read-only: it reports who
# can read the places a licence key or a script body can end up on a PC: the PowerShell, Security and Sysmon event
# log channels (and any CustomSD policy), the AutoElevate and PDF-XChange registry keys, C:\Windows\Installer and
# the AutoElevate install log. It prints SDDL, translated ACEs, counts and value NAMES only: never a registry value,
# never event text. Log lines that look like they hold a key are replaced by their length. It writes nothing.
# -ReportOnly is accepted because the loader forwards it, and ignored. Exit 0. Prints one JSON line.
[CmdletBinding()]
param([switch]$ReportOnly)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:SrChannels = @('Microsoft-Windows-PowerShell/Operational', 'Windows PowerShell', 'Security', 'Microsoft-Windows-Sysmon/Operational')
$script:SrKeys = @('SOFTWARE\AutoElevate', 'SOFTWARE\WOW6432Node\AutoElevate', 'SOFTWARE\PDF-XChange\Vault', 'SOFTWARE\Tracker Software')
$script:SrInstallerDir = "$env:SystemRoot\Installer"
$script:SrLogPath = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'Relian\autoelevate\intune-install.log'

# Groups every signed-in staff member is in. Event Log Readers is reported apart: membership is granted per user.
$script:SrStandardSids = @('S-1-1-0', 'S-1-5-11', 'S-1-5-32-545', 'S-1-5-4')
$script:SrEventLogReaders = 'S-1-5-32-573'
$script:SrAlias = @{
    SY = 'S-1-5-18'; BA = 'S-1-5-32-544'; BU = 'S-1-5-32-545'; AU = 'S-1-5-11'; IU = 'S-1-5-4'; WD = 'S-1-1-0'
    LS = 'S-1-5-19'; NS = 'S-1-5-20'; SU = 'S-1-5-6'; SO = 'S-1-5-32-549'; BO = 'S-1-5-32-551'; ER = 'S-1-5-32-573'
    CO = 'S-1-3-0'; OW = 'S-1-3-4'; AC = 'S-1-15-2-1'; PU = 'S-1-5-32-547'; RD = 'S-1-5-32-555'; NU = 'S-1-5-2'
}
$script:SrNames = @{
    'S-1-5-18' = 'SYSTEM'; 'S-1-5-32-544' = 'Administrators'; 'S-1-5-32-545' = 'Users'; 'S-1-5-11' = 'Authenticated Users'
    'S-1-5-4' = 'INTERACTIVE'; 'S-1-1-0' = 'Everyone'; 'S-1-5-19' = 'LOCAL SERVICE'; 'S-1-5-20' = 'NETWORK SERVICE'
    'S-1-5-6' = 'SERVICE'; 'S-1-5-32-549' = 'Server Operators'; 'S-1-5-32-551' = 'Backup Operators'
    'S-1-5-32-573' = 'Event Log Readers'; 'S-1-3-0' = 'CREATOR OWNER'; 'S-1-3-4' = 'OWNER RIGHTS'
    'S-1-15-2-1' = 'ALL APPLICATION PACKAGES'; 'S-1-15-2-2' = 'ALL RESTRICTED APPLICATION PACKAGES'
    'S-1-5-32-547' = 'Power Users'; 'S-1-5-32-555' = 'Remote Desktop Users'; 'S-1-5-2' = 'NETWORK'
    'S-1-5-3' = 'BATCH'; 'S-1-5-33' = 'WRITE RESTRICTED'; 'S-1-5-80-0' = 'ALL SERVICES'
}
$script:SrRightLetters = @{
    GA = 0x10000000L; GR = 0x80000000L; GW = 0x40000000; GX = 0x20000000; RC = 0x20000; SD = 0x10000; WD = 0x40000; WO = 0x80000
    CC = 0x1; DC = 0x2; LC = 0x4; SW = 0x8; RP = 0x10; WP = 0x20; DT = 0x40; LO = 0x80; CR = 0x100
    FA = 0x1F01FF; FR = 0x120089; FW = 0x120116; FX = 0x1200A0; KA = 0xF003F; KR = 0x20019; KW = 0x20006; KX = 0x20019
}
# Bit 0x1 is read for all three objects here: ELF_LOGFILE_READ, KEY_QUERY_VALUE, FILE_READ_DATA/FILE_LIST_DIRECTORY.
$script:SrReadBits = 0x1L -bor 0x80000000L -bor 0x10000000L

$script:SrTranslateSid = {
    param($Sid)
    ([Security.Principal.SecurityIdentifier]$Sid).Translate([Security.Principal.NTAccount]).Value
}

$script:SrReadChannel = {
    param($Name)
    $lines = @(& wevtutil.exe gl $Name 2>&1 | ForEach-Object { "$_" })
    if ($LASTEXITCODE -ne 0) { throw (($lines -join ' ').Trim()) }
    $lines
}

# CustomSD policy: ChannelAccess under each subkey of the EventLog policy key (SDDL, not a secret).
$script:SrReadPolicy = {
    $out = @{}
    $hklm = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
    $root = $hklm.OpenSubKey('SOFTWARE\Policies\Microsoft\Windows\EventLog')
    if (-not $root) { return $out }
    try {
        foreach ($name in $root.GetSubKeyNames()) {
            $k = $root.OpenSubKey($name)
            if (-not $k) { continue }
            try { $v = $k.GetValue('ChannelAccess'); if ($v) { $out[$name] = [string]$v } } finally { $k.Dispose() }
        }
    } finally { $root.Dispose() }
    $out
}

# Times only: EventLogReader never formats the message text.
$script:SrRead4104 = {
    $query = [Diagnostics.Eventing.Reader.EventLogQuery]::new('Microsoft-Windows-PowerShell/Operational', [Diagnostics.Eventing.Reader.PathType]::LogName, '*[System[(EventID=4104)]]')
    $reader = [Diagnostics.Eventing.Reader.EventLogReader]::new($query)
    try {
        while ($null -ne ($e = $reader.ReadEvent())) {
            try { $e.TimeCreated } finally { $e.Dispose() }
        }
    } finally { $reader.Dispose() }
}

# The ACL and the value and subkey NAMES of one HKLM key, 64-bit view; $null when absent. No value is read.
$script:SrReadKey = {
    param($Path)
    $hklm = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
    $k = $hklm.OpenSubKey($Path, [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadSubTree, [Security.AccessControl.RegistryRights]'ReadKey')
    if (-not $k) { return $null }
    try {
        [pscustomobject]@{
            Sddl = $k.GetAccessControl([Security.AccessControl.AccessControlSections]::Access -bor [Security.AccessControl.AccessControlSections]::Owner).GetSecurityDescriptorSddlForm('Access, Owner')
            ValueNames = @($k.GetValueNames()); SubKeyNames = @($k.GetSubKeyNames())
        }
    } finally { $k.Dispose() }
}

$script:SrReadSddl = { param($Path) if (Test-Path -LiteralPath $Path) { (Get-Acl -LiteralPath $Path).Sddl } else { $null } }
$script:SrFirstFile = { param($Dir, $Filter) @(Get-ChildItem -LiteralPath $Dir -Filter $Filter -File -Force -ErrorAction Stop | Select-Object -First 1 | ForEach-Object FullName)[0] }
$script:SrReadTail = { param($Path) if (Test-Path -LiteralPath $Path) { @(Get-Content -LiteralPath $Path -Tail 5) } else { $null } }
$script:SrReadMembers = {
    param($Sid)
    $name = ([Security.Principal.SecurityIdentifier]$Sid).Translate([Security.Principal.NTAccount]).Value.Split('\')[-1]
    # ADSI, not Get-LocalGroupMember: that throws on an orphaned or Entra ID member.
    $group = [ADSI]"WinNT://./$name,group"
    @($group.psbase.Invoke('Members') | ForEach-Object {
        $path = [string]$_.GetType().InvokeMember('ADsPath', 'GetProperty', $null, $_, $null)
        $path -replace '\AWinNT://', '' -replace '/', '\'
    })
}

function Get-SrText {
    param([AllowNull()]$Text)
    $t = [string]$Text
    return $t.Substring(0, [Math]::Min($t.Length, 300))
}

function Get-SrName {
    param([string]$Sid)
    if ($script:SrNames.ContainsKey($Sid)) { return $script:SrNames[$Sid] }
    try { return [string](& $script:SrTranslateSid $Sid) } catch { return $Sid }
}

function Get-SrMask {
    param([string]$Rights)
    if ($Rights -match '\A0x[0-9a-fA-F]+\z') { return [Convert]::ToInt64($Rights.Substring(2), 16) }
    [int64]$mask = 0
    foreach ($pair in [regex]::Matches($Rights, '..')) {
        if ($script:SrRightLetters.ContainsKey($pair.Value)) { $mask = $mask -bor [int64]$script:SrRightLetters[$pair.Value] }
    }
    return $mask
}

# The DACL of an SDDL string as ACEs, with who and whether the ACE grants read on the object itself.
function Get-SrAccess {
    param([AllowEmptyString()][string]$Sddl)
    $dacl = [regex]::Match($Sddl, 'D:[^()]*((\([^)]*\))*)').Groups[1].Value
    $aces = @(foreach ($m in [regex]::Matches($dacl, '\(([^;]*);([^;]*);([^;]*);[^;]*;[^;]*;([^)]*)\)')) {
        $type = $m.Groups[1].Value; $flags = $m.Groups[2].Value; $rights = $m.Groups[3].Value; $sidText = $m.Groups[4].Value
        $sid = if ($script:SrAlias.ContainsKey($sidText)) { $script:SrAlias[$sidText] } else { $sidText }
        $inheritOnly = $flags -match '(?:\A|(?<=\A(?:..)*))IO'
        [ordered]@{
            who = Get-SrName $sid; sid = $sid; type = $(if ($type -eq 'D') { 'deny' } elseif ($type -eq 'A') { 'allow' } else { $type })
            rights = $rights; flags = $flags
            read = (-not $inheritOnly) -and (((Get-SrMask $rights) -band $script:SrReadBits) -ne 0)
        }
    })
    # Windows order for the read bit: the first applicable allow or deny that carries it decides.
    # Every staff token holds all the standard SIDs; a member of Event Log Readers holds that SID too.
    $canRead = {
        param($Sids)
        foreach ($ace in $aces) {
            if ($ace.read -and $Sids -contains $ace.sid -and @('allow', 'deny') -contains $ace.type) { return ($ace.type -eq 'allow') }
        }
        return $false
    }
    $staffRead = & $canRead $script:SrStandardSids
    $standard = @(if ($staffRead) { $script:SrStandardSids | Where-Object { $sid = $_; @($aces | Where-Object { $_.type -eq 'allow' -and $_.read -and $_.sid -eq $sid }).Count } | ForEach-Object { Get-SrName $_ } })
    $readersRead = & $canRead (@($script:SrStandardSids) + $script:SrEventLogReaders)
    # D:NO_ACCESS_CONTROL is a null DACL: everyone has every right. No DACL section at all is unknown, not denied.
    if ($Sddl -match 'D:NO_ACCESS_CONTROL') { $standard = @('Everyone (null DACL)'); $staffRead = $true; $readersRead = $true }
    elseif ($Sddl -notmatch 'D:') { $staffRead = $null; $readersRead = $null }
    [ordered]@{
        sddl = $Sddl
        aces = $aces
        standardReaders = $standard
        standardUserRead = $staffRead
        eventLogReadersRead = $readersRead
    }
}

function ConvertFrom-SrChannelText {
    param([string[]]$Lines)
    $out = [ordered]@{ channelAccess = ''; enabled = ''; maxSize = ''; retention = ''; logFileName = '' }
    foreach ($line in $Lines) {
        $m = [regex]::Match($line, '\A\s*(channelAccess|enabled|maxSize|retention|logFileName):\s*(.*)\z')
        if ($m.Success) { $out[$m.Groups[1].Value] = $m.Groups[2].Value.Trim() }
    }
    $out
}

# A key-shaped token (20+ characters, a GUID included: a key can be GUID-shaped) or a key assignment hides the
# whole line; its length is shown.
function Get-SrSafeLine {
    param([AllowEmptyString()][string]$Line)
    $assignment = '(?i)(key|licen[cs]e|serial|secret|password|passwd|token|pwd)\w*\s*[:=]\s*(?!<redacted>|\*+(\s|\z))\S'
    if ($Line -match '[A-Za-z0-9+/=_-]{20,}' -or $Line -match $assignment) { return "<withheld: $($Line.Length) chars>" }
    return Get-SrText $Line
}

function Get-SrUtc { param([datetime]$Time) $Time.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }

function Invoke-SrJob {
    $problems = [Collections.Generic.List[string]]::new()

    $channels = @(foreach ($name in $script:SrChannels) {
        try {
            $gl = ConvertFrom-SrChannelText @(& $script:SrReadChannel $name)
            [ordered]@{ name = $name; present = $true; enabled = $gl.enabled; maxSize = $gl.maxSize; retention = $gl.retention; access = (Get-SrAccess $gl.channelAccess); error = '' }
        } catch {
            [ordered]@{ name = $name; present = $false; error = (Get-SrText $_.Exception.Message) }
        }
    })

    $customSd = @()
    try {
        $policy = & $script:SrReadPolicy
        $customSd = @(foreach ($log in @($policy.Keys | Sort-Object)) { [ordered]@{ log = $log; access = (Get-SrAccess $policy[$log]) } })
    } catch { $problems.Add("CustomSD read failed: $($_.Exception.Message)") }

    $ps4104 = [ordered]@{ count = $null; oldest = $null; newest = $null }
    try {
        $times = @(& $script:SrRead4104 | Where-Object { $null -ne $_ } | Sort-Object)
        $ps4104.count = $times.Count
        if ($times.Count) { $ps4104.oldest = Get-SrUtc $times[0]; $ps4104.newest = Get-SrUtc $times[-1] }
    } catch { $problems.Add("4104 read failed: $($_.Exception.Message)") }

    $registry = @(foreach ($path in $script:SrKeys) {
        try {
            $key = & $script:SrReadKey $path
            if ($null -eq $key) { [ordered]@{ path = "HKLM\$path"; present = $false } }
            else { [ordered]@{ path = "HKLM\$path"; present = $true; valueNames = @($key.ValueNames | ForEach-Object { Get-SrText $_ }); subKeyNames = @($key.SubKeyNames | ForEach-Object { Get-SrText $_ }); access = (Get-SrAccess $key.Sddl) } }
        } catch { [ordered]@{ path = "HKLM\$path"; present = $null; error = (Get-SrText $_.Exception.Message) } }
    })

    $installer = [ordered]@{ directory = $null; sampleFile = $null }
    try {
        $installer.directory = [ordered]@{ path = $script:SrInstallerDir; access = (Get-SrAccess (& $script:SrReadSddl $script:SrInstallerDir)) }
        $sample = & $script:SrFirstFile $script:SrInstallerDir '*.msi'
        if ($sample) { $installer.sampleFile = [ordered]@{ path = (Get-SrText $sample); access = (Get-SrAccess (& $script:SrReadSddl $sample)) } }
    } catch { $problems.Add("Installer read failed: $($_.Exception.Message)") }

    $installLog = [ordered]@{ path = $script:SrLogPath; present = $false }
    try {
        $tail = & $script:SrReadTail $script:SrLogPath
        if ($null -ne $tail) {
            $installLog.present = $true
            $installLog.tail = @($tail | ForEach-Object { Get-SrSafeLine $_ })
            $installLog.access = Get-SrAccess (& $script:SrReadSddl $script:SrLogPath)
            $installLog.directoryAccess = Get-SrAccess (& $script:SrReadSddl (Split-Path -Parent $script:SrLogPath))
        }
    } catch { $problems.Add("install log read failed: $($_.Exception.Message)") }

    $groups = [ordered]@{ administrators = @(); eventLogReaders = @() }
    foreach ($g in @(@('administrators', 'S-1-5-32-544'), @('eventLogReaders', $script:SrEventLogReaders))) {
        try { $groups[$g[0]] = @(& $script:SrReadMembers $g[1] | ForEach-Object { Get-SrText $_ }) }
        catch { $problems.Add("$($g[0]) members read failed: $($_.Exception.Message)") }
    }

    [pscustomobject]@{
        ExitCode = 0
        Line = ([ordered]@{
            job = 'inspect-secret-read-access'; status = 'ok'; channels = $channels; customSd = $customSd; ps4104 = $ps4104
            registry = $registry; installer = $installer; installLog = $installLog; groups = $groups
            error = (Get-SrText ($problems -join '; '))
        } | ConvertTo-Json -Compress -Depth 8)
    }
}

# Dot-sourcing under test defines functions and changes nothing.
if ($env:RELIAN_DEPLOY_TEST -eq '1' -and $MyInvocation.InvocationName -eq '.') {
    return
}

$result = Invoke-SrJob
Write-Output $result.Line
exit $result.ExitCode
