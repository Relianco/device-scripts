<#
.SYNOPSIS
    Finds, and with Fix removes, stale Firefox copies and classic Teams 1.x, for the Relian deploy runner (NinjaOne script 374).

.DESCRIPTION
    Read-only unless Fix is "true". Target is "firefox", "teams" or "all" (default).

    Firefox: lists every copy (machine-wide MSI or exe, and per-user installs under C:\Users) with its
    version and the newest write time of each user's profile (last use). A copy older than CurrentMajor is
    removed when it is not running and either another copy is current or nobody has used Firefox for
    IdleDays. An old copy that is in use is reported as "upgrade" and left alone: upgrade it with the
    firefox package, then run this again. A running copy is reported as "skip-running".

    Teams: removes the classic Teams Machine-Wide Installer (msiexec /x). New Teams (ms-teams) is never touched.

    Per-user copies (Firefox under a profile, classic Teams under AppData) are only reported, action "user-context":
    they sit in a user-writable tree, and SYSTEM neither runs files there nor deletes recursively there (a junction
    swap would redirect the delete). Remove them in the user session, for example with an Intune user-context script.

    The runner passes DeploymentType, Action and PinVersion, then each PackageArguments pair as -Name value:
    Target, Fix, CurrentMajor, IdleDays (all strings). Install, Update, Repair and Reinstall run the check
    (and the fix when Fix is "true"); Uninstall changes nothing and exits 0.

    The result is one line of compact JSON, printed last on stdout. Exit 1 when a removal failed or a
    copy was still present after Fix.

.NOTES
    Requirements: Windows PowerShell 5.1+, run as SYSTEM
    shortcut: per-user copies are report-only; upgrade to a user-context remover when one is needed.
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

# Pure: 'none', 'check' or 'fix'. An empty PinVersion is the off switch. Throws on bad input.
function Get-AcMode {
    param([string]$Action, [string]$Fix, [string]$Target, [string]$PinVersion = '1.0.0')
    if ([string]::IsNullOrWhiteSpace($PinVersion)) { return 'none' }
    if (@('Install', 'Update', 'Repair', 'Reinstall', 'Uninstall') -notcontains $Action) {
        throw 'Action must be Install, Update, Repair, Reinstall, or Uninstall.'
    }
    if (@('firefox', 'teams', 'all') -notcontains $Target) { throw 'Target must be firefox, teams or all.' }
    if ($Fix -ne '' -and $Fix -ne 'true' -and $Fix -ne 'false') { throw 'Fix must be true or false.' }
    if ($Action -eq 'Uninstall') { return 'none' }
    if ($Fix -eq 'true') { return 'fix' }
    return 'check'
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
            $other = @($Installs | Where-Object { $_.Id -ne $i.Id -and (& $isCurrent $_) -and ($_.Scope -eq 'machine' -or ($i.Scope -eq 'user' -and $_.User -eq $i.User)) })
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
    return $plan
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

# True only when the fully resolved path (no "..", no relative form) sits under Program Files. Anything unresolvable is false.
function Test-AcProgramFiles {
    param([string]$Path)
    try { $full = [System.IO.Path]::GetFullPath($Path) } catch { return $false }
    foreach ($root in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if (-not $root) { continue }
        try { $r = [System.IO.Path]::GetFullPath($root).TrimEnd([char]92, [char]47) } catch { continue }
        if (-not $full.StartsWith($r + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        # Program Files is admin-writable, but a link anywhere between it and the file would still lead out of it: refuse.
        for ($d = $full; $d.Length -gt $r.Length; $d = Split-Path -Parent $d) {
            if ((Test-Path -LiteralPath $d) -and ((Get-Item -LiteralPath $d -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { return $false }
        }
        return $true
    }
    return $false
}

function Get-AcFirefoxInventory {
    $installs = @(); $n = 0
    foreach ($k in @(Get-AcMachineKeys | Where-Object { $_.Name -like 'Mozilla Firefox*' })) {
        $n++
        $loc = $k.Location
        if (-not $loc -and $k.Uninstall -match '"?([^"]+)\\uninstall\\helper\.exe') { $loc = $Matches[1] }
        $exe = if ($loc) { Join-Path $loc 'firefox.exe' } else { '' }
        $ver = if ($exe -and (Test-Path -LiteralPath $exe)) { Get-AcFileVersion -Path $exe } else { '' }
        if (-not $ver) { $ver = $k.Version -replace '\s.*', '' }
        $msi = ($k.Key -match '^\{[0-9A-Fa-f-]{36}\}$')
        # An MSI registration with no recorded install location stays unverified (report-only): a firefox.exe at the default
        # path may belong to a different installation.
        # Machine scope only after the install path is positively inside Program Files. Registered under HKLM is not
        # enough: a copy in a profile, or one whose location is unknown, is user-writable or unverified, so report-only.
        $probe = if ($exe) { $exe } elseif (-not $msi) { ([string]$k.Uninstall).Trim('"') } else { '' }
        $scope = 'user'; $owner = ''
        if ($probe -and (Test-AcProgramFiles -Path $probe)) { $scope = 'machine' }
        elseif ($probe -match '(?i)[\\/]Users[\\/]([^\\/]+)') { $owner = $Matches[1] }
        $installs += [pscustomobject]@{ Id = "m$n"; Version = $ver; Scope = $scope; User = $owner; Path = $exe; Uninstall = $k.Uninstall; Key = $k.Key; Msi = $msi }
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
    return $out
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
    # A per-user copy sits in a user-writable tree: SYSTEM neither runs nor recursively deletes there (junction swap). 4 = left for user context.
    if ($Install.Scope -eq 'user') { return 4 }
    if ($Install.Msi) { return Invoke-AcProcess -File "$env:SystemRoot\System32\msiexec.exe" -Arguments "/x $($Install.Key) /qn /norestart" }
    $helper = if ($Install.Uninstall -match '"?([^"]+helper\.exe)') { $Matches[1] } else { '' }
    if (-not $helper -or -not (Test-Path -LiteralPath $helper)) { return 2 }
    if (-not (Test-AcProgramFiles -Path $helper)) { return 4 }
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
            if ($code -ne 0 -and $code -ne 3010 -and $code -ne 4) { $failed++ }
        }
        $rows += [ordered]@{ scope = $i.Scope; user = $i.User; version = $i.Version; path = $i.Path; msi = $i.Msi; action = $p.Action; reason = $p.Reason; result = $res }
    }
    $after = $null
    if ($Fix) {
        $left = @(Get-AcFirefoxInventory)
        $after = @($left | ForEach-Object { "$($_.Version) $($_.Path)" })
        # A removal that exited 0 but left that same copy behind is a failure; skipped and kept copies are not.
        for ($x = 0; $x -lt $installs.Count; $x++) {
            if ($rows[$x].result -ne 'exit 0' -and $rows[$x].result -ne 'exit 3010') { continue }
            $i = $installs[$x]
            if (@($left | Where-Object { ($i.Key -and $_.Key -eq $i.Key) -or ($i.Path -and $_.Path -eq $i.Path) }).Count -gt 0) { $failed++; $rows[$x].result += ' but still present' }
        }
    }
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
            $res = "exit $c"
            $still = (Test-Path -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$code") -or (Test-Path -LiteralPath "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\$code")
            if (($c -ne 0 -and $c -ne 3010) -or $still) { $failed++; if ($still) { $res += ' but still present' } }
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
            $row.action = 'user-context'
            $row.result = 'not removed: per-user copy, remove it in the user session'
        }
        $rows += $row
    }
    return [ordered]@{ items = $rows; failed = $failed }
}

function Invoke-Main {
    param([switch]$Fix, [string]$Target, [int]$CurrentMajor, [int]$IdleDays)
    try {
        $rec = [ordered]@{ mode = $(if ($Fix) { 'fix' } else { 'check' }); host = $env:COMPUTERNAME; version = '1.0' }
        $failed = 0
        if ($Target -ne 'teams') { $rec.firefox = Invoke-AcFirefox -Fix:$Fix -CurrentMajor $CurrentMajor -IdleDays $IdleDays; $failed += $rec.firefox.failed }
        if ($Target -ne 'firefox') { $rec.teams = Invoke-AcTeams -Fix:$Fix; $failed += $rec.teams.failed }
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
