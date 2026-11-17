<#
.SYNOPSIS
    Adds one Active Directory user to one AD group, optionally until an expiry date, or removes that membership.

.DESCRIPTION
    Run it on a domain controller, as SYSTEM, through the deploy runner. The runner decodes the base64 JSON in
    -PackageArguments and passes each key to this script as a named parameter. All values are strings:
      User           required. The userPrincipalName, else the sAMAccountName. Characters [A-Za-z0-9._'@+-].
      Group          required. The group's sAMAccountName or cn. Characters [A-Za-z0-9 ._'&+-].
      ExpiresInDays  optional, Install only. 1 to 365. The membership is removed that many days from now.
      ExpiresOn      optional, Install only. yyyy-MM-dd or yyyy-MM-ddTHH:mm, DC local time, in the future and at
                     most 366 days out. A bare date means midnight at the start of that day.
      Section        'Evidence' is read-only: is the user a member, and is an expiry task registered.

    The allowed characters hold no LDAP filter metacharacter (* ( ) \ NUL), so a value goes into a filter as is.

    -Action Install (Update, Repair): add the user when not already a direct member, then read the membership back.
      With an expiry, a scheduled task \Relian\AdGroupExpiry-<group guid>-<user guid> is registered first, so a
      failed add never leaves a membership without its removal. Running Install again replaces the task's date.
      Install without an expiry leaves an existing expiry task alone and reports its date.
      The task runs as SYSTEM at the expiry, removes the membership, and then deletes itself. If the removal
      fails it keeps the task and retries every hour for 30 days. A start missed while the DC was off runs at
      the next boot (StartWhenAvailable). It holds only the two object GUIDs, in -EncodedCommand, and downloads
      nothing, so it does not depend on this package's file still being on disk.
    -Action Uninstall: remove the membership when present and delete the expiry task when present.

    Refused, for every action: a group that is privileged by name, by well-known SID or RID, or by adminCount=1
    (AdminSDHolder protects it, which means it is in a protected group). A user that is not in AD, which is what a
    cloud-only Entra ID account looks like from the DC: it has no AD object and cannot join an AD group. A user or
    group name that matches more than one object. A machine that is not a domain controller.

    Each run appends its result line to %ProgramData%\Relian\AdGroupMember\ad-group-member.log on the DC, and the
    expiry task appends its own lines there. AD's own time-limited membership needs the Privileged Access
    Management optional feature, which cannot be turned off once on, so this package does not use it.
    An empty -PinVersion exits 0 and changes nothing, for every action.
    Prints one JSON line, at most 2000 bytes. Exit 0 on success, 1 on any refusal or error.
#>
[CmdletBinding()]
param(
    [string]$DeploymentType = '',
    [string]$Action = '',
    [string]$PinVersion = '',
    [string]$Section = '',
    [string]$User = '',
    [string]$Group = '',
    [string]$ExpiresInDays = '',
    [string]$ExpiresOn = ''
)

$ErrorActionPreference = 'Stop'
$script:AgUserPattern = "\A[A-Za-z0-9._'@+-]{1,256}\z"
$script:AgGroupPattern = "\A[A-Za-z0-9 ._'&+-]{1,256}\z"
$script:AgGuidPattern = '\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z'
$script:AgTaskPath = '\Relian\'
$script:AgMaxBytes = 2000
$script:AgPrivilegedNames = @(
    'Domain Admins', 'Enterprise Admins', 'Administrators', 'Schema Admins', 'Account Operators',
    'Backup Operators', 'Server Operators', 'Print Operators', 'Group Policy Creator Owners', 'DnsAdmins',
    'Protected Users', 'Key Admins', 'Enterprise Key Admins', 'Domain Controllers',
    'Read-only Domain Controllers', 'Enterprise Read-only Domain Controllers'
)
# Builtin: Administrators, Account, Server, Print and Backup Operators. A rename or a localized name keeps these.
$script:AgPrivilegedSids = @('S-1-5-32-544', 'S-1-5-32-548', 'S-1-5-32-549', 'S-1-5-32-550', 'S-1-5-32-551')
# Domain RIDs: Domain Admins, Domain Controllers, Schema Admins, Enterprise Admins, Group Policy Creator Owners,
# Read-only DCs, Protected Users, Key Admins, Enterprise Key Admins, Enterprise Read-only DCs.
$script:AgPrivilegedRids = @(512, 516, 518, 519, 520, 521, 525, 526, 527, 498)
$script:AgLogPath = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'Relian\AdGroupMember\ad-group-member.log'

# Seams. Tests replace these; the defaults touch AD and the task scheduler.
$script:AgIsDc = { [int](Get-CimInstance -ClassName Win32_ComputerSystem).DomainRole -ge 4 }
$script:AgImport = { Import-Module ActiveDirectory -ErrorAction Stop }
$script:AgFindUsers = { param($ldap) @(Get-ADUser -LDAPFilter $ldap -Properties UserPrincipalName) }
$script:AgFindGroups = { param($ldap) @(Get-ADGroup -LDAPFilter $ldap -Properties adminCount) }
$script:AgMemberOf = { param($userGuid) @((Get-ADUser -Identity $userGuid -Properties MemberOf).MemberOf) }
$script:AgAdd = { param($groupGuid, $userGuid) Add-ADGroupMember -Identity $groupGuid -Members $userGuid }
$script:AgRemove = { param($groupGuid, $userGuid) Remove-ADGroupMember -Identity $groupGuid -Members $userGuid -Confirm:$false }
$script:AgNow = { [DateTime]::Now }
$script:AgGetTask = {
    param($name)
    $task = Get-ScheduledTask -TaskPath $script:AgTaskPath -TaskName $name -ErrorAction SilentlyContinue
    if ($task) { [string]@($task.Triggers)[0].StartBoundary }
}
$script:AgRegisterTask = {
    param($name, [DateTime]$at, $encoded)
    $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $taskAction = New-ScheduledTaskAction -Execute $exe -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded"
    $trigger = New-ScheduledTaskTrigger -Once -At $at -RepetitionInterval (New-TimeSpan -Hours 1) -RepetitionDuration (New-TimeSpan -Days 30)
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
    $null = Register-ScheduledTask -TaskPath $script:AgTaskPath -TaskName $name -Action $taskAction -Trigger $trigger `
        -Principal $principal -Settings $settings -Description 'Removes a temporary AD group membership, then deletes itself. Made by ad-group-member.' -Force
}
$script:AgUnregisterTask = { param($name) Unregister-ScheduledTask -TaskPath $script:AgTaskPath -TaskName $name -Confirm:$false }
$script:AgWriteLog = {
    param($line)
    $dir = Split-Path -Parent $script:AgLogPath
    if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
    Add-Content -LiteralPath $script:AgLogPath -Value ([DateTime]::Now.ToString('o') + ' ' + $line) -Encoding UTF8
}

# The script the expiry task runs. Only the two GUIDs and the task name are filled in, after a GUID check.
$script:AgTaskTemplate = @'
$ErrorActionPreference = 'Stop'
$g = '__GROUP__'; $u = '__USER__'; $n = '__TASK__'
$log = Join-Path $env:ProgramData 'Relian\AdGroupMember\ad-group-member.log'
function Write-AgLog($text) {
    try {
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $log) -Force
        Add-Content -LiteralPath $log -Value ([DateTime]::Now.ToString('o') + " expiry $n $text") -Encoding UTF8
    } catch { }
}
try {
    Import-Module ActiveDirectory -ErrorAction Stop
    $grp = Get-ADGroup -Filter "ObjectGUID -eq '$g'"
    $usr = Get-ADUser -Filter "ObjectGUID -eq '$u'" -Properties MemberOf
    if ($null -eq $grp -or $null -eq $usr) {
        Write-AgLog 'user or group no longer exists; nothing to remove'
    } elseif (@($usr.MemberOf) -contains $grp.DistinguishedName) {
        Remove-ADGroupMember -Identity $grp -Members $usr -Confirm:$false
        $after = Get-ADUser -Filter "ObjectGUID -eq '$u'" -Properties MemberOf
        if (@($after.MemberOf) -contains $grp.DistinguishedName) { throw 'still a member after removal' }
        Write-AgLog 'membership removed'
    } else {
        Write-AgLog 'not a member; nothing to remove'
    }
    Unregister-ScheduledTask -TaskPath '\Relian\' -TaskName $n -Confirm:$false
    Write-AgLog 'task deleted'
} catch {
    Write-AgLog ('failed, retrying hourly: ' + $_.Exception.Message)
    exit 1
}
'@

function Get-AgTaskName([string]$GroupGuid, [string]$UserGuid) { "AdGroupExpiry-$GroupGuid-$UserGuid" }

function Get-AgEncodedTask([string]$GroupGuid, [string]$UserGuid) {
    foreach ($id in @($GroupGuid, $UserGuid)) {
        if ($id -cnotmatch $script:AgGuidPattern) { throw 'refusing to build an expiry task from a value that is not a GUID' }
    }
    $text = $script:AgTaskTemplate.Replace('__GROUP__', $GroupGuid).Replace('__USER__', $UserGuid).Replace('__TASK__', (Get-AgTaskName $GroupGuid $UserGuid))
    return [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($text))
}

function Test-AgPrivileged($GroupObject, [string]$Requested) {
    foreach ($name in @($Requested, [string]$GroupObject.Name, [string]$GroupObject.SamAccountName)) {
        if ($script:AgPrivilegedNames -contains $name) { return $true }
    }
    $sid = [string]$GroupObject.SID
    if ($script:AgPrivilegedSids -contains $sid) { return $true }
    if ($sid -match '\AS-1-5-21-\d+-\d+-\d+-(\d+)\z' -and $script:AgPrivilegedRids -contains [int]$Matches[1]) { return $true }
    $adminCount = $GroupObject.PSObject.Properties['adminCount']
    if ($adminCount -and "$($adminCount.Value)" -eq '1') { return $true }
    return $false
}

# Returns a DateTime, $null for no expiry, or a string reason.
function Get-AgExpiry([string]$InDays, [string]$On, [DateTime]$Now) {
    if ($InDays -ne '' -and $On -ne '') { return 'give ExpiresInDays or ExpiresOn, not both' }
    if ($InDays -ne '') {
        if ($InDays -notmatch '\A[0-9]{1,3}\z' -or [int]$InDays -lt 1 -or [int]$InDays -gt 365) { return 'ExpiresInDays must be a whole number from 1 to 365' }
        return $Now.AddDays([int]$InDays)
    }
    if ($On -ne '') {
        $parsed = [DateTime]::MinValue
        $formats = [string[]]@('yyyy-MM-dd', 'yyyy-MM-ddTHH:mm')
        if (-not [DateTime]::TryParseExact($On, $formats, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeLocal, [ref]$parsed)) {
            return 'ExpiresOn must be yyyy-MM-dd or yyyy-MM-ddTHH:mm'
        }
        if ($parsed -le $Now) { return 'ExpiresOn is not in the future' }
        if ($parsed -gt $Now.AddDays(366)) { return 'ExpiresOn is more than 366 days away' }
        return $parsed
    }
    return $null
}

function Test-AgMember([string]$UserGuid, [string]$GroupDn) {
    return @(& $script:AgMemberOf $UserGuid) -contains $GroupDn
}

function Invoke-AgMain {
    param([string]$Action = '', [string]$Section = '', [string]$User = '', [string]$Group = '',
        [string]$ExpiresInDays = '', [string]$ExpiresOn = '', [string]$PinVersion = 'pinned')
    $result = [ordered]@{ Package = 'ad-group-member'; Action = $Action; Section = $Section; Status = 'error' }
    if ([string]::IsNullOrWhiteSpace($PinVersion)) { $result.Status = 'disabled'; return @{ ExitCode = 0; Result = $result } }
    $fail = { param($reason) $result.Reason = $reason; return @{ ExitCode = 1; Result = $result } }

    if ($Section -notin @('', 'Evidence')) { return & $fail 'unsupported section' }
    $evidence = $Section -eq 'Evidence'
    $removing = $Action -eq 'Uninstall'
    if (-not $evidence -and -not $removing -and $Action -notin @('Install', 'Update', 'Repair')) { return & $fail 'unsupported action' }
    # Rejected values are not echoed, so the output stays bounded.
    if ($User -cnotmatch $script:AgUserPattern) { return & $fail "User is required: a userPrincipalName or sAMAccountName from A-Z a-z 0-9 . _ ' @ + -" }
    if ($Group -cnotmatch $script:AgGroupPattern) { return & $fail "Group is required: a group name from A-Z a-z 0-9 space . _ ' & + -" }
    $expiry = Get-AgExpiry $ExpiresInDays $ExpiresOn (& $script:AgNow)
    if ($expiry -is [string]) { return & $fail $expiry }
    if ($null -ne $expiry -and ($evidence -or $removing)) { return & $fail 'an expiry applies to Install only' }

    if (-not [bool](& $script:AgIsDc)) { return & $fail 'not a domain controller; run this package on a DC' }
    & $script:AgImport

    $users = @(& $script:AgFindUsers "(&(objectCategory=person)(objectClass=user)(userPrincipalName=$User))")
    if ($users.Count -eq 0) { $users = @(& $script:AgFindUsers "(&(objectCategory=person)(objectClass=user)(sAMAccountName=$User))") }
    if ($users.Count -eq 0) {
        return & $fail "user $User is not in Active Directory (no userPrincipalName or sAMAccountName match). A cloud-only Entra ID account has no AD object and cannot join an AD group: create an AD account, or sync one, first."
    }
    if ($users.Count -gt 1) { return & $fail "user $User matches $($users.Count) AD objects; use a unique userPrincipalName" }
    $groups = @(& $script:AgFindGroups "(&(objectCategory=group)(|(sAMAccountName=$Group)(cn=$Group)))")
    if ($groups.Count -eq 0) { return & $fail "group $Group is not in Active Directory" }
    if ($groups.Count -gt 1) { return & $fail "group $Group matches $($groups.Count) AD groups; use its sAMAccountName" }
    $u = $users[0]; $g = $groups[0]
    if (Test-AgPrivileged $g $Group) { return & $fail "group $($g.Name) is privileged and is never changed by this package" }

    $userGuid = ([Guid]$u.ObjectGUID).ToString()
    $groupGuid = ([Guid]$g.ObjectGUID).ToString()
    $taskName = Get-AgTaskName $groupGuid $userGuid
    $result.User = [string]$u.SamAccountName
    $result.UserPrincipalName = [string]$u.UserPrincipalName
    $result.Group = [string]$g.Name
    $result.Member = Test-AgMember $userGuid ([string]$g.DistinguishedName)
    $result.ExpiryTask = "$($script:AgTaskPath)$taskName"
    $result.ExpiresAt = & $script:AgGetTask $taskName

    if ($evidence) { $result.Status = 'evidence'; return @{ ExitCode = 0; Result = $result } }

    if ($removing) {
        $changed = $false
        if ($result.Member) {
            & $script:AgRemove $groupGuid $userGuid
            if (Test-AgMember $userGuid ([string]$g.DistinguishedName)) { return & $fail 'still a member after removal' }
            $result.Member = $false
            $changed = $true
        }
        if ($null -ne $result.ExpiresAt) {
            & $script:AgUnregisterTask $taskName
            $result.ExpiresAt = $null
            $changed = $true
        }
        $result.Status = if ($changed) { 'removed' } else { 'absent' }
        return @{ ExitCode = 0; Result = $result }
    }

    # The task first: an add that fails after it leaves a task that finds no membership and deletes itself.
    if ($null -ne $expiry) {
        & $script:AgRegisterTask $taskName $expiry (Get-AgEncodedTask $groupGuid $userGuid)
        $result.ExpiresAt = & $script:AgGetTask $taskName
        if ($null -eq $result.ExpiresAt) { return & $fail 'expiry task not found after registering it; membership not added' }
    }
    if ($result.Member) {
        $result.Status = 'compliant'
    } else {
        & $script:AgAdd $groupGuid $userGuid
        if (-not (Test-AgMember $userGuid ([string]$g.DistinguishedName))) { return & $fail 'read-back after add did not find the membership' }
        $result.Member = $true
        $result.Status = 'applied'
    }
    return @{ ExitCode = 0; Result = $result }
}

# One line, never more than AgMaxBytes: a long exception message is cut, not the fields around it.
function ConvertTo-AgLine($Result) {
    $line = ConvertTo-Json -InputObject $Result -Depth 3 -Compress
    if ([System.Text.Encoding]::UTF8.GetByteCount($line) -gt $script:AgMaxBytes -and $Result.Contains('Reason')) {
        $Result.Reason = ([string]$Result.Reason).Substring(0, [Math]::Min(200, ([string]$Result.Reason).Length))
        $line = ConvertTo-Json -InputObject $Result -Depth 3 -Compress
    }
    return $line
}

if ($env:RELIAN_DEPLOY_TEST -eq '1' -and $MyInvocation.InvocationName -eq '.') {
    return
}

try {
    $run = Invoke-AgMain -Action $Action -Section $Section -User $User -Group $Group -ExpiresInDays $ExpiresInDays -ExpiresOn $ExpiresOn -PinVersion $PinVersion
} catch {
    $run = @{ ExitCode = 1; Result = [ordered]@{ Package = 'ad-group-member'; Status = 'error'; Reason = $_.Exception.Message } }
}
$line = ConvertTo-AgLine $run.Result
# A log write that fails must not hide the result of a change already made; stdout still carries it.
try { & $script:AgWriteLog $line } catch { }
Write-Output $line
exit $run.ExitCode
