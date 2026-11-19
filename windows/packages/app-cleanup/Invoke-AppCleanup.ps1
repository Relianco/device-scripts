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

    Teams: removes the classic Teams Machine-Wide Installer (msiexec /x) and each user's classic copy
    (Update.exe --uninstall -s). A user's copy is skipped while that user's classic Teams runs. New Teams
    (ms-teams) is never touched.

    The runner passes DeploymentType, Action and PinVersion, then each PackageArguments pair as -Name value:
    Target, Fix, CurrentMajor, IdleDays (all strings). Install, Update, Repair and Reinstall run the check
    (and the fix when Fix is "true"); Uninstall changes nothing and exits 0.

    The result is one line of compact JSON, printed last on stdout. Exit 1 when a removal failed or a
    copy was still present after Fix.

.NOTES
    Requirements: Windows PowerShell 5.1+, run as SYSTEM
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
