<#
.SYNOPSIS
    Re-points one Active Directory user's identity attributes (names, UPN, mail, proxyAddresses, sAMAccountName) and
    moves it between OUs, so the user can be hard-matched to an existing cloud-only Entra user by Entra Cloud Sync.
    Plan by default. Never changes the password, group memberships or enabled state, and never deletes anything.

.DESCRIPTION
    Run it on a domain controller, as SYSTEM, through the deploy runner (Windows PowerShell 5.1). The runner decodes
    the base64 JSON in -PackageArguments and passes each key as a named parameter. All values are strings; the runner
    accepts @ : and ; in a value, so nothing needs hex encoding. The runner's own -Action is ignored.
      Identity           required. The user's sAMAccountName, [A-Za-z0-9._-], at most 20.
      Mode               Plan (default), Apply or Rollback.
      GivenName, Surname, DisplayName
                         optional. Letters, spaces and . ' -, at most 64, no leading or trailing space.
      UserPrincipalName, Mail
                         optional. An e-mail address.
      ProxyAddresses     optional. SMTP:addr;smtp:addr2;... with exactly one primary SMTP:. It replaces the SMTP and
                         smtp entries; other entries already on the user (X500:, SIP: ...) are kept.
      TargetOu           optional. The DN of an existing OU or container, such as OU=Unsynced,DC=example,DC=com.
      NewSamAccountName  optional. Same rule as Identity.
      Backup             Rollback only, optional. A backup file name (<sam>-yyyyMMdd-HHmmss.json); default the newest
                         backup of this user (matched by objectGUID, so a renamed user still finds it).

    Plan: prints the current values, the changes, the move, every other AD object (user, contact, group, any class)
    whose userPrincipalName, mail or SMTP proxyAddresses equal a planned address, or whose sAMAccountName equals the
    planned one (case-insensitive), and the objectGUID with its base64. ImmutableId is the base64 of
    mS-DS-ConsistencyGuid when that is set (Cloud Sync anchors on it), else of objectGUID: set the cloud user's
    onPremisesImmutableId to it before the user comes into sync scope. Plan writes nothing and exits 0.
    Apply: refuses on any conflict or a missing OU. When something differs, it writes a JSON backup of the identity
    attributes and the OU to %ProgramData%\Relian\ad-user-identity\<sam>-<yyyyMMdd-HHmmss>.json (the folder is locked
    to SYSTEM and Administrators), then sets only the given attributes, moves the user, and reads it back. A second
    run with the same values changes nothing.
    Rollback: backs up the current state the same way, then restores every identity attribute (clearing one that was
    empty) and the OU from the backup, with the same conflict check.

    Prints one JSON line. Exit 0 on success, plan or no change; 1 on invalid input, a missing user, a refusal or a
    read-back mismatch. An empty -PinVersion exits 0 and changes nothing.
    Conflicts are searched in this domain only, not the whole forest or Entra.
#>
[CmdletBinding()]
param(
    [string]$DeploymentType = '',
    [string]$Action = '',
    [string]$PinVersion = '',
    [string]$Mode = '',
    [string]$Identity = '',
    [string]$GivenName = '',
    [string]$Surname = '',
    [string]$DisplayName = '',
    [string]$UserPrincipalName = '',
    [string]$Mail = '',
    [string]$ProxyAddresses = '',
    [string]$TargetOu = '',
    [string]$NewSamAccountName = '',
    [string]$Backup = ''
)

$ErrorActionPreference = 'Stop'
$script:UiSamPattern = '\A[A-Za-z0-9._-]{1,20}\z'
$script:UiNamePattern = "\A(?=.*\p{L})(?! )[\p{L} .'-]{1,64}(?<! )\z"
$script:UiMailPattern = "\A(?=[^@]{1,64}@)(?=.{6,254}\z)[A-Za-z0-9_%+'-]+(?:\.[A-Za-z0-9_%+'-]+)*@(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}\z"
$script:UiOuPattern = "\A(?:OU|CN)=[A-Za-z0-9 ._'-]{1,64}(?:,(?:OU|CN)=[A-Za-z0-9 ._'-]{1,64}){0,15}(?:,DC=[A-Za-z0-9-]{1,63}){1,10}\z"
$script:UiBackupPattern = '\A[A-Za-z0-9._-]{1,20}-\d{8}-\d{6}\.json\z'
$script:UiMaxProxies = 32
# The only attributes this package writes.
$script:UiAttributes = @('givenName', 'sn', 'displayName', 'userPrincipalName', 'mail', 'proxyAddresses', 'sAMAccountName')
$script:UiBackupRoot = [System.IO.Path]::Combine([string]$env:ProgramData, 'Relian', 'ad-user-identity')

# Seams. Tests replace these; the defaults touch AD and the file system.
$script:UiIsDc = { [int](Get-CimInstance -ClassName Win32_ComputerSystem).DomainRole -ge 4 }
$script:UiImport = { Import-Module ActiveDirectory -ErrorAction Stop }
$script:UiProps = @('givenName', 'sn', 'displayName', 'userPrincipalName', 'mail', 'proxyAddresses', 'mS-DS-ConsistencyGuid')
$script:UiFind = { param($sam) @(Get-ADUser -LDAPFilter "(sAMAccountName=$sam)" -Properties $script:UiProps) }
$script:UiGet = { param($guid) Get-ADUser -Identity $guid -Properties $script:UiProps }
$script:UiSearch = { param($filter) @(Get-ADObject -LDAPFilter $filter -Properties sAMAccountName, userPrincipalName, mail, proxyAddresses) }
# A missing object throws ADIdentityNotFoundException; any other error propagates.
$script:UiOuExists = {
    param($dn)
    try { [bool](Get-ADObject -Identity $dn) }
    catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] { $false }
}
$script:UiSet = {
    param($guid, $replace, $clear)
    if ($replace.Count -gt 0) { Set-ADUser -Identity $guid -Replace $replace }
    if (@($clear).Count -gt 0) { Set-ADUser -Identity $guid -Clear $clear }
}
$script:UiMove = { param($guid, $ou) Move-ADObject -Identity $guid -TargetPath $ou }
$script:UiNow = { [DateTime]::Now }
$script:UiHost = { $env:COMPUTERNAME }
$script:UiLockFolder = {
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

# RFC 4515 escaping for a value inside an LDAP filter.
function Get-UiFilterValue([string]$Value) {
    return $Value.Replace('\', '\5c').Replace('*', '\2a').Replace('(', '\28').Replace(')', '\29').Replace([string][char]0, '\00')
}

# Strings sorted ordinally and joined: equal keys mean equal values (multi-valued attributes have no order).
function Get-UiKey($Value) {
    $a = [string[]]@($Value | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
    [Array]::Sort($a, [StringComparer]::Ordinal)
    return ($a -join [string][char]10)
}

function Get-UiParent([string]$Dn) {
    if ($Dn -match '\A(?:[^,\\]|\\.)*,(.+)\z') { return $Matches[1] }
    return ''
}

function Get-UiState($User) {
    $state = [ordered]@{}
    foreach ($a in $script:UiAttributes) {
        if ($a -eq 'proxyAddresses') { $state[$a] = [string[]]@($User.proxyAddresses | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ }) }
        else { $state[$a] = [string]$User.$a }
    }
    return $state
}

# The SMTP addresses in a proxyAddresses list, without the prefix.
function Get-UiSmtp($List) {
    return @($List | Where-Object { [string]$_ -match '\Asmtp:' } | ForEach-Object { ([string]$_).Substring(5) })
}

# $null when valid, else the reason. The parsed items go into $Out.
function Test-UiProxyList([string]$Text, [System.Collections.Generic.List[string]]$Out) {
    $items = @($Text.Split(';') | ForEach-Object { $_.Trim() })
    if ($items.Count -gt $script:UiMaxProxies) { return "ProxyAddresses holds at most $($script:UiMaxProxies) addresses" }
    $seen = @{}
    $primary = 0
    foreach ($i in $items) {
        $prefix, $address = $i -split ':', 2
        if ($prefix -cnotin @('SMTP', 'smtp') -or [string]$address -cnotmatch $script:UiMailPattern) { return 'each ProxyAddresses item must be SMTP:<address> or smtp:<address>, separated by ;' }
        if ($prefix -ceq 'SMTP') { $primary++ }
        $key = $address.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { return 'ProxyAddresses lists the same address twice' }
        $seen[$key] = $true
        $Out.Add($i)
    }
    if ($primary -ne 1) { return 'ProxyAddresses needs exactly one primary SMTP: address' }
    return $null
}

# attribute -> @{ from; to } for every planned value that differs from the current one.
function Get-UiChanges($Current, $Planned) {
    $changes = [ordered]@{}
    foreach ($a in $Planned.Keys) {
        if ((Get-UiKey $Current[$a]) -cne (Get-UiKey $Planned[$a])) { $changes[$a] = [ordered]@{ from = $Current[$a]; to = $Planned[$a] } }
    }
    return $changes
}

# Every other object holding a planned address or the planned sAMAccountName.
function Get-UiConflicts([string]$Guid, $Planned) {
    $addresses = @(@($Planned['userPrincipalName'], $Planned['mail']) + @(Get-UiSmtp $Planned['proxyAddresses']) |
        Where-Object { $_ } | ForEach-Object { ([string]$_).ToLowerInvariant() } | Select-Object -Unique)
    $sam = [string]$Planned['sAMAccountName']
    $terms = @(foreach ($a in $addresses) { $v = Get-UiFilterValue $a; "(userPrincipalName=$v)(mail=$v)(proxyAddresses=smtp:$v)" })
    if ($sam) { $terms += "(sAMAccountName=$(Get-UiFilterValue $sam))" }
    if ($terms.Count -eq 0) { return , @() }
    $found = @(& $script:UiSearch ('(|' + ($terms -join '') + ')'))
    $conflicts = [System.Collections.Generic.List[object]]::new()
    foreach ($o in $found) {
        if (([Guid]$o.ObjectGUID).ToString() -eq $Guid) { continue }
        $hits = @()
        foreach ($attr in @('userPrincipalName', 'mail')) { if ($addresses -contains ([string]$o.$attr).ToLowerInvariant()) { $hits += , @($attr, [string]$o.$attr) } }
        foreach ($p in @($o.proxyAddresses)) { if ([string]$p -match '\Asmtp:(.+)\z' -and $addresses -contains $Matches[1].ToLowerInvariant()) { $hits += , @('proxyAddresses', [string]$p) } }
        if ($sam -and [string]$o.sAMAccountName -and ([string]$o.sAMAccountName).Equals($sam, [StringComparison]::OrdinalIgnoreCase)) { $hits += , @('sAMAccountName', [string]$o.sAMAccountName) }
        foreach ($h in $hits) {
            $conflicts.Add([ordered]@{ attribute = $h[0]; value = $h[1]; class = [string]$o.ObjectClass; sAMAccountName = [string]$o.sAMAccountName; dn = [string]$o.DistinguishedName; guid = ([Guid]$o.ObjectGUID).ToString() })
        }
    }
    return , $conflicts.ToArray()
}

function Write-UiBackup([string]$Guid, [string]$Dn, $State, [DateTime]$Now) {
    $root = $script:UiBackupRoot
    if (-not (Test-Path -LiteralPath $root)) { $null = New-Item -ItemType Directory -Path $root -Force }
    & $script:UiLockFolder $root
    $stamp = $Now.ToString('yyyyMMdd-HHmmss')
    $file = Join-Path $root ('{0}-{1}.json' -f $State['sAMAccountName'], $stamp)
    $doc = [ordered]@{ takenAt = $Now.ToString('o'); stamp = $stamp; host = [string](& $script:UiHost); guid = $Guid; dn = $Dn; parent = (Get-UiParent $Dn); attributes = $State }
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes((ConvertTo-Json -InputObject $doc -Depth 5))
    # CreateNew: an existing backup is never overwritten.
    $stream = [System.IO.File]::Open($file, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write)
    try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
    if ((ConvertFrom-Json ([System.IO.File]::ReadAllText($file))).guid -ne $Guid) { throw 'backup read-back did not match' }
    return $file
}

# The backup to restore for this user: the named one, or the newest whose objectGUID matches.
function Get-UiRestore([string]$Guid, [string]$Name) {
    $root = $script:UiBackupRoot
    if ($Name) {
        $path = Join-Path $root $Name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "backup $Name not found under $root" }
        $doc = ConvertFrom-Json ([System.IO.File]::ReadAllText($path))
        if ([string]$doc.guid -ne $Guid) { throw "backup $Name belongs to another object" }
        return @{ Path = $path; Doc = $doc }
    }
    $best = $null
    if (Test-Path -LiteralPath $root) {
        foreach ($f in @(Get-ChildItem -LiteralPath $root -Filter '*.json' -File | Where-Object { $_.Name -cmatch $script:UiBackupPattern })) {
            try { $doc = ConvertFrom-Json ([System.IO.File]::ReadAllText($f.FullName)) } catch { continue }
            if ([string]$doc.guid -ne $Guid) { continue }
            if ($null -eq $best -or [string]::CompareOrdinal([string]$doc.stamp, [string]$best.Doc.stamp) -gt 0) { $best = @{ Path = $f.FullName; Doc = $doc } }
        }
    }
    if ($null -eq $best) { throw "no backup for this user under $root" }
    return $best
}

# Returns @{ ExitCode; Line }.
function Invoke-UiMain {
    param([string]$Mode = '', [string]$Identity = '', [string]$GivenName = '', [string]$Surname = '', [string]$DisplayName = '',
        [string]$UserPrincipalName = '', [string]$Mail = '', [string]$ProxyAddresses = '', [string]$TargetOu = '',
        [string]$NewSamAccountName = '', [string]$Backup = '', [string]$PinVersion = 'pinned')
    if ($Mode -eq '') { $Mode = 'Plan' }
    $line = [ordered]@{ Package = 'ad-user-identity'; Mode = $Mode; Identity = $Identity; Status = 'error' }
    if ([string]::IsNullOrWhiteSpace($PinVersion)) { $line.Status = 'disabled'; return @{ ExitCode = 0; Line = $line } }
    $fail = { param($reason) $line.Reason = $reason; return @{ ExitCode = 1; Line = $line } }

    if ($Mode -cnotin @('Plan', 'Apply', 'Rollback')) { return & $fail 'Mode must be Plan, Apply or Rollback' }
    if ($Identity -cnotmatch $script:UiSamPattern) { return & $fail 'Identity must be a sAMAccountName (A-Z a-z 0-9 . _ -, at most 20)' }
    if ($NewSamAccountName -ne '' -and $NewSamAccountName -cnotmatch $script:UiSamPattern) { return & $fail 'NewSamAccountName must be a sAMAccountName (A-Z a-z 0-9 . _ -, at most 20)' }
    foreach ($n in @(@('GivenName', $GivenName), @('Surname', $Surname), @('DisplayName', $DisplayName))) {
        if ($n[1] -ne '' -and $n[1] -cnotmatch $script:UiNamePattern) { return & $fail "$($n[0]) must be letters, spaces and . ' -, at most 64" }
    }
    foreach ($n in @(@('UserPrincipalName', $UserPrincipalName), @('Mail', $Mail))) {
        if ($n[1] -ne '' -and $n[1] -cnotmatch $script:UiMailPattern) { return & $fail "$($n[0]) must be an e-mail address" }
    }
    $proxyList = [System.Collections.Generic.List[string]]::new()
    if ($ProxyAddresses -ne '') { $why = Test-UiProxyList $ProxyAddresses $proxyList; if ($why) { return & $fail $why } }
    if ($TargetOu -ne '' -and $TargetOu -notmatch $script:UiOuPattern) { return & $fail 'TargetOu must be a DN such as OU=Unsynced,DC=example,DC=com' }
    $given = [ordered]@{ givenName = $GivenName; sn = $Surname; displayName = $DisplayName; userPrincipalName = $UserPrincipalName; mail = $Mail; sAMAccountName = $NewSamAccountName }
    $anyChange = @($given.Values | Where-Object { $_ -ne '' }).Count -gt 0 -or $ProxyAddresses -ne '' -or $TargetOu -ne ''
    if ($Mode -eq 'Rollback' -and $anyChange) { return & $fail 'Rollback takes only Identity and Backup' }
    if ($Backup -ne '' -and $Mode -ne 'Rollback') { return & $fail 'Backup applies to Rollback only' }
    if ($Backup -ne '' -and $Backup -cnotmatch $script:UiBackupPattern) { return & $fail 'Backup must be a file name such as jdoe-20261119-103000.json' }
    if (-not [bool](& $script:UiIsDc)) { return & $fail 'not a domain controller; run this package on a DC' }
    & $script:UiImport

    try {
        $found = @(& $script:UiFind $Identity)
        if ($found.Count -eq 0) { $line.Status = 'notfound'; return & $fail "no AD user with sAMAccountName $Identity" }
        if ($found.Count -gt 1) { $line.Status = 'refused'; return & $fail "$Identity matches $($found.Count) AD objects" }
        $user = $found[0]
        $guid = ([Guid]$user.ObjectGUID).ToString()
        $dn = [string]$user.DistinguishedName
        $current = Get-UiState $user
        $parent = Get-UiParent $dn
        $line.ObjectGuid = $guid
        $line.ObjectGuidBase64 = [Convert]::ToBase64String(([Guid]$user.ObjectGUID).ToByteArray())
        $consistency = $user.'mS-DS-ConsistencyGuid'
        $line.ConsistencyGuidBase64 = if ($consistency) { [Convert]::ToBase64String([byte[]]$consistency) } else { '' }
        $line.ImmutableId = if ($consistency) { $line.ConsistencyGuidBase64 } else { $line.ObjectGuidBase64 }
        $line.Current = [ordered]@{}
        foreach ($k in $current.Keys) { $line.Current[$k] = $current[$k] }
        $line.Current.ou = $parent

        $planned = [ordered]@{}
        if ($Mode -eq 'Rollback') {
            $restore = Get-UiRestore $guid $Backup
            $line.RestoredFrom = $restore.Path
            foreach ($a in $script:UiAttributes) {
                $v = $restore.Doc.attributes.$a
                $planned[$a] = if ($a -eq 'proxyAddresses') { [string[]]@($v | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ }) } else { [string]$v }
            }
            $target = [string]$restore.Doc.parent
        } else {
            foreach ($k in $given.Keys) { if ($given[$k] -ne '') { $planned[$k] = $given[$k] } }
            if ($ProxyAddresses -ne '') {
                # Only the SMTP entries are replaced; X500, SIP and other entries stay.
                $planned['proxyAddresses'] = [string[]](@($current['proxyAddresses'] | Where-Object { $_ -notmatch '\Asmtp:' }) + @($proxyList))
            }
            $target = $TargetOu
        }
        $changes = Get-UiChanges $current $planned
        $move = $target -ne '' -and -not $parent.Equals($target, [StringComparison]::OrdinalIgnoreCase)
        $problems = @()
        if ($move -and -not [bool](& $script:UiOuExists $target)) { $problems += "target $target does not exist" }
        $conflicts = Get-UiConflicts $guid $planned
        $line.Changes = $changes
        $line.Move = if ($move) { [ordered]@{ from = $parent; to = $target } } else { $null }
        $line.Conflicts = $conflicts
        $line.Problems = $problems

        if ($Mode -eq 'Plan') { $line.Status = 'planned'; return @{ ExitCode = 0; Line = $line } }
        if ($conflicts.Count -gt 0 -or $problems.Count -gt 0) {
            $line.Status = 'refused'
            return & $fail "$($conflicts.Count) conflict(s), $($problems.Count) problem(s); nothing changed"
        }
        if ($changes.Count -eq 0 -and -not $move) { $line.Status = 'unchanged'; return @{ ExitCode = 0; Line = $line } }

        $line.Backup = Write-UiBackup $guid $dn $current (& $script:UiNow)
        if ($changes.Count -gt 0) {
            $replace = @{}
            $clear = @()
            foreach ($a in $changes.Keys) {
                $to = $changes[$a].to
                if ((Get-UiKey $to) -eq '') { $clear += $a }
                elseif ($a -eq 'proxyAddresses') { $replace[$a] = [string[]]$to }
                else { $replace[$a] = [string]$to }
            }
            & $script:UiSet $guid $replace $clear
        }
        if ($move) { & $script:UiMove $guid $target }

        $after = & $script:UiGet $guid
        $left = Get-UiChanges (Get-UiState $after) $planned
        $problems = @($left.Keys | ForEach-Object { "$_ differs" })
        $afterOu = Get-UiParent ([string]$after.DistinguishedName)
        if ($target -ne '' -and -not $afterOu.Equals($target, [StringComparison]::OrdinalIgnoreCase)) { $problems += 'not in the target OU' }
        $line.After = Get-UiState $after
        $line.After.ou = $afterOu
        if ($problems.Count -gt 0) {
            $line.Status = 'mismatch'
            return & $fail "read-back: $($problems -join ', '); restore with Mode Rollback"
        }
        $line.Status = if ($Mode -eq 'Rollback') { 'rolledback' } else { 'applied' }
        return @{ ExitCode = 0; Line = $line }
    } catch {
        if ($line.Status -notin @('notfound', 'refused')) { $line.Status = 'error' }
        return & $fail $_.Exception.Message
    }
}

if ($env:RELIAN_DEPLOY_TEST -eq '1' -and $MyInvocation.InvocationName -eq '.') {
    return
}

$mainArgs = @{
    Mode = $Mode; Identity = $Identity; GivenName = $GivenName; Surname = $Surname; DisplayName = $DisplayName
    UserPrincipalName = $UserPrincipalName; Mail = $Mail; ProxyAddresses = $ProxyAddresses; TargetOu = $TargetOu
    NewSamAccountName = $NewSamAccountName; Backup = $Backup; PinVersion = $PinVersion
}
try {
    $run = Invoke-UiMain @mainArgs
} catch {
    $run = @{ ExitCode = 1; Line = [ordered]@{ Package = 'ad-user-identity'; Status = 'error'; Reason = $_.Exception.Message } }
}
Write-Output (ConvertTo-Json -InputObject $run.Line -Depth 6 -Compress)
exit $run.ExitCode
