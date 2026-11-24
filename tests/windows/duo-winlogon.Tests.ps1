$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
function Assert($Condition, $Label) { if (-not $Condition) { throw "FAIL $Label" } }
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$path = Join-Path $root 'windows/packages/duo-winlogon/Invoke-DuoWinLogon.ps1'
$env:RELIAN_DEPLOY_TEST = '1'
. $path

# Parses as Windows PowerShell 5.1.
$tokens = $null; $errors = $null
[void][Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
Assert ($errors.Count -eq 0) 'parser'
foreach ($kind in @('QuestionQuestion', 'QuestionQuestionEquals', 'QuestionDot', 'QuestionLBracket', 'AndAnd', 'OrOr', 'QuestionMark')) {
    Assert (-not @($tokens | Where-Object { [string]$_.Kind -eq $kind })) "no PowerShell 7 token $kind"
}

# Pins equal the release file, and the release file equals Duo's and Microsoft's published hashes.
$rel = Get-Content -LiteralPath (Join-Path $root 'windows/releases/duo-winlogon.json') -Raw | ConvertFrom-Json
Assert ($rel.version -eq '6.0.0.4198' -and $script:DuoPin.Version -eq $rel.version) 'pin version'
Assert ($script:DuoPin.ZipSha -eq '24e30573e1429e6aaa9578969212b82be485df337860394fd68b5dc180b68e7a' -and $rel.zipSha256 -eq $script:DuoPin.ZipSha) 'pin zip'
Assert ($script:DuoPin.Msi['x64'][1] -eq 'ce64870036390a8dcf91b04a68676bccbeacbe3ec51616aad0f3685187258f30') 'pin msi x64'
Assert ($script:DuoArchive['4.3.1.4861'].ZipSha -eq '0eb91974f11423157a2daa49c77ae6507200dd1efac8d409ba78f340a8f91daf') 'archive 4.3.1 zip'
Assert ($script:DuoArchive['4.3.1.4861'].Msi['x64'][1] -eq '42768db1dc8fa38ec30e8956f37c0b0b421c9b6926af81ad33803048b78a95c7') 'archive 4.3.1 msi'
Assert ($script:DuoArchive['5.2.1.2007'].ZipSha -eq 'c9ae978212e74859fdfc776db571bc7ac286e33d2ad0e44e64eb2026f83c9656') 'archive 5.2.1 zip'
Assert ($script:VcRedist['x64'][1] -eq '9c02c9ed120f671b900e6b9471d890e3b2414117a7e53f4ae2e855466fa2b7c9') 'vc x64'

# Plan.
Assert ((Get-DuoPlan -Products @()) -eq 'install') 'plan install'
foreach ($v in @('4.3.1.4861', '5.2.1.2007')) { Assert ((Get-DuoPlan -Products @([pscustomobject]@{ Version = $v })) -eq 'upgrade') "plan upgrade $v" }
Assert ((Get-DuoPlan -Products @([pscustomobject]@{ Version = '4.2.0.100' })) -eq 'refuse') 'plan refuse unknown old build'
Assert ((Get-DuoPlan -Products @([pscustomobject]@{ Version = '6.0.0.4198' })) -eq 'configure') 'plan configure at pin'
Assert ((Get-DuoPlan -Products @([pscustomobject]@{ Version = '6.0.1.100' })) -eq 'configure') 'plan configure newer'
Assert ((Get-DuoPlan -Products @([pscustomobject]@{ Version = '' })) -eq 'refuse') 'plan refuse unreadable version'

# A fake PC: registry values, products, provider, VC++ runtime. Seams only; the package logic runs as is.
$secret = 'b2' * 20
$settings = @{ IKey = 'DIAB1234567890WXYZ12'; SKey = $secret; Host = 'api-0000abcd.duosecurity.com'; Marker = '0123abcd' }
function New-Pc([string]$Version) {
    $pc = @{ Products = @(); Values = @{}; Provider = $false; Vc = $true; Calls = [Collections.Generic.List[string]]::new(); Policy = @(); Marker = $null
             NewBreaksProvider = $false; NewDropsValue = ''; VcFixes = $true; MsiCode = 0 }
    if ($Version) {
        $pc.Products = @([pscustomobject]@{ Name = 'Duo Authentication for Windows Logon x64'; Version = $Version; Code = '{OLD}' })
        $pc.Values = @{ IKey = @('DIOLD000000000000000', 'String'); SKey = @(('c3' * 20), 'String'); Host = @('api-0000abcd.duosecurity.com', 'String')
                        AutoPush = @(1, 'DWord'); FailOpen = @(0, 'DWord'); RdpOnly = @(0, 'DWord'); ProvidersWhitelist = @('{X}', 'String') }
        $pc.Provider = $true
    }
    $pc
}
function Use-Pc($pc) {
    $script:PC = $pc
    $script:ReadProducts = { $script:PC.Products }
    $script:ReadValues = { if ($script:PC.Products.Count -or $script:PC.Values.Count) { $copy = @{}; foreach ($k in $script:PC.Values.Keys) { $copy[$k] = $script:PC.Values[$k] }; $copy } else { $null } }
    $script:SetValue = { param($Name, $Value, $Kind) $script:PC.Values[$Name] = @($Value, $Kind) }
    $script:DeleteValue = { param($Name) [void]$script:PC.Values.Remove($Name) }
    $script:PolicyValueNames = { $script:PC.Policy }
    $script:ProviderRegistered = { $script:PC.Provider }
    $script:VcPresent = { $script:PC.Vc }
    $script:WriteMarker = { param($Value) $script:PC.Marker = $Value }
    $script:NewWorkDir = { [IO.Path]::GetTempPath() }
    $script:RemoveWorkDir = { param($Dir) }
    $script:Fetch = { param($Url, $Sha, $Dest) $script:PC.Calls.Add("fetch $Url"); $Dest }
    $script:ExpandMsi = { param($Zip, $Name, $Sha, $Dir) "$Dir\$Name|$Sha" }
    $script:RunExe = { param($File, $Arguments) $script:PC.Calls.Add("exe $File $($Arguments -join ' ')"); if ($script:PC.VcFixes) { $script:PC.Vc = $true }; 0 }
    $script:RunMsi = {
        param($Arguments)
        $script:PC.Calls.Add('msi ' + ($Arguments -join ' '))
        if ($Arguments[0] -eq '/i') {
            $msiSha = ($Arguments[1] -split '\|')[1].Trim('"')
            $ver = if ($msiSha -eq $script:DuoPin.Msi['x64'][1]) { '6.0.0.4198' } else { '4.3.1.4861' }
            $code = if ($ver -eq '6.0.0.4198') { '{NEW}' } else { '{OLD}' }
            $script:PC.Products = @([pscustomobject]@{ Name = 'Duo Authentication for Windows Logon x64'; Version = $ver; Code = $code })
            $script:PC.Provider = -not ($ver -eq '6.0.0.4198' -and $script:PC.NewBreaksProvider)
            if ($script:PC.NewDropsValue) { [void]$script:PC.Values.Remove($script:PC.NewDropsValue) }
            return $script:PC.MsiCode
        }
        $script:PC.Products = @($script:PC.Products | Where-Object { $_.Code -ne $Arguments[1] }); $script:PC.Provider = $false
        0
    }
}
$env:PROCESSOR_ARCHITECTURE = 'AMD64'; $env:PROCESSOR_ARCHITEW6432 = ''

# Upgrade 4.3.1 -> 6.0.0: no key on any msiexec call, a value the upgrade dropped comes back, settings and marker written.
$pc = New-Pc '4.3.1.4861'; $pc.NewDropsValue = 'ProvidersWhitelist'; Use-Pc $pc
$line = Invoke-DuoWinLogon -Settings $settings
$r = $line | ConvertFrom-Json
Assert ($r.status -eq 'upgraded' -and $r.before -eq '4.3.1.4861' -and $r.after -eq '6.0.0.4198') "upgrade status $line"
Assert ($pc.Products[0].Version -eq '6.0.0.4198' -and $pc.Values['ProvidersWhitelist'][0] -eq '{X}') 'dropped value restored'
Assert ($pc.Values['SKey'][0] -eq $secret -and $pc.Values['IKey'][0] -eq 'DIAB1234567890WXYZ12' -and $pc.Values['FailOpen'][0] -eq 0) 'settings written'
Assert ($pc.Marker -eq '0123abcd') 'marker'
Assert (-not $line.Contains($secret)) 'secret not in output'
foreach ($c in $pc.Calls) { Assert ($c -notmatch 'IKEY|SKEY|HOST=|' + $secret) "no key in $c" }
Assert (@($pc.Calls | Where-Object { $_ -like 'msi /i*' }).Count -eq 1 -and ($pc.Calls -join ';') -match 'ISADMIN=1') 'one install, ISADMIN'
# The rollback build is fetched before anything changes.
Assert (($pc.Calls[0]) -like 'fetch *4.3.1.zip') "rollback build first: $($pc.Calls[0])"

# Upgrade breaks the credential provider: put the old build and every old value back.
$pc = New-Pc '4.3.1.4861'; $pc.NewBreaksProvider = $true; Use-Pc $pc
$before = @{}; foreach ($k in $pc.Values.Keys) { $before[$k] = $pc.Values[$k][0] }
$r = (Invoke-DuoWinLogon -Settings $settings) | ConvertFrom-Json
Assert ($r.status -eq 'rolledBack' -and $r.after -eq '4.3.1.4861') "rollback status $($r.status)"
Assert (($pc.Calls -join ';') -match 'msi /x \{NEW\}.*msi /i .*42768db1') 'removed new, reinstalled old'
foreach ($k in $before.Keys) { Assert ($pc.Values[$k][0] -eq $before[$k]) "old value $k back" }
Assert ($pc.Provider -and $null -eq $pc.Marker) 'provider back, no marker'

# An old build with no pinned rollback copy is left alone.
$pc = New-Pc '4.2.0.100'; Use-Pc $pc
$r = (Invoke-DuoWinLogon -Settings $settings) | ConvertFrom-Json
Assert ($r.status -eq 'refused' -and $pc.Calls.Count -eq 0 -and $pc.Values['IKey'][0] -eq 'DIOLD000000000000000') 'refused, nothing done'

# VC++ runtime missing: installed first; still missing after: Duo untouched.
$pc = New-Pc '4.3.1.4861'; $pc.Vc = $false; Use-Pc $pc
$r = (Invoke-DuoWinLogon -Settings $settings) | ConvertFrom-Json
Assert ($r.status -eq 'upgraded' -and ($pc.Calls -join ';') -match 'exe .*vc_redist.*/install /quiet /norestart;.*msi /i') "vc first: $($pc.Calls -join ';')"
$pc = New-Pc '4.3.1.4861'; $pc.Vc = $false; $pc.VcFixes = $false; Use-Pc $pc
$r = (Invoke-DuoWinLogon -Settings $settings) | ConvertFrom-Json
Assert ($r.status -eq 'failed' -and -not ($pc.Calls -join ';').Contains('msi ') -and $pc.Products[0].Version -eq '4.3.1.4861') 'vc missing: no msi'

# Fresh install whose provider does not register: removed again.
$pc = New-Pc ''; $pc.NewBreaksProvider = $true; Use-Pc $pc
$r = (Invoke-DuoWinLogon -Settings $settings) | ConvertFrom-Json
Assert ($r.status -eq 'failed' -and $pc.Products.Count -eq 0 -and ($pc.Calls -join ';') -match 'msi /x \{NEW\}') 'fresh install removed'

# Fresh install: 3010 is success with a restart pending.
$pc = New-Pc ''; $pc.MsiCode = 3010; Use-Pc $pc
$r = (Invoke-DuoWinLogon -Settings $settings) | ConvertFrom-Json
Assert ($r.status -eq 'installed' -and $r.restartPending -eq $true -and $pc.Marker -eq '0123abcd') 'installed, restart pending'

# Already at the pin: settings only; a policy key that would override them stops everything.
$pc = New-Pc '6.0.0.4198'; Use-Pc $pc
$r = (Invoke-DuoWinLogon -Settings $settings) | ConvertFrom-Json
Assert ($r.status -eq 'configured' -and -not ($pc.Calls -join ';').Contains('msi ')) 'configured only'
$pc = New-Pc '4.3.1.4861'; $pc.Policy = @('FailOpen'); Use-Pc $pc
$r = (Invoke-DuoWinLogon -Settings $settings) | ConvertFrom-Json
Assert ($r.status -eq 'refused' -and $pc.Calls.Count -eq 0) 'policy override refused'

# No settings (runner use): upgrade keeps the PC's own keys.
$pc = New-Pc '5.2.1.2007'; Use-Pc $pc
$r = (Invoke-DuoWinLogon -Settings $null) | ConvertFrom-Json
Assert ($r.status -eq 'upgraded' -and $pc.Values['IKey'][0] -eq 'DIOLD000000000000000' -and $null -eq $pc.Marker) 'upgrade without settings'

Write-Output 'duo-winlogon ok'
