# Remediation module, run by windows/runner/Invoke-RelianJob.ps1 as SYSTEM. Removes the retired N-able
# N-sight RMM agent ("Advanced Monitoring Agent", its GP installer, Web Protection, Network Management,
# File Cache, patch and Take Control parts). First the vendor uninstallers (msiexec /x, or the Inno
# unins000.exe), then, for anything left, its services, folders and Add/Remove Programs keys.
# Only names and folders on the lists below are touched. Anything naming NinjaOne, SentinelOne, Global
# Secure Access, WireGuard or Wazuh is refused even if it matches. A machine without the agent reports
# compliant. Exit 0 compliant or removed, 1 drift with -ReportOnly, 2 failed. Prints one JSON line.
# An Add/Remove Programs key whose software is gone (no uninstaller, or the uninstaller failed and its files
# are gone, and no agent service remains) is deleted after its values are backed up to a new JSON file under
# C:\ProgramData\Relian\NableUninstallKeyBackup. No backup, no delete. For an MSI entry the matching
# Installer\Products registration goes too, but only when the cached package is missing; else it is reported.
[CmdletBinding()]
param([switch]$ReportOnly)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Add/Remove Programs names of the agent and its parts. A name on the first list matches alone. A part
# name on the second list is generic, so it matches only with an agent publisher. The publisher never
# matches alone: the same vendors ship other products (backup, for one) that must not be uninstalled.
$script:NaNamePattern = '(?i)\A(Advanced Monitoring Agent\b.*|Take Control Agent\b.*|N-able Take Control\b.*|BeAnywhere Support Express\b.*)\z'
$script:NaPartPattern = '(?i)\A(Request Handler Agent|File Cache Service Agent|Patch Management Service Controller)\z'
$script:NaPublisherPattern = '(?i)\A(Remote Monitoring Services|SolarWinds MSP|N-able Technologies|LogicNow( Ltd)?|BeAnywhere)\z'
# Agent folders, as a path under Program Files (either view) or ProgramData. The vendor roots hold
# other products too (backup, for one), so only the agent's own subfolders of them match, never the root.
$script:NaVendorRoots = @('SolarWinds MSP', 'N-able Technologies')
$script:NaFolderPattern = '(?i)\A(Advanced Monitoring Agent[^\\]*|BeAnywhere Support Express|Take Control Agent|MspPlatform|GetSupportService[^\\]*|(SolarWinds MSP|N-able Technologies)\\(Ecosystem Agent|PME|Cache Service|RpcServer|Take Control Agent))\z'
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
                        Uninstall = [string]$key.GetValue('UninstallString'); InstallLocation = [string]$key.GetValue('InstallLocation')
                        Msi = ([string]$key.GetValue('WindowsInstaller') -eq '1')
                    }
                } finally { $key.Dispose() }
            }
        } finally { $parent.Dispose() }
    }
}

$script:NaBackupDir = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'Relian\NableUninstallKeyBackup'
$script:NaProductsRoot = 'SOFTWARE\Classes\Installer\Products'
$script:NaUserDataRoot = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products'

# Every value of one key as @{ name; kind; data }. Binary is base64. A key with subkeys throws: the backup
# would not hold it all. A denied or missing key throws too, so nothing is deleted on a blind read.
$script:NaReadKeyValues = {
    param($Path)
    $key = (Open-NaHklm).OpenSubKey($Path)
    if (-not $key) { throw 'key not found' }
    try {
        if ($key.SubKeyCount) { throw 'key has subkeys' }
        foreach ($name in $key.GetValueNames()) {
            $data = $key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            if ($data -is [byte[]]) { $data = [Convert]::ToBase64String($data) }
            @{ name = $name; kind = [string]$key.GetValueKind($name); data = $data }
        }
    } finally { $key.Dispose() }
}

$script:NaProtectDir = {
    param($Path)
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetSecurityDescriptorSddlForm('D:P(A;OICI;FA;;;SY)')
    Set-Acl -LiteralPath $Path -AclObject $acl
}

# The cached package path of a product, '' when the value is absent, $null when the product has no
# InstallProperties key.
$script:NaReadLocalPackage = {
    param($Packed)
    $key = (Open-NaHklm).OpenSubKey("$script:NaUserDataRoot\$Packed\InstallProperties")
    if (-not $key) { return $null }
    try { return [string]$key.GetValue('LocalPackage') } finally { $key.Dispose() }
}

$script:NaHasProduct = {
    param($Packed)
    $key = (Open-NaHklm).OpenSubKey("$script:NaProductsRoot\$Packed")
    if ($key) { $key.Dispose(); return $true }
    return $false
}

$script:NaDeleteProduct = { param($Packed) (Open-NaHklm).DeleteSubKeyTree("$script:NaProductsRoot\$Packed", $false) }

$script:NaDeleteKey = { param($Path) (Open-NaHklm).DeleteSubKeyTree($Path, $false) }

$script:NaReadServices = {
    foreach ($s in @(Get-CimInstance -ClassName Win32_Service -ErrorAction Stop)) {
        [pscustomobject]@{ Name = [string]$s.Name; DisplayName = [string]$s.DisplayName; Path = [string]$s.PathName; ProcessId = [int]$s.ProcessId }
    }
}

$script:NaReadDependents = {
    param($Name)
    @((Get-Service -Name $Name -ErrorAction Stop).DependentServices | ForEach-Object { $_.Name })
}

$script:NaRemoveService = {
    param($Service)
    # -Force stops dependent services too, so every one of them must be an agent service.
    if (-not (Test-NaStopAllowed @(Get-NaAllDependents $Service.Name) @(& $script:NaReadServices))) {
        throw "a service outside the agent depends on $($Service.Name)"
    }
    Stop-Service -Name $Service.Name -Force -ErrorAction SilentlyContinue
    # The PID is read again after the stop, never taken from the earlier snapshot.
    $killId = Get-NaServiceKillId $Service.Name @(& $script:NaReadServices)
    if ($killId -gt 0) { Stop-Process -Id $killId -Force -ErrorAction SilentlyContinue }
    $null = & sc.exe delete $Service.Name
}

$script:NaFolderParents = {
    @(${env:ProgramFiles(x86)}, $env:ProgramW6432, $env:ProgramFiles, $env:ProgramData) | Where-Object { $_ } | Sort-Object -Unique
}

$script:NaListFolders = {
    param($Parent)
    $base = $Parent.TrimEnd('\')
    foreach ($dir in @($base) + @($script:NaVendorRoots | ForEach-Object { "$base\$_" })) {
        $item = Get-Item -LiteralPath $dir -Force -ErrorAction SilentlyContinue
        # A reparse point is not followed: it could lead outside the agent's folder.
        if (-not $item -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { continue }
        Get-ChildItem -LiteralPath $dir -Directory -Force -ErrorAction Stop |
            Where-Object { $_.FullName.Substring($base.Length + 1) -match $script:NaFolderPattern -and -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } |
            ForEach-Object { $_.FullName }
    }
}

$script:NaReadProcesses = {
    foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) {
        $path = try { [string]$p.Path } catch { '' }
        [pscustomobject]@{ Id = $p.Id; Path = $path }
    }
}

$script:NaRemoveFolder = {
    param($Path)
    # Processes running from the folder hold their files open. One that hosts a non-agent service is
    # spared; its open files then make Remove-Item fail, and the folder is reported.
    foreach ($id in @(Get-NaFolderKillIds $Path @(& $script:NaReadProcesses) @(& $script:NaReadServices))) {
        Stop-Process -Id $id -Force -ErrorAction SilentlyContinue
    }
    Remove-NaTree $Path
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
# A path that cannot be tested counts as present: the key is then kept.
$script:NaPathExists = { param($Path) try { Test-Path -LiteralPath $Path } catch { $true } }

function Test-NaAppEntry {
    param($Entry)
    if (-not $Entry.Name -or (Test-NaProtected "$($Entry.Name) $($Entry.Publisher) $($Entry.Uninstall)")) { return $false }
    return ($Entry.Name -match $script:NaNamePattern) -or ($Entry.Name -match $script:NaPartPattern -and $Entry.Publisher -match $script:NaPublisherPattern)
}

# True when the path sits inside an agent folder under Program Files or ProgramData. A same-named
# folder anywhere else is another product's.
function Test-NaInAgentFolder {
    param([AllowEmptyString()][string]$Path)
    foreach ($parent in & $script:NaFolderParents) {
        $prefix = $parent.TrimEnd('\') + '\'
        if (-not $Path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { continue }
        $parts = $Path.Substring($prefix.Length).Split('\')
        if ($parts.Count -ge 2 -and $parts[0] -match $script:NaFolderPattern) { return $true }
        if ($parts.Count -ge 3 -and "$($parts[0])\$($parts[1])" -match $script:NaFolderPattern) { return $true }
    }
    return $false
}

# Every service -Force would stop, at any depth. EnumDependentServices may already list indirect ones;
# walking the graph here does not rely on that. A cycle stops at a name already seen.
function Get-NaAllDependents {
    param([string]$Name)
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $queue = [Collections.Generic.Queue[string]]::new()
    $queue.Enqueue($Name)
    while ($queue.Count) {
        foreach ($dep in @(& $script:NaReadDependents $queue.Dequeue())) {
            if ($dep -and $dep -ne $Name -and $seen.Add($dep)) { $queue.Enqueue($dep) }
        }
    }
    return @($seen)
}

# Deletes a folder tree without following links: Remove-Item -Recurse in Windows PowerShell 5.1
# walks into a junction and deletes its target's files. A linked folder inside loses only the link.
function Remove-NaTree {
    param([string]$Path)
    foreach ($item in ([IO.DirectoryInfo]::new($Path)).GetFileSystemInfos()) {
        if ($item -is [IO.DirectoryInfo]) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { [IO.Directory]::Delete($item.FullName, $false) }
            else { Remove-NaTree $item.FullName }
        } else {
            $item.Attributes = [IO.FileAttributes]::Normal
            $item.Delete()
        }
    }
    [IO.Directory]::Delete($Path, $false)
}

# True when every dependent service name is an agent service.
function Test-NaStopAllowed {
    param($Dependents, $Services)
    foreach ($name in @($Dependents)) {
        $svc = @($Services | Where-Object { $_.Name -eq $name })
        if ($svc.Count -ne 1 -or -not (Test-NaServiceEntry $svc[0])) { return $false }
    }
    return $true
}

# Processes running from the folder that host no service outside the agent.
function Get-NaFolderKillIds {
    param([string]$Folder, $Processes, $Services)
    foreach ($p in @($Processes)) {
        if (-not $p.Path -or -not $p.Path.StartsWith($Folder + '\', [StringComparison]::OrdinalIgnoreCase)) { continue }
        if (@($Services | Where-Object { $_.ProcessId -eq $p.Id -and -not (Test-NaServiceEntry $_) }).Count) { continue }
        $p.Id
    }
}

# True when a service still installed runs from the folder: a protected service, or one whose removal
# was refused. Deleting the folder would leave that service broken, so the folder stays.
function Test-NaFolderInUse {
    param([string]$Folder, $Services)
    foreach ($svc in @($Services)) {
        if ((Get-NaExecutable "$($svc.Path)").StartsWith($Folder + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

# The live process to stop for a service, or 0. A stopped service has no process. A process that also
# hosts another service is not stopped: killing it would take that service down too.
function Get-NaServiceKillId {
    param([string]$Name, $Services)
    $live = @($Services | Where-Object { $_.Name -eq $Name })
    if ($live.Count -ne 1 -or $live[0].ProcessId -le 0) { return 0 }
    if (@($Services | Where-Object { $_.ProcessId -eq $live[0].ProcessId }).Count -ne 1) { return 0 }
    return $live[0].ProcessId
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

# Windows Installer's packed GUID: the first three groups reversed, the rest with each byte's two digits swapped.
function ConvertTo-NaPackedGuid {
    param([string]$Guid)
    $m = [regex]::Match($Guid, '\A\{([0-9A-Fa-f]{8})-([0-9A-Fa-f]{4})-([0-9A-Fa-f]{4})-([0-9A-Fa-f]{4})-([0-9A-Fa-f]{12})\}\z')
    if (-not $m.Success) { throw "not a product code: $Guid" }
    $rev = { param($t) $a = $t.ToCharArray(); [Array]::Reverse($a); -join $a }
    $tail = ($m.Groups[4].Value + $m.Groups[5].Value) -replace '(.)(.)', '$2$1'
    return ((& $rev $m.Groups[1].Value) + (& $rev $m.Groups[2].Value) + (& $rev $m.Groups[3].Value) + $tail).ToUpperInvariant()
}

# Why a key left after the removal steps is proven orphaned, or $null when it is not. The key may be the
# only sign the software is still installed, so any doubt keeps it.
function Get-NaOrphanReason {
    param($Entry, $Attempted, $Services)
    if (Test-NaProtected "$($Entry.Name) $($Entry.Publisher) $($Entry.Uninstall)") { return $null }
    if (@($Services).Count) { return $null }
    if (Test-NaOrphanKey $Entry) { return 'uninstaller gone' }
    $isMsi = $Entry.Msi -and $Entry.Id -match '\A\{[0-9A-Fa-f-]{36}\}\z'
    if (-not $Entry.Uninstall -and -not $isMsi) { return 'no uninstaller' }
    if (-not (@($Attempted) -contains $Entry.Key)) { return $null }
    $prop = $Entry.PSObject.Properties['InstallLocation']
    $paths = @(if ($prop -and $prop.Value) { ([string]$prop.Value).TrimEnd('\') })
    $exe = Get-NaExecutable "$($Entry.Uninstall)"
    if ($exe -and $exe -notmatch '(?i)(\A|\\)msiexec(\.exe)?\z') { $paths += $exe }
    foreach ($path in $paths) { if (& $script:NaPathExists $path) { return $null } }
    if ($paths.Count) { return 'uninstall failed, files gone' }
    return $null
}

# Writes the key's values to a new file and reads it back. CreateNew: nothing is overwritten. Throws on failure.
function Write-NaBackup {
    param([string]$KeyPath, $Values)
    $null = New-Item -ItemType Directory -Path $script:NaBackupDir -Force
    & $script:NaProtectDir $script:NaBackupDir
    $name = 'backup-{0}-{1}.json' -f [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ'), [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $path = Join-Path $script:NaBackupDir $name
    $want = @($Values)
    $doc = [ordered]@{ schemaVersion = 1; createdUtc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'); key = "HKLM\$KeyPath"; values = $want }
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes(($doc | ConvertTo-Json -Depth 5))
    $stream = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush() } finally { $stream.Dispose() }
    $back = (Get-Content -LiteralPath $path -Raw -Encoding UTF8) | ConvertFrom-Json
    $got = @($back.values)
    $flat = { param($v) "$($v.name)|$($v.kind)|$(@($v.data) -join [char]0)" }
    if ($back.key -ne $doc.key -or $got.Count -ne $want.Count) { throw 'backup read-back differs' }
    for ($i = 0; $i -lt $want.Count; $i++) { if ((& $flat $want[$i]) -ne (& $flat $got[$i])) { throw 'backup read-back differs' } }
    return $name
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
    $kept = @(); $backups = @()
    try {
        $state = Get-NaState
        if (Test-NaClean $state) {
            $status = 'compliant'; $exitCode = 0
        } elseif ($ReportOnly) {
            $status = 'drift'; $exitCode = 1
        } else {
            $attempted = [Collections.Generic.List[string]]::new()
            $kept = [Collections.Generic.List[string]]::new()
            $backups = [Collections.Generic.List[string]]::new()
            # 1. Vendor uninstallers. The re-detect below decides the result, not their exit codes.
            foreach ($entry in $state.Apps) {
                $cmd = Get-NaUninstallCommand $entry
                if (-not $cmd) { $log.Add("no uninstaller: $($entry.Name)"); continue }
                if ($cmd.File -ne 'msiexec.exe' -and -not (& $script:NaFileExists $cmd.File)) { $log.Add("uninstaller missing: $($entry.Name)"); continue }
                $code = & $script:NaRun $cmd.File $cmd.Arguments
                $attempted.Add($entry.Key)
                $log.Add("uninstall $($entry.Name) exit $code")
            }
            if ($state.Apps.Count) { & $script:NaSettle }
            # 2. Whatever the uninstallers left: services, then folders, then Add/Remove Programs keys.
            $left = Get-NaState
            foreach ($svc in $left.Services) {
                try { & $script:NaRemoveService $svc; $log.Add("service deleted: $($svc.Name)") } catch { $log.Add("service kept: $($svc.Name)") }
            }
            $stillInstalled = @(& $script:NaReadServices)
            foreach ($dir in $left.Folders) {
                if (Test-NaFolderInUse $dir $stillInstalled) { $log.Add("folder kept: $dir"); continue }
                try { & $script:NaRemoveFolder $dir; $log.Add("folder removed: $dir") } catch { $log.Add("folder failed: $dir") }
            }
            # Services are read again: a service the steps above could not remove blocks every key delete.
            $svcNow = @(& $script:NaReadServices | Where-Object { Test-NaServiceEntry $_ })
            foreach ($entry in $left.Apps) {
                $why = Get-NaOrphanReason $entry $attempted $svcNow
                if (-not $why) { $log.Add("uninstall key kept: $($entry.Name)"); continue }
                try {
                    $backups.Add((Write-NaBackup $entry.Key @(& $script:NaReadKeyValues $entry.Key)))
                    & $script:NaDeleteKey $entry.Key
                    $log.Add("uninstall key removed: $($entry.Name) ($why)")
                } catch { $log.Add("uninstall key kept: $($entry.Name) (backup or delete failed)"); continue }
                if ($entry.Msi -and $entry.Id -match '\A\{[0-9A-Fa-f-]{36}\}\z') {
                    try {
                        $packed = ConvertTo-NaPackedGuid $entry.Id
                        if (& $script:NaHasProduct $packed) {
                            $pkg = & $script:NaReadLocalPackage $packed
                            if ($null -eq $pkg) { $kept.Add("Installer Products $packed kept: no InstallProperties, package unknown") }
                            elseif ($pkg -and (& $script:NaFileExists $pkg)) { $kept.Add("Installer Products $packed kept: cached package on disk") }
                            else { & $script:NaDeleteProduct $packed; $log.Add("installer product removed: $packed") }
                        }
                    } catch { $kept.Add("Installer Products for $($entry.Id) kept: $($_.Exception.Message)") }
                }
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
        Folders = @($state.Folders); Log = @($log); Left = @($kept); Backups = @($backups); Error = $problem
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
        log = @(& $cut $Result.Log 30 100); left = @(& $cut $Result.Left 10 100); backups = @(& $cut $Result.Backups 10 64); error = Get-NaSafeText $Result.Error 200
    } | ConvertTo-Json -Compress
}

# Dot-sourcing under test defines functions and changes nothing.
if ($env:RELIAN_DEPLOY_TEST -eq '1' -and $MyInvocation.InvocationName -eq '.') {
    return
}

$jobResult = Invoke-NableRemovalJob -ReportOnly:$ReportOnly
Write-Output (ConvertTo-NableJobLine $jobResult)
exit $jobResult.ExitCode
