# Offline checks for scripts/remote-sessions.ps1, on anonymised captures (tests/fixtures/remote-sessions-*.json). No network.
# The fixtures are real NinjaOne NINJA_REMOTE activities and Wazuh alerts from November 2026 with names, users, hosts and
# addresses replaced. Expected values are read off those captures by hand (durations are NinjaOne's own "duration" field).
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'scripts/remote-sessions.ps1'
$fixtures = Join-Path $PSScriptRoot 'fixtures'

function Fail {
    param([string]$Message)
    [Console]::Error.WriteLine("FAIL $Message")
    exit 1
}

# Compares the compact JSON of a value with a literal, so lists, nulls and booleans are checked exactly.
function Assert-Json {
    param($Actual, [string]$Expected, [string]$Label)
    $json = ConvertTo-Json -InputObject $Actual -Compress -Depth 8
    if ($json -cne $Expected) { Fail "$Label was [$json] expected [$Expected]" }
}

function Assert-Same {
    param($Actual, $Expected, [string]$Label)
    $same = if ($null -eq $Expected -or $null -eq $Actual) { $null -eq $Expected -and $null -eq $Actual } else { $Actual -ceq $Expected }
    if (-not $same) { Fail "$Label was [$Actual] expected [$Expected]" }
}

$script:n = 0
function Ok { param([string]$Name) $script:n++; Write-Output "ok $Name" }

function Load { param([string]$Name) Get-Content -LiteralPath (Join-Path $fixtures $Name) -Raw | ConvertFrom-Json -AsHashtable -DateKind String }

# A shallow copy with some keys replaced, as Python's dict(d, k=v).
function With {
    param([System.Collections.IDictionary]$Base, [hashtable]$Changes)
    $copy = [ordered]@{}
    foreach ($k in $Base.Keys) { $copy[$k] = $Base[$k] }
    foreach ($k in $Changes.Keys) { $copy[$k] = $Changes[$k] }
    return $copy
}

$env:RELIAN_DEPLOY_TEST = '1'
Set-StrictMode -Off
. $scriptPath
Set-StrictMode -Version Latest

$NINJA = Load 'remote-sessions-ninja.json'

# ---------------------------------------------------------------- sessions: NinjaOne's own start, end and technician
$S = @{}
foreach ($one in @(Get-RsSessions -Activities $NINJA['activities'] -Devices $NINJA['devices'])) { $S[$one['id']] = $one }
Assert-Json @($S.Keys | Sort-Object) '["4314106653211F90KWGWV6ZLP8MKVO2N","4714976556211F90SYUAUQ68SHGNRGV3","5592750678211F90GUEAWF29GATLVYSJ","8230077061211F90SPBXYUBL6AGF0HNI","9872937265211F90OFIRX2GXWY4HJSKI"]' 'session ids'
Ok 'sessions: only connections that were established; requests and failed starts are not sessions'

$w = $S['5592750678211F90GUEAWF29GATLVYSJ']
Assert-Json @($w['device'], $w['server'], $w['start'], $w['end'], $w['seconds'], $w['tech'], $w['staff']) '["PC-01",false,1795111385,1795113834,2448,"Relian Tech",false]' 'workstation session'
Ok 'sessions: start = established, end = terminated, seconds = NinjaOne duration, technician from the request'

Assert-Same $S['4714976556211F90SYUAUQ68SHGNRGV3']['server'] $true 'server is server'
Assert-Same $S['9872937265211F90OFIRX2GXWY4HJSKI']['staff'] $true 'client user is staff'
Ok 'sessions: a server is a server; a connection by a client user (not a Relian address) is marked staff'

$noReq = @($NINJA['activities'] | Where-Object { -not ($_['data']['sessionName'].StartsWith('5592750678') -and $_['data']['message']['code'] -eq 'nc_session_requested') })
$lost = @(Get-RsSessions -Activities $noReq -Devices $NINJA['devices'] | Where-Object { $_['id'].StartsWith('5592750678') })[0]
Assert-Same $lost['staff'] $null 'request not seen: staff unknown'
Assert-Same (Get-RsVerdict (With $lost @{ ids = @($lost['id']) })) 'technician unknown (request not seen): a person checks' 'request not seen verdict'
Ok 'sessions: a connection whose request is outside the pull is not taken for client staff; a person checks it'

# NinjaOne also logs a request and a termination (duration "0", one participant) with no established record: not a session.
$requestOnly = @(@{ id = 1; activityTime = 1795111380; deviceId = 1001; activityType = 'NINJA_REMOTE'; data = @{ sessionName = 'X1'; message = @{ code = 'nc_session_requested'; params = @{ appUserEmail = 'tech@relian.ca' } } } },
    @{ id = 2; activityTime = 1795111390; deviceId = 1001; activityType = 'NINJA_REMOTE'; data = @{ sessionName = 'X1'; message = @{ code = 'nc_session_terminated_with_handle'; params = @{ duration = '0'; participants = '[PLAYER]' } } } })
Assert-Same @(Get-RsSessions -Activities $requestOnly -Devices $NINJA['devices']).Count 0 'request and termination only'
Assert-Same @(Get-RsSittings -Sessions @()).Count 0 'no sessions, no sittings'
Ok 'sessions: a request that ended without a connection is not a session, and none at all is an empty report'

# ---------------------------------------------------------------- sittings and verdicts
$sittingList = @(Get-RsSittings -Sessions @($S.Values))
$by = @{}
foreach ($one in $sittingList) { $by[$one['ids'][0]] = $one }
$srv2 = $by['4314106653211F90KWGWV6ZLP8MKVO2N']
Assert-Json $srv2['ids'] '["4314106653211F90KWGWV6ZLP8MKVO2N","8230077061211F90SPBXYUBL6AGF0HNI"]' 'srv2 ids'
Assert-Same $srv2['seconds'] 20 'srv2 seconds'
Ok 'sittings: two connections to one device 13 minutes apart are one sitting of 20 s (13 + 7)'

$ws1 = $by['5592750678211F90GUEAWF29GATLVYSJ']
Assert-Same (Get-RsVerdict $srv2) 'connection only (under a minute): not drafted' 'under a minute'
Assert-Same (Get-RsVerdict $by['9872937265211F90OFIRX2GXWY4HJSKI']) 'opened by client staff, not Relian: not drafted' 'staff'
Assert-Same (Get-RsVerdict $ws1) $null 'normal session'
Assert-Same (Get-RsVerdict (With $ws1 @{ device = $null })) 'device no longer in NinjaOne: a person checks it' 'device gone'
Assert-Same (Get-RsVerdict (With $ws1 @{ seconds = 4 * 3600 + 1 })) 'over 4 h: a person checks it was not left connected' 'over 4 h'
Ok 'verdicts: under a minute, client staff and over 4 h are not drafted; a normal session is'

$apart = @(Get-RsSittings -Sessions @((With $w @{ id = 'a'; start = 0; end = 600; seconds = 600 }), (With $w @{ id = 'b'; start = 600 + 901; end = 2000; seconds = 499 })))
Assert-Json @($apart | ForEach-Object { , @($_['ids']) }) '[["a"],["b"]]' 'apart'
Ok 'sittings: a gap over 15 minutes starts a new sitting'

$twins = @(Get-RsSittings -Sessions @((With $w @{ id = 'a'; start = 0; end = 600; seconds = 600 }), (With $w @{ id = 'b'; deviceId = 'dev-z'; org = 'org-z'; start = 700; end = 1300; seconds = 600 })))
Assert-Json @($twins | ForEach-Object { , @($_['ids']) }) '[["a"],["b"]]' 'twins'
Ok 'sittings: two devices with the same name (two clients) never merge; the NinjaOne device id decides'

Assert-Json $srv2['spans'] '[[1795181294,1795181307],[1795182082,1795182090]]' 'srv2 spans'
$both = @(Get-RsSittings -Sessions @((With $w @{ id = 'a'; start = 0; end = 600; seconds = 600 }), (With $w @{ id = 'b'; start = 0; end = 600; seconds = 600 }), (With $w @{ id = 'c'; start = 300; end = 900; seconds = 600 })))
Assert-Json @($both | ForEach-Object { , @(@($_['ids']), $_['seconds']) }) '[[["a","b","c"],900]]' 'overlap'
Ok 'sittings: overlapping connections (two windows open at once) count their elapsed time once'
Ok 'sittings: keep each connection window, so the time between connections is not searched for activity'

# ---------------------------------------------------------------- hours: 0.5 h minimum, then 0.1 h steps (Support Terms Schedule A)
Assert-Json @(628, 1800, 1801, 2356, 2448, (3 * 3600) | ForEach-Object { Get-RsBillableHours $_ }) '[0.5,0.5,0.6,0.7,0.7,3.0]' 'hours'
Ok 'hours: 0.5 h minimum, rounded up to 0.1 h'

# ---------------------------------------------------------------- activity from Wazuh alerts
$inst = Get-RsActivity -Alerts (Load 'remote-sessions-wazuh-install.json') -Spans @(, @(1794882750, 1794885107))
Assert-Json $inst['installed'] '["SL2100 PC Pro 5.30.00"]' 'install installed'
Assert-Json $inst['observed'] '[]' 'install observed'
Assert-Json $inst['apps'] '["Command Prompt","AppMgrPx"]' 'install apps'   # Edge only ran on from before (its own child processes): not opened
Assert-Json $inst['commands'] '["ping"]' 'install commands'
Assert-Same $inst['elevations'] 1 'install elevations'
Ok 'activity (server): the install by name and version from MsiInstaller, apps the admin opened, commands typed, one UAC approval'

$wsAlerts = Load 'remote-sessions-wazuh-workstation.json'
$ws = Get-RsActivity -Alerts $wsAlerts -Spans @(, @(1795111385, 1795113834))
Assert-Json $ws['apps'] '["Notepad","Microsoft Word","Notepad++","Microsoft Edge","Copilot"]' 'workstation apps'   # launch order in the capture
Assert-Json @($ws['installed'], $ws['commands'], $ws['elevations']) '[[],[],2]' 'workstation rest'
Ok 'activity (workstation): background work by Intune, NinjaOne scripts and services is left out'

$sysmonConsent = @{ timestamp = ''; data = @{ win = @{ system = @{ eventID = '1'; systemTime = '2026-11-19T18:07:42.0000000Z' }
            eventdata = @{ image = 'C:\Windows\System32\consent.exe'; parentImage = 'C:\Windows\System32\svchost.exe'; user = 'NT AUTHORITY\SYSTEM' } } } }
Assert-Same (Get-RsActivity -Alerts (@($wsAlerts) + $sysmonConsent) -Spans @(, @(1795111385, 1795113834)))['elevations'] 2 'consent twice'
Ok 'activity: a UAC prompt seen by both Sysmon and 4688 counts once'

function Msi {
    param([string]$Eid, [string]$Data)
    @{ data = @{ win = @{ system = @{ eventID = $Eid; providerName = 'MsiInstaller'; systemTime = '2026-11-19T18:30:00.0000000Z' }; eventdata = @{ data = $Data } } } }
}
$bg = Get-RsActivity -Alerts @((Msi '1033' 'Unattended Update, 1.2.3, 1033, 0, Vendor'), (Msi '11724' 'Product: Old Tool -- Removal completed successfully.')) -Spans @(, @(1795111385, 1795113834))
Assert-Json @($bg['installed'], $bg['observed']) '[[],["Unattended Update 1.2.3 installed","Old Tool removed"]]' 'background install'
Ok 'activity: an install or removal no person started is only observed, never claimed as our work'

Assert-Json (Get-RsAgentFor -Buckets @(@{ key = '021' }, @{ key = '107' }) -Name 'PC-01') '{"agent":null,"note":"two Wazuh agents are named PC-01: activity not read"}' 'two agents'
Assert-Json (Get-RsAgentFor -Buckets @(@{ key = '021' }) -Name 'PC-01') '{"agent":"021","note":""}' 'one agent'
Assert-Json (Get-RsAgentFor -Buckets @() -Name 'PC-01') '{"agent":null,"note":"no Wazuh agent named PC-01"}' 'no agent'
Ok 'activity: when two Wazuh agents share the host name (two clients), nothing is read rather than the wrong client'

function HostHit { param($C) @{ data = @{ win = @{ system = @{ eventID = '1'; computer = $C } } } } }
Assert-Same (Select-RsSameHost -Hits @((HostHit 'PC-01.corp-a.example'), (HostHit 'pc-01.CORP-A.example')) -Dns 'PC-01.corp-a.example')['note'] '' 'same host'
Assert-Json (Select-RsSameHost -Hits @(HostHit 'PC-01.corp-b.example') -Dns 'PC-01.corp-a.example') '{"hits":[],"note":"the Wazuh agent PC-01 is another computer (PC-01.corp-b.example): activity not read"}' 'other host'
Assert-Json (Select-RsSameHost -Hits @((HostHit 'PC-01.corp-a.example'), @{ data = @{ win = @{ system = @{ eventID = '1' } } } }) -Dns 'PC-01.corp-a.example')['hits'] '[]' 'no computer name'
Assert-Json (Select-RsSameHost -Hits @(HostHit 'PC-01') -Dns $null)['hits'] '[]' 'no dns'
Ok "activity: the Wazuh agent's Windows computer name must be the NinjaOne device's DNS name, or another client's PC-01 is not read"
Ok 'activity: an event with no computer name, or a device with no DNS name, is not read (fail closed)'

# A server sign-in mid-session: Windows starts the admin's tray and Run-key apps (security icon, backup tray, EDR UI) by itself.
$logon = Get-RsActivity -Alerts (Load 'remote-sessions-wazuh-logon.json') -Spans @(, @(1795275341, 1795275969))
Assert-Json $logon '{"installed":[],"observed":[],"apps":["Command Prompt"],"commands":["whoami"],"elevations":0}' 'logon'
Ok 'activity: apps Windows starts at sign-in are not counted; the prompt the admin opened and the command typed are'

# A staff sign-in watched over a remote session: tray apps, updaters and audio services trickle in for minutes, and a
# user-context script (powershell -ExecutionPolicy ByPass) runs whoami. None of it is the technician's.
$signin = Get-RsActivity -Alerts (Load 'remote-sessions-wazuh-signin.json') -Spans @(, @(1794322162, 1794322559))
Assert-Json @($signin['installed'], $signin['apps'], $signin['commands'], $signin['elevations']) '[[],[],[],0]' 'signin'
Ok 'activity: startup apps after a slow sign-in and commands run by scripts are not counted'

$early = Get-RsActivity -Alerts (Load 'remote-sessions-wazuh-install.json') -Spans @(, @(1794882750, (1794882750 + 300)))
Assert-Json @($early['installed'], $early['apps']) '[[],["Command Prompt"]]' 'early'
Ok 'activity: only events inside the session window count (event time, not ingest time)'

$gap = Get-RsActivity -Alerts (Load 'remote-sessions-wazuh-install.json') -Spans @(@(1794882750, (1794882750 + 120)), @((1794885107 - 120), 1794885107))
Assert-Json $gap['installed'] '[]' 'gap installed'
if (@($gap['apps']) -contains 'AppMgrPx') { Fail 'gap apps has AppMgrPx' }
Ok 'activity: an install between two connections is not in either'

function Proc {
    param([string]$Exe, [string]$Parent, [string]$Desc = '', $Pcl = $null)
    $ed = @{ image = 'C:\Tools\' + $Exe; parentImage = 'C:\Windows\' + $Parent; user = 'CORP\user1'; description = $Desc }
    if ($null -ne $Pcl) { $ed['parentCommandLine'] = $Pcl }
    @{ data = @{ win = @{ system = @{ eventID = '1'; systemTime = '2026-11-19T18:30:00.0000000Z' }; eventdata = $ed } } }
}
function Mmc {
    param([string]$Msc)
    @{ data = @{ win = @{ system = @{ eventID = '1'; systemTime = '2026-11-19T18:30:00.0000000Z' }
                eventdata = @{ image = 'C:\Windows\System32\mmc.exe'; parentImage = 'C:\Windows\explorer.exe'; user = 'CORP\user1'
                    commandLine = '"C:\Windows\system32\mmc.exe" "C:\Tools\' + $Msc + '"' } } } }
}
$named = Get-RsActivity -Alerts @((Proc 'alice-pc01-support.exe' 'explorer.exe'), (Proc 'bob-tool.exe' 'cmd.exe' -Pcl 'cmd.exe'),
    (Proc 'ipconfig.exe' 'cmd.exe' -Pcl 'cmd.exe'), (Mmc 'Alice-PC.msc'), (Mmc 'dsa.msc')) -Spans @(, @(1795111385, 1795113834))
Assert-Json @($named['apps'], $named['commands']) '[["Active Directory Users and Computers"],["ipconfig"]]' 'named'
Ok 'activity: an app with no description and an unknown command are not named (a file name can carry a person or a host)'

Assert-Json (Get-RsActivity -Alerts @(Proc 'whoami.exe' 'powershell.exe') -Spans @(, @(1795111385, 1795113834)))['commands'] '[]' 'no shell command line'
Ok 'activity: a command whose shell command line is unknown is not claimed as typed'

$later = Proc 'setup.exe' 'explorer.exe' -Desc 'Setup'
$later['data']['win']['system']['systemTime'] = '2026-11-19T18:40:00.0000000Z'   # 10 minutes after the update finished
Assert-Json (Get-RsActivity -Alerts @((Msi '1033' 'Unattended Update, 1.2.3, 1033, 0, Vendor'), $later) -Spans @(, @(1795111385, 1795113834)))['installed'] '[]' 'setup later'
$setupFirst = Proc 'setup.exe' 'explorer.exe' -Desc 'Setup'
$setupFirst['data']['win']['system']['systemTime'] = '2026-11-19T18:20:00.0000000Z'
$updateAfter = Msi '1033' 'Unattended Update, 1.2.3, 1033, 0, Vendor'
$updateAfter['data']['win']['system']['systemTime'] = '2026-11-19T18:21:00.0000000Z'
Assert-Json (Get-RsActivity -Alerts @($setupFirst, $updateAfter) -Spans @(, @(1795111385, 1795113834)))['installed'] '[]' 'setup first'
Ok 'activity: an install is ours only when a person ran that package (msiexec /i <its .msi>), not because some installer ran near it'

$tgit = @{ data = @{ win = @{ system = @{ eventID = '1'; systemTime = '2026-11-19T18:20:00.0000000Z' }; eventdata = @{
                image = 'C:\Windows\System32\msiexec.exe'; parentImage = 'C:\Windows\explorer.exe'; user = 'CORP\user1'
                commandLine = '"C:\Windows\System32\msiexec.exe" /i "C:\Fixtures\Downloads\TortoiseGit-2.17.0.msi"' } } } }
$bothGit = Get-RsActivity -Alerts @($tgit, (Msi '1033' 'Git, 2.47.0, 1033, 0, Vendor'), (Msi '1033' 'TortoiseGit, 2.17.0, 1033, 0, Vendor')) -Spans @(, @(1795111385, 1795113834))
Assert-Json @($bothGit['installed'], $bothGit['observed']) '[["TortoiseGit 2.17.0"],["Git 2.47.0 installed"]]' 'tortoisegit'
Ok 'activity: the package file name must start with the product name word for word (TortoiseGit does not claim Git)'

# ---------------------------------------------------------------- task text (billing-entry style)
# Wall clock from tzdata's America/Vancouver: UTC-7 all year from 2026 (BC permanent daylight time), so 02:32 UTC on Nov 17 is 7:32 PM.
# A host with time zone data older than 2026 prints 6:32 and fails here, as it would mislabel real tasks.
$srv1 = $by['4714976556211F90SYUAUQ68SHGNRGV3']
$expected = "Server maintenance: installed SL2100 PC Pro 5.30.00 on the server by remote session, so staff have the software they need.`n" +
    "- Installed: SL2100 PC Pro 5.30.00`n" +
    "- Apps opened: Command Prompt, AppMgrPx`n" +
    "- Commands run: ping`n" +
    "- Administrator prompts: 1`n" +
    'Remote session Nov 16, 7:32-8:11 PM PT (39 min). Ref: NinjaOne 4714976556'
Assert-Same (Format-RsDescription -Sitting $srv1 -Activity $inst) $expected 'server text'
Ok 'text: topic sentence first, then what was done, then the session; no names, no host'

$expected = "Computers: worked with a staff member on their computer by remote session (Notepad, Microsoft Word), so they could keep working.`n" +
    "- Apps opened: Notepad, Microsoft Word, Notepad++, Microsoft Edge, Copilot`n" +
    "- Administrator prompts: 2`n" +
    'Remote session Nov 19, 11:03-11:43 AM PT (41 min). Ref: NinjaOne 5592750678'
Assert-Same (Format-RsDescription -Sitting $ws1 -Activity $ws) $expected 'workstation text'
$empty = [ordered]@{ installed = @(); observed = @(); apps = @(); commands = @(); elevations = 0 }
$text = Format-RsDescription -Sitting $ws1 -Activity $empty
if (-not "$text".StartsWith("Computers: checked a staff computer by remote session, so problems are caught early.`nRemote session Nov 19")) { Fail "empty text was [$text]" }
Ok 'text: a workstation with and without recorded activity; never "Uncategorized" or "script run"'

# ---------------------------------------------------------------- duplicates
$tasks = @(@{ number = '0042'; description = "Computers: ...`nRemote session Nov 20, 6:28-6:41 AM PT (1 min). Ref: NinjaOne 4314106653, 8230077061" },
    @{ number = '0043'; description = "Server maintenance: ...`nRef: NinjaOne 43141066539" })
Assert-Json (Get-RsDrafted -Tasks $tasks) '{"4314106653":"0042","8230077061":"0042"}' 'drafted'
Ok 'duplicates: every handle of a multi-connection draft is found; a longer number is not a match'

$old = @{ number = '0099'; description = "X`n`nComputer: PC-01`nTool: NinjaOne Remote"; time_log = '[[1795111385, 1795111985, "", true]]' }
Assert-Same (Find-RsOldTask -Sitting $ws1 -Tasks @($old))['number'] '0099' 'old task'
Assert-Same (Find-RsOldTask -Sitting $ws1 -Tasks @($old) -Shared) $null 'old task shared'
Ok 'comparison: the old task is matched by computer and start, and not at all when two NinjaOne devices share the name'

Assert-Same (Get-RsLoggedHours '[[1795111385, 1795111985, "", true], [1795112000, 1795112720, "", true], [1795113000, 0, "", true]]') 0.37 'old task hours'
Ok 'comparison: the old task shows its logged hours (finished entries only), to two decimals'

$realZone = $script:RsZone
$script:RsZone = [TimeZoneInfo]::CreateCustomTimeZone('pre-2026', [timespan]::FromHours(-8), 'pre-2026', 'pre-2026')   # what a host with time zone data older than 2026 has for America/Vancouver
Assert-Same (Get-RsClock 1794882750).ToString('HH:mm') '19:32' 'clock from 2026 is UTC-7'
Assert-Same (Get-RsClock (1767225600 - 86400 * 300)).Offset ([timespan]::FromHours(-8)) 'clock before 2026 follows the zone'
$script:RsZone = $realZone
Ok 'time: BC is UTC-7 all year from 2026 whatever the host time zone data says; earlier dates follow the zone'

# ---------------------------------------------------------------- -Apply: Backlog tasks in Invoice Ninja (the HTTP boundary is mocked)
$row = [ordered]@{ org = 12; start = 1794882750; seconds = 2356; ids = @('4714976556211F90SYUAUQ68SHGNRGV3'); skip = $null; hours = 0.7
    draft = 'Server maintenance: text'; alreadyDrafted = $null }
$body = New-RsTaskBody -Row $row -ClientId 'cl12' -StatusId 'st9'
# 02:32 UTC on Nov 17 is Nov 16 in Vancouver; the log ends 0.7 h (2520 s) after the start.
Assert-Json $body '{"client_id":"cl12","description":"Server maintenance: text","status_id":"st9","time_log":"[[1794882750,1794885270,\"\",true]]","date":"2026-11-16"}' 'task body'
Ok 'apply: a Backlog task carries the client, the draft text, the billable hours as its time log and the local date; no rate'

$env:INVOICENINJA_API_URL = 'https://invoicing.test/'
$env:INVOICENINJA_API_KEY = 'test-key'
$script:calls = [System.Collections.Generic.List[object]]::new()
$script:statuses = @(@{ id = 'st1'; name = 'Ready to do'; is_deleted = $false }, @{ id = 'st9'; name = 'Backlog'; is_deleted = $false })
function Invoke-RsHttp {
    param([string]$Method, [string]$Uri, [hashtable]$Headers, [string]$Body, [string]$ContentType, [string]$PinSha256, [switch]$NoRetry)
    $script:calls.Add([ordered]@{ method = $Method; uri = $Uri; body = $Body; token = $Headers['X-API-TOKEN']; noRetry = [bool]$NoRetry })
    if ($Method -eq 'GET') { return @{ data = $script:statuses } }
    return @{ data = @{ id = 'new'; number = '0100' } }
}
$rows = @(
    $row,
    (With $row @{ ids = @('1111111111AAAA'); alreadyDrafted = '0042' }),
    (With $row @{ ids = @('2222222222BBBB'); skip = 'connection only (under a minute): not drafted'; hours = $null; draft = $null }),
    (With $row @{ ids = @('3333333333CCCC'); org = 13 })
)
$report = @(Invoke-RsApply -Rows $rows -ClientMap @{ '12' = 'cl12' })
Assert-Json @($script:calls | ForEach-Object { "$($_.method) $($_.uri)" }) '["GET https://invoicing.test/api/v1/task_statuses?per_page=500","POST https://invoicing.test/api/v1/tasks"]' 'apply calls'
Assert-Same $script:calls[1].body '{"client_id":"cl12","description":"Server maintenance: text","status_id":"st9","time_log":"[[1794882750,1794885270,\"\",true]]","date":"2026-11-16"}' 'apply post body'
Assert-Same $script:calls[1].token 'test-key' 'apply token header'
Assert-Same $script:calls[1].noRetry $true 'task creation is never retried'
Assert-Json $report '["created task 0100 for NinjaOne 4714976556","skipped NinjaOne 3333333333: organization 13 is not in the client map"]' 'apply report'
Ok 'apply: only drafted sittings not already drafted become tasks; an organization missing from the map is skipped and reported'

$script:calls.Clear()
$script:statuses = @(@{ id = 'st1'; name = 'Ready to do'; is_deleted = $false })
$threw = $false
$msg = ''
try { Invoke-RsApply -Rows $rows -ClientMap @{ '12' = 'cl12' } | Out-Null } catch { $threw = $true; $msg = $_.Exception.Message }
Assert-Same $threw $true 'no Backlog throws'
Assert-Same $msg 'Invoice Ninja has no task status named Backlog; nothing created' 'no Backlog message'
Assert-Same $script:calls.Count 1 'no Backlog: only the status read'
Ok 'apply: without a Backlog status nothing is created'

# ---------------------------------------------------------------- NinjaOne read (HTTP mocked): a JSON list of devices stays a list of devices
$env:NINJAONE_BASE_URL = 'https://ninja.test'
function Invoke-RsHttp {
    param([string]$Method, [string]$Uri, [hashtable]$Headers, [string]$Body, [string]$ContentType, [string]$PinSha256)
    if ($Uri -like '*/ws/oauth/token') { return @{ access_token = 't' } }
    if ($Uri -like '*/v2/activities*') { return @{ activities = @() } }
    return ConvertFrom-Json -InputObject '[{"id":1001,"systemName":"PC-01"},{"id":1002,"systemName":"SRV-01"}]' -AsHashtable -NoEnumerate
}
$read = Get-RsNinja -Since 0
Assert-Same @($read['devices']).Count 2 'device count'
Assert-Json @($read['devices'] | ForEach-Object { $_['systemName'] }) '["PC-01","SRV-01"]' 'devices read'
Ok 'ninja: the device list is read as devices, so every session finds its device'

$threw = $false
try { Get-RsWazuh -Url 'http://indexer.test:9200' -Device 'PC-01' -Start 0 -End 1 | Out-Null } catch { $threw = $true; $msg = $_.Exception.Message }
Assert-Same $threw $true 'plain http indexer refused'
Assert-Same $msg 'the Wazuh indexer URL must be https (its certificate is pinned); nothing sent' 'plain http message'
Ok 'wazuh: a plain http indexer address is refused before the credentials are sent'

Assert-Json (Get-RsActivity -Alerts @() -Spans @(, @(1795111385, 1795113834))) '{"installed":[],"observed":[],"apps":[],"commands":[],"elevations":0}' 'no alerts'
Ok 'activity: no Wazuh alerts is an empty activity, not an error'

# ---------------------------------------------------------------- retries (the single send is mocked): transient failures three times, nothing else
. $scriptPath   # the real Invoke-RsHttp again, over the mocked send below
$script:RsRetryDelaySeconds = 0
$script:sends = 0
function Send-RsRequest {
    param([string]$Method, [string]$Uri, [hashtable]$Headers, $Body, [string]$ContentType, [string]$PinSha256)
    $script:sends++
    $s = $script:replies[[math]::Min($script:sends, $script:replies.Count) - 1]
    if ($s -eq 'drop') { throw [System.Net.Http.HttpRequestException]::new('connection refused', [System.Net.Sockets.SocketException]::new(111)) }
    if ($s -eq 'badcert') { throw [System.Net.Http.HttpRequestException]::new('SSL failed', [System.Security.Authentication.AuthenticationException]::new('remote certificate is invalid')) }
    return @{ status = $s; text = '{"ok":true}' }
}
$script:replies = @(503, 'drop', 200)
Assert-Same (Invoke-RsHttp -Method GET -Uri 'https://x.test/a')['ok'] $true 'third attempt succeeds'
Assert-Same $script:sends 3 'three attempts'
$script:sends = 0; $script:replies = @(503)
try { Invoke-RsHttp -Method GET -Uri 'https://x.test/a' | Out-Null } catch { $msg = $_.Exception.Message }
Assert-Same $script:sends 3 'gives up after three'
Assert-Same $msg 'GET /a: HTTP 503' 'last status reported'
$script:sends = 0; $script:replies = @(404)
try { Invoke-RsHttp -Method GET -Uri 'https://x.test/a' | Out-Null } catch { }
Assert-Same $script:sends 1 '404 is one attempt'
$script:sends = 0; $script:replies = @(503)
try { Invoke-RsHttp -Method POST -Uri 'https://x.test/tasks' -Body '{}' -NoRetry | Out-Null } catch { }
Assert-Same $script:sends 1 'a task creation is one attempt (a retry after a lost reply could create it twice)'
$script:sends = 0; $script:replies = @('badcert')
try { Invoke-RsHttp -Method GET -Uri 'https://x.test/a' | Out-Null } catch { }
Assert-Same $script:sends 1 'a TLS failure is one attempt'
Ok 'http: timeouts, connection failures and 408/429/5xx are tried three times; other failures, other statuses and task creation once'

# ---------------------------------------------------------------- the Wazuh indexer certificate is pinned (a certificate made here; no network)
$rsa = [System.Security.Cryptography.RSA]::Create(2048)
$certRequest = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=indexer.test', $rsa, 'SHA256', [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
$cert = $certRequest.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-1), [DateTimeOffset]::UtcNow.AddDays(1))
$pinned = ($cert.GetCertHashString('SHA256').ToLowerInvariant() -replace '(..)(?!$)', '$1:')   # as an operator pastes it: lower case, colons
$pin = New-RsPin $pinned
Assert-Same $pin.Check($null, $cert, $null, 'None') $true 'pinned certificate accepted'
Assert-Same $pin.Mismatch $false 'pinned certificate no mismatch'
$other = New-RsPin ('00' * 32)
Assert-Same $other.Check($null, $cert, $null, 'None') $false 'other certificate refused'
Assert-Same $other.Mismatch $true 'other certificate mismatch recorded'
$threw = $false
try { New-RsPin 'not-a-hash' | Out-Null } catch { $threw = $true }
Assert-Same $threw $true 'a pin that is not a SHA-256 is refused'
Ok 'pin: only the certificate with the pinned SHA-256 is accepted; an empty or malformed pin is refused'

Write-Output "remote-sessions: $($script:n) checks ok"
