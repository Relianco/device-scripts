$ErrorActionPreference = 'Stop'
$env:RELIAN_DEPLOY_TEST = '1'
. (Join-Path $PSScriptRoot '../../windows/packages/storage-maintenance/Invoke-StorageMaintenance.ps1')
function Assert($Condition, $Message) { if (-not $Condition) { throw $Message } }
function Throws($Code) { try { & $Code; return $false } catch { return $true } }

# Arguments: a tier needs Cleanup, implies component cleanup, and never implies profile removal.
$a = Get-SmArguments
Assert ($a.Tier -eq 'None' -and -not $a.ComponentCleanup -and $a.CleanupSeconds -eq 600) 'Default is no tier'
$a = Get-SmArguments -Mode Cleanup -Tier Safe
Assert ($a.Tier -eq 'Safe' -and $a.ComponentCleanup -and -not $a.RemoveProfiles) 'Safe tier adds component cleanup and no profile removal'
Assert (Throws { Get-SmArguments -Mode Report -Tier Safe }) 'A tier in Report mode is refused'
Assert (Throws { Get-SmArguments -Mode Cleanup -Tier safe }) 'Tier is case-sensitive'
Assert (Throws { Get-SmArguments -Mode Cleanup -Tier Safe -CleanupSeconds 10 }) 'CleanupSeconds below 60 is refused'

$root = Join-Path ([IO.Path]::GetTempPath()) ('smt-' + [guid]::NewGuid().ToString('n'))
$null = New-Item -ItemType Directory $root
function New-File($Path, [int]$AgeDays) {
    $null = New-Item -ItemType Directory -Force (Split-Path -Parent $Path)
    [IO.File]::WriteAllText($Path, 'x' * 10)
    $t = [datetime]::UtcNow.AddDays(-$AgeDays)
    [IO.File]::SetLastWriteTimeUtc($Path, $t)
    if ($IsWindows -or $PSVersionTable.PSVersion.Major -lt 6) { [IO.File]::SetCreationTimeUtc($Path, $t) }
}
try {
    $cutoff = [datetime]::UtcNow.AddDays(-7); $deadline = [datetime]::UtcNow.AddMinutes(5)
    $canAge = ($IsWindows -or $PSVersionTable.PSVersion.Major -lt 6)

    # Aged files go, recent files stay, filters hold, and a symlinked folder is never followed.
    $t = Join-Path $root 'temp'
    New-File (Join-Path $t 'old.tmp') 30; New-File (Join-Path $t 'new.tmp') 1; New-File (Join-Path $t 'sub/old2.tmp') 30
    $outside = Join-Path $root 'outside'; New-File (Join-Path $outside 'keep.doc') 30
    $linked = $false
    try { $null = New-Item -ItemType SymbolicLink -Path (Join-Path $t 'link') -Target $outside -ErrorAction Stop; $linked = $true } catch { 'symlink not permitted here; reparse test skipped' }
    $res = Remove-SmAgedFiles $t $cutoff $deadline -RemoveEmptyDirs
    Assert (Test-Path (Join-Path $t 'new.tmp')) 'A recent file is kept'
    Assert (Test-Path (Join-Path $outside 'keep.doc')) 'A file behind a symlinked folder is never deleted'
    if ($canAge) {
        Assert (-not (Test-Path (Join-Path $t 'old.tmp')) -and -not (Test-Path (Join-Path $t 'sub/old2.tmp'))) 'Aged files are deleted, recursively'
        Assert ($res.Files -eq 2 -and $res.LogicalBytes -eq 20) 'Counts deleted files and bytes'
    }
    Assert (Test-Path $t) 'The category root itself is kept'
    $again = Remove-SmAgedFiles $t $cutoff $deadline -RemoveEmptyDirs
    Assert ($again.Files -eq 0) 'A second run deletes nothing (idempotent)'

    # A folder created just now is not pruned even when empty: an installer may be about to use it.
    $fresh = Join-Path $t 'fresh'; $null = New-Item -ItemType Directory $fresh
    $null = Remove-SmAgedFiles $t $cutoff $deadline -RemoveEmptyDirs
    Assert (Test-Path $fresh) 'A new empty folder is kept'

    # Include, exclude and no-recursion: CBS.log stays, a rotated log goes, subfolders are untouched.
    $cbs = Join-Path $root 'cbs'
    New-File (Join-Path $cbs 'CBS.log') 30; New-File (Join-Path $cbs 'CbsPersist_1.log') 30; New-File (Join-Path $cbs 'x.txt') 30; New-File (Join-Path $cbs 'deep/a.log') 30
    $null = Remove-SmAgedFiles $cbs $cutoff $deadline -Include '\.(log|cab)$' -Exclude '^CBS\.log$' -NoRecurse
    Assert (Test-Path (Join-Path $cbs 'CBS.log')) 'The live CBS.log is never deleted'
    Assert (Test-Path (Join-Path $cbs 'x.txt')) 'Include filter holds'
    Assert (Test-Path (Join-Path $cbs 'deep/a.log')) 'NoRecurse leaves subfolders alone'
    if ($canAge) { Assert (-not (Test-Path (Join-Path $cbs 'CbsPersist_1.log'))) 'A rotated aged log is deleted' }

    # A deadline in the past stops at the first entry and deletes nothing.
    New-File (Join-Path $root 'late/old.tmp') 30
    $late = Remove-SmAgedFiles (Join-Path $root 'late') $cutoff ([datetime]::UtcNow.AddSeconds(-1))
    Assert ($late.TimedOut -and $late.Files -eq 0 -and (Test-Path (Join-Path $root 'late/old.tmp'))) 'Deadline stops the walk'
    $emptyRoot = Join-Path $root 'empty'; $null = New-Item -ItemType Directory $emptyRoot
    $prune = Remove-SmAgedFiles $emptyRoot ([datetime]::MaxValue) ([datetime]::UtcNow.AddSeconds(-1)) -RemoveEmptyDirs -IncludeRoot
    Assert ($prune.TimedOut -and (Test-Path $emptyRoot)) 'Folder pruning stops at the deadline too'

    # App caches: only cache folders, never cookies, logins, IndexedDB, Local Storage or Documents.
    $p = Join-Path $root 'profile-fixture'
    foreach ($d in @('AppData/Local/Microsoft/Edge/User Data/Default/Cache', 'AppData/Local/Microsoft/Edge/User Data/Default/Code Cache',
            'AppData/Local/Microsoft/Edge/User Data/Default/Service Worker/CacheStorage', 'AppData/Local/Microsoft/Edge/User Data/Default/IndexedDB',
            'AppData/Local/Microsoft/Edge/User Data/Default/Local Storage', 'AppData/Local/Microsoft/Edge/User Data/ShaderCache',
            'AppData/Local/Google/Chrome/User Data/Profile 1/GPUCache', 'AppData/Local/Packages/MSTeams_8wekyb3d8bbwe/LocalCache/Microsoft/MSTeams/EBWebView/Default/Cache',
            'AppData/Roaming/Microsoft/Teams/Cache', 'AppData/Local/Microsoft/Edge/User Data/Default/Extensions/ext/1.0/Cache', 'Documents/Cache', 'Downloads/Cache', 'OneDrive - Org/Cache')) { $null = New-Item -ItemType Directory -Force (Join-Path $p $d) }
    $caches = @(Get-SmAppCacheRoots $p | ForEach-Object { $_.Substring($p.Length + 1).Replace('\', '/') })
    foreach ($want in @('User Data/Default/Cache', 'Default/Code Cache', 'Service Worker/CacheStorage', 'User Data/ShaderCache', 'Profile 1/GPUCache', 'EBWebView/Default/Cache', 'Teams/Cache')) {
        Assert (@($caches | Where-Object { $_.EndsWith($want) }).Count -eq 1) "Cache root found: $want"
    }
    Assert (@($caches | Where-Object { $_ -match 'Extensions' }).Count -eq 0) 'Cache discovery stops at depth 3'
    Assert (@($caches | Where-Object { $_ -match 'IndexedDB|Local Storage|^Documents|^Downloads|^OneDrive' }).Count -eq 0) 'No data, Documents, Downloads or OneDrive folder is a cache root'

    # Category roots never include user data folders, and cover the agreed Safe categories.
    $cats = @(Get-SmCleanupCategories @($p) (Join-Path $root 'Windows') (Join-Path $root 'ProgramData'))
    Assert (@($cats | Where-Object { $_.Root -match '(?i)[\\/](Documents|Desktop|Downloads|OneDrive[^\\/]*|Outlook|Favorites|Pictures)([\\/]|$)' }).Count -eq 0) 'No category root is a user data folder'
    Assert (@($cats | Where-Object { $_.Name -eq 'AppCache' -and $_.Prune }).Count -eq 0) 'Cache subfolders are never pruned while a browser may use them'
    foreach ($n in @('Temp','WindowsUpdateDownload', 'CrashDumps', 'ServicingLogs', 'AppCache')) { Assert (@($cats | Where-Object { $_.Name -eq $n }).Count -gt 0) "Category present: $n" }
    Assert (@($cats | Where-Object { $_.Root -match '(?i)\$WINDOWS\.~(BT|WS)|Windows\.old|[\\/]ESD$|FeatureUpgrade|hiberfil|pagefile' }).Count -eq 0) 'Upgrade staging, rollback and the upgrade ISO folder are never generic roots'

    # Recycle Bin: aged by the deletion time inside the $I record, never by file dates.
    function New-IRecord($Path, [int]$DeletedDaysAgo, [int64]$Version = 2) {
        $b = New-Object byte[] 32
        [BitConverter]::GetBytes($Version).CopyTo($b, 0)
        [BitConverter]::GetBytes([datetime]::UtcNow.AddDays(-$DeletedDaysAgo).ToFileTimeUtc()).CopyTo($b, 16)
        $null = New-Item -ItemType Directory -Force (Split-Path -Parent $Path); [IO.File]::WriteAllBytes($Path, $b)
    }
    $bin = Join-Path $root 'bin/S-1-5-21-1'
    New-IRecord (Join-Path $bin '$IA1.txt') 30 1; New-File (Join-Path $bin '$RA1.txt') 1
    New-IRecord (Join-Path $bin '$IB2') 30; New-File (Join-Path $bin '$RB2/inner/file.txt') 1
    # Recent deletion with an old file date: the record decides, so it stays.
    New-IRecord (Join-Path $bin '$IC3.txt') 1; [IO.File]::SetLastWriteTimeUtc((Join-Path $bin '$IC3.txt'), [datetime]::UtcNow.AddDays(-30)); New-File (Join-Path $bin '$RC3.txt') 30
    # Unreadable or future records keep the item.
    New-File (Join-Path $bin '$ID4.txt') 30; New-File (Join-Path $bin '$RD4.txt') 30
    New-IRecord (Join-Path $bin '$IE5.txt') -5; New-File (Join-Path $bin '$RE5.txt') 30
    New-IRecord (Join-Path $bin '$IF6.txt') 30 7; New-File (Join-Path $bin '$RF6.txt') 30
    $rb = Remove-SmRecycleBin (Join-Path $root 'bin') $cutoff $deadline
    Assert ((Test-Path (Join-Path $bin '$IC3.txt')) -and (Test-Path (Join-Path $bin '$RC3.txt'))) 'A recently recycled item is kept even when its record file looks old'
    Assert (-not (Test-Path (Join-Path $bin '$RA1.txt')) -and -not (Test-Path (Join-Path $bin '$IA1.txt'))) 'An item recycled long ago goes, whatever its own file date'
    Assert (-not (Test-Path (Join-Path $bin '$RB2'))) 'A recycled folder goes with its contents'
    foreach ($k in 'D4', 'E5', 'F6') { Assert (Test-Path (Join-Path $bin ('$R' + $k + '.txt'))) "Invalid record $k keeps the item" }
    Assert ($rb.Files -eq 2) 'Recycle Bin counts deleted data files'
    Assert ($null -eq (ConvertFrom-SmRecycleRecord ([byte[]](1, 2, 3)))) 'A short record is unreadable'

    # cleanmgr: never Downloads, Recycle Bin or File History; Windows.old only when allowed.
    $available = @('DownloadsFolder', 'Recycle Bin', 'User file versions', 'BranchCache', 'Previous Installations', 'Temporary Files', 'Update Cleanup', 'Windows Upgrade Log Files')
    $sel = Get-SmCleanmgrSelection $available $false
    Assert (@($sel | Where-Object { $_ -in @('DownloadsFolder', 'Recycle Bin', 'User file versions', 'BranchCache', 'Previous Installations') }).Count -eq 0) 'Excluded handlers never selected'
    Assert ($sel -contains 'Temporary Files' -and $sel -contains 'Update Cleanup') 'Listed handlers selected'
    Assert ((Get-SmCleanmgrSelection $available $true) -contains 'Previous Installations') 'Previous Installations only when Windows.old is eligible'

    $now = [datetime]::UtcNow
    Assert (Test-SmWindowsOldEligible $now.AddDays(-11) $now.AddDays(-11) 10 $now) 'Windows.old and the upgrade older than 10 days are eligible'
    Assert (-not (Test-SmWindowsOldEligible $now.AddDays(-9) $now.AddDays(-9) 10 $now)) 'Windows.old inside the rollback window is kept'
    Assert (-not (Test-SmWindowsOldEligible $now.AddDays(-40) $now.AddDays(-40) 60 $now)) 'An extended rollback window is honoured'
    Assert (-not (Test-SmWindowsOldEligible $now.AddDays(-40) $now.AddDays(-3) 10 $now)) 'A recent upgrade keeps an old Windows.old folder'
    Assert (-not (Test-SmWindowsOldEligible $now.AddDays(-40) $null 10 $now)) 'Unknown upgrade date keeps Windows.old'
    Assert (-not (Test-SmWindowsOldEligible $now.AddDays(-40) $now.AddDays(-40) $null $now)) 'Unknown rollback window keeps Windows.old'
    Assert (-not (Test-SmWindowsOldEligible $null $now 10 $now)) 'No Windows.old, nothing to do'
    Assert (Test-SmShadowShrink ([uint64]::MaxValue) 1000) 'Unbounded shadow storage is shrunk'
    Assert (-not (Test-SmShadowShrink 50 1000)) 'Shadow storage at 5 percent is left alone'

    # Orchestration: an unsafe guard withholds every category; a live upgrade keeps its ISO.
    $priorWin = $env:windir; $priorPd = $env:ProgramData; $priorSd = $env:SystemDrive
    $env:windir = Join-Path $root 'Windows'; $env:ProgramData = Join-Path $root 'ProgramData'; $env:SystemDrive = $root
    $script:SmFreeBytes = { [int64]100 }
    $script:SmDeliveryOptimization = { $script:doCalled = $true }
    $script:SmCleanmgr = { throw 'cleanmgr must not run in the Safe tier' }
    $script:SmShadowShrink = { throw 'vssadmin must not run in the Safe tier' }
    $fu = Join-Path $env:ProgramData 'Relian/FeatureUpgrade'; New-File (Join-Path $fu 'abc.iso') 30
    '{"status":"running","time":"2026-01-01T00:00:00Z"}' | Set-Content (Join-Path $fu 'state.json')
    try {
        $script:SmGuards = { [pscustomobject]@{ Safe = $false; Light = $true; Reasons = @('setup') } }
        $steps = @(Invoke-SmCleanupTier (Get-SmArguments -Mode Cleanup -Tier Safe) @($p))
        Assert (@($steps | Where-Object { $_.Status -ne 'withheld' }).Count -eq 0 -and -not $script:doCalled) 'Unsafe guard withholds every category'

        $script:SmGuards = { [pscustomobject]@{ Safe = $true; Light = $false; Reasons = @() } }
        $steps = @(Invoke-SmCleanupTier (Get-SmArguments -Mode Cleanup -Tier Safe) @($p))
        Assert ($script:doCalled) 'Delivery Optimization cache cleared through its cmdlet'
        Assert (Test-Path (Join-Path $fu 'abc.iso')) 'The ISO of a running upgrade attempt is kept'
        Assert (@($steps | Where-Object { $_.Name -in @('Cleanmgr', 'ShadowStorage') }).Count -eq 0) 'Safe tier never runs cleanmgr or vssadmin'
        Assert (@($steps | Where-Object { $_.Error }).Count -eq 0) ('Safe tier steps succeed: ' + (@($steps | Where-Object { $_.Error } | ForEach-Object { "$($_.Name): $($_.Error)" }) -join '; '))

        '{"status":"failed","time":"2026-01-01T00:00:00Z"}' | Set-Content (Join-Path $fu 'state.json')
        $null = Invoke-SmCleanupTier (Get-SmArguments -Mode Cleanup -Tier Safe) @($p)
        if ($canAge) { Assert (-not (Test-Path (Join-Path $fu 'abc.iso'))) 'The ISO of an aged failed attempt is deleted' }
        Assert (Test-Path (Join-Path $fu 'state.json')) 'The attempt state file is kept'

        $script:SmCleanmgr = { param($Prev, $Seconds) $script:cleanPrev = $Prev; @{ Handlers = @('Temporary Files'); State = 'exited'; ExitCode = 0 } }
        $script:SmShadowShrink = { 'alreadyAtOrBelow5Percent' }
        $script:SmWindowsOldState = { @{ CreatedUtc = [datetime]::UtcNow.AddDays(-40); InstalledUtc = [datetime]::UtcNow.AddDays(-3); WindowDays = 10 } }
        $steps = @(Invoke-SmCleanupTier (Get-SmArguments -Mode Cleanup -Tier Aggressive) @($p))
        Assert ($script:cleanPrev -eq $false) 'A recent Windows.old keeps the rollback option'
        Assert (@($steps | Where-Object { $_.Name -eq 'ShadowStorage' -and $_.Status -eq 'done' }).Count -eq 1) 'Aggressive tier reviews shadow storage'

        # A refused root (a junction or symlink) makes its category partial with the reason.
        if ($linked) {
            $null = New-Item -ItemType Directory -Force $env:windir
            $null = New-Item -ItemType SymbolicLink -Path (Join-Path $env:windir 'Minidump') -Target $outside
            $refused = @(Invoke-SmCleanupTier (Get-SmArguments -Mode Cleanup -Tier Safe) @($p) | Where-Object { $_.Name -eq 'CrashDumps' })[0]
            Assert ($refused.Status -eq 'partial' -and $refused.Error -match 'reparse') 'A refused root is reported, not marked done'
            Assert (Test-Path (Join-Path $outside 'keep.doc')) 'Nothing behind the refused root is deleted'
            [IO.Directory]::Delete((Join-Path $env:windir 'Minidump'))  # removes the link only; Remove-Item fails on a link in 5.1
        }

        $report = [pscustomobject]@{ Status = 'complete'; Mode = 'Cleanup'; Actions = $steps; Guards = @{ Reasons = @() }; Scan = $null; Before = @(); After = @(); FreeSpaceDelta = @(); Profiles = @(); Notifications = @(); Errors = @(); Evidence = @{ Opportunities = @() }; RemovalPlan = $null; Audit = $null }
        $summary = ConvertTo-SmSummary $report 'r.json' | ConvertFrom-Json
        Assert (@($summary.Categories).Count -ge 7 -and $null -ne $summary.Categories[0].FreedBytes) 'Stdout summary lists each category with its freed bytes'
    } finally { $env:windir = $priorWin; $env:ProgramData = $priorPd; $env:SystemDrive = $priorSd }
} finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
'storage-maintenance cleanup tier tests passed'
