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
      TenantId            Entra tenant GUID, for {{TenantId}}
      LibraryIdHex        hex of the UTF-8 SharePoint library ID ("Copy library ID"), for
                          {{LibraryId}}. Over 128 hex characters, split it in order into
                          LibraryIdHex, LibraryIdHex2 ... LibraryIdHex8, each at most 128.
                          Hex, because the ID holds & and =. Its tenantId must equal TenantId.
      LibraryName         [A-Za-z0-9 ]{1,40}, for {{LibraryName}}; also part of the marker
                          ([relian-gpo-baseline:<id>:<LibraryName>]) when the GPO name uses it
      ApplyTo, ApplyType  sAMAccountName (a computer without the $) and Group, User or
                          Computer. Only for a definition with securityFilter: Authenticated
                          Users keep GpoRead (MS16-072) and ApplyTo gets GpoApply. Without
                          them an "optional" filter gives Authenticated Users GpoApply.
      AdoptGpo            GUID of an existing GPO without the marker, for an adopt definition
      AllowUnmarked       "true", required with AdoptGpo. An adopt definition only adds
                          registry values or a WMI filter link; an existing different value
                          or link is refused, and nothing is deleted.

    Definitions: cis-ws2022-dc-low-risk, comet-vss-provider-qemu, workstations-only (adopt:
    adds the workstation WMI filter), onedrive-workstations (TenantId), onedrive-users,
    onedrive-automount (TenantId, LibraryIdHex, LibraryName, ApplyTo), password-lockout
    (Default Domain Policy, AllowDefaultPolicy). The OneDrive definitions may be linked at
    the domain root (LinkTo = the domain DN).

    Install, Update, Repair and Reinstall compare the GPO with the definition and print
    the differences. With Apply=true they create the GPO (description carries the
    marker [relian-gpo-baseline:<id>]) or, for an existing GPO, run Backup-GPO to
    %ProgramData%\Relian\gpo-backups\{GPO GUID} first, then write only the differing
    values. A GPO with the same name but without the marker is never touched.

    Uninstall with Apply=true backs up and removes the GPO this package created, or,
    for an allowed default policy, restores the backup taken before the last change. For an
    adopted GPO it backs up, then undoes only what adopt added (values that still match, and
    its own WMI link); the backup taken before adoption stays for a manual Restore-GPO.

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
    [string]$AllowDefaultPolicy = '',
    [string]$TenantId = '',
    [string]$LibraryIdHex = '', [string]$LibraryIdHex2 = '', [string]$LibraryIdHex3 = '', [string]$LibraryIdHex4 = '',
    [string]$LibraryIdHex5 = '', [string]$LibraryIdHex6 = '', [string]$LibraryIdHex7 = '', [string]$LibraryIdHex8 = '',
    [string]$LibraryName = '',
    [string]$ApplyTo = '',
    [string]$ApplyType = '',
    [string]$AdoptGpo = '',
    [string]$AllowUnmarked = ''
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
    "description": "Adds COMET_FORCE_VSS_PROVIDER=system to Comet's service environment if missing (merge, never replace). Managed by the Relian gpo-baseline package. A new script version means publishing a new content-addressed blob and bumping both the URL and the sha256 together.",
    "file": {
     "name": "Invoke-CometVssProvider.ps1",
     "url": "https://relianpub.blob.core.windows.net/pub/sec/Invoke-CometVssProvider-2311bb495f855e34c6b8db7f50ae8b02498d5258750590c3e5cdd672f2cfb8ba.ps1",
     "sha256": "2311bb495f855e34c6b8db7f50ae8b02498d5258750590c3e5cdd672f2cfb8ba"
    },
    "arguments": "-Action Install",
    "intervalMinutes": 60,
    "bootDelayMinutes": 5
   }
  ]
 },
 {
  "id": "workstations-only",
  "adopt": true,
  "description": "Adds the workstation WMI filter to the existing GPO named by AdoptGpo, so it stops applying to servers. Adds only.",
  "allowDefaultPolicy": false,
  "registry": [],
  "security": [],
  "audit": [],
  "wmiFilter": {
   "name": "Relian - Workstations",
   "description": "Windows client editions only (Win32_OperatingSystem ProductType 1): no servers, no domain controllers.",
   "queries": ["SELECT * FROM Win32_OperatingSystem WHERE ProductType = 1"]
  }
 },
 {
  "id": "onedrive-workstations",
  "gpoName": "Relian - OneDrive (workstations)",
  "description": "OneDrive and Storage Sense for workstations: sync only the TenantId tenant, confirm shared deletes, stop downloads under 2 GB free, Storage Sense weekly (cloud files offline after 30 days unused, Recycle Bin after 60 days, Downloads never).",
  "allowDefaultPolicy": false,
  "securityFilter": "optional",
  "linkDomainRoot": true,
  "registry": [
   {"cis": "none: OneDrive AllowTenantList", "key": "HKLM\\SOFTWARE\\Policies\\Microsoft\\OneDrive\\AllowTenantList", "valueName": "{{TenantId}}", "type": "String", "value": "{{TenantId}}"},
   {"cis": "none: OneDrive SharedContentDeleteConfirmation", "key": "HKLM\\SOFTWARE\\Policies\\Microsoft\\OneDrive", "valueName": "SharedContentDeleteConfirmation", "type": "DWord", "value": 1},
   {"cis": "none: OneDrive MinDiskSpaceLimitInMB", "key": "HKLM\\SOFTWARE\\Policies\\Microsoft\\OneDrive", "valueName": "MinDiskSpaceLimitInMB", "type": "DWord", "value": 2048},
   {"cis": "none: Storage Sense", "key": "HKLM\\SOFTWARE\\Policies\\Microsoft\\Windows\\StorageSense", "valueName": "AllowStorageSenseGlobal", "type": "DWord", "value": 1},
   {"cis": "none: Storage Sense", "key": "HKLM\\SOFTWARE\\Policies\\Microsoft\\Windows\\StorageSense", "valueName": "ConfigStorageSenseGlobalCadence", "type": "DWord", "value": 7},
   {"cis": "none: Storage Sense", "key": "HKLM\\SOFTWARE\\Policies\\Microsoft\\Windows\\StorageSense", "valueName": "ConfigStorageSenseCloudContentDehydrationThreshold", "type": "DWord", "value": 30},
   {"cis": "none: Storage Sense", "key": "HKLM\\SOFTWARE\\Policies\\Microsoft\\Windows\\StorageSense", "valueName": "ConfigStorageSenseRecycleBinCleanupThreshold", "type": "DWord", "value": 60},
   {"cis": "none: Storage Sense", "key": "HKLM\\SOFTWARE\\Policies\\Microsoft\\Windows\\StorageSense", "valueName": "ConfigStorageSenseDownloadsCleanupThreshold", "type": "DWord", "value": 0}
  ],
  "security": [],
  "audit": [],
  "wmiFilter": {
   "name": "Relian - Workstations",
   "description": "Windows client editions only (Win32_OperatingSystem ProductType 1): no servers, no domain controllers.",
   "queries": ["SELECT * FROM Win32_OperatingSystem WHERE ProductType = 1"]
  }
 },
 {
  "id": "onedrive-users",
  "gpoName": "Relian - OneDrive (users)",
  "description": "OneDrive user policy: no personal OneDrive accounts.",
  "allowDefaultPolicy": false,
  "securityFilter": "optional",
  "linkDomainRoot": true,
  "registry": [
   {"cis": "none: OneDrive DisablePersonalSync", "key": "HKCU\\SOFTWARE\\Policies\\Microsoft\\OneDrive", "valueName": "DisablePersonalSync", "type": "DWord", "value": 1}
  ],
  "security": [],
  "audit": []
 },
 {
  "id": "onedrive-automount",
  "gpoName": "Relian - OneDrive AutoMount {{LibraryName}}",
  "description": "Mounts one SharePoint library in OneDrive (TenantAutoMount) for the ApplyTo account only, on workstations. Users cannot stop syncing it while the policy applies.",
  "allowDefaultPolicy": false,
  "securityFilter": "required",
  "linkDomainRoot": true,
  "registry": [
   {"cis": "none: OneDrive TenantAutoMount", "key": "HKCU\\Software\\Policies\\Microsoft\\OneDrive\\TenantAutoMount", "valueName": "{{LibraryName}}", "type": "String", "value": "{{LibraryId}}"}
  ],
  "security": [],
  "audit": [],
  "wmiFilter": {
   "name": "Relian - Workstations",
   "description": "Windows client editions only (Win32_OperatingSystem ProductType 1): no servers, no domain controllers.",
   "queries": ["SELECT * FROM Win32_OperatingSystem WHERE ProductType = 1"]
  }
 },
 {
  "id": "password-lockout",
  "gpoName": "Default Domain Policy",
  "description": "Domain password and lockout policy: 12-character minimum (enforced at each user's next change; no expiry is set), lockout after 10 bad passwords for 15 minutes, counter reset after 15 minutes.",
  "allowDefaultPolicy": true,
  "registry": [],
  "security": [
   {"cis": "none: minimum length 12", "section": "System Access", "key": "MinimumPasswordLength", "value": "12"},
   {"cis": "none: lockout threshold 10", "section": "System Access", "key": "LockoutBadCount", "value": "10"},
   {"cis": "1.2.4", "section": "System Access", "key": "ResetLockoutCount", "value": "15"},
   {"cis": "1.2.1", "section": "System Access", "key": "LockoutDuration", "value": "15"}
  ],
  "audit": []
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
# Uninstall skips the download-only URL check: it never downloads.
function Test-GpbDefinition {
    param($Def, [string]$Action = 'Install')
    if ([string](Get-GpbProp $Def 'id') -notmatch '^[a-z0-9][a-z0-9-]{0,63}$') { return 'Definition id is invalid.' }
    $sf = Get-GpbProp $Def 'securityFilter'
    if ($null -ne $sf -and @('required', 'optional') -cnotcontains [string]$sf) { return 'securityFilter must be required or optional.' }
    if ((Get-GpbProp $Def 'adopt') -eq $true) {
        # Adopt is add-only: no security template, audit, task, permission or default-policy change.
        if ($null -ne (Get-GpbProp $Def 'gpoName')) { return 'An adopt definition names its GPO only through AdoptGpo.' }
        foreach ($k in @('security', 'audit', 'tasks')) { if (@(Get-GpbProp $Def $k).Count) { return "An adopt definition may not carry $k." } }
        if ($null -ne $sf -or (Get-GpbProp $Def 'allowDefaultPolicy') -eq $true -or (Get-GpbProp $Def 'linkDomainRoot') -eq $true) { return 'An adopt definition may not change permissions, default policies or links.' }
    } elseif ([string](Get-GpbProp $Def 'gpoName') -notmatch '^[A-Za-z0-9 ._()-]{1,128}$') { return 'gpoName is invalid.' }
    foreach ($i in @(Get-GpbProp $Def 'registry')) {
        if ([string]$i.key -cnotmatch '^HK(LM|CU)\\[^\x00-\x1F]+$') { return "Registry key must be under HKLM or HKCU: $($i.key)" }
        if ([string]$i.valueName -notmatch '^[^\x00-\x1F\\]{1,255}$') { return "Registry value name is invalid: $($i.valueName)" }
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
        if ($Action -ne 'Uninstall' -and $url -notmatch '^https://[^/@\s]+/[^\s"]+$') { return 'Task file URL must be https without user info.' }
        if ([string](Get-GpbProp $f 'sha256') -cnotmatch '^[0-9a-f]{64}$') { return 'Task file sha256 must be 64 lowercase hex characters.' }
        # Arguments are placed in a -Command line: words, dashes and = only.
        if ([string](Get-GpbProp $t 'arguments') -notmatch '^[A-Za-z0-9 =_.-]*$') { return 'Task arguments may hold letters, digits, spaces, = _ . - only.' }
        if ([int](Get-GpbProp $t 'intervalMinutes') -lt 15 -or [int](Get-GpbProp $t 'intervalMinutes') -gt 1440) { return 'Task intervalMinutes must be 15 to 1440.' }
        if ([int](Get-GpbProp $t 'bootDelayMinutes') -lt 0 -or [int](Get-GpbProp $t 'bootDelayMinutes') -gt 60) { return 'Task bootDelayMinutes must be 0 to 60.' }
    }
    return $null
}

# ---- Arguments, placeholders and security filtering ----

$GpbGuid = '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}'

# The tenant of a SharePoint library ID ("Copy library ID": tenantId, siteId, webId, listId,
# webUrl and version, URL-encoded), or $null when it is not one.
function Get-GpbLibraryTenant {
    param([string]$Id)
    if ($Id -cnotmatch '\A[A-Za-z0-9%&=._:/{}-]{1,512}\z') { return $null }
    $pairs = @{}
    foreach ($part in $Id.Split('&')) {
        $kv = $part.Split('=', 2)
        if ($kv.Count -ne 2 -or $pairs.ContainsKey($kv[0])) { return $null }
        try { $pairs[$kv[0]] = [Uri]::UnescapeDataString($kv[1]) } catch { return $null }
    }
    if ($pairs.Count -ne 6) { return $null }
    if ([string]$pairs['tenantId'] -notmatch "\A$GpbGuid\z") { return $null }
    foreach ($k in @('siteId', 'webId', 'listId')) { if ([string]$pairs[$k] -notmatch "\A\{?$GpbGuid\}?\z") { return $null } }
    if ([string]$pairs['webUrl'] -notmatch '\Ahttps://[A-Za-z0-9-]+\.sharepoint\.com(/[^\s?#]*)?\z' -or [string]$pairs['version'] -notmatch '\A[0-9]{1,4}\z') { return $null }
    return ([string]$pairs['tenantId']).ToLowerInvariant()
}

# Validates every argument before anything is read. Throws the reason; returns the placeholder values and the filter target.
function ConvertFrom-GpbArguments {
    param([string]$TenantId, [string[]]$LibraryIdHex, [string]$LibraryName, [string]$ApplyTo, [string]$ApplyType, [string]$AdoptGpo)
    $values = @{}
    if ($TenantId) {
        if ($TenantId -notmatch "\A$GpbGuid\z") { throw 'TenantId must be a GUID.' }
        $values.TenantId = $TenantId.ToLowerInvariant()
    }
    # Parts joined in order; a part after an empty one is refused, so a dropped part cannot shorten the ID.
    $hex = ''; $gap = $false
    foreach ($p in @($LibraryIdHex)) {
        if (-not $p) { $gap = $true; continue }
        if ($gap) { throw 'LibraryIdHex parts must follow each other with no empty part between.' }
        if ($p -notmatch '\A(?:[0-9A-Fa-f]{2}){1,64}\z') { throw 'Each LibraryIdHex part must be 2 to 128 hex characters.' }
        $hex += $p
    }
    if ($hex) {
        $bytes = [byte[]]::new($hex.Length / 2)
        for ($i = 0; $i -lt $bytes.Length; $i++) { $bytes[$i] = [Convert]::ToByte($hex.Substring($i * 2, 2), 16) }
        try { $id = [Text.UTF8Encoding]::new($false, $true).GetString($bytes) } catch { throw 'LibraryIdHex is not UTF-8.' }
        $libTenant = Get-GpbLibraryTenant $id
        if (-not $libTenant) { throw 'LibraryIdHex is not a SharePoint Online library ID.' }
        if ($values.TenantId -and $libTenant -ne $values.TenantId) { throw 'The library ID belongs to another tenant than TenantId.' }
        $values.LibraryId = $id
    }
    if ($LibraryName) {
        if ($LibraryName -cnotmatch '\A[A-Za-z0-9](?:[A-Za-z0-9 ]{0,38}[A-Za-z0-9])?\z') { throw 'LibraryName must be 1 to 40 letters, digits or inner spaces.' }
        $values.LibraryName = $LibraryName
    }
    if ([bool]$ApplyTo -ne [bool]$ApplyType) { throw 'ApplyTo and ApplyType go together.' }
    if ($ApplyTo) {
        # The name goes into an LDAP filter and Set-GPPermission: no metacharacters.
        if ($ApplyTo -cnotmatch '\A[A-Za-z0-9](?:[A-Za-z0-9 ._-]{0,62}[A-Za-z0-9_-])?\z') { throw 'ApplyTo must be an account name (letters, digits, space . _ -; a computer without the $).' }
        if (@('Group', 'User', 'Computer') -cnotcontains $ApplyType) { throw 'ApplyType must be Group, User or Computer.' }
    }
    if ($AdoptGpo -and $AdoptGpo -notmatch "\A\{?$GpbGuid\}?\z") { throw 'AdoptGpo must be a GPO GUID.' }
    return @{ Values = $values; ApplyTo = $ApplyTo; ApplyType = $ApplyType; AdoptGpo = $AdoptGpo.Trim('{', '}') }
}

# A copy of the definition with {{Name}} replaced in gpoName and the registry key, valueName and
# value (the only places placeholders are read), its marker added, and the names it lacked.
function Resolve-GpbDefinition {
    param($Def, [hashtable]$Values)
    $missing = [Collections.Generic.List[string]]::new()
    $sub = {
        param($Text)
        if ($Text -isnot [string]) { return $Text }
        foreach ($m in [regex]::Matches($Text, '\{\{([A-Za-z]+)\}\}')) {
            $n = $m.Groups[1].Value
            if ($Values.ContainsKey($n)) { $Text = $Text.Replace($m.Value, [string]$Values[$n]) } elseif (-not $missing.Contains($n)) { $missing.Add($n) }
        }
        return $Text
    }
    $out = $Def.PSObject.Copy()
    if ($null -ne (Get-GpbProp $Def 'gpoName')) { $out.gpoName = & $sub $Def.gpoName }
    $registry = @()
    foreach ($i in @(Get-GpbProp $Def 'registry')) {
        $c = $i.PSObject.Copy()
        foreach ($k in @('key', 'valueName', 'value')) { if ($c.PSObject.Properties[$k]) { $c.$k = & $sub $c.$k } }
        $registry += $c
    }
    if ($out.PSObject.Properties['registry']) { $out.registry = $registry }
    $marker = "[relian-gpo-baseline:$($Def.id)]"
    if ([string](Get-GpbProp $Def 'gpoName') -match '\{\{LibraryName\}\}') { $marker = "[relian-gpo-baseline:$($Def.id):$($Values['LibraryName'])]" }
    $out | Add-Member -NotePropertyName marker -NotePropertyValue $marker -Force
    return @{ Def = $out; Missing = @($missing) }
}

# objectSid of the one account with this sAMAccountName and class, or $null.
function Get-GpbTrusteeSid {
    param($Context, [string]$Name, [string]$Type)
    $filter = @{ Group = "(&(objectClass=group)(sAMAccountName=$Name))"; User = "(&(objectCategory=person)(objectClass=user)(sAMAccountName=$Name))"; Computer = "(&(objectClass=computer)(sAMAccountName=$($Name)$))" }[$Type]
    $found = @(Get-ADObject -LDAPFilter $filter -Properties objectSid -Server $Context.Server -ErrorAction Stop)
    if ($found.Count -ne 1) { return $null }
    return [string]$found[0].objectSid
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
        # SYSTEM principal with no inner LogonType: Task Scheduler registers it as LocalSystem (service
        # account), which reads SYSVOL as the computer account. The outer GPP logonType is the GPMC value.
        [void]$sb.Append("<Properties action=`"R`" name=`"$(& $e $t.name)`" runAs=`"NT AUTHORITY\System`" logonType=`"S4U`"><Task version=`"1.3`">")
        [void]$sb.Append("<RegistrationInfo><Author>Relian gpo-baseline</Author><Description>$(& $e $t.description)</Description></RegistrationInfo>")
        [void]$sb.Append('<Principals><Principal id="Author"><UserId>NT AUTHORITY\System</UserId><RunLevel>HighestAvailable</RunLevel></Principal></Principals>')
        [void]$sb.Append('<Settings><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy><DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries><StopIfGoingOnBatteries>false</StopIfGoingOnBatteries><AllowHardTerminate>true</AllowHardTerminate><StartWhenAvailable>true</StartWhenAvailable><AllowStartOnDemand>true</AllowStartOnDemand><Enabled>true</Enabled><Hidden>false</Hidden><ExecutionTimeLimit>PT30M</ExecutionTimeLimit><Priority>7</Priority></Settings>')
        [void]$sb.Append("<Triggers><BootTrigger><Enabled>true</Enabled><Delay>PT$([int]$t.bootDelayMinutes)M</Delay></BootTrigger><TimeTrigger><Repetition><Interval>PT$([int]$t.intervalMinutes)M</Interval><StopAtDurationEnd>false</StopAtDurationEnd></Repetition><StartBoundary>2026-01-01T00:00:00</StartBoundary><Enabled>true</Enabled></TimeTrigger></Triggers>")
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
    param($Context, $Def, $Gpo, [string]$LinkTo, [bool]$LinkOn, $Filter)
    $changes = [Collections.Generic.List[object]]::new()
    if (-not $Gpo) { $changes.Add([ordered]@{ kind = 'create'; target = $Def.gpoName; current = $null; desired = 'new GPO' }) }
    if ($Filter) {
        $perms = @()
        if ($Gpo) { $perms = @(Get-GPPermission -Guid $Gpo.Id -All -Server $Context.Server -ErrorAction Stop | Where-Object { -not $_.Denied }) }
        $level = { param($Sid) $p = @($perms | Where-Object { [string]$_.Trustee.Sid -eq $Sid }) | Select-Object -First 1; if ($p) { [string]$p.Permission } else { 'None' } }
        # New-GPO grants Authenticated Users GpoApply.
        $au = 'GpoApply'; if ($Gpo) { $au = & $level 'S-1-5-11' }
        $want = 'GpoApply'; if ($Filter.Name) { $want = 'GpoRead' }
        if ($au -ne $want) { $changes.Add([ordered]@{ kind = 'permission'; target = 'Authenticated Users'; current = $au; desired = $want; trustee = 'Authenticated Users'; trusteeType = 'Group'; sid = 'S-1-5-11' }) }
        if ($Filter.Name) {
            $cur = 'None'; if ($Gpo) { $cur = & $level $Filter.Sid }
            if ($cur -ne 'GpoApply') { $changes.Add([ordered]@{ kind = 'permission'; target = "$($Filter.Type) $($Filter.Name)"; current = $cur; desired = 'GpoApply'; trustee = $Filter.Name; trusteeType = $Filter.Type; sid = $Filter.Sid }) }
            # A previous ApplyTo keeps apply unless removed: ApplyTo names the one account the GPO applies to.
            foreach ($p in @($perms | Where-Object { [string]$_.Permission -eq 'GpoApply' -and @('S-1-5-11', $Filter.Sid) -notcontains [string]$_.Trustee.Sid })) {
                $type = 'Group'; if (@('User', 'Computer') -contains [string]$p.Trustee.SidType) { $type = [string]$p.Trustee.SidType }
                # Set-GPPermission names a computer without its $.
                $name = [string]$p.Trustee.Name; if ($type -eq 'Computer') { $name = $name.TrimEnd('$') }
                $changes.Add([ordered]@{ kind = 'permission'; target = "$type $name"; current = 'GpoApply'; desired = 'None'; trustee = $name; trusteeType = $type; sid = [string]$p.Trustee.Sid })
            }
        }
    }
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

function Get-GpbAdoptRecordPath { param($Context, $Gpo, [string]$Id) Join-Path (Get-GpbStateDir $Context $Gpo) "adopted-$Id.json" }

# What an adopt definition added to this GPO: "key|valueName" strings and whether it set the WMI link.
function Get-GpbAdoptRecord {
    param($Context, $Gpo, [string]$Id)
    $added = @{ values = @(); wmiLink = $false }
    $path = Get-GpbAdoptRecordPath $Context $Gpo $Id
    if ([IO.File]::Exists($path)) {
        $o = [IO.File]::ReadAllText($path) | ConvertFrom-Json
        $added.values = @($o.values | Where-Object { $_ })
        $added.wmiLink = $o.wmiLink -eq $true
    }
    return $added
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
        $Gpo = New-GPO -Name $Def.gpoName -Comment ("$($Def.marker) Managed by the Relian gpo-baseline package. " + $Def.description) -Server $Context.Server -ErrorAction Stop
        $Report.gpo.id = [string]$Gpo.Id; $Report.gpo.exists = $true; $Report.gpo.owned = $true
    } else {
        # A publish-only retry backs up settings this package already wrote: it must not become the restore point.
        $settingChange = [bool]@($Changes | Where-Object { $_.kind -ne 'publish' }).Count
        $Report.backupId = Save-GpbBackup -Context $Context -Gpo $Gpo -DefinitionId $Def.id -Record:$settingChange
        if ((Get-GpbProp $Def 'adopt') -eq $true) {
            # Record what adopt adds before adding it (the plan only holds absent values and an empty link), so Uninstall undoes exactly that.
            $added = Get-GpbAdoptRecord $Context $Gpo $Def.id
            foreach ($c in @($Changes | Where-Object { $_.kind -eq 'registry' })) { $v = "$($c.item.key)|$($c.item.valueName)"; if ($added.values -notcontains $v) { $added.values += $v } }
            if (@($Changes | Where-Object { $_.kind -eq 'wmiLink' }).Count) { $added.wmiLink = $true }
            [IO.File]::WriteAllText((Get-GpbAdoptRecordPath $Context $Gpo $Def.id), ($added | ConvertTo-Json -Compress))
        }
    }
    # Security filtering before any setting: a run that stops here applies to fewer, never more.
    $permChanges = @($Changes | Where-Object { $_.kind -eq 'permission' })
    if ($permChanges.Count) {
        # Read again: a GPO created this run carries New-GPO's ACL, which the plan could not see.
        $now = @(Get-GPPermission -Guid $Gpo.Id -All -Server $Context.Server -ErrorAction Stop | Where-Object { -not $_.Denied })
        foreach ($c in $permChanges) {
            $p = @($now | Where-Object { [string]$_.Trustee.Sid -eq $c.sid }) | Select-Object -First 1
            if ($p -and @('GpoRead', 'GpoApply') -notcontains [string]$p.Permission) { throw "$($c.target) holds $($p.Permission) on this GPO; security filtering never lowers it." }
        }
    }
    foreach ($c in $permChanges) {
        Set-GPPermission -Guid $Gpo.Id -PermissionLevel $c.desired -TargetName $c.trustee -TargetType $c.trusteeType -Replace -Server $Context.Server -ErrorAction Stop | Out-Null
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
    param([string]$Action = 'Install', [string]$Definition = '', [string]$Apply = '', [string]$LinkTo = '', [string]$LinkEnabled = '', [string]$AllowDefaultPolicy = '',
        [string]$TenantId = '', [string[]]$LibraryIdHex = @(), [string]$LibraryName = '', [string]$ApplyTo = '', [string]$ApplyType = '', [string]$AdoptGpo = '', [string]$AllowUnmarked = '',
        $Context, $DefinitionObject)
    # Binary cmdlets report most failures as non-terminating errors; every one must stop the run.
    $ErrorActionPreference = 'Stop'
    $report = [ordered]@{ version = '1'; status = 'plan'; action = $Action; definition = $Definition; gpo = [ordered]@{}; changes = @(); backupId = $null }
    $refuse = { param($Why) $report.status = 'refused'; $report.reason = $Why; return @{ report = $report; exitCode = 1 } }
    $def = $DefinitionObject
    if (-not $def) { $def = Get-GpbDefinition $Definition }
    if (-not $def) { return (& $refuse ('Unknown Definition. Embedded: ' + ((($GpbDefinitionJson | ConvertFrom-Json) | ForEach-Object { $_.id }) -join ', ') + '.')) }
    $report.definition = [string](Get-GpbProp $def 'id')
    # As with the runner's pins: an empty hash exits 0 and does nothing, before its URL is read.
    foreach ($t in @(Get-GpbProp $def 'tasks')) {
        if ([string](Get-GpbProp (Get-GpbProp $t 'file') 'sha256') -eq '') { $report.status = 'notPinned'; $report.reason = "Task $($t.name) has no sha256. Nothing was read or changed."; return @{ report = $report; exitCode = 0 } }
    }
    try {
        $applyOn = Test-GpbFlag 'Apply' $Apply
        $linkOn = Test-GpbFlag 'LinkEnabled' $LinkEnabled
        $allowDefault = Test-GpbFlag 'AllowDefaultPolicy' $AllowDefaultPolicy
        $allowUnmarkedOn = Test-GpbFlag 'AllowUnmarked' $AllowUnmarked
        $a = ConvertFrom-GpbArguments -TenantId $TenantId -LibraryIdHex $LibraryIdHex -LibraryName $LibraryName -ApplyTo $ApplyTo -ApplyType $ApplyType -AdoptGpo $AdoptGpo
    } catch { return (& $refuse $_.Exception.Message) }
    $adopt = (Get-GpbProp $def 'adopt') -eq $true
    $sf = [string](Get-GpbProp $def 'securityFilter')
    if (-not $adopt -and ($a.AdoptGpo -or $allowUnmarkedOn)) { return (& $refuse 'AdoptGpo and AllowUnmarked are only for adopt definitions.') }
    if ($adopt -and -not ($a.AdoptGpo -and $allowUnmarkedOn)) { return (& $refuse 'An unmarked GPO is changed only when both AdoptGpo and AllowUnmarked=true are passed.') }
    if ($a.ApplyTo -and -not $sf) { return (& $refuse 'ApplyTo is only for definitions with a security filter.') }
    $resolved = Resolve-GpbDefinition $def $a.Values
    $def = $resolved.Def
    # Uninstall only needs the name.
    if ($resolved.Missing.Count -and ($Action -ne 'Uninstall' -or [string](Get-GpbProp $def 'gpoName') -match '\{\{')) { return (& $refuse ('Missing arguments for {{' + ($resolved.Missing -join '}}, {{') + '}} (LibraryId comes from LibraryIdHex).')) }
    $problem = Test-GpbDefinition $def $Action
    if ($problem) { return (& $refuse $problem) }
    if ($sf -eq 'required' -and -not $a.ApplyTo -and $Action -ne 'Uninstall') { return (& $refuse 'This definition applies only to the account named by ApplyTo and ApplyType.') }
    if ($a.ApplyType -and $Action -ne 'Uninstall') {
        # Computer policy is filtered on the computer, user policy on the user; a mismatch would never apply.
        $hives = @(@(Get-GpbProp $def 'registry') | ForEach-Object { ([string]$_.key).Substring(0, 4) })
        $machine = ($hives -contains 'HKLM') -or @(Get-GpbProp $def 'security').Count -or @(Get-GpbProp $def 'audit').Count -or @(Get-GpbProp $def 'tasks').Count
        if (($a.ApplyType -eq 'Computer' -and -not $machine) -or ($a.ApplyType -eq 'User' -and $hives -notcontains 'HKCU')) { return (& $refuse "ApplyType $($a.ApplyType) would never receive this definition's settings.") }
    }
    try {
        if (-not $Context) { $Context = Get-GpbContext }
        if ($adopt) {
            # Adopted by GUID only, never by name, and never created.
            $gpo = $null
            try { $gpo = Get-GPO -Guid $a.AdoptGpo -Server $Context.Server -ErrorAction Stop } catch [System.ArgumentException] { $gpo = $null }
            if (-not $gpo) { return (& $refuse 'AdoptGpo was not found. Nothing was changed.') }
            $def | Add-Member -NotePropertyName gpoName -NotePropertyValue ([string]$gpo.DisplayName) -Force
        } else { $gpo = Get-GpbGpo -Context $Context -Name $def.gpoName }
        $isDefault = $GpbDefaultPolicies.Values -contains $def.gpoName
        if ($gpo -and $GpbDefaultPolicies.ContainsKey($gpo.Id.ToString().ToLower())) { $isDefault = $true }
        $owned = $false
        if ($gpo -and $gpo.Description) { $owned = ([string]$gpo.Description).Contains($def.marker) }
        $report.gpo = [ordered]@{ name = $def.gpoName; id = $null; exists = [bool]$gpo; owned = $owned; default = $isDefault; adopted = $adopt }
        if ($gpo) { $report.gpo.id = [string]$gpo.Id }
        if ($adopt -and $isDefault) { return (& $refuse 'Default policies are changed only through their own definitions, never adopted.') }
        if ($isDefault -and -not ($def.allowDefaultPolicy -eq $true -and $allowDefault)) { return (& $refuse 'Default policies change only when the definition sets allowDefaultPolicy and AllowDefaultPolicy=true is passed.') }
        if ($isDefault -and -not $gpo) { return (& $refuse 'Default policy not found.') }
        if ($gpo -and -not $isDefault -and -not $owned -and -not $adopt) { return (& $refuse 'A GPO with this name exists without the Relian marker. It was not changed.') }
        $w = Get-GpbProp $def 'wmiFilter'
        $ownFilter = $null
        if ($w) {
            # Definitions share a filter by name (same queries, checked by the tests); any Relian marker owns it.
            $ownFilter = Get-GpbWmiFilter -Context $Context -Name $w.name
            if ($ownFilter -and -not ([string]$ownFilter.'msWMI-Parm1').Contains('[relian-gpo-baseline:')) { return (& $refuse 'A WMI filter with this name exists without the Relian marker. It was not changed.') }
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
            if ($adopt) {
                # Undo only what adopt recorded adding (still matching), so pre-existing settings and later edits by others survive.
                $undo = @()
                $added = Get-GpbAdoptRecord $Context $gpo $def.id
                foreach ($item in @($def.registry | Where-Object { $added.values -contains "$($_.key)|$($_.valueName)" })) {
                    $cur = $null
                    try { $cur = Get-GPRegistryValue -Guid $gpo.Id -Key $item.key -ValueName $item.valueName -Server $Context.Server -ErrorAction Stop } catch { $cur = $null }
                    if ($cur -and [string]$cur.Value -eq [string]$item.value -and [string]$cur.Type -eq [string]$item.type) { $undo += [ordered]@{ kind = 'removeValue'; target = "$($item.key)\$($item.valueName)"; current = [string]$cur.Value; desired = $null; item = $item } }
                }
                if ($ownFilter -and $added.wmiLink) {
                    $linked = [string](Get-ADObject -Identity (Get-GpbGpoDn $Context $gpo) -Properties gPCWQLFilter -Server $Context.Server -ErrorAction Stop).gPCWQLFilter
                    if ($linked -eq "[$($Context.DnsRoot);$($ownFilter.'msWMI-ID');0]") { $undo += [ordered]@{ kind = 'unlinkWmi'; target = $w.name; current = $linked; desired = $null } }
                }
                $report.changes = @(Get-GpbPublicChanges $undo)
                $report.lastBackupId = $lastBackup
                if (-not $applyOn) { return @{ report = $report; exitCode = 0 } }
                if (-not $Context.IsPdc) { return (& $refuse 'Run changes on the PDC emulator.') }
                if ($undo.Count -eq 0) { $report.status = 'noChange'; return @{ report = $report; exitCode = 0 } }
                $report.backupId = Save-GpbBackup -Context $Context -Gpo $gpo -DefinitionId $def.id
                foreach ($u in $undo) {
                    if ($u.kind -eq 'removeValue') { Remove-GPRegistryValue -Guid $gpo.Id -Key $u.item.key -ValueName $u.item.valueName -Server $Context.Server -ErrorAction Stop | Out-Null }
                    else { Set-ADObject -Identity (Get-GpbGpoDn $Context $gpo) -Clear gPCWQLFilter -Server $Context.Server -ErrorAction Stop }
                }
                [IO.File]::Delete((Get-GpbAdoptRecordPath $Context $gpo $def.id))
                $report.status = 'undone'
                return @{ report = $report; exitCode = 0 }
            }
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
            if ($isDefault -or $adopt) { return (& $refuse 'Default and adopted policies are not linked by this package.') }
            $domainRoot = (Get-GpbProp $def 'linkDomainRoot') -eq $true -and $LinkTo -ieq $Context.DomainDN
            # shortcut: DNs with escaped commas are refused rather than parsed.
            if (-not $domainRoot -and ($LinkTo -notmatch '^OU=[^,\\]+(,(OU|DC)=[^,\\]+)*$' -or -not $LinkTo.EndsWith(',' + $Context.DomainDN, [StringComparison]::OrdinalIgnoreCase))) { return (& $refuse 'LinkTo must be an OU distinguished name in this domain, or the domain itself for a definition that allows it.') }
        }
        $filter = $null
        if ($sf) {
            $filter = @{ Name = $a.ApplyTo; Type = $a.ApplyType; Sid = $null }
            if ($a.ApplyTo) {
                $filter.Sid = Get-GpbTrusteeSid -Context $Context -Name $a.ApplyTo -Type $a.ApplyType
                if (-not $filter.Sid) { return (& $refuse "ApplyTo was not found as exactly one $($a.ApplyType) in this domain.") }
                $report.applyTo = "$($a.ApplyType) $($a.ApplyTo)"
            }
        }
        $changes = Get-GpbPlan -Context $Context -Def $def -Gpo $gpo -LinkTo $LinkTo -LinkOn $linkOn -Filter $filter
        $report.changes = @(Get-GpbPublicChanges $changes)
        $report.changeCount = $changes.Count
        # Adopt only adds: an existing different value or WMI link is never replaced.
        if ($adopt -and @($changes | Where-Object { ($_.kind -eq 'registry' -and $null -ne $_.current) -or ($_.kind -eq 'wmiLink' -and $_.current) -or ($_.kind -eq 'wmiFilter' -and $null -ne $_.current) }).Count) { return (& $refuse 'The adopted GPO already holds a different value or WMI link, or the shared WMI filter has other queries. Adopt only adds; nothing was changed.') }
        # Security filtering only moves trustees between none, read and apply; edit rights are never lowered.
        if (@($changes | Where-Object { $_.kind -eq 'permission' -and @('None', 'GpoRead', 'GpoApply') -notcontains $_.current }).Count) { return (& $refuse 'A security filter trustee holds more than apply on this GPO. It was not changed.') }
        if (-not $applyOn) { return @{ report = $report; exitCode = 0 } }
        if (-not $Context.IsPdc) { return (& $refuse 'Run changes on the PDC emulator.') }
        if ($changes.Count -eq 0) { $report.status = 'noChange'; return @{ report = $report; exitCode = 0 } }
        $err = $null
        try { $gpo = Invoke-GpbApply -Context $Context -Def $def -Gpo $gpo -Changes $changes -LinkTo $LinkTo -LinkOn $linkOn -Report $report }
        catch { $err = Protect-GpbText $_.Exception.Message }
        if (-not $gpo) { $gpo = Get-GpbGpo -Context $Context -Name $def.gpoName }
        $left = @()
        if ($gpo) { $left = @(Get-GpbPublicChanges (Get-GpbPlan -Context $Context -Def $def -Gpo $gpo -LinkTo $LinkTo -LinkOn $linkOn -Filter $filter)) }
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
$run = Invoke-GpoBaseline -Action $Action -Definition $Definition -Apply $Apply -LinkTo $LinkTo -LinkEnabled $LinkEnabled -AllowDefaultPolicy $AllowDefaultPolicy `
    -TenantId $TenantId -LibraryIdHex @($LibraryIdHex, $LibraryIdHex2, $LibraryIdHex3, $LibraryIdHex4, $LibraryIdHex5, $LibraryIdHex6, $LibraryIdHex7, $LibraryIdHex8) `
    -LibraryName $LibraryName -ApplyTo $ApplyTo -ApplyType $ApplyType -AdoptGpo $AdoptGpo -AllowUnmarked $AllowUnmarked
Write-Output (ConvertTo-GpbBoundedJson $run.report)
exit $run.exitCode
