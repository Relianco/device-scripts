<#
.SYNOPSIS
    Reports on a departed user's profile and, with Fix, removes only that user's per-user Firefox program folder and its
    HKLM uninstall entry, for the Relian deploy runner (NinjaOne script 374). One-off, hash-pinned by the caller.

.DESCRIPTION
    The runner passes DeploymentType, Action and PinVersion, then each PackageArguments pair as -Name value (all strings):
    User (the account name, as in C:\Users\<User>), Fix ("true" removes; anything else reports only).

    Report (always): profile size, Firefox profile size, sizes of the top folders under the profile, whether OneDrive is
    present, and how many files under Desktop, Documents and Downloads are NOT inside a OneDrive folder (so the owner can decide
    on retention). Nothing is deleted or read beyond names, sizes and dates.

    Fix removes C:\Users\<User>\AppData\Local\Mozilla Firefox and ...\Programs\Mozilla Firefox (when present) and the HKLM
    Uninstall entries whose install location is one of those folders. It never touches the profile or any other file. As SYSTEM,
    it refuses (exit 1, nothing changed) unless ALL of these hold:
      - the account exists in the domain and is disabled (userAccountControl bit 2). An unreachable directory refuses.
      - no interactive logon session exists on the PC, for anyone (active or disconnected), and the session list was readable.
      - no process runs from the Firefox folder.
      - neither the user's profile folder nor any folder down to the Firefox folder is a reparse point.
    The user name must be a plain account name (letters, digits, dot, dash, underscore).

    The result is one line of compact JSON, printed last on stdout. Exit 1 when a guard refused or a removal failed.

.NOTES
    Requirements: Windows PowerShell 5.1+, run as SYSTEM on a domain-joined PC
#>

# Not Mandatory: a mandatory param block prompts when this file is dot-sourced under RELIAN_DEPLOY_TEST.
[CmdletBinding()]
param(
    [string]$DeploymentType,
    [string]$Action,
    [string]$PinVersion,
    [string]$User = '',
    [string]$Fix = ''
)

$ProgressPreference = 'SilentlyContinue'

# Pure: 'none', 'report' or 'fix'. Empty PinVersion is the off switch. Throws on bad input.
function Get-DuMode {
    param([string]$Action, [string]$Fix, [string]$User, [string]$PinVersion = '1.0.0')
    if ([string]::IsNullOrWhiteSpace($PinVersion)) { return 'none' }
    if (@('Install', 'Update', 'Repair', 'Reinstall', 'Uninstall') -notcontains $Action) { throw 'Action must be Install, Update, Repair, Reinstall, or Uninstall.' }
    if ($User -notmatch '^[A-Za-z0-9._-]{1,64}$' -or $User -match '^\.+$') { throw 'User must be a plain account name.' }
    if ($Fix -ne '' -and $Fix -ne 'true' -and $Fix -ne 'false') { throw 'Fix must be true or false.' }
    if ($Action -eq 'Uninstall') { return 'none' }
    if ($Fix -eq 'true') { return 'fix' }
    return 'report'
}

# Seams for unit tests.
function Get-DuUsersRoot { Join-Path $env:SystemDrive 'Users' }
function Get-DuAccountDisabled {
    # $true / $false, or $null when the directory cannot answer (a missing account is $null as well: refuse).
    param([string]$User)
    try {
        $s = [adsisearcher]"(&(objectCategory=person)(objectClass=user)(sAMAccountName=$User))"
        $s.PropertiesToLoad.Add('useraccountcontrol') | Out-Null
        $r = @($s.FindAll())
        if ($r.Count -ne 1) { return $null }
        return (([int]$r[0].Properties['useraccountcontrol'][0]) -band 2) -eq 2
    } catch { return $null }
}
function Get-DuSessionCount {
    # Interactive logon sessions (console, remote, cached; active or disconnected). $null when unreadable.
    try { return @(Get-CimInstance -ClassName Win32_LogonSession -ErrorAction Stop | Where-Object { @(2, 10, 11, 12, 13) -contains [int]$_.LogonType }).Count }
    catch { return $null }
}
function Get-DuProcessPaths {
    # $null when the process list cannot be read: the caller refuses (an empty list would mean "nothing runs").
    # The comma keeps an empty list an empty array instead of $null.
    try { return ,@(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object { $_.ExecutablePath } | ForEach-Object { [string]$_.ExecutablePath }) }
    catch { return $null }
}
function Get-DuUninstallKeys {
    foreach ($root in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall') {
        Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue | ForEach-Object {
            $p = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue
            if ($p -and ([string]$p.DisplayName) -like 'Mozilla Firefox*') { [pscustomobject]@{ Path = $_.PSPath; Location = [string]$p.InstallLocation; Uninstall = [string]$p.UninstallString } }
        }
    }
}
function Get-DuFolderBytes {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    $sum = [int64]0
    foreach ($f in @(Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue)) { $sum += [int64]$f.Length }
    return $sum
}
function Test-DuReparse { param([string]$Path) [bool]((Get-Item -LiteralPath $Path -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint) }

# Folders that may be removed for this user, under the profile root only.
function Get-DuFirefoxFolders {
    param([string]$Profile)
    @('AppData\Local\Mozilla Firefox', 'AppData\Local\Programs\Mozilla Firefox' | ForEach-Object { Join-Path $Profile $_ } | Where-Object { Test-Path -LiteralPath $_ })
}

# Pure-ish guard check: returns the list of reasons the removal must be refused (empty = allowed).
function Get-DuRefusals {
    param([string]$User, [string]$Profile, [string[]]$Folders)
    $why = @()
    if (-not (Test-Path -LiteralPath $Profile)) { return @('profile folder not found') }
    $disabled = Get-DuAccountDisabled -User $User
    if ($null -eq $disabled) { $why += 'account not found or directory unreachable' } elseif (-not $disabled) { $why += 'account is enabled' }
    $sessions = Get-DuSessionCount
    if ($null -eq $sessions) { $why += 'session list unreadable' } elseif ($sessions -gt 0) { $why += "interactive sessions exist ($sessions)" }
    $procs = Get-DuProcessPaths
    if ($null -eq $procs) { $why += 'process list unreadable' }
    foreach ($f in $Folders) {
        $running = @(@($procs | Where-Object { $_ }) | Where-Object { $_.StartsWith($f + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase) })
        if ($running.Count) { $why += "a process runs from $f" }
        for ($d = $f; $d.Length -ge $Profile.Length; $d = Split-Path -Parent $d) {
            if (Test-DuReparse -Path $d) { $why += "reparse point on the path: $d"; break }
            if ($d.Length -eq $Profile.Length) { break }
        }
    }
    return $why
}

function Get-DuReport {
    param([string]$Profile)
    $fox = Join-Path $Profile 'AppData\Roaming\Mozilla\Firefox'
    $top = @(Get-ChildItem -LiteralPath $Profile -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object { [ordered]@{ name = $_.Name; mb = [int]((Get-DuFolderBytes -Path $_.FullName) / 1MB) } })
    $oneDrive = @(Get-ChildItem -LiteralPath $Profile -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'OneDrive*' } | ForEach-Object { $_.Name })
    $outside = [ordered]@{}
    foreach ($n in 'Desktop', 'Documents', 'Downloads') {
        $p = Join-Path $Profile $n
        if (-not (Test-Path -LiteralPath $p)) { $outside[$n] = 0; continue }
        # A redirected known folder is a reparse point into OneDrive; its files are not "outside".
        if (Test-DuReparse -Path $p) { $outside[$n] = 0; continue }
        $outside[$n] = @(Get-ChildItem -LiteralPath $p -Recurse -File -Force -ErrorAction SilentlyContinue).Count
    }
    $latest = Get-ChildItem -LiteralPath $Profile -Recurse -File -Force -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    return [ordered]@{
        profileMB          = [int]((Get-DuFolderBytes -Path $Profile) / 1MB)
        firefoxProfileMB   = [int]((Get-DuFolderBytes -Path $fox) / 1MB)
        topFolders         = $top
        oneDriveFolders    = $oneDrive
        filesOutsideOneDrive = $outside
        newestFileWrite    = $(if ($latest) { $latest.LastWriteTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } else { $null })
    }
}

function Get-DuResult {
    param([string]$User, [switch]$Fix)
    $rec = [ordered]@{ mode = $(if ($Fix) { 'fix' } else { 'report' }); host = $env:COMPUTERNAME; user = $User; version = '1.0' }
    $code = 0
    $profile = Join-Path (Get-DuUsersRoot) $User
    $folders = @(Get-DuFirefoxFolders -Profile $profile)
    $rec.firefoxFolders = $folders
    $rec.report = if (Test-Path -LiteralPath $profile) { Get-DuReport -Profile $profile } else { $null }
    if ($Fix) {
        $why = @(Get-DuRefusals -User $User -Profile $profile -Folders $folders)
        $rec.refused = $why
        if ($why.Count) { $code = 1 }
        else {
            $removed = @(); $failed = 0
            foreach ($k in @(Get-DuUninstallKeys | Where-Object { $loc = $_.Location.TrimEnd([char]92, [char]47); $loc -and (@($folders | Where-Object { $_ -ieq $loc }).Count) })) {
                Remove-Item -LiteralPath $k.Path -Recurse -Force -ErrorAction SilentlyContinue
                if (Test-Path -LiteralPath $k.Path) { $failed++; $removed += "uninstall entry still present: $($k.Path)" } else { $removed += "uninstall entry $($k.Path | Split-Path -Leaf)" }
            }
            foreach ($f in $folders) {
                try { [System.IO.Directory]::Delete($f, $true) } catch { }
                if (Test-Path -LiteralPath $f) { $failed++; $removed += "still present: $f" } else { $removed += "removed $f" }
            }
            $rec.actions = $removed
            if ($failed) { $code = 1 }
        }
    }
    $rec.timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    return [ordered]@{ record = $rec; exitCode = $code }
}

function Invoke-DuMain {
    param([string]$User, [switch]$Fix)
    $run = Get-DuResult -User $User -Fix:$Fix
    Write-Output ($run.record | ConvertTo-Json -Depth 6 -Compress)
    exit $run.exitCode
}

if ($env:RELIAN_DEPLOY_TEST -ne '1') {
    try { $duMode = Get-DuMode -Action $Action -Fix $Fix -User $User -PinVersion $PinVersion }
    catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }
    if ($duMode -eq 'none') { Write-Output 'Nothing to change. Nothing was installed.'; exit 0 }
    Invoke-DuMain -User $User -Fix:($duMode -eq 'fix')
}
