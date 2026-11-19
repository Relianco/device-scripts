<#
.SYNOPSIS
    Reports, or disables, named Active Directory user accounts for a leaver. Never deletes, never removes group
    memberships, never touches a mailbox.

.DESCRIPTION
    Run it on a domain controller, as SYSTEM, through the deploy runner (Windows PowerShell 5.1). The runner decodes
    the base64 JSON in -PackageArguments and passes each key as a named parameter. All values are strings:
      Users        required. Comma-separated sAMAccountNames, 1 to 20 of them. Characters [A-Za-z0-9._'-], at most 20 each.
      Mode         Report (default) or Disable. -Action Report|Disable is accepted too, but the runner's own
                   Install/Update/Uninstall action is ignored (it means Report).
      Description  optional, Disable only. Default "Disabled by Relian yyyy-MM-dd". 1 to 1024 characters, no control
                   characters. It replaces the account's Description.
      TargetOu     optional, Disable only. The distinguished name of an OU. The account is moved there after it is
                   disabled, and only when that OU exists. A missing OU skips the move and says so; it does not fail.

    Report: prints the before-state of each account (enabled, description, DN, group names, lastLogonTimestamp,
    adminCount, which privileged groups it is in) and whether Disable would refuse it. It changes nothing.

    Disable: refuses an account that does not exist or matches more than one object, is a member (nested or by primary
    group) of Domain Admins, Enterprise Admins or Schema Admins, is a built-in account (RID under 1000, Administrator,
    Guest, krbtgt, DefaultAccount) or a directory-sync or break-glass account (MSOL_*, AAD_*, Sync_*, svc-dirmaint*,
    breakglass*, break-glass*, in the sAMAccountName or the userPrincipalName). For every other account it writes a JSON
    backup of the before-state to C:\Relian\Offboard\<yyyy-MM-dd>\<sam>-<HHmmss>.json (the folders are locked to SYSTEM and
    Administrators), disables the account, sets the Description, optionally moves it, then reads it back. Any mismatch
    exits 1. A refused account is not touched and the others still run. Group memberships are left as they are.

    Prints one JSON line per account. Exit 0 when every account succeeded, 1 on any refusal, miss or mismatch.
    An empty -PinVersion exits 0 and changes nothing.
    Follow-up, outside this package: revoke sign-in sessions and run a directory sync (see the README).
#>
[CmdletBinding()]
param(
    [string]$DeploymentType = '',
    [string]$Action = '',
    [string]$PinVersion = '',
    [string]$Mode = '',
    [string]$Users = '',
    [string]$Description = '',
    [string]$TargetOu = ''
)

$ErrorActionPreference = 'Stop'
$script:OfSamPattern = "\A[A-Za-z0-9._'-]{1,20}\z"
$script:OfOuPattern = "\A(OU|CN)=[A-Za-z0-9 ._'&+-]{1,64}(,(OU|CN|DC)=[A-Za-z0-9 ._'&+-]{1,64}){0,15}\z"
$script:OfDescriptionPattern = '\A[^\x00-\x1f\x7f]{1,1024}\z'
$script:OfMaxUsers = 20
$script:OfMaxGroups = 40
$script:OfBackupRoot = 'C:\Relian\Offboard'
$script:OfBuiltinNames = @('Administrator', 'Guest', 'krbtgt', 'DefaultAccount')
# Sync service accounts and the break-glass names (Relian-CIPP docs/breakglass-accounts.md: svc-dirmaint@*).
$script:OfProtectedNamePattern = '\A(MSOL_|AAD_|Sync_|svc-dirmaint|breakglass|break-glass|break_glass)'
$script:OfAdminRids = @(512, 518, 519)
$script:OfAdminNames = @('Domain Admins', 'Schema Admins', 'Enterprise Admins')
# Privileged for the report only: Builtin Administrators/Account/Server/Print/Backup Operators and the other privileged RIDs.
$script:OfPrivilegedSids = @('S-1-5-32-544', 'S-1-5-32-548', 'S-1-5-32-549', 'S-1-5-32-550', 'S-1-5-32-551')
$script:OfPrivilegedRids = @(512, 516, 518, 519, 520, 521, 525, 526, 527, 498)
$script:OfProps = @('Enabled', 'Description', 'MemberOf', 'lastLogonTimestamp', 'adminCount', 'UserPrincipalName', 'PrimaryGroupID', 'whenCreated')

# Seams. Tests replace these; the defaults touch AD and the file system.
$script:OfIsDc = { [int](Get-CimInstance -ClassName Win32_ComputerSystem).DomainRole -ge 4 }
$script:OfImport = { Import-Module ActiveDirectory -ErrorAction Stop }
$script:OfFind = { param($sam) @(Get-ADUser -LDAPFilter "(&(objectCategory=person)(objectClass=user)(sAMAccountName=$sam))" -Properties $script:OfProps) }
$script:OfGet = { param($guid) Get-ADUser -Identity $guid -Properties $script:OfProps }
# Every group the user is in, nested ones too (LDAP_MATCHING_RULE_IN_CHAIN). The DN is escaped for a filter.
$script:OfGroups = {
    param($dn)
    $safe = $dn.Replace('\', '\5c').Replace('*', '\2a').Replace('(', '\28').Replace(')', '\29').Replace([string][char]0, '\00')
    @(Get-ADGroup -LDAPFilter "(member:1.2.840.113556.1.4.1941:=$safe)" -Properties adminCount)
}
$script:OfDisable = { param($guid) Disable-ADAccount -Identity $guid }
$script:OfSetDescription = { param($guid, $text) Set-ADUser -Identity $guid -Description $text }
$script:OfOuExists = { param($dn) [bool](Get-ADObject -LDAPFilter '(objectClass=organizationalUnit)' -SearchBase $dn -SearchScope Base -ErrorAction SilentlyContinue) }
$script:OfMove = { param($guid, $ou) Move-ADObject -Identity $guid -TargetPath $ou }
$script:OfNow = { [DateTime]::Now }
$script:OfHost = { $env:COMPUTERNAME }
$script:OfLockFolder = {
    param($path)
    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
        $identity = New-Object System.Security.Principal.SecurityIdentifier($sid)
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($identity, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $path -AclObject $acl
}

function ConvertTo-OfTime($FileTime) {
    if ($null -eq $FileTime -or [int64]$FileTime -le 0) { return $null }
    return [DateTime]::FromFileTimeUtc([int64]$FileTime).ToString('o')
}

function Get-OfRid([string]$Sid) {
    if ($Sid -match '\AS-1-5-21-\d+-\d+-\d+-(\d+)\z') { return [int]$Matches[1] }
    return -1
}

# The before-state: what a restore needs. memberOf holds the direct group DNs, groups the names of all groups.
function Get-OfSnapshot($User, $Groups) {
    $names = @($Groups | ForEach-Object { [string]$_.Name } | Sort-Object)
    $privileged = [System.Collections.Generic.List[string]]::new()
    $adminHit = [System.Collections.Generic.List[string]]::new()
    foreach ($g in @($Groups)) {
        $sid = [string]$g.SID; $rid = Get-OfRid $sid
        $count = $g.PSObject.Properties['adminCount']
        if ($script:OfAdminRids -contains $rid -or $script:OfAdminNames -contains [string]$g.Name) { $adminHit.Add([string]$g.Name) }
        if ($adminHit.Contains([string]$g.Name) -or $script:OfPrivilegedSids -contains $sid -or $script:OfPrivilegedRids -contains $rid -or ($count -and "$($count.Value)" -eq '1')) {
            $privileged.Add([string]$g.Name)
        }
    }
    # The primary group is not in the member chain, so a Domain Admins primary group needs its own check.
    if ($script:OfAdminRids -contains [int]$User.PrimaryGroupID) { $adminHit.Add("primary group RID $($User.PrimaryGroupID)"); $privileged.Add("primary group RID $($User.PrimaryGroupID)") }
    $userCount = $User.PSObject.Properties['adminCount']
    return [ordered]@{
        sam = [string]$User.SamAccountName; upn = [string]$User.UserPrincipalName; dn = [string]$User.DistinguishedName
        guid = ([Guid]$User.ObjectGUID).ToString(); sid = [string]$User.SID
        enabled = [bool]$User.Enabled; description = [string]$User.Description
        lastLogonTimestamp = ConvertTo-OfTime $User.lastLogonTimestamp
        adminCount = if ($userCount) { [string]$userCount.Value } else { '' }
        privilegedGroups = @($privileged | Select-Object -Unique); adminGroups = @($adminHit | Select-Object -Unique)
        memberOf = @($User.MemberOf | ForEach-Object { [string]$_ }); groups = $names
    }
}

# $null when Disable may proceed, else the reason it refuses.
function Get-OfRefusal($Snapshot) {
    $sam = $Snapshot.sam
    if ($script:OfBuiltinNames -contains $sam) { return "$sam is a built-in account" }
    $rid = Get-OfRid $Snapshot.sid
    if ($rid -ge 0 -and $rid -lt 1000) { return "$sam is a built-in account (RID $rid)" }
    foreach ($name in @($sam, ([string]$Snapshot.upn).Split('@')[0])) {
        if ($name -imatch $script:OfProtectedNamePattern) { return "$sam matches a break-glass or directory-sync account name" }
    }
    if ($Snapshot.adminGroups.Count -gt 0) { return "$sam is in $($Snapshot.adminGroups -join ', ')" }
    return $null
}

function Test-OfDescription([string]$Text) { return $Text -cmatch $script:OfDescriptionPattern }

function Write-OfBackup($Snapshot, [DateTime]$Now) {
    $dir = Join-Path $script:OfBackupRoot $Now.ToString('yyyy-MM-dd')
    foreach ($p in @($script:OfBackupRoot, $dir)) {
        if (-not (Test-Path -LiteralPath $p)) { $null = New-Item -ItemType Directory -Path $p -Force }
        & $script:OfLockFolder $p
    }
    $file = Join-Path $dir ("{0}-{1}.json" -f $Snapshot.sam, $Now.ToString('HHmmss'))
    $doc = [ordered]@{ takenAt = $Now.ToString('o'); host = [string](& $script:OfHost); before = $Snapshot }
    [System.IO.File]::WriteAllText($file, (ConvertTo-Json -InputObject $doc -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
    $back = ConvertFrom-Json ([System.IO.File]::ReadAllText($file))
    if ($back.before.guid -ne $Snapshot.guid) { throw 'backup read-back did not match' }
    return $file
}

function Invoke-OfAccount([string]$Sam, [bool]$Apply, [string]$Text, [string]$Ou) {
    $line = [ordered]@{ Package = 'ad-user-offboard'; Mode = if ($Apply) { 'Disable' } else { 'Report' }; Sam = $Sam; Status = 'error' }
    try {
        $found = @(& $script:OfFind $Sam)
        if ($found.Count -eq 0) { $line.Status = 'notfound'; $line.Reason = "no AD user with sAMAccountName $Sam"; return $line }
        if ($found.Count -gt 1) { $line.Status = 'refused'; $line.Reason = "$Sam matches $($found.Count) AD objects"; return $line }
        $user = $found[0]
        $groups = @(& $script:OfGroups ([string]$user.DistinguishedName))
        $before = Get-OfSnapshot $user $groups
        $refusal = Get-OfRefusal $before
        $line.Before = $before
        if ($before.groups.Count -gt $script:OfMaxGroups) {
            $before.groupsTruncated = $before.groups.Count
            $before.groups = @($before.groups | Select-Object -First $script:OfMaxGroups)
        }
        if (-not $Apply) {
            $line.Status = 'reported'
            $line.WouldRefuse = $refusal
            return $line
        }
        if ($refusal) { $line.Status = 'refused'; $line.Reason = $refusal; return $line }

        $now = & $script:OfNow
        # The backup holds the full group list; the printed line may be cut.
        $line.Backup = Write-OfBackup (Get-OfSnapshot $user $groups) $now
        $guid = $before.guid
        & $script:OfDisable $guid
        & $script:OfSetDescription $guid $Text
        $moved = $null
        if ($Ou -ne '') {
            if (& $script:OfOuExists $Ou) { & $script:OfMove $guid $Ou; $moved = $true } else { $moved = $false }
        }
        $after = & $script:OfGet $guid
        $line.After = [ordered]@{ enabled = [bool]$after.Enabled; description = [string]$after.Description; dn = [string]$after.DistinguishedName }
        $line.Moved = if ($null -eq $moved) { 'not requested' } elseif ($moved) { 'yes' } else { 'skipped, OU not found' }
        $problems = @()
        if ($after.Enabled) { $problems += 'still enabled' }
        if ([string]$after.Description -cne $Text) { $problems += 'description mismatch' }
        if ($moved -and -not ([string]$after.DistinguishedName).EndsWith(",$Ou", [StringComparison]::OrdinalIgnoreCase)) { $problems += 'not in the target OU' }
        if ($problems.Count -gt 0) { $line.Status = 'mismatch'; $line.Reason = "read-back: $($problems -join ', ')"; return $line }
        $line.Status = 'disabled'
    } catch {
        $line.Status = 'error'
        $line.Reason = $_.Exception.Message
    }
    return $line
}

# Returns @{ ExitCode; Lines } where each line is an ordered hashtable.
function Invoke-OfMain {
    param([string]$Action = '', [string]$Mode = '', [string]$Users = '', [string]$Description = '', [string]$TargetOu = '', [string]$PinVersion = 'pinned')
    $head = [ordered]@{ Package = 'ad-user-offboard'; Status = 'error' }
    if ([string]::IsNullOrWhiteSpace($PinVersion)) { $head.Status = 'disabled'; return @{ ExitCode = 0; Lines = @($head) } }
    $fail = { param($reason) $head.Reason = $reason; return @{ ExitCode = 1; Lines = @($head) } }

    $effective = if ($Mode -ne '') { $Mode } elseif ($Action -in @('Report', 'Disable')) { $Action } else { 'Report' }
    if ($effective -notin @('Report', 'Disable')) { return & $fail 'Mode must be Report or Disable' }
    $apply = $effective -eq 'Disable'
    $sams = @($Users.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    if ($sams.Count -eq 0 -or $sams.Count -gt $script:OfMaxUsers) { return & $fail "Users needs 1 to $($script:OfMaxUsers) comma-separated sAMAccountNames" }
    foreach ($s in $sams) { if ($s -cnotmatch $script:OfSamPattern) { return & $fail "a user name is not a valid sAMAccountName (A-Z a-z 0-9 . _ ' -, at most 20)" } }
    if (@($sams | Select-Object -Unique).Count -ne $sams.Count) { return & $fail 'Users lists the same account twice' }
    if (($Description -ne '' -or $TargetOu -ne '') -and -not $apply) { return & $fail 'Description and TargetOu apply to Disable only' }
    if ($Description -eq '') { $Description = 'Disabled by Relian ' + (& $script:OfNow).ToString('yyyy-MM-dd') }
    if (-not (Test-OfDescription $Description)) { return & $fail 'Description must be 1 to 1024 characters with no control characters' }
    if ($TargetOu -ne '' -and $TargetOu -cnotmatch $script:OfOuPattern) { return & $fail 'TargetOu must be an OU distinguished name such as OU=Disabled Users,DC=example,DC=com' }
    if (-not [bool](& $script:OfIsDc)) { return & $fail 'not a domain controller; run this package on a DC' }
    & $script:OfImport

    $lines = @(foreach ($s in $sams) { Invoke-OfAccount $s $apply $Description $TargetOu })
    $bad = @($lines | Where-Object { $_.Status -notin @('reported', 'disabled') })
    return @{ ExitCode = $(if ($bad.Count -gt 0) { 1 } else { 0 }); Lines = $lines }
}

if ($env:RELIAN_DEPLOY_TEST -eq '1' -and $MyInvocation.InvocationName -eq '.') {
    return
}

try {
    $run = Invoke-OfMain -Action $Action -Mode $Mode -Users $Users -Description $Description -TargetOu $TargetOu -PinVersion $PinVersion
} catch {
    $run = @{ ExitCode = 1; Lines = @([ordered]@{ Package = 'ad-user-offboard'; Status = 'error'; Reason = $_.Exception.Message }) }
}
foreach ($l in $run.Lines) { Write-Output (ConvertTo-Json -InputObject $l -Depth 5 -Compress) }
exit $run.ExitCode
