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
    $policies = Join-Path $tmp ([guid]::NewGuid().ToString('n'))
    [void](New-Item -ItemType Directory -Path $policies)
    return @{ Server = 'pdc.example.invalid'; DomainDN = 'DC=example,DC=invalid'; PoliciesPath = $policies; BackupRoot = (Join-Path $policies 'backups'); IsPdc = $true }
}
function Add-FakeGpo {
    param($Context, [string]$Name, [string]$Comment, [guid]$Id = [guid]::NewGuid())
    $script:gpos[$Name] = [pscustomobject]@{ Id = $Id; DisplayName = $Name; Description = $Comment }
    $script:ad[$Id.ToString()] = @{ versionNumber = 0; gPCMachineExtensionNames = '' }
    $dir = Join-Path $Context.PoliciesPath ('{' + $Id.ToString().ToUpper() + '}')
    [void](New-Item -ItemType Directory -Path $dir -Force)
    [IO.File]::WriteAllText((Join-Path $dir 'GPT.INI'), "[General]`r`nVersion=0`r`n")
    return $script:gpos[$Name]
}
function Find-FakeGpo { param($Guid) foreach ($g in $script:gpos.Values) { if ($g.Id -eq [guid]$Guid) { return $g } } }
function Step-FakeVersion {
    param($Context, [guid]$Id)
    $script:ad[$Id.ToString()].versionNumber = [int]$script:ad[$Id.ToString()].versionNumber + 1
    $ini = Join-Path $Context.PoliciesPath ('{' + $Id.ToString().ToUpper() + '}\GPT.INI')
    [IO.File]::WriteAllText($ini, "[General]`r`nVersion=$($script:ad[$Id.ToString()].versionNumber)`r`n")
}
function Import-Module { param([Parameter(ValueFromRemainingArguments)]$Rest) }
function Get-GPO {
    param($Name, $Guid, $Server, $ErrorAction)
    $script:calls.Add('Get-GPO')
    if ($Guid) { $g = Find-FakeGpo $Guid } elseif ($script:gpos.ContainsKey($Name)) { $g = $script:gpos[$Name] } else { $g = $null }
    if (-not $g) { throw [System.ArgumentException]::new('not found') }
    return $g
}
function New-GPO {
    param($Name, $Comment, $Server)
    $script:calls.Add('New-GPO')
    return (Add-FakeGpo -Context $script:ctx -Name $Name -Comment $Comment)
}
function Get-GPRegistryValue {
    param($Guid, $Key, $ValueName, $Server, $ErrorAction)
    $k = "$Guid|$Key|$ValueName"
    if (-not $script:regValues.ContainsKey($k)) { throw [System.ArgumentException]::new('missing value') }
    return $script:regValues[$k]
}
function Set-GPRegistryValue {
    param($Guid, $Key, $ValueName, $Type, $Value, $Server)
    $script:setCount++
    if ($script:failSetAfter -ge 0 -and $script:setCount -gt $script:failSetAfter) { throw 'simulated write failure' }
    $script:calls.Add("Set-GPRegistryValue $Key\$ValueName")
    $script:regValues["$Guid|$Key|$ValueName"] = [pscustomobject]@{ Value = $Value; Type = $Type }
    Step-FakeVersion -Context $script:ctx -Id $Guid
    $o = $script:ad[([guid]$Guid).ToString()]
    $o.gPCMachineExtensionNames = Add-GpbExtensionNames -Current $o.gPCMachineExtensionNames -Pairs @($reg)
}
function Backup-GPO {
    param($Guid, $Path, $Comment, $Server)
    $script:calls.Add('Backup-GPO')
    Assert (Test-Path -LiteralPath $Path) 'backup folder exists before Backup-GPO'
    return [pscustomobject]@{ Id = [guid]'11111111-2222-3333-4444-555555555555' }
}
function Restore-GPO { param($BackupId, $Path, $Server) $script:calls.Add("Restore-GPO $BackupId") }
function Remove-GPO { param($Guid, $Server) $script:calls.Add('Remove-GPO'); $g = Find-FakeGpo $Guid; $script:gpos.Remove($g.DisplayName) }
function Get-ADObject {
    param($Identity, $Properties, $Server)
    $id = ([regex]::Match($Identity, '\{([0-9a-fA-F-]{36})\}').Groups[1].Value).ToLower()
    $o = $script:ad[$id]
    return [pscustomobject]@{ versionNumber = $o.versionNumber; gPCMachineExtensionNames = $o.gPCMachineExtensionNames }
}
function Set-ADObject {
    param($Identity, $Replace, $Server)
    $script:calls.Add('Set-ADObject')
    $id = ([regex]::Match($Identity, '\{([0-9a-fA-F-]{36})\}').Groups[1].Value).ToLower()
    foreach ($k in $Replace.Keys) { $script:ad[$id][$k] = $Replace[$k] }
}
function Get-GPInheritance {
    param($Target, $Server)
    return [pscustomobject]@{ GpoLinks = @($script:links.Values | Where-Object { $_.Target -eq $Target }) }
}
function New-GPLink {
    param($Guid, $Target, $LinkEnabled, $Server)
    $script:calls.Add("New-GPLink $LinkEnabled")
    $script:links["$Guid|$Target"] = [pscustomobject]@{ GpoId = [guid]$Guid; Target = $Target; Enabled = ($LinkEnabled -eq 'Yes') }
}
function Set-GPLink { param($Guid, $Target, $LinkEnabled, $Server) $script:calls.Add("Set-GPLink $LinkEnabled") }
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
} finally { Remove-Item -LiteralPath $tmp -Recurse -Force }
'gpo-baseline tests passed'
