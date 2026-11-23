# Remediation module, run by windows/runner/Invoke-RelianJob.ps1 as SYSTEM. Removes end-of-life .NET 5 and .NET 7
# runtimes (Runtime, Windows Desktop Runtime, ASP.NET Core Shared Framework, Host, Host FX Resolver) published by
# Microsoft Corporation. Leaves .NET 6, .NET 8, .NET 9, .NET 10, .NET Framework, and third-party runtimes untouched.
# remove-eol-dotnet-6.ps1 is this file with DnIncludeDotnet6 set to $true: it also removes .NET 6 (end of life
# 2024-11-12), its Windows Desktop Runtime and its ASP.NET Core Hosting Bundle (Windows Server Hosting and Hosting Bundle
# Options), which removes the IIS ASP.NET Core Module 6 with it. Never .NET 8 or later.
# Before running any uninstaller, writes a JSON backup under C:\ProgramData\Relian\EolDotnetBackup (SYSTEM-only,
# never overwritten) and reads it back. Verified WiX Burn bundles under C:\ProgramData\Package Cache\{GUID}\*.exe
# run first (/uninstall /quiet /norestart), then any remaining matched Windows Installer {GUID} products run via
# msiexec.exe /x {GUID} /qn /norestart.
# -ReportOnly changes and writes nothing. Exit 0 unchanged or removed, 1 drift with -ReportOnly, 2 failed.
# Prints one JSON line on stdout.
[CmdletBinding()]
param([switch]$ReportOnly)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:DnUninstallRoots = @(
    'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
    'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
)
$script:DnNamePattern = '(?i)\A(?:Microsoft \.NET (?:Runtime|Host|Host FX Resolver) - [57]\.\d+\.\d+|Microsoft Windows Desktop Runtime - [57]\.\d+\.\d+|Microsoft ASP\.NET Core [57]\.\d+\.\d+(?:\s+-)?\s+Shared Framework)\s+\((?:x64|x86|arm64)\)\z'
# The loader forwards only -ReportOnly, so the .NET 6 opt-in is a sibling file that differs from this one in this line only.
$script:DnIncludeDotnet6 = $false
$script:Dn6NamePattern = '(?i)\A(?:(?:Microsoft \.NET (?:Runtime|Host|Host FX Resolver) - 6\.\d+\.\d+|Microsoft Windows Desktop Runtime - 6\.\d+\.\d+|Microsoft ASP\.NET Core 6\.\d+\.\d+(?:\s+-)?\s+Shared Framework)\s+\((?:x64|x86|arm64)\)|Microsoft \.NET 6\.\d+\.\d+ - Windows Server Hosting|Microsoft ASP\.NET Core 6\.\d+\.\d+ Hosting Bundle Options)\z'
$script:DnGuidPattern = '\A\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}\z'
$script:DnPackageCacheRoot = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'Package Cache'
$script:DnBackupDir = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'Relian\EolDotnetBackup'

function Open-DnHklm {
    [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
}

$script:DnReadSddl = { param($Path) (Get-Acl -LiteralPath $Path).Sddl }

$script:DnFileExists = { param([string]$Path) [IO.File]::Exists($Path) }

$script:DnAssertNotReparse = {
    param([string[]]$Paths)
    foreach ($p in $Paths) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        $full = [IO.Path]::GetFullPath($p)
        $root = [IO.Path]::GetPathRoot($full)
        $cur = $(if ($full.Length -gt $root.Length) { $full.TrimEnd('\', '/') } else { $full })
        while ($cur -and $cur -ne $root) {
            if ((Test-Path -LiteralPath $cur) -and ((Get-Item -LiteralPath $cur -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw 'refusing reparse point on path'
            }
            $parent = Split-Path -Parent $cur
            if (-not $parent -or $parent -eq $cur) { break }
            $cur = $parent
        }
    }
}

$script:DnProtectDir = {
    param($Path)
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetSecurityDescriptorSddlForm('O:SYG:SYD:P(A;OICI;FA;;;SY)')
    Set-Acl -LiteralPath $Path -AclObject $acl
}

$script:DnReadUninstallEntries = {
    $hklm = Open-DnHklm
    $out = [Collections.Generic.List[object]]::new()
    try {
        foreach ($root in $script:DnUninstallRoots) {
            $parent = $hklm.OpenSubKey($root)
            if (-not $parent) { continue }
            try {
                foreach ($sub in $parent.GetSubKeyNames()) {
                    $key = $parent.OpenSubKey($sub)
                    if (-not $key) { continue }
                    try {
                        $out.Add(@{
                            key             = "$root\$sub"
                            id              = [string]$sub
                            name            = [string]$key.GetValue('DisplayName')
                            publisher       = [string]$key.GetValue('Publisher')
                            version         = [string]$key.GetValue('DisplayVersion')
                            bundleCachePath = [string]$key.GetValue('BundleCachePath')
                            quietUninstall  = [string]$key.GetValue('QuietUninstallString')
                            uninstall       = [string]$key.GetValue('UninstallString')
                            msi             = ([string]$key.GetValue('WindowsInstaller') -eq '1')
                        })
                    } finally { $key.Dispose() }
                }
            } finally { $parent.Dispose() }
        }
    } finally { $hklm.Dispose() }
    return @($out)
}

$script:DnRunBundle = {
    param([string]$ExePath, [string]$Arguments)
    $p = Start-Process -FilePath $ExePath -ArgumentList $Arguments -Wait -PassThru -WindowStyle Hidden
    return [int]$p.ExitCode
}

$script:DnRunMsi = {
    param([string]$ProductCode)
    $msiexec = Join-Path $env:SystemRoot 'System32\msiexec.exe'
    $p = Start-Process -FilePath $msiexec -ArgumentList "/x $ProductCode /qn /norestart" -Wait -PassThru -WindowStyle Hidden
    return [int]$p.ExitCode
}

function Get-DnProp {
    param($Obj, [string]$Name, $Default = $null)
    if ($null -eq $Obj) { return $Default }
    if ($Obj -is [Collections.IDictionary]) {
        if ($Obj.Contains($Name)) { return $Obj[$Name] }
        return $Default
    }
    $prop = $Obj.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $Default
}

# Owner must be SYSTEM or Administrators; DACL must be protected, inheritable to files, and allow SYSTEM only.
function Test-DnBackupAcl {
    param([AllowEmptyString()][string]$Sddl)
    return ($Sddl -match '\AO:(SY|BA)G:[^:]*D:([A-Z]*)(\(A;(?=[^;()]*OI)(?=[^;()]*CI)[A-Z]*;[^;()]*;;;SY\))+\z' -and $Matches[2].Contains('P'))
}

$script:DnSddlRightMap = @{
    'CC' = 0x00000001L; 'DC' = 0x00000002L; 'LC' = 0x00000004L; 'SW' = 0x00000008L
    'RP' = 0x00000010L; 'WP' = 0x00000020L; 'DT' = 0x00000040L; 'LO' = 0x00000080L
    'CR' = 0x00000100L; 'SD' = 0x00010000L; 'RC' = 0x00020000L; 'WD' = 0x00040000L
    'WO' = 0x00080000L; 'GA' = 0x10000000L; 'GX' = 0x20000000L; 'GW' = 0x40000000L
    'GR' = 0x80000000L; 'FA' = 0x001F01FFL; 'FR' = 0x00120089L; 'FW' = 0x00120116L
    'FX' = 0x001200A0L; 'KA' = 0x000F003FL; 'KR' = 0x00020019L; 'KW' = 0x00020006L
    'KX' = 0x00020019L
}

function ConvertFrom-DnSddlRights {
    param([AllowEmptyString()][string]$Rights)
    if ([string]::IsNullOrWhiteSpace($Rights)) { return -1L }
    if ($Rights -match '\A0x([0-9a-fA-F]{1,8})\z') {
        return [Convert]::ToInt64($Matches[1], 16)
    }
    if (($Rights.Length % 2) -ne 0) { return -1L }
    $mask = 0L
    for ($i = 0; $i -lt $Rights.Length; $i += 2) {
        $tok = $Rights.Substring($i, 2).ToUpperInvariant()
        if (-not $script:DnSddlRightMap.ContainsKey($tok)) { return -1L }
        $mask = $mask -bor $script:DnSddlRightMap[$tok]
    }
    return $mask
}

# Parent directory must be owned by SYSTEM or Administrators with no non-admin write, create, delete, or ownership-change ACEs.
function Test-DnParentAcl {
    param([AllowEmptyString()][string]$Sddl)
    if ($Sddl -notmatch '\AO:(SY|BA)G:[^:]*D:[^()]*((?:\([^()]+\))+)\z') { return $false }
    $aces = [regex]::Matches($Matches[2], '\(([^()]+)\)')
    foreach ($m in $aces) {
        $parts = $m.Groups[1].Value -split ';'
        if ($parts.Count -lt 6) { return $false }
        $aceType = $parts[0]
        $aceFlags = $parts[1]
        $rights = $parts[2]
        $trustee = $parts[5]
        if ($aceType -ne 'A') { continue }
        if ($trustee -in @('SY', 'BA')) { continue }
        if ($aceFlags -match 'IO') { continue }
        $mask = ConvertFrom-DnSddlRights $rights
        if ($mask -lt 0) { return $false }
        # Reject generic all/write, delete, delete-child (DT/0x40), write-dac, write-owner, write-data/create-file (DC/0x2), append-data/create-subdir (LC/0x4), write-ea (RP/0x10), write-attributes (CR/0x100).
        if (($mask -band 0x500D0156L) -ne 0) { return $false }
    }
    return $true
}

function Ensure-DnBackupDirectory {
    param([string]$BackupDir)
    $parent = Split-Path -Parent $BackupDir
    $chain = @($parent, $BackupDir)
    & $script:DnAssertNotReparse $chain
    if ($parent) {
        if (-not (Test-Path -LiteralPath $parent)) {
            $null = New-Item -ItemType Directory -Path $parent -Force
            & $script:DnAssertNotReparse @($parent)
            & $script:DnProtectDir $parent
        } elseif (-not (Test-DnParentAcl (& $script:DnReadSddl $parent))) {
            & $script:DnAssertNotReparse @($parent)
            & $script:DnProtectDir $parent
        }
        if (-not (Test-DnParentAcl (& $script:DnReadSddl $parent))) {
            throw 'refusing backup parent directory with untrusted owner or ACL'
        }
    }
    if (-not (Test-Path -LiteralPath $BackupDir)) {
        $null = New-Item -ItemType Directory -Path $BackupDir -Force
        & $script:DnAssertNotReparse $chain
        & $script:DnProtectDir $BackupDir
    } elseif (-not (Test-DnBackupAcl (& $script:DnReadSddl $BackupDir))) {
        & $script:DnAssertNotReparse $chain
        & $script:DnProtectDir $BackupDir
    }
    if (-not (Test-DnBackupAcl (& $script:DnReadSddl $BackupDir))) {
        throw 'refusing backup directory with untrusted owner or ACL'
    }
}

# Pure: filters uninstall entries down to Microsoft EOL .NET 5 and .NET 7 (and opt-in .NET 6) runtime/desktop/ASP.NET Core packages.
function Get-DnTargets {
    param($Entries)
    $found = [Collections.Generic.List[object]]::new()
    foreach ($e in @($Entries)) {
        if ($null -eq $e) { continue }
        $pub = ([string](Get-DnProp $e 'publisher' '')).Trim()
        if ($pub -ine 'Microsoft Corporation') { continue }
        $name = ([string](Get-DnProp $e 'name' '')).Trim()
        if ($name -notmatch $script:DnNamePattern -and -not ($script:DnIncludeDotnet6 -and $name -match $script:Dn6NamePattern)) { continue }
        $found.Add([ordered]@{
            key             = [string](Get-DnProp $e 'key' '')
            id              = [string](Get-DnProp $e 'id' '')
            name            = $name
            version         = [string](Get-DnProp $e 'version' '')
            bundleCachePath = [string](Get-DnProp $e 'bundleCachePath' '')
            quietUninstall  = [string](Get-DnProp $e 'quietUninstall' '')
            uninstall       = [string](Get-DnProp $e 'uninstall' '')
            msi             = [bool](Get-DnProp $e 'msi' $false)
        })
    }
    return @($found | Sort-Object @{ Expression = { $_.name } }, @{ Expression = { $_.id } })
}

function Get-DnVerifiedBundlePath {
    param($Entry)
    $cand = ([string](Get-DnProp $Entry 'bundleCachePath' '')).Trim()
    if (-not $cand) {
        $q = [string](Get-DnProp $Entry 'quietUninstall' '')
        if ($q -match '\A"([^"]+\.exe)"' -or $q -match '\A([^\s"]+\.exe)(?:\s|\z)') {
            $cand = $Matches[1].Trim()
        }
    }
    if (-not $cand) { return $null }
    $root = $script:DnPackageCacheRoot.TrimEnd('\', '/')
    $escapedRoot = [regex]::Escape($root)
    if ($cand -notmatch "\A${escapedRoot}\\\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}\\[^\\/:*?`"<>|]+\.exe\z") {
        return $null
    }
    if ($cand.Contains('..')) { return $null }
    try { & $script:DnAssertNotReparse @($cand) } catch { return $null }
    if (-not (& $script:DnFileExists $cand)) { return $null }
    return $cand
}

function Get-DnSummary {
    param($Targets)
    $list = [Collections.Generic.List[object]]::new()
    foreach ($t in @($Targets)) {
        if ($null -eq $t) { continue }
        $list.Add([ordered]@{
            id      = [string](Get-DnProp $t 'id' '')
            name    = [string](Get-DnProp $t 'name' '')
            version = [string](Get-DnProp $t 'version' '')
        })
    }
    return @($list)
}

function Write-DnBackup {
    param($Targets)
    Ensure-DnBackupDirectory $script:DnBackupDir
    $name = 'backup-{0}-{1}.json' -f [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ'), [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $path = Join-Path $script:DnBackupDir $name
    $targetList = @($Targets)
    $doc = [ordered]@{
        schemaVersion = 1
        createdUtc    = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        targets       = $targetList
    }
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes(($doc | ConvertTo-Json -Depth 8))
    $stream = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush() } finally { $stream.Dispose() }
    $back = (Get-Content -LiteralPath $path -Raw -Encoding UTF8) | ConvertFrom-Json
    $backTargets = @($back.targets)
    if ($backTargets.Count -ne $targetList.Count) { throw 'backup read-back count differs from targets' }
    for ($i = 0; $i -lt $targetList.Count; $i++) {
        if ([string]$backTargets[$i].key -ne [string]$targetList[$i].key -or
            [string]$backTargets[$i].name -ne [string]$targetList[$i].name) {
            throw 'backup read-back entry differs from targets'
        }
    }
    return $name
}

function Invoke-DnJob {
    param([switch]$ReportOnly)
    $mode = $(if ($ReportOnly) { 'report' } else { 'run' })
    $r = @{
        ExitCode       = 2
        Status         = 'failed'
        Mode           = $mode
        Before         = @()
        After          = @()
        BundlesRun     = @()
        MsisRun        = @()
        RebootRequired = $false
        Backup         = $null
        Error          = ''
    }
    try {
        $targets = @(Get-DnTargets (& $script:DnReadUninstallEntries))
        $r.Before = @(Get-DnSummary $targets)
        if ($targets.Count -eq 0) {
            $r.After = @()
            $r.Status = 'unchanged'
            $r.ExitCode = 0
        } elseif ($ReportOnly) {
            $r.After = $r.Before
            $r.Status = 'drift'
            $r.ExitCode = 1
        } else {
            $r.Backup = Write-DnBackup $targets
            $bundlesRun = [Collections.Generic.List[string]]::new()
            $msisRun = [Collections.Generic.List[string]]::new()
            $errors = [Collections.Generic.List[string]]::new()
            $seenBundles = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

            $backedUpMsiIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach ($t in $targets) {
                if ($t.msi -and $t.id -match $script:DnGuidPattern) { [void]$backedUpMsiIds.Add($t.id) }
            }

            foreach ($t in $targets) {
                $exe = Get-DnVerifiedBundlePath $t
                if (-not $exe -or -not $seenBundles.Add($exe)) { continue }
                try {
                    $code = [int](& $script:DnRunBundle $exe '/uninstall /quiet /norestart')
                    $bundlesRun.Add([IO.Path]::GetFileName($exe))
                    if ($code -eq 3010) { $r.RebootRequired = $true }
                    elseif ($code -ne 0) { $errors.Add("bundle $([IO.Path]::GetFileName($exe)) exit $code") }
                } catch {
                    $errors.Add($_.Exception.Message)
                }
            }

            $remaining = @(Get-DnTargets (& $script:DnReadUninstallEntries))
            $seenMsis = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach ($t in $remaining) {
                if (-not $t.msi -or $t.id -notmatch $script:DnGuidPattern) { continue }
                if (-not $backedUpMsiIds.Contains($t.id)) { continue }
                if (-not $seenMsis.Add($t.id)) { continue }
                try {
                    $code = [int](& $script:DnRunMsi $t.id)
                    $msisRun.Add($t.id)
                    if ($code -eq 3010) { $r.RebootRequired = $true }
                    elseif ($code -ne 0) { $errors.Add("msi $($t.id) exit $code") }
                } catch {
                    $errors.Add($_.Exception.Message)
                }
            }

            $after = @(Get-DnTargets (& $script:DnReadUninstallEntries))
            $r.After = @(Get-DnSummary $after)
            $r.BundlesRun = @($bundlesRun)
            $r.MsisRun = @($msisRun)
            if ($errors.Count -gt 0) {
                $r.Error = ($errors -join '; ')
            } elseif ($after.Count -eq 0) {
                $r.Status = 'removed'
                $r.ExitCode = 0
            } else {
                $r.Error = 'matching EOL .NET entries still present after removal'
            }
        }
    } catch {
        $r.Error = $_.Exception.Message
    }
    return [pscustomobject]$r
}

# Only characters JSON never escapes, so the line stays short and plain.
function Get-DnSafeText {
    param([AllowEmptyString()][string]$Text, [int]$Limit)
    $safe = $Text -replace '[^A-Za-z0-9 ._:()-]', '_'
    return $safe.Substring(0, [Math]::Min($safe.Length, $Limit))
}

function ConvertTo-DnJobLine {
    param([Parameter(Mandatory)]$Result)
    [ordered]@{
        job            = 'remove-eol-dotnet'
        mode           = $Result.Mode
        status         = $Result.Status
        before         = @($Result.Before)
        after          = @($Result.After)
        bundlesRun     = @($Result.BundlesRun)
        msisRun        = @($Result.MsisRun)
        rebootRequired = [bool]$Result.RebootRequired
        backup         = $Result.Backup
        error          = Get-DnSafeText $Result.Error 200
    } | ConvertTo-Json -Depth 6 -Compress
}

# Dot-sourcing under test defines functions and changes nothing.
if ($env:RELIAN_DEPLOY_TEST -eq '1' -and $MyInvocation.InvocationName -eq '.') {
    return
}

$jobResult = Invoke-DnJob -ReportOnly:$ReportOnly
Write-Output (ConvertTo-DnJobLine $jobResult)
exit $jobResult.ExitCode
