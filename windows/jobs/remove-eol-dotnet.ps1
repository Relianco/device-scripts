# Remediation module, run by windows/runner/Invoke-RelianJob.ps1 as SYSTEM. Removes end-of-life .NET 5 and .NET 7
# runtimes (Runtime, Windows Desktop Runtime, ASP.NET Core Shared Framework, Host, Host FX Resolver) published by
# Microsoft Corporation. Leaves .NET 6, .NET 8, .NET 9, .NET 10, .NET Framework, and third-party runtimes untouched.
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

# Owner must be SYSTEM or Administrators; DACL must be protected and allow SYSTEM only.
function Test-DnBackupAcl {
    param([AllowEmptyString()][string]$Sddl)
    return ($Sddl -match '\AO:(SY|BA)G:[^:]*D:([A-Z]*)(\(A;[A-Z]*;[^;()]*;;;SY\))+\z' -and $Matches[2].Contains('P'))
}

# Parent directory must be owned by SYSTEM or Administrators with no non-admin write, delete, or ownership-change ACEs.
function Test-DnParentAcl {
    param([AllowEmptyString()][string]$Sddl)
    if ($Sddl -notmatch '\AO:(SY|BA)G:[^:]*D:[^()]*((?:\([^()]+\))+)') { return $false }
    $aces = [regex]::Matches($Matches[2], '\(([^()]+)\)')
    foreach ($m in $aces) {
        $parts = $m.Groups[1].Value -split ';'
        if ($parts.Count -lt 6) { return $false }
        $aceType = $parts[0]
        $rights = $parts[2]
        $trustee = $parts[5]
        if ($aceType -ne 'A') { continue }
        if ($trustee -in @('SY', 'BA')) { continue }
        if ($trustee -eq 'CO' -and $parts[1] -match 'IO') { continue }
        if ($rights -match '^(FA|GA|GW|KA)$' -or $rights -match '(DC|SD|WD|WDAC|WO)') { return $false }
        if ($rights -match '^0x([0-9a-fA-F]+)$') {
            $mask = [Convert]::ToInt64($Matches[1], 16)
            if (($mask -band 0x500D0040) -ne 0) { return $false }
        }
    }
    return $true
}

function Ensure-DnBackupDirectory {
    param([string]$BackupDir)
    $parent = Split-Path -Parent $BackupDir
    $chain = @($parent, $BackupDir)
    & $script:DnAssertNotReparse $chain
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        $null = New-Item -ItemType Directory -Path $parent -Force
        & $script:DnAssertNotReparse @($parent)
        & $script:DnProtectDir $parent
    }
    if ($parent -and -not (Test-DnParentAcl (& $script:DnReadSddl $parent))) {
        throw 'refusing backup parent directory with untrusted owner or ACL'
    }
    if (-not (Test-Path -LiteralPath $BackupDir)) {
        $null = New-Item -ItemType Directory -Path $BackupDir -Force
        & $script:DnAssertNotReparse $chain
        & $script:DnProtectDir $BackupDir
    }
    if (-not (Test-DnBackupAcl (& $script:DnReadSddl $BackupDir))) {
        throw 'refusing backup directory with untrusted owner or ACL'
    }
}

# Pure: filters uninstall entries down to Microsoft EOL .NET 5 and .NET 7 runtime/desktop/ASP.NET Core packages.
function Get-DnTargets {
    param($Entries)
    $found = [Collections.Generic.List[object]]::new()
    foreach ($e in @($Entries)) {
        if ($null -eq $e) { continue }
        $pub = ([string](Get-DnProp $e 'publisher' '')).Trim()
        if ($pub -ine 'Microsoft Corporation') { continue }
        $name = ([string](Get-DnProp $e 'name' '')).Trim()
        if ($name -notmatch $script:DnNamePattern) { continue }
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
