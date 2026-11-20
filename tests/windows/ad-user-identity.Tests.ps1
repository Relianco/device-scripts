$ErrorActionPreference = 'Stop'
$env:RELIAN_DEPLOY_TEST = '1'
$packagePath = Join-Path $PSScriptRoot '../../windows/packages/ad-user-identity/Invoke-AdUserIdentity.ps1'
. $packagePath

function Assert($ok, $message) { if (-not $ok) { throw $message } }

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('ui-' + [Guid]::NewGuid().ToString('N'))
$userGuid = [Guid]'00112233-4455-6677-8899-aabbccddeeff'

function New-Obj([string]$Sam, [string]$Class = 'user', [string]$Upn = '', [string]$Mail = '', [string[]]$Proxy = @(), [Guid]$Guid = [Guid]::NewGuid(), [string]$Ou = 'OU=Staff,DC=example,DC=com') {
    [pscustomobject]@{
        ObjectGUID = $Guid; sAMAccountName = $Sam; ObjectClass = $Class; givenName = 'Old'; sn = 'Name'; displayName = 'Old Name'
        userPrincipalName = $Upn; mail = $Mail; proxyAddresses = $Proxy; DistinguishedName = "CN=$Sam,$Ou"; 'mS-DS-ConsistencyGuid' = $null
    }
}

# A fake directory. Every write and lock is recorded in Log, in order.
function New-Fake([object[]]$Objects, [string[]]$Ous = @('OU=Staff,DC=example,DC=com', 'OU=Unsynced,DC=example,DC=com'), [bool]$IsDc = $true) {
    $script:Fake = [pscustomobject]@{ Objects = @($Objects); Ous = $Ous; Log = [System.Collections.Generic.List[string]]::new(); Filters = [System.Collections.Generic.List[string]]::new() }
    $script:UiBackupRoot = $tmp
    $script:UiIsDc = if ($IsDc) { { $true } } else { { $false } }
    $script:UiImport = { }
    $script:UiNow = { [DateTime]'2026-11-19T10:30:00' }
    $script:UiHost = { 'DC1' }
    $script:UiLockFolder = { param($p) $script:Fake.Log.Add('lock') }
    $script:UiTrusted = { param($p) -not $p.EndsWith('-20261119-090000.json') }
    $script:UiFind = { param($sam) @($script:Fake.Objects | Where-Object { $_.ObjectClass -eq 'user' -and $_.sAMAccountName -eq $sam }) }
    $script:UiGet = { param($g) @($script:Fake.Objects | Where-Object { $_.ObjectGUID -eq [Guid]$g })[0] }
    $script:UiSearch = { param($filter) $script:Fake.Filters.Add($filter); @($script:Fake.Objects) }
    $script:UiOuExists = { param($dn) $script:Fake.Ous -contains $dn }
    $script:UiSet = {
        param($g, $replace, $clear)
        $script:Fake.Log.Add('set:' + (((@($replace.Keys) + @($clear | ForEach-Object { "-$_" })) | Sort-Object) -join ','))
        $o = & $script:UiGet $g
        foreach ($k in $replace.Keys) { $o.$k = $replace[$k] }
        foreach ($k in $clear) { $o.$k = $null }
    }
    $script:UiMove = { param($g, $ou) $script:Fake.Log.Add('move'); $o = & $script:UiGet $g; $o.DistinguishedName = ($o.DistinguishedName -replace ',.*\z', '') + ",$ou" }
}
function Run([hashtable]$A) { $p = @{ Identity = 'jdoe' }; foreach ($k in $A.Keys) { $p[$k] = $A[$k] }; Invoke-UiMain @p }
function Writes { @($script:Fake.Log | Where-Object { $_ -ne 'lock' }).Count }
function Backups { if (Test-Path -LiteralPath $tmp) { @(Get-ChildItem -LiteralPath $tmp -Filter '*.json') } else { @() } }

function New-Std {
    $u = New-Obj 'jdoe' -Upn 'jdoe@corp.local' -Proxy @('SMTP:jdoe@old.example', 'X500:/o=Org/cn=jdoe') -Guid $userGuid
    $contact = New-Obj 'c1' -Class 'contact' -Proxy @('SMTP:Accounts@Example.com')
    $other = New-Obj 'asmith' -Upn 'asmith@example.com'
    New-Fake @($u, $contact, $other)
}

try {
    # Validation: a rejected value looks nothing up.
    New-Std
    $bad = @(
        @{ Identity = '' }, @{ Identity = 'a b' }, @{ Identity = 'a*' }, @{ Identity = ('x' * 21) }, @{ Identity = 'a@b' },
        @{ Mode = 'Frob' }, @{ Mode = 'Install' },
        @{ GivenName = 'A1' }, @{ GivenName = 'a;b' }, @{ Surname = ('a' * 65) }, @{ DisplayName = ' Lead' }, @{ DisplayName = '...' },
        @{ UserPrincipalName = 'nope' }, @{ UserPrincipalName = 'a@b' }, @{ Mail = 'a b@example.com' }, @{ Mail = '.a@example.com' },
        @{ ProxyAddresses = 'smtp:a@example.com' }, @{ ProxyAddresses = 'SMTP:a@example.com;SMTP:b@example.com' },
        @{ ProxyAddresses = 'SMTP:a@example.com;X500:/o=x' }, @{ ProxyAddresses = 'SMTP:a@example.com;smtp:A@example.com' },
        @{ ProxyAddresses = 'Smtp:a@example.com' }, @{ ProxyAddresses = 'SMTP:a@example.com;;' },
        @{ TargetOu = 'not a dn' }, @{ TargetOu = 'OU=x' }, @{ TargetOu = 'OU=a\,b,DC=example,DC=com' }, @{ TargetOu = 'OU=a,DC=example,DC=com)(x=*' },
        @{ NewSamAccountName = 'a b' },
        @{ Mode = 'Apply'; Backup = 'jdoe-20261119-103000.json' }, @{ Mode = 'Rollback'; Mail = 'a@example.com' },
        @{ Mode = 'Rollback'; Backup = '..\x.json' }, @{ Mode = 'Rollback'; Backup = 'jdoe.json' }
    )
    foreach ($b in $bad) {
        $r = Run $b
        Assert ($r.ExitCode -eq 1 -and $r.Line.Status -eq 'error') "Refused: $(ConvertTo-Json $b -Compress)"
    }
    Assert ($script:Fake.Log.Count -eq 0 -and $script:Fake.Filters.Count -eq 0) 'Rejected input touches nothing'
    New-Std; $script:UiIsDc = { $false }
    Assert ((Run @{ Mode = 'Apply'; Mail = 'a@example.com' }).ExitCode -eq 1) 'Not a DC refused'
    New-Std
    Assert ((Run @{ PinVersion = ''; Mode = 'Apply'; Mail = 'x@example.com' }).ExitCode -eq 0 -and $script:Fake.Log.Count -eq 0) 'Empty pin is off'
    Assert ((Run @{ Identity = 'ghost' }).Line.Status -eq 'notfound') 'Missing user reported'
    Assert ((Run @{ Identity = 'ghost' }).ExitCode -eq 1) 'Missing user exits 1'

    # Plan: current, planned, conflicts, GUID; zero writes, no backup.
    New-Std
    $r = Run @{ GivenName = "Anne-Marie"; Surname = "O'Brien"; DisplayName = 'Anne-Marie O. Brien'; UserPrincipalName = 'accounts@example.com'; Mail = 'accounts@example.com'; ProxyAddresses = 'SMTP:accounts@example.com; smtp:asmith@example.com'; TargetOu = 'OU=Unsynced,DC=example,DC=com'; NewSamAccountName = 'asmith' }
    Assert ($r.ExitCode -eq 0 -and $r.Line.Status -eq 'planned') 'Plan exits 0'
    Assert ((Writes) -eq 0 -and $script:Fake.Log.Count -eq 0 -and (Backups).Count -eq 0) 'Plan makes zero writes and no backup'
    Assert ($r.Line.Current.userPrincipalName -eq 'jdoe@corp.local' -and $r.Line.Current.ou -eq 'OU=Staff,DC=example,DC=com') 'Plan prints current values'
    Assert ($r.Line.Changes.userPrincipalName.to -eq 'accounts@example.com' -and $r.Line.Changes.givenName.from -eq 'Old') 'Plan prints planned values'
    $proxy = @($r.Line.Changes.proxyAddresses.to)
    Assert ($proxy -contains 'X500:/o=Org/cn=jdoe' -and $proxy -contains 'SMTP:accounts@example.com' -and $proxy -notcontains 'SMTP:jdoe@old.example') 'Non-SMTP proxies are kept, SMTP ones replaced'
    Assert ($r.Line.Move.to -eq 'OU=Unsynced,DC=example,DC=com') 'Plan prints the move'
    $c = @($r.Line.Conflicts)
    Assert (@($c | Where-Object { $_.sAMAccountName -eq 'c1' -and $_.attribute -eq 'proxyAddresses' }).Count -ge 1) 'Contact proxy conflict, case-insensitive'
    Assert (@($c | Where-Object { $_.sAMAccountName -eq 'asmith' -and $_.attribute -eq 'userPrincipalName' }).Count -eq 1) 'User UPN conflict with a planned proxy'
    Assert (@($c | Where-Object { $_.sAMAccountName -eq 'asmith' -and $_.attribute -eq 'sAMAccountName' }).Count -eq 1) 'NewSamAccountName conflict'
    Assert (@($c | Where-Object { $_.guid -eq $userGuid.ToString() }).Count -eq 0) 'The user itself is not a conflict'
    Assert ($r.Line.ObjectGuid -eq $userGuid.ToString() -and $r.Line.ObjectGuidBase64 -eq 'MyIRAFVEd2aImaq7zN3u/w==' -and $r.Line.ImmutableId -eq 'MyIRAFVEd2aImaq7zN3u/w==') 'objectGUID base64'
    Assert ($script:Fake.Filters[0] -match 'proxyAddresses=smtp:accounts@example.com' -and $script:Fake.Filters[0] -match 'sAMAccountName=asmith') 'Search filter names the addresses'
    $script:Fake.Objects[0].'mS-DS-ConsistencyGuid' = [byte[]](1..16)
    $r = Run @{}
    Assert ($r.Line.ConsistencyGuidBase64 -eq 'AQIDBAUGBwgJCgsMDQ4PEA==' -and $r.Line.ImmutableId -eq 'AQIDBAUGBwgJCgsMDQ4PEA==') 'mS-DS-ConsistencyGuid is the anchor when set'
    Assert ((Run @{ TargetOu = 'OU=Gone,DC=example,DC=com' }).Line.Problems -match 'does not exist') 'Plan flags a missing OU'
    Assert ((Get-UiFilterValue 'a*b(c)\d') -eq 'a\2ab\28c\29\5cd') 'LDAP filter escaping'

    # Apply refuses on conflicts or a missing OU, with no writes.
    New-Std
    $r = Run @{ Mode = 'Apply'; ProxyAddresses = 'SMTP:accounts@example.com' }
    Assert ($r.ExitCode -eq 1 -and $r.Line.Status -eq 'refused' -and $script:Fake.Log.Count -eq 0 -and (Backups).Count -eq 0) 'Conflict blocks apply'
    $r = Run @{ Mode = 'Apply'; Mail = 'new@example.com'; TargetOu = 'OU=Gone,DC=example,DC=com' }
    Assert ($r.ExitCode -eq 1 -and $script:Fake.Log.Count -eq 0) 'Missing OU blocks apply'

    # Apply: backup first, then only the given attributes, then the move; read back.
    New-Std
    $r = Run @{ Mode = 'Apply'; UserPrincipalName = 'jdoe@example.com'; Mail = 'jdoe@example.com'; ProxyAddresses = 'SMTP:jdoe@example.com;smtp:j.doe@example.com'; TargetOu = 'OU=Unsynced,DC=example,DC=com' }
    Assert ($r.ExitCode -eq 0 -and $r.Line.Status -eq 'applied') "Apply succeeds: $($r.Line.Reason)"
    Assert ($script:Fake.Log[0] -eq 'lock' -and $script:Fake.Log[1] -eq 'set:mail,proxyAddresses,userPrincipalName' -and $script:Fake.Log[2] -eq 'move' -and $script:Fake.Log.Count -eq 3) "Lock, set, move in order: $($script:Fake.Log -join ' ')"
    $files = Backups
    Assert ($files.Count -eq 1 -and $files[0].Name -eq 'jdoe-20261119-103000.json' -and $r.Line.Backup -eq $files[0].FullName) 'Backup named sam-timestamp'
    $doc = Get-Content -LiteralPath $files[0].FullName -Raw | ConvertFrom-Json
    Assert ($doc.guid -eq $userGuid.ToString() -and $doc.parent -eq 'OU=Staff,DC=example,DC=com' -and $doc.attributes.userPrincipalName -eq 'jdoe@corp.local' -and $doc.attributes.mail -eq '' -and @($doc.attributes.proxyAddresses).Count -eq 2) 'Backup holds the before-state and the OU'
    $u = $script:Fake.Objects[0]
    Assert ($u.mail -eq 'jdoe@example.com' -and $u.DistinguishedName -eq 'CN=jdoe,OU=Unsynced,DC=example,DC=com' -and $u.givenName -eq 'Old' -and @($u.proxyAddresses) -contains 'X500:/o=Org/cn=jdoe') 'Applied only what was given'

    # Idempotent: a second apply changes nothing and writes no backup.
    $script:Fake.Log.Clear()
    $r = Run @{ Mode = 'Apply'; UserPrincipalName = 'jdoe@example.com'; Mail = 'jdoe@example.com'; ProxyAddresses = 'smtp:j.doe@example.com;SMTP:jdoe@example.com'; TargetOu = 'OU=Unsynced,DC=example,DC=com' }
    Assert ($r.ExitCode -eq 0 -and $r.Line.Status -eq 'unchanged' -and $script:Fake.Log.Count -eq 0 -and (Backups).Count -eq 1) 'Second apply is a no-op'

    # A read-back mismatch exits 1.
    $saved = $script:UiSet
    $script:UiSet = { param($g, $replace, $clear) $script:Fake.Log.Add('set') }
    $script:UiNow = { [DateTime]'2026-11-19T10:31:00' }
    $r = Run @{ Mode = 'Apply'; GivenName = 'New' }
    Assert ($r.ExitCode -eq 1 -and $r.Line.Status -eq 'mismatch' -and $r.Line.Backup) 'Read-back mismatch exits 1 and names the backup'
    $script:UiSet = $saved
    Remove-Item -LiteralPath $r.Line.Backup

    # Rollback: the newest backup for this user restores the attributes (clearing mail) and the OU.
    $script:Fake.Log.Clear()
    $script:UiNow = { [DateTime]'2026-11-19T11:00:00' }
    $r = Run @{ Mode = 'Rollback' }
    Assert ($r.ExitCode -eq 0 -and $r.Line.Status -eq 'rolledback') "Rollback succeeds: $($r.Line.Reason)"
    Assert ($r.Line.RestoredFrom -like '*jdoe-20261119-103000.json') 'Rollback used the newest backup'
    $u = $script:Fake.Objects[0]
    Assert ($u.userPrincipalName -eq 'jdoe@corp.local' -and $null -eq $u.mail -and $u.DistinguishedName -eq 'CN=jdoe,OU=Staff,DC=example,DC=com' -and (@($u.proxyAddresses) -join ';') -eq 'SMTP:jdoe@old.example;X500:/o=Org/cn=jdoe') 'Rollback restored attributes and OU'
    Assert ($script:Fake.Log[0] -eq 'lock' -and $script:Fake.Log[1] -eq 'lock' -and $script:Fake.Log[2] -eq 'set:-mail,proxyAddresses,userPrincipalName') "Rollback backs up, then clears what was empty: $($script:Fake.Log -join ' ')"
    Assert ((Backups).Count -eq 2) 'Rollback writes its own backup first'

    # A repeated Rollback restores the same Apply backup, not the Rollback's own one.
    $script:Fake.Log.Clear()
    $script:UiNow = { [DateTime]'2026-11-19T11:05:00' }
    $r = Run @{ Mode = 'Rollback' }
    Assert ($r.ExitCode -eq 0 -and $r.Line.Status -eq 'unchanged' -and $r.Line.RestoredFrom -like '*jdoe-20261119-103000.json' -and $script:Fake.Log.Count -eq 1) 'Second Rollback is a no-op'

    # Backups that are incomplete, or not owned by SYSTEM or Administrators, are never used.
    $good = Get-Content -LiteralPath (Join-Path $tmp 'jdoe-20261119-103000.json') -Raw | ConvertFrom-Json
    $good.stamp = '20261119-235959'
    $good.attributes.PSObject.Properties.Remove('mail')
    Set-Content -LiteralPath (Join-Path $tmp 'jdoe-20261119-235959.json') -Value (ConvertTo-Json $good -Depth 5)
    $good.stamp = '20261119-090000'
    Set-Content -LiteralPath (Join-Path $tmp 'jdoe-20261119-090000.json') -Value (Get-Content -LiteralPath (Join-Path $tmp 'jdoe-20261119-103000.json') -Raw)
    $r = Run @{ Mode = 'Rollback'; Backup = 'jdoe-20261119-235959.json' }
    Assert ($r.ExitCode -eq 1 -and $r.Line.Reason -match 'has no mail') 'Incomplete backup refused'
    $r = Run @{ Mode = 'Rollback'; Backup = 'jdoe-20261119-090000.json' }
    Assert ($r.ExitCode -eq 1 -and $r.Line.Reason -match 'not owned') 'Untrusted backup refused'
    Assert ((Run @{ Mode = 'Rollback' }).Line.RestoredFrom -like '*jdoe-20261119-103000.json') 'Newest skips bad backups'
    Remove-Item -LiteralPath (Join-Path $tmp 'jdoe-20261119-235959.json'), (Join-Path $tmp 'jdoe-20261119-090000.json')

    # A rename: the backup is found by GUID; a named backup for another object is refused.
    New-Std
    $script:UiNow = { [DateTime]'2026-11-19T12:00:00' }
    $r = Run @{ Mode = 'Apply'; NewSamAccountName = 'jdoe2' }
    Assert ($r.ExitCode -eq 0 -and $script:Fake.Objects[0].sAMAccountName -eq 'jdoe2') 'Rename applied'
    $script:UiNow = { [DateTime]'2026-11-19T12:01:00' }
    $r = Run @{ Identity = 'jdoe2'; Mode = 'Rollback'; Backup = 'jdoe-20261119-120000.json' }
    Assert ($r.ExitCode -eq 0 -and $script:Fake.Objects[0].sAMAccountName -eq 'jdoe') 'Named backup restores the old name'
    $r = Run @{ Identity = 'asmith'; Mode = 'Rollback'; Backup = 'jdoe-20261119-120000.json' }
    Assert ($r.ExitCode -eq 1 -and $r.Line.Reason -match 'another object') 'Backup of another object refused'
    $r = Run @{ Identity = 'asmith'; Mode = 'Rollback' }
    Assert ($r.ExitCode -eq 1 -and $r.Line.Reason -match 'no usable Apply backup') 'No backup for this user'
    $r = Run @{ Mode = 'Rollback'; Backup = 'jdoe-20990101-000000.json' }
    Assert ($r.ExitCode -eq 1) 'Missing named backup refused'

    # Never touches the password, groups, enabled state, and never deletes.
    $src = Get-Content -LiteralPath $packagePath -Raw
    foreach ($verb in @('Set-ADAccountPassword', 'Enable-ADAccount', 'Disable-ADAccount', 'Add-ADGroupMember', 'Remove-ADGroupMember', 'Add-ADPrincipalGroupMembership', 'Remove-ADPrincipalGroupMembership', 'Remove-ADUser', 'Remove-ADObject', 'Rename-ADObject', 'Set-ADAccountControl', 'unicodePwd', 'userAccountControl')) {
        Assert ($src -notmatch [regex]::Escape($verb)) "Package never uses $verb"
    }
    Assert (@($script:UiAttributes | Sort-Object) -join ',' -eq 'displayName,givenName,mail,proxyAddresses,sAMAccountName,sn,userPrincipalName') 'Only identity attributes are managed'

    Write-Output 'ad-user-identity: ok'
} finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
}
