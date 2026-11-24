# Diagnostic module, run by windows/runner/Invoke-RelianJob.ps1 as SYSTEM on a domain controller. Strictly read-only:
# linked-value replication metadata of the Staff group's member attribute (who was added or removed, and when),
# one user's memberOf and whenChanged, and group-membership change events (4728/4729/4732/4733/4756/4757) of 14 days.
[CmdletBinding()]
param([switch]$ReportOnly)
$ErrorActionPreference = 'Continue'
Set-StrictMode -Off
Import-Module ActiveDirectory
$r = [ordered]@{ host = $env:COMPUTERNAME; now = (Get-Date).ToString('s') }
$g = Get-ADGroup 'Staff' -Properties member, whenChanged, groupCategory, groupScope
$r.staff = "$($g.DistinguishedName) members=$(@($g.member).Count) whenChanged=$($g.whenChanged.ToString('s'))"
$since = (Get-Date).AddDays(-14)
$r.memberChanges = @(Get-ADReplicationAttributeMetadata -Object $g.DistinguishedName -Server $env:COMPUTERNAME -ShowAllLinkedValues -Filter { AttributeName -eq 'member' } |
    Where-Object { $_.LastOriginatingChangeTime -gt $since -or ($_.LastOriginatingDeleteTime -and $_.LastOriginatingDeleteTime -gt $since) } |
    ForEach-Object { "$(($_.AttributeValue -split ',')[0]) changed=$($_.LastOriginatingChangeTime.ToString('s')) deleted=$(if ($_.LastOriginatingDeleteTime -and $_.LastOriginatingDeleteTime.Year -gt 1601) { $_.LastOriginatingDeleteTime.ToString('s') } else { '-' }) dc=$(($_.LastOriginatingChangeDirectoryServerIdentity -split ',')[1])" })
$u = Get-ADUser 'selectother' -Properties memberOf, whenChanged, whenCreated
$r.user = "$($u.DistinguishedName) created=$($u.whenCreated.ToString('s')) changed=$($u.whenChanged.ToString('s'))"
$r.userGroups = @($u.memberOf | ForEach-Object { ($_ -split ',')[0] })
try { $r.events = @(Get-WinEvent -FilterHashtable @{ LogName = 'Security'; Id = 4728, 4729, 4732, 4733, 4756, 4757; StartTime = $since } -MaxEvents 60 -ErrorAction Stop | ForEach-Object {
    $x = [xml]$_.ToXml(); $d = @{}; foreach ($e in $x.Event.EventData.Data) { $d[$e.Name] = $e.'#text' }
    "$($_.TimeCreated.ToString('s')) $($_.Id) group=$($d.TargetUserName) member=$((($d.MemberName) -split ',')[0]) by=$($d.SubjectDomainName)\$($d.SubjectUserName)" }) } catch { $r.events = "err: $($_.Exception.Message)" }
Write-Output ($r | ConvertTo-Json -Depth 4 -Compress)
exit 0
