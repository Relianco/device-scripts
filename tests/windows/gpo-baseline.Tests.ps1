$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
function Assert($Condition, $Label) { if (-not $Condition) { throw "FAIL $Label" } }
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$path = Join-Path $root 'windows/packages/gpo-baseline/Invoke-GpoBaseline.ps1'
$env:RELIAN_DEPLOY_TEST = '1'
. $path

# Parses under the PowerShell grammar and uses no syntax newer than Windows PowerShell 5.1.
$tokens = $null; $errors = $null
[void][Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
Assert ($errors.Count -eq 0) 'parser'
foreach ($kind in @('QuestionQuestion', 'QuestionQuestionEquals', 'QuestionDot', 'QuestionLBracket', 'AndAnd', 'OrOr')) {
    Assert (-not @($tokens | Where-Object { [string]$_.Kind -eq $kind })) "no PowerShell 7 token $kind"
}
Assert (-not @($tokens | Where-Object { [string]$_.Kind -eq 'QuestionMark' })) 'no ternary operator'

# ---- Pure helpers ----
Assert ((Get-GpbNextVersion -AdVersion 0x00030005 -IniVersion 0x00030005) -eq 0x00030006) 'computer version is the low word'
Assert ((Get-GpbNextVersion -AdVersion 0x00030005 -IniVersion 0x00010009) -eq 0x0003000A) 'each word takes the larger of AD and GPT.INI'
Assert ((Get-GpbNextVersion -AdVersion -2147418107 -IniVersion 0) -eq [long]2147549190) 'negative AD integer is read as unsigned'
# 0x80010006 written as a decimal: PowerShell reads that hex literal as a negative Int32.
Assert ((ConvertTo-GpbAdVersion ([long]2147549190)) -eq -2147418106) 'AD versionNumber written as signed 32-bit'
Assert ((ConvertTo-GpbAdVersion 0x00030006) -eq 0x00030006) 'small version unchanged'
$wrapped = $false; try { [void](Get-GpbNextVersion -AdVersion 0x0000FFFF -IniVersion 0) } catch { $wrapped = $true }
Assert $wrapped 'computer version overflow refused'

$sec = '[{827D319E-6EAC-11D2-A4EA-00C04F79F83A}{803E14A0-B4FB-11D0-A0D0-00A0C90F574B}]'
$aud = '[{F3CCC681-B74C-4060-9F26-CD84525DCA2A}{0F3F3735-573D-9804-99E4-AB2A69BA5FD4}]'
$reg = '[{35378EAC-683F-11D2-A89A-00C04FBBCFA2}{D02B1F72-3407-48AE-BA88-E8213C6761F1}]'
Assert ((Add-GpbExtensionNames -Current $reg -Pairs @($aud, $sec)) -eq ($reg + $sec + $aud)) 'extension pairs sorted by CSE GUID'
Assert ((Add-GpbExtensionNames -Current ($reg + $sec) -Pairs @($sec)) -eq ($reg + $sec)) 'extension pair not duplicated'
Assert ((Add-GpbExtensionNames -Current '' -Pairs @($sec)) -eq $sec) 'extension names from empty'
$tool2 = '[{827D319E-6EAC-11D2-A4EA-00C04F79F83A}{00000000-0000-0000-0000-000000000001}]'
Assert ((Add-GpbExtensionNames -Current $tool2 -Pairs @($sec)) -eq '[{827D319E-6EAC-11D2-A4EA-00C04F79F83A}{00000000-0000-0000-0000-000000000001}{803E14A0-B4FB-11D0-A0D0-00A0C90F574B}]') 'tool GUIDs merged under one CSE'

$inf = "[Unicode]`r`nUnicode=yes`r`n[System Access]`r`nMinimumPasswordLength = 8`r`n[Version]`r`nsignature=`"`$CHICAGO`$`"`r`nRevision=1`r`n[Service General Setting]`r`n`"Fax`",3,`"`"`r`n"
$parsed = ConvertFrom-GpbInf $inf
Assert ($parsed['System Access']['MinimumPasswordLength'] -eq '8') 'inf key parsed'
Assert ($parsed['Service General Setting']['Fax'] -eq '3,""') 'inf service parsed'
$parsed['Service General Setting']['Spooler'] = '4,""'
$text = ConvertTo-GpbInf $parsed
Assert ($text -match '(?m)^"Spooler",4,""\r$' -and $text -match '(?m)^"Fax",3,""\r$' -and $text -match 'MinimumPasswordLength = 8') 'inf round trip keeps unrelated keys'
Assert ($text.StartsWith("[Unicode]`r`nUnicode=yes`r`n[Version]")) 'inf header first'

$csv = "Machine Name,Policy Target,Subcategory,Subcategory GUID,Inclusion Setting,Exclusion Setting,Setting Value`r`n,System,Audit Logon,{0cce9215-69ae-11d9-bed3-505054503030},Success,,1`r`n,,Option:CrashOnAuditFail,,Disabled,,0`r`n"
$rows = ConvertFrom-GpbAuditCsv $csv
Assert ($rows['{0cce9215-69ae-11d9-bed3-505054503030}'].Value -eq '1') 'audit row keyed by subcategory GUID'
Assert ($rows.Contains('Option:CrashOnAuditFail')) 'audit option row kept'
$out = ConvertTo-GpbAuditCsv $rows
Assert ($out.StartsWith('Machine Name,Policy Target,Subcategory,Subcategory GUID,Inclusion Setting') -and $out -match 'Option:CrashOnAuditFail') 'audit csv round trip'

Assert ((Protect-GpbText 'Groups.xml cpassword="abc"') -eq '[sensitive line omitted]') 'cpassword redacted'

# ---- Fake domain, GroupPolicy module and SYSVOL ----
$tmp = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('n'))
[void](New-Item -ItemType Directory -Path $tmp)
function New-FakeWorld {
    $script:calls = [Collections.Generic.List[string]]::new()
    $script:gpos = @{}
    $script:ad = @{}
    $script:regValues = @{}
    $script:links = @{}
    $script:failSetAfter = -1
    $script:setCount = 0
    $script:backupFails = $false
    $script:removeFails = $false
    $script:adGetCount = 0
    $script:adGetFailAt = -1
    $script:wmi = @{}
    $script:downloads = [Collections.Generic.List[string]]::new()
    $script:downloadBody = 'fake comet script'
    $script:perms = @{}
    $script:pol = [Collections.Generic.List[string]]::new()
    $script:sids = @{ 'Group|Authenticated Users' = 'S-1-5-11'; 'Group|Domain Admins' = 'S-1-5-21-9-512'; 'Group|Accounting' = 'S-1-5-21-9-1101'; 'User|Pilot' = 'S-1-5-21-9-1102'; 'Computer|PILOT-PC' = 'S-1-5-21-9-1103' }
    $policies = Join-Path $tmp ([guid]::NewGuid().ToString('n'))
    [void](New-Item -ItemType Directory -Path $policies)
    return @{ Server = 'pdc.example.invalid'; DomainDN = 'DC=example,DC=invalid'; PoliciesPath = $policies; BackupRoot = (Join-Path $policies 'backups'); IsPdc = $true; DnsRoot = 'example.invalid' }
}
function Add-FakeGpo {
    param($Context, [string]$Name, [string]$Comment, [guid]$Id = [guid]::NewGuid())
    $script:gpos[$Name] = [pscustomobject]@{ Id = $Id; DisplayName = $Name; Description = $Comment }
    $script:ad[$Id.ToString()] = @{ versionNumber = 0; gPCMachineExtensionNames = ''; gPCWQLFilter = $null }
    # New-GPO's default security: Authenticated Users apply, admins edit.
    $script:perms[$Id.ToString()] = [Collections.Generic.List[object]]@(@{ Name = 'Authenticated Users'; Sid = 'S-1-5-11'; Type = 'WellKnownGroup'; Permission = 'GpoApply' }, @{ Name = 'Domain Admins'; Sid = 'S-1-5-21-9-512'; Type = 'Group'; Permission = 'GpoEditDeleteModifySecurity' })
    $dir = Join-Path $Context.PoliciesPath ('{' + $Id.ToString().ToUpper() + '}')
    [void](New-Item -ItemType Directory -Path $dir -Force)
    [IO.File]::WriteAllText((Join-Path $dir 'GPT.INI'), "[General]`r`nVersion=0`r`ndisplayName=New Group Policy Object`r`n")
    return $script:gpos[$Name]
}
function Find-FakeGpo { param($Guid) foreach ($g in $script:gpos.Values) { if ($g.Id -eq [guid]$Guid) { return $g } } }
function Step-FakeVersion {
    param($Context, [guid]$Id)
    $script:ad[$Id.ToString()].versionNumber = [int]$script:ad[$Id.ToString()].versionNumber + 1
    $ini = Join-Path $Context.PoliciesPath ('{' + $Id.ToString().ToUpper() + '}\GPT.INI')
    [IO.File]::WriteAllText($ini, "[General]`r`nVersion=$($script:ad[$Id.ToString()].versionNumber)`r`ndisplayName=New Group Policy Object`r`n")
}
function Import-Module { param([Parameter(ValueFromRemainingArguments)]$Rest) }
function Get-GPO {
    [CmdletBinding()]
    param($Name, $Guid, $Server)
    $script:calls.Add('Get-GPO')
    if ($Guid) { $g = Find-FakeGpo $Guid } elseif ($script:gpos.ContainsKey($Name)) { $g = $script:gpos[$Name] } else { $g = $null }
    if (-not $g) { throw [System.ArgumentException]::new('not found') }
    return $g
}
function New-GPO {
    [CmdletBinding()]
    param($Name, $Comment, $Server)
    $script:calls.Add('New-GPO')
    return (Add-FakeGpo -Context $script:ctx -Name $Name -Comment $Comment)
}
function Get-GPRegistryValue {
    [CmdletBinding()]
    param($Guid, $Key, $ValueName, $Server)
    $k = "$Guid|$Key|$ValueName"
    if (-not $script:regValues.ContainsKey($k)) { throw [System.ArgumentException]::new('missing value') }
    return $script:regValues[$k]
}
function Set-GPRegistryValue {
    [CmdletBinding()]
    param($Guid, $Key, $ValueName, $Type, $Value, $Server)
    $script:setCount++
    if ($script:failSetAfter -ge 0 -and $script:setCount -gt $script:failSetAfter) { throw 'simulated write failure' }
    $script:calls.Add("Set-GPRegistryValue $Key\$ValueName")
    $side = 'Machine'; if ($Key -like 'HKCU\*') { $side = 'User' }
    $script:pol.Add("$Guid|$side|$Key\$ValueName")
    $script:regValues["$Guid|$Key|$ValueName"] = [pscustomobject]@{ Value = $Value; Type = $Type }
    Step-FakeVersion -Context $script:ctx -Id $Guid
    $o = $script:ad[([guid]$Guid).ToString()]
    $o.gPCMachineExtensionNames = Add-GpbExtensionNames -Current $o.gPCMachineExtensionNames -Pairs @($reg)
}
function Backup-GPO {
    [CmdletBinding()]
    param($Guid, $Path, $Comment, $Server)
    $script:calls.Add('Backup-GPO')
    # Non-terminating, as a binary cmdlet reports most failures.
    if ($script:backupFails) { Write-Error 'backup failed'; return }
    Assert (Test-Path -LiteralPath $Path) 'backup folder exists before Backup-GPO'
    return [pscustomobject]@{ Id = [guid]'11111111-2222-3333-4444-555555555555' }
}
function Restore-GPO { [CmdletBinding()] param($BackupId, $Path, $Server) $script:calls.Add("Restore-GPO $BackupId") }
function Remove-GPO { [CmdletBinding()] param($Guid, $Server) $script:calls.Add('Remove-GPO'); if ($script:removeFails) { Write-Error 'remove failed'; return }; $g = Find-FakeGpo $Guid; $script:gpos.Remove($g.DisplayName); $script:ad.Remove($g.Id.ToString()) }
function Get-ADObject {
    [CmdletBinding()]
    param($Identity, $Properties, $Server, $SearchBase, $LDAPFilter)
    if ($LDAPFilter -like '*msWMI-Som*') {
        $name = [regex]::Match($LDAPFilter, 'msWMI-Name=([^)]*)\)').Groups[1].Value
        return @($script:wmi.Values | Where-Object { $_.'msWMI-Name' -eq $name } | ForEach-Object { [pscustomobject]$_ })
    }
    if ($LDAPFilter -like '*sAMAccountName=*') {
        $sam = [regex]::Match($LDAPFilter, 'sAMAccountName=([^)]*)\)').Groups[1].Value
        $type = 'User'; if ($LDAPFilter -like '*objectClass=group*') { $type = 'Group' } elseif ($LDAPFilter -like '*objectClass=computer*') { $type = 'Computer'; Assert ($sam.EndsWith('$')) 'computer looked up by sAMAccountName with $' }
        $sid = $script:sids["$type|$($sam.TrimEnd('$'))"]
        if ($sid) { return [pscustomobject]@{ objectSid = $sid } }
        return
    }
    if ($LDAPFilter -like '*gPCWQLFilter*') {
        $fid = [regex]::Match($LDAPFilter, '\{[0-9A-Fa-f-]{36}\}').Value
        return @($script:ad.Values | Where-Object { [string]$_.gPCWQLFilter -like "*$fid*" } | ForEach-Object { [pscustomobject]$_ })
    }
    $script:adGetCount++
    if ($script:adGetCount -eq $script:adGetFailAt) { throw 'simulated AD read failure' }
    $id = ([regex]::Match($Identity, '\{([0-9a-fA-F-]{36})\}').Groups[1].Value).ToLower()
    $o = $script:ad[$id]
    return [pscustomobject]@{ versionNumber = $o.versionNumber; gPCMachineExtensionNames = $o.gPCMachineExtensionNames; gPCWQLFilter = $o.gPCWQLFilter }
}
function New-ADObject {
    [CmdletBinding()]
    param($Name, $Type, $Path, $OtherAttributes, $Server)
    $script:calls.Add("New-ADObject $Type")
    $o = @{ DistinguishedName = "CN=$Name,$Path" }
    foreach ($k in $OtherAttributes.Keys) { $o[$k] = $OtherAttributes[$k] }
    $script:wmi[$Name] = $o
}
function Remove-ADObject {
    [CmdletBinding()]
    param($Identity, [switch]$Confirm, $Server)
    $script:calls.Add('Remove-ADObject')
    foreach ($k in @($script:wmi.Keys)) { if ($script:wmi[$k].DistinguishedName -eq $Identity) { $script:wmi.Remove($k) } }
}
function Set-ADObject {
    [CmdletBinding()]
    param($Identity, $Replace, $Clear, $Server)
    $script:calls.Add('Set-ADObject')
    if ($Identity -like '*CN=SOM,*') {
        foreach ($w in $script:wmi.Values) { if ($w.DistinguishedName -eq $Identity) { foreach ($k in $Replace.Keys) { $w[$k] = $Replace[$k] } } }
        return
    }
    $id = ([regex]::Match($Identity, '\{([0-9a-fA-F-]{36})\}').Groups[1].Value).ToLower()
    if ($Clear) { $script:ad[$id][$Clear] = $null }
    if ($Replace) { foreach ($k in $Replace.Keys) { $script:ad[$id][$k] = $Replace[$k] } }
}
function Get-GPPermission {
    [CmdletBinding()]
    param($Guid, [switch]$All, $Server)
    Assert $All 'permissions read with -All'
    return @($script:perms[([guid]$Guid).ToString()] | ForEach-Object { [pscustomobject]@{ Trustee = [pscustomobject]@{ Name = $_.Name; Sid = $_.Sid; SidType = $_.Type }; Permission = $_.Permission; Denied = $false; Inherited = $false } })
}
function Set-GPPermission {
    [CmdletBinding()]
    param($Guid, $PermissionLevel, $TargetName, $TargetType, [switch]$Replace, $Server)
    $script:calls.Add("Set-GPPermission $TargetName $PermissionLevel")
    Assert $Replace 'permission replaced, not added to'
    $sid = $script:sids["$TargetType|$TargetName"]
    Assert $sid "Set-GPPermission target resolves: $TargetType $TargetName"
    $list = $script:perms[([guid]$Guid).ToString()]
    $e = @($list | Where-Object { $_.Sid -eq $sid }) | Select-Object -First 1
    # GPMC lists a computer trustee by its sAMAccountName, with the $.
    $listed = $TargetName; if ($TargetType -eq 'Computer') { $listed = "$TargetName$" }
    if ($PermissionLevel -eq 'None') { if ($e) { [void]$list.Remove($e) } }
    elseif ($e) { $e.Permission = $PermissionLevel } else { $list.Add(@{ Name = $listed; Sid = $sid; Type = $TargetType; Permission = $PermissionLevel }) }
}
function Get-FakePermission { param($Gpo, [string]$Sid) $e = @($script:perms[$Gpo.Id.ToString()] | Where-Object { $_.Sid -eq $Sid }) | Select-Object -First 1; if ($e) { return $e.Permission }; return 'None' }
function Get-GPInheritance {
    [CmdletBinding()]
    param($Target, $Server)
    return [pscustomobject]@{ GpoLinks = @($script:links.Values | Where-Object { $_.Target -eq $Target }) }
}
function New-GPLink {
    [CmdletBinding()]
    param($Guid, $Target, $LinkEnabled, $Server)
    $script:calls.Add("New-GPLink $LinkEnabled")
    $script:links["$Guid|$Target"] = [pscustomobject]@{ GpoId = [guid]$Guid; Target = $Target; Enabled = ($LinkEnabled -eq 'Yes') }
}
function Set-GPLink { [CmdletBinding()] param($Guid, $Target, $LinkEnabled, $Server) $script:calls.Add("Set-GPLink $LinkEnabled") }
$script:GpbDownload = { param($Url, $Path) $script:downloads.Add($Url); [IO.File]::WriteAllText($Path, $script:downloadBody) }
function Protect-GpbBackupRoot { param($Path) $script:calls.Add('Protect-GpbBackupRoot') }
function Get-Writes { return ,@($script:calls | Where-Object { $_ -notmatch '^(Get-GPO)$' }) }

try {
    $def = Get-GpbDefinition 'cis-ws2022-dc-low-risk'
    Assert ($null -ne $def) 'embedded definition found'

    # Plan-only is the default: no Apply argument, nothing written.
    $script:ctx = New-FakeWorld
    $r = Invoke-GpoBaseline -Action Install -Definition 'cis-ws2022-dc-low-risk' -Context $script:ctx
    Assert ($r.exitCode -eq 0 -and $r.report.status -eq 'plan') 'plan status'
    Assert ((Get-Writes).Count -eq 0) 'plan made no writes'
    Assert (@($r.report.changes | Where-Object { $_.kind -eq 'create' }).Count -eq 1) 'plan shows GPO creation'
    $expected = @($def.registry).Count + @($def.security).Count + @($def.audit).Count + 1
    Assert (@($r.report.changes).Count -eq $expected) 'plan lists every definition value'
    Assert ([IO.Directory]::GetDirectories($script:ctx.PoliciesPath).Count -eq 0) 'plan wrote no SYSVOL files'

    $r = Invoke-GpoBaseline -Action Install -Definition 'cis-ws2022-dc-low-risk' -Apply 'false' -Context $script:ctx
    Assert ($r.report.status -eq 'plan' -and (Get-Writes).Count -eq 0) 'Apply=false is plan-only'
    $r = Invoke-GpoBaseline -Action Install -Definition 'cis-ws2022-dc-low-risk' -Apply 'yes' -Context $script:ctx
    Assert ($r.exitCode -eq 1 -and (Get-Writes).Count -eq 0) 'unrecognized Apply value refused'
    $r = Invoke-GpoBaseline -Action Install -Definition 'no-such-definition' -Context $script:ctx
    Assert ($r.exitCode -eq 1 -and $r.report.status -eq 'refused') 'unknown definition refused'

    # Apply creates and writes only the definition's values.
    $r = Invoke-GpoBaseline -Action Install -Definition 'cis-ws2022-dc-low-risk' -Apply 'true' -Context $script:ctx
    Assert ($r.exitCode -eq 0 -and $r.report.status -eq 'applied') "apply status $($r.report.status) $($r.report | ConvertTo-Json -Depth 6 -Compress)"
    $gpo = $script:gpos[$def.gpoName]
    Assert ($gpo.Description -match [regex]::Escape('[relian-gpo-baseline:cis-ws2022-dc-low-risk]')) 'ownership marker in description'
    $setCalls = @($script:calls | Where-Object { $_ -like 'Set-GPRegistryValue *' })
    $wanted = @($def.registry | ForEach-Object { "Set-GPRegistryValue $($_.key)\$($_.valueName)" })
    Assert ($setCalls.Count -eq $wanted.Count -and -not (Compare-Object $setCalls $wanted)) 'registry writes are exactly the definition values'
    foreach ($item in $def.registry) {
        $v = $script:regValues["$($gpo.Id)|$($item.key)|$($item.valueName)"]
        Assert ([string]$v.Value -eq [string]$item.value -and [string]$v.Type -eq [string]$item.type) "registry value $($item.valueName)"
    }
    $gpoDir = Join-Path $script:ctx.PoliciesPath ('{' + $gpo.Id.ToString().ToUpper() + '}')
    $infPath = Join-Path $gpoDir 'Machine\Microsoft\Windows NT\SecEdit\GptTmpl.inf'
    $bytes = [IO.File]::ReadAllBytes($infPath)
    Assert ($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) 'GptTmpl.inf is UTF-16LE with BOM'
    $infText = [IO.File]::ReadAllText($infPath)
    foreach ($item in $def.security) { Assert ((ConvertFrom-GpbInf $infText)[$item.section][$item.key] -eq $item.value) "security $($item.key)" }
    $auditText = [IO.File]::ReadAllText((Join-Path $gpoDir 'Machine\Microsoft\Windows NT\Audit\audit.csv'))
    foreach ($item in $def.audit) { Assert ((ConvertFrom-GpbAuditCsv $auditText)[$item.guid].Value -eq [string]$item.setting) "audit $($item.subcategory)" }
    $adObj = $script:ad[$gpo.Id.ToString()]
    $iniVersion = [long]([regex]::Match([IO.File]::ReadAllText((Join-Path $gpoDir 'GPT.INI')), 'Version=(\d+)').Groups[1].Value)
    Assert ([long]$adObj.versionNumber -eq $iniVersion -and $iniVersion -eq (@($def.registry).Count + 1)) 'AD and GPT.INI versions match after one security bump'
    Assert ($adObj.gPCMachineExtensionNames -eq ($reg + $sec + $aud)) 'security and audit CSEs registered in order'
    Assert ([IO.File]::ReadAllText((Join-Path $gpoDir 'GPT.INI')) -match "Version=$iniVersion`r`ndisplayName=New Group Policy Object`r`n") 'GPT.INI version replaced without touching the next line'
    Assert (-not ($script:calls -contains 'Backup-GPO')) 'new GPO has nothing to back up'

    # Second run is idempotent.
    $script:calls.Clear()
    $r = Invoke-GpoBaseline -Action Install -Definition 'cis-ws2022-dc-low-risk' -Apply 'true' -Context $script:ctx
    Assert ($r.exitCode -eq 0 -and $r.report.status -eq 'noChange' -and @($r.report.changes).Count -eq 0) 'second apply has no changes'
    Assert ((Get-Writes).Count -eq 0) 'second apply wrote nothing'

    # Drift on an owned GPO: backup before the first write, backup id printed.
    $first = $def.registry[0]
    $script:regValues["$($gpo.Id)|$($first.key)|$($first.valueName)"] = [pscustomobject]@{ Value = 99; Type = $first.type }
    $script:calls.Clear()
    $r = Invoke-GpoBaseline -Action Install -Definition 'cis-ws2022-dc-low-risk' -Apply 'true' -Context $script:ctx
    $writes = Get-Writes
    Assert ($r.exitCode -eq 0 -and @($r.report.changes).Count -eq 1 -and [string]$r.report.changes[0].current -eq '99') 'drift diff shows current and desired'
    Assert ($writes[0] -eq 'Protect-GpbBackupRoot' -and $writes[1] -eq 'Backup-GPO' -and $writes[2] -like 'Set-GPRegistryValue *') "backup before write: $($writes -join ', ')"
    Assert ($r.report.backupId -eq '11111111-2222-3333-4444-555555555555') 'backup id reported'
    $last = Join-Path $script:ctx.BackupRoot ('{' + $gpo.Id.ToString().ToUpper() + '}\last-backup.json')
    Assert ((Get-Content -Raw $last | ConvertFrom-Json).backupId -eq '11111111-2222-3333-4444-555555555555') 'last backup recorded'

    # Partial apply: exit 1 and report what was left.
    foreach ($item in $def.registry) { $script:regValues.Remove("$($gpo.Id)|$($item.key)|$($item.valueName)") }
    $script:failSetAfter = 2; $script:setCount = 0
    $r = Invoke-GpoBaseline -Action Install -Definition 'cis-ws2022-dc-low-risk' -Apply 'true' -Context $script:ctx
    Assert ($r.exitCode -eq 1 -and $r.report.status -eq 'partial') 'partial apply exits 1'
    Assert (@($r.report.left).Count -eq (@($def.registry).Count - 2)) 'partial apply lists remaining values'
    Assert ($r.report.error -match 'simulated') 'partial apply reports the error'
    $script:failSetAfter = -1

    # Not the PDC emulator: apply refused before any write.
    $script:ctx.IsPdc = $false; $script:calls.Clear()
    $r = Invoke-GpoBaseline -Action Install -Definition 'cis-ws2022-dc-low-risk' -Apply 'true' -Context $script:ctx
    Assert ($r.exitCode -eq 1 -and $r.report.status -eq 'refused' -and (Get-Writes).Count -eq 0) 'apply off the PDC refused'
    $script:ctx.IsPdc = $true

    # Linking is a separate explicit argument, disabled by default, inside the domain only.
    $script:calls.Clear()
    $r = Invoke-GpoBaseline -Action Install -Definition 'cis-ws2022-dc-low-risk' -LinkTo 'OU=Domain Controllers,DC=example,DC=invalid' -Context $script:ctx
    Assert (-not @($script:calls | Where-Object { $_ -like 'New-GPLink*' }) -and @($r.report.changes | Where-Object { $_.kind -eq 'link' }).Count -eq 1) 'plan shows link, makes none'
    $r = Invoke-GpoBaseline -Action Install -Definition 'cis-ws2022-dc-low-risk' -Apply 'true' -LinkTo 'OU=Domain Controllers,DC=example,DC=invalid' -Context $script:ctx
    Assert ($r.exitCode -eq 0 -and ($script:calls -contains 'New-GPLink No')) 'link created disabled by default'
    $script:calls.Clear()
    $r = Invoke-GpoBaseline -Action Install -Definition 'cis-ws2022-dc-low-risk' -Apply 'true' -LinkTo 'OU=Domain Controllers,DC=example,DC=invalid' -LinkEnabled 'true' -Context $script:ctx
    Assert ($script:calls -contains 'Set-GPLink Yes') 'existing link enabled on request'
    foreach ($bad in @('OU=X,DC=other,DC=invalid', 'DC=example,DC=invalid', 'CN=Computers,DC=example,DC=invalid')) {
        $script:calls.Clear()
        $r = Invoke-GpoBaseline -Action Install -Definition 'cis-ws2022-dc-low-risk' -Apply 'true' -LinkTo $bad -Context $script:ctx
        Assert ($r.exitCode -eq 1 -and (Get-Writes).Count -eq 0) "link target refused: $bad"
    }

    # A same-named GPO without the marker is foreign: refused, untouched.
    $script:ctx = New-FakeWorld
    [void](Add-FakeGpo -Context $script:ctx -Name $def.gpoName -Comment 'made by hand')
    $r = Invoke-GpoBaseline -Action Install -Definition 'cis-ws2022-dc-low-risk' -Apply 'true' -Context $script:ctx
    Assert ($r.exitCode -eq 1 -and $r.report.status -eq 'refused' -and (Get-Writes).Count -eq 0) 'foreign GPO refused'
    $r = Invoke-GpoBaseline -Action Uninstall -Definition 'cis-ws2022-dc-low-risk' -Apply 'true' -Context $script:ctx
    Assert ($r.exitCode -eq 1 -and (Get-Writes).Count -eq 0) 'foreign GPO never removed'

    # Default policies need both the definition flag and the explicit argument.
    $script:ctx = New-FakeWorld
    $ddp = Add-FakeGpo -Context $script:ctx -Name 'Default Domain Policy' -Comment '' -Id '31B2F340-016D-11D2-945F-00C04FB984F9'
    $ddpDef = [pscustomobject]@{ id = 'test-ddp'; gpoName = 'Default Domain Policy'; allowDefaultPolicy = $false; description = 'test'
        registry = @(); audit = @(); security = @([pscustomobject]@{ section = 'System Access'; key = 'MinimumPasswordLength'; value = '14'; cis = '1.1.4' }) }
    $r = Invoke-GpoBaseline -Action Install -DefinitionObject $ddpDef -Apply 'true' -AllowDefaultPolicy 'true' -Context $script:ctx
    Assert ($r.exitCode -eq 1 -and (Get-Writes).Count -eq 0) 'default policy refused when the definition does not opt in'
    $ddpDef.allowDefaultPolicy = $true
    $r = Invoke-GpoBaseline -Action Install -DefinitionObject $ddpDef -Apply 'true' -Context $script:ctx
    Assert ($r.exitCode -eq 1 -and (Get-Writes).Count -eq 0) 'default policy refused without AllowDefaultPolicy'
    $renamed = [pscustomobject]@{ id = 'test-ddp'; gpoName = 'Renamed'; allowDefaultPolicy = $false; description = 't'; registry = @(); audit = @(); security = $ddpDef.security }
    $script:gpos['Renamed'] = $script:gpos['Default Domain Policy']
    $r = Invoke-GpoBaseline -Action Install -DefinitionObject $renamed -Apply 'true' -AllowDefaultPolicy 'true' -Context $script:ctx
    Assert ($r.exitCode -eq 1 -and (Get-Writes).Count -eq 0) 'default policy found by GUID under another name is refused'
    $script:gpos.Remove('Renamed')
    $r = Invoke-GpoBaseline -Action Install -DefinitionObject $ddpDef -Apply 'true' -AllowDefaultPolicy 'true' -Context $script:ctx
    $writes = Get-Writes
    Assert ($r.exitCode -eq 0 -and $writes[1] -eq 'Backup-GPO') 'default policy changed only with both flags, after a backup'
    Assert ($script:gpos['Default Domain Policy'].Description -eq '') 'default policy description untouched'
    $script:calls.Clear()
    $r = Invoke-GpoBaseline -Action Uninstall -DefinitionObject $ddpDef -Apply 'true' -AllowDefaultPolicy 'true' -Context $script:ctx
    Assert ($r.exitCode -eq 0 -and ($script:calls -contains 'Restore-GPO 11111111-2222-3333-4444-555555555555') -and -not ($script:calls -contains 'Remove-GPO')) 'default policy uninstall restores, never removes'

    # Uninstall: plan without Apply; removes only the GPO this package created.
    $script:ctx = New-FakeWorld
    $r = Invoke-GpoBaseline -Action Uninstall -Definition 'cis-ws2022-dc-low-risk' -Apply 'true' -Context $script:ctx
    Assert ($r.exitCode -eq 0 -and $r.report.status -eq 'nothingToUninstall') 'uninstall with no GPO'
    [void](Invoke-GpoBaseline -Action Install -Definition 'cis-ws2022-dc-low-risk' -Apply 'true' -Context $script:ctx)
    $script:calls.Clear()
    $r = Invoke-GpoBaseline -Action Uninstall -Definition 'cis-ws2022-dc-low-risk' -Context $script:ctx
    Assert ($r.exitCode -eq 0 -and $r.report.status -eq 'plan' -and (Get-Writes).Count -eq 0) 'uninstall without Apply is plan-only'
    $r = Invoke-GpoBaseline -Action Uninstall -Definition 'cis-ws2022-dc-low-risk' -Apply 'true' -Context $script:ctx
    $writes = Get-Writes
    Assert ($r.exitCode -eq 0 -and $r.report.status -eq 'removed' -and $writes[-1] -eq 'Remove-GPO' -and ($writes -contains 'Backup-GPO')) 'owned GPO backed up then removed'

    # Review: a non-terminating cmdlet error must stop the run. A failed backup must
    # leave the GPO unchanged, and a failed Remove-GPO must not report success.
    $script:ctx = New-FakeWorld
    [void](Invoke-GpoBaseline -Action Install -Definition 'cis-ws2022-dc-low-risk' -Apply 'true' -Context $script:ctx)
    $gpo = $script:gpos[$def.gpoName]
    $first = $def.registry[0]
    $script:regValues["$($gpo.Id)|$($first.key)|$($first.valueName)"] = [pscustomobject]@{ Value = 99; Type = $first.type }
    $script:backupFails = $true; $script:calls.Clear()
    # Devices run without StrictMode, so a missing backup id must not be caught by it here.
    $ErrorActionPreference = 'Continue'; Set-StrictMode -Off
    try { $r = Invoke-GpoBaseline -Action Install -Definition 'cis-ws2022-dc-low-risk' -Apply 'true' -Context $script:ctx 2>$null }
    finally { $ErrorActionPreference = 'Stop'; Set-StrictMode -Version Latest }
    Assert ($r.exitCode -eq 1 -and -not @($script:calls | Where-Object { $_ -like 'Set-GPRegistryValue*' })) "failed backup stops before any write: $($script:calls -join ', ')"
    $script:backupFails = $false
    $script:removeFails = $true
    # Devices run without StrictMode, so a missing backup id must not be caught by it here.
    $ErrorActionPreference = 'Continue'; Set-StrictMode -Off
    try { $r = Invoke-GpoBaseline -Action Uninstall -Definition 'cis-ws2022-dc-low-risk' -Apply 'true' -Context $script:ctx 2>$null }
    finally { $ErrorActionPreference = 'Stop'; Set-StrictMode -Version Latest }
    Assert ($r.exitCode -eq 1 -and $r.report.status -ne 'removed') 'failed Remove-GPO is not reported as removed'
    $script:removeFails = $false

    # Review: files that match but were never published (version or CSE missing) are repaired.
    $script:ctx = New-FakeWorld
    [void](Invoke-GpoBaseline -Action Install -Definition 'cis-ws2022-dc-low-risk' -Apply 'true' -Context $script:ctx)
    $gpo = $script:gpos[$def.gpoName]
    $script:ad[$gpo.Id.ToString()].gPCMachineExtensionNames = $reg
    $r = Invoke-GpoBaseline -Action Install -Definition 'cis-ws2022-dc-low-risk' -Context $script:ctx
    Assert (@($r.report.changes | Where-Object { $_.kind -eq 'publish' }).Count -eq 1) 'missing CSE registration planned'
    $r = Invoke-GpoBaseline -Action Install -Definition 'cis-ws2022-dc-low-risk' -Apply 'true' -Context $script:ctx
    Assert ($r.exitCode -eq 0 -and $script:ad[$gpo.Id.ToString()].gPCMachineExtensionNames -eq ($reg + $sec + $aud)) 'CSE registration repaired'
    $script:ad[$gpo.Id.ToString()].versionNumber = 1
    $r = Invoke-GpoBaseline -Action Install -Definition 'cis-ws2022-dc-low-risk' -Apply 'true' -Context $script:ctx
    $iniVersion = [long]([regex]::Match([IO.File]::ReadAllText((Join-Path (Join-Path $script:ctx.PoliciesPath ('{' + $gpo.Id.ToString().ToUpper() + '}')) 'GPT.INI')), 'Version=(\d+)').Groups[1].Value)
    Assert ($r.exitCode -eq 0 -and [long]$script:ad[$gpo.Id.ToString()].versionNumber -eq $iniVersion) 'AD and GPT.INI version mismatch repaired'
    $r = Invoke-GpoBaseline -Action Install -Definition 'cis-ws2022-dc-low-risk' -Apply 'true' -Context $script:ctx
    Assert ($r.report.status -eq 'noChange') 'repaired GPO is stable'

    # Review: files written but never published (AD read failed before GPT.INI) are
    # published on the next run, even though every value already matches.
    $script:ctx = New-FakeWorld
    [void](Invoke-GpoBaseline -Action Install -Definition 'cis-ws2022-dc-low-risk' -Apply 'true' -Context $script:ctx)
    $gpo = $script:gpos[$def.gpoName]
    $infPath = Join-Path (Join-Path $script:ctx.PoliciesPath ('{' + $gpo.Id.ToString().ToUpper() + '}')) 'Machine\Microsoft\Windows NT\SecEdit\GptTmpl.inf'
    [IO.File]::WriteAllText($infPath, "[Unicode]`r`nUnicode=yes`r`n", [Text.Encoding]::Unicode)
    $before = [long]$script:ad[$gpo.Id.ToString()].versionNumber
    $script:adGetCount = 0; $script:adGetFailAt = 2
    $r = Invoke-GpoBaseline -Action Install -Definition 'cis-ws2022-dc-low-risk' -Apply 'true' -Context $script:ctx
    $script:adGetFailAt = -1
    Assert ($r.exitCode -eq 1 -and [long]$script:ad[$gpo.Id.ToString()].versionNumber -eq $before) 'publication failure leaves version unchanged and exits 1'
    $r = Invoke-GpoBaseline -Action Install -Definition 'cis-ws2022-dc-low-risk' -Context $script:ctx
    Assert (@($r.report.changes | Where-Object { $_.kind -eq 'publish' }).Count -eq 1) 'pending publication planned after failure'
    $r = Invoke-GpoBaseline -Action Install -Definition 'cis-ws2022-dc-low-risk' -Apply 'true' -Context $script:ctx
    Assert ($r.exitCode -eq 0 -and [long]$script:ad[$gpo.Id.ToString()].versionNumber -gt $before) 'pending publication completed'
    $r = Invoke-GpoBaseline -Action Install -Definition 'cis-ws2022-dc-low-risk' -Apply 'true' -Context $script:ctx
    Assert ($r.report.status -eq 'noChange') 'pending marker cleared'

    # ---- Definition validation ----
    $base = { [pscustomobject]@{ id = 'test-def'; gpoName = 'Test'; description = 'd'; allowDefaultPolicy = $false; registry = @(); security = @(); audit = @() } }
    $script:ctx = New-FakeWorld
    $bad = @(
        @{ label = 'HKU registry key'; set = { param($d) $d.registry = @([pscustomobject]@{ cis = 'x'; key = 'HKU\S-1-5-18\Software\X'; valueName = 'A'; type = 'DWord'; value = 1 }) } },
        @{ label = 'unknown registry type'; set = { param($d) $d.registry = @([pscustomobject]@{ cis = 'x'; key = 'HKLM\Software\X'; valueName = 'A'; type = 'Binary'; value = 1 }) } },
        @{ label = 'audit setting out of range'; set = { param($d) $d.audit = @([pscustomobject]@{ cis = 'x'; subcategory = 'Audit Logon'; guid = '{0cce9215-69ae-11d9-bed3-505054503030}'; setting = 5 }) } },
        @{ label = 'unknown security section'; set = { param($d) $d.security = @([pscustomobject]@{ cis = 'x'; section = 'File Security'; key = 'k'; value = 'v' }) } },
        @{ label = 'task over plain http'; set = { param($d) $d | Add-Member tasks @([pscustomobject]@{ name = 'T'; description = 'd'; arguments = '-Action Install'; intervalMinutes = 60; bootDelayMinutes = 5; file = [pscustomobject]@{ name = 'a.ps1'; url = 'http://example.invalid/a.ps1'; sha256 = ('a' * 64) } }) } },
        @{ label = 'task file name with a path'; set = { param($d) $d | Add-Member tasks @([pscustomobject]@{ name = 'T'; description = 'd'; arguments = '-Action Install'; intervalMinutes = 60; bootDelayMinutes = 5; file = [pscustomobject]@{ name = '..\a.ps1'; url = 'https://example.invalid/a.ps1'; sha256 = ('a' * 64) } }) } },
        @{ label = 'uppercase task hash'; set = { param($d) $d | Add-Member tasks @([pscustomobject]@{ name = 'T'; description = 'd'; arguments = '-Action Install'; intervalMinutes = 60; bootDelayMinutes = 5; file = [pscustomobject]@{ name = 'a.ps1'; url = 'https://example.invalid/a.ps1'; sha256 = ('A' * 64) } }) } },
        @{ label = 'task bad hash'; set = { param($d) $d | Add-Member tasks @([pscustomobject]@{ name = 'T'; description = 'd'; arguments = '-Action Install'; intervalMinutes = 60; bootDelayMinutes = 5; file = [pscustomobject]@{ name = 'a.ps1'; url = 'https://example.invalid/a.ps1'; sha256 = 'abc' } }) } },
        @{ label = 'task arguments with a command separator'; set = { param($d) $d | Add-Member tasks @([pscustomobject]@{ name = 'T'; description = 'd'; arguments = '-Action Install; Remove-Item C:\'; intervalMinutes = 60; bootDelayMinutes = 5; file = [pscustomobject]@{ name = 'a.ps1'; url = 'https://example.invalid/a.ps1'; sha256 = ('a' * 64) } }) } },
        @{ label = 'URL with user info'; set = { param($d) $d | Add-Member tasks @([pscustomobject]@{ name = 'T'; description = 'd'; arguments = ''; intervalMinutes = 60; bootDelayMinutes = 5; file = [pscustomobject]@{ name = 'a.ps1'; url = 'https://user@example.invalid/a.ps1'; sha256 = ('a' * 64) } }) } },
        @{ label = 'WMI query outside SELECT'; set = { param($d) $d | Add-Member wmiFilter ([pscustomobject]@{ name = 'F'; description = 'd'; queries = @('DELETE FROM Win32_Process') }) } },
        @{ label = 'WMI filter name with LDAP metacharacters'; set = { param($d) $d | Add-Member wmiFilter ([pscustomobject]@{ name = 'F*)(x'; description = 'd'; queries = @('SELECT * FROM Win32_ComputerSystem') }) } }
    )
    foreach ($case in $bad) {
        $d = & $base; & $case.set $d
        $script:calls.Clear()
        $r = Invoke-GpoBaseline -Action Install -DefinitionObject $d -Apply 'true' -Context $script:ctx
        Assert ($r.exitCode -eq 1 -and $r.report.status -eq 'refused' -and (Get-Writes).Count -eq 0) "invalid definition refused: $($case.label)"
    }
    foreach ($id in @('cis-ws2022-dc-low-risk', 'comet-vss-provider-qemu')) { Assert (-not (Test-GpbDefinition (Get-GpbDefinition $id))) "embedded definition valid: $id" }

    # Review: transient download failures get three attempts; other failures one.
    # A response-bearing exception that builds the same way on .NET Framework and .NET.
    if (-not ('GpbFakeHttpException' -as [type])) { Add-Type -TypeDefinition 'public class GpbFakeHttpException : System.Exception { public GpbFakeHttpException(int code) : base("HTTP " + code) { StatusCode = code; } public int StatusCode { get; set; } }' }
    $script:GpbRetryDelay = { param($Seconds) }
    $script:dlCalls = 0
    $script:GpbDownload = { param($Url, $Path) $script:dlCalls++; if ($script:dlCalls -lt 3) { throw [System.Net.WebException]::new('timed out', [System.Net.WebExceptionStatus]::Timeout) }; [IO.File]::WriteAllText($Path, 'x') }
    $tmpDl = Join-Path $tmp 'dl-test'
    Invoke-GpbDownloadFile -Url 'https://example.invalid/a.ps1' -Path $tmpDl
    Assert ($script:dlCalls -eq 3 -and [IO.File]::Exists($tmpDl)) 'timeout retried up to three attempts'
    $script:dlCalls = 0
    $script:GpbDownload = { param($Url, $Path) $script:dlCalls++; throw [GpbFakeHttpException]::new(404) }
    $failed = $false; try { Invoke-GpbDownloadFile -Url 'https://example.invalid/a.ps1' -Path $tmpDl } catch { $failed = $true }
    Assert ($failed -and $script:dlCalls -eq 1 -and (Test-GpbTransient ([GpbFakeHttpException]::new(404))) -eq $false -and (Test-GpbTransient ([GpbFakeHttpException]::new(503)))) 'HTTP 404 not retried; status reaches the classifier'
    $script:dlCalls = 0
    $script:GpbDownload = { param($Url, $Path) $script:dlCalls++; throw [GpbFakeHttpException]::new(503) }
    $failed = $false; try { Invoke-GpbDownloadFile -Url 'https://example.invalid/a.ps1' -Path $tmpDl } catch { $failed = $true }
    Assert ($failed -and $script:dlCalls -eq 3) 'HTTP 503 retried three times then fails'
    $script:GpbDownload = { param($Url, $Path) $script:downloads.Add($Url); [IO.File]::WriteAllText($Path, $script:downloadBody) }

    # ---- Comet VSS provider: WMI-filtered GPO with a hash-pinned GPP scheduled task ----
    $comet = Get-GpbDefinition 'comet-vss-provider-qemu'
    $task = $comet.tasks[0]
    Assert ($task.file.url -eq "https://relianpub.blob.core.windows.net/pub/sec/Invoke-CometVssProvider-$($task.file.sha256).ps1") 'Comet script is a content-addressed blob named by its sha256'
    $pinned = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $root 'windows/packages/comet-vss-provider/Invoke-CometVssProvider.ps1')).Hash.ToLower()
    Assert ($task.file.sha256 -eq $pinned) 'Comet pin matches the comet-vss-provider package in this repo'
    Assert (($comet.wmiFilter.queries -join ' ') -match 'Manufacturer = "QEMU"' -and ($comet.wmiFilter.queries -join ' ') -match 'ProductType <> 1') 'WMI filter targets QEMU servers'
    Assert (@($comet.registry).Count -eq 0) 'no GPP or registry replace of AppEnvironmentExtra'

    $script:ctx = New-FakeWorld
    $script:downloadBody = 'fake comet script'
    $fakeHash = ([BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($script:downloadBody))) -replace '-', '').ToLower()
    $testComet = $comet | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $testComet.tasks[0].file.sha256 = $fakeHash
    $r = Invoke-GpoBaseline -Action Install -DefinitionObject $testComet -Context $script:ctx
    $kinds = @($r.report.changes | ForEach-Object { $_.kind })
    Assert ($r.exitCode -eq 0 -and $r.report.status -eq 'plan' -and (Get-Writes).Count -eq 0 -and $script:downloads.Count -eq 0) 'Comet plan writes and downloads nothing'
    foreach ($k in @('create', 'wmiFilter', 'wmiLink', 'file', 'tasks')) { Assert ($kinds -contains $k) "Comet plan lists $k" }

    # A pin mismatch stops before any write.
    $testComet.tasks[0].file.sha256 = ('0' * 64)
    $script:downloads.Clear()
    $r = Invoke-GpoBaseline -Action Install -DefinitionObject $testComet -Apply 'true' -Context $script:ctx
    Assert ($r.exitCode -eq 1 -and -not @($script:calls | Where-Object { $_ -match '^(New-GPO|New-ADObject|Backup-GPO|Set-)' })) 'hash mismatch makes no GPO or AD write'
    Assert (-not $script:gpos.ContainsKey($testComet.gpoName)) 'hash mismatch created no GPO'
    Assert ($script:downloads.Count -eq 1) 'hash mismatch is not retried'
    $testComet.tasks[0].file.sha256 = $fakeHash

    $script:calls.Clear(); $script:downloads.Clear()
    $r = Invoke-GpoBaseline -Action Install -DefinitionObject $testComet -Apply 'true' -Context $script:ctx
    Assert ($r.exitCode -eq 0 -and $r.report.status -eq 'applied') "Comet apply: $($r.report | ConvertTo-Json -Depth 5 -Compress)"
    Assert ($script:downloads.Count -eq 1 -and $script:downloads[0] -eq $task.file.url) 'pinned URL downloaded once'
    $cg = $script:gpos[$testComet.gpoName]
    $filter = @($script:wmi.Values)[0]
    Assert ($script:wmi.Count -eq 1 -and $filter.'msWMI-Parm1' -match [regex]::Escape('[relian-gpo-baseline:comet-vss-provider-qemu]')) 'WMI filter created with marker'
    $q1 = $comet.wmiFilter.queries[0]; $q2 = $comet.wmiFilter.queries[1]
    Assert ($filter.'msWMI-Parm2' -ceq "2;3;10;$($q1.Length);WQL;root\CIMv2;$q1;3;10;$($q2.Length);WQL;root\CIMv2;$q2;") 'WMI filter query encoding'
    Assert ($script:ad[$cg.Id.ToString()].gPCWQLFilter -eq "[example.invalid;$($filter.'msWMI-ID');0]") 'WMI filter linked to the GPO'
    $cgDir = Join-Path $script:ctx.PoliciesPath ('{' + $cg.Id.ToString().ToUpper() + '}')
    Assert ([IO.File]::ReadAllText((Join-Path $cgDir 'Machine\Scripts\Relian\Invoke-CometVssProvider.ps1')) -eq $script:downloadBody) 'pinned script stored in SYSVOL'
    [xml]$tx = [IO.File]::ReadAllText((Join-Path $cgDir 'Machine\Preferences\ScheduledTasks\ScheduledTasks.xml'))
    $t2 = $tx.ScheduledTasks.TaskV2
    Assert ($tx.ScheduledTasks.clsid -eq '{CC63F200-7309-4ba0-B154-A71CD118DBCC}' -and $t2.clsid -eq '{D8896631-B747-47a7-84A6-C155337F3BC8}') 'GPP TaskV2 class ids'
    Assert ($t2.Properties.Task.Principals.Principal.UserId -eq 'NT AUTHORITY\System' -and -not $t2.Properties.Task.Principals.Principal.SelectSingleNode("*[local-name()='LogonType']")) 'SYSTEM principal has no user logon type'
    Assert ($t2.Properties.runAs -eq 'NT AUTHORITY\System' -and $t2.Properties.action -eq 'R' -and $t2.removePolicy -eq '1') 'task runs as SYSTEM and is removed when the GPO no longer applies'
    $exec = $t2.Properties.Task.Actions.Exec
    Assert ($exec.Command -eq 'powershell.exe' -and $exec.Arguments.Contains($fakeHash) -and $exec.Arguments.Contains("\\example.invalid\SYSVOL\example.invalid\Policies\{$($cg.Id.ToString().ToUpper())}\Machine\Scripts\Relian\Invoke-CometVssProvider.ps1") -and $exec.Arguments.Contains('-Action Install')) 'task checks the pin, then runs the SYSVOL copy'
    # Task Scheduler trigger schema order: Repetition, StartBoundary, ..., Enabled.
    $tt = $t2.Properties.Task.Triggers.TimeTrigger
    Assert ((@($tt.ChildNodes | ForEach-Object { $_.LocalName }) -join ',') -eq 'Repetition,StartBoundary,Enabled') 'TimeTrigger children in schema order'
    Assert ($t2.Properties.Task.Triggers.BootTrigger -and $t2.Properties.Task.Triggers.TimeTrigger.Repetition.Interval -eq 'PT60M') 'task runs at boot and hourly'
    $ext = $script:ad[$cg.Id.ToString()].gPCMachineExtensionNames
    Assert ($ext.Contains('[{00000000-0000-0000-0000-000000000000}{CAB54552-DEEA-4691-817E-ED4A4D1AFC72}]') -and $ext.Contains('[{AADCED64-746C-4633-A97C-D61349046527}{CAB54552-DEEA-4691-817E-ED4A4D1AFC72}]')) 'GPP Scheduled Tasks CSE registered'

    $script:calls.Clear(); $script:downloads.Clear()
    $r = Invoke-GpoBaseline -Action Install -DefinitionObject $testComet -Apply 'true' -Context $script:ctx
    Assert ($r.report.status -eq 'noChange' -and $script:downloads.Count -eq 0 -and (Get-Writes).Count -eq 0) 'Comet rerun changes and downloads nothing'

    # Task drift on the owned GPO: backup first, then repair.
    [IO.File]::WriteAllText((Join-Path $cgDir 'Machine\Preferences\ScheduledTasks\ScheduledTasks.xml'), '<ScheduledTasks/>')
    $script:calls.Clear()
    $r = Invoke-GpoBaseline -Action Install -DefinitionObject $testComet -Apply 'true' -Context $script:ctx
    $writes = Get-Writes
    Assert ($r.exitCode -eq 0 -and $writes[1] -eq 'Backup-GPO' -and @($r.report.changes).Count -ge 1) "task drift backed up then repaired: $($writes -join ', ')"

    # A same-named WMI filter without the marker is foreign.
    $script:ctx = New-FakeWorld
    $script:wmi['{AAAAAAAA-0000-0000-0000-000000000000}'] = @{ DistinguishedName = 'CN={AAAAAAAA-0000-0000-0000-000000000000},CN=SOM,CN=WMIPolicy,CN=System,DC=example,DC=invalid'; 'msWMI-Name' = $comet.wmiFilter.name; 'msWMI-Parm1' = 'by hand'; 'msWMI-Parm2' = 'x'; 'msWMI-ID' = '{AAAAAAAA-0000-0000-0000-000000000000}' }
    $r = Invoke-GpoBaseline -Action Install -DefinitionObject $testComet -Apply 'true' -Context $script:ctx
    Assert ($r.exitCode -eq 1 -and $r.report.status -eq 'refused' -and (Get-Writes).Count -eq 0) 'foreign WMI filter refused'

    # Review: an empty pin exits 0 for every action, before the URL is read, with no download or write.
    $unpinned = $comet | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $unpinned.tasks[0].file.sha256 = ''
    $unpinned.tasks[0].file.url = 'https://user@example.invalid/a.ps1'
    foreach ($act in @('Install', 'Uninstall')) {
        $script:ctx = New-FakeWorld; $script:calls.Clear(); $script:downloads.Clear()
        $r = Invoke-GpoBaseline -Action $act -DefinitionObject $unpinned -Apply 'true' -Context $script:ctx
        Assert ($r.exitCode -eq 0 -and $r.report.status -eq 'notPinned' -and $script:downloads.Count -eq 0 -and $script:calls.Count -eq 0) "empty pin is a no-op for $act"
        $r = Invoke-GpoBaseline -Action $act -DefinitionObject $unpinned -Apply 'yes' -LinkEnabled 'maybe' -Context $script:ctx
        Assert ($r.exitCode -eq 0 -and $r.report.status -eq 'notPinned') "empty pin wins over invalid flags for $act"
    }
    # Review: a userinfo URL refuses Install before any download but does not block Uninstall.
    $script:ctx = New-FakeWorld
    [void](Invoke-GpoBaseline -Action Install -DefinitionObject $testComet -Apply 'true' -Context $script:ctx)
    $userinfo = $testComet | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $userinfo.tasks[0].file.url = 'https://user@example.invalid/a.ps1'
    $script:downloads.Clear()
    $r = Invoke-GpoBaseline -Action Install -DefinitionObject $userinfo -Apply 'true' -Context $script:ctx
    Assert ($r.exitCode -eq 1 -and $r.report.status -eq 'refused' -and $script:downloads.Count -eq 0) 'userinfo URL refused before download'
    $r = Invoke-GpoBaseline -Action Uninstall -DefinitionObject $userinfo -Apply 'true' -Context $script:ctx
    Assert ($r.exitCode -eq 0 -and $r.report.status -eq 'removed') 'userinfo URL does not block Uninstall'

    # Uninstall removes the owned GPO and its now-unused owned WMI filter.
    $script:ctx = New-FakeWorld
    [void](Invoke-GpoBaseline -Action Install -DefinitionObject $testComet -Apply 'true' -Context $script:ctx)
    $script:calls.Clear()
    $r = Invoke-GpoBaseline -Action Uninstall -DefinitionObject $testComet -Apply 'true' -Context $script:ctx
    Assert ($r.exitCode -eq 0 -and ($script:calls -contains 'Remove-GPO') -and ($script:calls -contains 'Remove-ADObject') -and $script:wmi.Count -eq 0) 'uninstall removes GPO and owned WMI filter'

    # Output cap.
    $big = [ordered]@{ status = 'plan'; changes = @(1..400 | ForEach-Object { [ordered]@{ kind = 'registry'; target = ('HKLM\Software\Policies\' + ('x' * 80)); current = $null; desired = 'é' * 20 } }) }
    $json = ConvertTo-GpbBoundedJson $big
    Assert ([Text.Encoding]::UTF8.GetByteCount($json) -le 8000 -and ($json | ConvertFrom-Json).truncated) 'output capped at 8000 bytes'

    # Embedded definition carries the CIS Server 2022 v5.1.0 values.
    $byKey = @{}; foreach ($i in $def.registry) { $byKey[$i.valueName + '@' + $i.key] = $i }
    Assert ($byKey['RegisterSpoolerRemoteRpcEndPoint@HKLM\Software\Policies\Microsoft\Windows NT\Printers'].value -eq 2) 'CIS 18.7.1'
    Assert ($byKey['MaxSize@HKLM\Software\Policies\Microsoft\Windows\EventLog\Security'].value -eq 196608) 'CIS 18.10.26.2.2'
    Assert ($byKey['LogFileSize@HKLM\Software\Policies\Microsoft\WindowsFirewall\DomainProfile\Logging'].value -eq 16384) 'CIS 9.1.5'
    Assert (@($def.registry | Where-Object { $_.key -like '*WindowsFirewall*' -and $_.valueName -match 'EnableFirewall|DefaultInboundAction|AllowLocal' }).Count -eq 0) 'firewall definition is logging only'
    $secByKey = @{}; foreach ($i in $def.security) { $secByKey[$i.key] = $i.value }
    Assert ($secByKey['MACHINE\System\CurrentControlSet\Services\Netlogon\Parameters\AuditNTLMInDomain'] -eq '4,7') 'CIS 2.3.11.12'
    Assert ($secByKey['MACHINE\System\CurrentControlSet\Control\Lsa\MSV1_0\AuditReceivingNTLMTraffic'] -eq '4,2') 'CIS 2.3.11.11'
    Assert ($secByKey['MACHINE\System\CurrentControlSet\Control\Lsa\MSV1_0\RestrictSendingNTLMTraffic'] -eq '4,1') 'CIS 2.3.11.13 audit only'
    Assert ($secByKey['Spooler'] -eq '4,""') 'CIS 5.1'
    $audByGuid = @{}; foreach ($i in $def.audit) { $audByGuid[$i.guid] = $i.setting }
    Assert ($audByGuid['{0cce923b-69ae-11d9-bed3-505054503030}'] -band 2) 'CIS 17.4.1 includes Failure'
    Assert ($audByGuid['{0cce923c-69ae-11d9-bed3-505054503030}'] -band 1) 'CIS 17.4.2 includes Success'
    Assert ($audByGuid['{0cce9228-69ae-11d9-bed3-505054503030}'] -band 1) 'CIS 17.8.1 includes Success'

    # ---- OneDrive, lockout and adopt definitions: arguments, placeholders, hives, security filtering ----
    $toHex = { param($s) ([BitConverter]::ToString([Text.Encoding]::UTF8.GetBytes($s)) -replace '-', '') }
    $tenant = '00000000-0000-4000-8000-000000000001'
    $libId = "tenantId=$tenant&siteId=%7B00000000-0000-4000-8000-000000000002%7D&webId=%7B00000000-0000-4000-8000-000000000003%7D&listId=%7B00000000-0000-4000-8000-000000000004%7D&webUrl=https%3A%2F%2Fexample%2Esharepoint%2Ecom%2Fsites%2FAccounting&version=1"
    $toParts = { param($s) $h = & $toHex $s; $parts = @(); for ($i = 0; $i -lt $h.Length; $i += 128) { $parts += $h.Substring($i, [Math]::Min(128, $h.Length - $i)) }; ,$parts }
    $libHex = & $toParts $libId
    Assert ($libHex.Count -gt 1) 'library ID needs several hex parts'
    $am = @{ Definition = 'onedrive-automount'; TenantId = $tenant; LibraryIdHex = $libHex; LibraryName = 'Accounting'; ApplyTo = 'Pilot'; ApplyType = 'User' }
    $amName = 'Relian - OneDrive AutoMount Accounting'
    $amKey = 'HKCU\Software\Policies\Microsoft\OneDrive\TenantAutoMount'

    Assert ((Get-GpbAuthenticatedUsersName) -match '\S') 'Authenticated Users name resolves or falls back'
    foreach ($id in @('workstations-only', 'onedrive-workstations', 'onedrive-users', 'onedrive-automount', 'password-lockout')) {
        $d = Get-GpbDefinition $id
        Assert ($null -ne $d) "embedded definition found: $id"
        $rd = Resolve-GpbDefinition $d @{ TenantId = $tenant; LibraryId = $libId; LibraryName = 'Accounting' }
        Assert ($rd.Missing.Count -eq 0 -and -not (Test-GpbDefinition $rd.Def)) "embedded definition valid once resolved: $id"
    }
    # Definitions that share a WMI filter name must share its queries, or two runs would fight over it.
    $filterQueries = @{}
    foreach ($d in ($GpbDefinitionJson | ConvertFrom-Json)) {
        $w = Get-GpbProp $d 'wmiFilter'
        if (-not $w) { continue }
        $q = @($w.queries) -join '|'
        if ($filterQueries.ContainsKey($w.name)) { Assert ($filterQueries[$w.name] -ceq $q) "shared WMI filter $($w.name) has one query set" } else { $filterQueries[$w.name] = $q }
    }
    Assert ($filterQueries['Relian - Workstations'] -ceq 'SELECT * FROM Win32_OperatingSystem WHERE ProductType = 1') 'workstation filter is ProductType 1'

    # Every argument is validated before the plan is built; a refusal writes nothing.
    $script:ctx = New-FakeWorld
    $badArgs = @(
        @{ label = 'TenantId not a GUID'; a = @{ TenantId = 'contoso' } },
        @{ label = 'odd hex length'; a = @{ LibraryIdHex = @('abc') } },
        @{ label = 'non-hex characters'; a = @{ LibraryIdHex = @('zz') } },
        @{ label = 'hex part over 128 characters'; a = @{ LibraryIdHex = @('41' * 65) } },
        @{ label = 'gap between hex parts'; a = @{ LibraryIdHex = @($libHex[0], '', $libHex[1]) } },
        @{ label = 'hex that is not UTF-8'; a = @{ LibraryIdHex = @('C3') } },
        @{ label = 'not a library ID'; why = 'not a SharePoint Online library ID'; a = @{ LibraryIdHex = @(& $toHex 'hello=world') } },
        @{ label = 'library ID with an extra key'; why = 'not a SharePoint Online library ID'; a = @{ LibraryIdHex = (& $toParts ($libId + '&x=1')) } },
        @{ label = 'library ID outside SharePoint Online'; why = 'not a SharePoint Online library ID'; a = @{ LibraryIdHex = (& $toParts ($libId -replace 'example%2Esharepoint%2Ecom', 'evil%2Eexample')) } },
        @{ label = 'library ID of another tenant'; a = @{ TenantId = '00000000-0000-4000-8000-0000000000ff' } },
        @{ label = 'library ID without TenantId'; why = 'needs TenantId'; a = @{ TenantId = '' } },
        @{ label = 'LibraryName with punctuation'; a = @{ LibraryName = 'Acc;ounting' } },
        @{ label = 'LibraryName over 40 characters'; a = @{ LibraryName = 'A' * 41 } },
        @{ label = 'ApplyType without ApplyTo'; a = @{ ApplyTo = '' } },
        @{ label = 'ApplyTo without ApplyType'; a = @{ ApplyType = '' } },
        @{ label = 'unknown ApplyType'; a = @{ ApplyType = 'OU' } },
        @{ label = 'ApplyTo with LDAP metacharacters'; a = @{ ApplyTo = 'Pilot*)(x' } },
        @{ label = 'ApplyTo with a trailing space'; a = @{ ApplyTo = 'Pilot ' } },
        @{ label = 'ApplyTo not in the directory'; a = @{ ApplyTo = 'Nobody' } },
        @{ label = 'ApplyType Computer on a user-side definition'; a = @{ ApplyTo = 'PILOT-PC'; ApplyType = 'Computer' } },
        @{ label = 'required filter without ApplyTo'; a = @{ ApplyTo = ''; ApplyType = '' } },
        @{ label = 'missing LibraryIdHex'; a = @{ LibraryIdHex = @() } },
        @{ label = 'missing LibraryName'; a = @{ LibraryName = '' } },
        @{ label = 'AdoptGpo on a definition that does not adopt'; a = @{ AdoptGpo = [guid]::NewGuid().ToString(); AllowUnmarked = 'true' } },
        @{ label = 'AllowUnmarked on a definition that does not adopt'; a = @{ AllowUnmarked = 'true' } },
        @{ label = 'AllowUnmarked not true or false'; a = @{ AllowUnmarked = 'yes' } }
    )
    foreach ($case in $badArgs) {
        $p = $am.Clone(); foreach ($k in $case.a.Keys) { $p[$k] = $case.a[$k] }
        $script:calls.Clear()
        $r = Invoke-GpoBaseline @p -Apply 'true' -Context $script:ctx
        Assert ($r.exitCode -eq 1 -and $r.report.status -eq 'refused' -and (Get-Writes).Count -eq 0) "refused: $($case.label) ($($r.report.status) $($r.report['reason']))"
        if ($case.label -eq 'required filter without ApplyTo') { Assert ($script:calls.Count -eq 0) 'required filter refused before any read' }
        if ($case.Contains('why')) { Assert ($r.report.reason -like "*$($case.why)*") "refused for the right reason: $($case.label) ($($r.report.reason))" }
    }
    $r = Invoke-GpoBaseline -Definition 'password-lockout' -ApplyTo 'Pilot' -ApplyType 'User' -AllowDefaultPolicy 'true' -Context $script:ctx
    Assert ($r.exitCode -eq 1 -and $r.report.status -eq 'refused') 'ApplyTo refused for a definition without a security filter'

    # onedrive-automount: plan makes zero writes and shows the resolved values.
    $script:ctx = New-FakeWorld; $script:calls.Clear()
    $r = Invoke-GpoBaseline @am -LinkTo 'DC=example,DC=invalid' -Context $script:ctx
    Assert ($r.exitCode -eq 0 -and $r.report.status -eq 'plan' -and (Get-Writes).Count -eq 0) "automount plan makes zero writes: $($r.report | ConvertTo-Json -Depth 5 -Compress)"
    Assert ($r.report.gpo.name -eq $amName) 'gpoName placeholder resolved'
    $amReg = @($r.report.changes | Where-Object { $_.kind -eq 'registry' })
    Assert ($amReg.Count -eq 1 -and $amReg[0].target -eq "$amKey\Accounting" -and $amReg[0].desired -eq $libId) 'TenantAutoMount name and library ID from the arguments'
    $kinds = @($r.report.changes | ForEach-Object { $_.kind })
    foreach ($k in @('create', 'permission', 'registry', 'wmiFilter', 'wmiLink', 'link')) { Assert ($kinds -contains $k) "automount plan lists $k" }

    # Apply: security filter before any setting, HKCU into the user Registry.pol, workstation filter, marker with the library name.
    $r = Invoke-GpoBaseline @am -LinkTo 'DC=example,DC=invalid' -Apply 'true' -Context $script:ctx
    Assert ($r.exitCode -eq 0 -and $r.report.status -eq 'applied') "automount apply: $($r.report | ConvertTo-Json -Depth 5 -Compress)"
    $g = $script:gpos[$amName]
    Assert ($g.Description.Contains('[relian-gpo-baseline:onedrive-automount:Accounting]')) 'parameterised marker carries the library name'
    $writes = Get-Writes
    $firstSetting = [array]::FindIndex([string[]]$writes, [Predicate[string]]{ param($w) $w -like 'Set-GPRegistryValue*' })
    $auAt = [array]::IndexOf([string[]]$writes, 'Set-GPPermission Authenticated Users GpoRead')
    $toAt = [array]::IndexOf([string[]]$writes, 'Set-GPPermission Pilot GpoApply')
    Assert ($auAt -ge 0 -and $toAt -ge 0 -and $auAt -lt $firstSetting -and $toAt -lt $firstSetting) "security filter set before any setting: $($writes -join ', ')"
    Assert ((Get-FakePermission $g 'S-1-5-11') -eq 'GpoRead' -and (Get-FakePermission $g 'S-1-5-21-9-1102') -eq 'GpoApply') 'Authenticated Users read, ApplyTo apply'
    Assert ((Get-FakePermission $g 'S-1-5-21-9-512') -eq 'GpoEditDeleteModifySecurity') 'admin permissions untouched'
    Assert ($script:pol -contains "$($g.Id)|User|$amKey\Accounting" -and -not @($script:pol | Where-Object { $_ -like "$($g.Id)|Machine|*" })) 'HKCU value lands in the user Registry.pol only'
    Assert ([string]$script:regValues["$($g.Id)|$amKey|Accounting"].Value -ceq $libId -and [string]$script:regValues["$($g.Id)|$amKey|Accounting"].Type -eq 'String') 'library ID written verbatim as REG_SZ'
    $wf = @($script:wmi.Values | Where-Object { $_.'msWMI-Name' -eq 'Relian - Workstations' })
    Assert ($wf.Count -eq 1 -and $script:ad[$g.Id.ToString()].gPCWQLFilter -eq "[example.invalid;$($wf[0].'msWMI-ID');0]") 'workstation WMI filter linked'
    Assert ($script:calls -contains 'New-GPLink No') 'domain-root link created disabled'
    $script:calls.Clear()
    $r = Invoke-GpoBaseline @am -LinkTo 'DC=example,DC=invalid' -Apply 'true' -Context $script:ctx
    Assert ($r.exitCode -eq 0 -and $r.report.status -eq 'noChange' -and (Get-Writes).Count -eq 0) "second automount apply changes nothing: $($r.report | ConvertTo-Json -Depth 5 -Compress)"

    # Switching ApplyTo: backup first, then the new trustee gets apply.
    $p = $am.Clone(); $p.ApplyTo = 'Accounting'; $p.ApplyType = 'Group'
    $script:calls.Clear()
    $r = Invoke-GpoBaseline @p -Apply 'true' -Context $script:ctx
    $writes = Get-Writes
    Assert ($r.exitCode -eq 0 -and $writes[1] -eq 'Backup-GPO' -and $writes[2] -eq 'Set-GPPermission Pilot None' -and $writes[3] -eq 'Set-GPPermission Accounting GpoApply' -and $r.report.backupId) "ApplyTo switch backs up, revokes the old target, then grants the new: $($writes -join ', ')"
    Assert ((Get-FakePermission $g 'S-1-5-21-9-1102') -eq 'None' -and (Get-FakePermission $g 'S-1-5-21-9-1101') -eq 'GpoApply' -and (Get-FakePermission $g 'S-1-5-11') -eq 'GpoRead') 'ApplyTo switch removes the previous target'
    $script:calls.Clear()
    $r = Invoke-GpoBaseline @p -Apply 'true' -Context $script:ctx
    Assert ($r.report.status -eq 'noChange' -and (Get-Writes).Count -eq 0) 'ApplyTo switch is idempotent'
    # A computer target from an earlier pilot is removed by its name without the $.
    $script:perms[$g.Id.ToString()].Add(@{ Name = 'PILOT-PC$'; Sid = 'S-1-5-21-9-1103'; Type = 'Computer'; Permission = 'GpoApply' })
    $r = Invoke-GpoBaseline @p -Apply 'true' -Context $script:ctx
    Assert ($r.exitCode -eq 0 -and ($script:calls -contains 'Set-GPPermission PILOT-PC None') -and (Get-FakePermission $g 'S-1-5-21-9-1103') -eq 'None') 'stale computer grant removed'

    # A trustee that already holds more than apply is never lowered.
    $script:perms[$g.Id.ToString()].Add(@{ Name = 'PILOT-PC$'; Sid = 'S-1-5-21-9-1103'; Type = 'Computer'; Permission = 'GpoEditDeleteModifySecurity' })
    $script:sids['User|Pilot'] = 'S-1-5-21-9-1103'
    $script:calls.Clear()
    $r = Invoke-GpoBaseline @am -Apply 'true' -Context $script:ctx
    Assert ($r.exitCode -eq 1 -and $r.report.status -eq 'refused' -and (Get-Writes).Count -eq 0) "ApplyTo with edit rights refused, not lowered: $($r.report | ConvertTo-Json -Depth 5 -Compress) $($script:calls -join ',')"
    $script:sids['User|Pilot'] = 'S-1-5-21-9-1102'

    # A new GPO's own admin grants are seen at write time and never lowered.
    $script:calls.Clear()
    $r = Invoke-GpoBaseline -Definition 'onedrive-users' -ApplyTo 'Domain Admins' -ApplyType 'Group' -Apply 'true' -Context $script:ctx
    $nu = $script:gpos['Relian - OneDrive (users)']
    Assert ($r.exitCode -eq 1 -and -not @($script:calls | Where-Object { $_ -like 'Set-GP*' }) -and (Get-FakePermission $nu 'S-1-5-21-9-512') -eq 'GpoEditDeleteModifySecurity') "new GPO admin rights never lowered: $($script:calls -join ', ')"

    # The cis definition still may not link at the domain root.
    $r = Invoke-GpoBaseline -Definition 'cis-ws2022-dc-low-risk' -LinkTo 'DC=example,DC=invalid' -Context $script:ctx
    Assert ($r.exitCode -eq 1) 'domain root link only for definitions that allow it'

    # Uninstall needs only the name's placeholder and removes the owned GPO.
    $script:calls.Clear()
    $r = Invoke-GpoBaseline -Action Uninstall -Definition 'onedrive-automount' -LibraryName 'Accounting' -Apply 'true' -Context $script:ctx
    Assert ($r.exitCode -eq 0 -and $r.report.status -eq 'removed' -and -not $script:gpos.ContainsKey($amName)) "automount uninstall removes its GPO: $($r.report | ConvertTo-Json -Depth 5 -Compress)"

    # onedrive-workstations: everyone by default, one PC for the pilot, then back to everyone.
    $script:ctx = New-FakeWorld
    $ws = @{ Definition = 'onedrive-workstations'; TenantId = $tenant }
    $r = Invoke-GpoBaseline @ws -Apply 'true' -Context $script:ctx
    $g = $script:gpos['Relian - OneDrive (workstations)']
    Assert ($r.exitCode -eq 0 -and -not @($script:calls | Where-Object { $_ -like 'Set-GPPermission*' }) -and (Get-FakePermission $g 'S-1-5-11') -eq 'GpoApply') 'no ApplyTo keeps Authenticated Users apply'
    Assert ([string]$script:regValues["$($g.Id)|HKLM\SOFTWARE\Policies\Microsoft\OneDrive\AllowTenantList|$tenant"].Value -eq $tenant) 'AllowTenantList named and valued by TenantId'
    Assert (-not @($script:pol | Where-Object { $_ -like "$($g.Id)|User|*" })) 'workstation settings stay on the computer side'
    $script:calls.Clear()
    $r = Invoke-GpoBaseline @ws -ApplyTo 'PILOT-PC' -ApplyType 'Computer' -Apply 'true' -Context $script:ctx
    $writes = Get-Writes
    Assert ($r.exitCode -eq 0 -and $writes[1] -eq 'Backup-GPO' -and (Get-FakePermission $g 'S-1-5-11') -eq 'GpoRead' -and (Get-FakePermission $g 'S-1-5-21-9-1103') -eq 'GpoApply') "pilot filter on one computer: $($writes -join ', ')"
    $r = Invoke-GpoBaseline @ws -ApplyTo 'Pilot' -ApplyType 'User' -Context $script:ctx
    Assert ($r.exitCode -eq 1 -and $r.report.status -eq 'refused') 'ApplyType User refused on a computer-side definition'
    $r = Invoke-GpoBaseline @ws -Apply 'true' -Context $script:ctx
    Assert ($r.exitCode -eq 0 -and (Get-FakePermission $g 'S-1-5-11') -eq 'GpoApply') 'fleet run gives Authenticated Users apply again'

    # onedrive-users is user side only.
    $script:ctx = New-FakeWorld
    $r = Invoke-GpoBaseline -Definition 'onedrive-users' -Apply 'true' -Context $script:ctx
    $g = $script:gpos['Relian - OneDrive (users)']
    Assert ($r.exitCode -eq 0 -and ($script:pol -contains "$($g.Id)|User|HKCU\SOFTWARE\Policies\Microsoft\OneDrive\DisablePersonalSync")) 'DisablePersonalSync in the user Registry.pol'

    # ---- Adopt: an unmarked GPO, only by GUID, only with AllowUnmarked, add-only ----
    $script:ctx = New-FakeWorld
    $so = Add-FakeGpo -Context $script:ctx -Name 'Set OneDrive' -Comment 'made by hand'
    $officeKey = 'HKLM\Software\Policies\Microsoft\Office\16.0\Common\OfficeUpdate'
    $script:regValues["$($so.Id)|$officeKey|updatebranch"] = [pscustomobject]@{ Value = 'Current'; Type = 'String' }
    $adoptId = $so.Id.ToString()
    foreach ($case in @(@{}, @{ AdoptGpo = $adoptId }, @{ AllowUnmarked = 'true' })) {
        $script:calls.Clear()
        $r = Invoke-GpoBaseline -Definition 'workstations-only' -Apply 'true' -Context $script:ctx @case
        Assert ($r.exitCode -eq 1 -and $r.report.status -eq 'refused' -and (Get-Writes).Count -eq 0) "unmarked GPO refused without both flags: $($case.Keys -join ',')"
    }
    $r = Invoke-GpoBaseline -Definition 'cis-ws2022-dc-low-risk' -AdoptGpo $adoptId -AllowUnmarked 'true' -Context $script:ctx
    Assert ($r.exitCode -eq 1) 'a normal definition cannot adopt'
    $script:calls.Clear()
    $r = Invoke-GpoBaseline -Definition 'workstations-only' -AdoptGpo $adoptId -AllowUnmarked 'true' -Context $script:ctx
    Assert ($r.exitCode -eq 0 -and $r.report.status -eq 'plan' -and (Get-Writes).Count -eq 0) 'adopt plan makes zero writes'
    Assert ($r.report.gpo.name -eq 'Set OneDrive' -and $r.report.gpo.adopted -and -not $r.report.gpo.owned) 'adopted GPO named in the report'
    $r = Invoke-GpoBaseline -Definition 'workstations-only' -AdoptGpo $adoptId -AllowUnmarked 'true' -LinkTo 'OU=X,DC=example,DC=invalid' -Context $script:ctx
    Assert ($r.exitCode -eq 1 -and (Get-Writes).Count -eq 0) 'adopted GPO is never linked by this package'
    $r = Invoke-GpoBaseline -Definition 'workstations-only' -AdoptGpo ([guid]::NewGuid().ToString()) -AllowUnmarked 'true' -Context $script:ctx
    Assert ($r.exitCode -eq 1 -and $r.report.status -eq 'refused') 'unknown AdoptGpo refused'
    $script:calls.Clear()
    $r = Invoke-GpoBaseline -Definition 'workstations-only' -AdoptGpo $adoptId -AllowUnmarked 'true' -Apply 'true' -Context $script:ctx
    $writes = Get-Writes
    Assert ($r.exitCode -eq 0 -and $r.report.status -eq 'applied') "adopt apply: $($r.report | ConvertTo-Json -Depth 5 -Compress)"
    Assert ($writes[0] -eq 'Protect-GpbBackupRoot' -and $writes[1] -eq 'Backup-GPO') "adopt backs up before the first write: $($writes -join ', ')"
    Assert ($r.report.backupId -eq '11111111-2222-3333-4444-555555555555') 'adopt prints the backup id'
    Assert (-not @($writes | Where-Object { $_ -match '^(Remove-|New-GPO|Set-GPRegistryValue|Set-GPPermission|New-GPLink|Set-GPLink|Restore-GPO)' })) "adopt only adds: $($writes -join ', ')"
    Assert ($so.Description -eq 'made by hand' -and [string]$script:regValues["$($so.Id)|$officeKey|updatebranch"].Value -eq 'Current') 'adopted GPO keeps its description and settings'
    $wf = @($script:wmi.Values | Where-Object { $_.'msWMI-Name' -eq 'Relian - Workstations' })
    Assert ($script:ad[$adoptId].gPCWQLFilter -eq "[example.invalid;$($wf[0].'msWMI-ID');0]") 'workstation filter linked to the adopted GPO'
    $script:calls.Clear()
    $r = Invoke-GpoBaseline -Definition 'workstations-only' -AdoptGpo $adoptId -AllowUnmarked 'true' -Apply 'true' -Context $script:ctx
    Assert ($r.exitCode -eq 0 -and $r.report.status -eq 'noChange' -and (Get-Writes).Count -eq 0) 'second adopt apply changes nothing'

    # Restore path: undo only what adopt added, after a backup; later edits by others survive.
    $script:regValues["$($so.Id)|HKLM\Software\Policies\Later|ByClient"] = [pscustomobject]@{ Value = 1; Type = 'DWord' }
    $script:calls.Clear()
    $r = Invoke-GpoBaseline -Action Uninstall -Definition 'workstations-only' -AdoptGpo $adoptId -AllowUnmarked 'true' -Context $script:ctx
    Assert ($r.exitCode -eq 0 -and $r.report.status -eq 'plan' -and @($r.report.changes).Count -eq 1 -and $r.report.changes[0].kind -eq 'unlinkWmi' -and $r.report.lastBackupId -eq '11111111-2222-3333-4444-555555555555' -and (Get-Writes).Count -eq 0) "adopt undo plan writes nothing and names the pre-adopt backup: $($r.report | ConvertTo-Json -Depth 5 -Compress)"
    $r = Invoke-GpoBaseline -Action Uninstall -Definition 'workstations-only' -AdoptGpo $adoptId -AllowUnmarked 'true' -Apply 'true' -Context $script:ctx
    $writes = Get-Writes
    Assert ($r.exitCode -eq 0 -and $r.report.status -eq 'undone' -and $writes[1] -eq 'Backup-GPO' -and $r.report.backupId -and -not @($writes | Where-Object { $_ -match '^(Restore-GPO|Remove-GPO|Remove-ADObject)' })) "adopt undo backs up first, never restores or removes: $($writes -join ', ')"
    Assert (-not $script:ad[$adoptId].gPCWQLFilter -and $script:gpos.ContainsKey('Set OneDrive')) 'undo clears the WMI link adopt added'
    Assert ([string]$script:regValues["$($so.Id)|HKLM\Software\Policies\Later|ByClient"].Value -eq '1' -and [string]$script:regValues["$($so.Id)|$officeKey|updatebranch"].Value -eq 'Current') 'undo keeps settings adopt did not add'
    $r = Invoke-GpoBaseline -Action Uninstall -Definition 'workstations-only' -AdoptGpo $adoptId -AllowUnmarked 'true' -Apply 'true' -Context $script:ctx
    Assert ($r.exitCode -eq 0 -and $r.report.status -eq 'noChange') 'second undo changes nothing'
    # Adopt, someone clears the link, uninstall finds nothing: the record retires, so a link set again later stays.
    [void](Invoke-GpoBaseline -Definition 'workstations-only' -AdoptGpo $adoptId -AllowUnmarked 'true' -Apply 'true' -Context $script:ctx)
    $relink = $script:ad[$adoptId].gPCWQLFilter
    $script:ad[$adoptId].gPCWQLFilter = $null
    $r = Invoke-GpoBaseline -Action Uninstall -Definition 'workstations-only' -AdoptGpo $adoptId -AllowUnmarked 'true' -Apply 'true' -Context $script:ctx
    Assert ($r.report.status -eq 'noChange') 'undo with the link already gone changes nothing'
    $script:ad[$adoptId].gPCWQLFilter = $relink
    $r = Invoke-GpoBaseline -Action Uninstall -Definition 'workstations-only' -AdoptGpo $adoptId -AllowUnmarked 'true' -Apply 'true' -Context $script:ctx
    Assert ($r.report.status -eq 'noChange' -and $script:ad[$adoptId].gPCWQLFilter -eq $relink) 'retired record never clears a link set again by someone else'
    $script:ad[$adoptId].gPCWQLFilter = $null
    # A link someone else set later is not ours to clear.
    $script:ad[$adoptId].gPCWQLFilter = '[example.invalid;{CCCCCCCC-0000-0000-0000-000000000000};0]'
    $r = Invoke-GpoBaseline -Action Uninstall -Definition 'workstations-only' -AdoptGpo $adoptId -AllowUnmarked 'true' -Apply 'true' -Context $script:ctx
    Assert ($r.report.status -eq 'noChange' -and $script:ad[$adoptId].gPCWQLFilter -like '*CCCCCCCC*') 'undo leaves a foreign WMI link'
    # A GPO that already used the workstation filter before adoption keeps it: adopt added nothing, so there is nothing to undo.
    $pre = Add-FakeGpo -Context $script:ctx -Name 'Already Filtered' -Comment ''
    $wfNow = @($script:wmi.Values | Where-Object { $_.'msWMI-Name' -eq 'Relian - Workstations' })[0]
    $script:ad[$pre.Id.ToString()].gPCWQLFilter = "[example.invalid;$($wfNow.'msWMI-ID');0]"
    $r = Invoke-GpoBaseline -Definition 'workstations-only' -AdoptGpo $pre.Id.ToString() -AllowUnmarked 'true' -Apply 'true' -Context $script:ctx
    Assert ($r.report.status -eq 'noChange') 'adopting an already filtered GPO changes nothing'
    $r = Invoke-GpoBaseline -Action Uninstall -Definition 'workstations-only' -AdoptGpo $pre.Id.ToString() -AllowUnmarked 'true' -Apply 'true' -Context $script:ctx
    Assert ($r.report.status -eq 'noChange' -and $script:ad[$pre.Id.ToString()].gPCWQLFilter -eq "[example.invalid;$($wfNow.'msWMI-ID');0]") 'undo keeps a WMI link that predates adoption'

    # Add-only: an existing different WMI link or value is a conflict, never replaced.
    $script:ctx = New-FakeWorld
    $so = Add-FakeGpo -Context $script:ctx -Name 'Set OneDrive' -Comment ''
    $script:ad[$so.Id.ToString()].gPCWQLFilter = '[example.invalid;{AAAAAAAA-0000-0000-0000-000000000000};0]'
    $script:calls.Clear()
    $r = Invoke-GpoBaseline -Definition 'workstations-only' -AdoptGpo $so.Id.ToString() -AllowUnmarked 'true' -Apply 'true' -Context $script:ctx
    Assert ($r.exitCode -eq 1 -and $r.report.status -eq 'refused' -and (Get-Writes).Count -eq 0) 'adopt never replaces an existing WMI link'
    $script:ad[$so.Id.ToString()].gPCWQLFilter = $null
    $script:wmi['{BBBBBBBB-0000-0000-0000-000000000000}'] = @{ DistinguishedName = 'CN={BBBBBBBB-0000-0000-0000-000000000000},CN=SOM,CN=WMIPolicy,CN=System,DC=example,DC=invalid'; 'msWMI-Name' = 'Relian - Workstations'; 'msWMI-Parm1' = '[relian-gpo-baseline:onedrive-workstations] x'; 'msWMI-Parm2' = 'other'; 'msWMI-ID' = '{BBBBBBBB-0000-0000-0000-000000000000}' }
    $r = Invoke-GpoBaseline -Definition 'workstations-only' -AdoptGpo $so.Id.ToString() -AllowUnmarked 'true' -Apply 'true' -Context $script:ctx
    Assert ($r.exitCode -eq 1 -and $r.report.status -eq 'refused' -and (Get-Writes).Count -eq 0 -and $script:wmi['{BBBBBBBB-0000-0000-0000-000000000000}'].'msWMI-Parm2' -eq 'other') 'adopt never rewrites a shared WMI filter'
    $script:wmi.Clear()
    # Adopt adds only a WMI link: a failed registry read cannot be told from an absent value.
    $adoptReg = [pscustomobject]@{ id = 'test-adopt'; adopt = $true; description = 'd'; allowDefaultPolicy = $false; security = @(); audit = @()
        registry = @([pscustomobject]@{ cis = 'x'; key = 'HKLM\Software\Policies\Relian\Test'; valueName = 'Added'; type = 'DWord'; value = 1 }) }
    $script:calls.Clear()
    $r = Invoke-GpoBaseline -DefinitionObject $adoptReg -AdoptGpo $so.Id.ToString() -AllowUnmarked 'true' -Apply 'true' -Context $script:ctx
    Assert ($r.exitCode -eq 1 -and $r.report.status -eq 'refused' -and (Get-Writes).Count -eq 0) 'adopt definition may not carry registry values'
    foreach ($k in @('security', 'securityFilter')) {
        $bad = [pscustomobject]@{ id = 'test-adopt'; adopt = $true; description = 'd'; allowDefaultPolicy = $false; registry = @(); audit = @(); security = @() }
        if ($k -eq 'security') { $bad.security = @([pscustomobject]@{ cis = 'x'; section = 'System Access'; key = 'LockoutBadCount'; value = '1' }) } else { $bad | Add-Member securityFilter 'optional' }
        $r = Invoke-GpoBaseline -DefinitionObject $bad -AdoptGpo $so.Id.ToString() -AllowUnmarked 'true' -Context $script:ctx
        Assert ($r.exitCode -eq 1 -and $r.report.status -eq 'refused') "adopt definition may not carry $k"
    }
    $ddp3 = Add-FakeGpo -Context $script:ctx -Name 'Default Domain Policy' -Comment '' -Id '31B2F340-016D-11D2-945F-00C04FB984F9'
    $r = Invoke-GpoBaseline -Definition 'workstations-only' -AdoptGpo '31B2F340-016D-11D2-945F-00C04FB984F9' -AllowUnmarked 'true' -Context $script:ctx
    Assert ($r.exitCode -eq 1 -and $r.report.status -eq 'refused') 'default policies are never adopted'

    # password-lockout: Default Domain Policy, both flags, backup first, then the four values.
    $script:ctx = New-FakeWorld
    $ddp4 = Add-FakeGpo -Context $script:ctx -Name 'Default Domain Policy' -Comment '' -Id '31B2F340-016D-11D2-945F-00C04FB984F9'
    $r = Invoke-GpoBaseline -Definition 'password-lockout' -Apply 'true' -Context $script:ctx
    Assert ($r.exitCode -eq 1 -and (Get-Writes).Count -eq 0) 'password-lockout needs AllowDefaultPolicy'
    $r = Invoke-GpoBaseline -Definition 'password-lockout' -AllowDefaultPolicy 'true' -Context $script:ctx
    Assert ($r.exitCode -eq 0 -and @($r.report.changes | Where-Object { $_.kind -eq 'security' }).Count -eq 4 -and (Get-Writes).Count -eq 0) 'password-lockout plan lists four values, writes nothing'
    $r = Invoke-GpoBaseline -Definition 'password-lockout' -AllowDefaultPolicy 'true' -Apply 'true' -Context $script:ctx
    $writes = Get-Writes
    Assert ($r.exitCode -eq 0 -and $writes[1] -eq 'Backup-GPO' -and $r.report.backupId) "password-lockout backed up first: $($writes -join ', ')"
    $sa = (ConvertFrom-GpbInf ([IO.File]::ReadAllText((Join-Path $script:ctx.PoliciesPath '{31B2F340-016D-11D2-945F-00C04FB984F9}\Machine\Microsoft\Windows NT\SecEdit\GptTmpl.inf'))))['System Access']
    Assert ($sa['MinimumPasswordLength'] -eq '12' -and $sa['LockoutBadCount'] -eq '10' -and $sa['ResetLockoutCount'] -eq '15' -and $sa['LockoutDuration'] -eq '15' -and -not $sa.Contains('MaximumPasswordAge')) 'G5 values, no expiry set'
    $r = Invoke-GpoBaseline -Definition 'password-lockout' -AllowDefaultPolicy 'true' -Apply 'true' -Context $script:ctx
    Assert ($r.report.status -eq 'noChange') 'password-lockout is idempotent'
    # A publish-only retry after a partial apply keeps the restore point taken before the values changed.
    $stateDir = Join-Path $script:ctx.BackupRoot '{31B2F340-016D-11D2-945F-00C04FB984F9}'
    $restorePoint = [IO.File]::ReadAllText((Join-Path $stateDir 'last-backup.json'))
    [IO.File]::WriteAllText((Join-Path $stateDir 'pending-publish'), 'x')
    Start-Sleep -Milliseconds 20
    $r = Invoke-GpoBaseline -Definition 'password-lockout' -AllowDefaultPolicy 'true' -Apply 'true' -Context $script:ctx
    Assert ($r.exitCode -eq 0 -and @($r.report.changes).Count -eq 1 -and $r.report.changes[0].kind -eq 'publish' -and [IO.File]::ReadAllText((Join-Path $stateDir 'last-backup.json')) -eq $restorePoint) 'publish-only retry keeps the restore point'
} finally { Remove-Item -LiteralPath $tmp -Recurse -Force }
'gpo-baseline tests passed'
