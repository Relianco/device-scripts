<#
.SYNOPSIS
    Read-only Group Policy evidence for a domain.
.DESCRIPTION
    Runs through the Relian deploy runner (NinjaOne script 374) as SYSTEM, Windows
    PowerShell 5.1, on a domain controller (or a member with GPMC/RSAT). Prints one
    line of JSON, at most 8,000 UTF-8 bytes, with "truncated" set when a list was cut.

    Package arguments (base64 JSON in -PackageArguments):
      Section  Summary (default), Gpos, Policy, Rsop, Gpo, Store, Profiles or Dc
      Gpo      GPO name or GUID; selects the Gpo section
      Offset   first row for the Gpos section (the previous run prints nextOffset)
      RsopUser sAMAccountName (1-20 of A-Z a-z 0-9 . _ -); selects the Rsop section for that
               user's scope (gpresult /user <NETBIOS>\<name> /scope user)

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
    Rsop     gpresult /scope computer /x for this computer (or /user for RsopUser): applied
             and filtered GPOs and client-side extension status. Needs no RSAT module, so it
             runs on a PC. The XML goes to a temp file that is deleted. A failure reports its
             stage, exception type and a redacted message.
    Gpo      one GPO's Registry.pol values (machine and user), GptTmpl.inf, audit.csv,
             Preferences files with a cpassword count, the folders in User\Documents &
             Settings\fdeploy.ini and fdeploy1.ini (redirected or not, target type, flags),
             and the script names in Machine and User scripts.ini (never their parameters).
    Store    whether Policies\PolicyDefinitions exists, its admx count, and the presence,
             date and revision of OneDrive.admx and en-US\OneDrive.adml.
    Profiles enabled users with profilePath, homeDirectory, homeDrive or scriptPath, grouped
             by path shape with the user name folded out; the GPOs that hold fdeploy files;
             the number of enabled users with badPwdCount above zero (read from one DC).
    Dc       DCs, FSMO holders, NTDS Settings objects, SERVER_TRUST computer objects, DFSR
             members and local replicated-folder state, the latest 4012 event and its
             partner, repadmin /showrepl failure count, the NS and SRV DC locator records,
             and every DC-like name that is not a live domain controller.

    A cpassword is counted, never printed. Lines naming passwords, secrets, tokens or
    credentials are omitted. Nothing is changed: no GPO, AD, registry, service, custom
    field or policy refresh. New sections and sources stop starting after 40 seconds.
#>
[CmdletBinding()]
param(
    [string]$DeploymentType,
    [string]$Action,
    [string]$PinVersion,
    [ValidateSet('Summary', 'Gpos', 'Policy', 'Rsop', 'Gpo', 'Store', 'Profiles', 'Dc')][string]$Section = 'Summary',
    [string]$Gpo = '',
    [string]$Offset = '0',
    [string]$RsopUser = ''
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

function Get-GpeError { param($ErrorRecord) return @{ status = 'unavailable'; error = $ErrorRecord.Exception.GetType().Name; message = (Protect-GpeText ([string]$ErrorRecord.Exception.Message) -Max 160) } }

# The failure line keeps the exception type, its inner type and the redacted message.
function ConvertTo-GpeFailure {
    param($ErrorRecord)
    $e = $ErrorRecord.Exception
    $line = [ordered]@{ status = 'failed'; error = $e.GetType().Name; message = (Protect-GpeText ([string]$e.Message) -Max 300) }
    if ($e.InnerException) { $line.inner = $e.InnerException.GetType().Name }
    return ($line | ConvertTo-Json -Compress)
}

# Runs one source of a section. Past 40 seconds it is not started; a failure is reported, not fatal.
function Invoke-GpeStep {
    param($Report, [string]$Key, [scriptblock]$Block, [switch]$AsList)
    if ($script:GpeClock.Elapsed.TotalSeconds -gt 40) { $Report[$Key] = @{ status = 'timeBudget' }; return }
    try { $v = & $Block; if ($AsList) { $v = @($v) }; $Report[$Key] = $v } catch { $Report[$Key] = Get-GpeError $_ }
}

function Get-GpeSystemExe { param([string]$Name) return [IO.Path]::Combine([string]$env:SystemRoot, 'System32', $Name) }

# Runs a native tool with a kill timer. Output is stdout plus stderr.
function Invoke-GpeNative {
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
    $truncated = $false
    while ($i + 2 -le $Bytes.Length) {
        if ($out.Count -ge $MaxEntries) { $truncated = $true; break }
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
    return [pscustomobject]@{ entries = $out.ToArray(); truncated = $truncated }
}

# First $Max items; sets truncated on the report when more were dropped.
function Limit-GpeItems {
    param($Items, [int]$Max, $Report)
    $all = @($Items)
    if ($all.Count -gt $Max) { $Report['truncated'] = $true }
    return @($all | Select-Object -First $Max)
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
    $errors = 0
    $hits = [Collections.Generic.List[object]]::new()
    foreach ($id in @($Ids)) {
        foreach ($side in @('Machine', 'User')) {
            $dir = Join-Path (Join-Path $PoliciesPath ('{' + ([string]$id).ToUpper() + '}')) "$side\Preferences"
            # Test-Path reports an access-denied folder as missing; only a real "not found" is skipped.
            try { [void](Get-Item -LiteralPath $dir -Force -ErrorAction Stop) }
            catch [System.Management.Automation.ItemNotFoundException] { continue }
            catch { $errors++; continue }
            $enumErrors = $null
            $files = @(Get-ChildItem -LiteralPath $dir -Recurse -Filter '*.xml' -File -ErrorAction SilentlyContinue -ErrorVariable enumErrors)
            # An unreadable subtree makes the scan incomplete, never clean.
            $errors += @($enumErrors).Count
            foreach ($file in $files) {
                if (++$seen -gt $MaxFiles) { return [pscustomobject]@{ hits = $hits.ToArray(); complete = $false; files = $MaxFiles; errors = $errors } }
                try { $text = [IO.File]::ReadAllText($file.FullName) } catch { $errors++; continue }
                try { $count = @(([xml]$text).SelectNodes("//@*[local-name()='cpassword']") | Where-Object { $_.Value }).Count }
                catch { $count = [regex]::Matches($text, '(?i)\bcpassword\s*=\s*("[^"]+"|''[^'']+'')').Count }
                if ($count) {
                    $relative = $side + '\Preferences\' + $file.FullName.Substring($dir.Length).TrimStart('\', '/')
                    $hits.Add([pscustomobject]@{ id = ([string]$id).ToLowerInvariant(); file = $relative; count = $count })
                }
            }
        }
    }
    return [pscustomobject]@{ hits = $hits.ToArray(); complete = ($errors -eq 0); files = $seen; errors = $errors }
}

# gpresult writes UTF-16, but a BOM-less or UTF-8 file that still declares utf-16 must load, and
# control characters from GPO text must not stop the parse. The reader works on a decoded string.
function Read-GpeXmlFile {
    param([string]$Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    $enc = [Text.Encoding]::UTF8
    if ($bytes.Length -ge 2) {
        if (($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) -or ($bytes[0] -eq 0x3C -and $bytes[1] -eq 0)) { $enc = [Text.Encoding]::Unicode }
        elseif (($bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) -or ($bytes[0] -eq 0 -and $bytes[1] -eq 0x3C)) { $enc = [Text.Encoding]::BigEndianUnicode }
    }
    $text = $enc.GetString($bytes).TrimStart([char]0xFEFF)
    $text = [regex]::Replace($text, '[\x00-\x08\x0B\x0C\x0E-\x1F\uFFFE\uFFFF]|&#(?:[xX]0*(?:[0-8bcefBCEF]|1[0-9a-fA-F])|0*(?:[0-8]|1[12]|1[4-9]|2[0-9]|3[01]));', ' ')
    $settings = [Xml.XmlReaderSettings]::new()
    $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $reader = [Xml.XmlReader]::Create([IO.StringReader]::new($text), $settings)
    try { $doc = [xml]::new(); $doc.Load($reader); return $doc } finally { $reader.Dispose() }
}

function Read-GpeRsop {
    param([xml]$Xml, [ValidateSet('Computer', 'User')][string]$Scope = 'Computer')
    $node = { param($Parent, $Name) $n = $Parent.SelectSingleNode("*[local-name()='$Name']"); if ($n) { return $n.InnerText } return '' }
    $computer = $Xml.SelectSingleNode("//*[local-name()='" + $Scope + "Results']")
    if (-not $computer) { throw ('gpresult XML has no ' + $Scope.ToLowerInvariant() + ' results.') }
    $r = [ordered]@{ scope = $Scope; som = (Protect-GpeText (& $node $computer 'SOM') -Max 160); site = (& $node $computer 'Site'); slowLink = ((& $node $computer 'SlowLink') -eq 'true'); applied = @(); notApplied = @(); extensions = @() }
    foreach ($g in @($computer.SelectNodes("*[local-name()='GPO']"))) {
        $link = $g.SelectSingleNode("*[local-name()='Link']")
        # AppliedOrder is read from the GPO element and from its Link; either layout counts.
        $som = ''; $order = 0; $linkOrder = 0
        [void][int]::TryParse((& $node $g 'AppliedOrder'), [ref]$order)
        if ($link) { $som = & $node $link 'SOMPath'; [void][int]::TryParse((& $node $link 'AppliedOrder'), [ref]$linkOrder) }
        $order = [Math]::Max($order, $linkOrder)
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
    # Accept both a flat ExtensionStatus record and ExtensionStatus/Extension children.
    $records = @()
    foreach ($s in @($computer.SelectNodes("*[local-name()='ExtensionStatus']"))) {
        $children = @($s.SelectNodes("*[local-name()='Extension']"))
        if ($children.Count) { $records += $children } else { $records += $s }
    }
    foreach ($e in $records) {
        $code = 0; [void][int]::TryParse((& $node $e 'Error'), [ref]$code)
        $r.extensions += [ordered]@{ name = (& $node $e 'Name'); error = $code; status = (& $node $e 'LoggingStatus') }
    }
    return $r
}

function Read-GpeRsopFile { param([string]$Path, [string]$Scope = 'Computer') return Read-GpeRsop (Read-GpeXmlFile $Path) $Scope }

# gpresult /user needs the NetBIOS domain of the joined domain. Domain Users of the joined DNS domain is
# translated to its SID and back, which names that domain explicitly; the first DNS label is the fallback.
function Get-GpeNetbiosDomain {
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem -OperationTimeoutSec 5 -ErrorAction Stop
    if (-not $cs.PartOfDomain) { throw 'This computer is not joined to a domain.' }
    $dns = [string]$cs.Domain
    try {
        $sid = ([Security.Principal.NTAccount]($dns + '\Domain Users')).Translate([Security.Principal.SecurityIdentifier])
        $name = $sid.Translate([Security.Principal.NTAccount]).Value
        if ($name -match '^([^\\]+)\\') { return $Matches[1] }
    } catch { }
    return $dns.Split('.')[0].ToUpperInvariant()
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
    param($Context, $Report)
    $map = @{}
    $objects = @(Get-ADObject -LDAPFilter '(gPLink=*)' -Properties gPLink -Server $Context.Server -ErrorAction Stop)
    if ($Context.ConfigDN) { try { $objects += @(Get-ADObject -SearchBase ("CN=Sites," + $Context.ConfigDN) -LDAPFilter '(gPLink=*)' -Properties gPLink -Server $Context.Server -ErrorAction Stop) } catch { $Report['notes'] = @($Report['notes']) + ('siteLinksUnavailable: ' + $_.Exception.GetType().Name) } }
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
        $Report.dcs = @(Limit-GpeItems (Get-ADDomainController -Filter * -ErrorAction Stop) 20 $Report | ForEach-Object {
                [ordered]@{ name = [string]$_.HostName; site = [string]$_.Site; os = [string]$_.OperatingSystem; gc = [bool]$_.IsGlobalCatalog; rodc = [bool]$_.IsReadOnly }
            })
    } catch { $Report.dcs = Get-GpeError $_ }
    try { $Report.sysvol = Get-GpeSysvol $Context } catch { $Report.sysvol = Get-GpeError $_ }
    $gpos = @(Get-GPO -All -Server $Context.Server -ErrorAction Stop)
    $mismatch = @($gpos | Where-Object { (Get-GpeVersionRow $_).mismatch })
    $Report.gpoCount = $gpos.Count
    $Report.allSettingsDisabled = @($gpos | Where-Object { [string]$_.GpoStatus -eq 'AllSettingsDisabled' }).Count
    $Report.versionMismatches = @(Limit-GpeItems $mismatch 15 $Report | ForEach-Object { $v = Get-GpeVersionRow $_; [ordered]@{ name = (Protect-GpeText $_.DisplayName -Max 80); id = [string]$_.Id; ad = $v.ad; sysvol = $v.sysvol } })
    $Report.versionMismatchCount = $mismatch.Count
    $names = @{}; foreach ($g in $gpos) { $names[$g.Id.ToString().ToLowerInvariant()] = $g.DisplayName }
    $scan = Find-GpeCpassword -PoliciesPath $Context.PoliciesPath -Ids @($gpos | ForEach-Object { $_.Id })
    $Report.cpasswordScan = [ordered]@{ complete = $scan.complete; files = $scan.files; errors = $scan.errors }
    $Report.cpassword = @($scan.hits | ForEach-Object { [ordered]@{ gpo = (Protect-GpeText ([string]$names[$_.id]) -Max 80); id = $_.id; file = (Protect-GpeText $_.file -Max 120); count = $_.count } })
    try { $map = Get-GpeLinkMap $Context $Report; $Report.unlinked = if ($Report['notes']) { $null } else { @($gpos | Where-Object { -not $map.ContainsKey($_.Id.ToString().ToLowerInvariant()) }).Count } } catch { $Report.unlinked = Get-GpeError $_ }
}

function Get-GpeGposSection {
    param($Context, $Report, [int]$Start)
    $gpos = @(Get-GPO -All -Server $Context.Server -ErrorAction Stop | Sort-Object @{ Expression = { -not (Get-GpeVersionRow $_).mismatch } }, DisplayName)
    $links = Get-GpeLinkMap $Context $Report
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
        if ($links.ContainsKey($id)) { $row.links = @(Limit-GpeItems $links[$id] 6 $Report); $row.linkCount = $links[$id].Count }
        if ($cp.ContainsKey($id)) { $row.cpassword = $cp[$id] }
        if ($script:GpeClock.Elapsed.TotalSeconds -gt 40) { $row.apply = 'timeBudget' }
        else {
            try {
                $perm = @(Get-GPPermission -Guid $g.Id -All -Server $Context.Server -ErrorAction Stop)
                $applyAll = @($perm | Where-Object { [string]$_.Permission -eq 'GpoApply' -and -not $_.Denied })
                $row.apply = @(Limit-GpeItems $applyAll 4 $Report | ForEach-Object { Protect-GpeText ([string]$_.Trustee.Name) -Max 60 })
                $row.applyCount = $applyAll.Count
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
    param($Report, [string]$User = '')
    $scope = 'Computer'; $gp = @('/scope', 'computer')
    if ($User) { $scope = 'User'; $gp = @('/user', ((Get-GpeNetbiosDomain) + '\' + $User), '/scope', 'user') }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('relian-gpresult-' + [guid]::NewGuid().ToString('n') + '.xml')
    $stage = 'run'
    try {
        $run = Invoke-GpeNative (Get-GpeSystemExe 'gpresult.exe') ($gp + @('/x', $tmp, '/f')) 30
        if ($run.TimedOut) { $Report.rsop = [ordered]@{ status = 'timeout' }; return }
        if ($run.ExitCode -ne 0) { $Report.rsop = [ordered]@{ status = 'failed'; stage = 'run'; exitCode = $run.ExitCode; message = (Protect-GpeText ([string]$run.Output -replace '\s+', ' ') -Max 240) }; return }
        $stage = 'parse'
        $xml = Read-GpeXmlFile $tmp
        $stage = 'summarize'
        $Report.rsop = Read-GpeRsop $xml $scope
    } catch {
        $Report.rsop = [ordered]@{ status = 'failed'; stage = $stage; error = $_.Exception.GetType().Name; message = (Protect-GpeText ([string]$_.Exception.Message) -Max 240) }
    } finally { if ([IO.File]::Exists($tmp)) { [IO.File]::Delete($tmp) } }
}

# Folder Redirection. fdeploy.ini: [FolderStatus] gives each folder's state, then a section per folder
# holds "<group sid>=<target path>" lines and Flags. fdeploy1.ini (version one, [Folder_Redirection]):
# "{known folder guid}=<sid>;<sid>" lines, then a "[{guid}_<sid>]" section with Flags and FullPath.
# Type: home when the target uses a home variable. A target with no path (a follow-parent entry) is not redirected.
$GpeKnownFolders = @{ 'FDD39AD0-238F-46AF-ADB4-6C85480369C7' = 'Documents'; '33E28130-4E1E-4676-835A-98395C3BC3BB' = 'Pictures'; 'B4BFCC3A-DB2C-424C-B029-7FE99A87C641' = 'Desktop'
    '3EB685DB-65F9-4CF6-A03A-E3EF65729F3D' = 'AppData(Roaming)'; '625B53C3-AB48-4EC1-BA1F-A1EF4146FC19' = 'Start Menu'; '4BD8D571-6D19-48D3-BE97-422220080E43' = 'Music'
    '18989B1D-99B5-455B-841C-AB7C74E4DDFC' = 'Videos'; '374DE290-123F-4565-9164-39C4925E467B' = 'Downloads'; '56784854-C6CB-462B-8169-88E350ACB882' = 'Contacts'
    '1777F761-68AD-4D8A-87BD-30B759FA33DD' = 'Favorites'; 'BFB9D5E0-C6A9-404C-B2B2-AE6DB6AF4968' = 'Links'; '4C5C32FF-BB9D-43B0-B5B4-2D72E54EAAA4' = 'Saved Games'; '7D1D3A04-DEBB-4115-95CF-2F29DA2920DA' = 'Searches' }

function ConvertTo-GpeFdeployTarget {
    param([string]$Sid, [string]$Path, $Flags)
    $type = 'local'
    if ($Path -match '(?i)%home(share|path|drive)%') { $type = 'home' } elseif ($Path.StartsWith('\\')) { $type = 'unc' }
    return [ordered]@{ sid = (Protect-GpeText $Sid -Max 60); type = $type; path = (Protect-GpeText $Path -Max 120); flags = $Flags }
}

function ConvertTo-GpeFdeployRow {
    param([string]$Folder, $Status, $Targets)
    $flags = $null; foreach ($t in $Targets) { if ($null -eq $flags -and $null -ne $t.flags) { $flags = $t.flags } }
    $withPath = @($Targets | Where-Object { $_.path })
    return [ordered]@{ folder = (Protect-GpeText $Folder -Max 40); status = $Status; redirected = ($withPath.Count -gt 0 -and $Status -ne 0); flags = $flags; targetCount = $Targets.Count; targets = @($Targets | Select-Object -First 3) }
}

function Read-GpeFdeploy {
    param([AllowEmptyString()][string]$Text)
    $ini = ConvertFrom-GpeInf $Text
    $get = { param($Name) foreach ($k in @($ini.Keys)) { if ($k -ieq $Name) { return ,$ini[$k] } } return ,@() }
    $kv = { param($Lines) $h = [ordered]@{}; foreach ($l in $Lines) { if ($l -match '^([^=]+?)\s*=\s*(.*)$') { $h[$Matches[1]] = $Matches[2] } }; return $h }
    if ($ini.Keys | Where-Object { $_ -ieq 'Folder_Redirection' }) {
        $map = & $kv (& $get 'Folder_Redirection')
        foreach ($guid in @($map.Keys)) {
            $name = [string]$guid; $bare = $name.Trim('{', '}').ToUpperInvariant()
            if ($GpeKnownFolders.ContainsKey($bare)) { $name = $GpeKnownFolders[$bare] }
            $targets = [Collections.Generic.List[object]]::new()
            foreach ($sid in @($map[$guid] -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
                $sec = & $kv (& $get ($guid + '_' + $sid))
                $path = ''; if ($sec.Contains('FullPath')) { $path = $sec['FullPath'] } elseif ($sec.Contains('RelativePath')) { $path = ([string]$sec['ParentFolder'] + '\' + $sec['RelativePath']).TrimStart('\') }
                $flags = $null; if ($sec.Contains('Flags')) { $flags = $sec['Flags'] }
                $targets.Add((ConvertTo-GpeFdeployTarget $sid $path $flags))
            }
            ConvertTo-GpeFdeployRow $name $null $targets
        }
        return
    }
    $status = [ordered]@{}
    foreach ($e in (& $kv (& $get 'FolderStatus')).GetEnumerator()) { $n = 0; if ([int]::TryParse($e.Value, [ref]$n)) { $status[$e.Key] = $n } }
    $names = [Collections.Generic.List[string]]::new()
    foreach ($n in @($status.Keys) + @($ini.Keys | Where-Object { $_ -ne 'FolderStatus' })) { if (-not $names.Contains($n)) { $names.Add($n) } }
    foreach ($name in $names) {
        $targets = [Collections.Generic.List[object]]::new(); $flags = $null
        foreach ($e in (& $kv (& $get $name)).GetEnumerator()) { if ($e.Key -eq 'Flags') { $flags = $e.Value } else { $targets.Add((ConvertTo-GpeFdeployTarget $e.Key $e.Value $null)) } }
        $st = $null; if ($status.Contains($name)) { $st = $status[$name] }
        $row = ConvertTo-GpeFdeployRow $name $st $targets
        $row.flags = $flags
        $row
    }
}

# scripts.ini: "<n>CmdLine=<path>" under [Logon], [Logoff], [Startup], [Shutdown]. Names only; the
# parameters are never read into the report, and anything after the script path in CmdLine is cut off.
function Read-GpeScriptsIni {
    param([AllowEmptyString()][string]$Text, [string]$Side)
    $ini = ConvertFrom-GpeInf $Text
    foreach ($ev in @($ini.Keys)) {
        foreach ($l in $ini[$ev]) {
            if ($l -match '^\d+CmdLine\s*=\s*(.+)$') { $c = $Matches[1].Trim(); if ($c -match '^"([^"]*)"') { $c = $Matches[1] } elseif ($c -match '(?i)^(.*?\.(?:bat|cmd|vbs|vbe|ps1|js|wsf|exe|com|msi|lnk))(?:\s|$)') { $c = $Matches[1] } else { $c = ($c -split '\s+')[0] }
                [ordered]@{ side = $Side; event = (Protect-GpeText $ev -Max 20); name = (Protect-GpeText (($c -split '[\\/]')[-1]) -Max 80) } }
        }
    }
}

function Get-GpeGpoSection {
    param($Context, $Report, [string]$Target)
    try {
        if ($Target -match '^\{?[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\}?$') { $g = Get-GPO -Guid $Target.Trim('{', '}') -Server $Context.Server -ErrorAction Stop }
        else { $g = Get-GPO -Name $Target -Server $Context.Server -ErrorAction Stop }
    } catch [System.ArgumentException] { $Report.gpo = @{ status = 'notFound' }; return }
    $id = $g.Id.ToString().ToLowerInvariant(); $v = Get-GpeVersionRow $g
    $Report.gpo = [ordered]@{ name = (Protect-GpeText $g.DisplayName -Max 80); id = $id; status = [string]$g.GpoStatus; ad = $v.ad; sysvol = $v.sysvol; mismatch = $v.mismatch; links = @() }
    try { $map = Get-GpeLinkMap $Context $Report; if ($map.ContainsKey($id)) { $Report.gpo.links = @($map[$id]) } } catch { $Report.gpo.links = Get-GpeError $_ }
    $dir = Get-GpeGpoDir $Context $id
    foreach ($side in @('Machine', 'User')) {
        $polPath = Join-Path $dir "$side\Registry.pol"
        $field = $side.ToLowerInvariant() + 'Pol'
        if (-not [IO.File]::Exists($polPath)) { $Report[$field] = @(); continue }
        try { $pol = Read-GpePol ([IO.File]::ReadAllBytes($polPath)); $Report[$field] = @($pol.entries); if ($pol.truncated) { $Report['truncated'] = $true } } catch { $Report[$field] = @{ status = 'invalid'; error = $_.Exception.Message } }
    }
    $inf = Read-GpeText (Join-Path $dir 'Machine\Microsoft\Windows NT\SecEdit\GptTmpl.inf')
    $Report.securityTemplate = [ordered]@{}
    if ($null -ne $inf) {
        $sections = ConvertFrom-GpeInf $inf
        foreach ($name in @($sections.Keys | Where-Object { $_ -ne 'Unicode' -and $_ -ne 'Version' })) { $Report.securityTemplate[$name] = @(Limit-GpeItems $sections[$name] 40 $Report | ForEach-Object { Protect-GpeText $_ -Max 160 }) }
    }
    $Report.audit = @()
    $csv = Read-GpeText (Join-Path $dir 'Machine\Microsoft\Windows NT\Audit\audit.csv')
    if ($null -ne $csv) {
        $Report.audit = @(Limit-GpeItems @($csv -split '\r?\n' | Where-Object { $_ -and -not $_.StartsWith('Machine Name,') }) 60 $Report | ForEach-Object {
                $f = $_.Split(','); if ($f.Count -ge 7) { [ordered]@{ subcategory = (Protect-GpeText $f[2] -Max 80); setting = (Protect-GpeText $f[4] -Max 40); value = $f[6] } }
            })
    }
    $Report.folderRedirection = @(); $Report.scripts = @()
    try {
        foreach ($file in @('fdeploy.ini', 'fdeploy1.ini')) {
            $text = Read-GpeText (Join-Path $dir "User\Documents & Settings\$file")
            if ($null -ne $text) { $Report.folderRedirection += [ordered]@{ file = $file; folders = @(Read-GpeFdeploy $text) } }
        }
        foreach ($side in @('Machine', 'User')) {
            $text = Read-GpeText (Join-Path $dir "$side\Scripts\scripts.ini")
            if ($null -ne $text) { $Report.scripts += @(Limit-GpeItems @(Read-GpeScriptsIni $text $side) 30 $Report) }
        }
    } catch { $Report.folderRedirection = Get-GpeError $_ }
    $scan = Find-GpeCpassword -PoliciesPath $Context.PoliciesPath -Ids @($id)
    $Report.cpasswordScanComplete = $scan.complete
    $hits = @{}; foreach ($h in @($scan.hits)) { $hits[$h.file] = $h.count }
    $Report.preferences = @()
    foreach ($side in @('Machine', 'User')) {
        $pref = Join-Path $dir "$side\Preferences"
        if (-not (Test-Path -LiteralPath $pref)) { continue }
        $Report.preferences += @(Limit-GpeItems @(Get-ChildItem -LiteralPath $pref -Recurse -Filter '*.xml' -File -ErrorAction SilentlyContinue) 30 $Report | ForEach-Object {
                $rel = $side + '\Preferences\' + $_.FullName.Substring($pref.Length).TrimStart('\', '/')
                $n = 0; if ($hits.ContainsKey($rel)) { $n = $hits[$rel] }
                [ordered]@{ file = (Protect-GpeText $rel -Max 120); sizeBytes = $_.Length; cpassword = $n }
            })
    }
}

function Get-GpeStoreFile {
    param([string]$Path)
    if (-not [IO.File]::Exists($Path)) { return [ordered]@{ present = $false } }
    $rev = $null
    try { if ([IO.File]::ReadAllText($Path) -match '(?is)<policyDefinition\w*\s[^>]*?revision\s*=\s*"([^"]{1,16})"') { $rev = $Matches[1] } } catch { }
    return [ordered]@{ present = $true; date = [IO.File]::GetLastWriteTimeUtc($Path).ToString('yyyy-MM-dd'); revision = $rev }
}

function Get-GpeStoreSection {
    param($Context, $Report)
    $dir = Join-Path $Context.PoliciesPath 'PolicyDefinitions'
    $Report.store = [ordered]@{ exists = [IO.Directory]::Exists($dir); admxCount = 0 }
    if (-not $Report.store.exists) { return }
    $Report.store.admxCount = @([IO.Directory]::GetFiles($dir, '*.admx')).Count
    $Report.store.languages = @(Limit-GpeItems @([IO.Directory]::GetDirectories($dir) | ForEach-Object { [IO.Path]::GetFileName($_) }) 30 $Report)
    $Report.store.oneDriveAdmx = Get-GpeStoreFile (Join-Path $dir 'OneDrive.admx')
    $Report.store.oneDriveAdml = Get-GpeStoreFile (Join-Path $dir 'en-US\OneDrive.adml')
}

# Path with each segment that is the user's name (or name$ or name.V2) folded to <user>.
function Get-GpePathShape {
    param([string]$Path, [string]$Sam)
    $parts = foreach ($s in ($Path -split '\\')) { if ($Sam -and ($s -ieq $Sam -or $s -ieq ($Sam + '$') -or $s -ilike ($Sam + '.V*'))) { '<user>' } else { $s } }
    return ($parts -join '\')
}

function Get-GpeShapeSummary {
    param($Users, [string]$Attr, $Report)
    $with = @($Users | Where-Object { $_.$Attr })
    $groups = @($with | Group-Object { Get-GpePathShape ([string]$_.$Attr) ([string]$_.SamAccountName) } | Sort-Object @{ Expression = 'Count'; Descending = $true }, Name)
    return [ordered]@{ count = $with.Count; shapes = @(Limit-GpeItems $groups 8 $Report | ForEach-Object { [ordered]@{ shape = (Protect-GpeText ([string]$_.Name) -Max 120); count = $_.Count } }) }
}

function Get-GpeProfilesSection {
    param($Context, $Report)
    $users = @(Get-ADUser -LDAPFilter '(&(objectCategory=person)(objectClass=user)(!(userAccountControl:1.2.840.113556.1.4.803:=2)))' -Properties profilePath, homeDirectory, homeDrive, scriptPath, badPwdCount -Server $Context.Server -ResultPageSize 500 -ErrorAction Stop)
    $p = [ordered]@{ enabledUsers = $users.Count }
    foreach ($a in @('profilePath', 'homeDirectory', 'homeDrive', 'scriptPath')) { $p[$a] = Get-GpeShapeSummary $users $a $Report }
    $p.badPwdCountAboveZero = @($users | Where-Object { [int]$_.badPwdCount -gt 0 }).Count
    $p.badPwdCountNote = 'one DC only; the count is not replicated'
    $Report.profiles = $p
    $Report.fdeployScanComplete = $false
    Invoke-GpeStep $Report 'fdeployGpos' -AsList {
        $stopped = $false
        foreach ($g in @(Get-GPO -All -Server $Context.Server -ErrorAction Stop)) {
            if ($script:GpeClock.Elapsed.TotalSeconds -gt 40) { $stopped = $true; break }
            $d = Get-GpeGpoDir $Context $g.Id
            $found = @('fdeploy.ini', 'fdeploy1.ini' | Where-Object { [IO.File]::Exists((Join-Path $d "User\Documents & Settings\$_")) })
            if ($found.Count) { [ordered]@{ name = (Protect-GpeText $g.DisplayName -Max 80); id = $g.Id.ToString().ToLowerInvariant(); files = $found } }
        }
        $Report.fdeployScanComplete = -not $stopped
    }
}

function Get-GpeShortName { param([string]$Name) return ($Name.Split('.')[0]).ToLowerInvariant() }

# repadmin /showrepl /csv: one showrepl_INFO row per inbound link; "Number of Failures" above zero is an error.
function Get-GpeRepadmin {
    $r = Invoke-GpeNative (Get-GpeSystemExe 'repadmin.exe') @('/showrepl', '/csv') 20
    if ($r.TimedOut) { return [ordered]@{ status = 'timeout' } }
    $lines = @(([string]$r.Output) -split '\r?\n')
    $head = @($lines | Where-Object { $_ -like 'showrepl_COLUMNS,*' })[0]
    if (-not $head) { return [ordered]@{ status = 'unparsed'; exitCode = $r.ExitCode } }
    $rows = @((@($head) + @($lines | Where-Object { $_ -like 'showrepl_INFO,*' })) | ConvertFrom-Csv)
    $bad = @($rows | Where-Object { [int]$_.'Number of Failures' -gt 0 })
    return [ordered]@{ rows = $rows.Count; failing = $bad.Count; failingSources = @($bad | ForEach-Object { Protect-GpeText ([string]$_.'Source DSA') -Max 40 } | Sort-Object -Unique | Select-Object -First 10) }
}

function Get-GpeDcSection {
    param($Context, $Report)
    $d = $Context.Domain; $f = $Context.Forest; $dn = $Context.DomainDN; $srv = $Context.Server
    $Report.fsmo = [ordered]@{ pdc = [string]$d.PDCEmulator; rid = [string]$d.RIDMaster; infrastructure = [string]$d.InfrastructureMaster; schema = $null; naming = $null }
    $dnsRoot = [string]$d.DNSRoot
    if ($f) { $Report.fsmo.schema = [string]$f.SchemaMaster; $Report.fsmo.naming = [string]$f.DomainNamingMaster; if ($f.RootDomain) { $dnsRoot = [string]$f.RootDomain } }
    # The live set covers every domain of the forest; if one cannot be read, stale candidates are not computed.
    $script:GpeLive = $null
    Invoke-GpeStep $Report 'dcs' -AsList {
        $all = @(Get-ADDomainController -Filter * -ErrorAction Stop)
        $live = @($all | ForEach-Object { Get-GpeShortName ([string]$_.HostName) })
        if ($f -and $f.PSObject.Properties['Domains']) {
            foreach ($dom in @($f.Domains | Where-Object { [string]$_ -ne [string]$d.DNSRoot })) {
                try { $live += @(Get-ADDomainController -Filter * -Server ([string]$dom) -ErrorAction Stop | ForEach-Object { Get-GpeShortName ([string]$_.HostName) }) } catch { $live = $null; break }
            }
        }
        $script:GpeLive = $live
        Limit-GpeItems $all 20 $Report | ForEach-Object { [ordered]@{ name = [string]$_.HostName; site = [string]$_.Site; os = (Protect-GpeText ([string]$_.OperatingSystem) -Max 40); gc = [bool]$_.IsGlobalCatalog; rodc = [bool]$_.IsReadOnly } } }
    Invoke-GpeStep $Report 'ntds' -AsList {
        Limit-GpeItems (Get-ADObject -SearchBase ('CN=Sites,' + $Context.ConfigDN) -LDAPFilter '(objectClass=nTDSDSA)' -Server $srv -ErrorAction Stop) 20 $Report | ForEach-Object {
            if ([string]$_.DistinguishedName -match '^CN=NTDS Settings,CN=([^,]+),CN=Servers,CN=([^,]+),') { [ordered]@{ server = (Protect-GpeText $Matches[1] -Max 40); site = (Protect-GpeText $Matches[2] -Max 40) } }
        }
    }
    Invoke-GpeStep $Report 'serverTrust' -AsList {
        Limit-GpeItems (Get-ADComputer -LDAPFilter '(userAccountControl:1.2.840.113556.1.4.803:=8192)' -Properties Enabled, LastLogonTimestamp, OperatingSystem -Server $srv -ErrorAction Stop) 20 $Report | ForEach-Object {
            $ll = $null; if ($_.LastLogonTimestamp) { $ll = [datetime]::FromFileTimeUtc([int64]$_.LastLogonTimestamp).ToString('yyyy-MM-dd') }
            [ordered]@{ name = (Protect-GpeText ([string]$_.Name) -Max 40); enabled = [bool]$_.Enabled; lastLogon = $ll; os = (Protect-GpeText ([string]$_.OperatingSystem) -Max 40) }
        }
    }
    Invoke-GpeStep $Report 'dfsrMembers' -AsList {
        Limit-GpeItems (Get-ADObject -SearchBase "CN=Domain System Volume,CN=DFSR-GlobalSettings,CN=System,$dn" -LDAPFilter '(objectClass=msDFSR-Member)' -Server $srv -ErrorAction Stop) 20 $Report | ForEach-Object { Protect-GpeText ([string]$_.Name) -Max 40 }
    }
    if ($Context.IsDc) {
        Invoke-GpeStep $Report 'dfsrLocal' -AsList {
            $states = @{ 0 = 'Uninitialized'; 1 = 'Initialized'; 2 = 'InitialSync'; 3 = 'AutoRecovery'; 4 = 'Normal'; 5 = 'InError' }
            Get-CimInstance -Namespace 'root\MicrosoftDFS' -ClassName DfsrReplicatedFolderInfo -OperationTimeoutSec 5 -ErrorAction Stop | ForEach-Object {
                $s = "state $($_.State)"; if ($states.ContainsKey([int]$_.State)) { $s = $states[[int]$_.State] }
                [ordered]@{ folder = (Protect-GpeText ([string]$_.ReplicatedFolderName) -Max 40); state = $s }
            }
        }
        Invoke-GpeStep $Report 'last4012' {
            try { $e = @(Get-WinEvent -FilterHashtable @{ LogName = 'DFS Replication'; Id = 4012 } -MaxEvents 1 -ErrorAction Stop)[0] }
            catch { if ($_.FullyQualifiedErrorId -match 'NoMatchingEventsFound') { return [ordered]@{ found = $false } }; throw }
            $partner = $null; if ([string]$e.Message -match '(?i)partner[^:\r\n]*:\s*(\S+)') { $partner = Protect-GpeText $Matches[1] -Max 80 }
            [ordered]@{ found = $true; time = $e.TimeCreated.ToUniversalTime().ToString('yyyy-MM-dd HH:mm'); partner = $partner; message = (Protect-GpeText (([string]$e.Message) -replace '\s+', ' ') -Max 240) }
        }
        Invoke-GpeStep $Report 'repadmin' { Get-GpeRepadmin }
    }
    Invoke-GpeStep $Report 'dnsNs' -AsList { Resolve-DnsName -Name ('_msdcs.' + $dnsRoot) -Type NS -Server $srv -DnsOnly -ErrorAction Stop | Where-Object { $_.NameHost } | ForEach-Object { Protect-GpeText ([string]$_.NameHost) -Max 80 } }
    Invoke-GpeStep $Report 'dnsSrv' -AsList { Resolve-DnsName -Name ('_ldap._tcp.dc._msdcs.' + [string]$d.DNSRoot) -Type SRV -Server $srv -DnsOnly -ErrorAction Stop | Where-Object { $_.NameTarget } | ForEach-Object { Protect-GpeText ([string]$_.NameTarget) -Max 80 } }
    # Any name that shows up as a DC in some source but is not a live domain controller.
    if ($null -ne $script:GpeLive) {
        $live = @{}; foreach ($x in $script:GpeLive) { $live[[string]$x] = $true }
        $seen = [ordered]@{}
        $sources = @(@('ntds', 'server'), @('trust', 'name'), @('dfsr', ''), @('ns', ''), @('srv', ''))
        $lists = @($Report.ntds, $Report.serverTrust, $Report.dfsrMembers, $Report.dnsNs, $Report.dnsSrv)
        for ($i = 0; $i -lt $lists.Count; $i++) {
            if ($lists[$i] -isnot [array]) { continue }
            foreach ($x in $lists[$i]) {
                $name = [string]$x; if ($sources[$i][1]) { $name = [string]$x.($sources[$i][1]) }
                $n = Get-GpeShortName $name
                if ($live.ContainsKey($n)) { continue }
                if (-not $seen.Contains($n)) { $seen[$n] = [Collections.Generic.List[string]]::new() }
                $seen[$n].Add($sources[$i][0])
            }
        }
        $Report.staleCandidates = @(Limit-GpeItems @($seen.Keys | ForEach-Object { [ordered]@{ name = $_; sources = ($seen[$_] -join ',') } }) 20 $Report)
    }
}

function Invoke-GpoEvidence {
    param([string]$Section = 'Summary', [string]$Gpo = '', [string]$Offset = '0', [string]$RsopUser = '', $Context)
    if ($RsopUser -and $RsopUser -notmatch '^[A-Za-z0-9._-]{1,20}\z') { throw 'RsopUser must be a sAMAccountName of 1 to 20 letters, digits, dot, underscore or hyphen.' }
    if ($RsopUser) { $Section = 'Rsop' }
    if ($Gpo) { $Section = 'Gpo' }
    if (@('Summary', 'Gpos', 'Policy', 'Rsop', 'Gpo', 'Store', 'Profiles', 'Dc') -notcontains $Section) { throw 'Unknown section.' }
    $report = [ordered]@{ version = '1'; timestamp = [datetime]::UtcNow.ToString('o'); status = 'collected'; section = $Section }
    if ($Section -eq 'Rsop') { Get-GpeRsopSection $report $RsopUser }
    else {
        if (-not $Context) { $Context = Get-GpeContext }
        switch ($Section) {
            'Summary' { Get-GpeSummary $Context $report }
            'Gpos' { $start = 0; [void][int]::TryParse($Offset, [ref]$start); Get-GpeGposSection $Context $report ([Math]::Max(0, $start)) }
            'Policy' { Get-GpePolicySection $Context $report }
            'Gpo' { if (-not $Gpo) { throw 'The Gpo section needs Gpo=<name or GUID>.' }; Get-GpeGpoSection $Context $report $Gpo }
            'Store' { Get-GpeStoreSection $Context $report }
            'Profiles' { Get-GpeProfilesSection $Context $report }
            'Dc' { Get-GpeDcSection $Context $report }
        }
    }
    $report.elapsedSeconds = [Math]::Round($script:GpeClock.Elapsed.TotalSeconds, 1)
    return ConvertTo-GpeBoundedJson $report
}

if ($env:RELIAN_DEPLOY_TEST -eq '1' -and $MyInvocation.InvocationName -eq '.') { return }
if ($Action -eq 'Uninstall') { Write-Output '{"status":"nothingToUninstall"}'; exit 0 }
if (@('Install', 'Update', 'Repair', 'Reinstall') -notcontains $Action) { [Console]::Error.WriteLine('Unsupported action.'); exit 1 }
try { Write-Output (Invoke-GpoEvidence -Section $Section -Gpo $Gpo -Offset $Offset -RsopUser $RsopUser); exit 0 }
catch { Write-Output (ConvertTo-GpeFailure $_); exit 1 }
