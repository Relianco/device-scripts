$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$scriptPath = Join-Path $repoRoot 'windows/packages/app-cleanup/Invoke-AppCleanup.ps1'

function Fail { param([string]$Message) [Console]::Error.WriteLine("FAIL $Message"); exit 1 }
function Assert-Same { param($Actual, $Expected, [string]$Label) if ($Actual -ne $Expected) { Fail "$Label was [$Actual] expected [$Expected]" } }
function Assert-True { param($Value, [string]$Label) if (-not $Value) { Fail $Label } }

$env:RELIAN_DEPLOY_TEST = '1'
Set-StrictMode -Off
. $scriptPath
Set-StrictMode -Version Latest

# Target list: chrome-user is accepted and opt-in; "all" never includes it.
Assert-Same (Get-AcMode -Action 'Install' -Fix 'true' -Target 'chrome-user') 'fix' 'chrome-user is a valid target'
Assert-Same ((Get-AcTargets -Target 'all') -join ',') 'firefox,teams' 'all is firefox and teams only'
Assert-Same ((Get-AcTargets -Target 'chrome-user') -join ',') 'chrome-user' 'chrome-user alone'

# Pure helpers.
Assert-True (Test-AcUnder -Path '"X:\P\u\AppData\Local\Google\Update\GoogleUpdate.exe" /c' -Dir 'x:\p\u\AppData\Local\Google') 'quoted command line under dir'
Assert-True (-not (Test-AcUnder -Path 'X:\P\u\AppData\Local\GoogleX\a.exe' -Dir 'X:\P\u\AppData\Local\Google')) 'sibling prefix is not under'
Assert-Same (@(Get-AcOtherGoogleApps -Ids @('{8A69D345-D564-463C-AFF1-A69D9E530F96}', '{430FD4D0-B729-4F61-AA34-91526481799D}', 'prefs')).Count) 0 'Chrome and updater ids are not other apps'
Assert-Same (@(Get-AcOtherGoogleApps -Ids @('{8A69D345-D564-463C-AFF1-A69D9E530F96}', '{11111111-2222-3333-4444-555555555555}')).Count) 1 'a foreign app id is another app'

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('relian-acc-' + [guid]::NewGuid().ToString('n'))
function New-File { param([string]$Path, [string]$Text = 'x') [void](New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force); Set-Content -LiteralPath $Path -Value $Text }
function New-ChromeUser {
    param([string]$Name)
    $u = Join-Path $tmp $Name
    $g = Join-Path $u 'AppData/Local/Google'
    New-File (Join-Path $g 'Chrome/Application/chrome.exe')
    New-File (Join-Path $g 'Chrome/Application/131.0.1/chrome.dll')
    New-File (Join-Path $g 'Chrome/User Data/Local State')
    New-File (Join-Path $g 'Chrome/User Data/Default/Bookmarks') 'my bookmarks'
    New-File (Join-Path $g 'Chrome/User Data/Default/Preferences')
    New-File (Join-Path $g 'Chrome/User Data/Profile 1/History')
    New-File (Join-Path $g 'GoogleUpdater/updater.exe')
    New-File (Join-Path $g 'Update/GoogleUpdate.exe')
    $app = Join-Path $g 'Chrome/Application/chrome.exe'
    New-File (Join-Path $u 'Desktop/Google Chrome.lnk') $app
    New-File (Join-Path $u 'Desktop/Other.lnk') (Join-Path $u 'tool.exe')
    New-File (Join-Path $u 'AppData/Roaming/Microsoft/Internet Explorer/Quick Launch/User Pinned/TaskBar/Google Chrome.lnk') $app
    $now = Get-AcNow
    (Get-Item -LiteralPath (Join-Path $g 'Chrome/User Data/Local State')).LastWriteTime = $now.AddDays(-40)
    (Get-Item -LiteralPath (Join-Path $g 'Chrome/User Data/Default/Preferences')).LastWriteTime = $now.AddDays(-30)
    (Get-Item -LiteralPath (Join-Path $g 'Chrome/User Data/Profile 1/History')).LastWriteTime = $now.AddDays(-12)
    return $u
}

try {
    # The real Test-AcReparse sees a real symlink (skipped where links need admin).
    $outside = Join-Path $tmp 'outside'
    New-File (Join-Path $outside 'keep.txt')
    $linked = Join-Path $tmp 'tree/sub'
    [void](New-Item -ItemType Directory -Path $linked -Force)
    $made = $true
    try { [void](New-Item -ItemType SymbolicLink -Path (Join-Path $linked 'link') -Target $outside -ErrorAction Stop) } catch { $made = $false }
    if ($made) {
        Assert-True (Find-AcReparseIn -Dir (Join-Path $tmp 'tree')) 'real symlink found inside the tree'
        [IO.Directory]::Delete((Join-Path $linked 'link'))
    }
    Remove-Item -LiteralPath (Join-Path $tmp 'tree') -Recurse -Force
    Remove-Item -LiteralPath $outside -Recurse -Force

    # The real handle-based Remove-AcTree against real junctions (Windows only; junctions need no admin).
    if ($env:OS -eq 'Windows_NT') {
        $prof = Join-Path $tmp 'win\prof'
        $out = Join-Path $tmp 'win\outside'
        $chrome = Join-Path $prof 'AppData\Local\Google\Chrome'
        $app = Join-Path $chrome 'Application'
        New-File (Join-Path $out 'Application\keep.txt')
        New-File (Join-Path $app '131\chrome.dll')
        New-File (Join-Path $app 'chrome.exe')
        New-File (Join-Path $chrome 'User Data\Default\Bookmarks') 'my bookmarks'
        $refused = { param($Path) try { Remove-AcTree -Root $prof -Path $Path; $false } catch { $true } }

        # A junction inside the target: refused, its target untouched.
        $j = Join-Path $app '131\link'
        [void](New-Item -ItemType Junction -Path $j -Target $out)
        Assert-True (& $refused $app) 'junction inside the target is refused'
        Assert-True (Test-Path -LiteralPath (Join-Path $out 'Application\keep.txt')) 'junction target survives'
        [IO.Directory]::Delete($j)

        # An ancestor swapped for a junction: the real location no longer matches, refused.
        Rename-Item -LiteralPath $chrome -NewName 'Chrome.real'
        [void](New-Item -ItemType Junction -Path $chrome -Target $out)
        Assert-True (& $refused $app) 'ancestor junction is refused'
        Assert-True (Test-Path -LiteralPath (Join-Path $out 'Application\keep.txt')) 'files behind the ancestor junction survive'
        [IO.Directory]::Delete($chrome)
        Rename-Item -LiteralPath (Join-Path $prof 'AppData\Local\Google\Chrome.real') -NewName 'Chrome'

        # A plain tree is deleted; User Data beside it survives.
        Assert-True (-not (& $refused $app)) 'plain Application folder is deleted'
        Assert-True (-not (Test-Path -LiteralPath $app)) 'Application folder is gone'
        Assert-Same (Get-Content -LiteralPath (Join-Path $chrome 'User Data\Default\Bookmarks')) 'my bookmarks' 'User Data survives the real delete'
    }

    $fixedNow = Get-Date
    function Get-AcNow { $fixedNow }
    $idle = New-ChromeUser 'idle'
    $busy = New-ChromeUser 'busy'
    $junk = New-ChromeUser 'junk'
    $shared = New-ChromeUser 'shared'
    [void](New-Item -ItemType Directory -Path (Join-Path $tmp 'nochrome') -Force)
    $gIdle = Join-Path $idle 'AppData/Local/Google'

    function Get-AcUserDirs { @(Get-ChildItem -LiteralPath $tmp -Directory | Sort-Object Name) }
    function Get-AcFileVersion { param($Path) '131.0.1' }
    function Get-AcMachineChrome { $null }
    function Get-AcShortcutTarget { param($Path) (Get-Content -LiteralPath $Path -Raw).Trim() }
    function Get-AcRunning { @([pscustomobject]@{ Name = 'chrome.exe'; Path = (Join-Path $busy 'AppData/Local/Google/Chrome/Application/chrome.exe') }) }
    # Fake reparse point: anything under junk's Application\131.0.1 folder.
    function Test-AcReparse { param($Path) ([string]$Path).Replace('\', '/') -like '*/junk/AppData/Local/Google/Chrome/Application/131.0.1*' }
    $script:tasks = @(
        [pscustomobject]@{ Name = 'GoogleUpdaterTaskUser131'; TaskPath = '\'; Exe = (Join-Path $gIdle 'GoogleUpdater/updater.exe') },
        [pscustomobject]@{ Name = 'GoogleUpdaterTaskUserShared'; TaskPath = '\'; Exe = (Join-Path $shared 'AppData/Local/Google/GoogleUpdater/updater.exe') },
        [pscustomobject]@{ Name = 'Other'; TaskPath = '\'; Exe = 'X:\Tools\other.exe' })
    function Get-AcTasks { $script:tasks }
    # The real handle-based delete is tested on Windows above; here it is a plain delete.
    function Remove-AcTree { param($Root, $Path) Remove-Item -LiteralPath $Path -Recurse -Force }
    $script:unregistered = New-Object System.Collections.Generic.List[string]
    function Unregister-AcTask { param($Task) $script:unregistered.Add($Task.Name) }

    # Fake registry: key path -> values. Each user gets a hive root HKU\<name>.
    $script:reg = @{}
    $script:mounted = New-Object System.Collections.Generic.List[string]
    $script:dismounted = New-Object System.Collections.Generic.List[string]
    function Mount-AcHive { param($Dir, $N) $name = Split-Path -Leaf $Dir; $script:mounted.Add($name); @{ Root = "HKU\$name"; Mounted = "RelianAC_$N" } }
    function Dismount-AcHive { param($Name) $script:dismounted.Add($Name) }
    function Get-AcRegValues { param($Path) if ($script:reg.ContainsKey($Path)) { $script:reg[$Path] } else { @{} } }
    function Get-AcRegKeys { param($Path) @($script:reg.Keys | Where-Object { $_.StartsWith("$Path\") } | ForEach-Object { $_.Substring($Path.Length + 1).Split('\')[0] } | Sort-Object -Unique) }
    function Test-AcRegKey { param($Path) @($script:reg.Keys | Where-Object { $_ -eq $Path -or $_.StartsWith("$Path\") }).Count -gt 0 }
    function Remove-AcRegKey { param($Path) foreach ($k in @($script:reg.Keys)) { if ($k -eq $Path -or $k.StartsWith("$Path\")) { $script:reg.Remove($k) } } }
    function Remove-AcRegValue { param($Path, $Name) $script:reg[$Path].Remove($Name) }
    foreach ($n in 'idle', 'shared') {
        $r = "HKU\$n\Software"
        $script:reg["$r\Microsoft\Windows\CurrentVersion\Uninstall\Google Chrome"] = @{ DisplayName = 'Google Chrome' }
        $script:reg["$r\Microsoft\Windows\CurrentVersion\Run"] = @{ GoogleUpdate = ('"' + (Join-Path $tmp "$n/AppData/Local/Google/Update/GoogleUpdate.exe") + '" /c'); OneDrive = 'X:\Tools\onedrive.exe' }
        $script:reg["$r\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe"] = @{ '' = (Join-Path $tmp "$n/AppData/Local/Google/Chrome/Application/chrome.exe") }
        $script:reg["$r\Google\Update\Clients\{8A69D345-D564-463C-AFF1-A69D9E530F96}"] = @{ pv = '131.0.1' }
        $script:reg["$r\Microsoft\Windows\Shell\Associations\UrlAssociations\https\UserChoice"] = @{ ProgId = 'ChromeHTML.ABC' }
    }
    $script:reg['HKU\shared\Software\Google\Update\Clients\{11111111-2222-3333-4444-555555555555}'] = @{ pv = '1.0' }

    # Check mode: report only, nothing touched.
    $r = Invoke-AcChromeUser -Fix $false
    Assert-Same @($r.users).Count 4 'four users with per-user Chrome, nochrome skipped'
    $row = @($r.users | Where-Object { $_.user -eq 'idle' })[0]
    Assert-Same $row.act 'remove' 'idle check action'
    Assert-Same $row.ver '131.0.1' 'version'
    Assert-Same $row.run $false 'idle not running'
    Assert-Same $row.prof 2 'Default and Profile 1 counted'
    Assert-Same $row.days 12 'last used from the newest History/Preferences/Local State'
    Assert-Same ($row.upd -join ',') 'GoogleUpdater,Update' 'both updater folders reported'
    Assert-Same ($row.tasks -join ',') 'GoogleUpdaterTaskUser131' 'own tasks only'
    Assert-Same (@($r.users | Where-Object { $_.user -eq 'busy' })[0].act) 'skip-running' 'busy is skip-running'
    Assert-Same (@($r.users | Where-Object { $_.user -eq 'junk' })[0].act) 'skip-unsafe' 'junk is skip-unsafe'
    Assert-Same $r.failed 0 'check mode never fails'
    Assert-True (Test-Path -LiteralPath (Join-Path $gIdle 'Chrome/Application/chrome.exe')) 'check mode deleted nothing'
    Assert-Same $script:mounted.Count 0 'check mode loads no hive'
    $json = $r | ConvertTo-Json -Depth 6 -Compress
    if ($json -notmatch '"machineChrome":null,"users":\[\{"user":"busy"') { Fail "json shape: $json" }

    # Fix mode.
    $r = Invoke-AcChromeUser -Fix $true
    Assert-Same $r.failed 1 'only the unsafe user is a failure (running is not)'
    $row = @($r.users | Where-Object { $_.user -eq 'idle' })[0]
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $gIdle 'Chrome/Application'))) 'Application folder deleted'
    Assert-Same (Get-Content -LiteralPath (Join-Path $gIdle 'Chrome/User Data/Default/Bookmarks')) 'my bookmarks' 'User Data survives'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $gIdle 'GoogleUpdater'))) 'GoogleUpdater deleted when Chrome is the only app'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $gIdle 'Update'))) 'Update deleted when Chrome is the only app'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $idle 'Desktop/Google Chrome.lnk'))) 'desktop shortcut deleted'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $idle 'AppData/Roaming/Microsoft/Internet Explorer/Quick Launch/User Pinned/TaskBar/Google Chrome.lnk'))) 'taskbar pin deleted'
    Assert-True (Test-Path -LiteralPath (Join-Path $idle 'Desktop/Other.lnk')) 'unrelated shortcut kept'
    Assert-True (-not $script:reg.ContainsKey('HKU\idle\Software\Microsoft\Windows\CurrentVersion\Uninstall\Google Chrome')) 'uninstall key removed'
    Assert-True (-not $script:reg.ContainsKey('HKU\idle\Software\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe')) 'app path removed'
    Assert-True (-not $script:reg.ContainsKey('HKU\idle\Software\Google\Update\Clients\{8A69D345-D564-463C-AFF1-A69D9E530F96}')) 'Software\Google\Update removed with the updater'
    $run = $script:reg['HKU\idle\Software\Microsoft\Windows\CurrentVersion\Run']
    Assert-True (-not $run.ContainsKey('GoogleUpdate')) 'Run value into Google removed'
    Assert-True ($run.ContainsKey('OneDrive')) 'other Run value kept'
    Assert-Same $row.progid $true 'ChromeHTML default reported'
    Assert-True ($script:unregistered -contains 'GoogleUpdaterTaskUser131') 'idle updater task unregistered'
    Assert-True ($script:dismounted.Count -gt 0 -and $script:dismounted.Count -eq $script:mounted.Count) 'every loaded hive unloaded'

    # Another Google app keeps the updater, its task and its registry.
    $gShared = Join-Path $shared 'AppData/Local/Google'
    $row = @($r.users | Where-Object { $_.user -eq 'shared' })[0]
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $gShared 'Chrome/Application'))) 'shared: Application deleted'
    Assert-True (Test-Path -LiteralPath (Join-Path $gShared 'GoogleUpdater/updater.exe')) 'shared: updater kept'
    Assert-True (Test-Path -LiteralPath (Join-Path $gShared 'Update/GoogleUpdate.exe')) 'shared: Update kept'
    Assert-True ($script:reg.ContainsKey('HKU\shared\Software\Google\Update\Clients\{11111111-2222-3333-4444-555555555555}')) 'shared: update key kept'
    Assert-True ($script:reg['HKU\shared\Software\Microsoft\Windows\CurrentVersion\Run'].ContainsKey('GoogleUpdate')) 'shared: updater Run value kept'
    Assert-True ($script:unregistered -notcontains 'GoogleUpdaterTaskUserShared') 'shared: updater task kept'
    if ($row.res -notlike '*kept GoogleUpdater for {11111111-2222-3333-4444-555555555555}*') { Fail "shared res was [$($row.res)]" }

    # Running and unsafe users untouched.
    Assert-True (Test-Path -LiteralPath (Join-Path $busy 'AppData/Local/Google/Chrome/Application/chrome.exe')) 'running Chrome untouched'
    Assert-True (Test-Path -LiteralPath (Join-Path $junk 'AppData/Local/Google/Chrome/Application/chrome.exe')) 'unsafe Chrome untouched'
    Assert-True (Test-Path -LiteralPath (Join-Path $junk 'AppData/Local/Google/Chrome/Application/131.0.1/chrome.dll')) 'nothing deleted beside the reparse point'
    Assert-Same $script:mounted.Count 2 'hives loaded only for removed users'

    # A reparse point on the path above the target (AppData\Local\Google) is caught too.
    function Test-AcReparse { param($Path) ([string]$Path).Replace('\', '/') -like '*/busy/AppData/Local/Google' }
    Assert-True (Find-AcReparseOnPath -Root $busy -Target (Join-Path $busy 'AppData/Local/Google/Chrome/Application')) 'reparse point on the path is found'
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force
}

Write-Host 'PASS app-cleanup-chrome-user'
