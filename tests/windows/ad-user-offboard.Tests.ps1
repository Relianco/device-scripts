$ErrorActionPreference = 'Stop'
$env:RELIAN_DEPLOY_TEST = '1'
$packagePath = Join-Path $PSScriptRoot '../../windows/packages/ad-user-offboard/Invoke-AdUserOffboard.ps1'
. $packagePath

function Assert($ok, $message) { if (-not $ok) { throw $message } }

$domain = 'S-1-5-21-1-2-3'
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("of-" + [Guid]::NewGuid().ToString('N'))

function New-User([string]$Sam, [int]$Rid, [string[]]$Groups = @('Staff'), [bool]$Enabled = $true, [string]$Upn = '', [int]$Primary = 513) {
    [pscustomobject]@{
        ObjectGUID = [Guid]::NewGuid(); SamAccountName = $Sam; UserPrincipalName = $(if ($Upn) { $Upn } else { "$Sam@example.com" })
        SID = "$domain-$Rid"; DistinguishedName = "CN=$Sam,CN=Users,DC=x"; Enabled = $Enabled; Description = 'old text'
        MemberOf = @($Groups | ForEach-Object { "CN=$_,CN=Users,DC=x" }); lastLogonTimestamp = 133000000000000000; PrimaryGroupID = $Primary
        _groups = $Groups
    }
}
function New-Group([string]$Name, [int]$Rid) { [pscustomobject]@{ Name = $Name; SID = "$domain-$Rid" } }

# A fake directory. Calls are recorded in Log; OUs lists the OUs that exist.
function New-Fake([object[]]$Users, [string[]]$Ous = @(), [bool]$IsDc = $true) {
    $script:Fake = [pscustomobject]@{ Users = @($Users); Ous = $Ous; Log = [System.Collections.Generic.List[string]]::new(); Locks = 0; DisableSticks = $true; DescSticks = $true }
    $script:OfBackupRoot = $tmp
    $script:OfIsDc = { $true }
    if (-not $IsDc) { $script:OfIsDc = { $false } }
    $script:OfImport = { }
    $script:OfNow = { [DateTime]'2026-11-19T10:30:00' }
    $script:OfHost = { 'DC1' }
    $script:OfLockFolder = { param($p) $script:Fake.Locks++; $script:Fake.Log.Add('lock') }
    $script:OfFind = { param($sam) @($script:Fake.Users | Where-Object { $_.SamAccountName -eq $sam }) }
    $script:OfGet = { param($g) @($script:Fake.Users | Where-Object { $_.ObjectGUID -eq $g })[0] }
    $script:OfGroups = {
        param($dn)
        $u = @($script:Fake.Users | Where-Object { $_.DistinguishedName -eq $dn })[0]
        @($u._groups | ForEach-Object {
            switch ($_) { 'Domain Admins' { New-Group $_ 512 } 'Enterprise Admins' { New-Group $_ 519 } 'Schema Admins' { New-Group $_ 518 } 'Administrators' { [pscustomobject]@{ Name = $_; SID = 'S-1-5-32-544' } } default { New-Group $_ 1105 } }
        })
    }
    $script:OfDisable = { param($g) $script:Fake.Log.Add('disable'); if ($script:Fake.DisableSticks) { (& $script:OfGet $g).Enabled = $false } }
    $script:OfSetDescription = { param($g, $t) $script:Fake.Log.Add('describe'); if ($script:Fake.DescSticks) { (& $script:OfGet $g).Description = $t } }
    $script:OfOuExists = { param($dn) $script:Fake.Ous -contains $dn }
    $script:OfMove = { param($g, $ou) $script:Fake.Log.Add('move'); $u = & $script:OfGet $g; $u.DistinguishedName = "CN=$($u.SamAccountName),$ou" }
}
function Run([string]$Mode, [string]$Users, [string]$Desc = '', [string]$Ou = '') { Invoke-OfMain -Mode $Mode -Users $Users -Description $Desc -TargetOu $Ou }

try {
    # Validation: nothing is looked up for a rejected value.
    New-Fake @((New-User 'jdoe' 1200))
    foreach ($bad in @('', 'a*', 'a(b', 'a\b', 'a b', ('x' * 21), 'jdoe,jdoe', 'a$')) {
        $r = Run 'Disable' $bad
        Assert ($r.ExitCode -eq 1 -and $r.Lines.Count -eq 1 -and $r.Lines[0].Status -eq 'error') "Bad Users refused: [$bad]"
    }
    Assert ((Run 'Disable' (((1..21) | ForEach-Object { "u$_" }) -join ',')).ExitCode -eq 1) 'More than 20 users refused'
    Assert ((Run 'Frob' 'jdoe').ExitCode -eq 1) 'Unknown mode refused'
    Assert ((Run 'Report' 'jdoe' 'text').ExitCode -eq 1) 'Description with Report refused'
    Assert ((Run 'Disable' 'jdoe' "a`nb").ExitCode -eq 1) 'Control character in Description refused'
    Assert ((Run 'Disable' 'jdoe' '' 'not a dn').ExitCode -eq 1) 'Bad TargetOu refused'
    Assert ($script:Fake.Log.Count -eq 0) 'Rejected input touches nothing'
    New-Fake @((New-User 'jdoe' 1200)) -IsDc $false
    Assert ((Run 'Disable' 'jdoe').ExitCode -eq 1) 'Not a DC refused'
    New-Fake @((New-User 'jdoe' 1200))
    Assert ((Invoke-OfMain -Users 'jdoe' -PinVersion '').ExitCode -eq 0 -and $script:Fake.Log.Count -eq 0) 'Empty pin is off'
    Assert ((Invoke-OfMain -Action 'Install' -Users 'jdoe').Lines[0].Mode -eq 'Report') 'Runner Install action means Report'
    Assert ((Invoke-OfMain -Action 'Disable' -Users 'ghost').Lines[0].Mode -eq 'Disable') 'Action Disable works'

    # Report changes nothing, even for a privileged account, and flags it.
    New-Fake @((New-User 'jdoe' 1200 @('Staff', 'Domain Admins') ), (New-User 'bob' 1201 @('Staff', 'Administrators')))
    $r = Run 'Report' 'jdoe,bob,ghost'
    Assert ($r.ExitCode -eq 1) 'Report exits 1 for a missing account'
    Assert ($r.Lines[0].Status -eq 'reported' -and $r.Lines[0].WouldRefuse -match 'Domain Admins') 'Report flags a Domain Admin'
    Assert ($r.Lines[0].Before.enabled -eq $true -and $r.Lines[0].Before.description -eq 'old text' -and $r.Lines[0].Before.lastLogonTimestamp) 'Report prints the before-state'
    Assert ($r.Lines[0].Before.groups -contains 'Staff') 'Report lists group names'
    Assert ($r.Lines[1].Before.privilegedGroups -contains 'Administrators' -and $null -eq $r.Lines[1].WouldRefuse) 'Report flags builtin Administrators as privileged but Disable would allow it'
    Assert ($r.Lines[2].Status -eq 'notfound') 'Report names a missing account'
    Assert ($script:Fake.Log.Count -eq 0 -and -not (Test-Path -LiteralPath $tmp)) 'Report changes nothing and writes no backup'
    Assert ((Run 'Report' 'jdoe').Lines[0].Package -eq 'ad-user-offboard' -and (Run 'Report' 'bob').ExitCode -eq 0) 'Report of an existing account exits 0'

    # Refusals: nothing is changed and no backup is written.
    New-Fake @(
        (New-User 'ea' 1300 @('Enterprise Admins')), (New-User 'sa' 1301 @('Schema Admins')), (New-User 'pa' 1302 @('Staff') -Primary 512),
        (New-User 'Administrator' 500), (New-User 'renamed' 502), (New-User 'krbtgt' 502), (New-User 'Guest' 501),
        (New-User 'svc-dirmaint' 1400), (New-User 'upnonly' 1401 -Upn 'svc-dirmaint@x.onmicrosoft.com'), (New-User 'MSOL_abc' 1402), (New-User 'BreakGlass1' 1403)
    )
    $r = Run 'Disable' 'ea,sa,pa,Administrator,renamed,krbtgt,Guest,svc-dirmaint,upnonly,MSOL_abc,BreakGlass1,ghost'
    Assert ($r.ExitCode -eq 1) 'Refusals exit 1'
    foreach ($l in $r.Lines | Select-Object -First 11) { Assert ($l.Status -eq 'refused') "Refused: $($l.Sam) ($($l.Status))" }
    Assert ($r.Lines[11].Status -eq 'notfound') 'Missing account is notfound'
    Assert ($script:Fake.Log.Count -eq 0 -and -not (Test-Path -LiteralPath $tmp)) 'A refusal changes nothing and writes no backup'
    Assert ($r.Lines[0].Reason -match 'Enterprise Admins' -and $r.Lines[2].Reason -match 'primary group') 'Reasons name the group'

    # Disable, no OU: backup first, then disable, describe, read back.
    New-Fake @((New-User 'jdoe' 1200 @('Staff', 'Payroll')), (New-User 'other' 1201))
    $r = Run 'Disable' 'jdoe'
    $l = $r.Lines[0]
    Assert ($r.ExitCode -eq 0 -and $l.Status -eq 'disabled') "Disable succeeds ($($l.Reason))"
    Assert (($script:Fake.Log -join ',') -eq 'lock,lock,disable,describe') "Order: lock, backup, disable, describe ($($script:Fake.Log -join ','))"
    Assert ($l.After.enabled -eq $false -and $l.After.description -eq 'Disabled by Relian 2026-11-19') 'Default description names the date'
    Assert ($l.Moved -eq 'not requested') 'No move unless asked'
    $backup = Get-Content -LiteralPath $l.Backup -Raw | ConvertFrom-Json
    Assert ($l.Backup -like "$tmp*2026-11-19*jdoe-103000.json") "Backup path is dated: $($l.Backup)"
    Assert ($backup.before.enabled -eq $true -and $backup.before.description -eq 'old text' -and $backup.before.memberOf.Count -eq 2) 'Backup holds the before-state and the group DNs'
    Assert ((Run 'Report' 'other').Lines[0].Before.enabled -eq $true) 'Other accounts are untouched'

    # Custom description, an existing OU, and a missing OU.
    New-Fake @((New-User 'jdoe' 1200)) -Ous @('OU=Disabled,DC=x')
    $r = Run 'Disable' 'jdoe' 'left the firm' 'OU=Disabled,DC=x'
    Assert ($r.Lines[0].Status -eq 'disabled' -and $r.Lines[0].Moved -eq 'yes' -and $r.Lines[0].After.dn -eq 'CN=jdoe,OU=Disabled,DC=x' -and $r.Lines[0].After.description -eq 'left the firm') 'Disable then move'
    Assert (($script:Fake.Log -join ',') -eq 'lock,lock,disable,describe,move') 'Move comes last'
    New-Fake @((New-User 'jdoe' 1200)) -Ous @('OU=Disabled,DC=x')
    $r = Run 'Disable' 'jdoe' '' 'OU=Nope,DC=x'
    Assert ($r.ExitCode -eq 0 -and $r.Lines[0].Moved -eq 'skipped, OU not found' -and -not ($script:Fake.Log -contains 'move')) 'A missing OU skips the move without failing'

    # Read-back mismatch exits 1.
    New-Fake @((New-User 'jdoe' 1200)); $script:Fake.DisableSticks = $false
    $r = Run 'Disable' 'jdoe'
    Assert ($r.ExitCode -eq 1 -and $r.Lines[0].Status -eq 'mismatch' -and $r.Lines[0].Reason -match 'still enabled') 'Disable that did not stick is a mismatch'
    New-Fake @((New-User 'jdoe' 1200)); $script:Fake.DescSticks = $false
    $r = Run 'Disable' 'jdoe'
    Assert ($r.ExitCode -eq 1 -and $r.Lines[0].Reason -match 'description') 'Description that did not stick is a mismatch'

    # A failed backup stops the change; one bad account does not stop the next.
    New-Fake @((New-User 'jdoe' 1200), (New-User 'ok' 1201))
    $script:OfLockFolder = { param($p) if ($script:Fake.Log.Count -eq 0) { $script:Fake.Log.Add('lock'); throw 'locked out' } }
    $r = Run 'Disable' 'jdoe,ok'
    Assert ($r.Lines[0].Status -eq 'error' -and $r.Lines[0].Reason -match 'locked out') 'No change after a failed backup'
    Assert ((@($script:Fake.Users)[0]).Enabled -eq $true) 'Account stays enabled when the backup fails'
    Assert ($r.Lines[1].Status -eq 'disabled' -and $r.ExitCode -eq 1) 'The next account still runs; exit is 1'

    # Never deletes or removes memberships: the package has no such call.
    $src = Get-Content -LiteralPath $packagePath -Raw
    Assert ($src -notmatch '(?m)^[^#\r\n]*\b(Remove-AD\w+|Remove-ADGroupMember|Set-Mailbox|Remove-Mailbox)\b') 'No delete, membership removal or mailbox cmdlet in the package'
    Write-Output 'ad-user-offboard tests passed'
} finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
}
