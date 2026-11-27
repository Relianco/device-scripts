$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
function Assert($Condition, $Label) { if (-not $Condition) { throw "FAIL $Label" } }
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$path = Join-Path $root 'windows/read/ad-evidence/Invoke-AdEvidence.ps1'
$env:RELIAN_DEPLOY_TEST = '1'
. $path

# Parses, uses no syntax newer than Windows PowerShell 5.1, and holds no write verb anywhere in its text.
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
Assert ($errors.Count -eq 0) 'parser'
foreach ($kind in @('QuestionQuestion', 'QuestionQuestionEquals', 'QuestionDot', 'QuestionLBracket', 'AndAnd', 'OrOr', 'QuestionMark')) {
    Assert (-not @($tokens | Where-Object { [string]$_.Kind -eq $kind })) "no PowerShell 7 token $kind"
}
$text = [IO.File]::ReadAllText($path)
foreach ($verb in @('Set', 'New', 'Remove', 'Move', 'Rename', 'Restore', 'Enable', 'Disable', 'Clear', 'Add', 'Start', 'Stop', 'Restart')) {
    Assert ($text -cnotmatch ('\b' + $verb + '-[A-Z]')) "read-only: no $verb- in the script text"
}
foreach ($c in @('Ninja-Property-Set', 'dsmod', 'dsadd', 'netdom', 'dnscmd')) { Assert ($text -notmatch [regex]::Escape($c)) "read-only: no $c" }

# Fake domain, found through RootDSE.
$domainDn = 'DC=corp,DC=example,DC=invalid'
$configDn = 'CN=Configuration,' + $domainDn
function Import-Module { param($Name, $ErrorAction) }
function Get-ADRootDSE { param($Server, $ErrorAction) [pscustomobject]@{ defaultNamingContext = $domainDn; configurationNamingContext = $configDn; dnsHostName = 'dc1.corp.example.invalid' } }
$ctx = Get-AdeContext
Assert ($ctx.DomainDN -eq $domainDn -and $ctx.ConfigDN -eq $configDn -and $ctx.DnsDomain -eq 'corp.example.invalid') 'domain and zone discovered from RootDSE'

# Inventory.
$t0 = ([datetime]'2026-11-01T00:00:00Z').ToUniversalTime()
function New-FakeComputer { param([string]$Name, [string]$Ou, [bool]$Enabled = $true, [int]$Certs = 0)
    [pscustomobject]@{ Name = $Name; SamAccountName = "$Name$"; DistinguishedName = "CN=$Name,$Ou,$domainDn"; Enabled = $Enabled; OperatingSystem = 'Windows 11 Pro'; OperatingSystemVersion = '10.0 (26100)'
        lastLogonTimestamp = $t0.ToFileTimeUtc(); pwdLastSet = $t0.AddDays(-20).ToFileTimeUtc(); userCertificate = @(1..$Certs | Where-Object { $Certs } | ForEach-Object { ,[byte[]](1, 2, 3) }) } }
function New-FakeUser { param([string]$Sam, [string]$Ou, [string]$Upn, [bool]$Enabled = $true)
    [pscustomobject]@{ SamAccountName = $Sam; DistinguishedName = "CN=$Sam,$Ou,$domainDn"; Enabled = $Enabled; UserPrincipalName = $Upn; ObjectGUID = [guid]'00112233-4455-6677-8899-aabbccddeeff'
        lastLogonTimestamp = $t0.ToFileTimeUtc(); adminCount = $null } }
$script:computers = @((New-FakeComputer 'PC-002' 'OU=Workstations' $true 1), (New-FakeComputer 'PC-001' 'OU=Workstations'), (New-FakeComputer 'OLD-PC' 'CN=Computers' $false))
1..80 | ForEach-Object { $script:computers += New-FakeComputer ('WS-{0:000}' -f $_) 'OU=Lab,OU=Workstations' }
$script:users = @((New-FakeUser 'user1' 'OU=Staff' 'user1@example.com'), (New-FakeUser 'svc1' 'CN=Users' $null $false), (New-FakeUser 'user2' 'OU=Staff' 'u.two@corp.example.invalid'))
$script:bases = [Collections.Generic.List[string]]::new()
function Get-ADComputer { param($LDAPFilter, $SearchBase, $Properties, $Server, $ResultPageSize, $ErrorAction) $script:bases.Add([string]$SearchBase); $script:computers }
function Get-ADUser { param($LDAPFilter, $SearchBase, $Properties, $Server, $ResultPageSize, $ErrorAction) $script:bases.Add([string]$SearchBase); $script:users }

$json = Invoke-AdEvidence -Context $ctx
$r = $json | ConvertFrom-Json
Assert ($r.section -eq 'Inventory' -and $r.searchBase -eq $domainDn -and @($script:bases | Where-Object { $_ -ne $domainDn }).Count -eq 0) 'Inventory defaults to the domain root'
Assert ([Text.Encoding]::UTF8.GetByteCount($json) -le 8000) 'Inventory output capped'
Assert ($r.total -eq 86 -and $r.returned -lt 86 -and $r.nextOffset -eq $r.returned) 'Inventory paged with next offset'
Assert ($r.counts.computers -eq 83 -and $r.counts.computersEnabled -eq 82 -and $r.counts.computersWithCert -eq 1 -and $r.counts.users -eq 3 -and $r.counts.usersEnabled -eq 2) 'Inventory counts every object'
$pc = @($r.rows | Where-Object { $_.name -eq 'PC-002' })[0]
Assert ($r.rows[0].name -eq 'OLD-PC' -and $pc.kind -eq 'computer' -and $pc.ou -eq 'OU=Workstations' -and $pc.enabled -and $pc.lastLogon -eq '2026-11-01' -and $pc.os -eq 'Windows 11 Pro' -and $pc.osVersion -eq '10.0 (26100)' -and $pc.certs -eq 1) 'computer row facts'
Assert (-not $r.rows[0].enabled -and $r.rows[0].ou -eq 'CN=Computers') 'disabled computer in the default container'
$last = Invoke-AdEvidence -Context $ctx -Offset '83' | ConvertFrom-Json
$u1 = @($last.rows | Where-Object { $_.name -eq 'user1' })[0]; $u2 = @($last.rows | Where-Object { $_.name -eq 'user2' })[0]; $s1 = @($last.rows | Where-Object { $_.name -eq 'svc1' })[0]
Assert ($last.offset -eq 83 -and $last.returned -eq 3 -and $null -eq $last.nextOffset) 'last page'
Assert ($u1.kind -eq 'user' -and $u1.ou -eq 'OU=Staff' -and $u1.upnSuffix -eq 'example.com' -and $u1.upnIsSam -and $u1.immutableId -eq [Convert]::ToBase64String(([guid]'00112233-4455-6677-8899-aabbccddeeff').ToByteArray())) 'user row facts'
Assert ($u2.upnSuffix -eq 'corp.example.invalid' -and -not $u2.upnIsSam -and $null -eq $s1.upnSuffix -and -not $s1.enabled) 'UPN suffix and local part'
$script:bases.Clear()
$scoped = Invoke-AdEvidence -Context $ctx -SearchBase ('OU=Workstations,' + $domainDn) | ConvertFrom-Json
Assert ($scoped.searchBase -eq ('OU=Workstations,' + $domainDn) -and @($script:bases | Where-Object { $_ -ne ('OU=Workstations,' + $domainDn) }).Count -eq 0) 'SearchBase scopes the query'
foreach ($bad in @('OU=Elsewhere,DC=other,DC=invalid', "OU=x`n,$domainDn", ('OU=' + ('a' * 600) + ',' + $domainDn))) {
    $threw = $false; try { [void](Invoke-AdEvidence -Context $ctx -SearchBase $bad) } catch { $threw = $true }
    Assert $threw "SearchBase outside the domain or malformed refused: $($bad.Substring(0, 12))"
}

# Scp.
$tenant = [guid]::NewGuid().ToString()
$scpDn = 'CN=62a0ff2e-97b9-4513-943f-0d221bd30080,CN=Device Registration Configuration,CN=Services,' + $configDn
$script:asked = $null
function Get-ADObject { param($Identity, $Properties, $Server, $ErrorAction) $script:asked = [string]$Identity
    [pscustomobject]@{ DistinguishedName = $Identity; keywords = @("azureADName:tenant.example.com", "azureADId:$tenant", 'other'); whenChanged = [datetime]'2026-10-01T12:00:00Z' } }
$sj = Invoke-AdEvidence -Section Scp -Context $ctx
$s = $sj | ConvertFrom-Json
Assert ($script:asked -eq $scpDn) 'Scp read from the configuration NC'
Assert ($s.section -eq 'Scp' -and $s.scp.exists -and $s.scp.azureADId -eq $tenant -and $s.scp.azureADName -eq 'tenant.example.com' -and $s.scp.otherKeywords -eq 1 -and $sj -match '"whenChanged":"2026-10-01T12:00') 'Scp keywords'
function Get-ADObject { param($Identity, $Properties, $Server, $ErrorAction) throw [Management.Automation.ItemNotFoundException]::new('Cannot find an object with identity') }
$sm = Invoke-AdEvidence -Section Scp -Context $ctx | ConvertFrom-Json
Assert ($sm.scp.exists -eq $false -and $null -eq $sm.scp.PSObject.Properties['azureADId']) 'missing SCP reported'
function Get-ADObject { param($Identity, $Properties, $Server, $ErrorAction) throw [UnauthorizedAccessException]::new('denied') }
$sd = Invoke-AdEvidence -Section Scp -Context $ctx | ConvertFrom-Json
Assert ($sd.scp.status -eq 'unavailable' -and $sd.scp.error -eq 'UnauthorizedAccessException') 'unreadable SCP is not reported as missing'

# Reach: input validation.
foreach ($bad in @('', 'PC 1', 'PC-1$', 'PC*', 'PC)(cn=*', ('A' * 16), "PC1`n", 'PC.example')) {
    $threw = $false; try { [void](Invoke-AdEvidence -Section Reach -Name $bad -Context $ctx) } catch { $threw = $true }
    Assert $threw "bad Name refused: [$bad]"
}
foreach ($bad in @('svc;x', 'a b', ('s' * 65), (@(1..9 | ForEach-Object { "s$_" }) -join ','))) {
    $threw = $false; try { [void](Invoke-AdEvidence -Name 'PC-001' -Services $bad -Context $ctx) } catch { $threw = $true }
    Assert $threw "bad Services refused: [$($bad.Substring(0, 3))]"
}

# Reach: every source mocked.
$ip = '192.0.2.10'
$script:filters = [Collections.Generic.List[string]]::new()
function Get-ADComputer { param($LDAPFilter, $SearchBase, $Properties, $Server, $ResultPageSize, $ErrorAction) $script:filters.Add([string]$LDAPFilter)
    $c = New-FakeComputer 'PC-001' 'OU=Workstations' $true 2
    $c | Add-Member -NotePropertyName DNSHostName -NotePropertyValue 'pc-001.corp.example.invalid'
    $c | Add-Member -NotePropertyName lastLogon -NotePropertyValue $t0.ToFileTimeUtc()
    $c | Add-Member -NotePropertyName whenChanged -NotePropertyValue $t0
    $c | Add-Member -NotePropertyName userAccountControl -NotePropertyValue 4096
    $c }
$script:resolved = $null
function Resolve-DnsName { param($Name, $Type, [switch]$DnsOnly, $ErrorAction) $script:resolved = $Name; @([pscustomobject]@{ Name = $Name; IPAddress = $ip }) }
$script:zone = $null
function Get-DnsServerResourceRecord { param($ZoneName, $Name, $ErrorAction) $script:zone = $ZoneName
    @([pscustomobject]@{ RecordType = 'A'; RecordData = [pscustomobject]@{ IPv4Address = $ip }; Timestamp = $t0 }) }
function Get-DhcpServerv4Scope { param($ErrorAction) @([pscustomobject]@{ ScopeId = '192.0.2.0' }) }
function Get-DhcpServerv4Lease { param($ScopeId, $ErrorAction) @(
    [pscustomobject]@{ IPAddress = $ip; ClientId = '00-00-5e-00-53-01'; HostName = 'PC-001.corp.example.invalid'; AddressState = 'Active'; LeaseExpiryTime = $t0 },
    [pscustomobject]@{ IPAddress = '192.0.2.11'; ClientId = '00-00-5e-00-53-02'; HostName = 'PC-0015.corp.example.invalid'; AddressState = 'Active'; LeaseExpiryTime = $t0 }) }
function Test-AdePing { param([string]$Address) 'Success' }
$script:ports = [Collections.Generic.List[string]]::new()
function Test-AdeTcp { param([string]$Address, [int]$Port) $script:ports.Add("$Address`:$Port"); $Port -ne 3389 }
function Get-NetNeighbor { param($IPAddress, $ErrorAction) @([pscustomobject]@{ IPAddress = $IPAddress; LinkLayerAddress = '00-00-5E-00-53-01'; State = 'Reachable' }) }
$script:xpath = $null
function Get-WinEvent { param($LogName, $FilterXPath, $MaxEvents, [switch]$Oldest, $ErrorAction)
    if ($Oldest) { return [pscustomobject]@{ TimeCreated = $t0.AddDays(-30) } }
    $script:xpath = $FilterXPath
    $e = [pscustomobject]@{ Id = 4768; TimeCreated = $t0 }
    $e | Add-Member -MemberType ScriptMethod -Name ToXml -Value { '<Event xmlns="http://schemas.microsoft.com/win/2004/08/events/event"><EventData><Data Name="TargetUserName">PC-001$</Data><Data Name="IpAddress">::ffff:192.0.2.10</Data></EventData></Event>' }
    @($e, $e) }
$script:sc = [Collections.Generic.List[string]]::new()
function Invoke-AdeNative { param([string]$Path, [string[]]$Arguments, [int]$TimeoutSec) $script:sc.Add(($Arguments -join ' '))
    $out = "SERVICE_NAME: x`r`n        TYPE               : 10  WIN32_OWN_PROCESS`r`n        STATE              : 4  RUNNING"
    if ($Arguments[2] -eq 'ncstreamer') { $out = '[SC] OpenService FAILED 5:' + "`r`n`r`nAccess is denied." }
    [pscustomobject]@{ ExitCode = 0; Output = $out; TimedOut = $false } }

$rj = Invoke-AdEvidence -Name 'PC-001' -Context $ctx
$x = $rj | ConvertFrom-Json
Assert ($x.section -eq 'Reach' -and $x.name -eq 'PC-001') 'Name selects the Reach section'
Assert ([Text.Encoding]::UTF8.GetByteCount($rj) -le 8000) 'Reach output capped'
Assert ($script:filters -contains '(sAMAccountName=PC-001$)' -and $x.ad.found -and $x.ad.ou -eq 'OU=Workstations' -and $x.ad.dnsHostName -eq 'pc-001.corp.example.invalid' -and $x.ad.certs -eq 2 -and $x.ad.enabled -and $rj -match '"lastLogonThisDc":"2026-11-01T00:00:00Z"') 'AD computer facts'
Assert ($script:resolved -eq 'PC-001.corp.example.invalid' -and $script:zone -eq 'corp.example.invalid') 'DNS zone from the domain'
Assert (@($x.dnsResolve) -contains $ip -and $x.dnsRecord[0].data -eq $ip -and $rj -match '"timestamp":"2026-11-01T00:00') 'DNS answer and record'
Assert (@($x.dhcp).Count -eq 1 -and $x.dhcp[0].ip -eq $ip -and $x.dhcp[0].state -eq 'Active') 'DHCP lease for that host only'
Assert (@($x.probe).Count -eq 1 -and $x.probe[0].ip -eq $ip -and $x.probe[0].ping -eq 'Success' -and $x.probe[0].tcp445 -and -not $x.probe[0].tcp3389 -and $x.probe[0].arp[0] -like '00-00-5E-00-53-01*') 'ping, TCP ports and ARP'
Assert ((@($script:ports | Sort-Object) -join ',') -eq "$ip`:135,$ip`:3389,$ip`:445,$ip`:5985") 'TCP 135, 445, 3389 and 5985'
Assert ($script:xpath -match '4768' -and $script:xpath -match '4624' -and $script:xpath -match "'PC-001\$'") 'events filtered to the computer account'
Assert ($x.events.count -eq 2 -and $x.events.newest[0].id -eq 4768 -and $x.events.newest[0].ip -eq '::ffff:192.0.2.10' -and $rj -match '"securityLogOldest":"2026-10-02T00:00') 'recent logon events'
Assert ($script:sc.Count -eq 2 -and @($script:sc | Where-Object { $_ -notmatch '^\\\\PC-001\.corp\.example\.invalid query [A-Za-z]+$' }).Count -eq 0) 'sc.exe only queries'
Assert ($x.remoteService.NinjaRMMAgent -match 'RUNNING' -and $x.remoteService.ncstreamer -match 'FAILED 5') 'remote service states'
$script:sc.Clear()
$one = Invoke-AdEvidence -Name 'PC-001' -Services 'Spooler' -Context $ctx | ConvertFrom-Json
Assert ($script:sc.Count -eq 1 -and $script:sc[0] -like '* query Spooler' -and $one.remoteService.Spooler) 'Services list overrides the default'

# No DHCP role, unknown computer, a failing source.
Remove-Item function:Get-DhcpServerv4Scope, function:Get-DhcpServerv4Lease
function Get-ADComputer { param($LDAPFilter, $SearchBase, $Properties, $Server, $ResultPageSize, $ErrorAction) @() }
function Resolve-DnsName { param($Name, $Type, [switch]$DnsOnly, $ErrorAction) throw [ComponentModel.Win32Exception]::new('name does not exist') }
$n = Invoke-AdEvidence -Name 'PC-404' -Context $ctx | ConvertFrom-Json
Assert ($n.dhcp.status -eq 'noDhcpRole' -and $n.ad.found -eq $false -and $n.dnsResolve.status -eq 'unavailable' -and @($n.probe).Count -eq 0) 'missing role, object and record reported, not fatal'

# Bounded output and failures.
$threw = $false; try { [void](Invoke-AdEvidence -Section Nope -Context $ctx) } catch { $threw = $true }
Assert $threw 'unknown section refused'
$huge = [ordered]@{ status = 'collected'; rows = @(1..500 | ForEach-Object { 'x' * 60 }) }
$hj = ConvertTo-AdeBoundedJson $huge
Assert ([Text.Encoding]::UTF8.GetByteCount($hj) -le 8000 -and ($hj | ConvertFrom-Json).truncated) 'bounded JSON'
$f = ConvertTo-AdeFailure ([Management.Automation.ErrorRecord]::new([InvalidOperationException]::new('token=abc'), 'x', 'NotSpecified', $null)) | ConvertFrom-Json
Assert ($f.status -eq 'failed' -and $f.error -eq 'InvalidOperationException' -and $f.message -notmatch 'abc') 'failure line redacted'
'ad-evidence tests passed'
