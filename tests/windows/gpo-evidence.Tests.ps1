$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
function Assert($Condition, $Label) { if (-not $Condition) { throw "FAIL $Label" } }
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$path = Join-Path $root 'windows/packages/gpo-evidence/Invoke-GpoEvidence.ps1'
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

    function Get-ADObject { param($LDAPFilter, $SearchBase, $Identity, $Properties, $Server, $ErrorAction)
        if ($Identity -like '*DFSR-GlobalSettings*') { return [pscustomobject]@{ 'msDFSR-Flags' = 48 } }
        if ($Identity) { throw [ArgumentException]::new('missing') }
        @([pscustomobject]@{ DistinguishedName = 'DC=example,DC=invalid'; gPLink = "[LDAP://cn={$ddpId},cn=policies,cn=system,DC=example,DC=invalid;0]" }) }
    function Get-ADDomainController { param($Filter, $ErrorAction) @([pscustomobject]@{ HostName = 'dc1.example.invalid'; Site = 'Site1'; OperatingSystem = 'Windows Server 2022 Datacenter'; IsGlobalCatalog = $true; IsReadOnly = $false }) }
    function Get-Service { param($Name, $ErrorAction) if ($Name -eq 'DFSR') { [pscustomobject]@{ Status = 'Running' } } else { throw 'absent' } }
    function Get-WinEvent { param($FilterHashtable, $MaxEvents, $ErrorAction) @([pscustomobject]@{ Id = 4012 }, [pscustomobject]@{ Id = 4012 }) }
    $sj = Invoke-GpoEvidence -Context $ctx
    $s = $sj | ConvertFrom-Json
    Assert ($s.section -eq 'Summary' -and $s.domain.mode -eq 'Windows2016Domain' -and $s.domain.forestMode -eq 'Windows2016Forest') 'functional levels'
    Assert ($s.dcs[0].gc -and $s.sysvol.type -eq 'DFSR' -and $s.sysvol.migrationState -eq 'Eliminated') 'DCs and SYSVOL DFSR'
    Assert ($s.sysvol.serviceDFSR -eq 'Running' -and $s.sysvol.serviceNtFrs -eq 'absent' -and $s.sysvol.dfsrWarnings7d.'4012' -eq 2) 'SYSVOL health hints'
    Assert ($s.gpoCount -eq 122 -and $s.versionMismatchCount -eq 1 -and $s.cpassword[0].count -eq 1) 'summary counts'
    Assert ([Text.Encoding]::UTF8.GetByteCount($sj) -le 8000 -and $sj -notmatch $secret) 'summary bounded and redacted'

    # Review: a capped scan says so instead of reporting a clean result.
    [void](New-Item -ItemType Directory -Path (Join-Path $gppDir 'User\Preferences\Drives') -Force)
    [IO.File]::WriteAllText((Join-Path $gppDir 'User\Preferences\Drives\Drives.xml'), '<Drives/>')
    $capped = Find-GpeCpassword -PoliciesPath $policies -Ids @($gppId) -MaxFiles 1
    # Review: an unreadable Preferences subtree is not a clean result.
    & {
        function Get-ChildItem { [CmdletBinding()] param($LiteralPath, [switch]$Recurse, $Filter, [switch]$File) Write-Error 'Access to the path is denied.' }
        $denied = Find-GpeCpassword -PoliciesPath $policies -Ids @($gppId)
        Assert (-not $denied.complete -and $denied.errors -ge 1) 'enumeration error marks the scan incomplete'
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

    $huge = [ordered]@{ status = 'collected'; rows = @(1..500 | ForEach-Object { 'é' * 50 }) }
    $hj = ConvertTo-GpeBoundedJson $huge
    Assert ([Text.Encoding]::UTF8.GetByteCount($hj) -le 8000 -and ($hj | ConvertFrom-Json).truncated) 'bounded JSON'
} finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
'gpo-evidence tests passed'
