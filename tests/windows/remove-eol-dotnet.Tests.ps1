# remove-eol-dotnet module tests. Registry reads, file checks, and uninstallers are faked behind seams; backups are real files in a temp directory.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$modulePath = Join-Path $repoRoot 'windows/jobs/remove-eol-dotnet.ps1'
$module6Path = Join-Path $repoRoot 'windows/jobs/remove-eol-dotnet-6.ps1'

function Fail { param([string]$Message) [Console]::Error.WriteLine("FAIL $Message"); exit 1 }
function Assert-True { param([bool]$Condition, [string]$Label) if (-not $Condition) { Fail $Label } }
function Assert-Same { param($Actual, $Expected, [string]$Label) if ("$Actual" -ne "$Expected") { Fail "$Label was [$Actual] expected [$Expected]" } }

if (-not (Test-Path -LiteralPath $modulePath)) {
    Fail "module missing: $modulePath"
}

$env:RELIAN_DEPLOY_TEST = '1'
. $modulePath

$tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ("rm-dotnet-" + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $tmpRoot

function New-Entry {
    param(
        [string]$Root = 'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        [string]$Id = ('{' + [Guid]::NewGuid().ToString().ToUpperInvariant() + '}'),
        [string]$Name,
        [string]$Publisher = 'Microsoft Corporation',
        [string]$Version = '',
        [string]$BundleCachePath = '',
        [string]$QuietUninstall = '',
        [string]$Uninstall = '',
        [bool]$Msi = $false
    )
    @{
        key             = "$Root\$Id"
        id              = $Id
        name            = $Name
        publisher       = $Publisher
        version         = $Version
        bundleCachePath = $BundleCachePath
        quietUninstall  = $QuietUninstall
        uninstall       = $Uninstall
        msi             = $Msi
    }
}

function Reset-Test {
    param($Entries = @(), $ExistingFiles = @(), [bool]$IncludeDotnet6 = $false, [int[]]$AncmMajors = @(18))
    $script:DnIncludeDotnet6 = $IncludeDotnet6
    $script:AncmMajors = $AncmMajors
    $script:AncmThrows = $false
    $script:FakeEntries = [Collections.Generic.List[object]]::new()
    foreach ($e in $Entries) { $script:FakeEntries.Add($e.Clone()) }
    $script:ExistingFiles = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($f in $ExistingFiles) { [void]$script:ExistingFiles.Add($f) }
    $script:Log = [Collections.Generic.List[string]]::new()
    $script:ReadThrows = $false
    $script:BundleExitCode = 0
    $script:MsiExitCode = 0
    $script:KeepIdsAfterUninstall = @()
    $script:ReparsePaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $script:FakeParentSddl = 'O:SYG:SYD:P(A;OICI;FA;;;SY)'
    $script:FakeBackupSddl = 'O:SYG:SYD:P(A;OICI;FA;;;SY)'
    $script:DnPackageCacheRoot = 'C:\ProgramData\Package Cache'
    $script:DnBackupDir = Join-Path (Join-Path $tmpRoot ([Guid]::NewGuid().ToString('N'))) 'EolDotnetBackup'
}

$script:DnAssertNotReparse = {
    param([string[]]$Paths)
    foreach ($p in $Paths) {
        if ($script:ReparsePaths.Contains($p)) { throw "refusing reparse point on path: $p" }
    }
}
$script:DnFileExists = { param([string]$Path) $script:ExistingFiles.Contains($Path) }
$script:DnReadAncmMajors = {
    if ($script:AncmThrows) { throw 'version read failure' }
    return @($script:AncmMajors)
}
$script:DnProtectDir = { param($Path) $script:Log.Add("protect:$(Split-Path -Leaf $Path)") }
$script:DnReadSddl = {
    param($Path)
    if ($Path -eq $script:DnBackupDir) { return $script:FakeBackupSddl }
    return $script:FakeParentSddl
}
$script:DnReadUninstallEntries = {
    if ($script:ReadThrows) { throw 'Registry failure' }
    return @($script:FakeEntries.ToArray())
}
$script:DnRunBundle = {
    param([string]$ExePath, [string]$Arguments)
    $script:Log.Add("bundle:$ExePath|$Arguments")
    # Simulate Burn removing its bundle and matching MSIs unless pinned to remain.
    $keep = [Collections.Generic.List[object]]::new()
    foreach ($e in $script:FakeEntries) {
        if ($script:KeepIdsAfterUninstall -contains $e.id) { $keep.Add($e); continue }
        if ($e.bundleCachePath -ieq $ExePath -or $e.quietUninstall -like "*$ExePath*") { continue }
        if ($e.name -match '\b7\.0\.7\b' -and $ExePath -like '*7.0.7*') { continue }
        $keep.Add($e)
    }
    $script:FakeEntries = $keep
    return $script:BundleExitCode
}
$script:DnRunMsi = {
    param([string]$ProductCode)
    $script:Log.Add("msi:$ProductCode")
    $keep = [Collections.Generic.List[object]]::new()
    foreach ($e in $script:FakeEntries) {
        if ($script:KeepIdsAfterUninstall -contains $e.id -or $e.id -ine $ProductCode) { $keep.Add($e) }
    }
    $script:FakeEntries = $keep
    return $script:MsiExitCode
}

function Backups { @(if (Test-Path -LiteralPath $script:DnBackupDir) { Get-ChildItem -LiteralPath $script:DnBackupDir -File }) }

try {
    # 1. Clean machine (.NET 6, 8, 10, .NET Framework 4.8, SAP Crystal Reports, non-Microsoft publisher): unchanged.
    $clean = @(
        (New-Entry -Name 'Microsoft .NET Runtime - 6.0.36 (x64)' -Version '48.144.23141' -Msi $true),
        (New-Entry -Name 'Microsoft Windows Desktop Runtime - 8.0.34 (x64)' -Version '64.136.61676' -Msi $true),
        (New-Entry -Name 'Microsoft .NET Runtime - 10.0.14 (x64)' -Version '80.56.61678' -Msi $true),
        (New-Entry -Name 'Microsoft .NET Framework 4.8' -Version '4.8.03761'),
        (New-Entry -Name 'SAP Crystal Reports runtime engine for .NET Framework (32-bit)' -Publisher 'SAP' -Version '13.0.24.2970' -Msi $true),
        (New-Entry -Name 'Microsoft .NET Runtime - 7.0.7 (x64)' -Publisher 'ThirdParty' -Version '56.31.61636' -Msi $true)
    )
    Reset-Test -Entries $clean
    $r = Invoke-DnJob
    Assert-Same $r.ExitCode 0 'clean exit'
    Assert-Same $r.Status 'unchanged' 'clean status'
    Assert-Same $script:Log.Count 0 'clean changes nothing'
    Assert-Same (@(Backups).Count) 0 'clean writes no backup'
    $line = ConvertTo-DnJobLine $r | ConvertFrom-Json
    Assert-Same $line.job 'remove-eol-dotnet' 'line job'
    Assert-True ($line.before -is [System.Array]) 'clean before is array'
    Assert-Same $line.before.Count 0 'clean before empty'

    # 2. -ReportOnly with .NET 7.0.7, 7.0.20, and 5.0.17: drift exit 1, no backup, no uninstallers run.
    $bundle707 = 'C:\ProgramData\Package Cache\{11111111-1111-1111-1111-111111111111}\windowsdesktop-runtime-7.0.7-win-x64.exe'
    $msi707 = '{ECCA3DB0-6DEF-42CD-A21A-F2F7B918FB59}'
    $msi7020 = '{221BB52A-B763-4C9D-AA62-4B0B6C9AAD62}'
    $msiAsp707 = '{4A749A1A-B799-41B4-A328-33A7B2355E76}'
    $msi517 = '{AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA}'
    $drift = @(
        (New-Entry -Id '{11111111-1111-1111-1111-111111111111}' -Name 'Microsoft Windows Desktop Runtime - 7.0.7 (x64)' -Version '7.0.7.32525' -BundleCachePath $bundle707 -QuietUninstall "`"$bundle707`" /uninstall /quiet"),
        (New-Entry -Id $msi707 -Name 'Microsoft .NET Runtime - 7.0.7 (x64)' -Version '56.31.61636' -Uninstall "MsiExec.exe /X$msi707" -Msi $true),
        (New-Entry -Id $msiAsp707 -Name 'Microsoft ASP.NET Core 7.0.7 - Shared Framework (x64)' -Version '7.0.7.23274' -Msi $true),
        (New-Entry -Id $msi7020 -Name 'Microsoft .NET Runtime - 7.0.20 (x64)' -Version '56.80.15184' -Msi $true),
        (New-Entry -Id $msi517 -Name 'Microsoft Windows Desktop Runtime - 5.0.17 (x64)' -Version '40.68.31219' -Msi $true),
        (New-Entry -Name 'Microsoft .NET Runtime - 6.0.36 (x64)' -Version '48.144.23141' -Msi $true)
    )
    Reset-Test -Entries $drift -ExistingFiles @($bundle707)
    $r = Invoke-DnJob -ReportOnly
    Assert-Same $r.ExitCode 1 'report drift exit'
    Assert-Same $r.Status 'drift' 'report drift status'
    Assert-Same $r.Before.Count 5 'report counts 5 EOL entries (leaves 6.0.36 alone)'
    Assert-Same $r.After.Count 5 'report after unchanged'
    Assert-Same $script:Log.Count 0 'report changes nothing'
    Assert-Same (@(Backups).Count) 0 'report writes no backup'

    # 3. Normal removal: backup written first, verified Burn bundle runs, leftover MSIs removed, rebootRequired=false.
    Reset-Test -Entries $drift -ExistingFiles @($bundle707)
    $r = Invoke-DnJob
    Assert-Same $r.ExitCode 0 'remove exit'
    Assert-Same $r.Status 'removed' 'remove status'
    Assert-Same $r.RebootRequired $false 'no reboot needed on 0'
    Assert-Same $r.Before.Count 5 'before count'
    Assert-Same $r.After.Count 0 'after empty'
    Assert-Same (@(Backups).Count) 1 'one backup written'
    $bundleLogs = @($script:Log | Where-Object { $_ -like 'bundle:*' })
    $msiLogs = @($script:Log | Where-Object { $_ -like 'msi:*' })
    Assert-Same $bundleLogs.Count 1 'bundle ran once'
    Assert-Same $bundleLogs[0] "bundle:$bundle707|/uninstall /quiet /norestart" 'bundle args'
    Assert-Same $msiLogs.Count 2 'remaining two MSIs (7.0.20 and 5.0.17) uninstalled via msiexec'
    Assert-Same $script:FakeEntries.Count 1 '6.0.36 left untouched'

    # 4. Untrusted bundle path (outside Package Cache) and reparse point bundle path are never executed; MSI fallback still cleans valid MSIs.
    $evilBundle = 'C:\Temp\evil.exe'
    $reparseBundle = 'C:\ProgramData\Package Cache\{22222222-2222-2222-2222-222222222222}\dotnet.exe'
    $badBundles = @(
        (New-Entry -Id '{33333333-3333-3333-3333-333333333333}' -Name 'Microsoft .NET Runtime - 7.0.7 (x64)' -Version '7.0.7.0' -BundleCachePath $evilBundle -QuietUninstall "`"$evilBundle`" /uninstall /quiet"),
        (New-Entry -Id '{22222222-2222-2222-2222-222222222222}' -Name 'Microsoft .NET Runtime - 5.0.17 (x64)' -Version '5.0.17.0' -BundleCachePath $reparseBundle -QuietUninstall "`"$reparseBundle`" /uninstall /quiet"),
        (New-Entry -Id $msi7020 -Name 'Microsoft .NET Runtime - 7.0.20 (x64)' -Version '56.80.15184' -Msi $true)
    )
    Reset-Test -Entries $badBundles -ExistingFiles @($evilBundle, $reparseBundle)
    [void]$script:ReparsePaths.Add($reparseBundle)
    $r = Invoke-DnJob
    $ranBundles = @($script:Log | Where-Object { $_ -like 'bundle:*' })
    Assert-Same $ranBundles.Count 0 'untrusted or reparse bundle never executed'
    Assert-Same $r.ExitCode 2 'unremovable non-MSI bundle leaves entry -> failed'
    Assert-Same $r.Status 'failed' 'failed when unverified bundle entries remain'
    $ranMsi = @($script:Log | Where-Object { $_ -like 'msi:*' })
    Assert-Same $ranMsi.Count 1 'valid MSI still cleaned'

    # 5. Exit 3010 marks rebootRequired=true and still succeeds when 0 entries remain.
    Reset-Test -Entries @((New-Entry -Id $msi7020 -Name 'Microsoft .NET Runtime - 7.0.20 (x64)' -Version '56.80.15184' -Msi $true))
    $script:MsiExitCode = 3010
    $r = Invoke-DnJob
    Assert-Same $r.ExitCode 0 '3010 exit 0'
    Assert-Same $r.Status 'removed' '3010 removed'
    Assert-Same $r.RebootRequired $true '3010 sets rebootRequired'

    # 6. Untrusted backup parent ACL or non-inheritable backup ACL aborts before running any uninstaller if protection does not fix it, or succeeds after healing pre-existing parent ACL.
    Reset-Test -Entries @((New-Entry -Id $msi7020 -Name 'Microsoft .NET Runtime - 7.0.20 (x64)' -Version '56.80.15184' -Msi $true))
    $script:FakeParentSddl = 'O:SYG:SYD:(A;OICI;FA;;;WD)'
    $r = Invoke-DnJob
    Assert-Same $r.ExitCode 2 'bad parent ACL exit 2'
    Assert-Same $r.Status 'failed' 'bad parent ACL status failed'
    Assert-Same (@($script:Log | Where-Object { $_ -like 'msi:*' -or $_ -like 'bundle:*' }).Count) 0 'no uninstaller ran on backup failure'

    Reset-Test -Entries @((New-Entry -Id $msi7020 -Name 'Microsoft .NET Runtime - 7.0.20 (x64)' -Version '56.80.15184' -Msi $true))
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $script:DnBackupDir) -Force
    $script:FakeParentSddl = 'O:SYG:SYD:(A;OICI;FA;;;WD)'
    $origDnProtect = $script:DnProtectDir
    $script:DnProtectDir = {
        param($Path)
        $script:Log.Add("protect:$Path")
        if ($Path -eq (Split-Path -Parent $script:DnBackupDir)) {
            $script:FakeParentSddl = 'O:SYG:SYD:P(A;OICI;FA;;;SY)'
        }
    }
    $rHeal = Invoke-DnJob
    $script:DnProtectDir = $origDnProtect
    Assert-Same $rHeal.ExitCode 0 'healed parent ACL exit 0'
    Assert-Same $rHeal.Status 'removed' 'healed parent ACL removed'

    Assert-True (-not (Test-DnParentAcl 'O:SYG:SYD:AI(A;;FW;;;BU)(A;;FA;;;SY)')) 'rejects FW on parent'
    Assert-True (-not (Test-DnParentAcl 'O:SYG:SYD:AI(A;CIID;0x100116;;;BU)(A;;FA;;;SY)')) 'rejects 0x100116 create-child on parent without IO'
    Assert-True (-not (Test-DnParentAcl 'O:SYG:SYD:P(A;;GAGR;;;BU)(A;;FA;;;SY)')) 'rejects combined GAGR on parent'
    Assert-True (Test-DnParentAcl 'O:SYG:SYD:AI(A;ID;0x1200a9;;;BU)(A;OICIIOID;0x100116;;;BU)(A;;FA;;;SY)') 'accepts ProgramData IO ACE on parent'
    Assert-True (-not (Test-DnBackupAcl 'O:SYG:SYD:P(A;;FA;;;SY)')) 'rejects backup ACL without OICI inheritance'
    Assert-True (Test-DnBackupAcl 'O:SYG:SYD:P(A;OICI;FA;;;SY)') 'accepts backup ACL with OICI inheritance'

    # 7. .NET 6 opt-in, with the .NET 6 entries found on a Server 2022 domain controller on 2026-11-23.
    $hostingId = '{58f3f479-fe1b-4cb4-b547-d6cb9196eac4}'
    $hostingExe = "C:\ProgramData\Package Cache\$hostingId\dotnet-hosting-6.0.16-win.exe"
    $rt64Exe = 'C:\ProgramData\Package Cache\{44444444-4444-4444-4444-444444444444}\dotnet-runtime-6.0.16-win-x64.exe'
    $rt86Exe = 'C:\ProgramData\Package Cache\{55555555-5555-5555-5555-555555555555}\dotnet-runtime-6.0.16-win-x86.exe'
    $azdc6 = @(
        (New-Entry -Root 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' -Id $hostingId -Name 'Microsoft .NET 6.0.16 - Windows Server Hosting' -Version '6.0.16.23174' -BundleCachePath $hostingExe -QuietUninstall "`"$hostingExe`" /uninstall /quiet"),
        (New-Entry -Name 'Microsoft .NET Host - 6.0.16 (x64)' -Version '48.64.23121' -Msi $true),
        (New-Entry -Name 'Microsoft .NET Host - 6.0.16 (x86)' -Version '48.64.23121' -Msi $true),
        (New-Entry -Name 'Microsoft .NET Host FX Resolver - 6.0.16 (x64)' -Version '48.64.23121' -Msi $true),
        (New-Entry -Name 'Microsoft .NET Host FX Resolver - 6.0.16 (x86)' -Version '48.64.23121' -Msi $true),
        (New-Entry -Name 'Microsoft .NET Runtime - 6.0.16 (x64)' -Version '48.64.23121' -Msi $true),
        (New-Entry -Name 'Microsoft .NET Runtime - 6.0.16 (x86)' -Version '48.64.23121' -Msi $true),
        (New-Entry -Id '{44444444-4444-4444-4444-444444444444}' -Name 'Microsoft .NET Runtime - 6.0.16 (x64)' -Version '6.0.16.32323' -BundleCachePath $rt64Exe),
        (New-Entry -Id '{55555555-5555-5555-5555-555555555555}' -Name 'Microsoft .NET Runtime - 6.0.16 (x86)' -Version '6.0.16.32323' -BundleCachePath $rt86Exe),
        (New-Entry -Name 'Microsoft ASP.NET Core 6.0.16 - Shared Framework (x64)' -Version '6.0.16.23174' -Msi $true),
        (New-Entry -Name 'Microsoft ASP.NET Core 6.0.16 - Shared Framework (x86)' -Version '6.0.16.23174' -Msi $true),
        (New-Entry -Name 'Microsoft ASP.NET Core 6.0.16 Shared Framework (x64)' -Version '6.0.16.23174' -Msi $true),
        (New-Entry -Name 'Microsoft ASP.NET Core 6.0.16 Shared Framework (x86)' -Version '6.0.16.23174' -Msi $true),
        (New-Entry -Id '{1DB68DD7-07DF-3B9C-A907-3E94A08E4651}' -Name 'Microsoft ASP.NET Core 6.0.16 Hosting Bundle Options' -Version '6.0.16.23174' -Msi $true)
    )
    $keepers = @(
        (New-Entry -Name 'Microsoft .NET 8.0.11 - Windows Server Hosting' -Version '8.0.11.24521'),
        (New-Entry -Name 'Microsoft ASP.NET Core 8.0.11 Hosting Bundle Options' -Version '8.0.11.24521' -Msi $true),
        (New-Entry -Name 'Microsoft .NET Runtime - 8.0.11 (x64)' -Version '64.44.23553' -Msi $true),
        (New-Entry -Name 'Microsoft Windows Desktop Runtime - 9.0.10 (x64)' -Version '72.40.11023' -Msi $true),
        (New-Entry -Name 'Microsoft .NET Runtime - 10.0.14 (x64)' -Version '80.56.61678' -Msi $true),
        (New-Entry -Name 'Microsoft .NET Framework 4.8' -Version '4.8.03761'),
        (New-Entry -Name 'Microsoft .NET Runtime - 6.0.16 (x64)' -Publisher 'ThirdParty' -Version '48.64.23121' -Msi $true)
    )
    $expected6 = @(
        'Microsoft .NET 6.0.16 - Windows Server Hosting',
        'Microsoft .NET Host - 6.0.16 (x64)', 'Microsoft .NET Host - 6.0.16 (x86)',
        'Microsoft .NET Host FX Resolver - 6.0.16 (x64)', 'Microsoft .NET Host FX Resolver - 6.0.16 (x86)',
        'Microsoft .NET Runtime - 6.0.16 (x64)', 'Microsoft .NET Runtime - 6.0.16 (x64)',
        'Microsoft .NET Runtime - 6.0.16 (x86)', 'Microsoft .NET Runtime - 6.0.16 (x86)',
        'Microsoft ASP.NET Core 6.0.16 - Shared Framework (x64)', 'Microsoft ASP.NET Core 6.0.16 - Shared Framework (x86)',
        'Microsoft ASP.NET Core 6.0.16 Shared Framework (x64)', 'Microsoft ASP.NET Core 6.0.16 Shared Framework (x86)',
        'Microsoft ASP.NET Core 6.0.16 Hosting Bundle Options'
    )
    $azdcFiles = @($hostingExe, $rt64Exe, $rt86Exe)

    # 7a. Default: .NET 6 and its Hosting Bundle are left alone.
    Reset-Test -Entries ($azdc6 + $keepers) -ExistingFiles $azdcFiles
    $r = Invoke-DnJob -ReportOnly
    Assert-Same $r.Status 'unchanged' 'default leaves .NET 6 alone'
    Assert-Same $r.Before.Count 0 'default finds no .NET 6 target'

    # 7b. Opt-in ReportOnly lists exactly the .NET 6 entries and changes nothing.
    Reset-Test -Entries ($azdc6 + $keepers) -ExistingFiles $azdcFiles -IncludeDotnet6 $true
    $r = Invoke-DnJob -ReportOnly
    Assert-Same $r.ExitCode 1 'opt-in report exit'
    Assert-Same $r.Status 'drift' 'opt-in report status'
    Assert-Same ((@($r.Before | ForEach-Object { $_.name }) | Sort-Object) -join '|') (($expected6 | Sort-Object) -join '|') 'opt-in report lists the .NET 6 entries'
    Assert-Same $script:Log.Count 0 'opt-in report changes nothing'
    Assert-Same (@(Backups).Count) 0 'opt-in report writes no backup'

    # 7c. Opt-in removal: backup first, three verified bundles, then the leftover MSIs; .NET 8/9/10, Framework and third party stay.
    Reset-Test -Entries ($azdc6 + $keepers) -ExistingFiles $azdcFiles -IncludeDotnet6 $true
    $r = Invoke-DnJob
    Assert-Same $r.Status 'removed' 'opt-in remove status'
    Assert-Same $r.ExitCode 0 'opt-in remove exit'
    Assert-Same (@(Backups).Count) 1 'opt-in backup written'
    Assert-Same (@($script:Log | Where-Object { $_ -like 'bundle:*' }) -join '|') "bundle:$hostingExe|/uninstall /quiet /norestart|bundle:$rt64Exe|/uninstall /quiet /norestart|bundle:$rt86Exe|/uninstall /quiet /norestart" 'opt-in bundles run'
    Assert-Same (@($script:Log | Where-Object { $_ -like 'msi:*' }).Count) 11 'opt-in leftover MSIs run'
    Assert-Same ((@($script:FakeEntries | ForEach-Object { $_.name }) | Sort-Object) -join '|') ((@($keepers | ForEach-Object { $_.name }) | Sort-Object) -join '|') 'opt-in leaves .NET 8/9/10, Framework and third party'

    # 7d. Opt-in refuses the .NET 6 Hosting Bundle while the shared IIS ASP.NET Core Module is the .NET 6 one (16.x),
    # even with a .NET 8 Hosting Bundle listed (installed with OPT_NO_ANCM=1). ANCM file majors: 6.0 = 16, 8.0 = 18 (dotnet.microsoft.com download pages).
    $refuseText = 'refusing .NET 6 Hosting Bundle: the IIS ASP.NET Core Module is not from a .NET 8 or later Hosting Bundle'
    Reset-Test -Entries ($azdc6 + $keepers) -ExistingFiles $azdcFiles -IncludeDotnet6 $true -AncmMajors @(16)
    $r = Invoke-DnJob
    Assert-Same $r.ExitCode 2 'ANCM 16 exit'
    Assert-Same $r.Status 'failed' 'ANCM 16 status'
    Assert-Same $r.Error $refuseText 'ANCM 16 error'
    Assert-Same $script:Log.Count 0 'ANCM 16 runs nothing'
    Assert-Same (@(Backups).Count) 0 'ANCM 16 writes no backup'
    Reset-Test -Entries ($azdc6 + $keepers) -ExistingFiles $azdcFiles -IncludeDotnet6 $true -AncmMajors @(18, 16)
    $r = Invoke-DnJob -ReportOnly
    Assert-Same $r.Status 'drift' 'ANCM 18 and 16 report status'
    Assert-Same $r.Error $refuseText 'ANCM 18 and 16 report error (any 16 copy refuses)'
    Reset-Test -Entries ($azdc6 + $keepers) -ExistingFiles $azdcFiles -IncludeDotnet6 $true -AncmMajors @(18)
    $script:AncmThrows = $true
    $r = Invoke-DnJob
    Assert-Same $r.Status 'failed' 'ANCM read failure status'
    Assert-Same $script:Log.Count 0 'ANCM read failure runs nothing'

    # 7e. No ASP.NET Core Module at all: nothing in IIS to break, so the Hosting Bundle goes.
    Reset-Test -Entries ($azdc6 + $keepers) -ExistingFiles $azdcFiles -IncludeDotnet6 $true -AncmMajors @()
    $r = Invoke-DnJob
    Assert-Same $r.Status 'removed' 'no ANCM removed'

    # 8. remove-eol-dotnet-6.ps1 is the base module with the opt-in line flipped, and nothing else.
    $baseLines = [IO.File]::ReadAllLines($modulePath)
    $sixLines = [IO.File]::ReadAllLines($module6Path)
    Assert-Same $sixLines.Count $baseLines.Count 'opt-in module line count'
    $diff = @(for ($i = 0; $i -lt $baseLines.Count; $i++) { if ($baseLines[$i] -cne $sixLines[$i]) { "$($baseLines[$i]) => $($sixLines[$i])" } })
    Assert-Same ($diff -join '|') '$script:DnIncludeDotnet6 = $false => $script:DnIncludeDotnet6 = $true' 'opt-in module differs only in the opt-in line'
    . $module6Path
    Assert-Same ((@(Get-DnTargets ($azdc6 + $keepers)) | ForEach-Object { $_.name } | Sort-Object) -join '|') (($expected6 | Sort-Object) -join '|') 'opt-in module targets the .NET 6 entries'
} finally {
    if (Test-Path -LiteralPath $tmpRoot) { Remove-Item -LiteralPath $tmpRoot -Recurse -Force }
}

Write-Host 'PASS remove-eol-dotnet'
