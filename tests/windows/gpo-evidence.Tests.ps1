$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
function Assert($Condition, $Label) { if (-not $Condition) { throw "FAIL $Label" } }
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$path = Join-Path $root 'windows/read/gpo-evidence/Invoke-GpoEvidence.ps1'
$env:RELIAN_DEPLOY_TEST = '1'
. $path

# Parses, uses no syntax newer than Windows PowerShell 5.1, and calls no write cmdlet.
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
Assert ($errors.Count -eq 0) 'parser'
foreach ($kind in @('QuestionQuestion', 'QuestionQuestionEquals', 'QuestionDot', 'QuestionLBracket', 'AndAnd', 'OrOr', 'QuestionMark')) {
    Assert (-not @($tokens | Where-Object { [string]$_.Kind -eq $kind })) "no PowerShell 7 token $kind"
}
$commands = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() })
foreach ($c in @($commands | Where-Object { $_ -ne 'Import-Module' })) { Assert ($c -notmatch '^(Set|New|Remove|Restore|Backup|Import|Rename|Copy|Move|Start|Stop|Restart)-') "read-only: no $c" }
foreach ($c in @('Ninja-Property-Set', 'secedit', 'gpupdate', 'auditpol')) { Assert ($commands -notcontains $c) "read-only: no $c" }

# Redaction.
$secret = [guid]::NewGuid().ToString('n')
Assert ((Protect-GpeText ('<Properties cpassword="' + $secret + '" />')) -eq '[sensitive line omitted]') 'cpassword line omitted'
Assert ((Protect-GpeText ('DefaultPassword=' + $secret)) -eq '[sensitive line omitted]') 'password value omitted'
Assert ((Protect-GpeText ('x' * 500) -Max 100).Length -le 110) 'text clipped'

# gPLink options: bit 1 disabled, bit 2 enforced.
$a = [guid]::NewGuid(); $b = [guid]::NewGuid()
$links = @(ConvertFrom-GpeLinks "[LDAP://cn={$a},cn=policies,cn=system,DC=example,DC=invalid;0][LDAP://CN={$($b.ToString().ToUpper())},CN=Policies,CN=System,DC=example,DC=invalid;3]")
Assert ($links.Count -eq 2 -and $links[0].id -eq $a.ToString() -and $links[0].enabled -and -not $links[0].enforced) 'enabled link'
Assert ($links[1].id -eq $b.ToString() -and -not $links[1].enabled -and $links[1].enforced) 'disabled enforced link'

# Registry.pol (PReg) parser.
function New-PolEntry {
    param([string]$Key, [string]$Name, [int]$Type, [byte[]]$Data)
    $u = [Text.Encoding]::Unicode
    $ms = [IO.MemoryStream]::new()
    $w = { param([byte[]]$x) $ms.Write($x, 0, $x.Length) }
    & $w $u.GetBytes('['); & $w $u.GetBytes($Key + [char]0); & $w $u.GetBytes(';'); & $w $u.GetBytes($Name + [char]0); & $w $u.GetBytes(';')
    & $w ([BitConverter]::GetBytes([uint32]$Type)); & $w $u.GetBytes(';'); & $w ([BitConverter]::GetBytes([uint32]$Data.Length)); & $w $u.GetBytes(';')
    & $w $Data; & $w $u.GetBytes(']')
    return $ms.ToArray()
}
$pol = [byte[]](0x50, 0x52, 0x65, 0x67, 1, 0, 0, 0)
$pol += New-PolEntry 'Software\Policies\Microsoft\Windows NT\Printers' 'RegisterSpoolerRemoteRpcEndPoint' 4 ([BitConverter]::GetBytes([uint32]2))
$pol += New-PolEntry 'Software\Policies\Test' 'Path' 1 ([Text.Encoding]::Unicode.GetBytes('C:\Logs' + [char]0))
$pol += New-PolEntry 'Software\Policies\Test' 'DefaultPassword' 1 ([Text.Encoding]::Unicode.GetBytes($secret + [char]0))
$parsedPol = Read-GpePol $pol
$entries = @($parsedPol.entries)
Assert (-not $parsedPol.truncated) 'Registry.pol read whole'
Assert ((Read-GpePol $pol -MaxEntries 2).truncated) 'Registry.pol cap reported'
Assert ($entries.Count -eq 3 -and $entries[0].type -eq 'REG_DWORD' -and $entries[0].data -eq 2) 'dword entry'
Assert ($entries[1].data -eq 'C:\Logs') 'string entry'
Assert (($entries | ConvertTo-Json -Compress) -notmatch $secret) 'password policy value redacted'
$bad = $false; try { [void](Read-GpePol ([byte[]](1, 2, 3, 4, 5, 6, 7, 8))) } catch { $bad = $true }
Assert $bad 'invalid PReg header refused'

# gpresult /x summary.
$rsopXml = [xml]@'
<Rsop xmlns="http://www.microsoft.com/GroupPolicy/Rsop"><ComputerResults><SOM>OU=Domain Controllers,DC=example,DC=invalid</SOM><Site>Site1</Site><SlowLink>false</SlowLink>
<GPO><Name>Default Domain Controllers Policy</Name><Enabled>true</Enabled><IsValid>true</IsValid><FilterAllowed>true</FilterAllowed><AccessDenied>false</AccessDenied><Link><SOMPath>example.invalid/Domain Controllers</SOMPath><AppliedOrder>1</AppliedOrder></Link></GPO>
<GPO><Name>Filtered</Name><Enabled>true</Enabled><IsValid>true</IsValid><FilterAllowed>false</FilterAllowed><AccessDenied>false</AccessDenied><Link><SOMPath>example.invalid</SOMPath><AppliedOrder>0</AppliedOrder></Link></GPO>
<GPO><Name>Denied</Name><Enabled>true</Enabled><IsValid>true</IsValid><FilterAllowed>true</FilterAllowed><AccessDenied>true</AccessDenied><Link><SOMPath>example.invalid</SOMPath><AppliedOrder>0</AppliedOrder></Link></GPO>
<ExtensionStatus><Name>Security</Name><Error>1332</Error><LoggingStatus>Complete</LoggingStatus></ExtensionStatus>
</ComputerResults></Rsop>
'@
$rsop = Read-GpeRsop $rsopXml
Assert ($rsop.applied.Count -eq 1 -and $rsop.applied[0].name -eq 'Default Domain Controllers Policy') 'applied GPO'
Assert (@($rsop.notApplied | Where-Object { $_.name -eq 'Filtered' -and $_.reason -eq 'wmiFilter' }).Count -eq 1) 'WMI-filtered GPO'
Assert (@($rsop.notApplied | Where-Object { $_.name -eq 'Denied' -and $_.reason -eq 'securityFilter' }).Count -eq 1) 'security-filtered GPO'
Assert ($rsop.extensions[0].name -eq 'Security' -and $rsop.extensions[0].error -eq 1332) 'extension error'
# Review: AppliedOrder directly under GPO (not inside Link) also counts as applied.
$direct = Read-GpeRsop ([xml]'<Rsop><ComputerResults><GPO><Name>Direct</Name><Enabled>true</Enabled><IsValid>true</IsValid><FilterAllowed>true</FilterAllowed><AccessDenied>false</AccessDenied><AppliedOrder>2</AppliedOrder><Link><SOMPath>example.invalid</SOMPath></Link></GPO></ComputerResults></Rsop>')
Assert ($direct.applied.Count -eq 1 -and $direct.applied[0].order -eq 2 -and $direct.applied[0].som -eq 'example.invalid') 'AppliedOrder under GPO read'
$nested = Read-GpeRsop ([xml]'<Rsop><ComputerResults><ExtensionStatus><Extension><Name>Registry</Name><Error>0</Error><LoggingStatus>Complete</LoggingStatus></Extension><Extension><Name>Security</Name><Error>5</Error><LoggingStatus>Complete</LoggingStatus></Extension></ExtensionStatus></ComputerResults></Rsop>')
Assert ($nested.extensions.Count -eq 2 -and $nested.extensions[1].name -eq 'Security' -and $nested.extensions[1].error -eq 5) 'nested Extension records read'

# Fake SYSVOL and domain.
$tmp = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('n'))
$policies = Join-Path $tmp 'Policies'
$ddpId = [guid]'31B2F340-016D-11D2-945F-00C04FB984F9'
$gppId = [guid]::NewGuid()
function New-GpoDir { param([guid]$Id) $d = Join-Path $policies ('{' + $Id.ToString().ToUpper() + '}'); [void](New-Item -ItemType Directory -Path $d -Force); $d }
try {
    $ddpDir = New-GpoDir $ddpId
    [void](New-Item -ItemType Directory -Path (Join-Path $ddpDir 'MACHINE\Microsoft\Windows NT\SecEdit') -Force)
    [IO.File]::WriteAllText((Join-Path $ddpDir 'MACHINE\Microsoft\Windows NT\SecEdit\GptTmpl.inf'), "[Unicode]`r`nUnicode=yes`r`n[System Access]`r`nMinimumPasswordLength = 8`r`nLockoutBadCount = 20`r`nNewAdministratorName = `"Admin2`"`r`n[Kerberos Policy]`r`nMaxTicketAge = 10`r`n", [Text.Encoding]::Unicode)
    $gppDir = New-GpoDir $gppId
    [void](New-Item -ItemType Directory -Path (Join-Path $gppDir 'Machine\Preferences\Groups') -Force)
    [IO.File]::WriteAllText((Join-Path $gppDir 'Machine\Preferences\Groups\Groups.xml'), "<Groups><User><Properties cpassword=`"$secret`" userName=`"x`"/></User></Groups>")
    [void](New-Item -ItemType Directory -Path (Join-Path $gppDir 'Machine') -Force)
    [IO.File]::WriteAllBytes((Join-Path $gppDir 'Machine\Registry.pol'), $pol)
    [void](New-Item -ItemType Directory -Path (Join-Path $gppDir 'Machine\Microsoft\Windows NT\Audit') -Force)
    [IO.File]::WriteAllText((Join-Path $gppDir 'Machine\Microsoft\Windows NT\Audit\audit.csv'), "Machine Name,Policy Target,Subcategory,Subcategory GUID,Inclusion Setting,Exclusion Setting,Setting Value`r`n,System,Audit Logon,{0cce9215-69ae-11d9-bed3-505054503030},Success,,1`r`n")

    $scan = Find-GpeCpassword -PoliciesPath $policies -Ids @($ddpId, $gppId)
    $hits = @($scan.hits)
    Assert ($scan.complete -and $scan.files -eq 1) 'cpassword scan complete'
    Assert ($hits.Count -eq 1 -and $hits[0].id -eq $gppId.ToString() -and $hits[0].count -eq 1 -and $hits[0].file -like 'Machine*Groups.xml') 'cpassword found by file and count'
    Assert (($hits | ConvertTo-Json -Compress) -notmatch $secret) 'cpassword value never printed'

    $ctx = @{ Server = 'dc1.example.invalid'; PoliciesPath = $policies; DomainDN = 'DC=example,DC=invalid'; ConfigDN = $null; IsDc = $true; Forest = [pscustomobject]@{ ForestMode = 'Windows2016Forest' }
        Domain = [pscustomobject]@{ DNSRoot = 'example.invalid'; NetBIOSName = 'EXAMPLE'; DomainMode = 'Windows2016Domain'; PDCEmulator = 'dc1.example.invalid' } }
    function New-FakeGpo { param([guid]$Id, [string]$Name, [int]$Ad, [int]$Sv)
        [pscustomobject]@{ Id = $Id; DisplayName = $Name; Owner = 'EXAMPLE\Domain Admins'; CreationTime = [datetime]'2020-01-01'; ModificationTime = [datetime]'2026-01-01'; GpoStatus = 'AllSettingsEnabled'
            WmiFilter = $null; Computer = [pscustomobject]@{ DSVersion = $Ad; SysvolVersion = $Sv }; User = [pscustomobject]@{ DSVersion = 0; SysvolVersion = 0 } } }
    $script:fakeGpos = @((New-FakeGpo $ddpId 'Default Domain Policy' 3 3), (New-FakeGpo $gppId 'Legacy drive maps' 5 4))
    1..120 | ForEach-Object { $script:fakeGpos += New-FakeGpo ([guid]::NewGuid()) ("Zone policy number $_ with a long descriptive name") 1 1 }
    $script:servers = [Collections.Generic.List[string]]::new()
    function Get-GPO { param([switch]$All, $Guid, $Name, $Server, $ErrorAction) $script:servers.Add([string]$Server); if ($All) { return $script:fakeGpos } foreach ($g in $script:fakeGpos) { if (($Guid -and $g.Id -eq [guid]$Guid) -or ($Name -and $g.DisplayName -eq $Name)) { return $g } } throw [ArgumentException]::new('not found') }
    function Get-GPPermission { param($Guid, [switch]$All, $Server, $ErrorAction) @([pscustomobject]@{ Permission = 'GpoApply'; Denied = $false; Trustee = [pscustomobject]@{ Name = 'Authenticated Users' } }) }
    function Get-ADObject { param($LDAPFilter, $SearchBase, $Identity, $Properties, $Server, $ErrorAction)
        if ($Identity) { throw [ArgumentException]::new('missing') }
        @([pscustomobject]@{ DistinguishedName = 'DC=example,DC=invalid'; gPLink = "[LDAP://cn={$ddpId},cn=policies,cn=system,DC=example,DC=invalid;0]" }) }

    $json = Invoke-GpoEvidence -Section Gpos -Context $ctx
    $r = $json | ConvertFrom-Json
    Assert ([Text.Encoding]::UTF8.GetByteCount($json) -le 8000) 'Gpos output capped'
    Assert ($r.gpoTotal -eq 122 -and $r.returned -lt 122 -and $r.nextOffset -eq $r.returned) 'Gpos paged with next offset'
    Assert ($r.gpos[0].mismatch -eq $true -and $r.gpos[0].name -eq 'Legacy drive maps') 'version mismatch listed first'
    Assert ($r.gpos[0].cpassword -eq 1) 'cpassword flagged on the GPO row'
    $ddpRow = @($r.gpos | Where-Object { $_.name -eq 'Default Domain Policy' })[0]
    Assert ($ddpRow.links[0].som -eq 'DC=example,DC=invalid' -and $ddpRow.links[0].enabled) 'links on GPO row'
    Assert ($ddpRow.apply -contains 'Authenticated Users') 'security filtering summary'
    $page2 = Invoke-GpoEvidence -Section Gpos -Offset ([string]$r.nextOffset) -Context $ctx | ConvertFrom-Json
    Assert ($page2.offset -eq $r.nextOffset -and $page2.gpos[0].name -ne $r.gpos[0].name) 'second page'
    Assert ($json -notmatch $secret) 'Gpos output has no cpassword value'

    function Get-ADDefaultDomainPasswordPolicy { [pscustomobject]@{ MinPasswordLength = 8; PasswordHistoryCount = 1; ComplexityEnabled = $false; MaxPasswordAge = [timespan]::Zero; MinPasswordAge = [timespan]::Zero; LockoutThreshold = 20; LockoutDuration = [timespan]::FromMinutes(15); LockoutObservationWindow = [timespan]::FromMinutes(15); ReversibleEncryptionEnabled = $false } }
    function Get-ADFineGrainedPasswordPolicy { param($Filter) @() }
    function Get-GPInheritance { param($Target, $Server, $ErrorAction) [pscustomobject]@{ GpoLinks = @([pscustomobject]@{ DisplayName = 'Default Domain Policy'; Enabled = $true; Enforced = $false; Order = 1 }) } }
    $p = Invoke-GpoEvidence -Section Policy -Context $ctx | ConvertFrom-Json
    Assert ($p.defaultDomainPolicy.systemAccess.MinimumPasswordLength -eq '8' -and $p.defaultDomainPolicy.kerberos.MaxTicketAge -eq '10') 'default domain policy values'
    Assert (-not $p.defaultDomainPolicy.systemAccess.PSObject.Properties['NewAdministratorName']) 'non-allowlisted keys omitted'
    Assert ($p.effective.LockoutThreshold -eq 20 -and $p.fineGrainedPolicies -eq 0) 'effective password policy'
    Assert ($p.defaultDcPolicy.status -eq 'missing') 'missing DC policy reported'

    $g = Invoke-GpoEvidence -Section Gpo -Gpo $gppId.ToString() -Context $ctx
    $gr = $g | ConvertFrom-Json
    Assert ($gr.gpo.name -eq 'Legacy drive maps' -and $gr.machinePol.Count -eq 3 -and $gr.audit[0].subcategory -eq 'Audit Logon') 'single GPO dump'
    Assert ($gr.preferences[0].cpassword -eq 1 -and $g -notmatch $secret) 'single GPO flags cpassword without value'
    $gn = Invoke-GpoEvidence -Section Summary -Gpo 'Legacy drive maps' -Context $ctx | ConvertFrom-Json
    Assert ($gn.section -eq 'Gpo' -and $gn.gpo.id -eq $gppId.ToString()) 'Gpo argument by name selects the Gpo section'
    $missing = Invoke-GpoEvidence -Section Gpo -Gpo 'No such policy' -Context $ctx | ConvertFrom-Json
    Assert ($missing.gpo.status -eq 'notFound') 'unknown GPO reported'

    $staleId = [guid]::NewGuid()
    function Get-ADObject { param($LDAPFilter, $SearchBase, $Identity, $Properties, $Server, $ErrorAction)
        if ($Identity -like '*DFSR-GlobalSettings*') { return [pscustomobject]@{ 'msDFSR-Flags' = 48 } }
        if ($Identity) { throw [ArgumentException]::new('missing') }
        # A stale link to a deleted GPO must not reduce the unlinked count.
        @([pscustomobject]@{ DistinguishedName = 'DC=example,DC=invalid'; gPLink = "[LDAP://cn={$ddpId},cn=policies,cn=system,DC=example,DC=invalid;0][LDAP://cn={$staleId},cn=policies,cn=system,DC=example,DC=invalid;0]" }) }
    function Get-ADDomainController { param($Filter, $ErrorAction) @([pscustomobject]@{ HostName = 'dc1.example.invalid'; Site = 'Site1'; OperatingSystem = 'Windows Server 2022 Datacenter'; IsGlobalCatalog = $true; IsReadOnly = $false }) }
    function Get-Service { param($Name, $ErrorAction) if ($Name -eq 'DFSR') { [pscustomobject]@{ Status = 'Running' } } else { throw 'absent' } }
    function Get-WinEvent { param($FilterHashtable, $MaxEvents, $ErrorAction) @([pscustomobject]@{ Id = 4012 }, [pscustomobject]@{ Id = 4012 }) }
    $sj = Invoke-GpoEvidence -Context $ctx
    $s = $sj | ConvertFrom-Json
    Assert ($s.section -eq 'Summary' -and $s.domain.mode -eq 'Windows2016Domain' -and $s.domain.forestMode -eq 'Windows2016Forest') 'functional levels'
    Assert ($s.dcs[0].gc -and $s.sysvol.type -eq 'DFSR' -and $s.sysvol.migrationState -eq 'Eliminated') 'DCs and SYSVOL DFSR'
    Assert ($s.sysvol.serviceDFSR -eq 'Running' -and $s.sysvol.serviceNtFrs -eq 'absent' -and $s.sysvol.dfsrWarnings7d.'4012' -eq 2) 'SYSVOL health hints'
    Assert ($s.gpoCount -eq 122 -and $s.versionMismatchCount -eq 1 -and $s.cpassword[0].count -eq 1) 'summary counts'
    Assert ($s.unlinked -eq 121) 'unlinked counts existing GPOs with no link, ignoring stale links'
    # Review: per-row link and trustee caps set truncated.
    & {
        function Get-ADObject { param($LDAPFilter, $SearchBase, $Identity, $Properties, $Server, $ErrorAction)
            @(1..7 | ForEach-Object { [pscustomobject]@{ DistinguishedName = "OU=Site$_,DC=example,DC=invalid"; gPLink = "[LDAP://cn={$ddpId},cn=policies,cn=system,DC=example,DC=invalid;0]" } }) }
        $cap = Invoke-GpoEvidence -Section Gpos -Context $ctx | ConvertFrom-Json
        $row = @($cap.gpos | Where-Object { $_.name -eq 'Default Domain Policy' })[0]
        Assert ($row.linkCount -eq 7 -and @($row.links).Count -eq 6 -and $cap.truncated) 'link cap marks truncated'
    }
    Assert (-not $s.PSObject.Properties['notes']) 'a successful site-link read adds no notes'
    # A failed site-link read is reported, not shown as "no site links".
    & {
        function Get-ADObject { param($LDAPFilter, $SearchBase, $Identity, $Properties, $Server, $ErrorAction)
            if ($Identity -like '*DFSR-GlobalSettings*') { return [pscustomobject]@{ 'msDFSR-Flags' = 48 } }
            if ($SearchBase) { throw [UnauthorizedAccessException]::new('denied') }
            @([pscustomobject]@{ DistinguishedName = 'DC=example,DC=invalid'; gPLink = "[LDAP://cn={$ddpId},cn=policies,cn=system,DC=example,DC=invalid;0]" }) }
        $ctx.ConfigDN = 'CN=Configuration,DC=example,DC=invalid'
        $f = Invoke-GpoEvidence -Context $ctx | ConvertFrom-Json
        Assert (@($f.notes) -contains 'siteLinksUnavailable: UnauthorizedAccessException') 'failed site-link read is noted'
        Assert ($null -eq $f.unlinked) 'unlinked is unknown, not a count, when site links were unreadable'
        $fg = Invoke-GpoEvidence -Section Gpos -Context $ctx | ConvertFrom-Json
        Assert (@($fg.notes) -contains 'siteLinksUnavailable: UnauthorizedAccessException') 'Gpos section notes a failed site-link read'
        $ctx.ConfigDN = $null
    }
    Assert ([Text.Encoding]::UTF8.GetByteCount($sj) -le 8000 -and $sj -notmatch $secret) 'summary bounded and redacted'

    # Review: a capped scan says so instead of reporting a clean result.
    [void](New-Item -ItemType Directory -Path (Join-Path $gppDir 'User\Preferences\Drives') -Force)
    [IO.File]::WriteAllText((Join-Path $gppDir 'User\Preferences\Drives\Drives.xml'), '<Drives/>')
    $capped = Find-GpeCpassword -PoliciesPath $policies -Ids @($gppId) -MaxFiles 1
    # Review: more than 15 mismatches sets truncated.
    $savedGpos = $script:fakeGpos
    $script:fakeGpos = @(1..16 | ForEach-Object { New-FakeGpo ([guid]::NewGuid()) "Mismatch $_" 2 1 })
    $m = Invoke-GpoEvidence -Context $ctx | ConvertFrom-Json
    $script:fakeGpos = $savedGpos
    Assert ($m.versionMismatchCount -eq 16 -and @($m.versionMismatches).Count -eq 15 -and $m.truncated) 'mismatch list cap marks truncated'
    # Review: an unreadable Preferences subtree is not a clean result.
    & {
        function Get-ChildItem { [CmdletBinding()] param($LiteralPath, [switch]$Recurse, $Filter, [switch]$File) Write-Error 'Access to the path is denied.' }
        $denied = Find-GpeCpassword -PoliciesPath $policies -Ids @($gppId)
        Assert (-not $denied.complete -and $denied.errors -ge 1) 'enumeration error marks the scan incomplete'
    }
    # Review: an inaccessible Preferences folder is not skipped as missing.
    & {
        function Get-Item { [CmdletBinding()] param($LiteralPath, [switch]$Force) throw [UnauthorizedAccessException]::new('Access to the path is denied.') }
        $denied = Find-GpeCpassword -PoliciesPath $policies -Ids @($gppId)
        Assert (-not $denied.complete -and $denied.errors -ge 1) 'inaccessible Preferences folder marks the scan incomplete'
    }
    # Review: valid XML with single quotes or spaces around = is still counted.
    $altId = [guid]::NewGuid(); $altDir = New-GpoDir $altId
    [void](New-Item -ItemType Directory -Path (Join-Path $altDir 'Machine\Preferences\Services') -Force)
    [IO.File]::WriteAllText((Join-Path $altDir 'Machine\Preferences\Services\Services.xml'), "<Services><S><Properties cpassword = '$secret'/></S><S><Properties cpassword=`"`"/></S></Services>")
    $alt = Find-GpeCpassword -PoliciesPath $policies -Ids @($altId)
    Assert ($alt.hits.Count -eq 1 -and $alt.hits[0].count -eq 1 -and ($alt | ConvertTo-Json -Compress) -notmatch $secret) 'single-quoted cpassword counted, empty one ignored'
    # Review: a fixed list limit sets truncated.
    $lim = [ordered]@{}
    $kept = @(Limit-GpeItems -Items @(1, 2, 3) -Max 2 -Report $lim)
    Assert ($kept.Count -eq 2 -and $lim.truncated) 'list limit marks report truncated'
    Assert (-not $capped.complete) 'capped cpassword scan marked incomplete'
    Assert ($s.cpasswordScan.complete -eq $true) 'summary reports scan completeness'
    # Review: GPO versions come from the same DC as the SYSVOL path.
    Assert ($script:servers.Count -gt 0 -and -not @($script:servers | Where-Object { $_ -ne 'dc1.example.invalid' })) 'Get-GPO bound to the context DC'


    # ---- Leaf R1 additions ----
    # Rsop reads the gpresult file in any encoding it may leave, even with invalid XML characters.
    $rsopBody = '<Rsop xmlns="http://www.microsoft.com/GroupPolicy/Rsop"><ComputerResults><SOM>OU=Workstations,DC=example,DC=invalid</SOM><Site>Site1</Site><GPO><Name>Computer GPO</Name><Enabled>true</Enabled><IsValid>true</IsValid><FilterAllowed>true</FilterAllowed><AccessDenied>false</AccessDenied><Link><SOMPath>example.invalid</SOMPath><AppliedOrder>1</AppliedOrder></Link></GPO></ComputerResults>' +
        '<UserResults><GPO><Name>User GPO' + [char]1 + '&#x2;</Name><Enabled>true</Enabled><IsValid>true</IsValid><FilterAllowed>true</FilterAllowed><AccessDenied>false</AccessDenied><Link><SOMPath>example.invalid/Staff</SOMPath><AppliedOrder>2</AppliedOrder></Link></GPO>' +
        '<GPO><Name>Hidden GPO</Name><Enabled>true</Enabled><IsValid>true</IsValid><FilterAllowed>false</FilterAllowed><AccessDenied>false</AccessDenied><Link><SOMPath>example.invalid</SOMPath><AppliedOrder>0</AppliedOrder></Link></GPO>' +
        '<ExtensionStatus><Name>Folder Redirection</Name><Error>0</Error><LoggingStatus>Complete</LoggingStatus></ExtensionStatus></UserResults></Rsop>'
    $declared = '<?xml version="1.0" encoding="utf-16"?>' + $rsopBody
    $clean = $declared.Replace([string][char]1, '')
    $files = [ordered]@{
        'utf16-bom + invalid char' = [byte[]](@(0xFF, 0xFE) + [Text.Encoding]::Unicode.GetBytes($declared))
        'utf8 declared utf-16'     = [Text.UTF8Encoding]::new($false).GetBytes($clean)
        'utf16 without bom'        = [Text.Encoding]::Unicode.GetBytes($clean)
        'utf16-bom clean'          = [byte[]](@(0xFF, 0xFE) + [Text.Encoding]::Unicode.GetBytes($clean))
    }
    foreach ($label in $files.Keys) {
        $f = Join-Path $tmp 'rsop-fixture.xml'
        [IO.File]::WriteAllBytes($f, $files[$label])
        $c = Read-GpeRsopFile $f 'Computer'
        Assert ($c.applied.Count -eq 1 -and $c.applied[0].name -eq 'Computer GPO') "computer scope read ($label)"
        $u = Read-GpeRsopFile $f 'User'
        Assert ($u.applied.Count -eq 1 -and $u.applied[0].name -like 'User GPO*' -and $u.applied[0].order -eq 2 -and $u.applied[0].som -eq 'example.invalid/Staff') "user scope read ($label)"
        Assert (@($u.notApplied | Where-Object { $_.name -eq 'Hidden GPO' -and $_.reason -eq 'wmiFilter' }).Count -eq 1 -and $u.extensions[0].name -eq 'Folder Redirection') "user scope filtered GPO and extensions ($label)"
    }
    $noUser = $false; try { [void](Read-GpeRsop ([xml]'<Rsop><ComputerResults/></Rsop>') 'User') } catch { $noUser = $true }
    Assert $noUser 'user scope without UserResults is an error'

    # Rsop section: gpresult arguments, temp file cleanup, surfaced messages, no RSAT.
    $realNative = ${function:Invoke-GpeNative}
    function Get-GpeNetbiosDomain { 'EXAMPLE' }
    function Get-GpeContext { throw 'RSAT was loaded for Rsop' }
    $script:calls = [Collections.Generic.List[object]]::new()
    $script:nativeResult = $null
    $script:nativeBytes = $files['utf16-bom clean']
    function Invoke-GpeNative {
        param([string]$Path, [string[]]$Arguments, [int]$TimeoutSec)
        $script:calls.Add(@($Path) + $Arguments)
        if ($script:nativeResult) { return $script:nativeResult }
        [IO.File]::WriteAllBytes($Arguments[([array]::IndexOf($Arguments, '/x') + 1)], $script:nativeBytes)
        [pscustomobject]@{ ExitCode = 0; Output = ''; TimedOut = $false }
    }
    $before = @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Filter 'relian-gpresult-*').Count
    $rc = Invoke-GpoEvidence -Section Rsop | ConvertFrom-Json
    Assert ($rc.section -eq 'Rsop' -and $rc.rsop.scope -eq 'Computer' -and $rc.rsop.applied[0].name -eq 'Computer GPO') 'Rsop computer scope'
    $a = @($script:calls[0] | Select-Object -Skip 1)
    Assert ($a.Count -eq 5 -and $a[0] -eq '/scope' -and $a[1] -eq 'computer' -and $a[2] -eq '/x' -and $a[3] -like '*relian-gpresult-*.xml' -and $a[4] -eq '/f') 'gpresult computer arguments'
    $ru = Invoke-GpoEvidence -Section Rsop -RsopUser 'j.smith-2' | ConvertFrom-Json
    $a = @($script:calls[1] | Select-Object -Skip 1)
    Assert ($a.Count -eq 7 -and $a[0] -eq '/user' -and $a[1] -eq 'EXAMPLE\j.smith-2' -and $a[2] -eq '/scope' -and $a[3] -eq 'user' -and $a[4] -eq '/x' -and $a[6] -eq '/f') 'gpresult user arguments'
    Assert ($ru.section -eq 'Rsop' -and $ru.rsop.scope -eq 'User' -and $ru.rsop.applied[0].name -like 'User GPO*') 'RsopUser selects the user scope'
    Assert (@(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Filter 'relian-gpresult-*').Count -eq $before) 'gpresult temp file deleted'
    foreach ($badUser in @('', 'a b', 'x;y', 'EXAMPLE\u', ('a' * 21), 'u$', '..\x')) {
        if ($badUser -eq '') { continue }
        $threw = $false; try { [void](Invoke-GpoEvidence -Section Rsop -RsopUser $badUser) } catch { $threw = $true }
        Assert $threw "RsopUser [$badUser] refused"
    }
    Assert ($script:calls.Count -eq 2) 'refused RsopUser runs nothing'

    $script:nativeResult = [pscustomobject]@{ ExitCode = 1; Output = "ERROR: The user EXAMPLE\ghost does not have RSOP data.  password=$secret"; TimedOut = $false }
    $rf = Invoke-GpoEvidence -Section Rsop -RsopUser 'ghost' | ConvertFrom-Json
    Assert ($rf.status -eq 'collected' -and $rf.rsop.status -eq 'failed' -and $rf.rsop.exitCode -eq 1) 'gpresult failure reported'
    Assert ($rf.rsop.message -eq '[sensitive line omitted]' -and ($rf | ConvertTo-Json -Depth 6) -notmatch $secret) 'gpresult message redacted'
    $script:nativeResult = [pscustomobject]@{ ExitCode = 1; Output = "ERROR: The user EXAMPLE\ghost does not have RSOP data."; TimedOut = $false }
    $rf = Invoke-GpoEvidence -Section Rsop -RsopUser 'ghost' | ConvertFrom-Json
    Assert ($rf.rsop.message -like '*does not have RSOP data*') 'gpresult message surfaced'
    $script:nativeResult = [pscustomobject]@{ ExitCode = $null; Output = ''; TimedOut = $true }
    Assert ((Invoke-GpoEvidence -Section Rsop | ConvertFrom-Json).rsop.status -eq 'timeout') 'gpresult timeout reported'
    $script:nativeResult = $null
    $script:nativeBytes = [Text.Encoding]::UTF8.GetBytes('this is not xml')
    $rp = Invoke-GpoEvidence -Section Rsop | ConvertFrom-Json
    Assert ($rp.rsop.status -eq 'failed' -and $rp.rsop.stage -eq 'parse' -and $rp.rsop.message -and $rp.rsop.error) 'unparseable gpresult XML reports stage, type and message'
    $script:nativeBytes = $files['utf16-bom clean']
    Remove-Item function:Get-GpeContext

    # The wrapper runs a real process, bounds it and reports the exit code.
    $self = (Get-Process -Id $PID).Path
    Remove-Item function:Invoke-GpeNative
    $n = & $realNative $self @('-NoProfile', '-Command', 'Write-Output "two words"; exit 3') 30
    Assert ($n.ExitCode -eq 3 -and $n.Output -match 'two words' -and -not $n.TimedOut) 'native wrapper output and exit code'
    $n = & $realNative $self @('-NoProfile', '-Command', 'Start-Sleep -Seconds 30') 1
    Assert ($n.TimedOut) 'native wrapper kills a slow process'
    Remove-Item function:Get-GpeNetbiosDomain

    # Top-level failure keeps the redacted message.
    $fj = ConvertTo-GpeFailure ([Management.Automation.ErrorRecord]::new([InvalidOperationException]::new('boom at the DC'), 'x', 'NotSpecified', $null)) | ConvertFrom-Json
    Assert ($fj.status -eq 'failed' -and $fj.error -eq 'InvalidOperationException' -and $fj.message -eq 'boom at the DC') 'failure line carries the message'
    Assert ((ConvertTo-GpeFailure ([Management.Automation.ErrorRecord]::new([InvalidOperationException]::new("bad password=$secret"), 'x', 'NotSpecified', $null))) -notmatch $secret) 'failure message redacted'

    # fdeploy.ini and scripts.ini in the Gpo section.
    $fdId = [guid]::NewGuid(); $fdDir = New-GpoDir $fdId
    $uds = Join-Path $fdDir 'User\Documents & Settings'
    [void](New-Item -ItemType Directory -Path $uds -Force)
    [IO.File]::WriteAllText((Join-Path $uds 'fdeploy.ini'), "[FolderStatus]`r`nDesktop=3`r`nMusic=0`r`n[Desktop]`r`ns-1-1-0=\\fs1\Redirected$\%username%\Desktop`r`nFlags=1F001F`r`n[Music]`r`nFlags=1F001F`r`n", [Text.Encoding]::Unicode)
    [IO.File]::WriteAllText((Join-Path $uds 'fdeploy1.ini'), "[version]`r`nversion=100`r`n[Folder_Redirection]`r`n{FDD39AD0-238F-46AF-ADB4-6C85480369C7}=S-1-1-0; S-1-5-21-1-2-3-1105`r`n{33E28130-4E1E-4676-835A-98395C3BC3BB}=S-1-1-0`r`n[{FDD39AD0-238F-46AF-ADB4-6C85480369C7}_S-1-1-0]`r`nFlags=1001`r`nFullPath=\\fs1\Docs\%USERNAME%\Documents`r`n[{FDD39AD0-238F-46AF-ADB4-6C85480369C7}_S-1-5-21-1-2-3-1105]`r`nFlags=1001`r`nFullPath=%HOMESHARE%\Documents`r`n[{33E28130-4E1E-4676-835A-98395C3BC3BB}_S-1-1-0]`r`nFlags=2001`r`n", [Text.Encoding]::Unicode)
    [void](New-Item -ItemType Directory -Path (Join-Path $fdDir 'User\Scripts') -Force)
    [void](New-Item -ItemType Directory -Path (Join-Path $fdDir 'Machine\Scripts') -Force)
    [IO.File]::WriteAllText((Join-Path $fdDir 'User\Scripts\scripts.ini'), "[Logon]`r`n0CmdLine=\\example.invalid\netlogon\map.bat`r`n0Parameters=-flag secretflag`r`n1CmdLine=logon.vbs`r`n3CmdLine=plain.cmd sensitiveValue`r`n2CmdLine=`"C:\Program Files\x\tool.exe`" -flag zzzsecret1`r`n1Parameters=`r`n", [Text.Encoding]::Unicode)
    [IO.File]::WriteAllText((Join-Path $fdDir 'Machine\Scripts\scripts.ini'), "[Startup]`r`n0CmdLine=C:\Windows\SYSVOL\boot.cmd`r`n0Parameters=`r`n", [Text.Encoding]::Unicode)
    $script:fakeGpos = @($script:fakeGpos) + (New-FakeGpo $fdId 'Folder redirection' 1 1)
    $fd = Invoke-GpoEvidence -Section Gpo -Gpo $fdId.ToString() -Context $ctx
    $fr = $fd | ConvertFrom-Json
    $fdep = @($fr.folderRedirection | Where-Object { $_.file -eq 'fdeploy.ini' })[0]
    $desk = @($fdep.folders | Where-Object { $_.folder -eq 'Desktop' })[0]
    Assert ($desk.redirected -eq $true -and $desk.status -eq 3 -and $desk.flags -eq '1F001F' -and $desk.targets[0].type -eq 'unc' -and $desk.targets[0].path -like '\\fs1\Redirected$\*') 'fdeploy.ini redirected folder'
    $music = @($fdep.folders | Where-Object { $_.folder -eq 'Music' })[0]
    Assert ($music.redirected -eq $false -and @($music.targets).Count -eq 0) 'fdeploy.ini folder not redirected'
    $v1 = @((@($fr.folderRedirection | Where-Object { $_.file -eq 'fdeploy1.ini' })[0]).folders)
    $docs = @($v1 | Where-Object { $_.folder -eq 'Documents' })[0]
    Assert ($v1.Count -eq 2 -and $docs.redirected -eq $true -and $docs.flags -eq '1001' -and $docs.targetCount -eq 2 -and @($docs.targets | Where-Object { $_.type -eq 'home' }).Count -eq 1 -and @($docs.targets | Where-Object { $_.type -eq 'unc' -and $_.path -like '\\fs1\Docs\*' }).Count -eq 1) 'fdeploy1.ini known folder, unc and home targets'
    $pics = @($v1 | Where-Object { $_.folder -eq 'Pictures' })[0]
    Assert ($pics.redirected -eq $false -and $pics.flags -eq '2001') 'fdeploy1.ini follow-parent entry is not redirected'
    $names = @($fr.scripts | ForEach-Object { $_.side + ':' + $_.event + ':' + $_.name })
    Assert (($names -contains 'User:Logon:map.bat') -and ($names -contains 'User:Logon:logon.vbs') -and ($names -contains 'User:Logon:tool.exe') -and ($names -contains 'User:Logon:plain.cmd') -and ($names -contains 'Machine:Startup:boot.cmd')) 'scripts.ini script names'
    Assert ($fd -notmatch 'secretflag' -and $fd -notmatch 'zzzsecret1' -and $fd -notmatch 'sensitiveValue' -and [Text.Encoding]::UTF8.GetByteCount($fd) -le 8000) 'script parameters never printed'
    $plain = Invoke-GpoEvidence -Section Gpo -Gpo $gppId.ToString() -Context $ctx | ConvertFrom-Json
    Assert (@($plain.folderRedirection).Count -eq 0 -and @($plain.scripts).Count -eq 0) 'GPO without these files reports none'

    # Store section.
    $store = Invoke-GpoEvidence -Section Store -Context $ctx | ConvertFrom-Json
    Assert ($store.section -eq 'Store' -and $store.store.exists -eq $false -and $store.store.admxCount -eq 0) 'missing central store reported'
    $pd = Join-Path $policies 'PolicyDefinitions'
    [void](New-Item -ItemType Directory -Path (Join-Path $pd 'en-US') -Force)
    [IO.File]::WriteAllText((Join-Path $pd 'OneDrive.admx'), '<?xml version="1.0" encoding="utf-8"?><policyDefinitions revision="1.1" schemaVersion="1.0"></policyDefinitions>')
    [IO.File]::WriteAllText((Join-Path $pd 'System.admx'), '<policyDefinitions revision="1.0"/>')
    [IO.File]::WriteAllText((Join-Path $pd 'en-US\OneDrive.adml'), '<?xml version="1.0" encoding="utf-8"?><policyDefinitionResources revision="1.0" schemaVersion="1.0"></policyDefinitionResources>')
    $store = Invoke-GpoEvidence -Section Store -Context $ctx | ConvertFrom-Json
    Assert ($store.store.exists -and $store.store.admxCount -eq 2 -and @($store.store.languages) -contains 'en-US') 'central store counted'
    Assert ($store.store.oneDriveAdmx.present -and $store.store.oneDriveAdmx.revision -eq '1.1' -and $store.store.oneDriveAdmx.date -match '^\d{4}-\d\d-\d\d$') 'OneDrive.admx present with date and revision'
    Assert ($store.store.oneDriveAdml.present -and $store.store.oneDriveAdml.revision -eq '1.0') 'OneDrive.adml present with revision'
    [IO.File]::Delete((Join-Path $pd 'en-US\OneDrive.adml'))
    Assert (-not (Invoke-GpoEvidence -Section Store -Context $ctx | ConvertFrom-Json).store.oneDriveAdml.present) 'missing adml reported'

    # Profiles section.
    function New-FakeUser { param($Sam, $ProfDir = $null, $HomeDir = $null, $Drive = $null, $Logon = $null, [int]$Bad = 0)
        [pscustomobject]@{ SamAccountName = $Sam; profilePath = $ProfDir; homeDirectory = $HomeDir; homeDrive = $Drive; scriptPath = $Logon; badPwdCount = $Bad } }
    $script:fakeUsers = @(
        (New-FakeUser 'usr1' '\\fs1\profiles\usr1' '\\fs1\dirs\usr1' 'H:' 'logon.bat' 0),
        (New-FakeUser 'usr2' '\\fs1\profiles\USR2.V2' '\\fs1\dirs\usr2' 'H:' $null 3),
        (New-FakeUser 'usr3' $null 'D:\Data\usr3' $null $null 1),
        (New-FakeUser 'usr4'))
    function Get-ADUser { param($Filter, $LDAPFilter, $Properties, $Server, $ResultPageSize, $ErrorAction) $script:fakeUsers }
    $pj = Invoke-GpoEvidence -Section Profiles -Context $ctx
    $pr = $pj | ConvertFrom-Json
    Assert ($pr.section -eq 'Profiles' -and $pr.profiles.enabledUsers -eq 4 -and $pr.profiles.badPwdCountAboveZero -eq 2) 'profile user counts'
    Assert ($pr.profiles.profilePath.count -eq 2 -and $pr.profiles.profilePath.shapes[0].shape -eq '\\fs1\profiles\<user>' -and $pr.profiles.profilePath.shapes[0].count -eq 2) 'profilePath folded by shape'
    Assert ($pr.profiles.homeDirectory.count -eq 3 -and @($pr.profiles.homeDirectory.shapes | Where-Object { $_.shape -eq 'D:\Data\<user>' }).Count -eq 1) 'homeDirectory shapes'
    Assert ($pr.profiles.homeDrive.count -eq 2 -and $pr.profiles.scriptPath.count -eq 1) 'homeDrive and scriptPath counts'
    Assert ($pj -notmatch 'usr1|usr2|usr3|usr4') 'no user names in the Profiles output'
    Assert (@($pr.fdeployGpos | Where-Object { $_.name -eq 'Folder redirection' -and $_.files -contains 'fdeploy.ini' -and $_.files -contains 'fdeploy1.ini' }).Count -eq 1) 'GPOs holding fdeploy files'
    Assert (@($pr.fdeployGpos).Count -eq 1 -and $pr.fdeployScanComplete -eq $true) 'only GPOs with fdeploy files listed'
    # The SYSVOL scan checks the clock for every GPO and says when it stopped early.
    $savedClock = $script:GpeClock
    $script:tick = 0
    $tickClock = [pscustomobject]@{}
    Add-Member -InputObject $tickClock -MemberType ScriptProperty -Name Elapsed -Value { $script:tick++; [timespan]::FromSeconds($(if ($script:tick -gt 6) { 41 } else { 0 })) }
    $script:GpeClock = $tickClock
    $pt = Invoke-GpoEvidence -Section Profiles -Context $ctx | ConvertFrom-Json
    $script:GpeClock = $savedClock
    Assert ($pt.fdeployScanComplete -eq $false) 'Profiles scan stops at the time budget and says so'

    # Dc section.
    $ctx.Domain = [pscustomobject]@{ DNSRoot = 'example.invalid'; NetBIOSName = 'EXAMPLE'; DomainMode = 'Windows2016Domain'; PDCEmulator = 'dc1.example.invalid'; RIDMaster = 'dc1.example.invalid'; InfrastructureMaster = 'dc1.example.invalid' }
    $ctx.Forest = [pscustomobject]@{ ForestMode = 'Windows2016Forest'; RootDomain = 'example.invalid'; SchemaMaster = 'dc1.example.invalid'; DomainNamingMaster = 'dc1.example.invalid' }
    $ctx.ConfigDN = 'CN=Configuration,DC=example,DC=invalid'
    function Get-ADDomainController { param($Filter, $ErrorAction) @([pscustomobject]@{ HostName = 'dc1.example.invalid'; Site = 'Site1'; OperatingSystem = 'Windows Server 2022 Datacenter'; IsGlobalCatalog = $true; IsReadOnly = $false }) }
    function Get-ADObject { param($LDAPFilter, $SearchBase, $Identity, $Properties, $Server, $ErrorAction)
        if ($LDAPFilter -eq '(objectClass=nTDSDSA)') { return @('DC1', 'OLD1' | ForEach-Object { [pscustomobject]@{ DistinguishedName = "CN=NTDS Settings,CN=$_,CN=Servers,CN=Site1,CN=Sites,CN=Configuration,DC=example,DC=invalid" } }) }
        if ($LDAPFilter -eq '(objectClass=msDFSR-Member)') { return @('DC1', 'OLD1' | ForEach-Object { [pscustomobject]@{ Name = $_ } }) }
        throw [ArgumentException]::new('unexpected') }
    function Get-ADComputer { param($LDAPFilter, $Properties, $Server, $ErrorAction)
        if ($LDAPFilter -notlike '*1.2.840.113556.1.4.803:=8192*') { throw 'wrong filter' }
        @([pscustomobject]@{ Name = 'DC1'; Enabled = $true; LastLogonTimestamp = ([datetime]'2026-11-18').ToFileTimeUtc(); OperatingSystem = 'Windows Server 2022 Datacenter' },
            [pscustomobject]@{ Name = 'OLD1'; Enabled = $false; LastLogonTimestamp = ([datetime]'2024-03-02').ToFileTimeUtc(); OperatingSystem = 'Windows Server 2012 R2 Standard' }) }
    function Get-CimInstance { param($Namespace, $ClassName, $OperationTimeoutSec, $ErrorAction) @([pscustomobject]@{ ReplicatedFolderName = 'SYSVOL Share'; State = 5 }) }
    function Get-WinEvent { param($FilterHashtable, $MaxEvents, $ErrorAction)
        @([pscustomobject]@{ TimeCreated = [datetime]'2026-11-10T08:30:00Z'; Message = "The DFS Replication service stopped replication on the replicated folder.`r`nPartner DNS Address: old1.example.invalid`r`nReplication Group Name: Domain System Volume" }) }
    $script:repCsv = @'
showrepl_COLUMNS,Destination DSA Site,Destination DSA,Naming Context,Source DSA Site,Source DSA,Transport Type,Number of Failures,Last Failure Time,Last Success Time,Last Failure Status
showrepl_INFO,Site1,DC1,"DC=example,DC=invalid",Site1,OLD1,RPC,5,2026-11-19 10:00:00,2026-03-01 09:00:00,1722
showrepl_INFO,Site1,DC1,"CN=Configuration,DC=example,DC=invalid",Site1,OLD1,RPC,2,2026-11-19 10:00:00,2026-03-01 09:00:00,1722
showrepl_INFO,Site1,DC1,"DC=example,DC=invalid",Site1,DC2,RPC,0,0,2026-11-19 10:00:00,0
'@
    function Invoke-GpeNative { param([string]$Path, [string[]]$Arguments, [int]$TimeoutSec) [pscustomobject]@{ ExitCode = 0; Output = $script:repCsv; TimedOut = $false } }
    function Resolve-DnsName { param($Name, $Type, $Server, [switch]$DnsOnly, $ErrorAction)
        if ($Type -eq 'NS') { return @('dc1.example.invalid.', 'old1.example.invalid.' | ForEach-Object { [pscustomobject]@{ Name = $Name; NameHost = $_ } }) }
        @('dc1.example.invalid', 'old1.example.invalid' | ForEach-Object { [pscustomobject]@{ Name = $Name; NameTarget = $_ } }) }
    $dj = Invoke-GpoEvidence -Section Dc -Context $ctx
    $dr = $dj | ConvertFrom-Json
    Assert ($dr.section -eq 'Dc' -and $dr.fsmo.pdc -eq 'dc1.example.invalid' -and $dr.fsmo.schema -eq 'dc1.example.invalid' -and $dr.dcs[0].name -eq 'dc1.example.invalid') 'DCs and FSMO holders'
    Assert (@($dr.ntds | ForEach-Object { $_.server }) -contains 'OLD1' -and $dr.ntds[0].site -eq 'Site1') 'NTDS Settings objects'
    $old = @($dr.serverTrust | Where-Object { $_.name -eq 'OLD1' })[0]
    Assert ($old.enabled -eq $false -and $old.lastLogon -eq '2024-03-02' -and $old.os -like '*2012*') 'SERVER_TRUST computers'
    Assert (@($dr.dfsrMembers) -contains 'OLD1' -and $dr.dfsrLocal[0].folder -eq 'SYSVOL Share' -and $dr.dfsrLocal[0].state -eq 'InError') 'DFSR members and local state'
    Assert ($dr.last4012.found -and $dr.last4012.time -eq '2026-11-10 08:30' -and $dr.last4012.partner -eq 'old1.example.invalid') 'latest 4012 and partner'
    Assert ($dr.repadmin.rows -eq 3 -and $dr.repadmin.failing -eq 2 -and @($dr.repadmin.failingSources) -contains 'OLD1') 'repadmin failure count'
    Assert (@($dr.dnsNs) -contains 'old1.example.invalid.' -and @($dr.dnsSrv) -contains 'old1.example.invalid') 'NS and SRV record names'
    $stale = @($dr.staleCandidates | Where-Object { $_.name -eq 'old1' })[0]
    Assert ($stale -and $stale.sources -match 'ntds' -and $stale.sources -match 'trust' -and $stale.sources -match 'dfsr' -and $stale.sources -match 'ns' -and $stale.sources -match 'srv') 'stale DC-like object found across sources'
    Assert (@($dr.staleCandidates | Where-Object { $_.name -eq 'dc1' }).Count -eq 0) 'live DC not stale'
    Assert ([Text.Encoding]::UTF8.GetByteCount($dj) -le 8000) 'Dc output bounded'
    # A live DC beyond the 20-row display cap is not stale.
    function Get-ADDomainController { param($Filter, $ErrorAction) @(1..21 | ForEach-Object { [pscustomobject]@{ HostName = "dc$_.example.invalid"; Site = 'Site1'; OperatingSystem = 'Windows Server 2022'; IsGlobalCatalog = $false; IsReadOnly = $false } }) }
    function Resolve-DnsName { param($Name, $Type, $Server, [switch]$DnsOnly, $ErrorAction) @([pscustomobject]@{ Name = $Name; NameTarget = 'dc21.example.invalid' }, [pscustomobject]@{ Name = $Name; NameTarget = 'gone9.example.invalid' }) }
    $d21 = Invoke-GpoEvidence -Section Dc -Context $ctx | ConvertFrom-Json
    Assert (@($d21.dcs).Count -eq 20 -and $d21.truncated -and @($d21.staleCandidates | Where-Object { $_.name -eq 'dc21' }).Count -eq 0 -and @($d21.staleCandidates | Where-Object { $_.name -eq 'gone9' }).Count -eq 1) 'live DC past the display cap is not stale'
    # One failing source is reported, not fatal.
    function Get-ADComputer { throw [UnauthorizedAccessException]::new('denied') }
    $df = Invoke-GpoEvidence -Section Dc -Context $ctx | ConvertFrom-Json
    Assert ($df.serverTrust.status -eq 'unavailable' -and $df.serverTrust.error -eq 'UnauthorizedAccessException' -and $df.serverTrust.message -eq 'denied' -and $df.ntds.Count -ge 1) 'a failing Dc source does not stop the others'
    # Past the time budget a source is skipped, not started.
    $script:GpeClock = [Diagnostics.Stopwatch]::StartNew(); $savedClock = $script:GpeClock
    $slow = [pscustomobject]@{ Elapsed = [timespan]::FromSeconds(41) }
    $script:GpeClock = $slow
    $dt = Invoke-GpoEvidence -Section Dc -Context $ctx | ConvertFrom-Json
    $script:GpeClock = $savedClock
    Assert ($dt.dcs.status -eq 'timeBudget' -and $dt.repadmin.status -eq 'timeBudget') 'Dc sources stop starting after 40 seconds'
    Remove-Item function:Get-ADUser, function:Get-ADDomainController, function:Get-ADComputer, function:Get-CimInstance, function:Get-WinEvent, function:Invoke-GpeNative, function:Resolve-DnsName

    $threw = $false; try { [void](Invoke-GpoEvidence -Section Nope -Context $ctx) } catch { $threw = $true }
    Assert $threw 'unknown section refused'

    $huge = [ordered]@{ status = 'collected'; rows = @(1..500 | ForEach-Object { 'é' * 50 }) }
    $hj = ConvertTo-GpeBoundedJson $huge
    Assert ([Text.Encoding]::UTF8.GetByteCount($hj) -le 8000 -and ($hj | ConvertFrom-Json).truncated) 'bounded JSON'
} finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
'gpo-evidence tests passed'
