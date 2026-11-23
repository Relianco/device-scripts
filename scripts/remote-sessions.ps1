#!/usr/bin/env pwsh
#Requires -Version 7.5
<#
.SYNOPSIS
    Remote-session task drafts: NinjaOne's own session records for when and who, Wazuh alerts for what was done.

.DESCRIPTION
    An operator tool, run from an admin machine or a server (Linux or Windows, pwsh 7.5+). A device never downloads it.

    - When: NINJA_REMOTE activities (nc_session_established_with_handle / nc_session_terminated_with_handle and NinjaOne's own
      duration), keyed by sessionName. A request that never connected is not a session.
    - Who: the request names the NinjaOne user. A user outside relian.ca (client staff with NinjaOne access) is not drafted.
      Connections to one device (NinjaOne device id) by one person less than 15 minutes apart are one sitting.
    - What: Wazuh alerts of the device in each connection window: Sysmon 1 and Security 4688 process starts by a person (not a
      machine account or a service), MsiInstaller installs a person ran, UAC prompts. Activity is read only when the host name is
      one Wazuh agent, one NinjaOne device, and every event names the device's DNS name.
    - Text: no names, no host, no file names. Hours: 0.5 h minimum, then 0.1 h steps. Under a minute: not drafted. Over 4 h: review.

    Limits: an install through an .exe setup is not claimed (shown as "also seen"); on a shared desktop the technician's and the
    user's clicks look the same; an app open before the session is not listed; a NinjaOne script run as the logged-on user would
    count its commands; Splashtop sessions are not read.

    Default: a dry run that reads only (GET, plus the Wazuh _search POST) and prints a draft per sitting beside the old task.
    -Apply also creates one Invoice Ninja task in the Backlog status per drafted sitting that no task carries yet ("Ref: NinjaOne
    <handle>"). It never sends, invoices or emails anything. -ClientMap is a JSON file of NinjaOne organizationId -> Invoice Ninja
    client id, for example {"12": "VolejRejNm"}; a sitting whose organization is not in it is skipped and reported.

    Credentials come only from the environment: NINJAONE_BASE_URL, NINJAONE_CLIENT_ID, NINJAONE_CLIENT_SECRET,
    WAZUH_INDEXER_USER, WAZUH_INDEXER_PASSWORD, WAZUH_INDEXER_SHA256 (the indexer certificate's pinned SHA-256),
    INVOICENINJA_API_URL, INVOICENINJA_API_KEY. WAZUH_INDEXER_URL overrides the default indexer address.

.EXAMPLE
    pwsh -NoProfile -File scripts/remote-sessions.ps1 -Days 3

.EXAMPLE
    pwsh -NoProfile -File scripts/remote-sessions.ps1 -Days 3 -Apply -ClientMap ./client-map.json
#>
# Not Mandatory: a mandatory param block prompts when this file is dot-sourced under RELIAN_DEPLOY_TEST.
[CmdletBinding()]
param(
    [double]$Days = 3,
    [string]$IndexerUrl = $(if ($env:WAZUH_INDEXER_URL) { $env:WAZUH_INDEXER_URL } else { 'https://100.94.199.113:9200' }),   # the indexer's tailnet address
    [string]$Json,
    [switch]$Apply,
    [string]$ClientMap
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- shared rules
$script:RsGap = 900              # connections to one device by one person less than 15 minutes apart are one sitting
$script:RsMinSeconds = 60        # under a minute in total: a connection test, not work
$script:RsMaxSeconds = 4 * 3600  # longer: a person checks it was not left connected
$script:RsSlack = 60             # device clock against NinjaOne's clock: events this close outside the window still count
$script:RsRemoteMinHours = 0.5   # remote support minimum, then 0.1 h steps (Support Terms Schedule A)

# Python's sorted(): stable, strings compared ordinally, numbers as numbers. Key returns an array (a tuple).
function Compare-RsKey {
    param($A, $B)
    for ($i = 0; $i -lt $A.Count; $i++) {
        $c = if ($A[$i] -is [string]) { [string]::CompareOrdinal($A[$i], [string]$B[$i]) } else { ([double]$A[$i]).CompareTo([double]$B[$i]) }
        if ($c -ne 0) { return [math]::Sign($c) }
    }
    return 0
}

function Sort-RsStable {
    param($Items, [scriptblock]$Key)
    $decorated = [System.Collections.Generic.List[object]]::new()
    $i = 0
    foreach ($item in @($Items)) { $decorated.Add([pscustomobject]@{ k = @(& $Key $item); i = $i++; v = $item }) }
    $decorated.Sort([System.Comparison[object]] {
            param($x, $y)
            $c = Compare-RsKey $x.k $y.k
            if ($c -ne 0) { return $c }
            return $x.i.CompareTo($y.i)
        })
    foreach ($d in $decorated) { $d.v }
}

# ---------------------------------------------------------------- NinjaOne sessions

# NINJA_REMOTE activities -> one record per established and terminated connection.
function Get-RsSessions {
    param($Activities, $Devices, [string[]]$TechDomains = @('relian.ca'))
    $dev = @{}
    foreach ($d in @($Devices)) { $dev["$($d['id'])"] = $d }
    $by = [System.Collections.Generic.Dictionary[string, hashtable]]::new()
    $order = [System.Collections.Generic.List[string]]::new()
    foreach ($a in @($Activities)) {
        $data = $a['data']
        if ($null -eq $data) { $data = @{} }
        $name = $data['sessionName']
        $msg = $data['message']
        if ($null -eq $msg) { $msg = @{} }
        if ($a['activityType'] -cne 'NINJA_REMOTE' -or -not $name) { continue }
        if (-not $by.ContainsKey($name)) { $by[$name] = @{ id = $name; deviceId = $a['deviceId'] }; $order.Add($name) }
        $s = $by[$name]
        $code = $msg['code']
        $p = $msg['params']
        if ($null -eq $p) { $p = @{} }
        if ($code -ceq 'nc_session_requested') {
            $s['tech'] = $p['appUserName']
            $s['email'] = ([string]$p['appUserEmail']).ToLowerInvariant()
        } elseif ($code -ceq 'nc_session_established_with_handle') {
            $s['start'] = [long][math]::Truncate([double]$a['activityTime'])
        } elseif ($code -ceq 'nc_session_terminated_with_handle') {
            $s['end'] = [long][math]::Truncate([double]$a['activityTime'])
            $s['seconds'] = if ($p['duration']) { [long]$p['duration'] } else { [long]0 }
        }
    }
    $out = foreach ($name in $order) {
        $s = $by[$name]
        if (-not $s.ContainsKey('start') -or -not $s.ContainsKey('end')) { continue }   # never connected, or still open: nothing to bill yet
        $d = $dev["$($s['deviceId'])"]
        if ($null -eq $d) { $d = @{} }
        $email = $s['email']
        [ordered]@{
            id = $s['id']; deviceId = $s['deviceId']; device = $d['systemName']; dns = $d['dnsName']; org = $d['organizationId']
            server = ([string]$d['nodeClass']).Contains('SERVER'); start = $s['start']; end = $s['end']; seconds = $s['seconds']
            tech = $s['tech']; email = $email
            staff = if (-not $email) { $null } else { $TechDomains -cnotcontains $email.Substring($email.LastIndexOf('@') + 1) }   # null: the request was not seen
        }
    }
    Sort-RsStable $out { param($s) , $s['start'] }
}

# Connections to one device (NinjaOne device id, not name: two clients can both have a PC-01) by one person, GAP apart at most.
function Get-RsSittings {
    param($Sessions, [int]$Gap = $script:RsGap)
    $sittingKey = { param($s) @("$($s['deviceId'])", $(if ($s['email']) { $s['email'] } elseif ($s['tech']) { $s['tech'] } else { '' })) }
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($s in @(Sort-RsStable $Sessions { param($s) @(& $sittingKey $s) + $s['start'] })) {
        $t = if ($out.Count) { $out[$out.Count - 1] } else { $null }
        if ($t -and (Compare-RsKey @(& $sittingKey $t) @(& $sittingKey $s)) -eq 0 -and $s['start'] - $t['end'] -le $Gap) {
            # two windows open at once count once: only the part past the sitting's end is new time
            $t['seconds'] += if ($s['start'] -ge $t['end']) { $s['seconds'] } else { [math]::Max(0, $s['end'] - $t['end']) }
            $t['ids'].Add($s['id'])
            $t['spans'].Add(@($s['start'], $s['end']))
            $t['end'] = [math]::Max($t['end'], $s['end'])
        } else {
            $t = [ordered]@{}
            foreach ($k in $s.Keys) { $t[$k] = $s[$k] }
            $t['ids'] = [System.Collections.Generic.List[string]]::new()
            $t['ids'].Add($s['id'])
            $t['spans'] = [System.Collections.Generic.List[object]]::new()
            $t['spans'].Add(@($s['start'], $s['end']))
            $out.Add($t)
        }
    }
    Sort-RsStable $out { param($t) , $t['start'] }
}

# Null when the sitting is drafted, else why not.
function Get-RsVerdict {
    param($Sitting)
    $t = $Sitting
    if ($null -eq $t['staff']) { return 'technician unknown (request not seen): a person checks' }
    if ($t['staff']) { return 'opened by client staff, not Relian: not drafted' }
    if (-not $t['device']) { return 'device no longer in NinjaOne: a person checks it' }
    if ($t['seconds'] -lt $script:RsMinSeconds) { return 'connection only (under a minute): not drafted' }
    if ($t['seconds'] -gt $script:RsMaxSeconds) { return 'over 4 h: a person checks it was not left connected' }
    return $null
}

# NinjaOne handle -> the task number that already carries it (Ref: NinjaOne a, b), so no session is drafted twice.
function Get-RsDrafted {
    param($Tasks)
    $out = [ordered]@{}
    foreach ($k in @($Tasks)) {
        foreach ($refs in [regex]::Matches([string]$k['description'], 'Ref: NinjaOne ([\d, ]+)')) {
            foreach ($h in [regex]::Matches($refs.Groups[1].Value, '\d+')) {
                if ($h.Value.Length -eq 10 -and -not $out.Contains($h.Value)) { $out[$h.Value] = $k['number'] }
            }
        }
    }
    return $out
}

function Get-RsBillableHours {
    param([double]$Seconds)
    return [math]::Max($script:RsRemoteMinHours, [math]::Ceiling([math]::Round($Seconds / 360, 6)) / 10)
}

# ---------------------------------------------------------------- Wazuh activity
$script:RsShells = [System.Collections.Generic.HashSet[string]]::new([string[]]@('cmd.exe', 'powershell.exe', 'pwsh.exe'))
$script:RsHelpers = [System.Collections.Generic.HashSet[string]]::new([string[]]@(
        'conhost.exe', 'rundll32.exe', 'dllhost.exe', 'backgroundtaskhost.exe', 'runtimebroker.exe', 'sihost.exe', 'ai.exe', 'consent.exe',
        'copilotapp_proxy.exe', 'msiexec.exe', 'searchprotocolhost.exe', 'searchfilterhost.exe', 'smartscreen.exe', 'taskhostw.exe',
        'ctfmon.exe', 'textinputhost.exe', 'wermgr.exe', 'onedrive.exe', 'securityhealthsystray.exe', 'ms-teams.exe', 'msteams.exe',
        'phoneexperiencehost.exe', 'widgets.exe', 'chcp.com', 'runonce.exe', 'msedgewebview2.exe', 'ie4uinit.exe',
        'wcchromenativemessaginghost.exe', 'wab.exe'))
# Named admin commands; anything else is not named.
$script:RsCommands = [System.Collections.Generic.HashSet[string]]::new([string[]]@(
        ('ping tracert pathping nslookup ipconfig netstat route arp netsh net net1 sc reg gpupdate gpresult ' +
        'sfc dism chkdsk whoami hostname systeminfo tasklist taskkill shutdown winget robocopy xcopy icacls ' +
        'takeown certutil klist dsregcmd repadmin dcdiag w32tm wevtutil schtasks bcdedit manage-bde powercfg ' +
        'cipher wmic curl msiexec dsquery dsget nltest qwinsta quser logoff').Split(' ') | ForEach-Object { $_ + '.exe' }))
$script:RsIgnoreCase = [System.Text.RegularExpressions.RegexOptions]'IgnoreCase, CultureInvariant'
# A shell running a script, not a person typing.
$script:RsScripted = [regex]::new('\s[-/](file|command|c|encodedcommand|enc|e|ec|executionpolicy|ep|noninteractive)\b', $script:RsIgnoreCase)
# Tray and updater apps Windows starts from Run keys, sometimes minutes after a slow sign-in: never a person's choice.
$script:RsStartup = [regex]::new('(Service|Installer|Setup|Assistant|Utility|notification icon|Agent UI|Tray|ClickOnce)( Application)?$', $script:RsIgnoreCase)
$script:RsSigninStartup = 60   # seconds after a sign-in (explorer.exe started by userinit.exe) in which explorer's children are Windows' own startup apps
$script:RsLabels = @{
    'msedge.exe' = 'Microsoft Edge'; 'chrome.exe' = 'Google Chrome'; 'firefox.exe' = 'Firefox'; 'cmd.exe' = 'Command Prompt'
    'powershell.exe' = 'PowerShell'; 'pwsh.exe' = 'PowerShell'; 'winword.exe' = 'Microsoft Word'; 'excel.exe' = 'Microsoft Excel'
    'outlook.exe' = 'Outlook'; 'olk.exe' = 'Outlook'; 'notepad.exe' = 'Notepad'; 'notepad++.exe' = 'Notepad++'; 'copilotapp.exe' = 'Copilot'
    'regedit.exe' = 'Registry Editor'; 'control.exe' = 'Control Panel'; 'systemsettings.exe' = 'Settings'; 'taskmgr.exe' = 'Task Manager'
    'explorer.exe' = 'File Explorer'
}
$script:RsSnapins = @{
    'dsa.msc' = 'Active Directory Users and Computers'; 'gpmc.msc' = 'Group Policy Management'; 'services.msc' = 'Services'
    'eventvwr.msc' = 'Event Viewer'; 'compmgmt.msc' = 'Computer Management'; 'devmgmt.msc' = 'Device Manager'; 'dnsmgmt.msc' = 'DNS'
    'dhcpmgmt.msc' = 'DHCP'; 'printmanagement.msc' = 'Print Management'; 'diskmgmt.msc' = 'Disk Management'; 'certlm.msc' = 'Certificates'
}

function Get-RsBase {
    param($Path)
    return @([regex]::Split([string]$Path, '[\\/]+'))[-1].ToLowerInvariant()
}

function Get-RsWords {
    param($Text)
    [regex]::Split(([string]$Text).ToLowerInvariant(), '[^a-z0-9]+') | Where-Object { $_ }
}

# A logged-on person, not a machine account (NAME$), a service account or a window-manager session.
function Test-RsPerson {
    param($User)
    $u = @([regex]::Split([string]$User, '\\+'))[-1]
    return [bool]$u -and -not $u.EndsWith('$') -and @('SYSTEM', 'LOCAL SERVICE', 'NETWORK SERVICE') -cnotcontains $u.ToUpperInvariant() -and $u -cnotmatch '^(DWM|UMFD)-\d+$'
}

# Event time in seconds, to the microsecond as Python's datetime keeps it.
function ConvertTo-RsEpoch {
    param([string]$Text)
    $dto = [DateTimeOffset]::Parse($Text, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal)
    return [math]::Floor(($dto.UtcTicks - [DateTimeOffset]::UnixEpoch.UtcTicks) / 10) / 1e6
}

function Get-RsOr { param($A, $B) if ($A) { $A } else { $B } }

# What was done in the connection windows Spans @(@(start, end), ...), from the device's Wazuh alerts.
function Get-RsActivity {
    param($Alerts, $Spans)
    $apps = [ordered]@{}
    $cmds = [ordered]@{}
    $inst = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.List[string]]::new()
    $startup = [System.Collections.Generic.HashSet[string]]::new()
    $packages = [System.Collections.Generic.List[object]]::new()
    $elev = 0
    $signin = -1e18
    $sorted = Sort-RsStable @($Alerts) { param($e) , [string](Get-RsOr $e['data']['win']['system']['systemTime'] '') }
    foreach ($e in @($sorted)) {
        $w = $e['data']['win']
        $sy = $w['system']
        $d = Get-RsOr $w['eventdata'] @{}
        if (-not $sy['systemTime']) { continue }
        $t = ConvertTo-RsEpoch $sy['systemTime']
        $inWindow = $false
        foreach ($span in @($Spans)) { if ($span[0] - $script:RsSlack -le $t -and $t -le $span[1] + $script:RsSlack) { $inWindow = $true; break } }
        if (-not $inWindow) { continue }
        $eid = [string]$sy['eventID']
        if (($eid -ceq '1033' -or $eid -ceq '11724') -and [string]$sy['providerName'] -ceq 'MsiInstaller') {
            # Timing proves nothing (updates by Intune, NinjaOne or the app itself land any time): only a package a person ran is ours.
            if ($eid -ceq '1033') {
                $f = @(([string]$d['data']).Split(',') | ForEach-Object { $_.Trim() })
                if ($f.Count -ge 4 -and $f[3] -ceq '0') {
                    $words = @(Get-RsWords $f[0])
                    $ours = $false
                    foreach ($p in $packages) {
                        if ($words.Count -and $p.Count -ge $words.Count) {
                            $ours = $true
                            for ($i = 0; $i -lt $words.Count; $i++) { if ($p[$i] -cne $words[$i]) { $ours = $false; break } }
                            if ($ours) { break }
                        }
                    }
                    if ($ours) {   # file name starts with the product name, word for word
                        if (-not $inst.Contains($f[0] + ' ' + $f[1])) { $inst.Add($f[0] + ' ' + $f[1]) }
                    } elseif (-not $seen.Contains($f[0] + ' ' + $f[1] + ' installed')) {
                        $seen.Add($f[0] + ' ' + $f[1] + ' installed')
                    }
                }
            } else {
                $m = [regex]::Match([string]$d['data'], '^Product: (.+?) -- Removal completed successfully')
                if ($m.Success -and -not $seen.Contains($m.Groups[1].Value + ' removed')) { $seen.Add($m.Groups[1].Value + ' removed') }
            }
            continue
        }
        if ($eid -cne '1' -and $eid -cne '4688') { continue }
        $exe = Get-RsBase (Get-RsOr $d['image'] $d['newProcessName'])
        $parent = Get-RsBase (Get-RsOr $d['parentImage'] $d['parentProcessName'])
        $user = Get-RsOr $d['user'] $d['subjectUserName']
        if ($exe -ceq 'msiexec.exe' -and (Test-RsPerson $user)) {
            $m = [regex]::Match([string]$d['commandLine'], '/i\s+[\\"]*([^"]+?\.msi)', $script:RsIgnoreCase)   # Wazuh keeps the quotes escaped: \"C:\...msi\"
            if ($m.Success) { $packages.Add(@(Get-RsWords (Get-RsBase $m.Groups[1].Value))) }   # the package a person ran
        }
        if ($exe -ceq 'consent.exe') {
            if ($eid -ceq '4688') { $elev++ }   # Sysmon's config leaves consent out; 4688 sees every UAC prompt once
            continue
        }
        # Agents (NinjaOne, Intune) run as SYSTEM or the machine account, so the person filter drops their work.
        # shortcut: a NinjaOne script run as the logged-on user would count its commands; follow processGuid lineage if that shows up.
        if (-not (Test-RsPerson $user)) { continue }
        if ($exe -ceq 'explorer.exe' -and $parent -ceq 'userinit.exe') { $signin = $t; continue }
        $desc = [string]$d['description']
        if ($script:RsShells.Contains($parent) -and -not $script:RsShells.Contains($exe) -and -not $script:RsHelpers.Contains($exe)) {
            $pcl = $d['parentCommandLine']
            if ($eid -ceq '1' -and $script:RsCommands.Contains($exe) -and $pcl -and -not $script:RsScripted.IsMatch($pcl)) {   # a typed command needs the shell's own command line as proof
                if (-not $cmds.Contains($exe)) { $cmds[$exe] = $exe.Substring(0, $exe.LastIndexOf('.')) }
            }
        } elseif ($exe -ceq 'mmc.exe') {
            $m = [regex]::Match([string]$d['commandLine'], '([\w-]+\.msc)', $script:RsIgnoreCase)
            if ($m.Success) {
                $k = $m.Groups[1].Value.ToLowerInvariant()
                if ($script:RsSnapins.ContainsKey($k) -and -not $apps.Contains('mmc:' + $k)) { $apps['mmc:' + $k] = $script:RsSnapins[$k] }   # a custom console's file name is not ours to print
            }
        } elseif (-not $script:RsHelpers.Contains($exe) -and $parent -ceq 'explorer.exe' -and $t - $signin -gt $script:RsSigninStartup) {   # opened from the desktop, Start or taskbar
            if ($apps.Contains($exe) -and $null -eq $apps[$exe] -and $desc -and -not $script:RsStartup.IsMatch($desc)) {
                $apps[$exe] = [regex]::Replace($desc.Trim(), '\s+(MFC )?Application$', '')
                continue
            }
            if ($script:RsStartup.IsMatch($desc) -or $exe.Contains('systray') -or @('sentinelui.exe', 'fsquirt.exe', 'chrmstp.exe', 'setup.exe', 'acrotray.exe') -ccontains $exe) {
                [void]$startup.Add($exe)   # 4688 has no description: the Sysmon twin of the same start decides for both
                continue
            }
            $desc = [regex]::Replace($desc.Trim(), '\s+(MFC )?Application$', '')
            if ($script:RsLabels.ContainsKey($exe) -or $desc) {   # never a bare file name: it can carry a person or a host
                if (-not $apps.Contains($exe)) { $apps[$exe] = Get-RsOr $script:RsLabels[$exe] $desc }
            } elseif ($eid -ceq '4688') {
                if (-not $apps.Contains($exe)) { $apps[$exe] = $null }   # 4688 has no description: hold the place, the Sysmon twin names it
            }
        }
    }
    $named = [System.Collections.Generic.List[string]]::new()
    foreach ($k in $apps.Keys) { $v = $apps[$k]; if (-not $startup.Contains($k) -and $v -and -not $named.Contains($v)) { $named.Add($v) } }
    return [ordered]@{ installed = @($inst); observed = @($seen); apps = @($named); commands = @($cmds.Values); elevations = $elev }
}

# The hits if every Windows event came from the NinjaOne device's own DNS name, else none and why.
function Select-RsSameHost {
    param($Hits, $Dns)
    if (-not $Dns) { return [ordered]@{ hits = @(); note = 'the NinjaOne device has no DNS name to check the Wazuh agent against: activity not read' } }
    foreach ($h in @($Hits)) {
        $c = $h['data']['win']['system']['computer']
        if (([string]$c).ToLowerInvariant() -cne ([string]$Dns).ToLowerInvariant()) {   # fail closed: an event that does not name its computer is not proof of this one
            return [ordered]@{ hits = @(); note = "the Wazuh agent $(([string]$Dns).Split('.')[0]) is another computer ($(Get-RsOr $c '(none)')): activity not read" }
        }
    }
    return [ordered]@{ hits = @($Hits); note = '' }
}

# The one Wazuh agent id that reported under this host name in the last 30 days (terms buckets of agent.id), or why not.
# A host name is not unique across clients: two agents with it means no activity is read rather than the wrong client's.
function Get-RsAgentFor {
    param($Buckets, [string]$Name)
    $b = @($Buckets)
    if ($b.Count -gt 1) { return [ordered]@{ agent = $null; note = "two Wazuh agents are named $($Name): activity not read" } }
    if ($b.Count -eq 1) { return [ordered]@{ agent = $b[0]['key']; note = '' } }
    return [ordered]@{ agent = $null; note = "no Wazuh agent named $Name" }
}

# ---------------------------------------------------------------- task text (billing-entry style: no names, no host, no file names)
# On Linux the IANA id; on Windows .NET maps it to the Windows zone.
$script:RsZone = [TimeZoneInfo]::FindSystemTimeZoneById('America/Vancouver')
$script:RsInvariant = [cultureinfo]::InvariantCulture

$script:RsBcUtc7From = 1772964000   # 2026-03-08 10:00 UTC: BC moved its clocks to UTC-7 and stays there (permanent daylight time)

function Get-RsClock {
    param([double]$Ts)
    $instant = [DateTimeOffset]::FromUnixTimeMilliseconds([long][math]::Floor($Ts * 1000))
    # shortcut: fixed UTC-7 from 2026 so a host whose time zone data predates the change does not print 6:32 for 7:32; drop once every host has 2026+ data
    if ($Ts -ge $script:RsBcUtc7From) { return $instant.ToOffset([timespan]::FromHours(-7)) }
    return [TimeZoneInfo]::ConvertTime([DateTimeOffset]::FromUnixTimeMilliseconds([long][math]::Floor($Ts * 1000)), $script:RsZone)
}

function Format-RsSpan {
    param([double]$Start, [double]$End)
    $a = Get-RsClock $Start
    $b = Get-RsClock $End
    $hm = { param($x) $h = $x.Hour % 12; if ($h -eq 0) { $h = 12 }; '{0}:{1:00}' -f $h, $x.Minute }
    $ap = { param($x) if ($x.Hour -lt 12) { 'AM' } else { 'PM' } }
    $first = (& $hm $a) + $(if ((& $ap $a) -ceq (& $ap $b)) { '' } else { ' ' + (& $ap $a) })
    return "$($a.ToString('MMM', $script:RsInvariant)) $($a.Day), $first-$(& $hm $b) $(& $ap $b) PT"
}

function Join-RsAnd {
    param([string[]]$Items)
    if ($Items.Count -eq 1) { return $Items[0] }
    return ($Items[0..($Items.Count - 2)] -join ', ') + ' and ' + $Items[-1]
}

function Get-RsHandles {
    param($Ids)
    (@($Ids) | ForEach-Object { if ($_.Length -gt 10) { $_.Substring(0, 10) } else { $_ } }) -join ', '
}

function Format-RsDescription {
    param($Sitting, $Activity)
    $t = $Sitting
    $act = $Activity
    $where = if ($t['server']) { 'the server' } else { "a staff member's computer" }
    if (@($act['installed']).Count) {
        $topic = if ($t['server']) { 'Server maintenance' } else { 'Computers' }
        $head = "$($topic): installed $(Join-RsAnd @($act['installed'])) on $where by remote session, so staff have the software they need."
    } elseif ($t['server']) {
        $head = 'Server maintenance: checked and maintained the server by remote session, so issues are found before they slow the office down.'
    } elseif (@($act['apps']).Count -or @($act['commands']).Count) {
        $shown = @($act['apps'] | Select-Object -First 2) -join ', '
        $head = "Computers: worked with a staff member on their computer by remote session$(if ($shown) { " ($shown)" }), so they could keep working."
    } else {
        $head = 'Computers: checked a staff computer by remote session, so problems are caught early.'   # nothing seen: claim no more than a check
    }
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add($head)
    foreach ($pair in @(@('Installed', 'installed'), @('Apps opened', 'apps'), @('Commands run', 'commands'))) {   # 'observed' is for the reviewer only
        if (@($act[$pair[1]]).Count) { $lines.Add("- $($pair[0]): " + (@($act[$pair[1]]) -join ', ')) }
    }
    if ($act['elevations']) { $lines.Add("- Administrator prompts: $($act['elevations'])") }   # consent.exe starts; a prompt can be cancelled
    $minutes = [math]::Max(1, [long][math]::Round($t['seconds'] / 60))   # half to even, as Python's round
    $lines.Add("Remote session $(Format-RsSpan $t['start'] $t['end']) ($minutes min). Ref: NinjaOne $(Get-RsHandles $t['ids'])")
    return $lines -join "`n"
}

# The old pipeline's task for this sitting: same device in its Computer: line, first time-log start within 10 minutes.
# Null when another NinjaOne device has the same name (the old task names no client, so it cannot be told apart).
function Find-RsOldTask {
    param($Sitting, $Tasks, [switch]$Shared)
    if ($Shared) { return $null }
    foreach ($k in @($Tasks)) {
        $m = [regex]::Match([string]$k['description'], '^Computer: (.+)$', 'Multiline')
        $log = ConvertFrom-Json -InputObject (Get-RsOr $k['time_log'] '[]') -NoEnumerate
        if ($m.Success -and @($log).Count -and $m.Groups[1].Value.Trim().ToUpperInvariant() -ceq ([string]$Sitting['device']).ToUpperInvariant() -and
            [math]::Abs($log[0][0] - $Sitting['start']) -le 600) {
            return $k
        }
    }
    return $null
}

# ---------------------------------------------------------------- -Apply: Backlog tasks in Invoice Ninja (create only: never sends, invoices or emails)

# The task for one drafted sitting: no rate (the client's Invoice Ninja default applies), billable hours as the time log.
function New-RsTaskBody {
    param($Row, [string]$ClientId, [string]$StatusId)
    $start = [long]$Row['start']
    $end = $start + [long][math]::Round([double]$Row['hours'] * 3600)
    return [ordered]@{
        client_id   = $ClientId
        description = $Row['draft']
        status_id   = $StatusId
        time_log    = '[[{0},{1},"",true]]' -f $start, $end
        date        = (Get-RsClock $start).ToString('yyyy-MM-dd', $script:RsInvariant)
    }
}

# One Backlog task per drafted sitting that no task carries yet; returns one report line per task created or skipped.
function Invoke-RsApply {
    param($Rows, $ClientMap)
    $todo = @(@($Rows) | Where-Object { -not $_['skip'] -and -not $_['alreadyDrafted'] })
    if (-not $todo.Count) { return }
    $base = ([string]$env:INVOICENINJA_API_URL).TrimEnd('/') + '/api/v1/'
    $headers = @{ 'X-API-TOKEN' = $env:INVOICENINJA_API_KEY; 'X-Requested-With' = 'XMLHttpRequest' }
    $statuses = (Invoke-RsHttp -Method GET -Uri ($base + 'task_statuses?per_page=500') -Headers $headers)['data']
    $backlog = @(@($statuses) | Where-Object { $_['name'] -ceq 'Backlog' -and -not $_['is_deleted'] })
    if (-not $backlog.Count) { throw 'Invoice Ninja has no task status named Backlog; nothing created' }
    foreach ($r in $todo) {
        $handles = Get-RsHandles $r['ids']
        $client = $ClientMap["$($r['org'])"]
        if (-not $client) { "skipped NinjaOne $($handles): organization $($r['org']) is not in the client map"; continue }
        $body = ConvertTo-Json -InputObject (New-RsTaskBody -Row $r -ClientId $client -StatusId $backlog[0]['id']) -Compress
        $created = Invoke-RsHttp -Method POST -Uri ($base + 'tasks') -Headers $headers -Body $body
        "created task $($created['data']['number']) for NinjaOne $handles"
    }
}

# ---------------------------------------------------------------- HTTP (the one network boundary; tests replace it)

$script:RsPinSource = @'
using System;
using System.Net.Http;
using System.Net.Security;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;

public sealed class RelianCertPin {
    private readonly string expected;
    public bool Mismatch;
    public RelianCertPin(string sha256Hex) { expected = sha256Hex; }
    public bool Check(HttpRequestMessage message, X509Certificate2 certificate, X509Chain chain, SslPolicyErrors errors) {
        bool ok = certificate != null && string.Equals(Convert.ToHexString(SHA256.HashData(certificate.RawData)), expected, StringComparison.Ordinal);
        if (!ok) { Mismatch = true; }
        return ok;
    }
    public Func<HttpRequestMessage, X509Certificate2, X509Chain, SslPolicyErrors, bool> Callback { get { return Check; } }
}
'@

# The indexer's self-signed certificate is trusted by its SHA-256 alone, checked in the TLS handshake before anything is sent.
function New-RsPin {
    param([string]$Sha256)
    $hex = ([string]$Sha256).ToUpperInvariant() -replace '[^0-9A-F]', ''
    if ($hex.Length -ne 64) { throw 'WAZUH_INDEXER_SHA256 is not a SHA-256 fingerprint' }
    if (-not ('RelianCertPin' -as [type])) { Add-Type -TypeDefinition $script:RsPinSource }
    return ('RelianCertPin' -as [type])::new($hex)
}

function Invoke-RsHttp {
    param([string]$Method, [string]$Uri, [hashtable]$Headers = @{}, [string]$Body, [string]$ContentType = 'application/json', [string]$PinSha256)
    $handler = [System.Net.Http.HttpClientHandler]::new()
    $pin = $null
    if ($PinSha256) {
        $pin = New-RsPin $PinSha256
        $handler.ServerCertificateCustomValidationCallback = $pin.Callback
    }
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [timespan]::FromSeconds(300)
    try {
        $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::new($Method), $Uri)
        [void]$request.Headers.TryAddWithoutValidation('User-Agent', 'curl/8')
        foreach ($k in $Headers.Keys) { [void]$request.Headers.TryAddWithoutValidation($k, [string]$Headers[$k]) }
        if ($PSBoundParameters.ContainsKey('Body')) { $request.Content = [System.Net.Http.StringContent]::new($Body, [System.Text.Encoding]::UTF8, $ContentType) }
        try {
            $response = $client.SendAsync($request).GetAwaiter().GetResult()
        } catch {
            if ($pin -and $pin.Mismatch) { throw 'Wazuh indexer certificate does not match the pinned SHA-256; nothing sent' }
            throw "$Method $(([uri]$Uri).Host) failed: $($_.Exception.InnerException.Message)"
        }
        $text = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) { throw "$Method $(([uri]$Uri).AbsolutePath): HTTP $([int]$response.StatusCode)" }
        if (-not $text) { return $null }
        return ConvertFrom-Json -InputObject $text -AsHashtable -NoEnumerate -DateKind String
    } finally {
        $client.Dispose()
    }
}

# ---------------------------------------------------------------- live reads

function Get-RsNinja {
    param([long]$Since)
    $b = ([string]$env:NINJAONE_BASE_URL).TrimEnd('/')
    $form = 'grant_type=client_credentials&client_id=' + [uri]::EscapeDataString([string]$env:NINJAONE_CLIENT_ID) +
        '&client_secret=' + [uri]::EscapeDataString([string]$env:NINJAONE_CLIENT_SECRET) + '&scope=monitoring'
    $token = (Invoke-RsHttp -Method POST -Uri "$b/ws/oauth/token" -Body $form -ContentType 'application/x-www-form-urlencoded')['access_token']
    $h = @{ Authorization = "Bearer $token" }
    $acts = [System.Collections.Generic.List[object]]::new()
    $older = $null
    while ($true) {   # olderThan=<id> pages backwards; startTime/endTime return nothing
        $uri = "$b/v2/activities?type=NINJA_REMOTE&pageSize=1000" + $(if ($null -ne $older) { "&olderThan=$older" })
        $page = @(Get-RsOr (Invoke-RsHttp -Method GET -Uri $uri -Headers $h)['activities'] @())
        if (-not $page.Count) { break }
        $minTime = [double]::MaxValue
        $minId = [double]::MaxValue
        foreach ($a in $page) {
            if ($a['activityTime'] -ge $Since) { $acts.Add($a) }
            $minTime = [math]::Min($minTime, [double]$a['activityTime'])
            $minId = [math]::Min($minId, [double]$a['id'])
        }
        if ($minTime -lt $Since -or ($null -ne $older -and $minId -ge $older)) { break }
        $older = [long]$minId
    }
    $devices = Invoke-RsHttp -Method GET -Uri "$b/v2/devices" -Headers $h   # a list as one value: @() around the call would nest it
    return @{ activities = @($acts); devices = $devices }
}

# The device's alerts in the window, from the one agent with this host name: hits, whether the indexer cut them, and why none.
function Get-RsWazuh {
    param([string]$Url, [string]$Device, [long]$Start, [long]$End)
    $auth = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("$($env:WAZUH_INDEXER_USER):$($env:WAZUH_INDEXER_PASSWORD)"))
    $search = {
        param($Query)
        Invoke-RsHttp -Method POST -Uri ($Url.TrimEnd('/') + '/wazuh-alerts-*/_search') -Headers @{ Authorization = "Basic $auth" } -PinSha256 $env:WAZUH_INDEXER_SHA256 -Body (ConvertTo-Json -InputObject $Query -Depth 12 -Compress)
    }
    $iso = { param($t) [DateTimeOffset]::FromUnixTimeSeconds($t).ToString("yyyy-MM-dd'T'HH:mm:ss'+00:00'", [cultureinfo]::InvariantCulture) }
    $names = @(@($Device, $Device.ToUpperInvariant(), $Device.ToLowerInvariant()) | Sort-Object -Unique -CaseSensitive)
    $ids = (& $search @{ size = 0; query = @{ bool = @{ filter = @(@{ terms = @{ 'agent.name' = $names } }, @{ range = @{ timestamp = @{ gte = (& $iso ($End - 30 * 86400)) } } }) } }
            aggs = @{ a = @{ terms = @{ field = 'agent.id'; size = 10 } } } })['aggregations']['a']['buckets']
    $agent = Get-RsAgentFor -Buckets @($ids) -Name $Device
    if (-not $agent['agent']) { return @{ hits = @(); cut = $false; note = $agent['note'] } }
    $data = & $search @{ size = 10000; sort = @(@{ timestamp = 'asc' }); track_total_hits = $true; query = @{ bool = @{ filter = @(
                    @{ term = @{ 'agent.id' = $agent['agent'] } },
                    @{ terms = @{ 'data.win.system.eventID' = @('1', '4688', '1033', '11724') } },
                    @{ range = @{ timestamp = @{ gte = (& $iso ($Start - 300)); lte = (& $iso ($End + 300)) } } }) } } }   # ingest time can lag event time
    $hits = @(@($data['hits']['hits']) | Where-Object { $_ } | ForEach-Object { $_['_source'] })
    return @{ hits = $hits; cut = $data['hits']['total']['value'] -gt $hits.Count; note = '' }
}

# Invoice Ninja tasks created since then (GET): the old pipeline's task beside each draft, and the handles already drafted.
function Get-RsTasks {
    param([long]$Since)
    $base = ([string]$env:INVOICENINJA_API_URL).TrimEnd('/') + '/api/v1/'
    $h = @{ 'X-API-TOKEN' = $env:INVOICENINJA_API_KEY; 'X-Requested-With' = 'XMLHttpRequest' }
    $out = [System.Collections.Generic.List[object]]::new()
    $page = 1
    while ($true) {
        $r = Invoke-RsHttp -Method GET -Uri ($base + "tasks?per_page=500&page=$page&sort=created_at|desc") -Headers $h
        $data = @(Get-RsOr $r['data'] @())
        foreach ($t in $data) { if ($t['created_at'] -ge $Since - 86400) { $out.Add($t) } }
        if (-not $data.Count -or $data[-1]['created_at'] -lt $Since - 86400 -or $page -ge $r['meta']['pagination']['total_pages']) { return @($out) }
        $page++
    }
}

# ---------------------------------------------------------------- the report

# Python's str() of a value, so the dry run prints what the Python tool printed.
function Format-RsPy {
    param($Value)
    if ($null -eq $Value) { return 'None' }
    if ($Value -is [bool]) { return $(if ($Value) { 'True' } else { 'False' }) }
    if ($Value -is [double]) { $s = $Value.ToString('R', [cultureinfo]::InvariantCulture); if ($s -notmatch '[.E]') { $s += '.0' }; return $s }
    return [string]$Value
}

function Invoke-RsMain {
    param([double]$Days, [string]$IndexerUrl, [string]$Json, [switch]$Apply, [string]$ClientMap)
    $map = $null
    if ($Apply) {
        if (-not $ClientMap) { throw '-Apply needs -ClientMap: a JSON file of NinjaOne organizationId -> Invoice Ninja client id' }
        $map = Get-Content -LiteralPath $ClientMap -Raw | ConvertFrom-Json -AsHashtable
    }
    foreach ($name in 'NINJAONE_BASE_URL', 'NINJAONE_CLIENT_ID', 'NINJAONE_CLIENT_SECRET', 'WAZUH_INDEXER_USER', 'WAZUH_INDEXER_PASSWORD',
        'WAZUH_INDEXER_SHA256', 'INVOICENINJA_API_URL', 'INVOICENINJA_API_KEY') {
        if (-not [Environment]::GetEnvironmentVariable($name)) { throw "$name is not set" }
    }
    $since = [long][math]::Truncate([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() / 1000 - $Days * 86400)
    $ninja = Get-RsNinja -Since ($since - 86400)   # a day of lookback, so a session's request and end are seen whatever the cutoff
    $devices = @($ninja['devices'])
    $tasks = @(Get-RsTasks -Since $since)
    $doneMap = Get-RsDrafted -Tasks $tasks
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($t in @(Get-RsSittings -Sessions @(Get-RsSessions -Activities $ninja['activities'] -Devices $devices))) {
        if ($t['start'] -lt $since) { continue }
        $why = Get-RsVerdict $t
        $done = $null
        foreach ($i in $t['ids']) { $h = Get-RsHandles @($i); if ($doneMap.Contains($h)) { $done = $doneMap[$h]; break } }
        $w = if (-not $why) { Get-RsWazuh -Url $IndexerUrl -Device $t['device'] -Start $t['start'] -End $t['end'] } else { @{ hits = @(); cut = $false; note = '' } }
        $hits = @($w['hits'])
        $note = $w['note']
        if (-not $note) { $same = Select-RsSameHost -Hits $hits -Dns $t['dns']; $hits = @($same['hits']); $note = $same['note'] }
        $shared = @($devices | Where-Object { ([string]$_['systemName']).ToUpperInvariant() -ceq ([string]$t['device']).ToUpperInvariant() }).Count -gt 1
        if ($shared) { $hits = @(); $note = "two NinjaOne devices are named $($t['device']): activity not read" }
        $act = if (-not $why) { Get-RsActivity -Alerts $hits -Spans @($t['spans']) } else { $null }
        $old = Find-RsOldTask -Sitting $t -Tasks $tasks -Shared:$shared
        $oldHours = $null
        if ($old) {
            $sum = 0
            foreach ($x in @(ConvertFrom-Json -InputObject $old['time_log'] -NoEnumerate)) { if ($x[1]) { $sum += $x[1] - $x[0] } }
            $oldHours = [math]::Round($sum / 3600, 2)
        }
        $rows.Add([ordered]@{
                device = $t['device']; org = $t['org']; start = $t['start']; seconds = $t['seconds']; ids = @($t['ids']); skip = $why
                wazuhEvents = $hits.Count; wazuhCut = $w['cut']; wazuhNote = $note; observed = $(if ($act) { $act['observed'] })
                hours = $(if ($why) { $null } else { Get-RsBillableHours $t['seconds'] }); draft = $(if ($why) { $null } else { Format-RsDescription -Sitting $t -Activity $act })
                alreadyDrafted = $done
                old = $(if ($old) { [ordered]@{ number = $old['number']; hours = [double]$oldHours; text = $old['description'] } })
            })
    }
    foreach ($r in $rows) {
        '=' * 100
        "$(Format-RsSpan $r['start'] ($r['start'] + $r['seconds']))  device $(Format-RsPy $r['device'])  org $(Format-RsPy $r['org'])  $($r['seconds']) s  sessions $(@($r['ids']).Count)"
        'NEW: ' + $(if ($r['skip']) { $r['skip'] } else { "$(([double]$r['hours']).ToString('0.0', $script:RsInvariant)) h" + $(if ($r['alreadyDrafted']) { " (already drafted as task $($r['alreadyDrafted']))" }) })
        if ($r['draft']) {
            $tail = if ($r['wazuhNote']) { ' - ' + $r['wazuhNote'] } elseif (-not $r['wazuhEvents']) { ' - no Wazuh data for this device, activity unknown' } else { '' }
            "[Wazuh: $($r['wazuhEvents']) events$(if ($r['wazuhCut']) { ', TRUNCATED' })$tail]"
            $r['draft']
            if (@($r['observed']).Count) { '[Also seen, not attributed: ' + (@($r['observed']) -join '; ') + ']' }
        }
        'OLD: ' + $(if ($r['old']) { "task $($r['old']['number']), $(Format-RsPy $r['old']['hours']) h: " + ([string]$r['old']['text']).Split("`n")[0] } else { 'no task' })
    }
    if ($Json) { ConvertTo-Json -InputObject @($rows) -Depth 8 | Set-Content -LiteralPath $Json -Encoding utf8 }
    $drafts = @($rows | Where-Object { -not $_['skip'] })
    $total = 0.0
    foreach ($r in $drafts) { $total += $r['hours'] }
    $written = 'Nothing written.'
    if ($Apply) {
        $report = @(Invoke-RsApply -Rows @($rows) -ClientMap $map)
        $report
        $written = "$(@($report | Where-Object { $_ -like 'created *' }).Count) tasks created in Backlog; nothing sent, invoiced or emailed."
    }
    ''
    "$($rows.Count) sittings: $($drafts.Count) drafted, $($total.ToString('0.0', $script:RsInvariant)) h; $($rows.Count - $drafts.Count) not drafted. $written"
}

if ($env:RELIAN_DEPLOY_TEST -ne '1') {
    try {
        Invoke-RsMain -Days $Days -IndexerUrl $IndexerUrl -Json $Json -Apply:$Apply -ClientMap $ClientMap
    } catch {
        [Console]::Error.WriteLine("remote-sessions: $($_.Exception.Message)")
        exit 1
    }
}
