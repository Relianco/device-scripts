<#
.SYNOPSIS
    Read-only Active Directory evidence for a hybrid join or directory sync review.
.DESCRIPTION
    Runs through the Relian deploy runner (NinjaOne script 374) as SYSTEM, Windows
    PowerShell 5.1, on a domain controller (or a member with the ActiveDirectory module).
    Prints one line of JSON, at most 8,000 UTF-8 bytes, with "truncated" set when a list
    was cut. The domain, configuration NC and DNS zone come from RootDSE.

    Package arguments (base64 JSON in -PackageArguments):
      Section    Inventory (default), Scp or Reach
      SearchBase DN inside this domain that scopes Inventory (default: the domain root)
      Offset     first row for Inventory (the previous run prints nextOffset)
      Name       computer name (1-15 of A-Z a-z 0-9 -); selects the Reach section
      Services   comma-separated service names for Reach (default NinjaRMMAgent,ncstreamer)

    Inventory computers, then users, one row each, paged by Offset. Computer: OU, enabled,
              lastLogonTimestamp, pwdLastSet, OS and version, userCertificate count. User:
              sAMAccountName, OU, enabled, lastLogonTimestamp, UPN suffix, whether the UPN
              local part is the sAMAccountName, adminCount, objectGUID as base64 (the Entra
              immutableId). Counts cover every object, not just the page.
    Scp       the forest's Device Registration Service connection point
              (CN=62a0ff2e-...,CN=Device Registration Configuration,CN=Services in the
              configuration NC): whether it exists, its azureADId and azureADName keywords.
    Reach     one computer: AD facts, the A answer and the DNS server record in the AD zone,
              its DHCP lease when the DHCP role is here, ping and TCP 135/445/3389/5985 from
              this server, ARP, Kerberos and logon events (4768/4624) for the computer
              account in the last 5 days, and "sc.exe \\<name> query" for each service.

    Nothing is changed: no AD, DNS, DHCP, service, registry or custom field write. New
    sources stop starting after 40 seconds.
#>
[CmdletBinding()]
param(
    [string]$DeploymentType,
    [string]$Action,
    [string]$PinVersion,
    [ValidateSet('Inventory', 'Scp', 'Reach')][string]$Section = 'Inventory',
    [string]$SearchBase = '',
    [string]$Offset = '0',
    [string]$Name = '',
    [string]$Services = 'NinjaRMMAgent,ncstreamer'
)
$ProgressPreference = 'SilentlyContinue'

$AdeScpCn = 'CN=62a0ff2e-97b9-4513-943f-0d221bd30080,CN=Device Registration Configuration,CN=Services,'
$script:AdeClock = [Diagnostics.Stopwatch]::StartNew()

function Protect-AdeText {
    param([AllowEmptyString()][string]$Text, [int]$Max = 200)
    if ($Text -match '(?i)password|passwd|secret|token|credential|bearer|api.?key') { return '[sensitive line omitted]' }
    $t = ($Text -replace '[\x00-\x1F]', ' ').Trim()
    if ($t.Length -gt $Max) { return $t.Substring(0, $Max) + '[clipped]' }
    return $t
}

function Find-AdeLargestArray {
    param($Value)
    $best = $null
    if ($Value -is [Collections.IDictionary]) {
        foreach ($k in @($Value.Keys)) {
            $item = $Value[$k]
            if ($item -is [array] -and $item.Count -gt 0 -and ($null -eq $best -or $item.Count -gt $best.Count)) { $best = @{ Container = $Value; Key = $k; Count = $item.Count } }
            $inner = Find-AdeLargestArray $item
            if ($inner -and ($null -eq $best -or $inner.Count -gt $best.Count)) { $best = $inner }
        }
    } elseif ($Value -is [array]) {
        foreach ($item in $Value) {
            $inner = Find-AdeLargestArray $item
            if ($inner -and ($null -eq $best -or $inner.Count -gt $best.Count)) { $best = $inner }
        }
    }
    return $best
}

# Drops entries from the longest list until the JSON fits, and says so with "truncated".
function ConvertTo-AdeBoundedJson {
    param($Report, [int]$MaxBytes = 8000)
    $json = $Report | ConvertTo-Json -Depth 8 -Compress
    while ([Text.Encoding]::UTF8.GetByteCount($json) -gt $MaxBytes) {
        $Report['truncated'] = $true
        $largest = Find-AdeLargestArray $Report
        if (-not $largest) { throw 'Report metadata exceeds the output budget.' }
        $keep = $largest.Count - [Math]::Max(1, [int][Math]::Ceiling($largest.Count / 8))
        $largest.Container[$largest.Key] = @($largest.Container[$largest.Key] | Select-Object -First $keep)
        $json = $Report | ConvertTo-Json -Depth 8 -Compress
    }
    return $json
}

function Get-AdeError { param($ErrorRecord) return [ordered]@{ status = 'unavailable'; error = $ErrorRecord.Exception.GetType().Name; message = (Protect-AdeText ([string]$ErrorRecord.Exception.Message) -Max 160) } }

function ConvertTo-AdeFailure {
    param($ErrorRecord)
    $e = $ErrorRecord.Exception
    $line = [ordered]@{ status = 'failed'; error = $e.GetType().Name; message = (Protect-AdeText ([string]$e.Message) -Max 300) }
    if ($e.InnerException) { $line.inner = $e.InnerException.GetType().Name }
    return ($line | ConvertTo-Json -Compress)
}

# Runs one source. Past 40 seconds it is not started; a failure is reported, not fatal.
function Invoke-AdeStep {
    param($Report, [string]$Key, [scriptblock]$Block, [switch]$AsList)
    if ($script:AdeClock.Elapsed.TotalSeconds -gt 40) { $Report[$Key] = @{ status = 'timeBudget' }; return }
    try { $v = & $Block; if ($AsList) { $v = @($v) }; $Report[$Key] = $v } catch { $Report[$Key] = Get-AdeError $_ }
}

function Get-AdeSystemExe { param([string]$Exe) return [IO.Path]::Combine([string]$env:SystemRoot, 'System32', $Exe) }

# Runs a native tool with a kill timer. Output is stdout plus stderr.
function Invoke-AdeNative {
    param([string]$Path, [string[]]$Arguments, [int]$TimeoutSec = 20)
    $psi = [Diagnostics.ProcessStartInfo]::new($Path)
    $psi.Arguments = (@($Arguments | ForEach-Object { if ($_ -eq '' -or $_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' ')
    $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
    $p = [Diagnostics.Process]::Start($psi)
    try {
        $out = $p.StandardOutput.ReadToEndAsync(); $err = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit($TimeoutSec * 1000)) { try { $p.Kill() } catch { }; return [pscustomobject]@{ ExitCode = $null; Output = ''; TimedOut = $true } }
        $p.WaitForExit()
        return [pscustomobject]@{ ExitCode = $p.ExitCode; Output = ($out.Result + $err.Result); TimedOut = $false }
    } finally { $p.Dispose() }
}

function Test-AdePing {
    param([string]$Address)
    try { return [string]([Net.NetworkInformation.Ping]::new().Send($Address, 1500).Status) } catch { return 'error' }
}

function Test-AdeTcp {
    param([string]$Address, [int]$Port)
    $c = [Net.Sockets.TcpClient]::new()
    try { return ($c.ConnectAsync($Address, $Port).Wait(2000) -and $c.Connected) } catch { return $false } finally { $c.Dispose() }
}

function ConvertTo-AdeDnsName { param([string]$Dn) return (@($Dn -split ',' | Where-Object { $_ -match '^DC=' } | ForEach-Object { $_.Substring(3) }) -join '.') }

function Get-AdeContext {
    Import-Module ActiveDirectory -ErrorAction Stop
    $rd = Get-ADRootDSE -ErrorAction Stop
    $dn = [string]$rd.defaultNamingContext
    return @{ DomainDN = $dn; ConfigDN = [string]$rd.configurationNamingContext; DnsDomain = (ConvertTo-AdeDnsName $dn); Server = [string]$rd.dnsHostName }
}

# The object's container, relative to the domain root.
function Get-AdeOu {
    param([string]$Dn, $Context)
    $parent = ($Dn -split '(?<!\\),', 2)[-1]
    $suffix = ',' + $Context.DomainDN
    if ($parent.EndsWith($suffix, [StringComparison]::OrdinalIgnoreCase)) { return $parent.Substring(0, $parent.Length - $suffix.Length) }
    if ($parent -ieq $Context.DomainDN) { return '' }
    return $parent
}

function Get-AdeDate {
    param($FileTime, [string]$Format = 'yyyy-MM-dd')
    if ($null -eq $FileTime -or [int64]$FileTime -le 0 -or [int64]$FileTime -eq [int64]::MaxValue) { return $null }
    return [datetime]::FromFileTimeUtc([int64]$FileTime).ToString($Format)
}

function Get-AdeCount { param($Value) if ($null -eq $Value) { return 0 } return @($Value).Count }

function Get-AdeInventorySection {
    param($Context, $Report, [string]$Base, [int]$Start)
    if (-not $Base) { $Base = $Context.DomainDN }
    if ($Base.Length -gt 512 -or $Base -match '[\x00-\x1F]' -or -not ($Base -ieq $Context.DomainDN -or $Base.EndsWith(',' + $Context.DomainDN, [StringComparison]::OrdinalIgnoreCase))) { throw 'SearchBase must be a DN inside this domain.' }
    $Report.searchBase = $Base
    $computers = @(Get-ADComputer -LDAPFilter '(objectCategory=computer)' -SearchBase $Base -Server $Context.Server -ResultPageSize 500 -Properties operatingSystem, operatingSystemVersion, lastLogonTimestamp, pwdLastSet, userCertificate -ErrorAction Stop | Sort-Object Name)
    $users = @(Get-ADUser -LDAPFilter '(&(objectCategory=person)(objectClass=user))' -SearchBase $Base -Server $Context.Server -ResultPageSize 500 -Properties lastLogonTimestamp, userPrincipalName, adminCount -ErrorAction Stop | Sort-Object SamAccountName)
    $rows = [Collections.Generic.List[object]]::new()
    $withCert = 0
    foreach ($c in $computers) {
        $certs = Get-AdeCount $c.userCertificate
        if ($certs) { $withCert++ }
        $rows.Add([ordered]@{ kind = 'computer'; name = [string]$c.Name; ou = (Get-AdeOu ([string]$c.DistinguishedName) $Context); enabled = [bool]$c.Enabled; lastLogon = (Get-AdeDate $c.lastLogonTimestamp); pwdLastSet = (Get-AdeDate $c.pwdLastSet); os = [string]$c.OperatingSystem; osVersion = [string]$c.OperatingSystemVersion; certs = $certs })
    }
    foreach ($u in $users) {
        $upn = [string]$u.UserPrincipalName; $suffix = $null; $isSam = $null
        if ($upn -match '^(.*)@([^@]+)$') { $suffix = $Matches[2]; $isSam = ($Matches[1] -ieq [string]$u.SamAccountName) }
        $rows.Add([ordered]@{ kind = 'user'; name = [string]$u.SamAccountName; ou = (Get-AdeOu ([string]$u.DistinguishedName) $Context); enabled = [bool]$u.Enabled; lastLogon = (Get-AdeDate $u.lastLogonTimestamp); upnSuffix = $suffix; upnIsSam = $isSam; adminCount = $u.adminCount; immutableId = [Convert]::ToBase64String(([guid]$u.ObjectGUID).ToByteArray()) })
    }
    $Report.counts = [ordered]@{ computers = $computers.Count; computersEnabled = @($computers | Where-Object { $_.Enabled }).Count; computersWithCert = $withCert; users = $users.Count; usersEnabled = @($users | Where-Object { $_.Enabled }).Count }
    $Report.total = $rows.Count; $Report.offset = $Start
    $page = [Collections.Generic.List[object]]::new()
    $budget = 7000 - [Text.Encoding]::UTF8.GetByteCount(($Report | ConvertTo-Json -Depth 8 -Compress))
    $i = $Start
    for (; $i -lt $rows.Count; $i++) {
        $size = [Text.Encoding]::UTF8.GetByteCount(($rows[$i] | ConvertTo-Json -Compress)) + 1
        if ($size -gt $budget) { break }
        $budget -= $size
        $page.Add($rows[$i])
    }
    $Report.rows = $page.ToArray()
    $Report.returned = $page.Count
    $Report.nextOffset = $null
    if ($i -lt $rows.Count) { $Report.nextOffset = $i }
}

function Get-AdeScpSection {
    param($Context, $Report)
    $Report.domain = $Context.DnsDomain
    Invoke-AdeStep $Report 'scp' {
        try { $o = Get-ADObject -Identity ($AdeScpCn + $Context.ConfigDN) -Properties keywords, whenChanged -Server $Context.Server -ErrorAction Stop }
        catch { if ($_.Exception.GetType().Name -match 'NotFound') { return [ordered]@{ exists = $false } }; throw }
        $scp = [ordered]@{ exists = $true; otherKeywords = 0 }
        foreach ($k in @($o.keywords)) {
            if ([string]$k -match '^(azureADId|azureADName):(.+)$') { $scp[$Matches[1]] = Protect-AdeText $Matches[2] -Max 100 } else { $scp.otherKeywords++ }
        }
        if ($o.whenChanged) { $scp.whenChanged = ([datetime]$o.whenChanged).ToUniversalTime().ToString('o') }
        $scp
    }
}

function Get-AdeReachSection {
    param($Context, $Report, [string]$Computer, [string[]]$ServiceNames)
    $fqdn = $Computer + '.' + $Context.DnsDomain
    $Report.name = $Computer
    Invoke-AdeStep $Report 'ad' {
        $all = @(Get-ADComputer -LDAPFilter "(sAMAccountName=$Computer$)" -Server $Context.Server -Properties dNSHostName, operatingSystem, lastLogon, lastLogonTimestamp, pwdLastSet, whenChanged, userCertificate, userAccountControl -ErrorAction Stop)
        if ($all.Count -eq 0) { return [ordered]@{ found = $false } }
        $c = $all[0]
        $iso = 'yyyy-MM-ddTHH:mm:ssZ'
        $changed = $null; if ($c.whenChanged) { $changed = ([datetime]$c.whenChanged).ToUniversalTime().ToString($iso) }
        [ordered]@{ found = $true; ou = (Get-AdeOu ([string]$c.DistinguishedName) $Context); dnsHostName = [string]$c.DNSHostName; os = [string]$c.OperatingSystem; enabled = [bool]$c.Enabled
            lastLogonThisDc = (Get-AdeDate $c.lastLogon $iso); lastLogonTimestamp = (Get-AdeDate $c.lastLogonTimestamp $iso); pwdLastSet = (Get-AdeDate $c.pwdLastSet $iso); whenChanged = $changed; certs = (Get-AdeCount $c.userCertificate); uac = [int]$c.userAccountControl }
    }
    Invoke-AdeStep $Report 'dnsResolve' -AsList { Resolve-DnsName -Name $fqdn -Type A -DnsOnly -ErrorAction Stop | Where-Object { $_.PSObject.Properties['IPAddress'] -and $_.IPAddress } | ForEach-Object { [string]$_.IPAddress } }
    Invoke-AdeStep $Report 'dnsRecord' {
        if (-not (Get-Command Get-DnsServerResourceRecord -ErrorAction SilentlyContinue)) { return [ordered]@{ status = 'noDnsRole' } }
        , @(Get-DnsServerResourceRecord -ZoneName $Context.DnsDomain -Name $Computer -ErrorAction Stop | ForEach-Object {
            $ts = 'static'; if ($_.Timestamp) { $ts = ([datetime]$_.Timestamp).ToUniversalTime().ToString('o') }
            $data = $null; if ($_.RecordData.PSObject.Properties['IPv4Address']) { $data = [string]$_.RecordData.IPv4Address }
            [ordered]@{ type = [string]$_.RecordType; data = $data; timestamp = $ts } })
    }
    Invoke-AdeStep $Report 'dhcp' {
        if (-not (Get-Command Get-DhcpServerv4Scope -ErrorAction SilentlyContinue)) { return [ordered]@{ status = 'noDhcpRole' } }
        , @(Get-DhcpServerv4Scope -ErrorAction Stop | ForEach-Object { Get-DhcpServerv4Lease -ScopeId $_.ScopeId -ErrorAction SilentlyContinue } |
            Where-Object { [string]$_.HostName -ieq $Computer -or [string]$_.HostName -ilike ($Computer + '.*') } | Select-Object -First 5 | ForEach-Object {
                $exp = $null; if ($_.LeaseExpiryTime) { $exp = ([datetime]$_.LeaseExpiryTime).ToUniversalTime().ToString('o') }
                [ordered]@{ ip = [string]$_.IPAddress; mac = [string]$_.ClientId; state = [string]$_.AddressState; expires = $exp } })
    }
    $ips = @()
    if ($Report.dnsResolve -is [array]) { $ips += @($Report.dnsResolve) }
    if ($Report.dhcp -is [array]) { $ips += @($Report.dhcp | ForEach-Object { $_.ip }) }
    $ips = @($ips | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' } | Select-Object -Unique -First 3)
    Invoke-AdeStep $Report 'probe' -AsList {
        foreach ($ip in $ips) {
            $o = [ordered]@{ ip = $ip; ping = (Test-AdePing $ip) }
            foreach ($port in 135, 445, 3389, 5985) { $o["tcp$port"] = [bool](Test-AdeTcp $ip $port) }
            $o.arp = @(Get-NetNeighbor -IPAddress $ip -ErrorAction SilentlyContinue | ForEach-Object { "$($_.LinkLayerAddress) $($_.State)" })
            $o
        }
    }
    Invoke-AdeStep $Report 'events' {
        $since = [datetime]::UtcNow.AddDays(-5).ToString('o')
        $xp = "*[System[(EventID=4768 or EventID=4624) and TimeCreated[@SystemTime>='$since']] and EventData[Data[@Name='TargetUserName']='$Computer$']]"
        try { $ev = @(Get-WinEvent -LogName Security -FilterXPath $xp -MaxEvents 400 -ErrorAction Stop) }
        catch { if ($_.FullyQualifiedErrorId -match 'NoMatchingEventsFound') { return [ordered]@{ count = 0 } }; throw }
        $newest = @($ev | Select-Object -First 8 | ForEach-Object {
            $d = @{}; foreach ($n in @(([xml]$_.ToXml()).Event.EventData.Data)) { $d[[string]$n.Name] = [string]$n.'#text' }
            [ordered]@{ t = $_.TimeCreated.ToUniversalTime().ToString('o'); id = $_.Id; ip = $d['IpAddress'] } })
        [ordered]@{ count = $ev.Count; newest = $newest; oldest = $ev[-1].TimeCreated.ToUniversalTime().ToString('o') }
    }
    Invoke-AdeStep $Report 'securityLogOldest' { (Get-WinEvent -LogName Security -MaxEvents 1 -Oldest -ErrorAction Stop).TimeCreated.ToUniversalTime().ToString('o') }
    $svc = [ordered]@{}
    foreach ($s in $ServiceNames) {
        Invoke-AdeStep $svc $s {
            $r = Invoke-AdeNative (Get-AdeSystemExe 'sc.exe') @("\\$fqdn", 'query', $s) 15
            if ($r.TimedOut) { return 'timeout' }
            Protect-AdeText ((@(([string]$r.Output) -split '\r?\n' | Where-Object { $_ -match 'STATE|FAILED|denied' } | ForEach-Object { $_.Trim() })) -join ' | ') -Max 200
        }
    }
    $Report.remoteService = $svc
}

function Invoke-AdEvidence {
    param([string]$Section = 'Inventory', [string]$SearchBase = '', [string]$Offset = '0', [string]$Name = '', [string]$Services = 'NinjaRMMAgent,ncstreamer', $Context)
    if ($Name) { $Section = 'Reach' }
    if (@('Inventory', 'Scp', 'Reach') -notcontains $Section) { throw 'Unknown section.' }
    $svc = @()
    if ($Section -eq 'Reach') {
        if ($Name -cnotmatch '^[A-Za-z0-9-]{1,15}\z') { throw 'Name must be a computer name of 1 to 15 letters, digits or hyphens.' }
        $svc = @($Services -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if ($svc.Count -lt 1 -or $svc.Count -gt 8 -or @($svc | Where-Object { $_ -cnotmatch '^[A-Za-z0-9_.-]{1,64}\z' }).Count) { throw 'Services must be 1 to 8 comma-separated service names.' }
    }
    $report = [ordered]@{ version = '1'; timestamp = [datetime]::UtcNow.ToString('o'); status = 'collected'; section = $Section }
    if (-not $Context) { $Context = Get-AdeContext }
    switch ($Section) {
        'Inventory' { $start = 0; [void][int]::TryParse($Offset, [ref]$start); Get-AdeInventorySection $Context $report $SearchBase ([Math]::Max(0, $start)) }
        'Scp' { Get-AdeScpSection $Context $report }
        'Reach' { Get-AdeReachSection $Context $report $Name $svc }
    }
    $report.elapsedSeconds = [Math]::Round($script:AdeClock.Elapsed.TotalSeconds, 1)
    return ConvertTo-AdeBoundedJson $report
}

if ($env:RELIAN_DEPLOY_TEST -eq '1' -and $MyInvocation.InvocationName -eq '.') { return }
if ($Action -eq 'Uninstall') { Write-Output '{"status":"nothingToUninstall"}'; exit 0 }
if (@('Install', 'Update', 'Repair', 'Reinstall') -notcontains $Action) { [Console]::Error.WriteLine('Unsupported action.'); exit 1 }
try { Write-Output (Invoke-AdEvidence -Section $Section -SearchBase $SearchBase -Offset $Offset -Name $Name -Services $Services); exit 0 }
catch { Write-Output (ConvertTo-AdeFailure $_); exit 1 }
