<#
.SYNOPSIS
    Read-only Group Policy evidence for a domain.
.DESCRIPTION
    Runs through the Relian deploy runner (NinjaOne script 374) as SYSTEM, Windows
    PowerShell 5.1, on a domain controller (or a member with GPMC/RSAT). Prints one
    line of JSON, at most 8,000 UTF-8 bytes, with "truncated" set when a list was cut.

    Package arguments (base64 JSON in -PackageArguments):
      Section  Summary (default), Gpos, Policy, Rsop or Gpo
      Gpo      GPO name or GUID; selects the Gpo section
      Offset   first row for the Gpos section (the previous run prints nextOffset)

    Summary  domain and forest functional levels, domain controllers, SYSVOL replication
             type (DFSR/FRS, migration state, DFSR service and recent DFSR warning event
             counts on a DC), GPO counts, AD/SYSVOL version mismatches, and GPOs whose
             Group Policy Preferences hold a cpassword.
    Gpos     every GPO: name, GUID, owner, created/modified, AD and SYSVOL versions with a
             mismatch flag, links (enabled/enforced), WMI filter, security filtering.
             Mismatches first, paged by Offset.
    Policy   Default Domain Policy and Default Domain Controllers Policy password, lockout
             and Kerberos values, the effective domain password policy, the number of
             fine-grained password policies, and the GPOs linked at the domain root.
    Rsop     gpresult /scope computer /x for this computer: applied and filtered GPOs and
             client-side extension status. The XML goes to a temp file that is deleted.
    Gpo      one GPO's Registry.pol values (machine and user), GptTmpl.inf, audit.csv,
             and Preferences files with a cpassword count.

    A cpassword is counted, never printed. Lines naming passwords, secrets, tokens or
    credentials are omitted. Nothing is changed: no GPO, AD, registry, service, custom
    field or policy refresh. New sections stop starting after 40 seconds.
#>
[CmdletBinding()]
param(
    [string]$DeploymentType,
    [string]$Action,
    [string]$PinVersion,
    [ValidateSet('Summary', 'Gpos', 'Policy', 'Rsop', 'Gpo')][string]$Section = 'Summary',
    [string]$Gpo = '',
    [string]$Offset = '0'
)
$ProgressPreference = 'SilentlyContinue'

$GpeDdp = '31B2F340-016D-11D2-945F-00C04FB984F9'
$GpeDdcp = '6AC1786C-016F-11D2-945F-00C04FB984F9'
$GpeSystemAccessKeys = @('MinimumPasswordAge', 'MaximumPasswordAge', 'MinimumPasswordLength', 'PasswordComplexity', 'PasswordHistorySize', 'LockoutBadCount', 'ResetLockoutCount', 'LockoutDuration', 'ClearTextPassword', 'RequireLogonToChangePassword', 'ForceLogoffWhenHourExpire', 'LSAAnonymousNameLookup', 'EnableAdminAccount', 'EnableGuestAccount')
$GpeKerberosKeys = @('MaxTicketAge', 'MaxRenewAge', 'MaxServiceAge', 'MaxClockSkew', 'TicketValidateClient')
$script:GpeClock = [Diagnostics.Stopwatch]::StartNew()

function Protect-GpeText {
    param([AllowEmptyString()][string]$Text, [int]$Max = 200)
    if ($Text -match '(?i)password|cpassword|passwd|secret|token|credential|bearer|api.?key') { return '[sensitive line omitted]' }
    $t = ($Text -replace '[\x00-\x1F]', ' ').Trim()
    if ($t.Length -gt $Max) { return $t.Substring(0, $Max) + '[clipped]' }
    return $t
}

function Find-GpeLargestArray {
    param($Value)
    $best = $null
    if ($Value -is [Collections.IDictionary]) {
        foreach ($k in @($Value.Keys)) {
            $item = $Value[$k]
            if ($item -is [array] -and $item.Count -gt 0 -and ($null -eq $best -or $item.Count -gt $best.Count)) { $best = @{ Container = $Value; Key = $k; Count = $item.Count } }
            $inner = Find-GpeLargestArray $item
            if ($inner -and ($null -eq $best -or $inner.Count -gt $best.Count)) { $best = $inner }
        }
    } elseif ($Value -is [array]) {
        foreach ($item in $Value) {
            $inner = Find-GpeLargestArray $item
            if ($inner -and ($null -eq $best -or $inner.Count -gt $best.Count)) { $best = $inner }
        }
    }
    return $best
}

# Drops entries from the longest list until the JSON fits, and says so with "truncated".
function ConvertTo-GpeBoundedJson {
    param($Report, [int]$MaxBytes = 8000)
    $json = $Report | ConvertTo-Json -Depth 8 -Compress
    while ([Text.Encoding]::UTF8.GetByteCount($json) -gt $MaxBytes) {
        $Report['truncated'] = $true
        $largest = Find-GpeLargestArray $Report
        if (-not $largest) { throw 'Report metadata exceeds the output budget.' }
        $keep = $largest.Count - [Math]::Max(1, [int][Math]::Ceiling($largest.Count / 8))
        $largest.Container[$largest.Key] = @($largest.Container[$largest.Key] | Select-Object -First $keep)
        $json = $Report | ConvertTo-Json -Depth 8 -Compress
    }
    return $json
}

function Get-GpeError { param($ErrorRecord) return @{ status = 'unavailable'; error = $ErrorRecord.Exception.GetType().Name } }

# gPLink: [LDAP://cn={GUID},cn=policies,...;options]; option bit 1 = disabled, bit 2 = enforced.
function ConvertFrom-GpeLinks {
    param([AllowEmptyString()][string]$GpLink)
    foreach ($m in [regex]::Matches([string]$GpLink, '(?i)\[LDAP://cn=\{([0-9a-f-]{36})\},[^;\]]*;(\d+)\]')) {
        $opt = [int]$m.Groups[2].Value
        [pscustomobject]@{ id = $m.Groups[1].Value.ToLowerInvariant(); enabled = (($opt -band 1) -eq 0); enforced = (($opt -band 2) -ne 0) }
    }
}

# Registry.pol ([MS-GPREG] 2.1): "PReg", version 1, then [key;value;type;size;data].
function Read-GpePol {
    param([byte[]]$Bytes, [int]$MaxEntries = 200)
    if ($Bytes.Length -lt 8 -or [Text.Encoding]::ASCII.GetString($Bytes, 0, 4) -ne 'PReg' -or [BitConverter]::ToUInt32($Bytes, 4) -ne 1) { throw 'Not a Registry.pol file.' }
    $u = [Text.Encoding]::Unicode
    $types = @{ 0 = 'REG_NONE'; 1 = 'REG_SZ'; 2 = 'REG_EXPAND_SZ'; 3 = 'REG_BINARY'; 4 = 'REG_DWORD'; 7 = 'REG_MULTI_SZ'; 11 = 'REG_QWORD' }
    $i = 8
    $readString = {
        $start = $i
        while ($i + 1 -lt $Bytes.Length -and ($Bytes[$i] -ne 0 -or $Bytes[$i + 1] -ne 0)) { $i += 2 }
        $s = $u.GetString($Bytes, $start, $i - $start)
        $i += 2
        return $s
    }
    $out = [Collections.Generic.List[object]]::new()
    while ($i + 2 -le $Bytes.Length -and $out.Count -lt $MaxEntries) {
        if ($u.GetString($Bytes, $i, 2) -ne '[') { throw 'Registry.pol entry is malformed.' }
        $i += 2
        $key = . $readString; $i += 2
        $name = . $readString; $i += 2
        $type = [BitConverter]::ToUInt32($Bytes, $i); $i += 6
        $size = [int][BitConverter]::ToUInt32($Bytes, $i); $i += 6
        if ($i + $size + 2 -gt $Bytes.Length) { throw 'Registry.pol entry is truncated.' }
        $data = $null
        switch ($type) {
            { $_ -eq 1 -or $_ -eq 2 } { $data = $u.GetString($Bytes, $i, $size).TrimEnd([char]0) }
            7 { $data = ($u.GetString($Bytes, $i, $size).TrimEnd([char]0) -split [char]0) -join '|' }
            4 { if ($size -ge 4) { $data = [BitConverter]::ToUInt32($Bytes, $i) } }
            11 { if ($size -ge 8) { $data = [BitConverter]::ToUInt64($Bytes, $i) } }
            default { $data = "$size bytes" }
        }
        $i += $size + 2
        $typeName = "type $type"; if ($types.ContainsKey([int]$type)) { $typeName = $types[[int]$type] }
        if ((Protect-GpeText "$key $name") -eq '[sensitive line omitted]') { $data = '[sensitive value omitted]' }
        elseif ($data -is [string]) { $data = Protect-GpeText $data }
        $out.Add([ordered]@{ key = (Protect-GpeText $key -Max 160); name = (Protect-GpeText $name -Max 80); type = $typeName; data = $data })
    }
    return $out.ToArray()
}

function ConvertFrom-GpeInf {
    param([AllowEmptyString()][string]$Text)
    $sections = [ordered]@{}
    $current = $null
    foreach ($line in ($Text -split '\r?\n')) {
        $t = $line.Trim()
        if (-not $t -or $t.StartsWith(';')) { continue }
        if ($t -match '^\[(.+)\]$') { $current = $Matches[1]; $sections[$current] = [Collections.Generic.List[string]]::new(); continue }
        if ($null -ne $current) { $sections[$current].Add($t) }
    }
    return $sections
}

function Get-GpeInfValues {
    param($Sections, [string]$Name, [string[]]$Keys)
    $r = [ordered]@{}
    if (-not $Sections.Contains($Name)) { return $r }
    foreach ($line in $Sections[$Name]) {
        if ($line -match '^([^=]+?)\s*=\s*(.*)$' -and $Keys -contains $Matches[1]) { $r[$Matches[1]] = $Matches[2] }
    }
    return $r
}

function Read-GpeText { param([string]$Path) if ([IO.File]::Exists($Path)) { return [IO.File]::ReadAllText($Path) } return $null }
function Get-GpeGpoDir { param($Context, $Id) Join-Path $Context.PoliciesPath ('{' + ([string]$Id).ToUpper() + '}') }

# Counts cpassword attributes in Preferences XML; the value is never kept. "complete" is
# false when the file cap stopped the scan, so a capped scan never reads as clean.
function Find-GpeCpassword {
    param([string]$PoliciesPath, $Ids, [int]$MaxFiles = 2000)
    $seen = 0
    $hits = [Collections.Generic.List[object]]::new()
    foreach ($id in @($Ids)) {
        foreach ($side in @('Machine', 'User')) {
            $dir = Join-Path (Join-Path $PoliciesPath ('{' + ([string]$id).ToUpper() + '}')) "$side\Preferences"
            if (-not (Test-Path -LiteralPath $dir)) { continue }
            foreach ($file in @(Get-ChildItem -LiteralPath $dir -Recurse -Filter '*.xml' -File -ErrorAction SilentlyContinue)) {
                if (++$seen -gt $MaxFiles) { return [pscustomobject]@{ hits = $hits.ToArray(); complete = $false; files = $MaxFiles } }
                $count = [regex]::Matches([IO.File]::ReadAllText($file.FullName), '(?i)\bcpassword="[^"]+"').Count
                if ($count) {
                    $relative = $side + '\Preferences\' + $file.FullName.Substring($dir.Length).TrimStart('\', '/')
                    $hits.Add([pscustomobject]@{ id = ([string]$id).ToLowerInvariant(); file = $relative; count = $count })
                }
            }
        }
    }
    return [pscustomobject]@{ hits = $hits.ToArray(); complete = $true; files = $seen }
}

function Read-GpeRsop {
    param([xml]$Xml)
    $node = { param($Parent, $Name) $n = $Parent.SelectSingleNode("*[local-name()='$Name']"); if ($n) { return $n.InnerText } return '' }
    $computer = $Xml.SelectSingleNode("//*[local-name()='ComputerResults']")
    if (-not $computer) { throw 'gpresult XML has no computer results.' }
    $r = [ordered]@{ som = (Protect-GpeText (& $node $computer 'SOM') -Max 160); site = (& $node $computer 'Site'); slowLink = ((& $node $computer 'SlowLink') -eq 'true'); applied = @(); notApplied = @(); extensions = @() }
    foreach ($g in @($computer.SelectNodes("*[local-name()='GPO']"))) {
        $link = $g.SelectSingleNode("*[local-name()='Link']")
        $som = ''; $order = 0
        if ($link) { $som = & $node $link 'SOMPath'; [void][int]::TryParse((& $node $link 'AppliedOrder'), [ref]$order) }
        $reason = $null
        if ((& $node $g 'AccessDenied') -eq 'true') { $reason = 'securityFilter' }
        elseif ((& $node $g 'FilterAllowed') -eq 'false') { $reason = 'wmiFilter' }
        elseif ((& $node $g 'Enabled') -eq 'false') { $reason = 'disabled' }
        elseif ((& $node $g 'IsValid') -eq 'false') { $reason = 'invalid' }
        elseif ($order -eq 0) { $reason = 'notApplied' }
        $row = [ordered]@{ name = (Protect-GpeText (& $node $g 'Name') -Max 80); som = (Protect-GpeText $som -Max 120) }
        if ($reason) { $row.reason = $reason; $r.notApplied += $row } else { $row.order = $order; $r.applied += $row }
    }
    $r.applied = @($r.applied | Sort-Object { $_.order })
    foreach ($e in @($computer.SelectNodes("*[local-name()='ExtensionStatus']"))) {
        $code = 0; [void][int]::TryParse((& $node $e 'Error'), [ref]$code)
        $r.extensions += [ordered]@{ name = (& $node $e 'Name'); error = $code; status = (& $node $e 'LoggingStatus') }
    }
    return $r
}

function Get-GpeContext {
    Import-Module GroupPolicy -ErrorAction Stop
    Import-Module ActiveDirectory -ErrorAction Stop
    $domain = Get-ADDomain -ErrorAction Stop
    $isDc = $false
    try { $isDc = [int](Get-CimInstance Win32_ComputerSystem -OperationTimeoutSec 5 -ErrorAction Stop).DomainRole -ge 4 } catch { }
    # One server for AD and SYSVOL reads: this DC, so a version mismatch shows its own
    # replication state, or the PDC emulator from a member.
    $server = [string]$domain.PDCEmulator; if ($isDc) { $server = $env:COMPUTERNAME }
    $forest = $null; try { $forest = Get-ADForest -ErrorAction Stop } catch { }
    $config = $null; try { $config = [string](Get-ADRootDSE -Server $server -ErrorAction Stop).configurationNamingContext } catch { }
    return @{ Domain = $domain; Forest = $forest; DomainDN = [string]$domain.DistinguishedName; ConfigDN = $config; IsDc = $isDc; Server = $server; PoliciesPath = "\\$server\SYSVOL\$($domain.DNSRoot)\Policies" }
}

function Get-GpeLinkMap {
    param($Context)
    $map = @{}
    $objects = @(Get-ADObject -LDAPFilter '(gPLink=*)' -Properties gPLink -Server $Context.Server -ErrorAction Stop)
    if ($Context.ConfigDN) { try { $objects += @(Get-ADObject -SearchBase ("CN=Sites," + $Context.ConfigDN) -LDAPFilter '(gPLink=*)' -Properties gPLink -Server $Context.Server -ErrorAction Stop) } catch { } }
    foreach ($o in $objects) {
        foreach ($l in @(ConvertFrom-GpeLinks ([string]$o.gPLink))) {
            if (-not $map.ContainsKey($l.id)) { $map[$l.id] = [Collections.Generic.List[object]]::new() }
            $map[$l.id].Add([ordered]@{ som = (Protect-GpeText ([string]$o.DistinguishedName) -Max 120); enabled = $l.enabled; enforced = $l.enforced })
        }
    }
    return $map
}

function Get-GpeVersionRow {
    param($G)
    $adU = [int]$G.User.DSVersion; $adC = [int]$G.Computer.DSVersion; $svU = [int]$G.User.SysvolVersion; $svC = [int]$G.Computer.SysvolVersion
    return [ordered]@{ ad = "u$adU/c$adC"; sysvol = "u$svU/c$svC"; mismatch = ($adU -ne $svU -or $adC -ne $svC) }
}

function Get-GpeSysvol {
    param($Context)
    $dn = $Context.DomainDN
    $exists = { param($Identity) try { [void](Get-ADObject -Identity $Identity -Server $Context.Server -ErrorAction Stop); return $true } catch { return $false } }
    $dfsr = & $exists "CN=Domain System Volume,CN=DFSR-GlobalSettings,CN=System,$dn"
    $frs = & $exists "CN=Domain System Volume (SYSVOL share),CN=File Replication Service,CN=System,$dn"
    $r = [ordered]@{ type = 'unknown'; dfsrObject = $dfsr; frsObject = $frs; migrationState = $null }
    if ($dfsr -and -not $frs) { $r.type = 'DFSR' } elseif ($frs -and -not $dfsr) { $r.type = 'FRS (deprecated)' } elseif ($frs -and $dfsr) { $r.type = 'migrating' }
    try {
        $flags = (Get-ADObject -Identity "CN=DFSR-GlobalSettings,CN=System,$dn" -Properties 'msDFSR-Flags' -Server $Context.Server -ErrorAction Stop).'msDFSR-Flags'
        $states = @{ 0 = 'Start'; 16 = 'Prepared'; 32 = 'Redirected'; 48 = 'Eliminated' }
        if ($null -ne $flags -and $states.ContainsKey([int]$flags)) { $r.migrationState = $states[[int]$flags] }
    } catch { }
    if ($Context.IsDc) {
        foreach ($svc in @('DFSR', 'NtFrs')) {
            try { $r["service$svc"] = [string](Get-Service -Name $svc -ErrorAction Stop).Status } catch { $r["service$svc"] = 'absent' }
        }
        # 2212/2213 dirty shutdown or paused, 4012 MaxOfflineTime exceeded, 5002/5008/5014 partner errors.
        try {
            $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'DFS Replication'; Id = @(2212, 2213, 4012, 5002, 5008, 5014); StartTime = [datetime]::Now.AddDays(-7) } -MaxEvents 500 -ErrorAction Stop)
            $counts = [ordered]@{}; foreach ($e in $events) { $counts[[string]$e.Id] = 1 + [int]$counts[[string]$e.Id] }
            $r.dfsrWarnings7d = $counts
        } catch { if ($_.FullyQualifiedErrorId -match 'NoMatchingEventsFound') { $r.dfsrWarnings7d = [ordered]@{} } else { $r.dfsrWarnings7d = Get-GpeError $_ } }
    }
    return $r
}

function Get-GpeSummary {
    param($Context, $Report)
    $d = $Context.Domain
    $Report.domain = [ordered]@{ dnsRoot = [string]$d.DNSRoot; netbios = [string]$d.NetBIOSName; mode = [string]$d.DomainMode; pdc = [string]$d.PDCEmulator; forestMode = $null }
    if ($Context.Forest) { $Report.domain.forestMode = [string]$Context.Forest.ForestMode }
    try {
        $Report.dcs = @(Get-ADDomainController -Filter * -ErrorAction Stop | Select-Object -First 20 | ForEach-Object {
                [ordered]@{ name = [string]$_.HostName; site = [string]$_.Site; os = [string]$_.OperatingSystem; gc = [bool]$_.IsGlobalCatalog; rodc = [bool]$_.IsReadOnly }
            })
    } catch { $Report.dcs = Get-GpeError $_ }
    try { $Report.sysvol = Get-GpeSysvol $Context } catch { $Report.sysvol = Get-GpeError $_ }
    $gpos = @(Get-GPO -All -Server $Context.Server -ErrorAction Stop)
    $mismatch = @($gpos | Where-Object { (Get-GpeVersionRow $_).mismatch })
    $Report.gpoCount = $gpos.Count
    $Report.allSettingsDisabled = @($gpos | Where-Object { [string]$_.GpoStatus -eq 'AllSettingsDisabled' }).Count
    $Report.versionMismatches = @($mismatch | Select-Object -First 15 | ForEach-Object { $v = Get-GpeVersionRow $_; [ordered]@{ name = (Protect-GpeText $_.DisplayName -Max 80); id = [string]$_.Id; ad = $v.ad; sysvol = $v.sysvol } })
    $Report.versionMismatchCount = $mismatch.Count
    $names = @{}; foreach ($g in $gpos) { $names[$g.Id.ToString().ToLowerInvariant()] = $g.DisplayName }
    $scan = Find-GpeCpassword -PoliciesPath $Context.PoliciesPath -Ids @($gpos | ForEach-Object { $_.Id })
    $Report.cpasswordScan = [ordered]@{ complete = $scan.complete; files = $scan.files }
    $Report.cpassword = @($scan.hits | ForEach-Object { [ordered]@{ gpo = (Protect-GpeText ([string]$names[$_.id]) -Max 80); id = $_.id; file = (Protect-GpeText $_.file -Max 120); count = $_.count } })
    try { $Report.unlinked = @($gpos).Count - @((Get-GpeLinkMap $Context).Keys).Count } catch { $Report.unlinked = Get-GpeError $_ }
}

function Get-GpeGposSection {
    param($Context, $Report, [int]$Start)
    $gpos = @(Get-GPO -All -Server $Context.Server -ErrorAction Stop | Sort-Object @{ Expression = { -not (Get-GpeVersionRow $_).mismatch } }, DisplayName)
    $links = Get-GpeLinkMap $Context
    $scan = Find-GpeCpassword -PoliciesPath $Context.PoliciesPath -Ids @($gpos | ForEach-Object { $_.Id })
    $cp = @{}; foreach ($h in @($scan.hits)) { $cp[$h.id] = [int]$cp[$h.id] + $h.count }
    $Report.cpasswordScanComplete = $scan.complete
    $Report.gpoTotal = $gpos.Count; $Report.offset = $Start
    $rows = [Collections.Generic.List[object]]::new()
    $budget = 7000 - [Text.Encoding]::UTF8.GetByteCount(($Report | ConvertTo-Json -Depth 8 -Compress))
    $i = $Start
    for (; $i -lt $gpos.Count; $i++) {
        $g = $gpos[$i]; $id = $g.Id.ToString().ToLowerInvariant(); $v = Get-GpeVersionRow $g
        $row = [ordered]@{ name = (Protect-GpeText $g.DisplayName -Max 80); id = $id; owner = (Protect-GpeText ([string]$g.Owner) -Max 60); created = $g.CreationTime.ToString('yyyy-MM-dd'); modified = $g.ModificationTime.ToString('yyyy-MM-dd'); status = [string]$g.GpoStatus; ad = $v.ad; sysvol = $v.sysvol; mismatch = $v.mismatch; wmi = $null; links = @(); apply = @(); deny = 0 }
        if ($g.WmiFilter) { $row.wmi = Protect-GpeText ([string]$g.WmiFilter.Name) -Max 60 }
        if ($links.ContainsKey($id)) { $row.links = @($links[$id] | Select-Object -First 6) }
        if ($cp.ContainsKey($id)) { $row.cpassword = $cp[$id] }
        if ($script:GpeClock.Elapsed.TotalSeconds -gt 40) { $row.apply = 'timeBudget' }
        else {
            try {
                $perm = @(Get-GPPermission -Guid $g.Id -All -Server $Context.Server -ErrorAction Stop)
                $row.apply = @($perm | Where-Object { [string]$_.Permission -eq 'GpoApply' -and -not $_.Denied } | Select-Object -First 4 | ForEach-Object { Protect-GpeText ([string]$_.Trustee.Name) -Max 60 })
                $row.deny = @($perm | Where-Object { $_.Denied }).Count
            } catch { $row.apply = 'unavailable' }
        }
        $size = [Text.Encoding]::UTF8.GetByteCount(($row | ConvertTo-Json -Depth 6 -Compress)) + 1
        if ($size -gt $budget) { break }
        $budget -= $size
        $rows.Add($row)
    }
    $Report.gpos = $rows.ToArray()
    $Report.returned = $rows.Count
    $Report.nextOffset = $null
    if ($i -lt $gpos.Count) { $Report.nextOffset = $i }
}

function Get-GpeDefaultPolicy {
    param($Context, [string]$Id)
    $text = Read-GpeText (Join-Path (Get-GpeGpoDir $Context $Id) 'MACHINE\Microsoft\Windows NT\SecEdit\GptTmpl.inf')
    if ($null -eq $text) { return [ordered]@{ status = 'missing' } }
    $inf = ConvertFrom-GpeInf $text
    return [ordered]@{ systemAccess = (Get-GpeInfValues $inf 'System Access' $GpeSystemAccessKeys); kerberos = (Get-GpeInfValues $inf 'Kerberos Policy' $GpeKerberosKeys); sections = @($inf.Keys) }
}

function Get-GpePolicySection {
    param($Context, $Report)
    $Report.defaultDomainPolicy = Get-GpeDefaultPolicy $Context $GpeDdp
    $Report.defaultDcPolicy = Get-GpeDefaultPolicy $Context $GpeDdcp
    try {
        $p = Get-ADDefaultDomainPasswordPolicy -ErrorAction Stop
        $Report.effective = [ordered]@{ MinPasswordLength = [int]$p.MinPasswordLength; PasswordHistoryCount = [int]$p.PasswordHistoryCount; ComplexityEnabled = [bool]$p.ComplexityEnabled
            MaxPasswordAgeDays = [Math]::Round($p.MaxPasswordAge.TotalDays, 2); MinPasswordAgeDays = [Math]::Round($p.MinPasswordAge.TotalDays, 2); LockoutThreshold = [int]$p.LockoutThreshold
            LockoutDurationMinutes = [Math]::Round($p.LockoutDuration.TotalMinutes, 2); LockoutObservationWindowMinutes = [Math]::Round($p.LockoutObservationWindow.TotalMinutes, 2); ReversibleEncryptionEnabled = [bool]$p.ReversibleEncryptionEnabled }
    } catch { $Report.effective = Get-GpeError $_ }
    try { $Report.fineGrainedPolicies = @(Get-ADFineGrainedPasswordPolicy -Filter * -ErrorAction Stop).Count } catch { $Report.fineGrainedPolicies = Get-GpeError $_ }
    try {
        $Report.domainRootLinks = @((Get-GPInheritance -Target $Context.DomainDN -Server $Context.Server -ErrorAction Stop).GpoLinks | ForEach-Object { [ordered]@{ name = (Protect-GpeText ([string]$_.DisplayName) -Max 80); order = [int]$_.Order; enabled = [bool]$_.Enabled; enforced = [bool]$_.Enforced } })
    } catch { $Report.domainRootLinks = Get-GpeError $_ }
}

function Get-GpeRsopSection {
    param($Report)
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('relian-gpresult-' + [guid]::NewGuid().ToString('n') + '.xml')
    try {
        & (Join-Path $env:SystemRoot 'System32\gpresult.exe') /scope computer /x $tmp /f 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { $Report.rsop = @{ status = 'failed'; exitCode = $LASTEXITCODE }; return }
        $Report.rsop = Read-GpeRsop ([xml][IO.File]::ReadAllText($tmp))
    } finally { if ([IO.File]::Exists($tmp)) { [IO.File]::Delete($tmp) } }
}

function Get-GpeGpoSection {
    param($Context, $Report, [string]$Target)
    try {
        if ($Target -match '^\{?[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\}?$') { $g = Get-GPO -Guid $Target.Trim('{', '}') -Server $Context.Server -ErrorAction Stop }
        else { $g = Get-GPO -Name $Target -Server $Context.Server -ErrorAction Stop }
    } catch [System.ArgumentException] { $Report.gpo = @{ status = 'notFound' }; return }
    $id = $g.Id.ToString().ToLowerInvariant(); $v = Get-GpeVersionRow $g
    $Report.gpo = [ordered]@{ name = (Protect-GpeText $g.DisplayName -Max 80); id = $id; status = [string]$g.GpoStatus; ad = $v.ad; sysvol = $v.sysvol; mismatch = $v.mismatch; links = @() }
    try { $map = Get-GpeLinkMap $Context; if ($map.ContainsKey($id)) { $Report.gpo.links = @($map[$id]) } } catch { $Report.gpo.links = Get-GpeError $_ }
    $dir = Get-GpeGpoDir $Context $id
    foreach ($side in @('Machine', 'User')) {
        $polPath = Join-Path $dir "$side\Registry.pol"
        $field = $side.ToLowerInvariant() + 'Pol'
        if (-not [IO.File]::Exists($polPath)) { $Report[$field] = @(); continue }
        try { $Report[$field] = @(Read-GpePol ([IO.File]::ReadAllBytes($polPath))) } catch { $Report[$field] = @{ status = 'invalid'; error = $_.Exception.Message } }
    }
    $inf = Read-GpeText (Join-Path $dir 'Machine\Microsoft\Windows NT\SecEdit\GptTmpl.inf')
    $Report.securityTemplate = [ordered]@{}
    if ($null -ne $inf) {
        $sections = ConvertFrom-GpeInf $inf
        foreach ($name in @($sections.Keys | Where-Object { $_ -ne 'Unicode' -and $_ -ne 'Version' })) { $Report.securityTemplate[$name] = @($sections[$name] | Select-Object -First 40 | ForEach-Object { Protect-GpeText $_ -Max 160 }) }
    }
    $Report.audit = @()
    $csv = Read-GpeText (Join-Path $dir 'Machine\Microsoft\Windows NT\Audit\audit.csv')
    if ($null -ne $csv) {
        $Report.audit = @($csv -split '\r?\n' | Where-Object { $_ -and -not $_.StartsWith('Machine Name,') } | Select-Object -First 60 | ForEach-Object {
                $f = $_.Split(','); if ($f.Count -ge 7) { [ordered]@{ subcategory = (Protect-GpeText $f[2] -Max 80); setting = (Protect-GpeText $f[4] -Max 40); value = $f[6] } }
            })
    }
    $scan = Find-GpeCpassword -PoliciesPath $Context.PoliciesPath -Ids @($id)
    $Report.cpasswordScanComplete = $scan.complete
    $hits = @{}; foreach ($h in @($scan.hits)) { $hits[$h.file] = $h.count }
    $Report.preferences = @()
    foreach ($side in @('Machine', 'User')) {
        $pref = Join-Path $dir "$side\Preferences"
        if (-not (Test-Path -LiteralPath $pref)) { continue }
        $Report.preferences += @(Get-ChildItem -LiteralPath $pref -Recurse -Filter '*.xml' -File -ErrorAction SilentlyContinue | Select-Object -First 30 | ForEach-Object {
                $rel = $side + '\Preferences\' + $_.FullName.Substring($pref.Length).TrimStart('\', '/')
                $n = 0; if ($hits.ContainsKey($rel)) { $n = $hits[$rel] }
                [ordered]@{ file = (Protect-GpeText $rel -Max 120); sizeBytes = $_.Length; cpassword = $n }
            })
    }
}

function Invoke-GpoEvidence {
    param([string]$Section = 'Summary', [string]$Gpo = '', [string]$Offset = '0', $Context)
    if ($Gpo) { $Section = 'Gpo' }
    if (@('Summary', 'Gpos', 'Policy', 'Rsop', 'Gpo') -notcontains $Section) { throw 'Unknown section.' }
    $report = [ordered]@{ version = '1'; timestamp = [datetime]::UtcNow.ToString('o'); status = 'collected'; section = $Section }
    if ($Section -eq 'Rsop') { Get-GpeRsopSection $report }
    else {
        if (-not $Context) { $Context = Get-GpeContext }
        switch ($Section) {
            'Summary' { Get-GpeSummary $Context $report }
            'Gpos' { $start = 0; [void][int]::TryParse($Offset, [ref]$start); Get-GpeGposSection $Context $report ([Math]::Max(0, $start)) }
            'Policy' { Get-GpePolicySection $Context $report }
            'Gpo' { if (-not $Gpo) { throw 'The Gpo section needs Gpo=<name or GUID>.' }; Get-GpeGpoSection $Context $report $Gpo }
        }
    }
    $report.elapsedSeconds = [Math]::Round($script:GpeClock.Elapsed.TotalSeconds, 1)
    return ConvertTo-GpeBoundedJson $report
}

if ($env:RELIAN_DEPLOY_TEST -eq '1' -and $MyInvocation.InvocationName -eq '.') { return }
if ($Action -eq 'Uninstall') { Write-Output '{"status":"nothingToUninstall"}'; exit 0 }
if (@('Install', 'Update', 'Repair', 'Reinstall') -notcontains $Action) { [Console]::Error.WriteLine('Unsupported action.'); exit 1 }
try { Write-Output (Invoke-GpoEvidence -Section $Section -Gpo $Gpo -Offset $Offset); exit 0 }
catch { Write-Output ('{"status":"failed","error":"' + $_.Exception.GetType().Name + '"}'); exit 1 }
