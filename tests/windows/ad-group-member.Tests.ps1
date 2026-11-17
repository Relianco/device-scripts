$ErrorActionPreference = 'Stop'
$env:RELIAN_DEPLOY_TEST = '1'
$packagePath = Join-Path $PSScriptRoot '../../windows/packages/ad-group-member/Invoke-AdGroupMember.ps1'
. $packagePath

function Assert($ok, $message) { if (-not $ok) { throw $message } }

$domain = 'S-1-5-21-1-2-3'
$ug = '11111111-1111-1111-1111-111111111111'
$gg = '22222222-2222-2222-2222-222222222222'

# A fake directory: one user, groups by name, membership as a set of group DNs, tasks by name.
function New-Fake {
    param([hashtable[]]$Groups = @(@{ Name = 'Staff'; Sid = "$domain-1333" }), [bool]$IsDc = $true)
    $f = [pscustomobject]@{
        IsDc = $IsDc; Users = [System.Collections.Generic.List[object]]::new(); Groups = [System.Collections.Generic.List[object]]::new()
        MemberOf = [System.Collections.Generic.List[string]]::new(); Tasks = @{}; Adds = 0; Removes = 0; Registers = 0
        Filters = [System.Collections.Generic.List[string]]::new(); AddSticks = $true; RegisterSticks = $true; Order = [System.Collections.Generic.List[string]]::new()
    }
    $f.Users.Add([pscustomobject]@{ ObjectGUID = [Guid]$ug; SamAccountName = 'jdoe'; UserPrincipalName = 'jdoe@example.com' })
    foreach ($g in $Groups) {
        $o = [pscustomobject]@{ ObjectGUID = [Guid]$gg; Name = $g.Name; SamAccountName = $g.Name; SID = $g.Sid; DistinguishedName = "CN=$($g.Name),CN=Users,DC=x" }
        if ($g.ContainsKey('AdminCount')) { $o | Add-Member -NotePropertyName adminCount -NotePropertyValue $g.AdminCount }
        $f.Groups.Add($o)
    }
    $script:Fake = $f
    $script:AgIsDc = { $script:Fake.IsDc }
    $script:AgImport = { }
    $script:AgFindUsers = {
        param($ldap)
        $script:Fake.Filters.Add($ldap)
        @($script:Fake.Users | Where-Object { $ldap -like "*(userPrincipalName=$($_.UserPrincipalName))*" -or $ldap -like "*(sAMAccountName=$($_.SamAccountName))*" })
    }
    $script:AgFindGroups = { param($ldap) @($script:Fake.Groups | Where-Object { $ldap -like "*(cn=$($_.Name))*" }) }
    $script:AgMemberOf = { param($u) @($script:Fake.MemberOf) }
    $script:AgAdd = { param($g, $u) $script:Fake.Adds++; $script:Fake.Order.Add('add'); if ($script:Fake.AddSticks) { $script:Fake.MemberOf.Add($script:Fake.Groups[0].DistinguishedName) } }
    $script:AgRemove = { param($g, $u) $script:Fake.Removes++; [void]$script:Fake.MemberOf.Remove($script:Fake.Groups[0].DistinguishedName) }
    $script:AgNow = { [DateTime]'2026-11-15T10:00:00' }
    $script:AgGetTask = { param($n) $script:Fake.Tasks[$n] }
    $script:AgRegisterTask = { param($n, $at, $enc) $script:Fake.Registers++; $script:Fake.Order.Add('task'); if ($script:Fake.RegisterSticks) { $script:Fake.Tasks[$n] = $at.ToString('s') } }
    $script:AgUnregisterTask = { param($n) $script:Fake.Tasks.Remove($n) }
    return $f
}
$task = "AdGroupExpiry-$gg-$ug"

# Validation and the off switch.
$f = New-Fake
foreach ($bad in @('', 'a*', 'a(b', 'a)b', 'a\b', "a`nb", ('x' * 257), 'a b')) {
    $r = Invoke-AgMain -Action Install -User $bad -Group 'Staff'
    Assert ($r.ExitCode -eq 1 -and -not $r.Result.Contains('User')) "Bad User refused: [$bad]"
}
foreach ($bad in @('', 'St*ff', 'a(b', 'a\b', ('g' * 257))) {
    $r = Invoke-AgMain -Action Install -User 'jdoe' -Group $bad
    Assert ($r.ExitCode -eq 1) "Bad Group refused: [$bad]"
}
Assert ($f.Filters.Count -eq 0) 'Nothing is looked up for a rejected value'
$r = Invoke-AgMain -Action Frob -User 'jdoe' -Group 'Staff'
Assert ($r.ExitCode -eq 1 -and $r.Result.Reason -eq 'unsupported action') 'Unknown action refused'
$r = Invoke-AgMain -Action Install -Section Nope -User 'jdoe' -Group 'Staff'
Assert ($r.ExitCode -eq 1) 'Unknown section refused'
foreach ($a in @('Install', 'Uninstall')) {
    $r = Invoke-AgMain -Action $a -User 'bad*' -Group 'Staff' -PinVersion ''
    Assert ($r.ExitCode -eq 0 -and $r.Result.Status -eq 'disabled' -and $f.Adds -eq 0) "Empty pin disables $a"
}

# Expiry parsing.
foreach ($case in @(
        @{ D = '0' }, @{ D = '366' }, @{ D = '-1' }, @{ D = '1.5' }, @{ D = 'seven' },
        @{ O = '2026-11-15' }, @{ O = '2025-01-01' }, @{ O = '2027-12-01' }, @{ O = '15/11/2026' }, @{ O = '2026-13-01' },
        @{ D = '7'; O = '2026-11-22' })) {
    $f = New-Fake
    $r = Invoke-AgMain -Action Install -User 'jdoe' -Group 'Staff' -ExpiresInDays ([string]$case.D) -ExpiresOn ([string]$case.O)
    Assert ($r.ExitCode -eq 1 -and $f.Adds -eq 0 -and $f.Registers -eq 0) "Bad expiry refused: D=$($case.D) O=$($case.O)"
}
$e = Get-AgExpiry '7' '' ([DateTime]'2026-11-15T10:00:00')
Assert ($e -eq [DateTime]'2026-11-22T10:00:00') 'ExpiresInDays adds days to now'
$e = Get-AgExpiry '' '2026-11-22' ([DateTime]'2026-11-15T10:00:00')
Assert ($e -eq [DateTime]'2026-11-22T00:00:00') 'A bare date is midnight at the start of that day'
$e = Get-AgExpiry '' '2026-11-22T17:30' ([DateTime]'2026-11-15T10:00:00')
Assert ($e -eq [DateTime]'2026-11-22T17:30:00') 'A date with a time is that time'
$f = New-Fake
$r = Invoke-AgMain -Action Uninstall -User 'jdoe' -Group 'Staff' -ExpiresInDays '7'
Assert ($r.ExitCode -eq 1 -and $r.Result.Reason -like '*Install only*') 'Expiry with Uninstall refused'

# Where it runs, and who it resolves.
$f = New-Fake -IsDc $false
$r = Invoke-AgMain -Action Install -User 'jdoe' -Group 'Staff'
Assert ($r.ExitCode -eq 1 -and $r.Result.Reason -like '*domain controller*') 'Refused off a DC'
$f = New-Fake
$r = Invoke-AgMain -Action Install -User 'cloud.only@example.com' -Group 'Staff'
Assert ($r.ExitCode -eq 1 -and $r.Result.Reason -like '*cloud-only*' -and $f.Adds -eq 0) 'A user not in AD is refused as cloud-only'
$f = New-Fake
$r = Invoke-AgMain -Action Install -User 'jdoe@example.com' -Group 'Staff'
Assert ($r.ExitCode -eq 0 -and $f.Filters.Count -eq 1 -and $f.Filters[0] -like '*userPrincipalName=jdoe@example.com*') 'UPN is tried first'
$f = New-Fake
$r = Invoke-AgMain -Action Install -User 'jdoe' -Group 'Staff'
Assert ($r.ExitCode -eq 0 -and $f.Filters.Count -eq 2 -and $f.Filters[1] -like '*sAMAccountName=jdoe*') 'sAMAccountName is the fallback'
$f = New-Fake
$f.Users.Add($f.Users[0])
$r = Invoke-AgMain -Action Install -User 'jdoe' -Group 'Staff'
Assert ($r.ExitCode -eq 1 -and $r.Result.Reason -like '*matches 2*') 'An ambiguous user is refused'
$f = New-Fake
$r = Invoke-AgMain -Action Install -User 'jdoe' -Group 'Nope'
Assert ($r.ExitCode -eq 1 -and $r.Result.Reason -like '*not in Active Directory*') 'A missing group is refused'

# Privileged groups: by name, by SID, by RID, by adminCount.
foreach ($name in @('Domain Admins', 'Enterprise Admins', 'Administrators', 'Schema Admins', 'Account Operators', 'Backup Operators',
        'Server Operators', 'Print Operators', 'Group Policy Creator Owners', 'DnsAdmins', 'Protected Users')) {
    $f = New-Fake -Groups @(@{ Name = $name; Sid = "$domain-5000" })
    $r = Invoke-AgMain -Action Install -User 'jdoe' -Group $name
    Assert ($r.ExitCode -eq 1 -and $r.Result.Reason -like '*privileged*' -and $f.Adds -eq 0) "Privileged by name: $name"
}
foreach ($sid in @('S-1-5-32-544', 'S-1-5-32-551', "$domain-512", "$domain-519", "$domain-518", "$domain-525")) {
    $f = New-Fake -Groups @(@{ Name = 'Renamed'; Sid = $sid })
    $r = Invoke-AgMain -Action Install -User 'jdoe' -Group 'Renamed'
    Assert ($r.ExitCode -eq 1 -and $f.Adds -eq 0) "Privileged by SID: $sid"
}
$f = New-Fake -Groups @(@{ Name = 'Nested'; Sid = "$domain-5001"; AdminCount = 1 })
$r = Invoke-AgMain -Action Install -User 'jdoe' -Group 'Nested'
Assert ($r.ExitCode -eq 1 -and $f.Adds -eq 0) 'Privileged by adminCount'
$f = New-Fake -Groups @(@{ Name = 'Domain Admins'; Sid = "$domain-512" })
$f.MemberOf.Add('CN=Domain Admins,CN=Users,DC=x')
$r = Invoke-AgMain -Action Uninstall -User 'jdoe' -Group 'Domain Admins'
Assert ($r.ExitCode -eq 1 -and $f.Removes -eq 0) 'Uninstall is refused on a privileged group too'

# Install: add once, idempotent, verified.
$f = New-Fake
$r = Invoke-AgMain -Action Install -User 'jdoe' -Group 'Staff'
Assert ($r.ExitCode -eq 0 -and $r.Result.Status -eq 'applied' -and $r.Result.Member -and $f.Adds -eq 1 -and $f.Registers -eq 0) 'Install adds without an expiry task'
$r = Invoke-AgMain -Action Install -User 'jdoe' -Group 'Staff'
Assert ($r.Result.Status -eq 'compliant' -and $f.Adds -eq 1) 'A second Install does not add again'
$f = New-Fake
$f.AddSticks = $false
$r = Invoke-AgMain -Action Install -User 'jdoe' -Group 'Staff'
Assert ($r.ExitCode -eq 1 -and $r.Result.Reason -like '*read-back*') 'An add that does not stick fails'

# Install with an expiry: the task first, read back, replaced on a rerun.
$f = New-Fake
$r = Invoke-AgMain -Action Install -User 'jdoe' -Group 'Staff' -ExpiresInDays '7'
Assert ($r.ExitCode -eq 0 -and $r.Result.ExpiresAt -eq '2026-11-22T10:00:00' -and $r.Result.ExpiryTask -eq "\Relian\$task") 'Expiry task registered and reported'
Assert (($f.Order -join ',') -eq 'task,add') 'The expiry task is registered before the add'
$r = Invoke-AgMain -Action Install -User 'jdoe' -Group 'Staff' -ExpiresOn '2026-12-01'
Assert ($r.Result.Status -eq 'compliant' -and $r.Result.ExpiresAt -eq '2026-12-01T00:00:00' -and $f.Registers -eq 2 -and $f.Adds -eq 1) 'A rerun replaces the date and does not add again'
$r = Invoke-AgMain -Action Install -User 'jdoe' -Group 'Staff'
Assert ($r.Result.ExpiresAt -eq '2026-12-01T00:00:00' -and $f.Registers -eq 2) 'Install without an expiry keeps the existing task'
$f = New-Fake
$f.RegisterSticks = $false
$r = Invoke-AgMain -Action Install -User 'jdoe' -Group 'Staff' -ExpiresInDays '7'
Assert ($r.ExitCode -eq 1 -and $f.Adds -eq 0) 'No add when the expiry task did not register'

# Evidence is read-only.
$f = New-Fake
$f.MemberOf.Add('CN=Staff,CN=Users,DC=x'); $f.Tasks[$task] = '2026-11-22T10:00:00'
$r = Invoke-AgMain -Section Evidence -Action Install -User 'jdoe' -Group 'Staff'
Assert ($r.Result.Status -eq 'evidence' -and $r.Result.Member -and $r.Result.ExpiresAt -eq '2026-11-22T10:00:00') 'Evidence reports membership and expiry'
$r = Invoke-AgMain -Section Evidence -Action Uninstall -User 'jdoe' -Group 'Staff'
Assert ($f.Adds -eq 0 -and $f.Removes -eq 0 -and $f.Tasks.Count -eq 1) 'Evidence changes nothing'

# Uninstall removes the membership and the task, and is idempotent.
$r = Invoke-AgMain -Action Uninstall -User 'jdoe' -Group 'Staff'
Assert ($r.ExitCode -eq 0 -and $r.Result.Status -eq 'removed' -and -not $r.Result.Member -and $f.Tasks.Count -eq 0) 'Uninstall removes membership and task'
$r = Invoke-AgMain -Action Uninstall -User 'jdoe' -Group 'Staff'
Assert ($r.Result.Status -eq 'absent' -and $f.Removes -eq 1) 'A second Uninstall is a no-op'

# The expiry task script: only GUIDs go in, and it parses.
$threw = $false
try { [void](Get-AgEncodedTask "x'; Remove-Item C:\ -Recurse; '" $ug) } catch { $threw = $true }
Assert $threw 'A non-GUID is never put into the task script'
$text = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String((Get-AgEncodedTask $gg $ug)))
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$errors)
Assert ($errors.Count -eq 0 -and $text.Contains("'$gg'") -and $text.Contains("'$ug'") -and $text.Contains("'$task'")) 'Task script parses and holds the GUIDs and its name'
Assert ((Get-AgEncodedTask $gg $ug).Length -lt 8000) 'Encoded task fits a task action argument'

# Run the task script against stubs in a child process: it removes, verifies, deletes itself, logs; on failure it keeps the task.
$work = Join-Path ([IO.Path]::GetTempPath()) ('agtest-' + [guid]::NewGuid().ToString('n'))
$null = New-Item -ItemType Directory -Path $work
try {
    $stubs = @'
function Import-Module { }
function Get-ADGroup { param($Filter) [pscustomobject]@{ DistinguishedName = 'CN=Staff,DC=x' } }
function Get-ADUser { param($Filter, $Properties) if ($env:AG_GONE) { return } [pscustomobject]@{ MemberOf = @(if (Test-Path (Join-Path $env:AG_WORK 'member')) { 'CN=Staff,DC=x' }) } }
function Remove-ADGroupMember { param($Identity, $Members, [switch]$Confirm) if ($env:AG_STUCK) { return } Remove-Item (Join-Path $env:AG_WORK 'member') }
function Unregister-ScheduledTask { param($TaskPath, $TaskName, [switch]$Confirm) Set-Content (Join-Path $env:AG_WORK 'unregistered') "$TaskPath$TaskName" }
'@
    $runTask = {
        param([hashtable]$Env)
        Get-ChildItem -LiteralPath $work -Exclude 'task.ps1' | Remove-Item -Recurse -Force
        Set-Content -LiteralPath (Join-Path $work 'task.ps1') -Value ($stubs + "`n" + $text)
        $saved = @{}
        foreach ($k in @('AG_WORK', 'AG_GONE', 'AG_STUCK', 'ProgramData')) { $saved[$k] = [Environment]::GetEnvironmentVariable($k) }
        [Environment]::SetEnvironmentVariable('AG_WORK', $work); [Environment]::SetEnvironmentVariable('ProgramData', $work)
        [Environment]::SetEnvironmentVariable('AG_GONE', $Env.Gone); [Environment]::SetEnvironmentVariable('AG_STUCK', $Env.Stuck)
        if ($Env.Member) { Set-Content (Join-Path $work 'member') 'x' }
        try {
            # The host running this test, so the 5.1 CI step runs the task script on 5.1 as the DC does.
            & (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File (Join-Path $work 'task.ps1') | Out-Null
            $code = $LASTEXITCODE
        } finally {
            foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
        }
        $logFile = Join-Path $work 'Relian/AdGroupMember/ad-group-member.log'
        return @{
            Code = $code; Member = Test-Path (Join-Path $work 'member'); Unregistered = Test-Path (Join-Path $work 'unregistered')
            Log = if (Test-Path $logFile) { Get-Content -Raw $logFile } else { '' }
        }
    }
    $o = & $runTask @{ Member = $true }
    Assert ($o.Code -eq 0 -and -not $o.Member -and $o.Unregistered -and $o.Log -like '*membership removed*' -and $o.Log -like '*task deleted*') 'Task removes the membership, then deletes itself'
    $o = & $runTask @{ Member = $false }
    Assert ($o.Code -eq 0 -and $o.Unregistered -and $o.Log -like '*not a member*') 'Task with nothing to remove still deletes itself'
    $o = & $runTask @{ Member = $true; Gone = '1' }
    Assert ($o.Code -eq 0 -and $o.Unregistered) 'Task deletes itself when the user is gone'
    $o = & $runTask @{ Member = $true; Stuck = '1' }
    Assert ($o.Code -eq 1 -and $o.Member -and -not $o.Unregistered -and $o.Log -like '*retrying*') 'A failed removal keeps the task for the hourly retry'
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

# Output cap.
$line = ConvertTo-AgLine ([ordered]@{ Package = 'ad-group-member'; Status = 'error'; Reason = ('E' * 5000) })
Assert ([System.Text.Encoding]::UTF8.GetByteCount($line) -le 2000 -and $line -notmatch "[\r\n]") 'Output capped at 2000 bytes on one line'

Write-Output 'ad-group-member tests passed'
