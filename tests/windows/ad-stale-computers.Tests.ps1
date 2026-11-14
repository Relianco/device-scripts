$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
function Assert($Condition, $Label) { if (-not $Condition) { throw "FAIL $Label" } }
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$path = Join-Path $root 'windows/packages/ad-stale-computers/Invoke-AdStaleComputers.ps1'
$env:RELIAN_DEPLOY_TEST = '1'
. $path

# Parses, uses no PowerShell 7 syntax, and every AD write sits in a replaceable script block.
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
Assert ($errors.Count -eq 0) 'parser'
foreach ($kind in @('QuestionQuestion', 'QuestionQuestionEquals', 'QuestionDot', 'QuestionLBracket', 'AndAnd', 'OrOr', 'QuestionMark')) {
    Assert (-not @($tokens | Where-Object { [string]$_.Kind -eq $kind })) "no PowerShell 7 token $kind"
}
$writes = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true) | Where-Object { $_.GetCommandName() -match '^(Set|New|Remove|Disable|Enable|Move|Rename)-AD' })
Assert ($writes.Count -eq 4) 'exactly four AD write calls'
foreach ($w in $writes) {
    $p = $w.Parent; while ($p -and -not ($p -is [Management.Automation.Language.AssignmentStatementAst])) { $p = $p.Parent }
    Assert ($p -and $p.Left.Extent.Text -in @('$script:AscDisable', '$script:AscEnsureOu', '$script:AscMoveTo')) "write $($w.GetCommandName()) only in a write block"
}
Assert ($ast.Extent.Text -notmatch 'Remove-AD') 'never deletes'

# Dates and parent DN.
$ft = { param($d) [datetime]::Parse($d, $null, 'AdjustToUniversal,AssumeUniversal').ToFileTimeUtc() }
Assert ($null -eq (ConvertFrom-AscFileTime 0)) 'zero filetime is never'
Assert ($null -eq (ConvertFrom-AscFileTime ([int64]::MaxValue))) 'max filetime is never'
Assert ((Format-AscDate (ConvertFrom-AscFileTime (& $ft '2025-01-02'))) -eq '2025-01-02') 'filetime round trip'
Assert ((Get-AscParentDn 'CN=PC1,OU=Desk\, Front,DC=example,DC=invalid') -eq 'OU=Desk\, Front,DC=example,DC=invalid') 'escaped comma in parent'

# Scope rules.
function New-Pc {
    param($Name, $Os = 'Windows 10 Pro', $Last = '2025-01-01', $Pwd = '2025-01-01', $Ou = 'OU=Workstations,DC=example,DC=invalid', $Spn = @(), $Group = 515, $Uac = 4096, [switch]$Laps)
    $o = [pscustomobject]@{
        Name = $Name; DistinguishedName = "CN=$Name,$Ou"; OperatingSystem = $Os; Enabled = $true; Description = $null
        lastLogonTimestamp = $(if ($Last) { & $ft $Last } else { $null }); pwdLastSet = $(if ($Pwd) { & $ft $Pwd } else { 0 })
        servicePrincipalName = $Spn; primaryGroupID = $Group; userAccountControl = $Uac
    }
    if ($Laps) { $o | Add-Member 'ms-Mcs-AdmPwdExpirationTime' 1; $o | Add-Member 'ms-Mcs-AdmPwd' 'lapsplain-123' }
    return $o
}
Assert ((Get-AscExclusion (New-Pc 'DC1' -Uac 8192 -Group 516)) -eq 'domainController') 'dc excluded'
Assert ((Get-AscExclusion (New-Pc 'SV1' -Os 'Windows Server 2022 Standard')) -eq 'server') 'server excluded'
Assert ((Get-AscExclusion (New-Pc 'CNO' -Spn @('MSClusterVirtualServer/CNO'))) -eq 'cluster') 'cluster excluded'
Assert ((Get-AscExclusion (New-Pc 'X' -Ou 'OU=Member Servers,DC=example,DC=invalid')) -eq 'serversOu') 'servers OU excluded'
Assert ($null -eq (Get-AscExclusion (New-Pc 'PC1'))) 'workstation in scope'
$now = [datetime]'2026-11-14'; $cut = $now.AddDays(-180)
Assert (Test-AscStale (New-Pc 'A') $cut) 'old is stale'
Assert (-not (Test-AscStale (New-Pc 'B' -Last '2026-11-01') $cut)) 'recent logon not stale'
Assert (-not (Test-AscStale (New-Pc 'C' -Pwd '2026-11-01') $cut)) 'recent password not stale'
Assert (Test-AscStale (New-Pc 'D' -Last $null -Pwd $null) $cut) 'never logged on is stale'

# Argument checks.
Assert ((ConvertTo-AscNameList ' PC1, PC2 ,PC1').Count -eq 2) 'names trimmed and unique'
foreach ($bad in @('', 'a)(cn=*', ('A' * 16), (1..11 | ForEach-Object { "PC$_" }) -join ',')) {
    $threw = $false; try { [void](ConvertTo-AscNameList $bad) } catch { $threw = $true }
    Assert $threw "names refused: $bad"
}
foreach ($bad in @('x', '29', '4000')) { $threw = $false; try { [void](Get-AscDays $bad) } catch { $threw = $true }; Assert $threw "days refused: $bad" }
$threw = $false; try { [void](ConvertTo-AscBool 'yes' 'WhatIf') } catch { $threw = $true }; Assert $threw 'bool refused'

# Stubs for AD.
$script:Writes = [Collections.Generic.List[string]]::new()
$script:Pcs = @(
    (New-Pc 'OLD1' -Laps), (New-Pc 'OLD2'), (New-Pc 'NEW1' -Last '2026-11-10'),
    (New-Pc 'SV1' -Os 'Windows Server 2019 Standard'), (New-Pc 'DC1' -Uac 8192 -Group 516 -Os 'Windows Server 2022')
)
$script:AscSchemaHas = { param($Name) $Name -like 'ms-Mcs-*' }
$script:AscGetComputers = { param($Properties) $script:Pcs }
$script:AscGetComputer = { param($Name, $Properties) $script:Pcs | Where-Object { $_.Name -eq $Name } }
$secretPw = '111111-222222-333333-444444-555555-666666-777777-888888'
$script:AscGetRecoveryAll = { @([pscustomobject]@{ DistinguishedName = 'CN=2025-01-01T00:00:00-00:00{AAAA},CN=OLD1,OU=Workstations,DC=example,DC=invalid' }) }
$script:AscGetRecovery = {
    param($Dn)
    if ($Dn -like 'CN=OLD1,*') { @([pscustomobject]@{ 'msFVE-RecoveryGuid' = [guid]::Empty.ToByteArray(); 'msFVE-RecoveryPassword' = $secretPw; whenCreated = [datetime]'2025-01-01' }) } else { @() }
}
$script:AscDomainDn = { 'DC=example,DC=invalid' }
$script:AscDisable = { param($Dn, $Description) $script:Writes.Add("disable $Dn $Description") }
$script:AscEnsureOu = { param($DomainDn, $Name) $script:Writes.Add("ou $Name"); "OU=$Name,$DomainDn" }
$script:AscMoveTo = { param($Dn, $TargetDn) $script:Writes.Add("move $Dn") }

# Report.
$r = Invoke-AscReport -Days 180 -Now $now | ConvertFrom-Json
Assert ($r.total -eq 5 -and $r.stale -eq 2 -and $r.matched -eq 2) 'report counts'
Assert ($r.excluded.server -eq 1 -and $r.excluded.domainController -eq 1) 'report exclusions'
Assert (($r.computers | Where-Object name -eq 'OLD1').bitlocker -eq 1 -and ($r.computers | Where-Object name -eq 'OLD1').laps -eq 'legacy') 'report bitlocker and laps'
$all = Invoke-AscReport -Days 180 -Filter All -Now $now | ConvertFrom-Json
Assert ($all.matched -eq 3) 'report all'
$script:Pcs = @(1..120 | ForEach-Object { New-Pc ('PC{0:D3}' -f $_) -Ou ('OU=' + ('x' * 60) + ',DC=example,DC=invalid') }) + @($script:Pcs)
$json = Invoke-AscReport -Days 180 -Now $now
$page = $json | ConvertFrom-Json
Assert ([Text.Encoding]::UTF8.GetByteCount($json) -le 8000 -and $page.truncated -and $page.nextOffset -eq $page.computers.Count) 'report paged'
$page2 = Invoke-AscReport -Days 180 -Offset $page.nextOffset -Now $now | ConvertFrom-Json
Assert ($page2.computers[0].name -ne $page.computers[0].name) 'second page moves on'
$script:Pcs = @($script:Pcs | Where-Object { $_.Name -notlike 'PC*' })

# Apply: key pair for the round trip.
$rsa = [Security.Cryptography.RSA]::Create(2048)
$pub = [Convert]::ToBase64String($rsa.ExportParameters($false).Modulus)
function Unprotect-Backup($b) {
    $aes = [Security.Cryptography.Aes]::Create(); $aes.Key = $rsa.Decrypt([Convert]::FromBase64String($b.key), [Security.Cryptography.RSAEncryptionPadding]::OaepSHA1)
    $aes.IV = [Convert]::FromBase64String($b.iv); $c = [Convert]::FromBase64String($b.data)
    $gz = [IO.Compression.GZipStream]::new([IO.MemoryStream]::new($aes.CreateDecryptor().TransformFinalBlock($c, 0, $c.Length)), [IO.Compression.CompressionMode]::Decompress)
    $out = [IO.MemoryStream]::new(); $gz.CopyTo($out)
    return [Text.Encoding]::UTF8.GetString($out.ToArray()) | ConvertFrom-Json
}

$threw = $false; try { [void](Invoke-AscApply -Names @('OLD1') -Days 180 -RecipientKey '' -WhatIf $true -Move $false -Now $now) } catch { $threw = $true }
Assert $threw 'apply needs a key'
$threw = $false; try { [void](Invoke-AscApply -Names @('OLD1') -Days 180 -RecipientKey ([Convert]::ToBase64String([byte[]](1..64))) -WhatIf $true -Move $false -Now $now) } catch { $threw = $true }
Assert $threw 'apply refuses a short key'

$w = Invoke-AscApply -Names @('OLD1', 'NEW1', 'SV1', 'NOPE') -Days 180 -RecipientKey $pub -WhatIf $true -Move $true -Now $now
Assert ($script:Writes.Count -eq 0) 'WhatIf writes nothing'
Assert ($w.Failed) 'refusals fail the run'
Assert ($w.Json -notmatch [regex]::Escape($secretPw) -and $w.Json -notmatch 'lapsplain') 'no plain secret in output'
$wr = $w.Json | ConvertFrom-Json
$res = @{}; foreach ($c in $wr.computers) { $res[$c.name] = $c.result }
Assert ($res.OLD1 -eq 'planned' -and $res.NEW1 -eq 'refused:notStale' -and $res.SV1 -eq 'refused:server' -and $res.NOPE -eq 'notFound') 'apply plan'
$b = Unprotect-Backup $wr.backup
$old1 = $b | Where-Object name -eq 'OLD1'
Assert ($old1.bitlocker[0].recoveryKey -eq $secretPw -and $old1.bitlocker[0].recoveryGuid -eq [guid]::Empty.ToString()) 'bitlocker backed up'
Assert ($old1.laps.'ms-Mcs-AdmPwd' -eq 'lapsplain-123') 'laps backed up'
Assert (@($b).Count -eq 3) 'every found computer backed up'

$a = Invoke-AscApply -Names @('OLD1', 'OLD2') -Days 180 -RecipientKey $pub -WhatIf $false -Move $false -Now $now
Assert (-not $a.Failed) 'apply ok'
Assert ($script:Writes.Count -eq 2 -and $script:Writes[0] -eq 'disable CN=OLD1,OU=Workstations,DC=example,DC=invalid Disabled by Relian 2026-11-14 stale >180d') 'disabled in place with description'
$script:Writes.Clear()
$m = Invoke-AscApply -Names @('OLD2') -Days 180 -RecipientKey $pub -WhatIf $false -Move $true -Now $now | ForEach-Object { $_.Json | ConvertFrom-Json }
Assert (($script:Writes -join '|') -eq 'disable CN=OLD2,OU=Workstations,DC=example,DC=invalid Disabled by Relian 2026-11-14 stale >180d|ou Disabled Computers|move CN=OLD2,OU=Workstations,DC=example,DC=invalid') 'move after disable'
Assert ($m.computers[0].result -eq 'disabledMoved' -and $m.computers[0].movedTo -eq 'OU=Disabled Computers,DC=example,DC=invalid') 'move reported'

$script:AscDisable = { param($Dn, $Description) throw [UnauthorizedAccessException]::new('denied') }
$f = Invoke-AscApply -Names @('OLD2') -Days 180 -RecipientKey $pub -WhatIf $false -Move $true -Now $now
Assert ($f.Failed -and ($f.Json | ConvertFrom-Json).computers[0].result -eq 'planned;failed:UnauthorizedAccessException') 'write failure reported'

Write-Output 'ad-stale-computers tests passed'
