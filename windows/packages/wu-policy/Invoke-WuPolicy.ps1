<#
.SYNOPSIS
    Windows Update policy package for the Relian deploy runner (NinjaOne script 374).
    Finds, and with Fix removes, local policy values that turn off automatic updates.

.DESCRIPTION
    By default it is read-only. It reads the Windows Update policy keys
    (HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate and its AU subkey),
    the machine Registry.pol (presence, size, date, entry count, and which of
    the values below it holds), and the state of the Microsoft Compatibility
    Appraiser task. It writes no registry value and no file.

    With -Fix true it acts only when automatic updates are off by policy:
    NoAutoUpdate = 1, AUOptions below 3, or DisableWindowsUpdateAccess = 1.
    It does nothing on a WSUS-managed device (UseWUServer = 1 or WUServer set).
    Otherwise it exports the WindowsUpdate policy key and copies Registry.pol to
    C:\relian\wu-policy-backup-<yyyyMMdd-HHmmss>, deletes those values (and
    SetDisableUXWUAccess when it is 1), renames Registry.pol to
    Registry.pol.bak-<stamp> when it holds nothing but those values, runs gpupdate,
    and reads the values again. TargetReleaseVersion, DeferFeatureUpdates,
    PauseFeatureUpdates, DisableOSUpgrade and WSUS values are left alone and
    reported. It never reboots, never starts an upgrade, and touches no service.
    A second run finds nothing to do.

    The runner passes DeploymentType, Action and PinVersion, then each
    PackageArguments pair as -Name value. Fix is the only one read, and it is a
    string: base64 of {"Fix":"true"} is eyJGaXgiOiJ0cnVlIn0=.
    Install, Update, Repair and Reinstall all run the check (and the fix when
    Fix is "true"). Uninstall changes nothing and exits 0.

    The result is one line of compact JSON, printed last on stdout, with a
    short "verdict". The JSON also goes to the NinjaOne device custom field
    relianWuPolicy when the NinjaOne agent is present. Exit 1 when a fix was
    attempted and the values are still set or a step failed.

.NOTES
    Requirements: Windows PowerShell 5.1+, run as SYSTEM
    No external module dependencies
#>

# Not Mandatory: a mandatory param block prompts when this file is dot-sourced
# under RELIAN_DEPLOY_TEST.
[CmdletBinding()]
param(
    [string]$DeploymentType,
    [string]$Action,
    [string]$PinVersion,
    [string]$Fix = ''
)

$ProgressPreference = "SilentlyContinue"

# NinjaOne field names are alphanumeric only.
$WupFieldName = "relianWuPolicy"
$WupKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
$WupAuKey = "$WupKey\AU"
$WupPolPath = "$env:SystemRoot\System32\GroupPolicy\Machine\Registry.pol"
$WupBackupRoot = 'C:\relian'
# Value names the fix may delete. Anything else is reported, never changed.
$WupFixNames = @('NoAutoUpdate', 'AUOptions', 'DisableWindowsUpdateAccess', 'SetDisableUXWUAccess')

function Write-Status {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$Level] $timestamp - $Message"
}

function Limit-Text {
    param([string]$Text, [int]$Max = 200)
    if ($null -eq $Text) { return $null }
    $t = ($Text -replace '\s+', ' ').Trim()
    if ($t.Length -gt $Max) { return $t.Substring(0, $Max) + "..." }
    return $t
}

# Values of one registry key as an ordered hashtable. Missing key = $null.
function Get-RegValues {
    param([string]$Path, [string[]]$Only)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $out = [ordered]@{}
    try {
        $key = Get-Item -LiteralPath $Path -ErrorAction Stop
        foreach ($name in $key.GetValueNames()) {
            if ($Only -and ($Only -notcontains $name)) { continue }
            $v = $key.GetValue($name)
            if ($v -is [byte[]]) { continue }
            if ($v -is [string[]]) { $v = $v -join ',' }
            if ($v -is [string]) { $v = Limit-Text $v 200 }
            $out[$(if ($name) { $name } else { '(default)' })] = $v
        }
    } catch { return @{ error = (Limit-Text "$_" 120) } }
    return $out
}

function Test-Has {
    param($Map, [string]$Name)
    return ($null -ne $Map -and $Map.Contains($Name) -and $null -ne $Map[$Name] -and "$($Map[$Name])" -ne '')
}

# Pure: a numeric policy value, or $null when absent or not a number.
function Get-WupInt {
    param($Map, [string]$Name)
    if ((Test-Has $Map $Name) -and "$($Map[$Name])" -match '^\d+$') { return [int]"$($Map[$Name])" }
    return $null
}

# Pure: "key;value" for each entry of a Registry.pol. PReg is an 8-byte header,
# then [key;value;type;size;data] with UTF-16LE text and uint32 type and size.
# Throws when the file is not well formed.
function Get-WupPolEntries {
    param([byte[]]$Bytes)
    if ($null -eq $Bytes -or $Bytes.Length -lt 8 -or [Text.Encoding]::ASCII.GetString($Bytes, 0, 4) -ne 'PReg') { throw 'not a PReg file' }
    $u = [Text.Encoding]::Unicode
    $out = New-Object System.Collections.Generic.List[string]
    $i = 8
    while ($i -lt $Bytes.Length) {
        if ([BitConverter]::ToUInt16($Bytes, $i) -ne 0x5B) { throw "no [ at $i" }
        $i += 2
        $text = @()
        foreach ($n in 1..2) {
            $start = $i
            while ([BitConverter]::ToUInt16($Bytes, $i) -ne 0) { $i += 2 }
            $text += $u.GetString($Bytes, $start, $i - $start)
            $i += 4   # terminator and ';'
        }
        $size = [int][BitConverter]::ToUInt32($Bytes, $i + 6)   # after type (4) and ';' (2)
        $i += 12 + $size                                       # type ; size ; data
        if ([BitConverter]::ToUInt16($Bytes, $i) -ne 0x5D) { throw "no ] at $i" }
        $i += 2
        $out.Add("$($text[0]);$($text[1])")
    }
    # Unrolled on purpose: callers wrap in @(), and an empty file must count 0.
    return $out.ToArray()
}

# Pure: true for a Registry.pol entry the fix deletes anyway (a "**del." entry counts).
function Test-WupFixEntry {
    param([string]$Entry)
    $parts = $Entry -split ';', 2
    $value = $parts[1] -replace '^\*\*del\.', ''
    $keys = @('Software\Policies\Microsoft\Windows\WindowsUpdate', 'Software\Policies\Microsoft\Windows\WindowsUpdate\AU')
    return ($keys -contains $parts[0]) -and ($WupFixNames -contains $value)
}

function Get-WupPolInfo {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return [ordered]@{ exists = $false } }
    try {
        $item = Get-Item -LiteralPath $Path -ErrorAction Stop
        $info = [ordered]@{
            exists    = $true
            size      = [long]$item.Length
            lastWrite = $item.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
        }
        try {
            $entries = @(Get-WupPolEntries ([IO.File]::ReadAllBytes($Path)))
            $ours = @($entries | Where-Object { Test-WupFixEntry $_ })
            $info.entries = $entries.Count
            $info.wuValues = @($ours | ForEach-Object { ($_ -split ';', 2)[1] })
            $info.other = $entries.Count - $ours.Count
        } catch { $info.parseError = Limit-Text "$_" 80 }
        return $info
    } catch { return [ordered]@{ exists = $true; error = (Limit-Text "$_" 120) } }
}

function Get-WupState {
    $task = try { "$((Get-ScheduledTask -TaskPath '\Microsoft\Windows\Application Experience\' -TaskName 'Microsoft Compatibility Appraiser' -ErrorAction Stop).State)" } catch { 'missing' }
    return [ordered]@{
        wu            = Get-RegValues $WupKey
        au            = Get-RegValues $WupAuKey
        registryPol   = Get-WupPolInfo $WupPolPath
        appraiserTask = $task
    }
}

# Pure: the values that turn automatic updates off. Empty = nothing to do.
function Get-WupBlockers {
    param($State)
    $b = @()
    if ((Get-WupInt $State.au 'NoAutoUpdate') -eq 1) { $b += 'NoAutoUpdate' }
    $o = Get-WupInt $State.au 'AUOptions'
    if ($null -ne $o -and $o -lt 3) { $b += 'AUOptions' }
    if ((Get-WupInt $State.wu 'DisableWindowsUpdateAccess') -eq 1) { $b += 'DisableWindowsUpdateAccess' }
    return @($b)
}

# Pure: the WSUS server, 'UseWUServer' when only the switch is set, or $null.
# A WUServer left without UseWUServer = 1 still counts: refusing is the safe side.
function Get-WupWsus {
    param($State)
    if (Test-Has $State.wu 'WUServer') { return "$($State.wu.WUServer)" }
    if ((Get-WupInt $State.au 'UseWUServer') -eq 1) { return 'UseWUServer' }
    return $null
}

# Pure: policy values the fix leaves in place that can still hold back feature updates.
function Get-WupRemaining {
    param($State)
    $r = @()
    if ($State.wu -and -not $State.wu.Contains('error')) {
        $r += @($State.wu.Keys | Where-Object { $_ -match '^(TargetReleaseVersion|ProductVersion|DeferFeatureUpdates|PauseFeatureUpdates|WUServer|WUStatusServer)' })
        if ((Get-WupInt $State.wu 'DisableOSUpgrade') -eq 1) { $r += 'DisableOSUpgrade' }
    }
    if ((Get-WupInt $State.au 'UseWUServer') -eq 1) { $r += 'UseWUServer' }
    return @($r)
}

# Pure: what a fix would do. action is 'none', 'wsus' or 'fix'.
function Get-WupPlan {
    param($State)
    $blockers = @(Get-WupBlockers $State)
    if ($blockers.Count -eq 0) { return [ordered]@{ action = 'none' } }
    $wsus = Get-WupWsus $State
    if ($wsus) { return [ordered]@{ action = 'wsus'; wsus = $wsus } }
    $deletes = @()
    foreach ($name in $blockers) {
        $deletes += [ordered]@{ key = $(if ($name -eq 'DisableWindowsUpdateAccess') { $WupKey } else { $WupAuKey }); name = $name }
    }
    if ((Get-WupInt $State.wu 'SetDisableUXWUAccess') -eq 1) { $deletes += [ordered]@{ key = $WupKey; name = 'SetDisableUXWUAccess' } }
    # gpupdate rewrites whatever Registry.pol holds, so a deleted value comes back
    # unless the file goes too. But without the file the registry extension can
    # also drop every other policy it set, so rename it only when it holds
    # nothing but entries this fix deletes anyway. Otherwise it is left, and a
    # value it puts back fails the verify step. An unparsed file is left.
    $pol = $State.registryPol
    $rename = $false
    if ($pol -and $pol.exists -and $pol.Contains('other') -and $pol.Contains('entries')) {
        $rename = ([int]$pol.other -eq 0) -and ([int]$pol.entries -gt 0)
    }
    return [ordered]@{ action = 'fix'; deletes = $deletes; renamePol = $rename }
}

function Backup-WupPolicy {
    param([string]$Dir)
    $null = New-Item -ItemType Directory -Path $Dir -Force -ErrorAction Stop
    $file = Join-Path $Dir 'WindowsUpdate-policy.reg'
    $null = & reg.exe export 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' $file /y 2>&1
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $file)) { throw "reg export failed ($LASTEXITCODE)" }
    if (Test-Path -LiteralPath $WupPolPath) { Copy-Item -LiteralPath $WupPolPath -Destination (Join-Path $Dir 'Registry.pol') -ErrorAction Stop }
}

function Remove-WupValue {
    param([string]$Key, [string]$Name)
    Remove-ItemProperty -LiteralPath $Key -Name $Name -ErrorAction Stop
}

function Rename-WupPol {
    param([string]$Stamp)
    $new = "Registry.pol.bak-$Stamp"
    Rename-Item -LiteralPath $WupPolPath -NewName $new -ErrorAction Stop
    return $new
}

# Computer policy only. gpupdate can ask to log off or restart; 'N' on stdin answers no.
function Invoke-WupGpUpdate {
    $null = 'N' | & gpupdate.exe /target:computer /force /wait:120 2>&1
    return $LASTEXITCODE
}

# Applies a 'fix' plan: backup first, and nothing else if the backup fails. Never throws.
function Invoke-WupFix {
    param($Plan, [string]$Stamp)
    $out = [ordered]@{ backup = $null; removed = @(); polRenamed = $null; gpupdate = $null; errors = @() }
    $dir = "$WupBackupRoot\wu-policy-backup-$Stamp"
    try { Backup-WupPolicy $dir; $out.backup = $dir }
    catch { $out.errors += "backup: $(Limit-Text "$_" 100)"; return $out }
    foreach ($d in $Plan.deletes) {
        try { Remove-WupValue $d.key $d.name; $out.removed += $d.name }
        catch { $out.errors += "$($d.name): $(Limit-Text "$_" 100)" }
    }
    if ($Plan.renamePol) {
        try { $out.polRenamed = Rename-WupPol $Stamp }
        catch { $out.errors += "Registry.pol: $(Limit-Text "$_" 100)" }
    }
    try {
        $code = Invoke-WupGpUpdate
        $out.gpupdate = $code
        if ($code -ne 0) { $out.errors += "gpupdate exit $code" }
    } catch { $out.errors += "gpupdate: $(Limit-Text "$_" 100)" }
    return $out
}

# Pure: 'check', 'fix' or 'none' for a runner Action and Fix string. Throws on bad input.
function Get-WupMode {
    param([string]$Action, [string]$Fix)
    if (@('Install', 'Update', 'Repair', 'Reinstall', 'Uninstall') -notcontains $Action) {
        throw 'Action must be Install, Update, Repair, Reinstall, or Uninstall.'
    }
    if ($Action -eq 'Uninstall') { return 'none' }
    if ($Fix -eq '' -or $Fix -eq 'false') { return 'check' }
    if ($Fix -eq 'true') { return 'fix' }
    throw 'Fix must be true or false.'
}

# Collects, fixes when asked and allowed, and returns the record plus an exit code.
function Invoke-WupRun {
    param([switch]$Fix)
    $state = Get-WupState
    $plan = Get-WupPlan $state
    $blockers = @(Get-WupBlockers $state)
    $remaining = @(Get-WupRemaining $state)
    $record = [ordered]@{
        mode          = $(if ($Fix) { 'fix' } else { 'check' })
        blockers      = $blockers
        wsus          = (Get-WupWsus $state)
        remaining     = $remaining
        au            = $state.au
        wu            = $state.wu
        registryPol   = $state.registryPol
        appraiserTask = $state.appraiserTask
    }
    $code = 0
    $left = if ($remaining.Count) { "; still set: $($remaining -join ', ')" } else { '' }
    if ($plan.action -eq 'none') {
        $verdict = "nothing to do: automatic updates not off by policy$left"
    } elseif ($plan.action -eq 'wsus') {
        $verdict = "WSUS-managed ($($plan.wsus)), not changed: $($blockers -join ', ')$left"
    } elseif (-not $Fix) {
        $verdict = "automatic updates off by policy: $($blockers -join ', ')$left"
    } else {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $record.fix = Invoke-WupFix $plan $stamp
        $after = Get-WupState
        $still = @(Get-WupBlockers $after)
        $record.after = [ordered]@{ blockers = $still; au = $after.au; wu = $after.wu; registryPol = $after.registryPol }
        $pol = 'no Registry.pol'
        if ($record.fix.polRenamed) { $pol = "Registry.pol renamed to $($record.fix.polRenamed)" }
        elseif ($plan.renamePol) { $pol = 'Registry.pol not renamed' }
        elseif ($state.registryPol.exists) {
            $p = $state.registryPol
            $why = if (-not $p.Contains('other')) { 'not parsed' } elseif ([int]$p.other -gt 0) { "$($p.other) other entries" } else { 'no entries' }
            $pol = "Registry.pol left ($why)"
        }
        if ($still.Count -eq 0 -and $record.fix.errors.Count -eq 0) {
            $verdict = "fixed: removed $($record.fix.removed -join ', '); $pol$left"
        } else {
            $code = 1
            $verdict = "fix incomplete: still set $(if ($still.Count) { $still -join ', ' } else { 'nothing' }); errors $($record.fix.errors.Count); $pol$left"
        }
    }
    $record.verdict = $verdict
    $record.timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    $record.version = "1.0"
    return [ordered]@{ record = $record; exitCode = $code }
}

# Pure: quotes a value for a native command line under Windows PowerShell 5.1,
# which passes embedded double quotes through unescaped. Backslashes before a
# quote are doubled, then the quote is escaped (MSVCRT argument rules).
function ConvertTo-WupNativeArg {
    param([string]$Value)
    return [regex]::Replace($Value, '(\\*)"', { param($m) $m.Groups[1].Value + $m.Groups[1].Value + '\"' })
}

# The runner starts the package in a child powershell.exe. Ninja-Property-Set
# there hands the value to the agent CLI as a native argument, and 5.1 strips
# the JSON's quotes. So write through the CLI's stdin and read it back.
function Set-WupField {
    param([string]$Value)
    $cli = Join-Path $env:ProgramData 'NinjaRMMAgent\ninjarmm-cli.exe'
    if (Test-Path -LiteralPath $cli) {
        try {
            $null = $Value | & $cli set --stdin $WupFieldName 2>&1
            $back = (& $cli get $WupFieldName 2>$null) -join "`n"
            if ($back.Trim() -eq $Value) { return $true }
        } catch { }
    }
    if (Get-Command Ninja-Property-Set -ErrorAction SilentlyContinue) {
        try { Ninja-Property-Set $WupFieldName (ConvertTo-WupNativeArg $Value); return $true } catch { }
    }
    return $false
}

function Invoke-Main {
    param([switch]$Fix)
    try {
        Write-Status "Windows Update policy $(if ($Fix) { 'fix' } else { 'check' }) starting"
        $run = Invoke-WupRun -Fix:$Fix
        # ponytail: no trimming like feature-update; two policy keys stay far under the ~10,000 character field.
        # ("ponytail:" is this repo's marker for a deliberate shortcut, as in feature-update; not a name.)
        $json = $run.record | ConvertTo-Json -Depth 6 -Compress
        Write-Status "Verdict: $($run.record.verdict) ($($json.Length) bytes)"
        if (Set-WupField $json) { Write-Status "Written to $WupFieldName" }
        else { Write-Status "Custom field not written; the JSON line below is the result" "WARN" }
        # Last stdout line is the JSON; so a log reader can find it.
        Write-Output $json
        exit $run.exitCode
    } catch {
        Write-Status "Windows Update policy error: $_" "ERROR"
        Write-Status $_.ScriptStackTrace "ERROR"
        exit 1
    }
}

if ($env:RELIAN_DEPLOY_TEST -ne '1') {
    try { $wupMode = Get-WupMode -Action $Action -Fix $Fix }
    catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }
    if ($wupMode -eq 'none') { Write-Output 'Nothing to change. Nothing was installed.'; exit 0 }
    Invoke-Main -Fix:($wupMode -eq 'fix')
}
