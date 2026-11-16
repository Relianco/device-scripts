<#
.SYNOPSIS
    Read-only endpoint evidence: the device and signed-in user state that Intune
    or a script was meant to set.
.DESCRIPTION
    Runs through the Relian deploy runner (NinjaOne script 374) as SYSTEM, Windows
    PowerShell 5.1. Silent: it loads no toolkit and shows no dialog or toast. Prints
    one line of JSON, at most 8,000 UTF-8 bytes, with "truncated" set when a list
    was cut. New sections stop starting after 90 seconds.

    Package arguments (base64 JSON in -PackageArguments):
      Sections        "all" (default) or a comma list of Start, Outlook, Edge,
                      Session, Cis, Apps, Intune, Edition, Taskbar, DefaultApps,
                      QuietWindows, Notifications, Acrobat, EdgeExtras, OneDrive, Drives
      AppRegex        uninstall DisplayName and Intune log lines to report (Apps, Intune)
      ShortcutRegex   .lnk/.rdp/.appref-ms names on desktops and Start Menus (Apps)
      ClickOnceRegex  ClickOnce folders under each user's AppData\Local\Apps\2.0 (Apps)
      Paths           "|"-separated file or folder paths whose presence to report (Apps)

    Per-user state comes from hives loaded under HKEY_USERS (signed-in users) and
    their profile folders. No hive is loaded. Each section is one Get-Ee<Name>
    function that returns a hashtable; add a section by adding one function.
    Nothing is changed: no registry, file, service, policy refresh or custom field.
    Files are read by name only, except a local DefaultAssociations XML (hashed
    and counted) and Network Shortcuts target.lnk files (icon location only).
#>
[CmdletBinding()]
param(
    [string]$DeploymentType,
    [string]$Action,
    [string]$PinVersion,
    [string]$Sections = 'all',
    [string]$AppRegex = '',
    [string]$ShortcutRegex = '',
    [string]$ClickOnceRegex = '',
    [string]$Paths = ''
)
$ProgressPreference = 'SilentlyContinue'

$script:EeSectionNames = @('Start', 'Outlook', 'Edge', 'Session', 'Cis', 'Apps', 'Intune', 'Edition', 'Taskbar', 'DefaultApps',
    'QuietWindows', 'Notifications', 'Acrobat', 'EdgeExtras', 'OneDrive', 'Drives')
$script:EeWatchedTypes = @('.pdf', 'http', 'https', 'mailto')
$script:EeProgramData = $env:ProgramData
$script:EePublic = $env:PUBLIC
$script:EeBudgetSeconds = 90
$script:EeClock = [Diagnostics.Stopwatch]::StartNew()
$HKLM = 'HKEY_LOCAL_MACHINE'

function Protect-EeText {
    param([AllowEmptyString()][string]$Text, [int]$Max = 160)
    if ($Text -match '(?i)password|secret|token|credential|bearer|api.?key') { return '[sensitive value omitted]' }
    $t = ($Text -replace '[\x00-\x1F]', ' ').Trim()
    if ($t.Length -gt $Max) { return $t.Substring(0, $Max) + '[clipped]' }
    return $t
}

# Registry primitives. Tests replace these two functions with an in-memory store.
function Get-EeValues {
    param([string]$Path)
    $r = [ordered]@{}
    $key = Get-Item -LiteralPath ('Registry::' + $Path) -ErrorAction SilentlyContinue
    if (-not $key) { return $r }
    foreach ($n in $key.GetValueNames()) { $r[$n] = $key.GetValue($n, $null, 'DoNotExpandEnvironmentNames') }
    return $r
}
function Get-EeSubKeys {
    param([string]$Path)
    $key = Get-Item -LiteralPath ('Registry::' + $Path) -ErrorAction SilentlyContinue
    if (-not $key) { return @() }
    return @($key.GetSubKeyNames())
}

function ConvertTo-EeValue {
    param($Value, [int]$Max = 160)
    if ($Value -is [string]) { return Protect-EeText $Value -Max $Max }
    if ($Value -is [byte[]]) { return "$($Value.Length) bytes" }
    if ($Value -is [array]) { return Protect-EeText (($Value | ForEach-Object { [string]$_ }) -join '|') -Max $Max }
    return $Value
}

# Values of a key and its subkeys as "sub\name" = value; at most $Max entries.
function Get-EeTree {
    param([string]$Path, [int]$Max = 40, [string]$Prefix = '', $Out)
    if ($null -eq $Out) { $Out = [ordered]@{} }
    $values = Get-EeValues $Path
    foreach ($n in @($values.Keys)) {
        if ($Out.Count -ge $Max) { $Out['_truncated'] = $true; return $Out }
        $label = $n; if (-not $label) { $label = '(default)' }
        $value = '[sensitive value omitted]'
        if ((Protect-EeText $label) -ne $value) { $value = ConvertTo-EeValue $values[$n] }
        $Out[$Prefix + $label] = $value
    }
    foreach ($s in @(Get-EeSubKeys $Path)) {
        [void](Get-EeTree -Path "$Path\$s" -Max $Max -Prefix "$Prefix$s\" -Out $Out)
    }
    return $Out
}

function Get-EeValue { param([string]$Path, [string]$Name) $v = Get-EeValues $Path; if ($v.Contains($Name)) { return $v[$Name] } return $null }

# Users with a loaded hive (signed in, or loaded by a service). Entra users are S-1-12-1.
function Get-EeUsers {
    foreach ($sid in @(Get-EeSubKeys 'HKEY_USERS' | Where-Object { $_ -match '^S-1-(5-21|12-1)-[\d-]+$' })) {
        $profilePath = [string](Get-EeValue "$HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid" 'ProfileImagePath')
        if ($profilePath) { $profilePath = [Environment]::ExpandEnvironmentVariables($profilePath) }
        $name = $sid
        if ($profilePath) { $name = Split-Path -Leaf $profilePath }
        [pscustomobject]@{ Sid = $sid; Name = $name; Profile = $profilePath; Hive = "HKEY_USERS\$sid" }
    }
}

function Test-EeDir { param([string]$Path) return ($Path -and [IO.Directory]::Exists($Path)) }
# Not a UNC path in any slash form (\\server, //server, \/server, \\?\UNC).
function Test-EeLocalPath { param([string]$Path) return ($Path -and $Path -notmatch '^[\\/]{2}') }

function Get-EeFileNames {
    param([string]$Dir, [string]$Regex, [switch]$Recurse)
    if (-not $Regex -or -not (Test-EeDir $Dir)) { return @() }
    $files = @(Get-ChildItem -LiteralPath $Dir -File -Recurse:$Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Extension -match '^\.(lnk|rdp|appref-ms)$' })
    return @($files | Where-Object { $_.BaseName -match $Regex } | ForEach-Object { $_.Name } | Sort-Object -Unique)
}

# shortcut: start2.bin is opaque, so "pinned" comes from the policy JSON and Start Menu shortcuts.
function ConvertFrom-EeStartPins {
    param([AllowEmptyString()][string]$Json)
    if (-not $Json) { return $null }
    try { $p = $Json | ConvertFrom-Json } catch { return [ordered]@{ status = 'invalidJson'; length = $Json.Length } }
    $pins = @()
    if ($p.PSObject.Properties['pinnedList']) {
        $pins = @($p.pinnedList | ForEach-Object { foreach ($prop in $_.PSObject.Properties) { [string]$prop.Value } })
    }
    $text = $pins -join '|'
    return [ordered]@{
        count = $pins.Count
        storePinned = ($text -match '(?i)Microsoft\.WindowsStore')
        outlookClassicPinned = ($text -match '(?i)Outlook \(classic\)|\\Outlook\.lnk|OUTLOOK\.EXE')
        newOutlookPinned = ($text -match '(?i)Microsoft\.OutlookForWindows')
        pins = @($pins | ForEach-Object { Protect-EeText ($_ -replace '^.*\\', '') -Max 60 })
    }
}

function Get-EeStart {
    $pm = "$HKLM\SOFTWARE\Microsoft\PolicyManager\current"
    $r = [ordered]@{
        devicePolicy = ConvertFrom-EeStartPins ([string](Get-EeValue "$pm\device\Start" 'ConfigureStartPins'))
        gpoPolicy = ConvertFrom-EeStartPins ([string](Get-EeValue "$HKLM\SOFTWARE\Policies\Microsoft\Windows\Explorer" 'ConfigureStartPins'))
        allUsersShortcuts = @()
        users = @()
    }
    $names = '^Outlook( \(classic\)| \(new\))?$'
    $r.allUsersShortcuts = @(Get-EeFileNames (Join-Path $script:EeProgramData 'Microsoft\Windows\Start Menu\Programs') $names)
    foreach ($u in @(Get-EeUsers)) {
        $row = [ordered]@{ user = $u.Name; policy = ConvertFrom-EeStartPins ([string](Get-EeValue "$pm\$($u.Sid)\Start" 'ConfigureStartPins')); shortcuts = @() }
        if ($u.Profile) { $row.shortcuts = @(Get-EeFileNames (Join-Path $u.Profile 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs') $names) }
        $r.users += $row
    }
    return $r
}

function Get-EeOutlook {
    $users = @()
    foreach ($u in @(Get-EeUsers)) {
        $users += [ordered]@{
            user = $u.Name
            outlookPolicy = Get-EeTree "$($u.Hive)\Software\Policies\Microsoft\Office\16.0\Outlook"
            commonPolicy = Get-EeTree "$($u.Hive)\Software\Policies\Microsoft\Office\16.0\Common"
            useNewOutlook = Get-EeValue "$($u.Hive)\Software\Microsoft\Office\16.0\Outlook\Preferences" 'UseNewOutlook'
            hideNewOutlookToggle = Get-EeValue "$($u.Hive)\Software\Microsoft\Office\16.0\Outlook\Options\General" 'HideNewOutlookToggle'
        }
    }
    return [ordered]@{ users = $users }
}

function Get-EeEdge {
    $edge = "$HKLM\SOFTWARE\Policies\Microsoft\Edge"
    $values = Get-EeValues $edge
    $r = [ordered]@{ policyValueCount = $values.Count }
    foreach ($n in @('HideFirstRunExperience', 'AutoImportAtFirstRun', 'NonMicrosoftAccountSignInEnabled', 'RestoreOnStartup', 'ExtensionManifestV2Availability')) {
        $r[$n] = $null; if ($values.Contains($n)) { $r[$n] = ConvertTo-EeValue $values[$n] }
    }
    # ExtensionSettings is either one JSON string value or one subkey per extension id.
    $settings = [ordered]@{}
    if ($values.Contains('ExtensionSettings')) {
        try {
            $json = [string]$values['ExtensionSettings'] | ConvertFrom-Json
            foreach ($p in $json.PSObject.Properties) {
                $mode = $null; $bar = $null
                if ($p.Value.PSObject.Properties['installation_mode']) { $mode = [string]$p.Value.installation_mode }
                if ($p.Value.PSObject.Properties['toolbar_state']) { $bar = [string]$p.Value.toolbar_state }
                $settings[$p.Name] = [ordered]@{ mode = $mode; toolbar = $bar }
            }
        } catch { $settings['_error'] = 'invalidJson' }
    }
    foreach ($id in @(Get-EeSubKeys "$edge\ExtensionSettings")) {
        $v = Get-EeValues "$edge\ExtensionSettings\$id"
        $settings[$id] = [ordered]@{ mode = $v['installation_mode']; toolbar = $v['toolbar_state'] }
    }
    $r.extensionSettings = $settings
    $force = Get-EeValues "$edge\ExtensionInstallForcelist"
    $r.forcelist = @($force.Values | ForEach-Object { ([string]$_ -split ';')[0] })
    $r.users = @()
    foreach ($u in @(Get-EeUsers)) {
        if (-not $u.Profile) { continue }
        $root = Join-Path $u.Profile 'AppData\Local\Microsoft\Edge\User Data'
        if ( -not (Test-EeDir $root)) { continue }
        $profiles = [ordered]@{}
        foreach ($d in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(Default|Profile \d+)$' })) {
            $ext = Join-Path $d.FullName 'Extensions'
            $profiles[$d.Name] = @()
            if (Test-EeDir $ext) { $profiles[$d.Name] = @(Get-ChildItem -LiteralPath $ext -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^[a-p]{32}$' } | ForEach-Object Name) }
        }
        $r.users += [ordered]@{ user = $u.Name; installedExtensions = $profiles }
    }
    return $r
}

function Get-EeSession {
    $users = @()
    foreach ($u in @(Get-EeUsers)) {
        $users += [ordered]@{
            user = $u.Name
            restartApps = Get-EeValue "$($u.Hive)\Software\Microsoft\Windows NT\CurrentVersion\Winlogon" 'RestartApps'
            persistBrowsers = Get-EeValue "$($u.Hive)\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" 'PersistBrowsers'
        }
    }
    return [ordered]@{ users = $users }
}

function ConvertFrom-EeFileTime {
    param($Value)
    if ($null -eq $Value) { return $null }
    try { return [DateTime]::FromFileTimeUtc([int64]$Value).ToString('o') } catch { return [string]$Value }
}

function Get-EeCis {
    $sys = Get-EeValues "$HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
    $caption = [string]$sys['LegalNoticeCaption']; $text = [string]$sys['LegalNoticeText']
    $lapsCsp = Get-EeValues "$HKLM\SOFTWARE\Microsoft\Policies\LAPS"
    $lapsGpo = Get-EeValues "$HKLM\SOFTWARE\Policies\Microsoft Windows\LAPS"
    $state = Get-EeValues "$HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\LAPS\State"
    $policy = $lapsCsp; $source = 'csp'
    if ($lapsCsp.Count -eq 0) { $policy = $lapsGpo; $source = 'gpo' }
    if ($policy.Count -eq 0) { $source = $null }
    return [ordered]@{
        legalNotice = [ordered]@{ caption = (Protect-EeText $caption -Max 80); textLength = $text.Length }
        laps = [ordered]@{
            policySource = $source
            backupDirectory = $policy['BackupDirectory']
            passwordAgeDays = $policy['PasswordAgeDays']
            lastPasswordUpdate = ConvertFrom-EeFileTime $state['LastPasswordUpdateTime']
        }
        rdp = [ordered]@{
            fDenyTSConnections = Get-EeValue "$HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server" 'fDenyTSConnections'
            policyDeny = Get-EeValue "$HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services" 'fDenyTSConnections'
        }
    }
}

function Get-EeApps {
    param([string]$AppRegex, [string]$ShortcutRegex, [string]$ClickOnceRegex, [string]$Paths)
    $r = [ordered]@{ installed = @(); paths = [ordered]@{}; shortcuts = @(); clickOnce = @() }
    $users = @(Get-EeUsers)
    if ($AppRegex) {
        $roots = @(
            @{ scope = 'machine'; path = "$HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall" }
            @{ scope = 'machine32'; path = "$HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall" }
        ) + @($users | ForEach-Object { @{ scope = $_.Name; path = "$($_.Hive)\Software\Microsoft\Windows\CurrentVersion\Uninstall" } })
        foreach ($root in $roots) {
            foreach ($k in @(Get-EeSubKeys $root.path)) {
                $v = Get-EeValues "$($root.path)\$k"
                $name = [string]$v['DisplayName']
                if ($name -and $name -match $AppRegex) { $r.installed += [ordered]@{ name = (Protect-EeText $name -Max 80); version = [string]$v['DisplayVersion']; scope = $root.scope } }
            }
        }
    }
    foreach ($p in @($Paths -split '\|' | Where-Object { $_.Trim() })) { $r.paths[$p.Trim()] = Test-Path -LiteralPath $p.Trim() }
    if ($ShortcutRegex) {
        $dirs = @(
            @{ where = 'publicDesktop'; dir = (Join-Path $script:EePublic 'Desktop'); recurse = $false }
            @{ where = 'allUsersStartMenu'; dir = (Join-Path $script:EeProgramData 'Microsoft\Windows\Start Menu\Programs'); recurse = $true }
        )
        foreach ($u in @($users | Where-Object { $_.Profile })) {
            $dirs += @{ where = "$($u.Name):desktop"; dir = (Join-Path $u.Profile 'Desktop'); recurse = $false }
            $dirs += @{ where = "$($u.Name):startMenu"; dir = (Join-Path $u.Profile 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs'); recurse = $true }
            if (Test-EeDir $u.Profile) {
                foreach ($od in @(Get-ChildItem -LiteralPath $u.Profile -Directory -Filter 'OneDrive*' -ErrorAction SilentlyContinue)) {
                    $dirs += @{ where = "$($u.Name):oneDriveDesktop"; dir = (Join-Path $od.FullName 'Desktop'); recurse = $false }
                }
            }
        }
        foreach ($d in $dirs) {
            $names = @(Get-EeFileNames $d.dir $ShortcutRegex -Recurse:$d.recurse)
            if ($names.Count) { $r.shortcuts += [ordered]@{ where = $d.where; names = @($names | ForEach-Object { Protect-EeText $_ -Max 80 }) } }
        }
    }
    if ($ClickOnceRegex) {
        foreach ($u in @($users | Where-Object { $_.Profile })) {
            $apps = Join-Path $u.Profile 'AppData\Local\Apps\2.0'
            if (-not (Test-EeDir $apps)) { continue }
            # Apps\2.0\<random>\<random>\<app folder>; the folder name starts with a shortened app name.
            $names = @(Get-ChildItem -LiteralPath $apps -Directory -ErrorAction SilentlyContinue | ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Directory -ErrorAction SilentlyContinue } |
                    ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Directory -ErrorAction SilentlyContinue } |
                    Where-Object { $_.Name -match $ClickOnceRegex } | ForEach-Object { ($_.Name -split '_')[0] } | Sort-Object -Unique)
            if ($names.Count) { $r.clickOnce += [ordered]@{ user = $u.Name; names = $names } }
        }
    }
    return $r
}

# Last $MaxBytes of a log file, shared read so a running writer is not blocked.
function Read-EeTail {
    param([string]$Path, [int]$MaxBytes = 2097152)
    $s = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try {
        $start = [Math]::Max(0L, $s.Length - $MaxBytes)
        [void]$s.Seek($start, [IO.SeekOrigin]::Begin)
        $buf = [byte[]]::new([int]($s.Length - $start))
        $n = $s.Read($buf, 0, $buf.Length)
        return [Text.Encoding]::UTF8.GetString($buf, 0, $n)
    } finally { $s.Dispose() }
}

# CMTrace lines: <![LOG[message]LOG]!><time="hh:mm:ss.fff+zzz" date="M-d-yyyy" ...>
function Select-EeLogLines {
    param([AllowEmptyString()][string]$Text, [string]$Regex, [int]$Max = 8)
    $out = @()
    foreach ($m in [regex]::Matches($Text, '<!\[LOG\[(.*?)\]LOG\]!><time="([\d:.]+)[^"]*" date="([\d-]+)"', 'Singleline')) {
        if ($m.Groups[1].Value -match $Regex) { $out += ($m.Groups[3].Value + ' ' + $m.Groups[2].Value.Split('.')[0] + ' ' + (Protect-EeText $m.Groups[1].Value -Max 200)) }
    }
    return @($out | Select-Object -Last $Max)
}

function Get-EeIntune {
    param([string]$AppRegex)
    $logs = Join-Path $script:EeProgramData 'Microsoft\IntuneManagementExtension\Logs'
    $r = [ordered]@{ imeLogLastWrite = $null; appWorkloadLastWrite = $null; win32Apps = [ordered]@{}; failed = @(); logMatches = @() }
    foreach ($pair in @(@('imeLogLastWrite', 'IntuneManagementExtension.log'), @('appWorkloadLastWrite', 'AppWorkload.log'))) {
        $f = Join-Path $logs $pair[1]
        if ([IO.File]::Exists($f)) { $r[$pair[0]] = [IO.File]::GetLastWriteTimeUtc($f).ToString('o') }
    }
    # Win32Apps\<user Entra object id, or the zero GUID for device>\<appId>_<revision> holds EnforcementStateMessage JSON.
    $w = "$HKLM\SOFTWARE\Microsoft\IntuneManagementExtension\Win32Apps"
    $states = @{}
    foreach ($sid in @(Get-EeSubKeys $w | Where-Object { $_ -match '^(S-1-[\d-]+|[0-9a-fA-F]{8}-[0-9a-fA-F-]{27})$' })) {
        foreach ($app in @(Get-EeSubKeys "$w\$sid" | Where-Object { $_ -match '^[0-9a-f-]{36}_\d+$' })) {
            $msg = [string](Get-EeValue "$w\$sid\$app" 'EnforcementStateMessage')
            $state = 'unknown'; $code = $null
            try { $j = $msg | ConvertFrom-Json; $state = [string]$j.EnforcementState; $code = $j.ErrorCode } catch { }
            $states[$state] = 1 + [int]$states[$state]
            if ($state -ne '1000' -and $state -ne 'unknown') { $r.failed += [ordered]@{ app = ($app -split '_')[0]; state = $state; errorCode = $code } }
        }
    }
    foreach ($k in @($states.Keys | Sort-Object)) { $r.win32Apps[$k] = $states[$k] }
    if ($AppRegex) {
        foreach ($name in @('AppWorkload.log', 'IntuneManagementExtension.log')) {
            $f = Join-Path $logs $name
            if (-not [IO.File]::Exists($f)) { continue }
            $lines = @(Select-EeLogLines (Read-EeTail $f) $AppRegex)
            if ($lines.Count) { $r.logMatches = $lines; $r.logFile = $name; break }
        }
    }
    return $r
}

# Policy values without the PolicyManager bookkeeping names (X_ProviderSet, X_WinningProvider, X_LastWrite).
function Get-EePolicy {
    param([string]$Path, [string[]]$Names)
    $values = Get-EeValues $Path
    $r = [ordered]@{}
    foreach ($n in @($values.Keys)) {
        if ($n -match '_(ProviderSet|WinningProvider|LastWrite|ADMXInstanceData)$') { continue }
        if ($Names -and $Names -notcontains $n) { continue }
        $r[$n] = ConvertTo-EeValue $values[$n]
    }
    return $r
}

function Get-EeEdition {
    $v = Get-EeValues "$HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion"
    return [ordered]@{ editionId = $v['EditionID']; installationType = $v['InstallationType']; displayVersion = $v['DisplayVersion']; build = $v['CurrentBuildNumber']; ubr = $v['UBR'] }
}

# Taskbar part of a StartLayout XML: placement, PinGeneration and pin names (link leaf or AUMID).
function ConvertFrom-EeTaskbarLayout {
    param([AllowEmptyString()][string]$Xml)
    if (-not $Xml) { return $null }
    $r = [ordered]@{ length = $Xml.Length; taskbar = ($Xml -match '(?i)TaskbarPinList'); pinListPlacement = $null; pinGeneration = $null; pins = @() }
    if ($Xml -match '(?i)PinListPlacement\s*=\s*"([^"]*)"') { $r.pinListPlacement = $Matches[1] }
    if ($Xml -match '(?i)PinGeneration\s*=\s*"([^"]*)"') { $r.pinGeneration = $Matches[1] }
    foreach ($m in [regex]::Matches($Xml, '(?i)(DesktopApplicationLinkPath|DesktopApplicationID|AppUserModelID)\s*=\s*"([^"]*)"')) {
        $r.pins += Protect-EeText ($m.Groups[2].Value -replace '^.*\\', '') -Max 60
    }
    return $r
}

function Get-EeTaskbar {
    $pm = "$HKLM\SOFTWARE\Microsoft\PolicyManager\current"
    $r = [ordered]@{
        devicePolicy = ConvertFrom-EeTaskbarLayout ([string](Get-EeValue "$pm\device\Start" 'StartLayout'))
        gpoPolicy = Get-EePolicy "$HKLM\SOFTWARE\Policies\Microsoft\Windows\Explorer" @('LockedStartLayout', 'StartLayoutFile')
        hideTaskViewButton = Get-EeValue "$pm\device\Start" 'HideTaskViewButton'
        users = @()
    }
    foreach ($u in @(Get-EeUsers)) {
        $row = [ordered]@{ user = $u.Name; policy = ConvertFrom-EeTaskbarLayout ([string](Get-EeValue "$pm\$($u.Sid)\Start" 'StartLayout')); pinned = @() }
        if ($u.Profile) { $row.pinned = @(Get-EeFileNames (Join-Path $u.Profile 'AppData\Roaming\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar') '.' | ForEach-Object { Protect-EeText $_ -Max 60 }) }
        $r.users += $row
    }
    return $r
}

# DefaultAssociationsConfiguration: the MDM value is base64 XML, the GPO value is a file path.
function ConvertFrom-EeAssociations {
    param([byte[]]$Bytes)
    $text = [Text.Encoding]::UTF8.GetString($Bytes)
    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) { $text = [Text.Encoding]::Unicode.GetString($Bytes) }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = -join ($sha.ComputeHash($Bytes)[0..7] | ForEach-Object { $_.ToString('x2') }) } finally { $sha.Dispose() }
    $r = [ordered]@{ sha256Prefix = $hash; count = 0; suggested = 0; watched = [ordered]@{} }
    foreach ($m in [regex]::Matches($text, '(?i)<Association\b[^>]*>')) {
        $r.count++
        $tag = $m.Value
        if ($tag -match '(?i)\bSuggested\s*=\s*"true"') { $r.suggested++ }
        if ($tag -match '(?i)\bIdentifier\s*=\s*"([^"]*)"' -and $script:EeWatchedTypes -contains $Matches[1].ToLowerInvariant()) {
            $id = $Matches[1].ToLowerInvariant()
            if ($tag -match '(?i)\bProgId\s*=\s*"([^"]*)"') { $r.watched[$id] = Protect-EeText $Matches[1] -Max 60 }
        }
    }
    return $r
}

function Get-EeDefaultApps {
    $r = [ordered]@{ mdmPolicy = $null; gpoPolicy = $null; users = @() }
    $b64 = [string](Get-EeValue "$HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\ApplicationDefaults" 'DefaultAssociationsConfiguration')
    if ($b64) {
        try { $r.mdmPolicy = ConvertFrom-EeAssociations ([Convert]::FromBase64String($b64)) } catch { $r.mdmPolicy = [ordered]@{ status = 'invalidBase64'; length = $b64.Length } }
    }
    $file = [string](Get-EeValue "$HKLM\SOFTWARE\Policies\Microsoft\Windows\System" 'DefaultAssociationsConfiguration')
    if ($file) {
        $r.gpoPolicy = [ordered]@{ path = Protect-EeText $file -Max 120; readable = $false }
        # A UNC path (\\, // or mixed) can stall under SYSTEM, so only a local file is read.
        if ((Test-EeLocalPath $file) -and [IO.File]::Exists($file) -and [IO.FileInfo]::new($file).Length -lt 1MB) {
            $r.gpoPolicy = ConvertFrom-EeAssociations ([IO.File]::ReadAllBytes($file))
            $r.gpoPolicy.path = Protect-EeText $file -Max 120
        }
    }
    foreach ($u in @(Get-EeUsers)) {
        $row = [ordered]@{ user = $u.Name }
        foreach ($t in $script:EeWatchedTypes) {
            $base = "$($u.Hive)\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\$t"
            if ($t.StartsWith('.')) { $base = "$($u.Hive)\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\$t" }
            $progId = Get-EeValue "$base\UserChoice" 'ProgId'
            # Newer builds also write UserChoiceLatest; report it when UserChoice has none.
            if (-not $progId) { $latest = Get-EeTree "$base\UserChoiceLatest" -Max 6; foreach ($k in @($latest.Keys)) { if ($k -match '(^|\\)ProgId$' -and $latest[$k]) { $progId = $latest[$k] } } }
            $row[$t] = $progId
        }
        $r.users += $row
    }
    return $r
}

function Get-EeQuietWindows {
    $pm = "$HKLM\SOFTWARE\Microsoft\PolicyManager\current"
    $r = [ordered]@{
        experiencePolicy = Get-EePolicy "$pm\device\Experience"
        cloudContentGpo = Get-EePolicy "$HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent"
        startPolicy = Get-EePolicy "$pm\device\Start" @('HideRecommendedPersonalizedSites', 'HideRecommendedSection')
        users = @()
    }
    foreach ($u in @(Get-EeUsers)) {
        $cdm = [ordered]@{}
        $values = Get-EeValues "$($u.Hive)\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
        foreach ($n in @($values.Keys | Where-Object { $_ -match '(Enabled|Allowed)$' } | Sort-Object)) { $cdm[$n] = ConvertTo-EeValue $values[$n] }
        $r.users += [ordered]@{
            user = $u.Name
            contentDelivery = $cdm
            engagement = Get-EePolicy "$($u.Hive)\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement"
            experiencePolicy = Get-EePolicy "$pm\$($u.Sid)\Experience"
            cloudContentGpo = Get-EePolicy "$($u.Hive)\Software\Policies\Microsoft\Windows\CloudContent"
        }
    }
    return $r
}

function Get-EeNotifications {
    $users = @()
    foreach ($u in @(Get-EeUsers)) {
        $apps = [ordered]@{}
        $settings = "$($u.Hive)\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings"
        # Only apps with an explicit Enabled value; an absent value means on.
        foreach ($k in @(Get-EeSubKeys $settings)) { $e = Get-EeValue "$settings\$k" 'Enabled'; if ($null -ne $e) { $apps[(Protect-EeText $k -Max 80)] = $e } }
        $users += [ordered]@{ user = $u.Name; toastEnabled = Get-EeValue "$($u.Hive)\Software\Microsoft\Windows\CurrentVersion\PushNotifications" 'ToastEnabled'; apps = $apps }
    }
    return [ordered]@{ users = $users }
}

function Get-EeAcrobat {
    $r = [ordered]@{}
    foreach ($product in @('Adobe Acrobat', 'Acrobat Reader')) {
        foreach ($root in @('SOFTWARE', 'SOFTWARE\WOW6432Node')) {
            $p = "$HKLM\$root\Policies\Adobe\$product\DC\FeatureLockDown"
            $t = Get-EeTree $p -Max 30
            $label = $product; if ($root -like '*WOW6432Node') { $label += ' (wow64)' }
            if ($t.Count) { $r[$label] = $t }
        }
    }
    return $r
}

$script:EeEdgeExtraNames = @('ShowPDFDefaultRecommendationsEnabled', 'ShowRecommendationsEnabled', 'DefaultBrowserSettingsCampaignEnabled', 'ShowMicrosoftRewards',
    'EdgeShoppingAssistantEnabled', 'NewTabPageContentEnabled', 'SpotlightExperiencesAndRecommendationsEnabled', 'WhatsNewPageForEntraProfilesEnabled',
    'DefaultPopupsSetting', 'ForceSync', 'SyncDisabled', 'BrowserSignin', 'OrganizationalBrandingOnWorkProfileUIEnabled', 'OrganizationLogoOverlayOnAppIconEnabled')

function Get-EeEdgeScope {
    param([string]$Path)
    $r = Get-EePolicy $Path $script:EeEdgeExtraNames
    # List policies keep one numbered value per entry in a subkey of the same name.
    foreach ($list in @('SyncTypesListDisabled', 'PopupsAllowedForUrls', 'PopupsBlockedForUrls')) {
        $v = Get-EeValues "$Path\$list"
        if ($v.Count) { $r[$list] = @($v.Values | ForEach-Object { [string]$_ }) }
    }
    $fav = [string](Get-EeValue $Path 'ManagedFavorites')
    if ($fav) {
        # Names only: favourites URLs are firm links, so only the count and folder name are shown.
        try {
            # Assigned first: Windows PowerShell 5.1 emits a JSON array as one pipeline item.
            $parsed = $fav | ConvertFrom-Json
            $items = @($parsed)
            $top = @($items | Where-Object { $_.PSObject.Properties['toplevel_name'] } | ForEach-Object { [string]$_.toplevel_name })
            $r['ManagedFavorites'] = [ordered]@{ count = @($items | Where-Object { $_.PSObject.Properties['url'] -or $_.PSObject.Properties['children'] }).Count; topLevelName = $null }
            if ($top.Count) { $r['ManagedFavorites'].topLevelName = Protect-EeText $top[0] -Max 60 }
        } catch { $r['ManagedFavorites'] = [ordered]@{ status = 'invalidJson'; length = $fav.Length } }
    }
    return $r
}

function Get-EeEdgeExtras {
    $r = [ordered]@{ device = Get-EeEdgeScope "$HKLM\SOFTWARE\Policies\Microsoft\Edge"; users = @() }
    foreach ($u in @(Get-EeUsers)) {
        $p = Get-EeEdgeScope "$($u.Hive)\Software\Policies\Microsoft\Edge"
        if ($p.Count) { $r.users += [ordered]@{ user = $u.Name; policy = $p } }
    }
    return $r
}

function Get-EeOneDrive {
    $r = [ordered]@{ devicePolicy = Get-EeTree "$HKLM\SOFTWARE\Policies\Microsoft\OneDrive" -Max 30; users = @() }
    foreach ($u in @(Get-EeUsers)) {
        $accounts = "$($u.Hive)\Software\Microsoft\OneDrive\Accounts"
        $business = @()
        foreach ($k in @(Get-EeSubKeys $accounts | Where-Object { $_ -match '^Business\d+$' })) {
            $v = Get-EeValues "$accounts\$k"
            # The account e-mail and folder path are personal, so only their presence is shown.
            $row = [ordered]@{ account = $k; tenantId = $v['ConfiguredTenantId']; signedIn = [bool]$v['UserEmail']; hasFolder = [bool]$v['UserFolder'] }
            foreach ($n in @($v.Keys | Where-Object { $_ -match '^(Kfm|FilesOnDemand|Timerautomount)' })) { $row[$n] = ConvertTo-EeValue $v[$n] }
            $business += $row
        }
        $folders = [ordered]@{}
        $shell = Get-EeValues "$($u.Hive)\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"
        foreach ($pair in @(@('desktop', 'Desktop'), @('documents', 'Personal'), @('pictures', 'My Pictures'))) {
            $where = $null
            if ($shell.Contains($pair[1])) { $where = 'local'; if ([string]$shell[$pair[1]] -match '(?i)\\OneDrive') { $where = 'oneDrive' } }
            $folders[$pair[0]] = $where
        }
        $r.users += [ordered]@{ user = $u.Name; policy = Get-EeTree "$($u.Hive)\Software\Policies\Microsoft\OneDrive" -Max 20; business = $business; knownFolders = $folders }
    }
    return $r
}

# IconLocation from a .lnk (MS-SHLLINK StringData), read without COM. $null when the link has none.
function Get-EeLnkIcon {
    param([string]$Path)
    $b = [IO.File]::ReadAllBytes($Path)
    if ($b.Length -lt 0x4C -or [BitConverter]::ToUInt32($b, 0) -ne 0x4C) { return 'invalidLink' }
    $flags = [BitConverter]::ToUInt32($b, 0x14)
    $pos = 0x4C
    if ($flags -band 0x1) { $pos += 2 + [BitConverter]::ToUInt16($b, $pos) }
    if ($flags -band 0x2) { $pos += [BitConverter]::ToUInt32($b, $pos) }
    $unicode = [bool]($flags -band 0x80)
    $index = [BitConverter]::ToInt32($b, 0x38)
    # StringData order: name 0x4, relative path 0x8, working dir 0x10, arguments 0x20, icon 0x40.
    foreach ($bit in @(0x4, 0x8, 0x10, 0x20, 0x40)) {
        if (-not ($flags -band $bit)) { continue }
        if ($pos + 2 -gt $b.Length) { return 'invalidLink' }
        $chars = [BitConverter]::ToUInt16($b, $pos); $pos += 2
        $len = $chars; if ($unicode) { $len = $chars * 2 }
        if ($pos + $len -gt $b.Length) { return 'invalidLink' }
        if ($bit -eq 0x40) {
            $text = if ($unicode) { [Text.Encoding]::Unicode.GetString($b, $pos, $len) } else { [Text.Encoding]::Default.GetString($b, $pos, $len) }
            return (Protect-EeText "$text,$index" -Max 160)
        }
        $pos += $len
    }
    return $null
}

function Get-EeDrives {
    $icons = [ordered]@{}
    $di = "$HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\DriveIcons"
    foreach ($l in @(Get-EeSubKeys $di)) {
        $icons[$l] = [ordered]@{ icon = ConvertTo-EeValue (Get-EeValue "$di\$l\DefaultIcon" ''); label = ConvertTo-EeValue (Get-EeValue "$di\$l\DefaultLabel" '') }
    }
    $users = @()
    foreach ($u in @(Get-EeUsers)) {
        $mapped = [ordered]@{}
        foreach ($l in @(Get-EeSubKeys "$($u.Hive)\Network")) { $mapped[$l] = ConvertTo-EeValue (Get-EeValue "$($u.Hive)\Network\$l" 'RemotePath') }
        $userIcons = [ordered]@{}
        $ud = "$($u.Hive)\Software\Classes\Applications\Explorer.exe\Drives"
        foreach ($l in @(Get-EeSubKeys $ud)) { $userIcons[$l] = ConvertTo-EeValue (Get-EeValue "$ud\$l\DefaultIcon" '') }
        $places = @()
        $ns = if ($u.Profile) { Join-Path $u.Profile 'AppData\Roaming\Microsoft\Windows\Network Shortcuts' } else { $null }
        if (Test-EeDir $ns) {
            foreach ($d in @(Get-ChildItem -LiteralPath $ns -Directory -ErrorAction SilentlyContinue)) {
                $lnk = Join-Path $d.FullName 'target.lnk'
                $icon = $null
                if ([IO.File]::Exists($lnk)) { try { $icon = Get-EeLnkIcon $lnk } catch { $icon = 'unreadable' } }
                $places += [ordered]@{ name = Protect-EeText $d.Name -Max 80; targetLnk = [IO.File]::Exists($lnk); desktopIni = [IO.File]::Exists((Join-Path $d.FullName 'desktop.ini')); icon = $icon }
            }
        }
        $users += [ordered]@{ user = $u.Name; mapped = $mapped; driveIcons = $userIcons; networkPlaces = $places }
    }
    return [ordered]@{ driveIcons = $icons; users = $users }
}

function Find-EeLargestArray {
    param($Value)
    $best = $null
    if ($Value -is [Collections.IDictionary]) {
        foreach ($k in @($Value.Keys)) {
            $item = $Value[$k]
            if ($item -is [array] -and $item.Count -gt 0 -and ($null -eq $best -or $item.Count -gt $best.Count)) { $best = @{ Container = $Value; Key = $k; Count = $item.Count } }
            $inner = Find-EeLargestArray $item
            if ($inner -and ($null -eq $best -or $inner.Count -gt $best.Count)) { $best = $inner }
        }
    } elseif ($Value -is [array]) {
        foreach ($item in $Value) {
            $inner = Find-EeLargestArray $item
            if ($inner -and ($null -eq $best -or $inner.Count -gt $best.Count)) { $best = $inner }
        }
    }
    return $best
}

# Drops entries from the longest list until the JSON fits, and says so with "truncated".
function ConvertTo-EeBoundedJson {
    param($Report, [int]$MaxBytes = 8000)
    $json = $Report | ConvertTo-Json -Depth 8 -Compress
    while ([Text.Encoding]::UTF8.GetByteCount($json) -gt $MaxBytes) {
        $Report['truncated'] = $true
        $largest = Find-EeLargestArray $Report
        if (-not $largest) {
            # No list left to cut: a large dictionary (paths, policy trees) remains, so drop the biggest section.
            $big = $null; $bigSize = 0
            foreach ($k in @($script:EeSectionNames | ForEach-Object { $_.ToLowerInvariant() } | Where-Object { $Report.Contains($_) })) {
                $size = ($Report[$k] | ConvertTo-Json -Depth 8 -Compress).Length
                if ($size -gt $bigSize) { $big = $k; $bigSize = $size }
            }
            if (-not $big) { throw 'Report exceeds the output budget.' }
            $Report[$big] = [ordered]@{ status = 'omitted'; reason = 'outputBudget'; bytes = $bigSize }
            $json = $Report | ConvertTo-Json -Depth 8 -Compress
            continue
        }
        $keep = $largest.Count - [Math]::Max(1, [int][Math]::Ceiling($largest.Count / 8))
        $largest.Container[$largest.Key] = @($largest.Container[$largest.Key] | Select-Object -First $keep)
        $json = $Report | ConvertTo-Json -Depth 8 -Compress
    }
    return $json
}

function Invoke-EndpointEvidence {
    param([string]$Sections = 'all', [string]$AppRegex = '', [string]$ShortcutRegex = '', [string]$ClickOnceRegex = '', [string]$Paths = '')
    $wanted = @($Sections -split '[,|\s]+' | Where-Object { $_ })
    if (-not $wanted.Count -or ($wanted.Count -eq 1 -and $wanted[0] -eq 'all')) { $wanted = $script:EeSectionNames }
    foreach ($s in $wanted) { if ($script:EeSectionNames -notcontains $s) { throw "Unknown section $s." } }
    foreach ($rx in @($AppRegex, $ShortcutRegex, $ClickOnceRegex)) { [void][regex]::new($rx) }
    $report = [ordered]@{ version = '2'; timestamp = [datetime]::UtcNow.ToString('o'); status = 'collected'; users = @(Get-EeUsers | ForEach-Object Name) }
    foreach ($s in $script:EeSectionNames) {
        if ($wanted -notcontains $s) { continue }
        $key = $s.ToLowerInvariant()
        if ($script:EeClock.Elapsed.TotalSeconds -gt $script:EeBudgetSeconds) { $report[$key] = @{ status = 'skipped'; reason = 'timeBudget' }; continue }
        try {
            switch ($s) {
                'Apps' { $report[$key] = Get-EeApps -AppRegex $AppRegex -ShortcutRegex $ShortcutRegex -ClickOnceRegex $ClickOnceRegex -Paths $Paths }
                'Intune' { $report[$key] = Get-EeIntune -AppRegex $AppRegex }
                default { $report[$key] = & "Get-Ee$s" }
            }
        } catch { $report[$key] = @{ status = 'unavailable'; error = $_.Exception.GetType().Name } }
    }
    $report.elapsedSeconds = [Math]::Round($script:EeClock.Elapsed.TotalSeconds, 1)
    return ConvertTo-EeBoundedJson $report
}

if ($env:RELIAN_DEPLOY_TEST -eq '1' -and $MyInvocation.InvocationName -eq '.') { return }
# Repo rule: an empty pin exits 0 for every action before any work.
if ([string]::IsNullOrWhiteSpace($PinVersion)) { Write-Output '{"status":"emptyPin"}'; exit 0 }
if ($Action -eq 'Uninstall') { Write-Output '{"status":"nothingToUninstall"}'; exit 0 }
if (@('Install', 'Update', 'Repair', 'Reinstall') -notcontains $Action) { [Console]::Error.WriteLine('Unsupported action.'); exit 1 }
try { Write-Output (Invoke-EndpointEvidence -Sections $Sections -AppRegex $AppRegex -ShortcutRegex $ShortcutRegex -ClickOnceRegex $ClickOnceRegex -Paths $Paths); exit 0 }
catch { Write-Output ('{"status":"failed","error":"' + $_.Exception.GetType().Name + '"}'); exit 1 }
