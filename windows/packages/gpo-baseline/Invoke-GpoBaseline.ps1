<#
.SYNOPSIS
    Applies a named, embedded Group Policy definition to a Relian-owned GPO.
.DESCRIPTION
    Runs through the Relian deploy runner (NinjaOne script 374) as SYSTEM on the
    PDC emulator, Windows PowerShell 5.1, with the GroupPolicy and ActiveDirectory
    modules. The runner passes DeploymentType, Action and PinVersion, then each
    PackageArguments pair as -Name value:

      Definition          id of an embedded definition (required)
      Apply               "true" makes changes. Anything else is plan-only.
      LinkTo              OU distinguished name inside this domain to link the GPO to
      LinkEnabled         "true" enables the link. Default: the link is created disabled.
      AllowDefaultPolicy  "true" allows a definition that targets the Default Domain
                          Policy or Default Domain Controllers Policy, and only when the
                          definition itself sets allowDefaultPolicy.

    Install, Update, Repair and Reinstall compare the GPO with the definition and print
    the differences. With Apply=true they create the GPO (description carries the
    marker [relian-gpo-baseline:<id>]) or, for an existing GPO, run Backup-GPO to
    %ProgramData%\Relian\gpo-backups\{GPO GUID} first, then write only the differing
    values. A GPO with the same name but without the marker is never touched.

    Uninstall with Apply=true backs up and removes the GPO this package created, or,
    for an allowed default policy, restores the backup taken before the last change.

    Mechanism (Microsoft documentation):
    - Registry policy: Set-GPRegistryValue, which writes Registry.pol and updates the
      GPO version and extension list itself.
      https://learn.microsoft.com/en-us/powershell/module/grouppolicy/set-gpregistryvalue
    - Security template (GptTmpl.inf, UTF-16LE with BOM) and advanced audit (audit.csv):
      the GroupPolicy module has no cmdlet. Files are written in the GPO's SYSVOL folder
      as [MS-GPSB] and [MS-GPAC] define them, the computer half (low 16 bits) of
      versionNumber is raised in both GPT.INI and AD, and the CSE/tool GUID pair is added
      to gPCMachineExtensionNames, sorted by CSE GUID, as [MS-GPOL] requires. Without the
      pair, clients skip the settings.
      https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-gpol/
      https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-gpsb/55bb803e-b35f-4ce8-b558-4c1e92ad77a4
      https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-gpac/ac9c8234-d2e8-455d-be76-f84244dd1e58
      Import-GPO from a generated backup was rejected: it replaces every setting in the
      target and depends on the undocumented backup XML layout.
    - GPP scheduled task (definition "tasks"): a script is downloaded once from its pinned
      URL (TLS 1.2), its SHA256 checked before any write, and stored in the GPO's SYSVOL
      folder (Machine\Scripts\Relian). Machine\Preferences\ScheduledTasks\ScheduledTasks.xml
      gets a TaskV2 item ([MS-GPPREF] 2.2.1.18.3) that runs as SYSTEM at boot and on an
      interval, checks the SYSVOL copy against the same hash, then runs it. The GPP item is
      removed from clients when the GPO stops applying.
      https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-gppref/d7172c0f-4540-4bec-83d2-1ea14491c23c
    - WMI filter (definition "wmiFilter"): an msWMI-Som object under CN=SOM,CN=WMIPolicy,
      CN=System, marked in its description, linked through the GPO's gPCWQLFilter. The
      GroupPolicy module can assign but not create WMI filters.
    Writes go to the PDC emulator (the GPMC default), and only when this device is it.

    Output is one line of compact JSON (<= 8,000 UTF-8 bytes). Exit 0 for a plan, no
    change or a complete apply; exit 1 for a refusal, a failure, or a partial apply, with
    the values left in "left".
#>
[CmdletBinding()]
param(
    [string]$DeploymentType,
    [string]$Action,
    [string]$PinVersion,
    [string]$Definition = '',
    [string]$Apply = '',
    [string]$LinkTo = '',
    [string]$LinkEnabled = '',
    [string]$AllowDefaultPolicy = ''
)
$ProgressPreference = 'SilentlyContinue'

$GpbDefaultPolicies = @{
    '31b2f340-016d-11d2-945f-00c04fb984f9' = 'Default Domain Policy'
    '6ac1786c-016f-11d2-945f-00c04fb984f9' = 'Default Domain Controllers Policy'
}
$GpbSecurityCse = '[{827D319E-6EAC-11D2-A4EA-00C04F79F83A}{803E14A0-B4FB-11D0-A0D0-00A0C90F574B}]'
$GpbAuditCse = '[{F3CCC681-B74C-4060-9F26-CD84525DCA2A}{0F3F3735-573D-9804-99E4-AB2A69BA5FD4}]'
$GpbTaskCses = @('[{00000000-0000-0000-0000-000000000000}{CAB54552-DEEA-4691-817E-ED4A4D1AFC72}]', '[{AADCED64-746C-4633-A97C-D61349046527}{CAB54552-DEEA-4691-817E-ED4A4D1AFC72}]')
$GpbAuditHeader = 'Machine Name,Policy Target,Subcategory,Subcategory GUID,Inclusion Setting,Exclusion Setting,Setting Value'

# Embedded definitions: the package hash pins them. Values come from the CIS Microsoft
# Windows Server 2022 Benchmark v5.1.0 Audit sections (cis = recommendation id).
# 17.8.1 is Success only: v5.1.0 states "The recommended state for this setting is: Success."
# (earlier CIS versions asked for Success and Failure).
$GpbDefinitionJson = @'
[
 {
  "id": "cis-ws2022-dc-low-risk",
  "gpoName": "Relian CIS - Domain Controllers (low risk)",
  "description": "CIS WS2022 v5.1.0 low-risk group for domain controllers: logging, audit-only NTLM, LDAP and SMBv1 evidence, Print Spooler off. Link to the Domain Controllers OU.",
  "allowDefaultPolicy": false,
  "registry": [
   {"cis": "18.7.1", "key": "HKLM\\Software\\Policies\\Microsoft\\Windows NT\\Printers", "valueName": "RegisterSpoolerRemoteRpcEndPoint", "type": "DWord", "value": 2},
   {"cis": "9.1.4", "key": "HKLM\\Software\\Policies\\Microsoft\\WindowsFirewall\\DomainProfile\\Logging", "valueName": "LogFilePath", "type": "String", "value": "%SystemRoot%\\System32\\logfiles\\firewall\\domainfw.log"},
   {"cis": "9.1.5", "key": "HKLM\\Software\\Policies\\Microsoft\\WindowsFirewall\\DomainProfile\\Logging", "valueName": "LogFileSize", "type": "DWord", "value": 16384},
   {"cis": "9.1.6", "key": "HKLM\\Software\\Policies\\Microsoft\\WindowsFirewall\\DomainProfile\\Logging", "valueName": "LogDroppedPackets", "type": "DWord", "value": 1},
   {"cis": "9.1.7", "key": "HKLM\\Software\\Policies\\Microsoft\\WindowsFirewall\\DomainProfile\\Logging", "valueName": "LogSuccessfulConnections", "type": "DWord", "value": 1},
   {"cis": "9.2.4", "key": "HKLM\\Software\\Policies\\Microsoft\\WindowsFirewall\\PrivateProfile\\Logging", "valueName": "LogFilePath", "type": "String", "value": "%SystemRoot%\\System32\\logfiles\\firewall\\privatefw.log"},
   {"cis": "9.2.5", "key": "HKLM\\Software\\Policies\\Microsoft\\WindowsFirewall\\PrivateProfile\\Logging", "valueName": "LogFileSize", "type": "DWord", "value": 16384},
   {"cis": "9.2.6", "key": "HKLM\\Software\\Policies\\Microsoft\\WindowsFirewall\\PrivateProfile\\Logging", "valueName": "LogDroppedPackets", "type": "DWord", "value": 1},
   {"cis": "9.2.7", "key": "HKLM\\Software\\Policies\\Microsoft\\WindowsFirewall\\PrivateProfile\\Logging", "valueName": "LogSuccessfulConnections", "type": "DWord", "value": 1},
   {"cis": "9.3.6", "key": "HKLM\\Software\\Policies\\Microsoft\\WindowsFirewall\\PublicProfile\\Logging", "valueName": "LogFilePath", "type": "String", "value": "%SystemRoot%\\System32\\logfiles\\firewall\\publicfw.log"},
   {"cis": "9.3.7", "key": "HKLM\\Software\\Policies\\Microsoft\\WindowsFirewall\\PublicProfile\\Logging", "valueName": "LogFileSize", "type": "DWord", "value": 16384},
   {"cis": "9.3.8", "key": "HKLM\\Software\\Policies\\Microsoft\\WindowsFirewall\\PublicProfile\\Logging", "valueName": "LogDroppedPackets", "type": "DWord", "value": 1},
   {"cis": "9.3.9", "key": "HKLM\\Software\\Policies\\Microsoft\\WindowsFirewall\\PublicProfile\\Logging", "valueName": "LogSuccessfulConnections", "type": "DWord", "value": 1},
   {"cis": "18.10.26.1.1", "key": "HKLM\\Software\\Policies\\Microsoft\\Windows\\EventLog\\Application", "valueName": "Retention", "type": "String", "value": "0"},
   {"cis": "18.10.26.1.2", "key": "HKLM\\Software\\Policies\\Microsoft\\Windows\\EventLog\\Application", "valueName": "MaxSize", "type": "DWord", "value": 32768},
   {"cis": "18.10.26.2.1", "key": "HKLM\\Software\\Policies\\Microsoft\\Windows\\EventLog\\Security", "valueName": "Retention", "type": "String", "value": "0"},
   {"cis": "18.10.26.2.2", "key": "HKLM\\Software\\Policies\\Microsoft\\Windows\\EventLog\\Security", "valueName": "MaxSize", "type": "DWord", "value": 196608},
   {"cis": "18.10.26.3.1", "key": "HKLM\\Software\\Policies\\Microsoft\\Windows\\EventLog\\Setup", "valueName": "Retention", "type": "String", "value": "0"},
   {"cis": "18.10.26.3.2", "key": "HKLM\\Software\\Policies\\Microsoft\\Windows\\EventLog\\Setup", "valueName": "MaxSize", "type": "DWord", "value": 32768},
   {"cis": "18.10.26.4.1", "key": "HKLM\\Software\\Policies\\Microsoft\\Windows\\EventLog\\System", "valueName": "Retention", "type": "String", "value": "0"},
   {"cis": "18.10.26.4.2", "key": "HKLM\\Software\\Policies\\Microsoft\\Windows\\EventLog\\System", "valueName": "MaxSize", "type": "DWord", "value": 32768},
   {"cis": "18.10.88.1", "key": "HKLM\\Software\\Policies\\Microsoft\\Windows\\PowerShell\\ScriptBlockLogging", "valueName": "EnableScriptBlockLogging", "type": "DWord", "value": 1},
   {"cis": "none: LDAP event 2889", "key": "HKLM\\System\\CurrentControlSet\\Services\\NTDS\\Diagnostics", "valueName": "16 LDAP Interface Events", "type": "DWord", "value": 2},
   {"cis": "none: SMBv1 event 3000", "key": "HKLM\\System\\CurrentControlSet\\Services\\LanmanServer\\Parameters", "valueName": "AuditSmb1Access", "type": "DWord", "value": 1}
  ],
  "security": [
   {"cis": "2.3.2.1", "section": "Registry Values", "key": "MACHINE\\System\\CurrentControlSet\\Control\\Lsa\\SCENoApplyLegacyAuditPolicy", "value": "4,1"},
   {"cis": "2.3.11.11", "section": "Registry Values", "key": "MACHINE\\System\\CurrentControlSet\\Control\\Lsa\\MSV1_0\\AuditReceivingNTLMTraffic", "value": "4,2"},
   {"cis": "2.3.11.12", "section": "Registry Values", "key": "MACHINE\\System\\CurrentControlSet\\Services\\Netlogon\\Parameters\\AuditNTLMInDomain", "value": "4,7"},
   {"cis": "2.3.11.13", "section": "Registry Values", "key": "MACHINE\\System\\CurrentControlSet\\Control\\Lsa\\MSV1_0\\RestrictSendingNTLMTraffic", "value": "4,1"},
   {"cis": "5.1", "section": "Service General Setting", "key": "Spooler", "value": "4,\"\""}
  ],
  "audit": [
   {"cis": "17.4.1", "subcategory": "Audit Directory Service Access", "guid": "{0cce923b-69ae-11d9-bed3-505054503030}", "setting": 3},
   {"cis": "17.4.2", "subcategory": "Audit Directory Service Changes", "guid": "{0cce923c-69ae-11d9-bed3-505054503030}", "setting": 3},
   {"cis": "17.8.1", "subcategory": "Audit Sensitive Privilege Use", "guid": "{0cce9228-69ae-11d9-bed3-505054503030}", "setting": 1}
  ]
 },
 {
  "id": "comet-vss-provider-qemu",
  "gpoName": "Relian - Comet VSS provider (QEMU guests)",
  "description": "Keeps COMET_FORCE_VSS_PROVIDER=system in Comet Backup's AppEnvironmentExtra on QEMU/Proxmox Windows servers, keeping every other line. Runs the comet-vss-provider package at boot and hourly; it restarts Comet only after a change and only when no backup job runs.",
  "allowDefaultPolicy": false,
  "registry": [],
  "security": [],
  "audit": [],
  "wmiFilter": {
   "name": "Relian - QEMU Windows servers",
   "description": "Windows Server (not workstations) whose Win32_ComputerSystem manufacturer is QEMU (Proxmox/KVM guests).",
   "queries": [
    "SELECT * FROM Win32_ComputerSystem WHERE Manufacturer = \"QEMU\"",
    "SELECT * FROM Win32_OperatingSystem WHERE ProductType <> 1"
   ]
  },
  "tasks": [
   {
    "name": "Relian Comet VSS provider",
    "description": "Adds COMET_FORCE_VSS_PROVIDER=system to Comet's service environment if missing (merge, never replace). Managed by the Relian gpo-baseline package.",
    "file": {
     "name": "Invoke-CometVssProvider.ps1",
     "url": "https://raw.githubusercontent.com/Relianco/device-scripts/27368651c3fc3aa561dd14f62d44d3aee35c5afc/windows/packages/comet-vss-provider/Invoke-CometVssProvider.ps1",
     "sha256": "79dfa7393aae0893317651c4ac992261f0a4b861e21ad7d5f8506b114d570704"
    },
    "arguments": "-Action Install",
    "intervalMinutes": 60,
    "bootDelayMinutes": 5
   }
  ]
 }
]
'@

function Get-GpbDefinition {
    param([string]$Id)
    # No @(): Windows PowerShell 5.1 emits a JSON array as one object, and foreach enumerates it.
    $all = $GpbDefinitionJson | ConvertFrom-Json
    foreach ($d in $all) { if ($d.id -eq $Id) { return $d } }
    return $null
}

# No output (not $null) for a missing property, so @(Get-GpbProp ...) is empty.
function Get-GpbProp { param($Object, [string]$Name) if ($null -ne $Object -and $Object.PSObject.Properties[$Name]) { return $Object.$Name } }

# Returns the first problem with a definition, or $null. Embedded and test definitions both pass here.
function Test-GpbDefinition {
    param($Def)
    if ([string](Get-GpbProp $Def 'id') -notmatch '^[a-z0-9][a-z0-9-]{0,63}$') { return 'Definition id is invalid.' }
    if ([string](Get-GpbProp $Def 'gpoName') -notmatch '^[A-Za-z0-9 ._()-]{1,128}$') { return 'gpoName is invalid.' }
    foreach ($i in @(Get-GpbProp $Def 'registry')) {
        if ([string]$i.key -notmatch '^HKLM\\[^\x00-\x1F]+$') { return "Registry key must be under HKLM: $($i.key)" }
        if (@('DWord', 'String', 'ExpandString', 'QWord') -notcontains [string]$i.type) { return "Registry type not supported: $($i.type)" }
    }
    foreach ($i in @(Get-GpbProp $Def 'security')) {
        if (@('System Access', 'Kerberos Policy', 'Event Audit', 'Registry Values', 'Privilege Rights', 'Service General Setting') -notcontains [string]$i.section) { return "Security section not supported: $($i.section)" }
    }
    foreach ($i in @(Get-GpbProp $Def 'audit')) {
        if ([string]$i.guid -notmatch '^\{[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\}$' -or @(0, 1, 2, 3) -notcontains [int]$i.setting -or [string]$i.subcategory -notmatch '^[A-Za-z /-]+$') { return "Audit entry invalid: $($i.subcategory)" }
    }
    $w = Get-GpbProp $Def 'wmiFilter'
    if ($w) {
        # Name goes into an LDAP filter: no metacharacters.
        if ([string]$w.name -notmatch '^[A-Za-z0-9 ._-]{1,64}$') { return 'WMI filter name is invalid.' }
        foreach ($q in @($w.queries)) { if ([string]$q -notmatch '^SELECT [^;\x00-\x1F]+$') { return 'WMI queries must be single SELECT statements.' } }
        if (@($w.queries).Count -lt 1) { return 'WMI filter has no query.' }
    }
    foreach ($t in @(Get-GpbProp $Def 'tasks')) {
        if ([string]$t.name -notmatch '^[A-Za-z0-9 ._-]{1,64}$') { return 'Task name is invalid.' }
        $f = Get-GpbProp $t 'file'
        if ([string](Get-GpbProp $f 'name') -notmatch '^[A-Za-z0-9._-]+\.ps1$') { return 'Task file name is invalid.' }
        $url = [string](Get-GpbProp $f 'url')
        if ($url -notmatch '^https://[^/@\s]+/[^\s"]+$') { return 'Task file URL must be https without user info.' }
        if ([string](Get-GpbProp $f 'sha256') -notmatch '^[0-9a-f]{64}$') { return 'Task file sha256 must be 64 lowercase hex characters.' }
        # Arguments are placed in a -Command line: words, dashes and = only.
        if ([string](Get-GpbProp $t 'arguments') -notmatch '^[A-Za-z0-9 =_.-]*$') { return 'Task arguments may hold letters, digits, spaces, = _ . - only.' }
        if ([int](Get-GpbProp $t 'intervalMinutes') -lt 15 -or [int](Get-GpbProp $t 'intervalMinutes') -gt 1440) { return 'Task intervalMinutes must be 15 to 1440.' }
        if ([int](Get-GpbProp $t 'bootDelayMinutes') -lt 0 -or [int](Get-GpbProp $t 'bootDelayMinutes') -gt 60) { return 'Task bootDelayMinutes must be 0 to 60.' }
    }
    return $null
}

function Get-GpbSha256 {
    param([string]$Path)
    if (-not [IO.File]::Exists($Path)) { return $null }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($Path))) -replace '-', '').ToLowerInvariant() } finally { $sha.Dispose() }
}

# Download seam. The runner's TLS setting does not reach this child process.
$script:GpbDownload = {
    param($Url, $Path)
    # Shared guard (tests/windows/tls12.Tests.ps1): add Tls12 only on legacy explicit defaults.
    $tlsNow = [int][Net.ServicePointManager]::SecurityProtocol; if ($tlsNow -ne 0 -and ($tlsNow -band 15360) -eq 0) { [Net.ServicePointManager]::SecurityProtocol = $tlsNow -bor 3072 }
    Invoke-WebRequest -Uri $Url -OutFile $Path -UseBasicParsing -ErrorAction Stop | Out-Null
}

$script:GpbRetryDelay = { param($Seconds) Start-Sleep -Seconds $Seconds }

# Transient: timeout, connection, TLS or DNS failure, or HTTP 408/429/5xx gateway codes.
function Test-GpbTransient {
    param($Exception)
    $e = $Exception
    for ($n = 0; $null -ne $e -and $n -lt 8; $n++) {
        $code = $null
        if ($e.PSObject.Properties['StatusCode'] -and $null -ne $e.StatusCode) { $code = [int]$e.StatusCode }
        elseif ($e.PSObject.Properties['Response'] -and $null -ne $e.Response -and $e.Response.PSObject.Properties['StatusCode']) { $code = [int]$e.Response.StatusCode }
        if ($null -ne $code) { return (@(408, 429, 500, 502, 503, 504) -contains $code) }
        if ($e -is [TimeoutException] -or $e -is [Net.Sockets.SocketException] -or $e -is [Threading.Tasks.TaskCanceledException]) { return $true }
        if ($e -is [Net.WebException] -and @('Timeout', 'NameResolutionFailure', 'ConnectFailure', 'SecureChannelFailure', 'ReceiveFailure', 'SendFailure', 'ConnectionClosed', 'KeepAliveFailure') -contains [string]$e.Status) { return $true }
        if ($e.PSObject.Properties['HttpRequestError'] -and @('NameResolutionError', 'ConnectionError', 'SecureConnectionError', 'ResponseEnded') -contains [string]$e.HttpRequestError) { return $true }
        $e = $e.InnerException
    }
    return $false
}

# Three attempts (waits 5 s, 20 s) for transient failures only. The hash is checked by the caller, once.
function Invoke-GpbDownloadFile {
    param([string]$Url, [string]$Path)
    $delays = @(5, 20)
    for ($attempt = 1; ; $attempt++) {
        try { & $script:GpbDownload $Url $Path; return }
        catch {
            if ($attempt -ge 3 -or -not (Test-GpbTransient $_.Exception)) { throw }
            if ([IO.File]::Exists($Path)) { [IO.File]::Delete($Path) }
            & $script:GpbRetryDelay $delays[$attempt - 1]
        }
    }
}

# msWMI-Parm2: "<count>;" then per query "3;10;<len>;WQL;root\CIMv2;<query>;" (the GPMC encoding).
function ConvertTo-GpbWmiParm2 {
    param([string[]]$Queries)
    $sb = [Text.StringBuilder]::new([string]$Queries.Count + ';')
    foreach ($q in $Queries) { [void]$sb.Append("3;10;$($q.Length);WQL;root\CIMv2;$q;") }
    return $sb.ToString()
}

function Get-GpbWmiFilter {
    param($Context, [string]$Name)
    $base = 'CN=SOM,CN=WMIPolicy,CN=System,' + $Context.DomainDN
    return @(Get-ADObject -SearchBase $base -LDAPFilter "(&(objectClass=msWMI-Som)(msWMI-Name=$Name))" -Properties 'msWMI-Name', 'msWMI-Parm1', 'msWMI-Parm2', 'msWMI-ID' -Server $Context.Server -ErrorAction Stop) | Select-Object -First 1
}

function Get-GpbGpoDn { param($Context, $Gpo) 'CN={' + $Gpo.Id.ToString().ToUpper() + '},CN=Policies,CN=System,' + $Context.DomainDN }
function Get-GpbScriptPath { param($Context, $Gpo, [string]$Name) Join-Path (Get-GpbGpoDir $Context $Gpo) "Machine\Scripts\Relian\$Name" }
function Get-GpbTasksPath { param($Context, $Gpo) Join-Path (Get-GpbGpoDir $Context $Gpo) 'Machine\Preferences\ScheduledTasks\ScheduledTasks.xml' }

# Stable uid per GPO and task name, so regenerating the XML is idempotent.
function Get-GpbStableGuid {
    param([string]$Text)
    $md5 = [Security.Cryptography.MD5]::Create()
    try { return ([guid]::new($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).ToString().ToUpper() } finally { $md5.Dispose() }
}

function ConvertTo-GpbTasksXml {
    param($Context, $Gpo, $Tasks)
    $e = { param($t) [Security.SecurityElement]::Escape([string]$t) }
    $sb = [Text.StringBuilder]::new('<?xml version="1.0" encoding="utf-8"?>' + "`r`n" + '<ScheduledTasks clsid="{CC63F200-7309-4ba0-B154-A71CD118DBCC}">' + "`r`n")
    foreach ($t in @($Tasks)) {
        $unc = "\\$($Context.DnsRoot)\SYSVOL\$($Context.DnsRoot)\Policies\{$($Gpo.Id.ToString().ToUpper())}\Machine\Scripts\Relian\$($t.file.name)"
        # The SYSVOL copy runs only while it matches the pin; a copy still replicating is skipped this round.
        $command = "`$p='$unc'; if ((Get-FileHash -LiteralPath `$p -Algorithm SHA256).Hash -ne '$($t.file.sha256)') { exit 2 }; & `$p $($t.arguments); exit `$LASTEXITCODE"
        $arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -Command `"$command`""
        $uid = Get-GpbStableGuid ($Gpo.Id.ToString() + '|' + $t.name)
        [void]$sb.Append("<TaskV2 clsid=`"{D8896631-B747-47a7-84A6-C155337F3BC8}`" name=`"$(& $e $t.name)`" image=`"1`" changed=`"2026-11-10 00:00:00`" uid=`"{$uid}`" userContext=`"0`" removePolicy=`"1`">")
        # NT AUTHORITY\System with S4U is what GPMC writes for a SYSTEM preference task; Task Scheduler
        # runs it as LocalSystem, which reaches SYSVOL as the computer account.
        [void]$sb.Append("<Properties action=`"R`" name=`"$(& $e $t.name)`" runAs=`"NT AUTHORITY\System`" logonType=`"S4U`"><Task version=`"1.3`">")
        [void]$sb.Append("<RegistrationInfo><Author>Relian gpo-baseline</Author><Description>$(& $e $t.description)</Description></RegistrationInfo>")
        [void]$sb.Append('<Principals><Principal id="Author"><UserId>NT AUTHORITY\System</UserId><LogonType>S4U</LogonType><RunLevel>HighestAvailable</RunLevel></Principal></Principals>')
        [void]$sb.Append('<Settings><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy><DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries><StopIfGoingOnBatteries>false</StopIfGoingOnBatteries><AllowHardTerminate>true</AllowHardTerminate><StartWhenAvailable>true</StartWhenAvailable><AllowStartOnDemand>true</AllowStartOnDemand><Enabled>true</Enabled><Hidden>false</Hidden><ExecutionTimeLimit>PT30M</ExecutionTimeLimit><Priority>7</Priority></Settings>')
        [void]$sb.Append("<Triggers><BootTrigger><Enabled>true</Enabled><Delay>PT$([int]$t.bootDelayMinutes)M</Delay></BootTrigger><TimeTrigger><StartBoundary>2026-01-01T00:00:00</StartBoundary><Enabled>true</Enabled><Repetition><Interval>PT$([int]$t.intervalMinutes)M</Interval><StopAtDurationEnd>false</StopAtDurationEnd></Repetition></TimeTrigger></Triggers>")
        [void]$sb.Append("<Actions Context=`"Author`"><Exec><Command>powershell.exe</Command><Arguments>$(& $e $arguments)</Arguments></Exec></Actions></Task></Properties></TaskV2>`r`n")
    }
    [void]$sb.Append("</ScheduledTasks>`r`n")
    return $sb.ToString()
}

function Protect-GpbText {
    param([string]$Text, [int]$Max = 300)
    if ($Text -match '(?i)password|cpassword|secret|token|credential|bearer') { return '[sensitive line omitted]' }
    $t = ($Text -replace '[\x00-\x1F]', ' ').Trim()
    if ($t.Length -gt $Max) { return $t.Substring(0, $Max) + '[clipped]' }
    return $t
}

function Find-GpbLargestArray {
    param($Value)
    $best = $null
    if ($Value -is [Collections.IDictionary]) {
        foreach ($k in @($Value.Keys)) {
            $item = $Value[$k]
            if ($item -is [array] -and $item.Count -gt 0 -and ($null -eq $best -or $item.Count -gt $best.Count)) { $best = @{ Container = $Value; Key = $k; Count = $item.Count } }
            $inner = Find-GpbLargestArray $item
            if ($inner -and ($null -eq $best -or $inner.Count -gt $best.Count)) { $best = $inner }
        }
    } elseif ($Value -is [array]) {
        foreach ($item in $Value) {
            $inner = Find-GpbLargestArray $item
            if ($inner -and ($null -eq $best -or $inner.Count -gt $best.Count)) { $best = $inner }
        }
    }
    return $best
}

# Drops entries from the longest list until the JSON fits, and says so with "truncated".
function ConvertTo-GpbBoundedJson {
    param($Report, [int]$MaxBytes = 8000)
    $json = $Report | ConvertTo-Json -Depth 8 -Compress
    while ([Text.Encoding]::UTF8.GetByteCount($json) -gt $MaxBytes) {
        $Report['truncated'] = $true
        $largest = Find-GpbLargestArray $Report
        if (-not $largest) { throw 'Report metadata exceeds the output budget.' }
        $keep = $largest.Count - [Math]::Max(1, [int][Math]::Ceiling($largest.Count / 8))
        $largest.Container[$largest.Key] = @($largest.Container[$largest.Key] | Select-Object -First $keep)
        $json = $Report | ConvertTo-Json -Depth 8 -Compress
    }
    return $json
}

# ---- GPT.INI / AD version and extension names ([MS-GPOL]) ----

# versionNumber: high 16 bits user, low 16 bits computer. Each half takes the larger of
# AD and GPT.INI so a store that is ahead is never moved back.
function Get-GpbNextVersion {
    param([long]$AdVersion, [long]$IniVersion)
    $mask = [long]4294967295
    $a = $AdVersion -band $mask
    $i = $IniVersion -band $mask
    $user = [Math]::Max(($a -shr 16), ($i -shr 16))
    $computer = [Math]::Max(($a -band 65535), ($i -band 65535)) + 1
    if ($computer -gt 65535) { throw 'GPO computer version would overflow 16 bits.' }
    return [long](($user -shl 16) -bor $computer)
}

# AD stores versionNumber as a signed 32-bit integer.
function ConvertTo-GpbAdVersion {
    param([long]$Version)
    if ($Version -gt 2147483647) { return [int]($Version - 4294967296) }
    return [int]$Version
}

function Add-GpbExtensionNames {
    param([AllowEmptyString()][string]$Current, [string[]]$Pairs)
    $map = @{}
    foreach ($text in @($Current) + @($Pairs)) {
        foreach ($m in [regex]::Matches([string]$text, '\[(\{[0-9A-Fa-f-]{36}\})((?:\{[0-9A-Fa-f-]{36}\})*)\]')) {
            $cse = $m.Groups[1].Value.ToUpperInvariant()
            if (-not $map.ContainsKey($cse)) { $map[$cse] = [Collections.Generic.List[string]]::new() }
            foreach ($t in [regex]::Matches($m.Groups[2].Value, '\{[0-9A-Fa-f-]{36}\}')) {
                $tool = $t.Value.ToUpperInvariant()
                if (-not $map[$cse].Contains($tool)) { $map[$cse].Add($tool) }
            }
        }
    }
    # Clients stop at the first CSE GUID out of order, so sort ordinally.
    $keys = [string[]]@($map.Keys)
    [Array]::Sort($keys, [StringComparer]::OrdinalIgnoreCase)
    $sb = [Text.StringBuilder]::new()
    foreach ($cse in $keys) {
        $tools = $map[$cse].ToArray()
        [Array]::Sort($tools, [StringComparer]::OrdinalIgnoreCase)
        [void]$sb.Append('[' + $cse + ($tools -join '') + ']')
    }
    return $sb.ToString()
}

# ---- GptTmpl.inf ([MS-GPSB]) ----

$GpbKeyedSections = @('Unicode', 'Version', 'System Access', 'Kerberos Policy', 'Event Audit', 'Registry Values', 'Privilege Rights', 'System Log', 'Security Log', 'Application Log')

# Sections -> keys -> right-hand side. Lines in other sections are kept verbatim.
function ConvertFrom-GpbInf {
    param([AllowEmptyString()][string]$Text)
    $sections = [ordered]@{}
    $current = $null
    foreach ($line in ($Text -split '\r?\n')) {
        $t = $line.Trim()
        if (-not $t -or $t.StartsWith(';')) { continue }
        if ($t -match '^\[(.+)\]$') {
            $current = $Matches[1]
            if (-not $sections.Contains($current)) { $sections[$current] = [ordered]@{} }
            continue
        }
        if ($null -eq $current) { continue }
        if ($current -eq 'Service General Setting' -and $t -match '^"?([^",]+)"?\s*,(.*)$') { $sections[$current][$Matches[1]] = $Matches[2].Trim() }
        elseif ($GpbKeyedSections -contains $current -and $t -match '^([^=]+?)\s*=\s*(.*)$') { $sections[$current][$Matches[1]] = $Matches[2] }
        else { $sections[$current][$t] = $null }
    }
    return $sections
}

function ConvertTo-GpbInf {
    param($Sections)
    if (-not $Sections.Contains('Unicode')) { $Sections['Unicode'] = [ordered]@{ Unicode = 'yes' } }
    if (-not $Sections.Contains('Version')) { $Sections['Version'] = [ordered]@{ signature = '"$CHICAGO$"'; Revision = '1' } }
    $sb = [Text.StringBuilder]::new()
    foreach ($name in @('Unicode', 'Version') + @($Sections.Keys | Where-Object { $_ -ne 'Unicode' -and $_ -ne 'Version' })) {
        [void]$sb.Append("[$name]`r`n")
        foreach ($k in @($Sections[$name].Keys)) {
            $v = $Sections[$name][$k]
            if ($null -eq $v) { [void]$sb.Append("$k`r`n") }
            elseif ($name -eq 'Service General Setting') { [void]$sb.Append("`"$k`",$v`r`n") }
            elseif ($name -eq 'Unicode' -or $name -eq 'Version') { [void]$sb.Append("$k=$v`r`n") }
            else { [void]$sb.Append("$k = $v`r`n") }
        }
    }
    return $sb.ToString()
}

# ---- audit.csv ([MS-GPAC]) ----

# shortcut: plain comma split; Microsoft subcategory names and settings contain no commas.
function ConvertFrom-GpbAuditCsv {
    param([AllowEmptyString()][string]$Text)
    $rows = [ordered]@{}
    foreach ($line in ($Text -split '\r?\n')) {
        if (-not $line.Trim() -or $line.StartsWith('Machine Name,')) { continue }
        $f = $line.Split(',')
        if ($f.Count -lt 7) { continue }
        $row = [pscustomobject]@{ Machine = $f[0]; Target = $f[1]; Subcategory = $f[2]; Guid = $f[3]; Inclusion = $f[4]; Exclusion = $f[5]; Value = $f[6] }
        $key = if ($f[3]) { $f[3].ToLowerInvariant() } else { $f[2] }
        $rows[$key] = $row
    }
    return $rows
}

function ConvertTo-GpbAuditCsv {
    param($Rows)
    $lines = @($GpbAuditHeader)
    foreach ($r in $Rows.Values) { $lines += (@($r.Machine, $r.Target, $r.Subcategory, $r.Guid, $r.Inclusion, $r.Exclusion, $r.Value) -join ',') }
    return (($lines -join "`r`n") + "`r`n")
}

function Get-GpbInclusion {
    param([int]$Setting)
    switch ($Setting) { 0 { 'No Auditing' } 1 { 'Success' } 2 { 'Failure' } 3 { 'Success and Failure' } default { throw "Invalid audit setting $Setting" } }
}

# ---- Domain access ----

function Get-GpbContext {
    Import-Module GroupPolicy -ErrorAction Stop
    Import-Module ActiveDirectory -ErrorAction Stop
    $domain = Get-ADDomain -ErrorAction Stop
    $pdc = [string]$domain.PDCEmulator
    return @{
        Server = $pdc
        DomainDN = [string]$domain.DistinguishedName
        PoliciesPath = "\\$pdc\SYSVOL\$($domain.DNSRoot)\Policies"
        BackupRoot = Join-Path $env:ProgramData 'Relian\gpo-backups'
        IsPdc = ($pdc.Split('.')[0] -ieq $env:COMPUTERNAME)
        DnsRoot = [string]$domain.DNSRoot
    }
}

function Get-GpbGpo {
    param($Context, [string]$Name)
    try { return Get-GPO -Name $Name -Server $Context.Server -ErrorAction Stop }
    catch [System.ArgumentException] { return $null } # Get-GPO reports "not found" this way.
}

function Get-GpbGpoDir { param($Context, $Gpo) Join-Path $Context.PoliciesPath ('{' + $Gpo.Id.ToString().ToUpper() + '}') }
function Get-GpbInfPath { param($Context, $Gpo) Join-Path (Get-GpbGpoDir $Context $Gpo) 'Machine\Microsoft\Windows NT\SecEdit\GptTmpl.inf' }
function Get-GpbAuditPath { param($Context, $Gpo) Join-Path (Get-GpbGpoDir $Context $Gpo) 'Machine\Microsoft\Windows NT\Audit\audit.csv' }
function Read-GpbText { param([string]$Path) if ([IO.File]::Exists($Path)) { return [IO.File]::ReadAllText($Path) } return '' }

function Get-GpbPlan {
    param($Context, $Def, $Gpo, [string]$LinkTo, [bool]$LinkOn)
    $changes = [Collections.Generic.List[object]]::new()
    if (-not $Gpo) { $changes.Add([ordered]@{ kind = 'create'; target = $Def.gpoName; current = $null; desired = 'new GPO' }) }
    foreach ($item in @($Def.registry)) {
        $cur = $null
        # shortcut: any read error counts as "not set"; the write that follows then reports the real failure.
        if ($Gpo) { try { $cur = Get-GPRegistryValue -Guid $Gpo.Id -Key $item.key -ValueName $item.valueName -Server $Context.Server -ErrorAction Stop } catch { $cur = $null } }
        if ($null -eq $cur -or [string]$cur.Value -ne [string]$item.value -or [string]$cur.Type -ne [string]$item.type) {
            $c = $null; if ($cur) { $c = [string]$cur.Value }
            $changes.Add([ordered]@{ kind = 'registry'; target = "$($item.key)\$($item.valueName)"; current = $c; desired = [string]$item.value; type = [string]$item.type; cis = $item.cis; item = $item })
        }
    }
    $inf = [ordered]@{}; $audit = [ordered]@{}
    if ($Gpo) {
        $inf = ConvertFrom-GpbInf (Read-GpbText (Get-GpbInfPath $Context $Gpo))
        $audit = ConvertFrom-GpbAuditCsv (Read-GpbText (Get-GpbAuditPath $Context $Gpo))
    }
    foreach ($item in @($Def.security)) {
        $cur = $null
        if ($inf.Contains($item.section) -and $inf[$item.section].Contains($item.key)) { $cur = $inf[$item.section][$item.key] }
        if ($cur -ne $item.value) { $changes.Add([ordered]@{ kind = 'security'; target = "[$($item.section)] $($item.key)"; current = $cur; desired = $item.value; cis = $item.cis; item = $item }) }
    }
    foreach ($item in @($Def.audit)) {
        $cur = $null
        if ($audit.Contains($item.guid)) { $cur = $audit[$item.guid].Value }
        if ($cur -ne [string]$item.setting) { $changes.Add([ordered]@{ kind = 'audit'; target = $item.subcategory; current = $cur; desired = [string]$item.setting; cis = $item.cis; item = $item }) }
    }
    $w = Get-GpbProp $Def 'wmiFilter'
    if ($w) {
        $marker = "[relian-gpo-baseline:$($Def.id)]"
        $want = ConvertTo-GpbWmiParm2 @($w.queries)
        $filter = Get-GpbWmiFilter -Context $Context -Name $w.name
        if (-not $filter) { $changes.Add([ordered]@{ kind = 'wmiFilter'; target = $w.name; current = $null; desired = ($w.queries -join ' AND ') }) }
        elseif ([string]$filter.'msWMI-Parm2' -cne $want) { $changes.Add([ordered]@{ kind = 'wmiFilter'; target = $w.name; current = 'different queries'; desired = ($w.queries -join ' AND '); filter = $filter }) }
        $linked = $null
        if ($Gpo) { $linked = [string](Get-ADObject -Identity (Get-GpbGpoDn $Context $Gpo) -Properties gPCWQLFilter -Server $Context.Server -ErrorAction Stop).gPCWQLFilter }
        if (-not $filter -or $linked -ne "[$($Context.DnsRoot);$($filter.'msWMI-ID');0]") { $changes.Add([ordered]@{ kind = 'wmiLink'; target = $w.name; current = $linked; desired = 'linked' }) }
    }
    $tasks = @(Get-GpbProp $Def 'tasks')
    foreach ($t in $tasks) {
        $cur = $null
        if ($Gpo) { $cur = Get-GpbSha256 (Get-GpbScriptPath $Context $Gpo $t.file.name) }
        if ($cur -ne $t.file.sha256) { $changes.Add([ordered]@{ kind = 'file'; target = $t.file.name; current = $cur; desired = $t.file.sha256; item = $t }) }
    }
    if ($tasks.Count) {
        $same = $false
        if ($Gpo) { $same = (Read-GpbText (Get-GpbTasksPath $Context $Gpo)) -ceq (ConvertTo-GpbTasksXml $Context $Gpo $tasks) }
        if (-not $same) { $changes.Add([ordered]@{ kind = 'tasks'; target = 'ScheduledTasks.xml'; current = $null; desired = (@($tasks | ForEach-Object { $_.name }) -join ', ') }) }
    }
    # Matching files are not enough: clients skip them unless the CSE pair is registered
    # and AD and GPT.INI carry the same version. A run that stopped between the two is repaired.
    $pairs = @()
    if (@($Def.security).Count) { $pairs += $GpbSecurityCse }
    if (@($Def.audit).Count) { $pairs += $GpbAuditCse }
    if ($tasks.Count) { $pairs += $GpbTaskCses }
    if ($Gpo -and $pairs.Count) {
        $pub = Get-GpbPublishState -Context $Context -Gpo $Gpo
        $missing = (Add-GpbExtensionNames -Current $pub.ext -Pairs $pairs) -ne (Add-GpbExtensionNames -Current $pub.ext -Pairs @())
        $pending = [IO.File]::Exists((Join-Path (Get-GpbStateDir $Context $Gpo) 'pending-publish'))
        if ($missing -or $pending -or $pub.adVersion -ne $pub.iniVersion) {
            $changes.Add([ordered]@{ kind = 'publish'; target = 'versionNumber, gPCMachineExtensionNames'; current = "ad=$($pub.adVersion) ini=$($pub.iniVersion) cseMissing=$missing pending=$pending"; desired = 'consistent' })
        }
    }
    if ($LinkTo) {
        $link = $null
        if ($Gpo) { $link = @((Get-GPInheritance -Target $LinkTo -Server $Context.Server -ErrorAction Stop).GpoLinks | Where-Object { $_.GpoId -eq $Gpo.Id }) | Select-Object -First 1 }
        if (-not $link) { $changes.Add([ordered]@{ kind = 'link'; target = $LinkTo; current = $null; desired = $(if ($LinkOn) { 'enabled' } else { 'disabled' }) }) }
        elseif ([bool]$link.Enabled -ne $LinkOn) { $changes.Add([ordered]@{ kind = 'link'; target = $LinkTo; current = $(if ($link.Enabled) { 'enabled' } else { 'disabled' }); desired = $(if ($LinkOn) { 'enabled' } else { 'disabled' }); exists = $true }) }
    }
    return , $changes
}

function Protect-GpbBackupRoot {
    param([string]$Path)
    # Backups can hold Group Policy Preference data: SYSTEM and Administrators only.
    & icacls.exe $Path /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' /C /Q | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls grant exited $LASTEXITCODE" }
    & icacls.exe $Path /inheritance:r /C /Q | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls inheritance exited $LASTEXITCODE" }
}

# Per-GPO folder for backups and state, under the SYSTEM/Administrators-only root.
function Initialize-GpbStateDir {
    param($Context, $Gpo)
    [void](New-Item -ItemType Directory -Path $Context.BackupRoot -Force)
    Protect-GpbBackupRoot $Context.BackupRoot
    $dir = Get-GpbStateDir $Context $Gpo
    [void](New-Item -ItemType Directory -Path $dir -Force)
    return $dir
}

function Get-GpbStateDir { param($Context, $Gpo) Join-Path $Context.BackupRoot ('{' + $Gpo.Id.ToString().ToUpper() + '}') }

function Save-GpbBackup {
    param($Context, $Gpo, [string]$DefinitionId, [switch]$Record)
    $dir = Initialize-GpbStateDir $Context $Gpo
    $backup = Backup-GPO -Guid $Gpo.Id -Path $dir -Comment "relian-gpo-baseline $DefinitionId" -Server $Context.Server -ErrorAction Stop
    $id = ''
    if ($backup -and $backup.PSObject.Properties['Id']) { $id = [string]$backup.Id }
    if (-not $id) { throw 'Backup-GPO returned no backup id. Nothing was changed.' }
    if ($Record) {
        $state = [ordered]@{ backupId = $id; gpoId = [string]$Gpo.Id; definition = $DefinitionId; utc = [datetime]::UtcNow.ToString('o') } | ConvertTo-Json -Compress
        [IO.File]::WriteAllText((Join-Path $dir 'last-backup.json'), $state)
    }
    return $id
}

# AD versionNumber and gPCMachineExtensionNames, and the GPT.INI text and version.
function Get-GpbPublishState {
    param($Context, $Gpo)
    $dn = 'CN={' + $Gpo.Id.ToString().ToUpper() + '},CN=Policies,CN=System,' + $Context.DomainDN
    $obj = Get-ADObject -Identity $dn -Properties versionNumber, gPCMachineExtensionNames -Server $Context.Server -ErrorAction Stop
    $ext = ''
    if ($obj.PSObject.Properties['gPCMachineExtensionNames'] -and $obj.gPCMachineExtensionNames) { $ext = [string]$obj.gPCMachineExtensionNames }
    $adVersion = [long]0
    if ($obj.PSObject.Properties['versionNumber'] -and $null -ne $obj.versionNumber) { $adVersion = ([long]$obj.versionNumber) -band [long]4294967295 }
    $iniPath = Join-Path (Get-GpbGpoDir $Context $Gpo) 'GPT.INI'
    $ini = ''
    if ([IO.File]::Exists($iniPath)) { $ini = [Text.Encoding]::Default.GetString([IO.File]::ReadAllBytes($iniPath)) }
    # Spaces and tabs only: \s would reach into the next line.
    $m = [regex]::Match($ini, '(?im)^[ \t]*Version[ \t]*=[ \t]*(\d+)[ \t]*\r?$')
    $iniVersion = [long]0
    if ($m.Success) { $iniVersion = [long]$m.Groups[1].Value }
    return @{ dn = $dn; ext = $ext; adVersion = $adVersion; iniPath = $iniPath; ini = $ini; match = $m; iniVersion = $iniVersion }
}

function Update-GpbVersion {
    param($Context, $Gpo, [string[]]$Pairs)
    $st = Get-GpbPublishState -Context $Context -Gpo $Gpo
    $dn = $st.dn; $ext = $st.ext; $iniPath = $st.iniPath; $ini = $st.ini; $m = $st.match
    $next = Get-GpbNextVersion -AdVersion $st.adVersion -IniVersion $st.iniVersion
    if ($m.Success) { $g = $m.Groups[1]; $ini = $ini.Substring(0, $g.Index) + [string]$next + $ini.Substring($g.Index + $g.Length) }
    elseif ($ini -match '(?im)^\[General\]\s*$') { $ini = [regex]::Replace($ini, '(?im)^\[General\]\s*$', "[General]`r`nVersion=$next", 1) }
    else { $ini = "[General]`r`nVersion=$next`r`n" + $ini }
    # SYSVOL first, then AD: a client that sees the new AD version must find the new files.
    [IO.File]::WriteAllBytes($iniPath, [Text.Encoding]::Default.GetBytes($ini))
    Set-ADObject -Identity $dn -Replace @{ versionNumber = (ConvertTo-GpbAdVersion $next); gPCMachineExtensionNames = (Add-GpbExtensionNames -Current $ext -Pairs $Pairs) } -Server $Context.Server -ErrorAction Stop
}

function Invoke-GpbApply {
    param($Context, $Def, $Gpo, $Changes, [string]$LinkTo, [bool]$LinkOn, $Report)
    # Downloads first: a pin mismatch stops the run before any GPO or AD write.
    $downloaded = @{}
    try {
        foreach ($c in @($Changes | Where-Object { $_.kind -eq 'file' })) {
            $tmp = Join-Path ([IO.Path]::GetTempPath()) ('relian-gpb-' + [guid]::NewGuid().ToString('n'))
            Invoke-GpbDownloadFile -Url $c.item.file.url -Path $tmp
            $got = Get-GpbSha256 $tmp
            if ($got -ne $c.item.file.sha256) { throw "Downloaded $($c.item.file.name) has SHA256 $got, not the pinned $($c.item.file.sha256). Nothing was changed." }
            $downloaded[$c.item.file.name] = $tmp
        }
        return (Invoke-GpbApplyWrites -Context $Context -Def $Def -Gpo $Gpo -Changes $Changes -LinkTo $LinkTo -LinkOn $LinkOn -Report $Report -Downloaded $downloaded)
    } finally {
        foreach ($f in $downloaded.Values) { if ([IO.File]::Exists($f)) { [IO.File]::Delete($f) } }
    }
}

function Invoke-GpbApplyWrites {
    param($Context, $Def, $Gpo, $Changes, [string]$LinkTo, [bool]$LinkOn, $Report, $Downloaded)
    if (-not $Gpo) {
        $Gpo = New-GPO -Name $Def.gpoName -Comment ("[relian-gpo-baseline:$($Def.id)] Managed by the Relian gpo-baseline package. " + $Def.description) -Server $Context.Server -ErrorAction Stop
        $Report.gpo.id = [string]$Gpo.Id; $Report.gpo.exists = $true; $Report.gpo.owned = $true
    } else {
        $Report.backupId = Save-GpbBackup -Context $Context -Gpo $Gpo -DefinitionId $Def.id -Record
    }
    $filter = $null
    $w = Get-GpbProp $Def 'wmiFilter'
    if ($w) {
        $stamp = [datetime]::UtcNow.ToString('yyyyMMddHHmmss.ffffff') + '-000'
        $parm1 = "[relian-gpo-baseline:$($Def.id)] " + $w.description
        $parm2 = ConvertTo-GpbWmiParm2 @($w.queries)
        $wc = @($Changes | Where-Object { $_.kind -eq 'wmiFilter' }) | Select-Object -First 1
        if ($wc -and $wc.Contains('filter')) {
            Set-ADObject -Identity $wc.filter.DistinguishedName -Replace @{ 'msWMI-Parm2' = $parm2; 'msWMI-ChangeDate' = $stamp } -Server $Context.Server -ErrorAction Stop
        } elseif ($wc) {
            $wid = '{' + [guid]::NewGuid().ToString().ToUpper() + '}'
            New-ADObject -Name $wid -Type 'msWMI-Som' -Path ('CN=SOM,CN=WMIPolicy,CN=System,' + $Context.DomainDN) -OtherAttributes @{ 'msWMI-Name' = $w.name; 'msWMI-Parm1' = $parm1; 'msWMI-Parm2' = $parm2; 'msWMI-Author' = 'relian-gpo-baseline'; 'msWMI-ID' = $wid; 'msWMI-CreationDate' = $stamp; 'msWMI-ChangeDate' = $stamp } -Server $Context.Server -ErrorAction Stop
        }
        $filter = Get-GpbWmiFilter -Context $Context -Name $w.name
        if (-not $filter) { throw 'WMI filter not found after creation.' }
    }
    foreach ($c in @($Changes | Where-Object { $_.kind -eq 'registry' })) {
        Set-GPRegistryValue -Guid $Gpo.Id -Key $c.item.key -ValueName $c.item.valueName -Type $c.item.type -Value $c.item.value -Server $Context.Server -ErrorAction Stop | Out-Null
    }
    $pairs = @()
    $security = @($Changes | Where-Object { $_.kind -eq 'security' })
    $audit = @($Changes | Where-Object { $_.kind -eq 'audit' })
    $fileChanges = @($Changes | Where-Object { $_.kind -eq 'file' -or $_.kind -eq 'tasks' })
    # Marker first: if publication fails after the files change, the next plan retries it.
    $marker = $null
    if ($security.Count -or $audit.Count -or $fileChanges.Count -or @($Changes | Where-Object { $_.kind -eq 'publish' }).Count) {
        $marker = Join-Path (Initialize-GpbStateDir $Context $Gpo) 'pending-publish'
        [IO.File]::WriteAllText($marker, [datetime]::UtcNow.ToString('o'))
    }
    if ($security.Count) {
        $path = Get-GpbInfPath $Context $Gpo
        $inf = ConvertFrom-GpbInf (Read-GpbText $path)
        foreach ($c in $security) {
            if (-not $inf.Contains($c.item.section)) { $inf[$c.item.section] = [ordered]@{} }
            $inf[$c.item.section][$c.item.key] = $c.item.value
        }
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force)
        [IO.File]::WriteAllText($path, (ConvertTo-GpbInf $inf), [Text.Encoding]::Unicode)
        $pairs += $GpbSecurityCse
    }
    if ($audit.Count) {
        $path = Get-GpbAuditPath $Context $Gpo
        $rows = ConvertFrom-GpbAuditCsv (Read-GpbText $path)
        foreach ($c in $audit) {
            $rows[$c.item.guid] = [pscustomobject]@{ Machine = ''; Target = 'System'; Subcategory = $c.item.subcategory; Guid = $c.item.guid; Inclusion = (Get-GpbInclusion $c.item.setting); Exclusion = ''; Value = [string]$c.item.setting }
        }
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force)
        [IO.File]::WriteAllText($path, (ConvertTo-GpbAuditCsv $rows), [Text.UTF8Encoding]::new($false))
        $pairs += $GpbAuditCse
    }
    $tasks = @(Get-GpbProp $Def 'tasks')
    foreach ($c in @($Changes | Where-Object { $_.kind -eq 'file' })) {
        $dest = Get-GpbScriptPath $Context $Gpo $c.item.file.name
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $dest) -Force)
        [IO.File]::Copy($Downloaded[$c.item.file.name], $dest, $true)
    }
    if (@($Changes | Where-Object { $_.kind -eq 'tasks' }).Count) {
        $path = Get-GpbTasksPath $Context $Gpo
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force)
        [IO.File]::WriteAllText($path, (ConvertTo-GpbTasksXml $Context $Gpo $tasks), [Text.UTF8Encoding]::new($false))
    }
    if ($fileChanges.Count) { $pairs += $GpbTaskCses }
    if (@($Changes | Where-Object { $_.kind -eq 'publish' }).Count) {
        if (@($Def.security).Count) { $pairs += $GpbSecurityCse }
        if (@($Def.audit).Count) { $pairs += $GpbAuditCse }
        if ($tasks.Count) { $pairs += $GpbTaskCses }
    }
    if ($pairs.Count) { Update-GpbVersion -Context $Context -Gpo $Gpo -Pairs $pairs }
    if ($marker) { [IO.File]::Delete($marker) }
    if ($filter -and @($Changes | Where-Object { $_.kind -eq 'wmiLink' }).Count) {
        Set-ADObject -Identity (Get-GpbGpoDn $Context $Gpo) -Replace @{ gPCWQLFilter = "[$($Context.DnsRoot);$($filter.'msWMI-ID');0]" } -Server $Context.Server -ErrorAction Stop
    }
    foreach ($c in @($Changes | Where-Object { $_.kind -eq 'link' })) {
        $state = 'No'; if ($LinkOn) { $state = 'Yes' }
        if ($c.Contains('exists')) { Set-GPLink -Guid $Gpo.Id -Target $LinkTo -LinkEnabled $state -Server $Context.Server -ErrorAction Stop | Out-Null }
        else { New-GPLink -Guid $Gpo.Id -Target $LinkTo -LinkEnabled $state -Server $Context.Server -ErrorAction Stop | Out-Null }
    }
    return $Gpo
}

function Get-GpbPublicChanges {
    param($Changes)
    return @($Changes | ForEach-Object { $o = [ordered]@{}; foreach ($k in @('kind', 'target', 'current', 'desired', 'cis')) { if ($_.Contains($k)) { $o[$k] = $_[$k] } }; $o })
}

function Test-GpbFlag {
    param([string]$Name, [string]$Value)
    if ($Value -eq '' -or $Value -eq 'false') { return $false }
    if ($Value -eq 'true') { return $true }
    throw "$Name must be true or false."
}

function Invoke-GpoBaseline {
    param([string]$Action = 'Install', [string]$Definition = '', [string]$Apply = '', [string]$LinkTo = '', [string]$LinkEnabled = '', [string]$AllowDefaultPolicy = '', $Context, $DefinitionObject)
    # Binary cmdlets report most failures as non-terminating errors; every one must stop the run.
    $ErrorActionPreference = 'Stop'
    $report = [ordered]@{ version = '1'; status = 'plan'; action = $Action; definition = $Definition; gpo = [ordered]@{}; changes = @(); backupId = $null }
    $refuse = { param($Why) $report.status = 'refused'; $report.reason = $Why; return @{ report = $report; exitCode = 1 } }
    try {
        $applyOn = Test-GpbFlag 'Apply' $Apply
        $linkOn = Test-GpbFlag 'LinkEnabled' $LinkEnabled
        $allowDefault = Test-GpbFlag 'AllowDefaultPolicy' $AllowDefaultPolicy
    } catch { return (& $refuse $_.Exception.Message) }
    $def = $DefinitionObject
    if (-not $def) { $def = Get-GpbDefinition $Definition }
    if (-not $def) { return (& $refuse 'Unknown Definition. Embedded: cis-ws2022-dc-low-risk.') }
    $report.definition = [string](Get-GpbProp $def 'id')
    $problem = Test-GpbDefinition $def
    if ($problem) { return (& $refuse $problem) }
    try {
        if (-not $Context) { $Context = Get-GpbContext }
        $gpo = Get-GpbGpo -Context $Context -Name $def.gpoName
        $isDefault = $GpbDefaultPolicies.Values -contains $def.gpoName
        if ($gpo -and $GpbDefaultPolicies.ContainsKey($gpo.Id.ToString().ToLower())) { $isDefault = $true }
        $owned = $false
        if ($gpo -and $gpo.Description) { $owned = ([string]$gpo.Description).Contains("[relian-gpo-baseline:$($def.id)]") }
        $report.gpo = [ordered]@{ name = $def.gpoName; id = $null; exists = [bool]$gpo; owned = $owned; default = $isDefault }
        if ($gpo) { $report.gpo.id = [string]$gpo.Id }
        if ($isDefault -and -not ($def.allowDefaultPolicy -eq $true -and $allowDefault)) { return (& $refuse 'Default policies change only when the definition sets allowDefaultPolicy and AllowDefaultPolicy=true is passed.') }
        if ($isDefault -and -not $gpo) { return (& $refuse 'Default policy not found.') }
        if ($gpo -and -not $isDefault -and -not $owned) { return (& $refuse 'A GPO with this name exists without the Relian marker. It was not changed.') }
        $w = Get-GpbProp $def 'wmiFilter'
        $ownFilter = $null
        if ($w) {
            $ownFilter = Get-GpbWmiFilter -Context $Context -Name $w.name
            if ($ownFilter -and -not ([string]$ownFilter.'msWMI-Parm1').Contains("[relian-gpo-baseline:$($def.id)]")) { return (& $refuse 'A WMI filter with this name exists without the Relian marker. It was not changed.') }
        }
        $backupDir = $null; $lastBackup = $null
        if ($gpo) {
            $backupDir = Join-Path $Context.BackupRoot ('{' + $gpo.Id.ToString().ToUpper() + '}')
            $lastPath = Join-Path $backupDir 'last-backup.json'
            if ([IO.File]::Exists($lastPath)) { $lastBackup = ([IO.File]::ReadAllText($lastPath) | ConvertFrom-Json).backupId }
        }

        if ($Action -eq 'Uninstall') {
            if (-not $gpo) { $report.status = 'nothingToUninstall'; return @{ report = $report; exitCode = 0 } }
            if ($isDefault -and -not $lastBackup) { return (& $refuse 'No Relian backup of this default policy to restore.') }
            $kind = 'remove'; if ($isDefault) { $kind = 'restore' }
            $report.changes = @([ordered]@{ kind = $kind; target = $def.gpoName; current = $null; desired = $lastBackup })
            if (-not $applyOn) { return @{ report = $report; exitCode = 0 } }
            if (-not $Context.IsPdc) { return (& $refuse 'Run changes on the PDC emulator.') }
            $report.backupId = Save-GpbBackup -Context $Context -Gpo $gpo -DefinitionId $def.id
            if ($isDefault) { Restore-GPO -BackupId $lastBackup -Path $backupDir -Server $Context.Server -ErrorAction Stop | Out-Null; $report.status = 'restored' }
            else {
                Remove-GPO -Guid $gpo.Id -Server $Context.Server -ErrorAction Stop | Out-Null
                # The owned WMI filter goes too, unless another GPO still uses it.
                if ($ownFilter) {
                    $users = @(Get-ADObject -SearchBase ('CN=Policies,CN=System,' + $Context.DomainDN) -LDAPFilter "(gPCWQLFilter=*$($ownFilter.'msWMI-ID')*)" -Server $Context.Server -ErrorAction Stop)
                    if ($users.Count -eq 0) { Remove-ADObject -Identity $ownFilter.DistinguishedName -Confirm:$false -Server $Context.Server -ErrorAction Stop }
                }
                $report.status = 'removed'
            }
            return @{ report = $report; exitCode = 0 }
        }

        if ($LinkTo) {
            if ($isDefault) { return (& $refuse 'Default policies are not linked by this package.') }
            # shortcut: DNs with escaped commas are refused rather than parsed.
            if ($LinkTo -notmatch '^OU=[^,\\]+(,(OU|DC)=[^,\\]+)*$' -or -not $LinkTo.EndsWith(',' + $Context.DomainDN, [StringComparison]::OrdinalIgnoreCase)) { return (& $refuse 'LinkTo must be an OU distinguished name in this domain.') }
        }
        $changes = Get-GpbPlan -Context $Context -Def $def -Gpo $gpo -LinkTo $LinkTo -LinkOn $linkOn
        $report.changes = @(Get-GpbPublicChanges $changes)
        $report.changeCount = $changes.Count
        if (-not $applyOn) { return @{ report = $report; exitCode = 0 } }
        if (-not $Context.IsPdc) { return (& $refuse 'Run changes on the PDC emulator.') }
        if ($changes.Count -eq 0) { $report.status = 'noChange'; return @{ report = $report; exitCode = 0 } }
        $err = $null
        try { $gpo = Invoke-GpbApply -Context $Context -Def $def -Gpo $gpo -Changes $changes -LinkTo $LinkTo -LinkOn $linkOn -Report $report }
        catch { $err = Protect-GpbText $_.Exception.Message }
        if (-not $gpo) { $gpo = Get-GpbGpo -Context $Context -Name $def.gpoName }
        $left = @()
        if ($gpo) { $left = @(Get-GpbPublicChanges (Get-GpbPlan -Context $Context -Def $def -Gpo $gpo -LinkTo $LinkTo -LinkOn $linkOn)) }
        else { $left = @($report.changes) }
        if ($err -or $left.Count) {
            $report.status = 'partial'; $report.left = $left; $report.error = $err
            return @{ report = $report; exitCode = 1 }
        }
        $report.status = 'applied'
        return @{ report = $report; exitCode = 0 }
    } catch {
        $report.status = 'failed'; $report.error = Protect-GpbText $_.Exception.Message
        return @{ report = $report; exitCode = 1 }
    }
}

if ($env:RELIAN_DEPLOY_TEST -eq '1' -and $MyInvocation.InvocationName -eq '.') { return }
if (@('Install', 'Update', 'Repair', 'Reinstall', 'Uninstall') -notcontains $Action) { [Console]::Error.WriteLine('Unsupported action.'); exit 1 }
$run = Invoke-GpoBaseline -Action $Action -Definition $Definition -Apply $Apply -LinkTo $LinkTo -LinkEnabled $LinkEnabled -AllowDefaultPolicy $AllowDefaultPolicy
Write-Output (ConvertTo-GpbBoundedJson $run.report)
exit $run.exitCode
