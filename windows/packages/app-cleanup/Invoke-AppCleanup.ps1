<#
.SYNOPSIS
    Finds, and with Fix removes, stale Firefox copies, classic Teams 1.x and per-user Google Chrome, for the Relian
    deploy runner (NinjaOne script 374).

.DESCRIPTION
    Read-only unless Fix is "true". Target is "firefox", "teams", "chrome-user" or "all" (default). "all" means
    firefox and teams only: chrome-user is opt-in, so an existing "all" run never removes Chrome.

    Firefox: lists every copy (machine-wide MSI or exe, and per-user installs under C:\Users) with its
    version and the newest write time of each user's profile (last use). A copy older than CurrentMajor is
    removed when it is not running and either another copy is current or nobody has used Firefox for
    IdleDays. An old copy that is in use is reported as "upgrade" and left alone: upgrade it with the
    firefox package, then run this again. A running copy is reported as "skip-running".

    Teams: removes the classic Teams Machine-Wide Installer (msiexec /x) and each user's classic copy
    (Update.exe --uninstall -s). A user's copy is skipped while that user's classic Teams runs. New Teams
    (ms-teams) is never touched.

    chrome-user: reports each per-user Chrome (AppData\Local\Google\Chrome\Application\chrome.exe in each profile)
    and the machine-wide version. Fix removes it by direct cleanup, not with Google's uninstaller: a user's
    setup.exe is user-writable, so running it as SYSTEM would hand that user SYSTEM, and without --system-level it
    would act on SYSTEM's own profile anyway. Per user, when Chrome is not running and no junction or symlink sits
    on the path to or inside any folder it deletes (else "skip-unsafe", a failure; each delete re-checks this on the
    open handle, so swapping in a junction after the check is refused too), it deletes the Application
    folder; the per-user updater folders only when Chrome is the only Google app in that user's hive; scheduled
    tasks and Run values that point into a deleted folder; the user's Chrome Uninstall and App Paths keys;
    Software\Google\Update when the updater went; and .lnk shortcuts (Desktop, Start Menu, taskbar pins) to the
    deleted chrome.exe. It never touches User Data (bookmarks, passwords), file associations, machine-wide Chrome
    (Program Files) or a running Chrome. A running Chrome is "skip-running", not a failure.

    The runner passes DeploymentType, Action and PinVersion, then each PackageArguments pair as -Name value:
    Target, Fix, CurrentMajor, IdleDays (all strings). Install, Update, Repair and Reinstall run the check
    (and the fix when Fix is "true"); Uninstall changes nothing and exits 0.

    The result is one line of compact JSON, printed last on stdout. Exit 1 when a removal failed or a
    copy was still present after Fix.

.NOTES
    Requirements: Windows PowerShell 5.1+, run as SYSTEM
    shortcut: chrome-user scans the profile's own Desktop folder, not a OneDrive-redirected one; add that path
    when users keep Chrome shortcuts on a redirected desktop.
    shortcut: a per-user uninstall as SYSTEM leaves the user's HKCU Uninstall key behind; delete it when
    an inventory tool keeps reporting a removed copy.
#>

# Not Mandatory: a mandatory param block prompts when this file is dot-sourced under RELIAN_DEPLOY_TEST.
[CmdletBinding()]
param(
    [string]$DeploymentType,
    [string]$Action,
    [string]$PinVersion,
    [string]$Target = 'all',
    [string]$Fix = '',
    [string]$CurrentMajor = '150',
    [string]$IdleDays = '90'
)

$ProgressPreference = 'SilentlyContinue'
$AcTeamsCodes = @('{731F6BAA-A986-45A4-8936-7C3AAAAA760B}', '{39AF0813-FA7B-4860-ADBE-93B9B214B914}')
# Chrome, Chrome binaries, Google Update (Omaha) and GoogleUpdater ids: any other app id keeps the per-user updater.
$AcChromeOwnIds = @('8A69D345-D564-463C-AFF1-A69D9E530F96', '4DC8B4CA-1BDA-483E-B5FA-D3C12E15B62D', '430FD4D0-B729-4F61-AA34-91526481799D', '44FC7FE2-65CE-487C-93F4-EDEE46EEAAAB')

# Pure: 'none', 'check' or 'fix'. An empty PinVersion is the off switch. Throws on bad input.
function Get-AcMode {
    param([string]$Action, [string]$Fix, [string]$Target, [string]$PinVersion = '1.0.0')
    if ([string]::IsNullOrWhiteSpace($PinVersion)) { return 'none' }
    if (@('Install', 'Update', 'Repair', 'Reinstall', 'Uninstall') -notcontains $Action) {
        throw 'Action must be Install, Update, Repair, Reinstall, or Uninstall.'
    }
    if (@('firefox', 'teams', 'chrome-user', 'all') -notcontains $Target) { throw 'Target must be firefox, teams, chrome-user or all.' }
    if ($Fix -ne '' -and $Fix -ne 'true' -and $Fix -ne 'false') { throw 'Fix must be true or false.' }
    if ($Action -eq 'Uninstall') { return 'none' }
    if ($Fix -eq 'true') { return 'fix' }
    return 'check'
}

# Pure. "all" is firefox and teams only: chrome-user must be asked for by name.
function Get-AcTargets { param([string]$Target) if ($Target -eq 'all') { return @('firefox', 'teams') } return @($Target) }

# Pure. True when Path (an exe path or a command line, quoted or not) starts inside Dir.
function Test-AcUnder {
    param([string]$Path, [string]$Dir)
    $p = $Path.Trim().TrimStart('"').Replace('/', '\').ToLowerInvariant()
    return $p.StartsWith($Dir.Replace('/', '\').TrimEnd('\').ToLowerInvariant() + '\')
}

# Pure. App ids (registry subkey names) other than Chrome and the updater itself.
function Get-AcOtherGoogleApps {
    param([string[]]$Ids)
    @($Ids | Where-Object { $_ -match '^\{?[0-9A-Fa-f-]{36}\}?$' -and $AcChromeOwnIds -notcontains $_.Trim('{', '}') } | Sort-Object -Unique)
}

# Pure. Installs: objects with Id, Version, Scope (machine|user), User, Path. IdleByUser: user -> days since last
# profile write ($null = no profile found). RunningPaths: lower-case firefox.exe paths now running.
function Get-AcFirefoxPlan {
    param($Installs, [hashtable]$IdleByUser, [string[]]$RunningPaths, [int]$CurrentMajor, [int]$IdleDays)
    $isCurrent = { param($i) $v = $null; [version]::TryParse([string]$i.Version, [ref]$v) -and $v.Major -ge $CurrentMajor }
    $plan = @()
    foreach ($i in @($Installs)) {
        $act = 'keep'; $why = 'current'
        if (-not (& $isCurrent $i)) {
            $other = @($Installs | Where-Object { $_.Id -ne $i.Id -and (& $isCurrent $_) })
            if (@($RunningPaths) -contains ([string]$i.Path).ToLowerInvariant()) {
                $act = 'skip-running'; $why = 'old copy is running'
            } elseif ($other.Count -gt 0) {
                $act = 'remove'; $why = 'a current copy exists: ' + $other[0].Version
            } else {
                $users = if ($i.Scope -eq 'user') { @($i.User) } else { @($IdleByUser.Keys) }
                $days = @($users | ForEach-Object { if ($IdleByUser.ContainsKey($_) -and $null -ne $IdleByUser[$_]) { [int]$IdleByUser[$_] } else { 9999 } })
                $min = if ($days.Count -gt 0) { ($days | Measure-Object -Minimum).Minimum } else { 9999 }
                if ($min -ge $IdleDays) { $act = 'remove'; $why = "unused for $min days" }
                else { $act = 'upgrade'; $why = "in use ($min days since last use), no current copy" }
            }
        }
        $plan += [pscustomobject]@{ Id = $i.Id; Action = $act; Reason = $why }
    }
    return , $plan
}

# Seams for unit tests.
function Get-AcUserDirs {
    @(Get-ChildItem -LiteralPath "$env:SystemDrive\Users" -Directory -ErrorAction SilentlyContinue |
        Where-Object { @('Public', 'Default', 'Default User', 'All Users') -notcontains $_.Name })
}
function Get-AcRunning {
    @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.ExecutablePath } |
        ForEach-Object { [pscustomobject]@{ Name = $_.Name; Path = [string]$_.ExecutablePath } })
}
function Get-AcMachineKeys {
    foreach ($root in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall') {
        Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue | ForEach-Object {
            $p = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue
            if ($p) { [pscustomobject]@{ Key = $_.PSChildName; Name = [string]$p.DisplayName; Version = [string]$p.DisplayVersion; Uninstall = [string]$p.UninstallString; Location = [string]$p.InstallLocation } }
        }
    }
}
function Get-AcFileVersion { param([string]$Path) try { return [string](Get-Item -LiteralPath $Path).VersionInfo.ProductVersion } catch { return '' } }
function Get-AcLastWrite {
    param([string]$Dir)
    $f = @(Get-ChildItem -LiteralPath $Dir -File -ErrorAction SilentlyContinue) +
        @(Get-ChildItem -LiteralPath (Join-Path $Dir 'sessionstore-backups') -File -ErrorAction SilentlyContinue)
    if ($f.Count -eq 0) { return $null }
    return ($f | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime
}
function Invoke-AcProcess {
    param([string]$File, [string]$Arguments)
    $p = Start-Process -FilePath $File -ArgumentList $Arguments -Wait -PassThru -WindowStyle Hidden
    return [int]$p.ExitCode
}
function Get-AcNow { Get-Date }
function Test-AcReparse { param([string]$Path) [bool]((Get-Item -LiteralPath $Path -Force -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint) }
function Get-AcTasks {
    @(Get-ScheduledTask -ErrorAction SilentlyContinue | ForEach-Object {
            $t = $_
            foreach ($a in @($t.Actions)) {
                if ($a.PSObject.Properties['Execute'] -and $a.Execute) { [pscustomobject]@{ Name = $t.TaskName; TaskPath = $t.TaskPath; Exe = [string]$a.Execute } }
            }
        })
}
function Unregister-AcTask { param($Task) Unregister-ScheduledTask -TaskName $Task.Name -TaskPath $Task.TaskPath -Confirm:$false -ErrorAction Stop }
function Get-AcShortcutTarget {
    param([string]$Path)
    if (-not $script:AcShell) { $script:AcShell = New-Object -ComObject WScript.Shell }
    return [string]$script:AcShell.CreateShortcut($Path).TargetPath
}
function Get-AcMachineChrome {
    foreach ($p in "${env:ProgramFiles}\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe") {
        if (Test-Path -LiteralPath $p) { return Get-AcFileVersion -Path $p }
    }
    return $null
}
# Returns @{ Root; Mounted }: the user's loaded hive (HKU\<SID>), else NTUSER.DAT loaded as HKU\RelianAC_<n>.
function Mount-AcHive {
    param([string]$Dir, [int]$N)
    $sid = $null
    foreach ($k in @(Get-ChildItem -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' -ErrorAction SilentlyContinue)) {
        $img = [Environment]::ExpandEnvironmentVariables([string](Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue).ProfileImagePath)
        if ($img -and $img.TrimEnd('\') -ieq $Dir.TrimEnd('\')) { $sid = $k.PSChildName; break }
    }
    if ($sid -and (Test-Path -LiteralPath "Registry::HKEY_USERS\$sid")) { return @{ Root = "Registry::HKEY_USERS\$sid"; Mounted = '' } }
    $name = "RelianAC_$N"
    & "$env:SystemRoot\System32\reg.exe" load "HKU\$name" (Join-Path $Dir 'NTUSER.DAT') 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "reg load exit $LASTEXITCODE" }
    return @{ Root = "Registry::HKEY_USERS\$name"; Mounted = $name }
}
function Dismount-AcHive {
    param([string]$Name)
    [gc]::Collect(); [gc]::WaitForPendingFinalizers()
    & "$env:SystemRoot\System32\reg.exe" unload "HKU\$Name" 2>&1 | Out-Null
}
function Get-AcRegValues {
    param([string]$Path)
    $h = @{}; $k = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($k) { foreach ($n in $k.GetValueNames()) { $h[$n] = [string]$k.GetValue($n) } }
    return $h
}
function Get-AcRegKeys { param([string]$Path) @(Get-ChildItem -LiteralPath $Path -ErrorAction SilentlyContinue | ForEach-Object { $_.PSChildName }) }
function Test-AcRegKey { param([string]$Path) Test-Path -LiteralPath $Path }
function Remove-AcRegKey { param([string]$Path) Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop }
function Remove-AcRegValue { param([string]$Path, [string]$Name) Remove-ItemProperty -LiteralPath $Path -Name $Name -Force -ErrorAction Stop }

function Get-AcFirefoxInventory {
    $installs = @(); $n = 0
    foreach ($k in @(Get-AcMachineKeys | Where-Object { $_.Name -like 'Mozilla Firefox*' })) {
        $n++
        $loc = $k.Location
        if (-not $loc -and $k.Uninstall -match '"?([^"]+)\\uninstall\\helper\.exe') { $loc = $Matches[1] }
        $exe = if ($loc) { Join-Path $loc 'firefox.exe' } else { '' }
        $ver = if ($exe -and (Test-Path -LiteralPath $exe)) { Get-AcFileVersion -Path $exe } else { '' }
        if (-not $ver) { $ver = $k.Version -replace '\s.*', '' }
        $installs += [pscustomobject]@{ Id = "m$n"; Version = $ver; Scope = 'machine'; User = ''; Path = $exe; Uninstall = $k.Uninstall; Key = $k.Key; Msi = ($k.Key -match '^\{[0-9A-Fa-f-]{36}\}$') }
    }
    foreach ($u in Get-AcUserDirs) {
        foreach ($rel in 'AppData\Local\Mozilla Firefox', 'AppData\Local\Programs\Mozilla Firefox') {
            $exe = Join-Path (Join-Path $u.FullName $rel) 'firefox.exe'
            if (Test-Path -LiteralPath $exe) {
                $n++
                $installs += [pscustomobject]@{ Id = "u$n"; Version = (Get-AcFileVersion -Path $exe); Scope = 'user'; User = $u.Name; Path = $exe; Uninstall = (Join-Path (Split-Path $exe) 'uninstall\helper.exe'); Key = ''; Msi = $false }
            }
        }
    }
    # Same firefox.exe seen as a registry entry and a user path counts once.
    $seen = @{}; $out = @()
    foreach ($i in $installs) { $p = $i.Path.ToLowerInvariant(); if ($p -and $seen[$p]) { continue }; if ($p) { $seen[$p] = $true }; $out += $i }
    return , $out
}

function Get-AcIdleByUser {
    $now = Get-AcNow; $h = @{}
    foreach ($u in Get-AcUserDirs) {
        $last = $null
        foreach ($pd in @(Get-ChildItem -LiteralPath (Join-Path $u.FullName 'AppData\Roaming\Mozilla\Firefox\Profiles') -Directory -ErrorAction SilentlyContinue)) {
            $t = Get-AcLastWrite -Dir $pd.FullName
            if ($t -and (-not $last -or $t -gt $last)) { $last = $t }
        }
        $h[$u.Name] = if ($last) { [int]($now - $last).TotalDays } else { $null }
    }
    return $h
}

function Remove-AcFirefox {
    param($Install)
    if ($Install.Msi) { return Invoke-AcProcess -File "$env:SystemRoot\System32\msiexec.exe" -Arguments "/x $($Install.Key) /qn /norestart" }
    $helper = if ($Install.Uninstall -match '"?([^"]+helper\.exe)') { $Matches[1] } else { '' }
    if (-not $helper -or -not (Test-Path -LiteralPath $helper)) { return 2 }
    return Invoke-AcProcess -File $helper -Arguments '/S'
}

function Invoke-AcFirefox {
    param([bool]$Fix, [int]$CurrentMajor, [int]$IdleDays)
    $running = @(Get-AcRunning | Where-Object { $_.Name -ieq 'firefox.exe' } | ForEach-Object { $_.Path.ToLowerInvariant() })
    $installs = @(Get-AcFirefoxInventory)
    $idle = Get-AcIdleByUser
    $plan = @(Get-AcFirefoxPlan -Installs $installs -IdleByUser $idle -RunningPaths $running -CurrentMajor $CurrentMajor -IdleDays $IdleDays)
    $failed = 0; $rows = @()
    for ($x = 0; $x -lt $installs.Count; $x++) {
        $i = $installs[$x]; $p = $plan[$x]; $res = ''
        if ($Fix -and $p.Action -eq 'remove') {
            $code = Remove-AcFirefox -Install $i
            $res = "exit $code"
            if ($code -ne 0 -and $code -ne 3010) { $failed++ }
        }
        $rows += [ordered]@{ scope = $i.Scope; user = $i.User; version = $i.Version; path = $i.Path; msi = $i.Msi; action = $p.Action; reason = $p.Reason; result = $res }
    }
    $after = if ($Fix) { @((Get-AcFirefoxInventory) | ForEach-Object { "$($_.Version) $($_.Path)" }) } else { $null }
    return [ordered]@{ installs = $rows; idleDays = $idle; remaining = $after; failed = $failed }
}

function Invoke-AcTeams {
    param([bool]$Fix)
    $procs = @(Get-AcRunning)
    $rows = @(); $failed = 0
    foreach ($code in $AcTeamsCodes) {
        $present = (Test-Path -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$code") -or (Test-Path -LiteralPath "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\$code")
        if (-not $present) { continue }
        $res = ''
        if ($Fix) {
            $c = Invoke-AcProcess -File "$env:SystemRoot\System32\msiexec.exe" -Arguments "/x $code /qn /norestart"
            $res = "exit $c"; if ($c -ne 0 -and $c -ne 3010) { $failed++ }
        }
        $rows += [ordered]@{ kind = 'machine-wide installer'; id = $code; action = 'remove'; result = $res }
    }
    foreach ($u in Get-AcUserDirs) {
        $dir = Join-Path $u.FullName 'AppData\Local\Microsoft\Teams'
        $upd = Join-Path $dir 'Update.exe'
        if (-not (Test-Path -LiteralPath $upd)) { continue }
        $run = @($procs | Where-Object { $_.Path.ToLowerInvariant().StartsWith($dir.ToLowerInvariant() + [System.IO.Path]::DirectorySeparatorChar) })
        $row = [ordered]@{ kind = 'user copy'; id = $u.Name; action = 'remove'; result = '' }
        if ($run.Count -gt 0) { $row.action = 'skip-running' }
        elseif ($Fix) {
            $c = Invoke-AcProcess -File $upd -Arguments '--uninstall -s'
            $row.result = "exit $c"; if ($c -ne 0) { $failed++ }
        }
        $rows += $row
    }
    return [ordered]@{ items = $rows; failed = $failed }
}

# Returns the first junction or symlink on the path from Root down to Target, Target included ($null when none).
function Find-AcReparseOnPath {
    param([string]$Root, [string]$Target)
    $p = $Root
    if (Test-AcReparse -Path $p) { return $p }
    foreach ($s in @($Target.Substring($Root.TrimEnd('\', '/').Length) -split '[\\/]' | Where-Object { $_ })) {
        $p = Join-Path $p $s
        if (Test-AcReparse -Path $p) { return $p }
    }
    return $null
}
# Returns the first junction or symlink inside Dir, never following one ($null when none).
function Find-AcReparseIn {
    param([string]$Dir)
    foreach ($c in @(Get-ChildItem -LiteralPath $Dir -Force -ErrorAction Stop)) {
        if (Test-AcReparse -Path $c.FullName) { return $c.FullName }
        if ($c.PSIsContainer) { $r = Find-AcReparseIn -Dir $c.FullName; if ($r) { return $r } }
    }
    return $null
}
# SYSTEM deletes inside a user-writable tree, where the user can swap any folder for a junction at any moment, so a
# path check before a delete can be raced. Each item is opened without following a link, refused when it is a
# reparse point or when its real location is not exactly Root's real location plus its relative path (an ancestor
# swapped for a junction), and deleted through that same handle. Names from a listing are only candidates.
$AcDeleteSource = @'
using System;
using System.IO;
using System.Text;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class RelianAcDelete {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern SafeFileHandle CreateFileW(string path, uint access, uint share, IntPtr sa, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern uint GetFinalPathNameByHandleW(SafeFileHandle h, StringBuilder buf, uint len, uint flags);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetFileInformationByHandleEx(SafeFileHandle h, int cls, out Basic info, uint size);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetFileInformationByHandle(SafeFileHandle h, int cls, ref byte delete, uint size);
    [StructLayout(LayoutKind.Sequential)] struct Basic { public long C, A, W, Ch; public uint Attr; }

    // OPEN_EXISTING with FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT: a link is opened itself, never its target.
    static SafeFileHandle Open(string path, uint access) {
        SafeFileHandle h = CreateFileW(path, access, 7, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero);
        if (h.IsInvalid) throw new IOException("open failed (" + Marshal.GetLastWin32Error() + "): " + path);
        return h;
    }
    static uint Attr(SafeFileHandle h) {
        Basic b;
        if (!GetFileInformationByHandleEx(h, 0, out b, (uint)Marshal.SizeOf(typeof(Basic)))) throw new IOException("attributes failed (" + Marshal.GetLastWin32Error() + ")");
        return b.Attr;
    }
    static string Final(SafeFileHandle h) {
        StringBuilder sb = new StringBuilder(1024);
        uint n = GetFinalPathNameByHandleW(h, sb, 1024, 0);
        if (n == 0 || n >= 1024) throw new IOException("final path failed (" + Marshal.GetLastWin32Error() + ")");
        return sb.ToString();
    }
    public static void Delete(string root, string path) {
        string real;
        using (SafeFileHandle h = Open(root, 0x80)) {
            if ((Attr(h) & 0x400) != 0) throw new IOException("reparse point: " + root);
            real = Final(h).TrimEnd('\\');
        }
        Del(path, real + path.Substring(root.TrimEnd('\\').Length));
    }
    static void Del(string path, string expected) {
        using (SafeFileHandle h = Open(path, 0x10080)) {
            uint a = Attr(h);
            if ((a & 0x400) != 0) throw new IOException("reparse point: " + path);
            if (!string.Equals(Final(h), expected, StringComparison.OrdinalIgnoreCase)) throw new IOException("moved under a link: " + path);
            if ((a & 0x10) != 0) { foreach (string c in Directory.GetFileSystemEntries(path)) { Del(c, expected + c.Substring(path.Length)); } }
            byte yes = 1;
            if (!SetFileInformationByHandle(h, 4, ref yes, 1)) throw new IOException("delete failed (" + Marshal.GetLastWin32Error() + "): " + path);
        }
    }
}
'@
function Remove-AcTree {
    param([string]$Root, [string]$Path)
    if (-not ('RelianAcDelete' -as [type])) { Add-Type -TypeDefinition $AcDeleteSource }
    try { [RelianAcDelete]::Delete($Root, $Path) }
    catch { throw $(if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }) }
}

# Fix for one user whose Chrome is not running and whose folders passed the reparse check. Returns @{ Res; Failed }.
function Remove-AcChromeUser {
    param([string]$Dir, [int]$N, $Tasks, $Row)
    $google = Join-Path $Dir 'AppData\Local\Google'
    $app = Join-Path $google 'Chrome\Application'
    $out = @('removed'); $bad = $false; $hive = $null
    $under = { param($p, $dirs) @($dirs | Where-Object { Test-AcUnder -Path $p -Dir $_ }).Count -gt 0 }
    try {
        try { $hive = Mount-AcHive -Dir $Dir -N $N } catch { $out += "hive not read: $($_.Exception.Message)"; $bad = $true }
        $others = @()
        if ($hive) {
            $ids = @(Get-AcRegKeys -Path "$($hive.Root)\Software\Google\Update\Clients") + @(Get-AcRegKeys -Path "$($hive.Root)\Software\Google\GoogleUpdater")
            $others = @(Get-AcOtherGoogleApps -Ids $ids)
        }
        $dropUpd = $hive -and $others.Count -eq 0
        Remove-AcTree -Root $Dir -Path $app
        $gone = @($app)
        foreach ($d in 'GoogleUpdater', 'Update') {
            $p = Join-Path $google $d
            if (-not (Test-Path -LiteralPath $p)) { continue }
            if ($dropUpd) { Remove-AcTree -Root $Dir -Path $p; $gone += $p }
            elseif ($hive) { $out += "kept $d for $($others -join ',')" }
            else { $out += "kept $d" }
        }
        $nt = 0
        foreach ($t in @($Tasks | Where-Object { & $under $_.Exe $gone })) { Unregister-AcTask -Task $t; $nt++ }
        if ($nt) { $out += "tasks $nt" }
        if ($hive) {
            $r = $hive.Root
            $un = "$r\Software\Microsoft\Windows\CurrentVersion\Uninstall\Google Chrome"
            if (Test-AcRegKey -Path $un) { Remove-AcRegKey -Path $un; $out += 'uninstall key' }
            $runKey = "$r\Software\Microsoft\Windows\CurrentVersion\Run"
            $vals = Get-AcRegValues -Path $runKey
            foreach ($name in @($vals.Keys)) { if (& $under $vals[$name] $gone) { Remove-AcRegValue -Path $runKey -Name $name; $out += "run $name" } }
            $ap = "$r\Software\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe"
            $apv = Get-AcRegValues -Path $ap
            if ($apv.ContainsKey('') -and (Test-AcUnder -Path $apv[''] -Dir $app)) { Remove-AcRegKey -Path $ap; $out += 'app path' }
            if ($dropUpd -and (Test-AcRegKey -Path "$r\Software\Google\Update")) { Remove-AcRegKey -Path "$r\Software\Google\Update"; $out += 'update key' }
            # Associations stay: Windows falls back to Edge. Report them so the user can be told.
            $choices = @(foreach ($s in 'http', 'https') { [string](Get-AcRegValues -Path "$r\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\$s\UserChoice")['ProgId'] })
            $Row.progid = @($choices | Where-Object { $_ -like 'ChromeHTML*' }).Count -gt 0
        }
    } finally {
        if ($hive -and $hive.Mounted) { Dismount-AcHive -Name $hive.Mounted }
    }
    $nl = 0
    foreach ($rel in 'Desktop', 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs', 'AppData\Roaming\Microsoft\Internet Explorer\Quick Launch\User Pinned') {
        foreach ($l in @(Get-ChildItem -LiteralPath (Join-Path $Dir $rel) -Filter '*.lnk' -File -Recurse -Force -ErrorAction SilentlyContinue)) {
            if (-not (Test-AcUnder -Path (Get-AcShortcutTarget -Path $l.FullName) -Dir $app)) { continue }
            try { Remove-AcTree -Root $Dir -Path $l.FullName; $nl++ } catch { $out += "kept $($l.Name): $($_.Exception.Message)" }
        }
    }
    if ($nl) { $out += "lnk $nl" }
    return @{ Res = ($out -join '; '); Failed = $bad }
}

function Invoke-AcChromeUser {
    param([bool]$Fix)
    $procs = @(Get-AcRunning); $now = Get-AcNow; $tasks = @(Get-AcTasks)
    $rows = @(); $failed = 0; $n = 0
    foreach ($u in Get-AcUserDirs) {
        $google = Join-Path $u.FullName 'AppData\Local\Google'
        $app = Join-Path $google 'Chrome\Application'
        $exe = Join-Path $app 'chrome.exe'
        if (-not (Test-Path -LiteralPath $exe)) { continue }
        $n++
        $data = Join-Path $google 'Chrome\User Data'
        $profs = @(Get-ChildItem -LiteralPath $data -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' })
        $marks = @(Get-Item -LiteralPath (Join-Path $data 'Local State') -Force -ErrorAction SilentlyContinue) +
            @($profs | ForEach-Object { Get-Item -LiteralPath (Join-Path $_.FullName 'Preferences'), (Join-Path $_.FullName 'History') -Force -ErrorAction SilentlyContinue })
        $last = @($marks | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
        $bytes = (@(Get-ChildItem -LiteralPath $data -Recurse -File -Force -ErrorAction SilentlyContinue) | Measure-Object -Property Length -Sum).Sum
        $upd = @(foreach ($d in 'GoogleUpdater', 'Update') { if (Test-Path -LiteralPath (Join-Path $google $d)) { $d } })
        $mine = @($tasks | Where-Object { Test-AcUnder -Path $_.Exe -Dir $google })
        $run = @($procs | Where-Object { Test-AcUnder -Path $_.Path -Dir $app }).Count -gt 0
        $row = [ordered]@{
            user = $u.Name; ver = (Get-AcFileVersion -Path $exe); run = $run; mb = [int][math]::Round([double]$bytes / 1MB)
            days = $(if ($last.Count) { [int]($now - $last[0].LastWriteTime).TotalDays } else { $null })
            prof = $profs.Count; upd = $upd; tasks = @($mine | ForEach-Object { $_.Name }); act = 'remove'; res = ''
        }
        $bad = $null
        if (-not $run) {
            try {
                foreach ($t in @($app) + @($upd | ForEach-Object { Join-Path $google $_ })) {
                    $bad = Find-AcReparseOnPath -Root $u.FullName -Target $t
                    if (-not $bad) { $bad = Find-AcReparseIn -Dir $t }
                    if ($bad) { break }
                }
            } catch { $bad = "unreadable: $($_.Exception.Message)" }
        }
        if ($run) { $row.act = 'skip-running' }
        elseif ($bad) {
            # Profile-relative keeps the line short (Intune output caps at 2048 characters).
            if ($bad.StartsWith($u.FullName)) { $bad = 'reparse point: ' + $bad.Substring($u.FullName.Length).TrimStart('\', '/') }
            $row.act = 'skip-unsafe'; $row.res = $bad; if ($Fix) { $failed++ }
        }
        elseif ($Fix) {
            $f = $false
            try { $r = Remove-AcChromeUser -Dir $u.FullName -N $n -Tasks $mine -Row $row; $row.res = $r.Res; $f = $r.Failed }
            catch { $row.res = "error: $($_.Exception.Message)"; $f = $true }
            if (Test-Path -LiteralPath $exe) { $row.res += '; chrome.exe still present'; $f = $true }
            if ($f) { $failed++ }
        }
        $rows += $row
    }
    return [ordered]@{ machineChrome = (Get-AcMachineChrome); users = $rows; failed = $failed }
}

function Invoke-Main {
    param([switch]$Fix, [string]$Target, [int]$CurrentMajor, [int]$IdleDays)
    try {
        $rec = [ordered]@{ mode = $(if ($Fix) { 'fix' } else { 'check' }); host = $env:COMPUTERNAME; version = '1.0' }
        $failed = 0
        $targets = Get-AcTargets -Target $Target
        if ($targets -contains 'firefox') { $rec.firefox = Invoke-AcFirefox -Fix:$Fix -CurrentMajor $CurrentMajor -IdleDays $IdleDays; $failed += $rec.firefox.failed }
        if ($targets -contains 'teams') { $rec.teams = Invoke-AcTeams -Fix:$Fix; $failed += $rec.teams.failed }
        if ($targets -contains 'chrome-user') { $rec.chromeUser = Invoke-AcChromeUser -Fix:$Fix; $failed += $rec.chromeUser.failed }
        $rec.timestamp = (Get-AcNow).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        Write-Output ($rec | ConvertTo-Json -Depth 6 -Compress)
        exit $(if ($failed -gt 0) { 1 } else { 0 })
    } catch {
        Write-Host "app-cleanup error: $_"
        exit 1
    }
}

if ($env:RELIAN_DEPLOY_TEST -ne '1') {
    try { $acMode = Get-AcMode -Action $Action -Fix $Fix -Target $Target -PinVersion $PinVersion }
    catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }
    if ($acMode -eq 'none') { Write-Output 'Nothing to change. Nothing was installed.'; exit 0 }
    Invoke-Main -Fix:($acMode -eq 'fix') -Target $Target -CurrentMajor ([int]$CurrentMajor) -IdleDays ([int]$IdleDays)
}
