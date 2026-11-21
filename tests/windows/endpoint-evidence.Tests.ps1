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
# The one exception: opt-in UserPrt registers a temporary task and writes a temporary script, both removed, in one helper.
$writers = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true) | Where-Object { $_.Body.Extent.Text -match 'RegisterTaskDefinition|WriteAll|::Delete\(' } | ForEach-Object Name)
Assert (($writers -join ',') -eq 'Invoke-EeAsUser') 'only the UserPrt task helper writes'

# Review: an empty pin exits 0 for every action and collects nothing.
foreach ($act in @('Install', 'Bogus')) {
    $out = & pwsh -NoProfile -File $path -Action $act 2>&1
    Assert ($LASTEXITCODE -eq 0 -and (($out | Out-String).Trim()) -eq '{"status":"emptyPin"}') "empty pin exits 0 for $act"
}

# On Windows, real runs first: the real registry primitives, every section, no failures.
# Two runs, as a fleet run would, so neither has to drop a section to fit 8,000 bytes.
if ($env:OS -eq 'Windows_NT') {
    $real = Invoke-EndpointEvidence -Sections 'Start,Outlook,Edge,Session,Cis,Apps,Intune' -AppRegex 'Microsoft' -ShortcutRegex '.' -ClickOnceRegex '.' -Paths $env:SystemRoot
    $ro = $real | ConvertFrom-Json
    Assert ([Text.Encoding]::UTF8.GetByteCount($real) -le 8000 -and $ro.status -eq 'collected') 'real run bounded'
    foreach ($k in @('start', 'outlook', 'edge', 'session', 'cis', 'apps', 'intune')) {
        Assert (-not $ro.$k.PSObject.Properties['status']) "real run section $k collected"
    }
    Assert (@($ro.apps.installed).Count -gt 0 -and @($ro.apps.paths.PSObject.Properties).Count -eq 1) 'real run reads the uninstall registry'
    $managed = Invoke-EndpointEvidence -Sections 'Edition,Taskbar,DefaultApps,QuietWindows,Notifications,Acrobat,EdgeExtras,OneDrive,Drives,Join'
    $mo = $managed | ConvertFrom-Json
    Assert ([Text.Encoding]::UTF8.GetByteCount($managed) -le 8000 -and $mo.status -eq 'collected') 'real managed run bounded'
    foreach ($k in @('edition', 'taskbar', 'defaultapps', 'quietwindows', 'notifications', 'acrobat', 'edgeextras', 'onedrive', 'drives', 'join')) {
        Assert ($mo.PSObject.Properties[$k] -and -not $mo.$k.PSObject.Properties["status"]) "real run section $k collected"
    }
    Assert ($mo.edition.editionId -and $mo.edition.build) 'real run reads the edition'
    $lk = Invoke-EndpointEvidence -Sections 'OfficeLicence,Kfm' | ConvertFrom-Json
    Assert (-not $lk.officelicence.PSObject.Properties['status'] -and -not $lk.kfm.PSObject.Properties['status']) 'real run OfficeLicence and Kfm collected'
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
    Add-Reg "HKEY_USERS\$sid\Software\Policies\Microsoft\Office\16.0\Common\General" @{ ShownFirstRunOptin = 1; ApiToken = [guid]::NewGuid().ToString('n') }
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
    '<![LOG[[Win32App] Vendor Client detection' + "`n" + ' result: installed]LOG]!><time="10:02:00.000+300" date="11-15-2026" component="AppWorkload" context="" type="1" thread="1" file="">'
    [IO.File]::WriteAllText((Join-Path $logs 'AppWorkload.log'), $log)
    $W = "$L\SOFTWARE\Microsoft\IntuneManagementExtension\Win32Apps"
    $zero = '00000000-0000-0000-0000-000000000000'
    function Add-App($Scope, $App, $Enf, $Cmp) {
        if ($Enf) { Add-Reg "$W\$Scope\$App\EnforcementStateMessage" @{ EnforcementStateMessage = $Enf } }
        if ($Cmp) { Add-Reg "$W\$Scope\$App\ComplianceStateMessage" @{ ComplianceStateMessage = $Cmp } }
    }
    $okCmp = '{"Applicability":0,"ComplianceState":1,"DesiredState":2,"ErrorCode":null}'
    $appId = [guid]::NewGuid().ToString()
    Add-App $sid "${appId}_1" '{"EnforcementState":1000,"ErrorCode":0}' $okCmp
    $failId = [guid]::NewGuid().ToString()
    Add-App $zero "${failId}_2" '{"EnforcementState":5000,"ErrorCode":-2147024894}' '{"Applicability":0,"ComplianceState":4,"DesiredState":2,"ErrorCode":null}'
    Add-Reg "$W\$sid\GRS\x" @{ a = 1 }
    # User-scoped apps sit under the user's Entra object id, not a SID; two users hold the same failing app, the newer revision wins.
    $userFail = [guid]::NewGuid().ToString(); $u1 = [guid]::NewGuid().ToString(); $u2 = [guid]::NewGuid().ToString()
    Add-App $u1 "${userFail}_3" '{"EnforcementState":5000,"ErrorCode":1603}' $okCmp
    Add-App $u2 "${userFail}_4" '{"EnforcementState":5000,"ErrorCode":1603}' $okCmp
    # An app only in progress, and one with a compliance message but no enforcement message, are not failures.
    Add-App $u1 "$([guid]::NewGuid())_1" '{"EnforcementState":2000,"ErrorCode":null}' $null
    Add-App $u1 "$([guid]::NewGuid())_1" $null '{"Applicability":1,"ComplianceState":2,"DesiredState":2,"ErrorCode":null}'
    $ime = Get-EeIntune -AppRegex 'Vendor Client'
    Assert ($ime.appWorkloadLastWrite -and $null -eq $ime.imeLogLastWrite) 'log last write times'
    Assert ($ime.win32Apps['Success'] -eq 1 -and $ime.win32Apps['Error'] -eq 2 -and $ime.win32Apps['InProgress'] -eq 1 -and $ime.win32Apps['noStateMessage'] -eq 1 -and -not $ime.win32Apps.Contains('')) 'readable enforcement state counts, one per app'
    Assert (@($ime.failed).Count -eq 2 -and @($ime.failed | Where-Object { $_.app -eq $failId -and $_.errorCode -eq -2147024894 -and $_.compliance -eq 'Error' }).Count -eq 1) 'failed device app listed'
    $uf = @($ime.failed | Where-Object { $_.app -eq $userFail })
    Assert ($uf.Count -eq 1 -and $uf[0].errorCode -eq 1603 -and $uf[0].revision -eq 4 -and $uf[0].userScopes -eq 2) 'failed user app once, latest revision, two scopes'
    Assert (@($ime.logMatches).Count -eq 2 -and $ime.logMatches[0] -like '11-15-2026 10:01:02 *Vendor Client*' -and $ime.logMatches[1] -like '*detection  result: installed') 'matching CMTrace lines (multi-line message)'

    $full = Invoke-EndpointEvidence -Sections 'Session' | ConvertFrom-Json
    Assert (-not $full.PSObject.Properties['noUserHivesLoaded']) 'users present: no noUserHivesLoaded'

    # Edition
    Add-Reg "$L\SOFTWARE\Microsoft\Windows NT\CurrentVersion" @{ EditionID = 'Professional'; CurrentBuildNumber = '26100'; UBR = 4061; DisplayVersion = '24H2'; InstallationType = 'Client' }
    $ed = Get-EeEdition
    Assert ($ed.editionId -eq 'Professional' -and $ed.build -eq '26100' -and $ed.ubr -eq 4061) 'edition and build'

    # Taskbar
    $layout = '<LayoutModificationTemplate><CustomTaskbarLayoutCollection PinListPlacement="Replace"><defaultlayout:TaskbarLayout><taskbar:TaskbarPinList PinGeneration="1"><taskbar:DesktopApp DesktopApplicationID="Microsoft.Windows.Explorer"/><taskbar:DesktopApp DesktopApplicationLinkPath="%APPDATA%\Microsoft\Windows\Start Menu\Programs\Outlook (classic).lnk"/><taskbar:UWA AppUserModelID="MSTeams_8wekyb3d8bbwe!MSTeams"/></taskbar:TaskbarPinList></defaultlayout:TaskbarLayout></CustomTaskbarLayoutCollection></LayoutModificationTemplate>'
    Add-Reg "$L\SOFTWARE\Microsoft\PolicyManager\current\device\Start" @{ ConfigureStartPins = $script:Reg["$L\SOFTWARE\Microsoft\PolicyManager\current\device\Start"]['ConfigureStartPins']; StartLayout = $layout; HideTaskViewButton = 1; HideRecommendedPersonalizedSites = 1; HideRecommendedPersonalizedSites_ProviderSet = 1 }
    New-File (Join-Path $profileDir 'AppData/Roaming/Microsoft/Internet Explorer/Quick Launch/User Pinned/TaskBar/File Explorer.lnk')
    New-File (Join-Path $profileDir 'AppData/Roaming/Microsoft/Internet Explorer/Quick Launch/User Pinned/TaskBar/desktop.ini')
    $tb = Get-EeTaskbar
    Assert ($tb.devicePolicy.taskbar -and $tb.devicePolicy.pinListPlacement -eq 'Replace' -and $tb.devicePolicy.pinGeneration -eq '1') 'taskbar placement and PinGeneration'
    Assert (($tb.devicePolicy.pins -join ',') -eq 'Microsoft.Windows.Explorer,Outlook (classic).lnk,MSTeams_8wekyb3d8bbwe!MSTeams') 'taskbar pins by leaf name or AUMID'
    Assert ($tb.hideTaskViewButton -eq 1 -and $null -eq $tb.users[0].policy) 'task view policy, no user layout'
    Assert ((@($tb.users[0].pinned) -join ',') -eq 'File Explorer.lnk') 'user taskbar pins are shortcut names only'

    # DefaultApps: MDM base64 XML and the user's UserChoice.
    $assoc = '<?xml version="1.0" encoding="UTF-8"?><DefaultAssociations><Association Identifier=".pdf" ProgId="Acrobat.Document.DC" ApplicationName="Adobe Acrobat" /><Association ApplicationName="Edge" ProgId="MSEdgeHTM" Identifier="https" /><Association Identifier=".htm" ProgId="MSEdgeHTM" ApplicationName="Edge" Suggested="true" /></DefaultAssociations>'
    $assocBytes = [Text.Encoding]::UTF8.GetBytes($assoc)
    Add-Reg "$L\SOFTWARE\Microsoft\PolicyManager\current\device\ApplicationDefaults" @{ DefaultAssociationsConfiguration = [Convert]::ToBase64String($assocBytes) }
    $gpoXml = Join-Path $tmp 'assoc.xml'
    [IO.File]::WriteAllBytes($gpoXml, [Text.Encoding]::Unicode.GetPreamble() + [Text.Encoding]::Unicode.GetBytes($assoc))
    Add-Reg "$L\SOFTWARE\Policies\Microsoft\Windows\System" @{ DefaultAssociationsConfiguration = $gpoXml }
    Add-Reg "HKEY_USERS\$sid\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.pdf\UserChoice" @{ ProgId = 'MSEdgePDF'; Hash = 'abc' }
    Add-Reg "HKEY_USERS\$sid\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\http\UserChoiceLatest\ProgId" @{ ProgId = 'MSEdgeHTM' }
    $da = Get-EeDefaultApps
    $sha = [Security.Cryptography.SHA256]::Create(); $want = -join ($sha.ComputeHash($assocBytes)[0..7] | ForEach-Object { $_.ToString('x2') })
    Assert ($da.mdmPolicy.sha256Prefix -eq $want -and $da.mdmPolicy.count -eq 3 -and $da.mdmPolicy.suggested -eq 1) 'default apps policy hash and counts'
    Assert ($da.mdmPolicy.watched['.pdf'] -eq 'Acrobat.Document.DC' -and $da.mdmPolicy.watched['https'] -eq 'MSEdgeHTM' -and -not $da.mdmPolicy.watched.Contains('.htm')) 'watched ProgIds in any attribute order'
    Assert ($da.gpoPolicy.count -eq 3 -and $da.gpoPolicy.path -eq $gpoXml -and $da.gpoPolicy.watched['.pdf'] -eq 'Acrobat.Document.DC') 'GPO file read as UTF-16'
    Assert ($da.users[0]['.pdf'] -eq 'MSEdgePDF' -and $da.users[0]['http'] -eq 'MSEdgeHTM' -and $null -eq $da.users[0]['mailto']) 'user choice and UserChoiceLatest'
    $script:Reg["$L\SOFTWARE\Microsoft\PolicyManager\current\device\ApplicationDefaults"] = @{ DefaultAssociationsConfiguration = '%%%' }
    $script:Reg["$L\SOFTWARE\Policies\Microsoft\Windows\System"] = @{ DefaultAssociationsConfiguration = '\\server\share\assoc.xml' }
    $da = Get-EeDefaultApps
    Assert ($da.mdmPolicy.status -eq 'invalidBase64' -and $da.gpoPolicy.readable -eq $false) 'bad base64 reported; UNC policy file not read'
    # Review: forward-slash and mixed UNC paths are not local either.
    foreach ($unc in @('\\server\s\a.xml', '//server/s/a.xml', '/\server\s\a.xml', '\\?\UNC\server\s\a.xml')) { Assert (-not (Test-EeLocalPath $unc)) "UNC path refused: $unc" }
    Assert ((Test-EeLocalPath $gpoXml) -and (Test-EeLocalPath 'C:\Windows\assoc.xml')) 'local paths allowed'

    # QuietWindows
    Add-Reg "$L\SOFTWARE\Microsoft\PolicyManager\current\device\Experience" @{ AllowWindowsConsumerFeatures = 0; AllowWindowsConsumerFeatures_WinningProvider = 'x' }
    Add-Reg "HKEY_USERS\$sid\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" @{ 'SubscribedContent-338389Enabled' = 0; SystemPaneSuggestionsEnabled = 1; ContentDeliveryAllowed = 1; LastRun = 5 }
    Add-Reg "HKEY_USERS\$sid\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement" @{ ScoobeSystemSettingEnabled = 0 }
    $qw = Get-EeQuietWindows
    Assert ($qw.experiencePolicy['AllowWindowsConsumerFeatures'] -eq 0 -and -not $qw.experiencePolicy.Contains('AllowWindowsConsumerFeatures_WinningProvider')) 'experience policy without bookkeeping values'
    Assert ($qw.startPolicy['HideRecommendedPersonalizedSites'] -eq 1 -and $qw.startPolicy.Count -eq 1) 'recommended section policy only'
    $cd = $qw.users[0].contentDelivery
    Assert ($cd['SubscribedContent-338389Enabled'] -eq 0 -and $cd['ContentDeliveryAllowed'] -eq 1 -and -not $cd.Contains('LastRun')) 'content delivery switches only'
    Assert ($qw.users[0].engagement['ScoobeSystemSettingEnabled'] -eq 0) 'finish-setup switch'

    # Notifications
    Add-Reg "HKEY_USERS\$sid\Software\Microsoft\Windows\CurrentVersion\PushNotifications" @{ ToastEnabled = 1 }
    Add-Reg "HKEY_USERS\$sid\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Microsoft.SkyDrive.Desktop" @{ Enabled = 0 }
    Add-Reg "HKEY_USERS\$sid\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\MSTeams_8wekyb3d8bbwe!MSTeams" @{ ShowInActionCenter = 1 }
    $nt = Get-EeNotifications
    Assert ($nt.users[0].toastEnabled -eq 1 -and $nt.users[0].apps['Microsoft.SkyDrive.Desktop'] -eq 0 -and $nt.users[0].apps.Count -eq 1) 'notification switches set explicitly'

    # Acrobat
    Add-Reg "$L\SOFTWARE\Policies\Adobe\Adobe Acrobat\DC\FeatureLockDown" @{ bToggleFTE = 1; bAcroSuppressUpsell = 1 }
    Add-Reg "$L\SOFTWARE\Policies\Adobe\Adobe Acrobat\DC\FeatureLockDown\cServices" @{ bToggleAdobeDocumentServices = 1 }
    Add-Reg "$L\SOFTWARE\WOW6432Node\Policies\Adobe\Acrobat Reader\DC\FeatureLockDown" @{ bWhatsNewExp = 1 }
    $ac = Get-EeAcrobat
    Assert ($ac['Adobe Acrobat']['bToggleFTE'] -eq 1 -and $ac['Adobe Acrobat']['cServices\bToggleAdobeDocumentServices'] -eq 1) 'acrobat lockdown tree'
    Assert ($ac['Acrobat Reader (wow64)']['bWhatsNewExp'] -eq 1 -and $ac.Count -eq 2) 'reader 32-bit policy labelled'

    # EdgeExtras
    $favJson = '[{"toplevel_name":"Firm links"},{"name":"Court","url":"https://example.org"},{"name":"Folder","children":[{"name":"a","url":"https://example.net"}]}]'
    $script:Reg["$L\SOFTWARE\Policies\Microsoft\Edge"]['ShowMicrosoftRewards'] = 0
    $script:Reg["$L\SOFTWARE\Policies\Microsoft\Edge"]['ForceSync'] = 1
    $script:Reg["$L\SOFTWARE\Policies\Microsoft\Edge"]['ManagedFavorites'] = $favJson
    Add-Reg "$L\SOFTWARE\Policies\Microsoft\Edge\SyncTypesListDisabled" @{ '1' = 'passwords' }
    Add-Reg "$L\SOFTWARE\Policies\Microsoft\Edge\PopupsAllowedForUrls" @{ '1' = '[*.]example.com' }
    Add-Reg "HKEY_USERS\$sid\Software\Policies\Microsoft\Edge" @{ ShowRecommendationsEnabled = 0 }
    $ex = Get-EeEdgeExtras
    Assert ($ex.device['ShowMicrosoftRewards'] -eq 0 -and $ex.device['ForceSync'] -eq 1 -and -not $ex.device.Contains('HideFirstRunExperience')) 'edge extra values only'
    Assert ((@($ex.device['SyncTypesListDisabled']) -join ',') -eq 'passwords') 'sync types list'
    # Review: list policies live in a subkey, not a value on the Edge key.
    Assert ((@($ex.device['PopupsAllowedForUrls']) -join ',') -eq '[*.]example.com') 'popup exceptions list'
    Assert ($ex.device['ManagedFavorites'].count -eq 2 -and $ex.device['ManagedFavorites'].topLevelName -eq 'Firm links') 'managed favorites count and folder'
    Assert (-not (($ex | ConvertTo-Json -Depth 6) -match 'example\.org')) 'favourite URLs not printed'
    Assert ($ex.users[0].policy['ShowRecommendationsEnabled'] -eq 0) 'user-scope edge policy'

    # OneDrive
    $tenant = [guid]::NewGuid().ToString()
    Add-Reg "$L\SOFTWARE\Policies\Microsoft\OneDrive" @{ SilentAccountConfig = 1; KFMSilentOptIn = $tenant; FilesOnDemandEnabled = 1 }
    Add-Reg "HKEY_USERS\$sid\Software\Policies\Microsoft\OneDrive" @{ DisableTutorial = 1 }
    Add-Reg "HKEY_USERS\$sid\Software\Microsoft\OneDrive\Accounts\Business1" @{ ConfiguredTenantId = $tenant; UserEmail = 'alex@example.com'; UserFolder = (Join-Path $profileDir 'OneDrive - Example'); KfmFoldersProtectedNow = 3584 }
    Add-Reg "HKEY_USERS\$sid\Software\Microsoft\OneDrive\Accounts\Personal" @{ UserEmail = 'x@example.net' }
    Add-Reg "HKEY_USERS\$sid\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" @{ Desktop = '%USERPROFILE%\OneDrive - Example\Desktop'; Personal = '%USERPROFILE%\Documents' }
    $od = Get-EeOneDrive
    Assert ($od.devicePolicy['KFMSilentOptIn'] -eq $tenant -and $od.users[0].policy['DisableTutorial'] -eq 1) 'onedrive policies'
    $b1 = $od.users[0].business[0]
    Assert (@($od.users[0].business).Count -eq 1 -and $b1.tenantId -eq $tenant -and $b1.signedIn -and $b1.hasFolder -and $b1.KfmFoldersProtectedNow -eq 3584) 'business account state'
    Assert (-not (($od | ConvertTo-Json -Depth 6) -match '@example')) 'account e-mail not printed'
    Assert ($od.users[0].knownFolders.desktop -eq 'oneDrive' -and $od.users[0].knownFolders.documents -eq 'local' -and $null -eq $od.users[0].knownFolders.pictures) 'known folder redirection'

    # OneDrive R2: hashed identity, tenant match, version, errors, mounted libraries, auto-mount policy.
    $sha = [Security.Cryptography.SHA256]::Create()
    $expectId = (($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes('alex@example.com')) | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 12)
    Assert ($b1.user.domain -eq 'example.com' -and $b1.user.id -eq $expectId -and $b1.tenantMatchesPolicy -eq $true) 'business account hashed identity and tenant match'
    Assert ((Get-EeAddressId '  Alex@Example.COM ').id -eq $expectId) 'address id is trimmed and lowercased'
    Assert ($null -eq (Get-EeAddressId '')) 'no address, no id'
    $acct = "HKEY_USERS\$sid\Software\Microsoft\OneDrive\Accounts\Business1"
    Add-Reg $acct @{ ConfiguredTenantId = [guid]::NewGuid().ToString(); UserEmail = 'alex@example.com'; UserFolder = 'x'; KfmFoldersProtectedNow = 3584; KfmSilentOptInDesktop = 1; FilesOnDemandEnabled = 1; LastSyncError = 'cannot reach bob@example.org'; Unrelated = 'zzz' }
    Add-Reg "HKEY_USERS\$sid\Software\Microsoft\OneDrive" @{ Version = '24.200.1.0001' }
    $mp = "HKEY_USERS\$sid\Software\SyncEngines\Providers\OneDrive"
    Add-Reg "$mp\lib1" @{ UrlNamespace = 'https://example.sharepoint.com/sites/Accounting/Shared Documents?id=secret'; MountPoint = (Join-Path $profileDir 'Example\Accounting - Documents'); LibraryType = 'teamsite' }
    Add-Reg "$mp\lib2" @{ UrlNamespace = 'https://example-my.sharepoint.com/personal/alex_example_com/Documents'; MountPoint = (Join-Path $profileDir 'OneDrive - Example'); LibraryType = 'mysite' }
    Add-Reg "$L\SOFTWARE\Policies\Microsoft\OneDrive\TenantAutoMount" @{ 'carol@example.net' = 'x'; Accounting = 'tenantId=abc&listId={x}&webUrl=https://example.sharepoint.com/sites/Accounting&version=1' }
    Add-Reg "HKEY_USERS\$sid\Software\Policies\Microsoft\OneDrive\TenantAutoMount" @{ Other = 'tenantId=abc&listId={y}' }
    $od = Get-EeOneDrive
    $u0 = $od.users[0]; $b1 = $u0.business[0]
    Assert ($b1.tenantMatchesPolicy -eq $false -and $b1.LastSyncError -eq 'cannot reach [email omitted]' -and $b1.KfmFoldersProtectedNow -eq 3584 -and $b1.KfmSilentOptInDesktop -eq 1 -and $b1.FilesOnDemandEnabled -eq 1 -and -not $b1.Contains('Unrelated')) 'KFM, files on-demand and error values; mismatched tenant; e-mail scrubbed'
    Assert ($u0.version -eq '24.200.1.0001') 'OneDrive version'
    $libs = @{}; foreach ($lib in $u0.libraries) { $libs[$lib.mount] = $lib }
    Assert ($libs['Accounting - Documents'].urlHost -eq 'example.sharepoint.com' -and $libs['Accounting - Documents'].urlPath -eq '/sites/Accounting/Shared Documents' -and $libs['Accounting - Documents'].libraryType -eq 'teamsite') 'mounted library host, path, leaf, type'
    Assert ($libs['OneDrive - Example'].urlPath -eq '/personal/[user]/Documents') 'personal site path hides the user segment'
    Assert ($od.autoMount.device['Accounting'] -like 'tenantId=abc&listId={x}*' -and $u0.autoMount['Other'] -like '*listId={y}') 'TenantAutoMount values, device and user'
    Assert (-not (($od | ConvertTo-Json -Depth 8) -match '@|secret|alex_example')) 'no e-mail, query or user segment in the OneDrive section'
    # Auto-mount view: the account's auto-mount values and whether each mounted library's folder is on disk.
    $script:Reg[$acct]['AutoMountTeamSites'] = 1
    [void](New-Dir (Join-Path $profileDir 'Example\Accounting - Documents'))
    Add-Reg "$mp\lib3" @{ UrlNamespace = 'https://example.sharepoint.com/sites/Gone/Shared Documents'; MountPoint = (Join-Path $profileDir 'Example\Gone - Documents'); LibraryType = 'teamsite' }
    $od = Get-EeOneDrive
    $libs = @{}; foreach ($lib in $od.users[0].libraries) { $libs[$lib.mount] = $lib }
    Assert ($od.users[0].business[0].AutoMountTeamSites -eq 1 -and -not $od.users[0].business[0].Contains('Timerautomount')) 'account auto-mount value'
    Assert ($libs['Accounting - Documents'].exists -eq $true -and $libs['Gone - Documents'].exists -eq $false) 'mounted library folder present or missing'

    # Join: dsregcmd parsed, nltest DC, WorkplaceJoin per user hashed. Natives are stubbed.
    $fakeDevice = [guid]::NewGuid().ToString(); $fakeTenant = [guid]::NewGuid().ToString()
    function Invoke-EeNative {
        param([string]$Name, [string[]]$Arguments)
        if ($Name -eq 'dsregcmd') { return @('+---+', '| Device State', '+---+', '', '             AzureAdJoined : NO', '          EnterpriseJoined : NO', '              DomainJoined : YES', '                DomainName : CORP', "                  DeviceId : $fakeDevice", "              TenantId : $fakeTenant", '        UserEmail : leak@example.com') }
        if ($Name -eq 'nltest') { Assert ($Arguments -contains '/dsgetdc:CORP') 'nltest asks the joined domain'; return @('           DC: \\DC01.corp.local', '      Address: \\10.0.0.5', '     Dom Name: CORP', 'Dc Site Name: Default-First-Site-Name', 'The command completed successfully') }
    }
    Add-Reg "HKEY_USERS\$sid\Software\Microsoft\Windows NT\CurrentVersion\WorkplaceJoin\JoinInfo\ABCDEF" @{ UserEmail = 'alex@example.com'; TenantId = 'tid-1' }
    $j = Get-EeJoin
    Assert ($j.device.AzureAdJoined -eq 'NO' -and $j.device.DomainJoined -eq 'YES' -and $j.device.EnterpriseJoined -eq 'NO' -and $j.device.deviceIdPresent -and $j.device.TenantId -eq $fakeTenant) 'dsregcmd device state parsed'
    Assert ($j.dc.name -eq 'DC01.corp.local' -and $j.dc.site -eq 'Default-First-Site-Name') 'nltest DC name and site'
    Assert ($j.users[0].workplaceJoin[0].user.id -eq $expectId -and $j.users[0].workplaceJoin[0].user.domain -eq 'example.com' -and $j.users[0].workplaceJoin[0].tenantId -eq 'tid-1') 'WorkplaceJoin hashed'
    Assert (-not (($j | ConvertTo-Json -Depth 8) -match ('@|' + $fakeDevice))) 'no e-mail and no device id in the Join section'
    function Invoke-EeNative { param([string]$Name, [string[]]$Arguments) return @('AzureAdJoined : YES', 'DomainJoined : NO') }
    $j2 = Get-EeJoin
    Assert ($j2.device.AzureAdJoined -eq 'YES' -and $j2.dc.status -eq 'notDomainJoined') 'no DomainName: nltest is not run'
    function Invoke-EeNative { param([string]$Name, [string[]]$Arguments) return @('garbage') }
    Assert ((Get-EeJoin).device.status -eq 'unavailable') 'output without device state is unavailable, not notJoined'
    function Invoke-EeNative { param([string]$Name, [string[]]$Arguments) throw 'nope' }
    Assert ((Get-EeJoin).device.status -eq 'unavailable') 'a failing native is reported, not thrown'

    # Drives: mapped drives, drive icons and a network place's target.lnk icon.
    Add-Reg "HKEY_USERS\$sid\Network\F" @{ RemotePath = '\\fs01\files'; ProviderName = 'Microsoft Windows Network' }
    Add-Reg "$L\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\DriveIcons\F\DefaultIcon" @{ '' = 'C:\ProgramData\Icons\f.ico' }
    Add-Reg "$L\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\DriveIcons\F\DefaultLabel" @{ '' = 'Files' }
    Add-Reg "HKEY_USERS\$sid\Software\Classes\Applications\Explorer.exe\Drives\Z\DefaultIcon" @{ '' = 'C:\ProgramData\Icons\z.ico,0' }
    # Minimal MS-SHLLINK: header, an ID list, then Unicode name and icon strings; icon index 3.
    function New-Lnk {
        param([string]$Name, [string]$Icon)
        $h = [byte[]]::new(0x4C)
        [BitConverter]::GetBytes([uint32]0x4C).CopyTo($h, 0)
        [BitConverter]::GetBytes([uint32](0x1 -bor 0x4 -bor 0x40 -bor 0x80)).CopyTo($h, 0x14)
        [BitConverter]::GetBytes([int32]3).CopyTo($h, 0x38)
        $out = [Collections.Generic.List[byte]]::new($h)
        $out.AddRange([byte[]](4, 0, 9, 9, 9, 9))
        foreach ($s in @($Name, $Icon)) { $out.AddRange([BitConverter]::GetBytes([uint16]$s.Length)); $out.AddRange([Text.Encoding]::Unicode.GetBytes($s)) }
        return $out.ToArray()
    }
    $place = Join-Path $profileDir 'AppData/Roaming/Microsoft/Windows/Network Shortcuts/Files (fs01)'
    New-File (Join-Path $place 'desktop.ini')
    [IO.File]::WriteAllBytes((Join-Path $place 'target.lnk'), (New-Lnk 'Files' '%ProgramData%\Icons\f.ico'))
    $bare = Join-Path $profileDir 'AppData/Roaming/Microsoft/Windows/Network Shortcuts/Old'
    New-File (Join-Path $bare 'target.lnk')
    $dr = Get-EeDrives
    Assert ($dr.driveIcons['F'].icon -eq 'C:\ProgramData\Icons\f.ico' -and $dr.driveIcons['F'].label -eq 'Files') 'machine drive icon and label'
    Assert ($dr.users[0].mapped['F'] -eq '\\fs01\files' -and $dr.users[0].driveIcons['Z'] -eq 'C:\ProgramData\Icons\z.ico,0') 'mapped drive and user drive icon'
    $np = @{}; foreach ($p in $dr.users[0].networkPlaces) { $np[$p.name] = $p }
    Assert ($np['Files (fs01)'].icon -eq '%ProgramData%\Icons\f.ico,3' -and $np['Files (fs01)'].desktopIni -and $np['Files (fs01)'].targetLnk) 'network place icon from target.lnk'
    Assert ($np['Old'].icon -eq 'invalidLink' -and -not $np['Old'].desktopIni) 'non-link target reported, not thrown'
    if ($env:OS -eq 'Windows_NT') {
        # A shortcut written by the Windows shell, so the parser is checked against the real format.
        $real = Join-Path $tmp 'real.lnk'
        $ws = New-Object -ComObject WScript.Shell
        $sc = $ws.CreateShortcut($real); $sc.TargetPath = $env:SystemRoot; $sc.IconLocation = 'C:\Windows\System32\imageres.dll,137'; $sc.Save()
        Assert ((Get-EeLnkIcon $real) -eq 'C:\Windows\System32\imageres.dll,137') 'shell-written lnk icon'
    }

    # OfficeLicence: device Click-to-Run licensing, the user's LicensingNext state and licence file fields, addresses hashed.
    Add-Reg "$L\SOFTWARE\Microsoft\Office\ClickToRun\Configuration" @{ ProductReleaseIds = 'O365BusinessRetail'; SharedComputerLicensing = '0'; Platform = 'x64' }
    Add-Reg "HKEY_USERS\$sid\Software\Microsoft\Office\16.0\Common\Licensing\LicensingNext" @{ o365businessretail = 2; LastKnownUser = 'alex@example.com' }
    $inner = '{"ProductReleaseId":"O365BusinessRetail","LicenseType":"User","ExpiresOn":"2026-12-31T00:00:00Z","Email":"alex@example.com","Metadata":{"LicenseCategory":"Subscription","Notes":"skip me"},"Blob":"' + ('A' * 300) + '"}'
    $licFile = '{"Version":1,"License":"' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($inner)) + '","Signature":"' + ('B' * 300) + '"}'
    $licDir = New-Dir (Join-Path $profileDir 'AppData/Local/Microsoft/Office/Licenses/5')
    [IO.File]::WriteAllText((Join-Path $licDir 'lic1'), $licFile, [Text.Encoding]::Unicode)
    [IO.File]::WriteAllText((Join-Path $licDir 'broken'), 'not json')
    $ol = Get-EeOfficeLicence
    Assert ($ol.device.ProductReleaseIds -eq 'O365BusinessRetail' -and $ol.device.SharedComputerLicensing -eq '0') 'click-to-run licensing values'
    Assert ($ol.users[0].user -eq 'alex' -and $ol.users[0].licensingNext['o365businessretail'] -eq 2 -and $ol.users[0].licensingNext['LastKnownUser'] -eq '[email omitted]') 'LicensingNext state, address scrubbed'
    $files = @{}; foreach ($f in $ol.users[0].files) { $files[$f.name] = $f }
    $lf = $files['lic1'].fields
    Assert ($lf['License.ProductReleaseId'] -eq 'O365BusinessRetail' -and $lf['License.LicenseType'] -eq 'User' -and $lf['License.ExpiresOn'] -like '2026-12-31*' -and $lf['License.Metadata.LicenseCategory'] -eq 'Subscription') 'licence file fields from the decoded License blob'
    Assert ($lf['License.Email'].id -eq $expectId -and $lf['License.Email'].domain -eq 'example.com') 'licence e-mail hashed'
    Assert (-not $lf.Contains('License.Blob') -and -not $lf.Contains('Signature') -and -not $lf.Contains('License.Metadata.Notes')) 'blobs and other fields left out'
    Assert ($files['broken'].status -eq 'unreadable') 'unreadable licence file reported, not thrown'
    Assert (-not (($ol | ConvertTo-Json -Depth 8) -match '@')) 'no e-mail in the OfficeLicence section'

    # Kfm: shell folder targets, OneDrive KFM state, and a bounded walk of the local folders with move blockers.
    Add-Reg "HKEY_USERS\$sid\Software\Microsoft\OneDrive" @{ Version = '24.200.1.0001'; SilentBusinessConfigCompleted = 1; KfmBlockOptOut = 0 }
    Add-Reg "HKEY_USERS\$sid\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" @{ Desktop = '%USERPROFILE%\OneDrive - Example\Desktop'; Personal = "$profileDir\Documents"; 'My Pictures' = '\\fs01\home\alex\Pictures'; Favorites = 'x' }
    $desk = New-Dir (Join-Path $profileDir 'Desktop')
    foreach ($n in @('mail.pst', 'notes.one', 'Open Notebook.onetoc2', '_vti_x.txt', 'CON.txt', 'Contract.docx', 'desktop.ini', '~$draft.docx')) { New-File (Join-Path $desk $n) }
    $deep = New-Dir (Join-Path $desk 'Sub')
    $long = Join-Path $deep ('n' * [Math]::Max(1, 252 - $deep.Length))
    New-File $long
    $kfm = Get-EeKfm
    $k0 = $kfm.users[0]
    Assert ($k0.user -eq 'alex' -and $k0.oneDrive['SilentBusinessConfigCompleted'] -eq 1 -and $k0.oneDrive['KfmBlockOptOut'] -eq 0 -and -not $k0.oneDrive.Contains('Version')) 'OneDrive KFM and silent config values'
    Assert ($k0.shellFolders['Desktop'] -eq '%USERPROFILE%\OneDrive - Example\Desktop' -and $k0.shellFolders['Personal'] -eq '%USERPROFILE%\Documents' -and $k0.shellFolders['My Pictures'] -like '\\fs01*' -and -not $k0.shellFolders.Contains('Favorites')) 'shell folder targets, profile path shortened'
    $fd = @{}; foreach ($f in $k0.folders) { $fd[$f.folder] = $f }
    $d = $fd['Desktop']
    Assert ($d.exists -and $d.files -eq 9 -and $d.pst -eq 1 -and $d.oneNote -eq 2 -and $d.badName -eq 3 -and $d.longPath -eq 1 -and $d.complete) 'desktop counts and blockers'
    Assert ($fd['Documents'].exists -eq $false -and $null -eq $fd['Documents']['files']) 'missing folder not walked'
    $script:EeKfmMaxEntries = 3
    $cut = (Get-EeKfm).users[0].folders[0]
    Assert ($cut.complete -eq $false -and $cut.files -le 3) 'walk stops at the entry cap'
    $script:EeKfmMaxEntries = 50000
    Assert (-not (($kfm | ConvertTo-Json -Depth 8) -match ('@|' + [regex]::Escape($profileDir)))) 'no e-mail or profile path in the Kfm section'

    # UserPrt: the user's own dsregcmd through a fake Task Scheduler; the task and both files are always removed.
    $userState = @('| User State', '                    NgcSet : NO', '           WorkplaceJoined : NO', '             WamDefaultSet : YES', '| SSO State', '                AzureAdPrt : YES',
        '      AzureAdPrtUpdateTime : 2026-11-20 14:01:02.000 UTC', '      AzureAdPrtExpiryTime : 2026-12-04 14:01:01.000 UTC', '       AzureAdPrtAuthority : https://login.microsoftonline.com/x',
        '             EnterprisePrt : NO', '| Diagnostic Data', '    Executing Account Name : AzureAD\AlexExample, alex@example.com')
    $script:Sched = @{ registered = @(); deleted = @(); defs = @(); mode = 'ok' }
    function Get-EeTaskService {
        $svc = [pscustomobject]@{}
        $svc | Add-Member ScriptMethod NewTask {
            param($f)
            $d = [pscustomobject]@{ Settings = [pscustomobject]@{ Hidden = $false; ExecutionTimeLimit = $null; DisallowStartIfOnBatteries = $true; StopIfGoingOnBatteries = $true }
                Principal = [pscustomobject]@{ UserId = $null; LogonType = $null; RunLevel = $null }; Actions = [pscustomobject]@{ Items = @() } }
            $d.Actions | Add-Member ScriptMethod Create { param($t) $a = [pscustomobject]@{ Path = $null; Arguments = $null }; $this.Items += $a; $a }
            $script:Sched.defs += $d
            $d
        }
        $svc | Add-Member ScriptMethod GetFolder {
            param($p)
            $folder = [pscustomobject]@{}
            $folder | Add-Member ScriptMethod RegisterTaskDefinition {
                param($name, $def, $flags, $user, $pw, $logon)
                $script:Sched.registered += $name
                $t = [pscustomobject]@{ State = 3; Def = $def }
                $t | Add-Member ScriptMethod Run {
                    param($x)
                    if ($script:Sched.mode -eq 'throw') { throw 'run failed' }
                    if ($script:Sched.mode -ne 'ok') { return }
                    $vbsPath = [regex]::Match($this.Def.Actions.Items[0].Arguments, '"(.+)"').Groups[1].Value
                    $outPath = [regex]::Match([IO.File]::ReadAllText($vbsPath), '> ""(.+?)""').Groups[1].Value
                    [IO.File]::WriteAllLines($outPath, [string[]]$userState)
                }
                $t | Add-Member ScriptMethod Stop { param($x) }
                $t
            }
            $folder | Add-Member ScriptMethod DeleteTask { param($n, $x) $script:Sched.deleted += $n }
            $folder
        }
        $svc
    }
    function Get-EeSessionSids { @($sid) }
    $userTemp = New-Dir (Join-Path $profileDir 'AppData/Local/Temp')
    $up = Get-EeUserPrt
    $p0 = $up.users[0]
    Assert ($p0.user -eq 'alex' -and $p0.AzureAdPrt -eq 'YES' -and $p0.AzureAdPrtUpdateTime -eq '2026-11-20 14:01:02.000 UTC' -and $p0.AzureAdPrtExpiryTime -like '2026-12-04*' -and $p0.WorkplaceJoined -eq 'NO' -and $p0.EnterprisePrt -eq 'NO') 'user PRT state parsed'
    Assert ($p0.account.id -eq $expectId -and $p0.account.domain -eq 'example.com') 'executing account hashed'
    Assert (-not (($up | ConvertTo-Json -Depth 8) -match '@|AlexExample|login\.microsoftonline')) 'no e-mail, account name or authority in the UserPrt section'
    $def = $script:Sched.defs[0]
    Assert ($def.Settings.Hidden -and $def.Settings.ExecutionTimeLimit -eq 'PT1M' -and $def.Principal.LogonType -eq 3 -and $def.Principal.RunLevel -eq 0 -and $def.Actions.Items[0].Path -like '*wscript.exe') 'hidden, time-limited, least-privilege interactive task'
    Assert ($script:Sched.registered.Count -eq 1 -and $script:Sched.registered[0] -like 'Relian-EndpointEvidence-*' -and ($script:Sched.deleted -join ',') -eq ($script:Sched.registered -join ',')) 'task registered once and removed'
    Assert (@(Get-ChildItem -LiteralPath $userTemp -Force).Count -eq 0) 'temporary script and output removed'
    [void](Get-EeUserPrt)
    Assert ($script:Sched.registered.Count -eq 2 -and $script:Sched.registered[0] -ne $script:Sched.registered[1]) 'unique task name per run'
    $script:Sched.mode = 'throw'
    $failed = Get-EeUserPrt
    Assert ($failed.users[0].status -eq 'unavailable' -and $script:Sched.deleted.Count -eq 3 -and @(Get-ChildItem -LiteralPath $userTemp -Force).Count -eq 0) 'a failed run still removes the task and files'
    $script:Sched.mode = 'silent'; $script:EeUserPrtSeconds = 1
    $slow = Get-EeUserPrt
    Assert ($slow.users[0].error -eq 'timeout' -and $script:Sched.deleted.Count -eq 4 -and @(Get-ChildItem -LiteralPath $userTemp -Force).Count -eq 0) 'a task that never writes times out and is removed'
    $script:EeUserPrtSeconds = 30
    function Get-EeSessionSids { @() }
    $away = Get-EeUserPrt
    Assert ($away.users[0].status -eq 'notSignedIn' -and $script:Sched.registered.Count -eq 4) 'no task for a user without a desktop session'

    # Whole report: one compact line, bounded, section selection, failures isolated.
    $json = Invoke-EndpointEvidence -Sections 'all' -AppRegex 'Vendor' -ShortcutRegex 'vendor' -ClickOnceRegex 'vend' -Paths $marker
    Assert (-not $json.Contains("`n")) 'single line'
    $o = $json | ConvertFrom-Json
    foreach ($k in @($script:EeSectionNames | Where-Object { $script:EeOptInSections -notcontains $_ } | ForEach-Object { $_.ToLowerInvariant() })) { Assert ($o.PSObject.Properties[$k]) "section $k present" }
    Assert (-not $o.PSObject.Properties['userprt'] -and $script:EeOptInSections -contains 'UserPrt') 'UserPrt is opt-in, not in all'
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

    # Review: a dictionary too large for the budget, with no list to cut, drops that section instead of failing.
    $manyPaths = (0..300 | ForEach-Object { Join-Path $tmp "no-such-path-number-$_" }) -join '|'
    $dict = Invoke-EndpointEvidence -Sections 'Apps,Cis' -Paths $manyPaths
    $do = $dict | ConvertFrom-Json
    Assert ([Text.Encoding]::UTF8.GetByteCount($dict) -le 8000 -and $do.truncated -and $do.apps.status -eq 'omitted' -and $do.cis.legalNotice.textLength -eq 300) 'oversized dictionary section omitted, others kept'

    # Time budget: sections after the budget are skipped, not run.
    $script:EeBudgetSeconds = -1
    $late = Invoke-EndpointEvidence -Sections 'Cis' | ConvertFrom-Json
    Assert ($late.cis.status -eq 'skipped') 'time budget skips sections'
    # Nobody signed in: the report says why the per-user sections are empty.
    function Get-EeUsers { @() }
    $script:EeBudgetSeconds = 90
    $nobody = Invoke-EndpointEvidence -Sections 'Session' | ConvertFrom-Json
    Assert ($nobody.noUserHivesLoaded -eq $true -and @($nobody.users).Count -eq 0) 'noUserHivesLoaded when no hive is loaded'
} finally {
    [IO.Directory]::Delete($tmp, $true)
}
Write-Output 'endpoint-evidence tests passed'
