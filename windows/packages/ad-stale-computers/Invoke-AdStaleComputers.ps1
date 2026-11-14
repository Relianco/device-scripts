<#
.SYNOPSIS
    Reports stale Active Directory computer accounts and, for named computers only, disables them.
.DESCRIPTION
    Runs through the Relian deploy runner (NinjaOne script 374) as SYSTEM, Windows PowerShell 5.1,
    on a domain controller (or a member with the ActiveDirectory module). Prints one line of JSON,
    at most 8,000 UTF-8 bytes.

    Package arguments (base64 JSON in -PackageArguments, every value a string):
      Mode          Report (default) or Apply
      Days          staleness age in days, 30 to 3650 (default 180)
      Filter        Report: Stale (default) or All
      Offset        Report: first row; the previous run prints nextOffset
      Names         Apply: comma-separated computer names, at most 10. Never computed here.
      RecipientKey  Apply: base64 RSA modulus (exponent 65537, 2048 bits or more). Required.
      WhatIf        Apply: true prints the plan and the backup and changes nothing
      Move          Apply: true also moves each computer to OU=Disabled Computers at the domain
                    root, created if missing. Default false: disable in place.

    Report is read-only. It lists workstation computer objects: name, DN, operating system,
    lastLogonTimestamp, pwdLastSet, enabled, the number of BitLocker recovery children, and
    whether LAPS manages the computer. It skips domain controllers (and objects left in the
    Domain Controllers OU), AZUREADSSOACC, servers (OperatingSystem
    like *Server*), cluster objects (servicePrincipalName MSClusterVirtualServer) and anything
    under an OU whose name holds "Server". Stale means lastLogonTimestamp and pwdLastSet are
    both older than Days. It prints no password.

    Apply re-reads each named computer and refuses it unless it is a stale workstation by the
    same rules. It first collects every refused-or-not computer's BitLocker recovery passwords
    and LAPS passwords and prints them only as "backup": AES-256-CBC over gzip JSON, the AES
    key wrapped with RSA-OAEP (SHA-1) to RecipientKey, so NinjaOne activity history never holds
    a plain secret. Then it disables each accepted computer and sets its Description. It deletes
    nothing. Exit 0 when every named computer was handled, 1 otherwise.
#>
[CmdletBinding()]
param(
    [string]$DeploymentType,
    [string]$Action,
    [string]$PinVersion,
    [string]$Mode = 'Report',
    [string]$Days = '180',
    [string]$Filter = 'Stale',
    [string]$Offset = '0',
    [string]$Names = '',
    [string]$RecipientKey = '',
    [string]$WhatIf = 'false',
    [string]$Move = 'false'
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:AscMaxNames = 10
$script:AscMaxBytes = 8000
$script:AscDisabledOu = 'Disabled Computers'

# AD access sits in script blocks so the tests can replace each one.
$script:AscProperties = @('OperatingSystem', 'lastLogonTimestamp', 'pwdLastSet', 'Enabled', 'servicePrincipalName', 'primaryGroupID', 'userAccountControl', 'Description')
$script:AscSchemaHas = {
    param($Name)
    [bool](Get-ADObject -SearchBase (Get-ADRootDSE).schemaNamingContext -LDAPFilter "(lDAPDisplayName=$Name)")
}
$script:AscGetComputers = { param($Properties) @(Get-ADComputer -Filter * -Properties $Properties) }
$script:AscGetComputer = { param($Name, $Properties) Get-ADComputer -Identity $Name -Properties $Properties }
$script:AscGetRecoveryAll = { @(Get-ADObject -LDAPFilter '(objectClass=msFVE-RecoveryInformation)') }
$script:AscGetRecovery = {
    param($Dn)
    @(Get-ADObject -SearchBase $Dn -SearchScope OneLevel -LDAPFilter '(objectClass=msFVE-RecoveryInformation)' -Properties 'msFVE-RecoveryPassword', 'msFVE-RecoveryGuid', 'whenCreated')
}
$script:AscDomainDn = { (Get-ADDomain).DistinguishedName }
$script:AscDisable = {
    param($Dn, $Description)
    Disable-ADAccount -Identity $Dn
    Set-ADComputer -Identity $Dn -Description $Description
}
$script:AscEnsureOu = {
    param($DomainDn, $Name)
    $dn = "OU=$Name,$DomainDn"
    if (-not (Get-ADObject -LDAPFilter "(&(objectClass=organizationalUnit)(distinguishedName=$dn))")) {
        New-ADOrganizationalUnit -Name $Name -Path $DomainDn -ProtectedFromAccidentalDeletion $true
    }
    return $dn
}
$script:AscMoveTo = { param($Dn, $TargetDn) Move-ADObject -Identity $Dn -TargetPath $TargetDn }

function ConvertFrom-AscFileTime {
    param($Value)
    if ($null -eq $Value) { return $null }
    $v = [int64]$Value
    # 0 is "never"; Int64.MaxValue is "never expires" on some attributes.
    if ($v -le 0 -or $v -eq [int64]::MaxValue) { return $null }
    return [DateTime]::FromFileTimeUtc($v)
}

function Format-AscDate {
    param($Date)
    if ($null -eq $Date) { return $null }
    return $Date.ToString('yyyy-MM-dd')
}

function Get-AscParentDn {
    param([string]$Dn)
    # A comma inside a name is escaped as \, in a DN.
    $m = [regex]::Match($Dn, '\A(?:\\.|[^,\\])*,(.*)\z')
    if ($m.Success) { return $m.Groups[1].Value }
    return ''
}

# Returns why a computer is out of scope, or $null for a workstation.
function Get-AscExclusion {
    param($Computer)
    $uac = 0; if ($Computer.userAccountControl) { $uac = [int]$Computer.userAccountControl }
    $group = 0; if ($Computer.primaryGroupID) { $group = [int]$Computer.primaryGroupID }
    # 8192 SERVER_TRUST_ACCOUNT; 516 Domain Controllers, 521 Read-only Domain Controllers.
    if (($uac -band 8192) -or $group -eq 516 -or $group -eq 521) { return 'domainController' }
    # A leftover object of a removed DC keeps its OU but can lose the flags above.
    if ((Get-AscParentDn ([string]$Computer.DistinguishedName)) -match '(?i)\AOU=Domain Controllers,') { return 'domainController' }
    # Seamless SSO's Kerberos account: disabling it breaks Entra sign-in from domain machines.
    if ([string]$Computer.Name -eq 'AZUREADSSOACC') { return 'entraSeamlessSso' }
    if ([string]$Computer.OperatingSystem -like '*Server*') { return 'server' }
    foreach ($spn in @($Computer.servicePrincipalName)) {
        if ([string]$spn -like 'MSClusterVirtualServer/*') { return 'cluster' }
    }
    if ((Get-AscParentDn ([string]$Computer.DistinguishedName)) -match '(?i)(\A|,)OU=[^,]*Server') { return 'serversOu' }
    return $null
}

function Test-AscStale {
    param($Computer, [datetime]$Cutoff)
    $last = ConvertFrom-AscFileTime $Computer.lastLogonTimestamp
    $pwdSet = ConvertFrom-AscFileTime $Computer.pwdLastSet
    return ($null -eq $last -or $last -lt $Cutoff) -and ($null -eq $pwdSet -or $pwdSet -lt $Cutoff)
}

function ConvertTo-AscNameList {
    param([AllowEmptyString()][string]$Names)
    $list = @($Names -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
    if ($list.Count -eq 0) { throw 'Names is empty.' }
    if ($list.Count -gt $script:AscMaxNames) { throw "At most $($script:AscMaxNames) names per run." }
    foreach ($n in $list) {
        # A NetBIOS computer name. Anything else could reach an LDAP filter or an identity lookup.
        if ($n -notmatch '\A[A-Za-z0-9][A-Za-z0-9_-]{0,14}\z') { throw 'A name is not a valid computer name.' }
    }
    return , $list
}

function Get-AscDays {
    param([string]$Days)
    $d = 0
    if (-not [int]::TryParse($Days, [ref]$d) -or $d -lt 30 -or $d -gt 3650) { throw 'Days must be 30 to 3650.' }
    return $d
}

function ConvertTo-AscBool {
    param([string]$Value, [string]$Name)
    if ($Value -eq 'true') { return $true }
    if ($Value -eq 'false' -or $Value -eq '') { return $false }
    throw "$Name must be true or false."
}

function Get-AscLapsAttributes {
    $attrs = @()
    foreach ($a in @('ms-Mcs-AdmPwd', 'ms-Mcs-AdmPwdExpirationTime', 'msLAPS-Password', 'msLAPS-EncryptedPassword', 'msLAPS-PasswordExpirationTime')) {
        if (& $script:AscSchemaHas $a) { $attrs += $a }
    }
    return , $attrs
}

# The AD module returns an empty collection, not $null, for an attribute that has no value.
function Get-AscValue {
    param($Computer, [string]$Name)
    $prop = $Computer.PSObject.Properties[$Name]
    if (-not $prop) { return $null }
    $values = @($prop.Value | Where-Object { $null -ne $_ -and "$_" -ne '' })
    if ($values.Count -eq 0) { return $null }
    return $values[0]
}

function Get-AscLapsKind {
    param($Computer)
    $kinds = @()
    foreach ($p in @(@('ms-Mcs-AdmPwdExpirationTime', 'legacy'), @('msLAPS-PasswordExpirationTime', 'windows'))) {
        if ($null -ne (Get-AscValue $Computer $p[0])) { $kinds += $p[1] }
    }
    return ($kinds -join '+')
}

# RecipientKey is the base64 RSA modulus. The exponent is 65537.
function Protect-AscBackup {
    param($Value, [string]$RecipientKey)
    $modulus = [Convert]::FromBase64String($RecipientKey)
    if ($modulus.Length -lt 256) { throw 'RecipientKey must be an RSA modulus of 2048 bits or more.' }
    $json = [Text.Encoding]::UTF8.GetBytes(($Value | ConvertTo-Json -Depth 6 -Compress))
    $ms = [IO.MemoryStream]::new()
    $gz = [IO.Compression.GZipStream]::new($ms, [IO.Compression.CompressionMode]::Compress)
    $gz.Write($json, 0, $json.Length); $gz.Dispose()
    $plain = $ms.ToArray()
    $aes = [Security.Cryptography.AesCryptoServiceProvider]::new()
    $rsa = [Security.Cryptography.RSACryptoServiceProvider]::new()
    try {
        $aes.KeySize = 256; $aes.Mode = 'CBC'; $aes.Padding = 'PKCS7'
        $aes.GenerateKey(); $aes.GenerateIV()
        $cipher = $aes.CreateEncryptor().TransformFinalBlock($plain, 0, $plain.Length)
        $p = [Security.Cryptography.RSAParameters]::new()
        $p.Modulus = $modulus; $p.Exponent = [byte[]](1, 0, 1)
        $rsa.ImportParameters($p)
        # shortcut: no MAC over the ciphertext; it only travels through NinjaOne back to the operator.
        return [ordered]@{ v = '1'; key = [Convert]::ToBase64String($rsa.Encrypt($aes.Key, $true)); iv = [Convert]::ToBase64String($aes.IV); data = [Convert]::ToBase64String($cipher) }
    } finally {
        $aes.Dispose(); $rsa.Dispose()
    }
}

function Invoke-AscReport {
    param([int]$Days, [string]$Filter = 'Stale', [int]$Offset = 0, [datetime]$Now = [datetime]::UtcNow)
    if (@('Stale', 'All') -notcontains $Filter) { throw 'Filter must be Stale or All.' }
    $cutoff = $Now.AddDays(-$Days)
    $laps = Get-AscLapsAttributes
    $props = @($script:AscProperties) + @($laps | Where-Object { $_ -like '*ExpirationTime' })
    $recovery = @{}
    foreach ($r in & $script:AscGetRecoveryAll) {
        $parent = Get-AscParentDn ([string]$r.DistinguishedName)
        if ($recovery.ContainsKey($parent)) { $recovery[$parent]++ } else { $recovery[$parent] = 1 }
    }
    $excluded = [ordered]@{ domainController = 0; entraSeamlessSso = 0; server = 0; cluster = 0; serversOu = 0 }
    $rows = [Collections.Generic.List[object]]::new()
    $all = @(& $script:AscGetComputers $props)
    $stale = 0
    foreach ($c in @($all | Sort-Object -Property Name)) {
        $why = Get-AscExclusion $c
        if ($why) { $excluded[$why]++; continue }
        $isStale = Test-AscStale $c $cutoff
        if ($isStale) { $stale++ }
        if ($Filter -eq 'Stale' -and -not $isStale) { continue }
        $bl = 0; if ($recovery.ContainsKey([string]$c.DistinguishedName)) { $bl = $recovery[[string]$c.DistinguishedName] }
        $rows.Add([ordered]@{
                name = [string]$c.Name; dn = [string]$c.DistinguishedName; os = [string]$c.OperatingSystem
                lastLogon = Format-AscDate (ConvertFrom-AscFileTime $c.lastLogonTimestamp); pwdLastSet = Format-AscDate (ConvertFrom-AscFileTime $c.pwdLastSet)
                enabled = [bool]$c.Enabled; stale = $isStale; bitlocker = $bl; laps = Get-AscLapsKind $c
            })
    }
    $page = @($rows | Select-Object -Skip $Offset)
    $report = [ordered]@{
        version = '1'; status = 'collected'; mode = 'Report'; cutoff = Format-AscDate $cutoff; filter = $Filter
        total = $all.Count; excluded = $excluded; stale = $stale; matched = $rows.Count; offset = $Offset; truncated = $false; computers = $page
    }
    # Page and nextOffset are sized together, so a cut row is never skipped by the next page.
    for ($keep = $page.Count; ; $keep--) {
        $report.computers = @($page | Select-Object -First $keep)
        $report.truncated = $keep -lt $page.Count
        if ($Offset + $keep -lt $rows.Count) { $report.nextOffset = $Offset + $keep } else { $report.Remove('nextOffset') }
        $json = $report | ConvertTo-Json -Depth 6 -Compress
        if ([Text.Encoding]::UTF8.GetByteCount($json) -le $script:AscMaxBytes -or $keep -eq 0) { return $json }
    }
}

function Invoke-AscApply {
    param([string[]]$Names, [int]$Days, [string]$RecipientKey, [bool]$WhatIf, [bool]$Move, [datetime]$Now = [datetime]::UtcNow)
    if ([string]::IsNullOrWhiteSpace($RecipientKey)) { throw 'Apply needs RecipientKey.' }
    $cutoff = $Now.AddDays(-$Days)
    $description = "Disabled by Relian $($Now.ToString('yyyy-MM-dd')) stale >$($Days)d"
    $laps = Get-AscLapsAttributes
    $props = @($script:AscProperties) + @($laps)
    $results = [Collections.Generic.List[object]]::new()
    $backup = [Collections.Generic.List[object]]::new()
    $accepted = [Collections.Generic.List[object]]::new()

    # Pass 1: read and back up everything before any change.
    foreach ($name in $Names) {
        $c = $null
        try { $c = & $script:AscGetComputer $name $props } catch { $c = $null }
        if ($null -eq $c) { $results.Add([ordered]@{ name = $name; result = 'notFound' }); continue }
        $entry = [ordered]@{ name = [string]$c.Name; dn = [string]$c.DistinguishedName; bitlocker = @(); laps = [ordered]@{} }
        foreach ($r in @(& $script:AscGetRecovery ([string]$c.DistinguishedName))) {
            $guid = $r.'msFVE-RecoveryGuid'
            if ($guid -is [byte[]]) { $guid = ([guid]::new($guid)).ToString() }
            $entry.bitlocker += [ordered]@{ recoveryGuid = [string]$guid; recoveryKey = [string]$r.'msFVE-RecoveryPassword'; created = Format-AscDate $r.whenCreated }
        }
        foreach ($a in $laps) {
            $v = Get-AscValue $c $a
            if ($null -eq $v) { continue }
            if ($v -is [byte[]]) { $v = [Convert]::ToBase64String($v) }
            $entry.laps[$a] = [string]$v
        }
        $backup.Add($entry)
        $row = [ordered]@{
            name = [string]$c.Name; dn = [string]$c.DistinguishedName; os = [string]$c.OperatingSystem
            lastLogon = Format-AscDate (ConvertFrom-AscFileTime $c.lastLogonTimestamp); enabled = [bool]$c.Enabled
            bitlocker = @($entry.bitlocker).Count; laps = @($entry.laps.Keys) -join '+'
        }
        $why = Get-AscExclusion $c
        if ($why) { $row.result = "refused:$why" }
        elseif (-not (Test-AscStale $c $cutoff)) { $row.result = 'refused:notStale' }
        else { $row.result = 'planned'; $accepted.Add($row) }
        $results.Add($row)
    }

    $protected = Protect-AscBackup -Value @($backup) -RecipientKey $RecipientKey
    $failed = @($results | Where-Object { $_.result -ne 'planned' }).Count -gt 0
    $report = [ordered]@{
        version = '1'; status = 'ok'; mode = 'Apply'; whatIf = $WhatIf; move = $Move
        cutoff = Format-AscDate $cutoff; description = $description; computers = @($results); backup = $protected
    }
    # The backup is the only copy the operator gets, so it must never be cut. 600 bytes per row
    # covers the longest later result text and the moved-to DN.
    $planned = [Text.Encoding]::UTF8.GetByteCount(($report | ConvertTo-Json -Depth 6 -Compress)) + 600 * $accepted.Count
    if ($planned -gt $script:AscMaxBytes) { throw 'The output would exceed 8000 bytes. Pass fewer names.' }

    if (-not $WhatIf) {
        $target = $null
        foreach ($row in $accepted) {
            try {
                & $script:AscDisable $row.dn $description
                $row.result = 'disabled'
                if ($Move) {
                    if (-not $target) { $target = & $script:AscEnsureOu (& $script:AscDomainDn) $script:AscDisabledOu }
                    & $script:AscMoveTo $row.dn $target
                    $row.result = 'disabledMoved'
                    $row.movedTo = $target
                }
            } catch {
                $row.result = "$($row.result);failed:$($_.Exception.GetType().Name)"
                $failed = $true
            }
        }
    }
    if ($failed) { $report.status = 'partial' }
    return @{ Json = ($report | ConvertTo-Json -Depth 6 -Compress); Failed = $failed }
}

if ($env:RELIAN_DEPLOY_TEST -eq '1' -and $MyInvocation.InvocationName -eq '.') { return }
if ([string]::IsNullOrWhiteSpace($PinVersion)) { exit 0 }
if ($Action -eq 'Uninstall') { Write-Output '{"status":"nothingToUninstall"}'; exit 0 }
if (@('Install', 'Update', 'Repair', 'Reinstall') -notcontains $Action) { [Console]::Error.WriteLine('Unsupported action.'); exit 1 }
try {
    $d = Get-AscDays $Days
    Import-Module ActiveDirectory
    if ($Mode -eq 'Report') {
        $o = 0; if (-not [int]::TryParse($Offset, [ref]$o) -or $o -lt 0) { throw 'Offset must be a whole number.' }
        Write-Output (Invoke-AscReport -Days $d -Filter $Filter -Offset $o)
        exit 0
    }
    if ($Mode -eq 'Apply') {
        $r = Invoke-AscApply -Names (ConvertTo-AscNameList $Names) -Days $d -RecipientKey $RecipientKey -WhatIf (ConvertTo-AscBool $WhatIf 'WhatIf') -Move (ConvertTo-AscBool $Move 'Move')
        Write-Output $r.Json
        if ($r.Failed) { exit 1 } else { exit 0 }
    }
    throw 'Mode must be Report or Apply.'
} catch {
    Write-Output ('{"status":"failed","error":' + (ConvertTo-Json ([string]$_.Exception.Message) -Compress) + '}')
    exit 1
}
