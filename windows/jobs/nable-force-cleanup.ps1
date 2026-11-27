# Remediation module, run by windows/runner/Invoke-RelianJob.ps1 as SYSTEM, only after nable-agent-removal failed to
# remove an N-able product. Forced cleanup, the equivalent of Microsoft's install/uninstall troubleshooter: it deletes the
# registration of a product the vendor uninstaller cannot remove. It NEVER starts a process, runs no vendor binary and no
# msiexec; everything it does is a registry or file delete. It always means force mode (the loader forwards only -ReportOnly).
# A product is cleaned only when ALL hold: its DisplayName matches the N-able lists copied from nable-agent-removal, it is not
# protected (NinjaOne, SentinelOne, Global Secure Access, WireGuard, Wazuh are refused first), no N-able service exists, and
# the product is still registered. This module tries no uninstall itself: a product that is still registered is the evidence
# that the normal uninstall did not work, because the lead runs this job only after nable-agent-removal failed.
# Every key and file it will delete is first written to C:\ProgramData\Relian\NableForceBackup\<UTC stamp>-<code>\ (JSON plus a
# registry listing, and a verified copy of the cached package and of the bootstrapper folder; SYSTEM only, never overwritten, read back). Any backup failure: nothing is deleted, exit 2.
# -ReportOnly writes and deletes nothing, lists what would go in "removed", exit 1 (drift). Exit 0 compliant or removed, 2 failed.
# Prints one JSON line: job, status, removed, backups, left, error. Any matched key still present after the run is a failure.
[CmdletBinding()]
param([switch]$ReportOnly)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Copied from nable-agent-removal.ps1: a module runs from its hashed bytes and cannot load a sibling file.
$script:NaNamePattern = '(?i)\A(Advanced Monitoring Agent\b.*|Take Control Agent\b.*|N-able Take Control\b.*|BeAnywhere Support Express\b.*)\z'
$script:NaPartPattern = '(?i)\A(Request Handler Agent|File Cache Service Agent|Patch Management Service Controller)\z'
$script:NaPublisherPattern = '(?i)\A(Remote Monitoring Services|SolarWinds MSP|N-able Technologies|LogicNow( Ltd)?|BeAnywhere)\z'
$script:NaBootstrapPattern = '(?i)\AC:\\ProgramData\\\{[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}\}\\Agent\.exe\z'
$script:NaVendorRoots = @('SolarWinds MSP', 'N-able Technologies')
$script:NaFolderPattern = '(?i)\A(Advanced Monitoring Agent[^\\]*|BeAnywhere Support Express|Take Control Agent|MspPlatform|GetSupportService[^\\]*|(SolarWinds MSP|N-able Technologies)\\(Ecosystem Agent|PME|Cache Service|RpcServer|Take Control Agent))\z'
$script:NaServicePattern = '(?i)\A(Advanced Monitoring Agent.*|BASupportExpress.*|GetSupportService.*)\z'
$script:NaProtectedPattern = '(?i)ninja|sentinel|global secure access|wireguard|wazuh'

$script:FcUninstallRoots = @(
    'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
    'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
)
$script:FcProductsRoot = 'SOFTWARE\Classes\Installer\Products'
$script:FcUserDataRoot = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products'
$script:FcComponentsRoot = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Components'
$script:FcUpgradeRoot = 'SOFTWARE\Classes\Installer\UpgradeCodes'
$script:FcBackupRoot = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'Relian\NableForceBackup'
$script:FcInstallerDir = $(if ([Environment]::GetEnvironmentVariable('SystemRoot')) { [Environment]::GetEnvironmentVariable('SystemRoot').TrimEnd('\') + '\Installer' } else { 'C:\Windows\Installer' })

function Open-FcHklm {
    [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
}

# Seam: one record per Uninstall subkey, both views.
$script:FcReadUninstall = {
    $hklm = Open-FcHklm
    foreach ($root in $script:FcUninstallRoots) {
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

# A key and every descendant as @{ path; values = @{ name; kind; data } }. Binary is base64. Emits nothing when a read fails
# half way, because the caller wraps it in try: a blind read must stop the run before any delete.
function Read-FcKey {
    param($Key, [string]$Path)
    $values = @(foreach ($name in $Key.GetValueNames()) {
        $data = $Key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        if ($data -is [byte[]]) { $data = [Convert]::ToBase64String($data) }
        [ordered]@{ name = $name; kind = [string]$Key.GetValueKind($name); data = $data }
    })
    [ordered]@{ path = $Path; values = $values }
    foreach ($sub in $Key.GetSubKeyNames()) {
        $child = $Key.OpenSubKey($sub)
        if (-not $child) { throw "cannot open $Path\$sub" }
        try { Read-FcKey $child "$Path\$sub" } finally { $child.Dispose() }
    }
}

# Seam: the flat list for one key path, or $null when the key is absent.
$script:FcReadTree = {
    param($Path)
    $key = (Open-FcHklm).OpenSubKey($Path)
    if (-not $key) { return $null }
    try { return @(Read-FcKey $key $Path) } finally { $key.Dispose() }
}

# Seam: subkeys of $Root that hold a value named $Packed, with all their value names. A product's client entry in a
# Windows Installer component or upgrade-code key is a value named by its packed product code.
$script:FcFindHolders = {
    param($Root, $Packed)
    $parent = (Open-FcHklm).OpenSubKey($Root)
    if (-not $parent) { return }
    try {
        foreach ($sub in $parent.GetSubKeyNames()) {
            $k = $parent.OpenSubKey($sub)
            if (-not $k) { continue }
            try {
                $names = @($k.GetValueNames())
                if (@($names | Where-Object { $_ -eq $Packed }).Count) { [pscustomobject]@{ Path = "$Root\$sub"; Names = $names } }
            } finally { $k.Dispose() }
        }
    } finally { $parent.Dispose() }
}

# Seam: the cached package of every registered product, as @{ Packed; Package }.
$script:FcReadPackages = {
    $parent = (Open-FcHklm).OpenSubKey($script:FcUserDataRoot)
    if (-not $parent) { return }
    try {
        foreach ($sub in $parent.GetSubKeyNames()) {
            $k = $parent.OpenSubKey("$sub\InstallProperties")
            if (-not $k) { continue }
            try { [pscustomobject]@{ Packed = $sub; Package = [string]$k.GetValue('LocalPackage') } } finally { $k.Dispose() }
        }
    } finally { $parent.Dispose() }
}

$script:FcDeleteTree = { param($Path) (Open-FcHklm).DeleteSubKeyTree($Path, $false) }

$script:FcReadServices = {
    foreach ($s in @(Get-CimInstance -ClassName Win32_Service -ErrorAction Stop)) {
        [pscustomobject]@{ Name = [string]$s.Name; DisplayName = [string]$s.DisplayName; Path = [string]$s.PathName }
    }
}

# Seam: $null when the file is absent, else its length and SHA256.
$script:FcFileFacts = {
    param($Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    [pscustomobject]@{ Length = (Get-Item -LiteralPath $Path -Force).Length; Sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
}
$script:FcDeleteFile = { param($Path) Remove-Item -LiteralPath $Path -Force }

# Seam: 'missing', 'reparse' (a link, never followed) or 'dir'.
$script:FcFolderKind = {
    param($Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item) { return 'missing' }
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { return 'reparse' }
    if ($item.PSIsContainer) { return 'dir' }
    return 'missing'
}
$script:FcRemoveFolder = { param($Path) Remove-FcTree $Path }

$script:FcProtectDir = {
    param($Path)
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetSecurityDescriptorSddlForm('D:P(A;OICI;FA;;;SY)')
    Set-Acl -LiteralPath $Path -AclObject $acl
}

# Deletes a folder tree without following links: Remove-Item -Recurse in Windows PowerShell 5.1 walks into a junction and
# deletes its target's files. A linked folder inside loses only the link. Nothing in it is run.
function Remove-FcTree {
    param([string]$Path)
    foreach ($item in ([IO.DirectoryInfo]::new($Path)).GetFileSystemInfos()) {
        if ($item -is [IO.DirectoryInfo]) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { [IO.Directory]::Delete($item.FullName, $false) }
            else { Remove-FcTree $item.FullName }
        } else {
            $item.Attributes = [IO.FileAttributes]::Normal
            $item.Delete()
        }
    }
    [IO.Directory]::Delete($Path, $false)
}

function Get-FcText {
    param([AllowNull()]$Text)
    $t = ([string]$Text) -replace '(?i)C:\\Users\\[^\\]+', 'C:\Users\<user>'
    return $t.Substring(0, [Math]::Min($t.Length, 300))
}

function Test-FcProtected { param([AllowEmptyString()][string]$Text) return $Text -match $script:NaProtectedPattern }

function Test-FcApp {
    param($Entry)
    if (-not $Entry.Name -or (Test-FcProtected "$($Entry.Name) $($Entry.Publisher) $($Entry.Uninstall)")) { return $false }
    return ($Entry.Name -match $script:NaNamePattern) -or ($Entry.Name -match $script:NaPartPattern -and $Entry.Publisher -match $script:NaPublisherPattern)
}

function Get-FcExecutable {
    param([AllowEmptyString()][string]$Command)
    ([regex]::Match($Command, '\A\s*(?:"(?<e>[^"]+)"|(?<e>.+?\.exe)(?=\s|\z)|(?<e>\S+))')).Groups['e'].Value
}

# True when the path sits inside an agent folder under Program Files or ProgramData.
function Test-FcInAgentFolder {
    param([AllowEmptyString()][string]$Path)
    $parents = @(${env:ProgramFiles(x86)}, $env:ProgramW6432, $env:ProgramFiles, $env:ProgramData) | Where-Object { $_ }
    foreach ($parent in $parents) {
        $prefix = $parent.TrimEnd('\') + '\'
        if (-not $Path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { continue }
        $parts = $Path.Substring($prefix.Length).Split('\')
        if ($parts.Count -ge 2 -and $parts[0] -match $script:NaFolderPattern) { return $true }
        if ($parts.Count -ge 3 -and "$($parts[0])\$($parts[1])" -match $script:NaFolderPattern) { return $true }
    }
    return $false
}

function Test-FcServiceEntry {
    param($Service)
    if (Test-FcProtected "$($Service.Name) $($Service.DisplayName) $($Service.Path)") { return $false }
    if ($Service.Name -match $script:NaServicePattern) { return $true }
    return Test-FcInAgentFolder (Get-FcExecutable "$($Service.Path)")
}

# Windows Installer's packed GUID: the first three groups reversed, the rest with each byte's two digits swapped.
function ConvertTo-FcPackedGuid {
    param([string]$Guid)
    $m = [regex]::Match($Guid, '\A\{([0-9A-Fa-f]{8})-([0-9A-Fa-f]{4})-([0-9A-Fa-f]{4})-([0-9A-Fa-f]{4})-([0-9A-Fa-f]{12})\}\z')
    if (-not $m.Success) { throw "not a product code: $Guid" }
    $rev = { param($t) $a = $t.ToCharArray(); [Array]::Reverse($a); -join $a }
    $tail = ($m.Groups[4].Value + $m.Groups[5].Value) -replace '(.)(.)', '$2$1'
    return ((& $rev $m.Groups[1].Value) + (& $rev $m.Groups[2].Value) + (& $rev $m.Groups[3].Value) + $tail).ToUpperInvariant()
}

# The C:\ProgramData\{GUID} folder of an entry whose UninstallString names the vendor bootstrapper Agent.exe in exactly that
# folder, or $null. The folder is only ever deleted; the Agent.exe in it is never run.
function Get-FcBootstrapperDir {
    param($Entry)
    $exe = Get-FcExecutable "$($Entry.Uninstall)"
    if ($exe -notmatch $script:NaBootstrapPattern) { return $null }
    return $exe.Substring(0, $exe.LastIndexOf([char]92))
}

function Get-FcServices { @(& $script:FcReadServices | Where-Object { Test-FcServiceEntry $_ }) }

# Everything one product owns and the job would delete. Reads only. Kept holds what is left alone, with the reason.
function Get-FcTarget {
    param($Apps, [string]$Code)
    $trees = [Collections.Generic.List[object]]::new()
    $kept = [Collections.Generic.List[string]]::new()
    $add = { param($Path) $t = & $script:FcReadTree $Path; if ($null -ne $t) { $trees.Add(@{ path = $Path; keys = @($t) }) } }
    $package = $null
    $packed = $null
    if ($Code) {
        $packed = ConvertTo-FcPackedGuid $Code
        & $add "$script:FcProductsRoot\$packed"
        & $add "$script:FcUserDataRoot\$packed"
    }
    foreach ($a in $Apps) { & $add $a.Key }
    if ($packed) {
        # A component or upgrade-code key goes only when this product is its sole client.
        foreach ($root in @($script:FcComponentsRoot, $script:FcUpgradeRoot)) {
            foreach ($h in @(& $script:FcFindHolders $root $packed)) {
                if (@($h.Names).Count -eq 1) { & $add $h.Path } else { $kept.Add("HKLM\$($h.Path): has other clients") }
            }
        }
        $pkg = $null
        foreach ($t in $trees) { foreach ($k in $t.keys) { if ($k.path -like '*\InstallProperties') { foreach ($v in $k.values) { if ($v.name -eq 'LocalPackage') { $pkg = [string]$v.data } } } } }
        if ($pkg) {
            $facts = & $script:FcFileFacts $pkg
            $name = $pkg.Substring($pkg.LastIndexOf([char]92) + 1)
            $dir = $(if ($pkg.Contains('\')) { $pkg.Substring(0, $pkg.LastIndexOf([char]92)) } else { '' })
            if ($null -eq $facts) { }
            elseif ($dir -ne $script:FcInstallerDir -or $name -notmatch '(?i)\A[0-9a-f]+\.msi\z') { $kept.Add("${pkg}: cached package is not directly in $script:FcInstallerDir with a hex .msi name") }
            elseif (@(& $script:FcReadPackages | Where-Object { $_.Packed -ne $packed -and $_.Package -eq $pkg }).Count) { $kept.Add("${pkg}: cached package is also used by another registered product") }
            else { $package = [ordered]@{ path = $pkg; length = $facts.Length; sha256 = $facts.Sha256 } }
        }
    }
    # A non-MSI key can exist in both registry views under one name, so the view is part of its backup folder name.
    $view = $(if ($Apps[0].Key -like '*WOW6432Node*') { 'wow64' } else { 'native' })
    [pscustomobject]@{ Code = $Code; Label = $(if ($Code) { $Code } else { "$view-$($Apps[0].Id)" }); Apps = @($Apps); Trees = $trees.ToArray(); Package = $package; Kept = @($kept) }
}

# Groups the matched entries per product code (both views of one MSI form one target) and finds the bootstrapper folders.
function Get-FcPlan {
    $apps = @(& $script:FcReadUninstall | Where-Object { Test-FcApp $_ })
    $isMsi = { param($a) $a.Id -match '\A\{[0-9A-Fa-f-]{36}\}\z' -and $a.Msi }
    $targets = [Collections.Generic.List[object]]::new()
    foreach ($g in @($apps | Where-Object { & $isMsi $_ } | Group-Object { $_.Id.ToUpperInvariant() })) { $targets.Add((Get-FcTarget @($g.Group) $g.Group[0].Id)) }
    foreach ($a in @($apps | Where-Object { -not (& $isMsi $_) })) { $targets.Add((Get-FcTarget @($a) '')) }
    $folders = @(); $kept = @()
    foreach ($dir in @($apps | ForEach-Object { Get-FcBootstrapperDir $_ } | Where-Object { $_ } | Sort-Object -Unique)) {
        $kind = & $script:FcFolderKind $dir
        if ($kind -eq 'dir') { $folders += $dir } elseif ($kind -eq 'reparse') { $kept += "${dir}: is a reparse point, not followed" }
    }
    [pscustomobject]@{ Targets = $targets.ToArray(); Folders = $folders; Kept = $kept; Services = @(Get-FcServices) }
}

# Seam: the text of a written backup file, read back for the comparison.
$script:FcReadBack = { param($Path) [IO.File]::ReadAllText($Path, (New-Object Text.UTF8Encoding($false))) }

# Copies a file or a folder tree to a new place and verifies every file by length and SHA256. A link inside a folder is not
# followed and not copied (the delete removes only the link). Throws when the destination exists or a copy differs.
function Copy-FcTree {
    param([string]$Source, [string]$Dest)
    if (Test-Path -LiteralPath $Dest) { throw "backup copy exists: $Dest" }
    if (Test-Path -LiteralPath $Source -PathType Leaf) {
        [IO.File]::Copy($Source, $Dest, $false)
        if ((Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $Dest -Algorithm SHA256).Hash) { throw "backup copy differs: $Source" }
        return
    }
    $null = [IO.Directory]::CreateDirectory($Dest)
    foreach ($item in ([IO.DirectoryInfo]::new($Source)).GetFileSystemInfos()) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
        Copy-FcTree $item.FullName (Join-Path $Dest $item.Name)
    }
}
$script:FcCopyBackup = { param($Source, $Dest) Copy-FcTree $Source $Dest }

# New file, never overwritten, read back and compared byte for byte. Throws on any failure.
function Write-FcFile {
    param([string]$Path, [string]$Text)
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($Text)
    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush() } finally { $stream.Dispose() }
    if ($bytes.Length -ne ([IO.File]::ReadAllBytes($Path)).Length -or (& $script:FcReadBack $Path) -ne $Text) { throw "backup read-back differs: $Path" }
}

# Registry listing in the style of reg export: [HKLM\path] then "name"=Kind:data. The JSON file is the restore source.
function ConvertTo-FcListing {
    param($Trees)
    $lines = foreach ($t in $Trees) { foreach ($k in $t.keys) {
        ''; "[HKLM\$($k.path)]"
        foreach ($v in $k.values) { "`"$($v.name)`"=$($v.kind):$(@($v.data) -join ' | ')" }
    } }
    return ((@($lines) -join "`r`n") + "`r`n")
}

# Writes the two backup files of one target under a new folder, and a verified copy of every file or folder it will delete
# (Copies). Returns the paths written. Throws on any failure, which stops the run before the first delete.
function Write-FcBackup {
    param($Target, [string]$Stamp, $Copies = @())
    $null = New-Item -ItemType Directory -Path $script:FcBackupRoot -Force
    & $script:FcProtectDir $script:FcBackupRoot
    $dir = Join-Path $script:FcBackupRoot ("$Stamp-" + ($Target.Label -replace '[^A-Za-z0-9{}._-]', '_'))
    if (Test-Path -LiteralPath $dir) { throw "backup folder exists: $dir" }
    $null = New-Item -ItemType Directory -Path $dir
    & $script:FcProtectDir $dir
    $doc = [ordered]@{
        schemaVersion = 1; createdUtc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'); product = $Target.Label
        keys = @($Target.Trees | ForEach-Object { $_.path }); trees = @($Target.Trees | ForEach-Object { $_.keys })
        cachedPackage = $Target.Package; copiedFrom = @($Copies)
    }
    $json = Join-Path $dir 'backup.json'
    $list = Join-Path $dir 'registry-listing.txt'
    Write-FcFile $json ($doc | ConvertTo-Json -Depth 10)
    Write-FcFile $list (ConvertTo-FcListing $Target.Trees)
    $written = @($json, $list)
    if (@($Copies).Count) { $null = New-Item -ItemType Directory -Path (Join-Path $dir 'files') }
    foreach ($c in @($Copies)) {
        $to = Join-Path (Join-Path $dir 'files') ($c -replace '[^A-Za-z0-9{}._-]', '_')
        & $script:FcCopyBackup $c $to
        $written += $to
    }
    return $written
}

function Invoke-FcJob {
    param([switch]$ReportOnly)
    $removed = [Collections.Generic.List[string]]::new()
    $backups = [Collections.Generic.List[string]]::new()
    $left = [Collections.Generic.List[string]]::new()
    $status = 'failed'; $exitCode = 2; $problem = ''
    try {
        $plan = Get-FcPlan
        foreach ($k in $plan.Kept) { $left.Add($k) }
        foreach ($t in $plan.Targets) { foreach ($k in $t.Kept) { $left.Add($k) } }
        if ($plan.Targets.Count -eq 0) {
            $status = 'compliant'; $exitCode = 0
        } else {
            $paths = @(foreach ($t in $plan.Targets) {
                foreach ($tree in $t.Trees) { "HKLM\$($tree.path)" }
                if ($t.Package) { $t.Package.path }
            }) + @($plan.Folders)
            foreach ($s in $plan.Services) { $left.Add("service $($s.Name): an N-able service exists, nothing is removed") }
            if ($ReportOnly) {
                foreach ($p in $paths) { $removed.Add($p) }
                $status = 'drift'; $exitCode = 1
            } elseif ($plan.Services.Count) {
                $problem = 'an N-able service exists'
            } else {
                # 1. Back up everything, for every product, before the first delete.
                $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
                foreach ($t in $plan.Targets) {
                    $copies = @(if ($t.Package) { $t.Package.path })
                    foreach ($f in (Write-FcBackup $t $stamp $copies)) { $backups.Add($f) }
                }
                foreach ($dir in $plan.Folders) {
                    $folderTarget = [pscustomobject]@{ Label = 'folder-' + $dir.Substring($dir.LastIndexOf([char]92) + 1); Trees = @(); Package = $null }
                    foreach ($f in (Write-FcBackup $folderTarget $stamp @($dir))) { $backups.Add($f) }
                }
                # The services are read again: a service that appeared since the plan stops the run with the backups kept.
                if (@(Get-FcServices).Count) { throw 'an N-able service appeared before the delete' }
                # 2. Registry, 3. the cached package, last the bootstrapper folders. A failed delete is recorded and the run goes on.
                $failed = 0
                foreach ($t in $plan.Targets) {
                    $ok = $true
                    foreach ($tree in $t.Trees) {
                        try { & $script:FcDeleteTree $tree.path; $removed.Add("HKLM\$($tree.path)") } catch { $ok = $false; $failed++; $left.Add("HKLM\$($tree.path): delete failed") }
                    }
                    if ($t.Package -and $ok) {
                        try { & $script:FcDeleteFile $t.Package.path; $removed.Add($t.Package.path) } catch { $failed++; $left.Add("$($t.Package.path): delete failed") }
                    }
                }
                foreach ($dir in $plan.Folders) {
                    if ($failed) { $left.Add("${dir}: kept, a key delete failed"); continue }
                    try { & $script:FcRemoveFolder $dir; $removed.Add($dir) } catch { $failed++; $left.Add("${dir}: delete failed") }
                }
                $now = @(& $script:FcReadUninstall | Where-Object { Test-FcApp $_ })
                if ($now.Count) { $problem = 'a matched uninstall key is still present: ' + (($now | ForEach-Object { $_.Key }) -join '; ') }
                elseif ($failed) { $problem = "$failed delete(s) failed" }
                else { $status = 'removed'; $exitCode = 0 }
            }
        }
    } catch {
        $problem = $_.Exception.Message
    }
    [pscustomobject]@{ ExitCode = $exitCode; Status = $status; Removed = @($removed); Backups = @($backups); Left = @($left); Error = $problem }
}

function ConvertTo-FcJobLine {
    param([Parameter(Mandatory)]$Result)
    $cut = { param($Items, $Count) @($Items | Select-Object -First $Count | ForEach-Object { Get-FcText $_ }) }
    [ordered]@{
        job = 'nable-force-cleanup'; status = $Result.Status
        removed = @(& $cut $Result.Removed 60); backups = @(& $cut $Result.Backups 30); left = @(& $cut $Result.Left 20); error = Get-FcText $Result.Error
    } | ConvertTo-Json -Compress
}

# Dot-sourcing under test defines functions and changes nothing.
if ($env:RELIAN_DEPLOY_TEST -eq '1' -and $MyInvocation.InvocationName -eq '.') {
    return
}

$jobResult = Invoke-FcJob -ReportOnly:$ReportOnly
Write-Output (ConvertTo-FcJobLine $jobResult)
exit $jobResult.ExitCode
