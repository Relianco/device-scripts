# Remediation module, run by windows/runner/Invoke-RelianJob.ps1 as SYSTEM. Removes the retired N-able
# N-sight RMM agent ("Advanced Monitoring Agent", its GP installer, Web Protection, Network Management,
# File Cache, patch and Take Control parts). First the vendor uninstallers (msiexec /x, or the Inno
# unins000.exe), then, for anything left, its services, folders and Add/Remove Programs keys.
# Only names and folders on the lists below are touched. Anything naming NinjaOne, SentinelOne, Global
# Secure Access, WireGuard or Wazuh is refused even if it matches. A machine without the agent reports
# compliant. Exit 0 compliant or removed, 1 drift with -ReportOnly, 2 failed. Prints one JSON line.
[CmdletBinding()]
param([switch]$ReportOnly)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Add/Remove Programs names and publishers of the agent and its parts. Generic part names such as
# "Request Handler Agent" match through the publisher only.
$script:NaNamePattern = '(?i)\A(Advanced Monitoring Agent\b.*|Take Control Agent\b.*|N-able Take Control\b.*|BeAnywhere Support Express\b.*)\z'
$script:NaPublisherPattern = '(?i)\A(Remote Monitoring Services|SolarWinds MSP|N-able Technologies|LogicNow( Ltd)?|BeAnywhere)\z'
# Agent folders: a direct child of Program Files (either view) or ProgramData with one of these names.
$script:NaFolderPattern = '(?i)\A(Advanced Monitoring Agent[^\\]*|BeAnywhere Support Express|Take Control Agent|MspPlatform|SolarWinds MSP|N-able Technologies|GetSupportService[^\\]*)\z'
$script:NaServicePattern = '(?i)\A(Advanced Monitoring Agent.*|BASupportExpress.*|GetSupportService.*)\z'
# Never touched, whatever else matches.
$script:NaProtectedPattern = '(?i)ninja|sentinel|global secure access|wireguard|wazuh'

$script:NaUninstallRoots = @(
    'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
    'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
)

function Test-NaProtected { param([AllowEmptyString()][string]$Text) return $Text -match $script:NaProtectedPattern }

# Ninja's PowerShell bitness is unconfirmed. Registry64 reaches both views from either.
function Open-NaHklm {
    [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
}

$script:NaReadUninstall = {
    $hklm = Open-NaHklm
    foreach ($root in $script:NaUninstallRoots) {
        $parent = $hklm.OpenSubKey($root)
        if (-not $parent) { continue }
        try {
            foreach ($sub in $parent.GetSubKeyNames()) {
                $key = $parent.OpenSubKey($sub)
                if (-not $key) { continue }
                try {
                    [pscustomobject]@{
                        Key = "$root\$sub"; Id = $sub
                        Name = [string]$key.GetValue('DisplayName'); Publisher = [string]$key.GetValue('Publisher')
                        Uninstall = [string]$key.GetValue('UninstallString')
                        Msi = ([string]$key.GetValue('WindowsInstaller') -eq '1')
                    }
                } finally { $key.Dispose() }
            }
        } finally { $parent.Dispose() }
    }
}

$script:NaDeleteKey = { param($Path) (Open-NaHklm).DeleteSubKeyTree($Path, $false) }

$script:NaReadServices = {
    foreach ($s in @(Get-CimInstance -ClassName Win32_Service -ErrorAction Stop)) {
        [pscustomobject]@{ Name = [string]$s.Name; DisplayName = [string]$s.DisplayName; Path = [string]$s.PathName; ProcessId = [int]$s.ProcessId }
    }
}

$script:NaRemoveService = {
    param($Service)
    Stop-Service -Name $Service.Name -Force -ErrorAction SilentlyContinue
    if ($Service.ProcessId -gt 0) { Stop-Process -Id $Service.ProcessId -Force -ErrorAction SilentlyContinue }
    $null = & sc.exe delete $Service.Name
}

$script:NaFolderParents = {
    @(${env:ProgramFiles(x86)}, $env:ProgramW6432, $env:ProgramFiles, $env:ProgramData) | Where-Object { $_ } | Sort-Object -Unique
}

$script:NaListFolders = {
    param($Parent)
    if (-not (Test-Path -LiteralPath $Parent)) { return }
    # A reparse point is not followed: it could lead outside the agent's folder.
    Get-ChildItem -LiteralPath $Parent -Directory -Force -ErrorAction Stop |
        Where-Object { $_.Name -match $script:NaFolderPattern -and -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } |
        ForEach-Object { $_.FullName }
}

$script:NaRemoveFolder = {
    param($Path)
    # Processes running from the folder hold their files open.
    Get-Process -ErrorAction SilentlyContinue | Where-Object {
        try { $_.Path -and $_.Path.StartsWith($Path + '\', [StringComparison]::OrdinalIgnoreCase) } catch { $false }
    } | ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
}

# Runs an uninstaller and waits up to 10 minutes. Returns the exit code, or -1 on a timeout.
$script:NaRun = {
    param($File, [string[]]$Arguments)
    $p = Start-Process -FilePath $File -ArgumentList $Arguments -PassThru -WindowStyle Hidden
    if (-not $p.WaitForExit(600000)) { try { $p.Kill() } catch { }; return -1 }
    return $p.ExitCode
}

# The Inno uninstaller finishes in a child copy; give it a moment before the re-detect.
$script:NaSettle = { Start-Sleep -Seconds 10 }

$script:NaFileExists = { param($Path) Test-Path -LiteralPath $Path -PathType Leaf }

function Test-NaAppEntry {
    param($Entry)
    if (-not $Entry.Name -or (Test-NaProtected "$($Entry.Name) $($Entry.Publisher) $($Entry.Uninstall)")) { return $false }
    return ($Entry.Name -match $script:NaNamePattern) -or ($Entry.Publisher -match $script:NaPublisherPattern)
}

# True when the path sits inside an agent folder: a direct child of Program Files or ProgramData
# with an agent folder name. A same-named folder anywhere else is another product's.
function Test-NaInAgentFolder {
    param([AllowEmptyString()][string]$Path)
    foreach ($parent in & $script:NaFolderParents) {
        $prefix = $parent.TrimEnd('\') + '\'
        if (-not $Path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { continue }
        $rest = $Path.Substring($prefix.Length)
        $cut = $rest.IndexOf('\')
        if ($cut -gt 0 -and $rest.Substring(0, $cut) -match $script:NaFolderPattern) { return $true }
    }
    return $false
}

function Get-NaExecutable {
    param([AllowEmptyString()][string]$Command)
    ([regex]::Match($Command, '\A\s*(?:"(?<e>[^"]+)"|(?<e>.+?\.exe)(?=\s|\z)|(?<e>\S+))')).Groups['e'].Value
}

# The agent's service by name, or by an executable inside an agent folder.
function Test-NaServiceEntry {
    param($Service)
    if (Test-NaProtected "$($Service.Name) $($Service.DisplayName) $($Service.Path)") { return $false }
    if ($Service.Name -match $script:NaServicePattern) { return $true }
    return Test-NaInAgentFolder (Get-NaExecutable "$($Service.Path)")
}

# A leftover Add/Remove Programs key is deleted only when its uninstaller lived in an agent folder
# and that file is now gone. Otherwise the key may be the only sign the software is still installed,
# so it stays and the run fails. An MSI entry keeps its Windows Installer registration, so it stays too.
function Test-NaOrphanKey {
    param($Entry)
    if ($Entry.Msi -or $Entry.Uninstall -match '(?i)msiexec') { return $false }
    $exe = Get-NaExecutable "$($Entry.Uninstall)"
    return $exe -and (Test-NaInAgentFolder $exe) -and -not (& $script:NaFileExists $exe)
}

function Get-NaState {
    [pscustomobject]@{
        Apps = @(& $script:NaReadUninstall | Where-Object { Test-NaAppEntry $_ })
        Services = @(& $script:NaReadServices | Where-Object { Test-NaServiceEntry $_ })
        Folders = @(@(foreach ($parent in & $script:NaFolderParents) { & $script:NaListFolders $parent }) |
                Where-Object { $_ -and -not (Test-NaProtected $_) } | Sort-Object -Unique)
    }
}

function Test-NaClean { param($State) return ($State.Apps.Count + $State.Services.Count + $State.Folders.Count) -eq 0 }

# The vendor command for one entry: msiexec /x for an MSI, else the Inno uninstaller, silently.
function Get-NaUninstallCommand {
    param($Entry)
    if ($Entry.Id -match '\A\{[0-9A-Fa-f-]{36}\}\z' -and ($Entry.Msi -or $Entry.Uninstall -match '(?i)msiexec')) {
        return [pscustomobject]@{ File = 'msiexec.exe'; Arguments = @('/x', $Entry.Id, '/qn', '/norestart') }
    }
    $m = [regex]::Match("$($Entry.Uninstall)", '\A\s*(?:"(?<e>[^"]+)"|(?<e>.+?\.exe)(?=\s|\z))')
    if ($m.Success -and $m.Groups['e'].Value -match '(?i)\\unins\d{3}\.exe\z') {
        return [pscustomobject]@{ File = $m.Groups['e'].Value; Arguments = @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART') }
    }
    return $null
}

function Invoke-NableRemovalJob {
    param([switch]$ReportOnly)
    $log = [Collections.Generic.List[string]]::new()
    $state = [pscustomobject]@{ Apps = @(); Services = @(); Folders = @() }
    $status = 'failed'; $exitCode = 2; $problem = ''
    try {
        $state = Get-NaState
        if (Test-NaClean $state) {
            $status = 'compliant'; $exitCode = 0
        } elseif ($ReportOnly) {
            $status = 'drift'; $exitCode = 1
        } else {
            # 1. Vendor uninstallers. The re-detect below decides the result, not their exit codes.
            foreach ($entry in $state.Apps) {
                $cmd = Get-NaUninstallCommand $entry
                if (-not $cmd) { $log.Add("no uninstaller: $($entry.Name)"); continue }
                if ($cmd.File -ne 'msiexec.exe' -and -not (& $script:NaFileExists $cmd.File)) { $log.Add("uninstaller missing: $($entry.Name)"); continue }
                $code = & $script:NaRun $cmd.File $cmd.Arguments
                $log.Add("uninstall $($entry.Name) exit $code")
            }
            if ($state.Apps.Count) { & $script:NaSettle }
            # 2. Whatever the uninstallers left: services, then folders, then Add/Remove Programs keys.
            $left = Get-NaState
            foreach ($svc in $left.Services) { & $script:NaRemoveService $svc; $log.Add("service deleted: $($svc.Name)") }
            foreach ($dir in $left.Folders) {
                try { & $script:NaRemoveFolder $dir; $log.Add("folder removed: $dir") } catch { $log.Add("folder failed: $dir") }
            }
            foreach ($entry in $left.Apps) {
                if (Test-NaOrphanKey $entry) { & $script:NaDeleteKey $entry.Key; $log.Add("uninstall key removed: $($entry.Name)") }
                else { $log.Add("uninstall key kept: $($entry.Name)") }
            }
            $after = Get-NaState
            if (Test-NaClean $after) {
                $status = 'removed'; $exitCode = 0
            } else {
                $state = $after
                $problem = 'still present after removal'
            }
        }
    } catch {
        $problem = $_.Exception.Message
    }
    [pscustomobject]@{
        ExitCode = $exitCode; Status = $status; ReportOnly = [bool]$ReportOnly
        Apps = @($state.Apps | ForEach-Object { $_.Name }); Services = @($state.Services | ForEach-Object { $_.Name })
        Folders = @($state.Folders); Log = @($log); Error = $problem
    }
}

# Only characters JSON never escapes, so the cuts below bound the line on both PowerShell versions.
function Get-NaSafeText {
    param([AllowEmptyString()][string]$Text, [int]$Limit)
    $safe = $Text -replace '[^A-Za-z0-9 ._:()-]', '_'
    return $safe.Substring(0, [Math]::Min($safe.Length, $Limit))
}

function ConvertTo-NableJobLine {
    param([Parameter(Mandatory)]$Result)
    $cut = { param($Items, $Count, $Limit) @($Items | Select-Object -First $Count | ForEach-Object { Get-NaSafeText $_ $Limit }) }
    [ordered]@{
        job = 'nable-agent-removal'; status = $Result.Status; reportOnly = $Result.ReportOnly
        apps = @(& $cut $Result.Apps 10 64); services = @(& $cut $Result.Services 10 64); folders = @(& $cut $Result.Folders 10 100)
        log = @(& $cut $Result.Log 30 100); error = Get-NaSafeText $Result.Error 200
    } | ConvertTo-Json -Compress
}

# Dot-sourcing under test defines functions and changes nothing.
if ($env:RELIAN_DEPLOY_TEST -eq '1' -and $MyInvocation.InvocationName -eq '.') {
    return
}

$jobResult = Invoke-NableRemovalJob -ReportOnly:$ReportOnly
Write-Output (ConvertTo-NableJobLine $jobResult)
exit $jobResult.ExitCode
