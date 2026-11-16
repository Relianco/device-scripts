$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
function Assert($Condition, $Label) { if (-not $Condition) { throw "FAIL $Label" } }
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$path = Join-Path $root 'windows/packages/endpoint-evidence/Invoke-EndpointEvidence.ps1'
$env:RELIAN_DEPLOY_TEST = '1'
. $path

# Parses, uses no syntax newer than Windows PowerShell 5.1, calls no write cmdlet, loads no toolkit.
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
Assert ($errors.Count -eq 0) 'parser'
foreach ($kind in @('QuestionQuestion', 'QuestionQuestionEquals', 'QuestionDot', 'QuestionLBracket', 'AndAnd', 'OrOr', 'QuestionMark')) {
    Assert (-not @($tokens | Where-Object { [string]$_.Kind -eq $kind })) "no PowerShell 7 token $kind"
}
$commands = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() })
foreach ($c in $commands) { Assert ($c -notmatch '^(Set|New|Remove|Restore|Backup|Import|Rename|Copy|Move|Start|Stop|Restart|Clear|Register|Invoke-WebRequest|Show)-') "read-only and silent: no $c" }
foreach ($c in @('reg', 'reg.exe', 'msg', 'Ninja-Property-Set')) { Assert ($commands -notcontains $c) "read-only: no $c" }
$source = [IO.File]::ReadAllText($path)
Assert ($source -notmatch '(?i)PSAppDeployToolkit|Show-ADT|Open-ADT|Start-ADT') 'silent: no toolkit session or dialog'

# On Windows, one real run first: the real registry primitives, every section, no failures.
if ($env:OS -eq 'Windows_NT') {
    $real = Invoke-EndpointEvidence -Sections 'all' -AppRegex 'Microsoft' -ShortcutRegex '.' -ClickOnceRegex '.' -Paths $env:SystemRoot
    $ro = $real | ConvertFrom-Json
    Assert ([Text.Encoding]::UTF8.GetByteCount($real) -le 8000 -and $ro.status -eq 'collected') 'real run bounded'
    foreach ($k in @('start', 'outlook', 'edge', 'session', 'cis', 'apps', 'intune')) {
        Assert (-not $ro.$k.PSObject.Properties['status']) "real run section $k collected"
    }
    Assert (@($ro.apps.installed).Count -gt 0 -and $ro.apps.paths.PSObject.Properties.Count -eq 1) 'real run reads the uninstall registry'
}

# In-memory registry: path -> values. Subkeys are the direct children of stored paths.
$script:Reg = @{}
function Add-Reg { param([string]$Path, [hashtable]$Values = @{}) $script:Reg[$Path] = $Values }
function Get-EeValues {
    param([string]$Path)
    $r = [ordered]@{}
    if ($script:Reg.ContainsKey($Path)) { foreach ($k in $script:Reg[$Path].Keys) { $r[$k] = $script:Reg[$Path][$k] } }
    return $r
}
function Get-EeSubKeys {
    param([string]$Path)
    $p = $Path + '\'
    return @($script:Reg.Keys | Where-Object { $_.StartsWith($p, [StringComparison]::OrdinalIgnoreCase) } | ForEach-Object { $_.Substring($p.Length).Split('\')[0] } | Sort-Object -Unique)
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('n'))
$script:EeProgramData = Join-Path $tmp 'ProgramData'
$script:EePublic = Join-Path $tmp 'Public'
function New-Dir { param([string]$P) [void][IO.Directory]::CreateDirectory($P); $P }
function New-File { param([string]$P) [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($P)); [IO.File]::WriteAllText($P, 'x') }
try {
    $L = 'HKEY_LOCAL_MACHINE'
    $sid = 'S-1-12-1-111-222-333-444'
    $profileDir = New-Dir (Join-Path $tmp 'Users/alex')
    Add-Reg "HKEY_USERS\$sid"
    Add-Reg 'HKEY_USERS\S-1-5-18'
    Add-Reg "HKEY_USERS\${sid}_Classes"
    Add-Reg "$L\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid" @{ ProfileImagePath = $profileDir }

    $users = @(Get-EeUsers)
    Assert ($users.Count -eq 1 -and $users[0].Name -eq 'alex' -and $users[0].Sid -eq $sid) 'loaded Entra user hive only (no SYSTEM, no _Classes)'

    # Start
    Add-Reg "$L\SOFTWARE\Microsoft\PolicyManager\current\device\Start" @{ ConfigureStartPins = '{"pinnedList":[{"packagedAppId":"Microsoft.WindowsStore_8wekyb3d8bbwe!App"},{"desktopAppLink":"%ALLUSERSPROFILE%\\Microsoft\\Windows\\Start Menu\\Programs\\Outlook (classic).lnk"}]}' }
    New-File (Join-Path $script:EeProgramData 'Microsoft/Windows/Start Menu/Programs/Outlook (classic).lnk')
    New-File (Join-Path $profileDir 'AppData/Roaming/Microsoft/Windows/Start Menu/Programs/Outlook.lnk')
    $start = Get-EeStart
    Assert ($start.devicePolicy.storePinned -and $start.devicePolicy.outlookClassicPinned -and $start.devicePolicy.count -eq 2) 'start pins parsed'
    Assert ($start.devicePolicy.pins -contains 'Outlook (classic).lnk') 'pin shown by leaf name'
    Assert ($null -eq $start.gpoPolicy) 'no GPO start policy'
    Assert ($start.allUsersShortcuts -contains 'Outlook (classic).lnk' -and $start.users[0].shortcuts -contains 'Outlook.lnk') 'outlook start shortcuts'
    Assert ((ConvertFrom-EeStartPins 'not json').status -eq 'invalidJson') 'bad start JSON reported'

    # Outlook
    Add-Reg "HKEY_USERS\$sid\Software\Policies\Microsoft\Office\16.0\Outlook\AutoDiscover" @{ ZeroConfigExchange = 1 }
    Add-Reg "HKEY_USERS\$sid\Software\Policies\Microsoft\Office\16.0\Outlook\Options\General" @{ HideNewOutlookToggle = 1; DisableOutlookMobileHyperlink = 1 }
    Add-Reg "HKEY_USERS\$sid\Software\Policies\Microsoft\Office\16.0\Common\General" @{ ShownFirstRunOptin = 1; ApiToken = 'abc' }
    $ol = Get-EeOutlook
    Assert ($ol.users[0].outlookPolicy['AutoDiscover\ZeroConfigExchange'] -eq 1) 'nested outlook policy read'
    Assert ($ol.users[0].outlookPolicy['Options\General\HideNewOutlookToggle'] -eq 1) 'hide new outlook toggle policy'
    Assert ($ol.users[0].commonPolicy['General\ShownFirstRunOptin'] -eq 1) 'common policy read'
    Assert ($ol.users[0].commonPolicy['General\ApiToken'] -eq '[sensitive value omitted]') 'sensitive policy value omitted'

    # Edge: JSON ExtensionSettings and per-id subkeys both read.
    $id1 = 'a' * 32; $id2 = 'b' * 32
    Add-Reg "$L\SOFTWARE\Policies\Microsoft\Edge" @{ HideFirstRunExperience = 1; RestoreOnStartup = 1; ExtensionSettings = ('{"' + $id1 + '":{"installation_mode":"force_installed","toolbar_state":"force_shown"}}') }
    Add-Reg "$L\SOFTWARE\Policies\Microsoft\Edge\ExtensionSettings\$id2" @{ installation_mode = 'normal_installed' }
    Add-Reg "$L\SOFTWARE\Policies\Microsoft\Edge\ExtensionInstallForcelist" @{ '1' = "$id1;https://edge.microsoft.com/extensionwebstorebase/v1/crx" }
    [void](New-Dir (Join-Path $profileDir "AppData/Local/Microsoft/Edge/User Data/Default/Extensions/$id1"))
    [void](New-Dir (Join-Path $profileDir 'AppData/Local/Microsoft/Edge/User Data/Default/Extensions/Temp'))
    $edge = Get-EeEdge
    Assert ($edge.HideFirstRunExperience -eq 1 -and $null -eq $edge.AutoImportAtFirstRun) 'edge values'
    Assert ($edge.extensionSettings[$id1].mode -eq 'force_installed' -and $edge.extensionSettings[$id1].toolbar -eq 'force_shown') 'edge JSON extension settings'
    Assert ($edge.extensionSettings[$id2].mode -eq 'normal_installed') 'edge subkey extension settings'
    Assert (@($edge.forcelist) -contains $id1) 'forcelist id without update URL'
    Assert (@($edge.users[0].installedExtensions['Default']).Count -eq 1 -and $edge.users[0].installedExtensions['Default'][0] -eq $id1) 'installed extension ids only'

    # Session
    Add-Reg "HKEY_USERS\$sid\Software\Microsoft\Windows NT\CurrentVersion\Winlogon" @{ RestartApps = 0 }
    $session = Get-EeSession
    Assert ($session.users[0].restartApps -eq 0 -and $null -eq $session.users[0].persistBrowsers) 'session restore values'

    # CIS
    $ft = [DateTime]::new(2026, 11, 1, 12, 0, 0, [DateTimeKind]::Utc).ToFileTimeUtc()
    Add-Reg "$L\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" @{ LegalNoticeCaption = 'Authorized use only'; LegalNoticeText = ('t' * 300) }
    Add-Reg "$L\SOFTWARE\Microsoft\Policies\LAPS" @{ BackupDirectory = 1; PasswordAgeDays = 30 }
    Add-Reg "$L\SOFTWARE\Microsoft\Windows\CurrentVersion\LAPS\State" @{ LastPasswordUpdateTime = [int64]$ft }
    Add-Reg "$L\SYSTEM\CurrentControlSet\Control\Terminal Server" @{ fDenyTSConnections = 1 }
    $cis = Get-EeCis
    Assert ($cis.legalNotice.caption -eq 'Authorized use only' -and $cis.legalNotice.textLength -eq 300) 'legal notice caption and length'
    Assert (-not (($cis | ConvertTo-Json -Depth 5) -match 'tttt')) 'legal notice text not printed'
    Assert ($cis.laps.policySource -eq 'csp' -and $cis.laps.passwordAgeDays -eq 30 -and $cis.laps.lastPasswordUpdate -like '2026-11-01T12:00:00*') 'laps policy and last update'
    Assert ($cis.rdp.fDenyTSConnections -eq 1) 'rdp deny'

    # Apps
    Add-Reg "$L\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\{X}" @{ DisplayName = 'Vendor Client 9'; DisplayVersion = '9.1' }
    Add-Reg "$L\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Other" @{ DisplayName = 'Something Else' }
    Add-Reg "HKEY_USERS\$sid\Software\Microsoft\Windows\CurrentVersion\Uninstall\abc" @{ DisplayName = 'Vendor Remote App' }
    New-File (Join-Path $script:EePublic 'Desktop/Vendor Remote.rdp')
    New-File (Join-Path $script:EePublic 'Desktop/Vendor notes.txt')
    New-File (Join-Path $profileDir 'OneDrive - Example/Desktop/Vendor Client.lnk')
    New-File (Join-Path $profileDir 'AppData/Roaming/Microsoft/Windows/Start Menu/Programs/Vendor/Vendor Client.appref-ms')
    [void](New-Dir (Join-Path $profileDir 'AppData/Local/Apps/2.0/AB12/CD34/vend..lient_0123abcd_0009.0001_feedbeef'))
    [void](New-Dir (Join-Path $profileDir 'AppData/Local/Apps/2.0/AB12/CD34/othe..tion_0123abcd_0001.0000_feedbeef'))
    $marker = New-Dir (Join-Path $tmp 'vendordir')
    $apps = Get-EeApps -AppRegex 'Vendor' -ShortcutRegex 'vendor' -ClickOnceRegex '^vend' -Paths "$marker|$(Join-Path $tmp 'missing')"
    Assert (@($apps.installed).Count -eq 2) 'uninstall matches machine32 and user'
    Assert (@($apps.installed | Where-Object { $_.scope -eq 'machine32' -and $_.version -eq '9.1' }).Count -eq 1) 'machine32 entry with version'
    Assert (@($apps.installed | Where-Object { $_.scope -eq 'alex' }).Count -eq 1) 'per-user uninstall entry'
    Assert ($apps.paths[$marker] -eq $true -and $apps.paths[(Join-Path $tmp 'missing')] -eq $false) 'path presence'
    $where = @{}; foreach ($s in $apps.shortcuts) { $where[$s.where] = @($s.names) }
    Assert ($where['publicDesktop'] -contains 'Vendor Remote.rdp' -and -not ($where['publicDesktop'] -contains 'Vendor notes.txt')) 'public desktop shortcut, not other files'
    Assert ($where['alex:oneDriveDesktop'] -contains 'Vendor Client.lnk') 'OneDrive desktop shortcut'
    Assert ($where['alex:startMenu'] -contains 'Vendor Client.appref-ms') 'start menu ClickOnce shortcut (recursive)'
    Assert (@($apps.clickOnce).Count -eq 1 -and @($apps.clickOnce[0].names) -join ',' -eq 'vend..lient') 'ClickOnce folder name'
    $none = Get-EeApps
    Assert (@($none.installed).Count -eq 0 -and @($none.shortcuts).Count -eq 0 -and @($none.clickOnce).Count -eq 0) 'empty regex reports nothing'

    # Intune
    $logs = New-Dir (Join-Path $script:EeProgramData 'Microsoft/IntuneManagementExtension/Logs')
    $log = '<![LOG[[Win32App] Processing app Vendor Client, applicability ok]LOG]!><time="10:01:02.123+300" date="11-15-2026" component="AppWorkload" context="" type="1" thread="1" file="">' + "`r`n" +
    '<![LOG[[Win32App] unrelated line]LOG]!><time="10:01:03.000+300" date="11-15-2026" component="AppWorkload" context="" type="1" thread="1" file="">' + "`r`n" +
    '<![LOG[[Win32App] Vendor Client detection
 result: installed]LOG]!><time="10:02:00.000+300" date="11-15-2026" component="AppWorkload" context="" type="1" thread="1" file="">'
    [IO.File]::WriteAllText((Join-Path $logs 'AppWorkload.log'), $log)
    $appId = [guid]::NewGuid().ToString()
    Add-Reg "$L\SOFTWARE\Microsoft\IntuneManagementExtension\Win32Apps\$sid\${appId}_1" @{ EnforcementStateMessage = '{"EnforcementState":1000,"ErrorCode":0}' }
    $failId = [guid]::NewGuid().ToString()
    Add-Reg "$L\SOFTWARE\Microsoft\IntuneManagementExtension\Win32Apps\00000000-0000-0000-0000-000000000000\${failId}_2" @{ EnforcementStateMessage = '{"EnforcementState":5000,"ErrorCode":-2147024894}' }
    Add-Reg "$L\SOFTWARE\Microsoft\IntuneManagementExtension\Win32Apps\$sid\GRS\x" @{ a = 1 }
    $ime = Get-EeIntune -AppRegex 'Vendor Client'
    Assert ($ime.appWorkloadLastWrite -and $null -eq $ime.imeLogLastWrite) 'log last write times'
    Assert ($ime.win32Apps['1000'] -eq 1 -and $ime.win32Apps['5000'] -eq 1) 'enforcement state counts'
    Assert (@($ime.failed).Count -eq 1 -and $ime.failed[0].app -eq $failId -and $ime.failed[0].errorCode -eq -2147024894) 'failed app listed'
    Assert (@($ime.logMatches).Count -eq 2 -and $ime.logMatches[0] -like '11-15-2026 10:01:02 *Vendor Client*' -and $ime.logMatches[1] -like '*detection  result: installed') 'matching CMTrace lines (multi-line message)'

    # Whole report: one compact line, bounded, section selection, failures isolated.
    $json = Invoke-EndpointEvidence -Sections 'all' -AppRegex 'Vendor' -ShortcutRegex 'vendor' -ClickOnceRegex 'vend' -Paths $marker
    Assert (-not $json.Contains("`n")) 'single line'
    $o = $json | ConvertFrom-Json
    foreach ($k in @('start', 'outlook', 'edge', 'session', 'cis', 'apps', 'intune')) { Assert ($o.PSObject.Properties[$k]) "section $k present" }
    Assert ($o.status -eq 'collected' -and @($o.users) -contains 'alex') 'report header'
    $only = Invoke-EndpointEvidence -Sections 'Cis,Session' | ConvertFrom-Json
    Assert ($only.PSObject.Properties['cis'] -and $only.PSObject.Properties['session'] -and -not $only.PSObject.Properties['edge']) 'section selection'
    $bad = $false; try { [void](Invoke-EndpointEvidence -Sections 'Bogus') } catch { $bad = $true }
    Assert $bad 'unknown section refused'
    $bad = $false; try { [void](Invoke-EndpointEvidence -Sections 'Apps' -AppRegex '(') } catch { $bad = $true }
    Assert $bad 'invalid regex refused'
    function Get-EeSession { throw [InvalidOperationException]::new('boom') }
    $iso = Invoke-EndpointEvidence -Sections 'Session,Cis' | ConvertFrom-Json
    Assert ($iso.session.status -eq 'unavailable' -and $iso.cis.legalNotice.textLength -eq 300) 'a failing section does not stop the others'

    # Output budget.
    for ($i = 0; $i -lt 400; $i++) { Add-Reg "$L\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\n$i" @{ DisplayName = "Vendor Bulk Package Number $i"; DisplayVersion = '1.0.0.0' } }
    $big = Invoke-EndpointEvidence -Sections 'Apps' -AppRegex 'Vendor'
    Assert ([Text.Encoding]::UTF8.GetByteCount($big) -le 8000 -and ($big | ConvertFrom-Json).truncated) 'bounded to 8000 bytes with truncated flag'

    # Time budget: sections after the budget are skipped, not run.
    $script:EeBudgetSeconds = -1
    $late = Invoke-EndpointEvidence -Sections 'Cis' | ConvertFrom-Json
    Assert ($late.cis.status -eq 'skipped') 'time budget skips sections'
} finally {
    [IO.Directory]::Delete($tmp, $true)
}
Write-Output 'endpoint-evidence tests passed'
