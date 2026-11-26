# Remediation module, run by windows/runner/Invoke-RelianJob.ps1 as SYSTEM. Makes every installed printer default to
# black and white and one-sided, and clears each user's saved per-printer preferences that say colour or two-sided, so
# they inherit that default. Staff can still pick colour or two-sided for one job.
# Machine default: Set-PrintConfiguration -Color $false -DuplexingMode OneSided, only the setting that is wrong; a driver
# that ignores it gets the same change through its default DEVMODE. A printer with a job in its queue is not touched
# (status busy, run again later). PDF, OneNote, XPS, fax and image printers are left alone.
# Users: HKU\<sid>\Printers\DevModePerUser and DevModes2. A value is deleted (not rewritten) when it is not monochrome or
# says two-sided; the printer then uses the machine default. Signed-in users are read in their loaded hive. Signed-out
# users' NTUSER.DAT is loaded under HKU\RelianPD_<sid> only when not in use, and always unloaded; a mount left by an
# earlier run is unloaded first. A hive that will not unload fails the run.
# Colour options (a Colour/Color name, -KeepColourPattern, or a plain queue with a "<name> BW" twin) keep colour and
# are still made one-sided, machine and user. The job loader forwards only -ReportOnly, so the default pattern is what runs.
# -ReportOnly changes nothing (hives are still loaded to be read, and unloaded).
# Exit 0 compliant or changed, 1 drift under -ReportOnly or a busy printer, 2 failed. Prints one JSON line.
[CmdletBinding()]
param([switch]$ReportOnly, [string]$KeepColourPattern = '(?i)\bcolou?r\b')

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:PdMountPrefix = 'RelianPD_'
$script:PdKeepColourPattern = $KeepColourPattern
$script:PdSkipPattern = 'PDF|OneNote|XPS|Fax|Image Printer|Microsoft Print to|Send To|Root Print Queue'

function Test-PdSkipPrinter {
    param([string]$Name, [AllowEmptyString()][string]$Driver)
    return ($Name -match $script:PdSkipPattern) -or ($Driver -match $script:PdSkipPattern)
}

# The colour option of a printer keeps colour: a name matching the pattern (Colour/Color), or a plain queue whose
# "<name> BW" twin exists. It is still made one-sided.
function Test-PdKeepColour {
    param([string]$Name, [string[]]$AllNames = @(), [string]$Pattern = $script:PdKeepColourPattern)
    return ($Name -match $Pattern) -or ($AllNames -contains "$Name BW")
}

# DEVMODEW: dmFields (uint32) at 72, dmColor at 92 (1 mono, 2 colour), dmDuplex at 94 (1 simplex, 2/3 two-sided).
# A field whose dmFields bit is clear does not override the printer default, so it is fine.
function Test-PdUserDevModeOk {
    param([byte[]]$Bytes, [switch]$KeepColour)
    if ($null -eq $Bytes -or $Bytes.Length -lt 96) { return $false }
    $fields = [BitConverter]::ToUInt32($Bytes, 72)
    if (-not $KeepColour -and ($fields -band 0x800) -and [BitConverter]::ToInt16($Bytes, 92) -ne 1) { return $false }
    if (($fields -band 0x1000) -and [BitConverter]::ToInt16($Bytes, 94) -ne 1) { return $false }
    return $true
}

function Format-PdConfig {
    param($Config)
    if ($null -eq $Config) { return '' }
    $s = '{0}/{1}' -f $(if ($Config.Color) { 'color' } else { 'mono' }), $Config.Duplex
    if ($Config.PSObject.Properties['Ticket'] -and $Config.Ticket) { $s += '/ticket:' + $Config.Ticket }
    return $s
}

function Test-PdConfigOk {
    param($Config, [switch]$KeepColour)
    $ticketColour = $Config.PSObject.Properties['Ticket'] -and $Config.Ticket -and $Config.Ticket -notmatch '^(Monochrome|Grayscale)$'
    return ($KeepColour -or (-not $Config.Color -and -not $ticketColour)) -and ([string]$Config.Duplex -eq 'OneSided')
}

# --- seams (the tests replace these)
$script:PdGetPrinters = {
    @(Get-Printer -ErrorAction Stop | ForEach-Object { [pscustomobject]@{ Name = [string]$_.Name; Driver = [string]$_.DriverName } })
}
$script:PdGetConfig = {
    param($Name)
    $c = Get-PrintConfiguration -PrinterName $Name -ErrorAction Stop
    # The driver's own reading of its default, private DEVMODE included: the PrintTicket PageOutputColor option.
    $ticket = ''
    if ([string]$c.PrintTicketXML -match 'PageOutputColor"\s*>\s*<psf:Option name="(?:[a-z0-9]+:)?([A-Za-z]+)"') { $ticket = $Matches[1] }
    [pscustomobject]@{ Color = [bool]$c.Color; Duplex = [string]$c.DuplexingMode; Ticket = $ticket }
}
$script:PdSetConfig = {
    param($Name, $Color, $Duplex)
    $a = @{ PrinterName = $Name; ErrorAction = 'Stop' }
    if ($null -ne $Color) { $a.Color = [bool]$Color }
    if ($null -ne $Duplex) { $a.DuplexingMode = [string]$Duplex }
    Set-PrintConfiguration @a
}
$script:PdJobCount = {
    param($Name)
    # Stop: an unreadable queue must not count as empty.
    @(Get-PrintJob -PrinterName $Name -ErrorAction Stop).Count
}
$script:PdSetDevMode = {
    param($Name, $KeepColour)
    Initialize-PdWinSpool
    $b = [Relian.PrinterDefaultsWinSpool]::ReadDevMode([string]$Name)
    if ($b.Length -lt 96) { throw 'DEVMODE too small' }
    $fields = [BitConverter]::ToUInt32($b, 72) -bor [uint32]0x1000
    if (-not $KeepColour) { $fields = $fields -bor [uint32]0x0800; [Array]::Copy([BitConverter]::GetBytes([int16]1), 0, $b, 92, 2) }
    [Array]::Copy([BitConverter]::GetBytes([int16]1), 0, $b, 94, 2)
    [Array]::Copy([BitConverter]::GetBytes([uint32]$fields), 0, $b, 72, 4)
    [Relian.PrinterDefaultsWinSpool]::WriteDevMode([string]$Name, $b)
}
$script:PdHiveNames = {
    $u = [Microsoft.Win32.Registry]::Users
    @($u.GetSubKeyNames())
}
# Profiles with a hive file on disk. ProfileList, not C:\Users, so Entra (S-1-12-1) and domain accounts both count.
$script:PdProfiles = {
    $base = 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
    $k = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($base)
    try {
        foreach ($sid in @($k.GetSubKeyNames())) {
            if ($sid -notmatch '^S-1-(5-21|12-1)-[\d-]+$') { continue }
            $p = $k.OpenSubKey($sid)
            try { $path = [string]$p.GetValue('ProfileImagePath') } finally { $p.Dispose() }
            if ($path -and (Test-Path -LiteralPath (Join-Path $path 'NTUSER.DAT'))) { [pscustomobject]@{ Sid = $sid; Path = $path } }
        }
    } finally { $k.Dispose() }
}
# 'ok', 'in-use' (a sharing violation: its user is signed in elsewhere, or a service holds it), or reg.exe's error.
$script:PdLoadHive = {
    param($Mount, $File)
    $out = (& reg.exe load "HKU\$Mount" $File 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -eq 0) { return 'ok' }
    if ($out -match 'being used by another process') { return 'in-use' }
    return $out
}
# Handles this process opened keep the hive loaded, so collect them first and retry.
$script:PdUnloadHive = {
    param($Mount)
    for ($i = 0; $i -lt 5; $i++) {
        [GC]::Collect(); [GC]::WaitForPendingFinalizers()
        $null = & reg.exe unload "HKU\$Mount" 2>&1
        if ($LASTEXITCODE -eq 0) { return $true }
        Start-Sleep -Seconds 2
    }
    return $false
}
$script:PdReadUserValues = {
    param($Root)
    foreach ($key in @('DevModePerUser', 'DevModes2')) {
        $k = [Microsoft.Win32.Registry]::Users.OpenSubKey("$Root\Printers\$key")
        if (-not $k) { continue }
        try {
            foreach ($n in @($k.GetValueNames())) {
                $v = $k.GetValue($n)
                [pscustomobject]@{ Key = $key; Name = $n; Bytes = $(if ($v -is [byte[]]) { $v } else { [byte[]]@() }) }
            }
        } finally { $k.Dispose() }
    }
}
$script:PdDeleteUserValue = {
    param($Root, $Key, $Name)
    $k = [Microsoft.Win32.Registry]::Users.OpenSubKey("$Root\Printers\$Key", $true)
    if ($k) { try { $k.DeleteValue($Name, $false) } finally { $k.Dispose() } }
}

function Initialize-PdWinSpool {
    if ('Relian.PrinterDefaultsWinSpool' -as [type]) { return }
    $source = @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace Relian {
    public static class PrinterDefaultsWinSpool {
        private const int PRINTER_ALL_ACCESS = 0x000F000C;
        private const int DM_OUT_BUFFER = 2;
        private const int DM_IN_BUFFER = 8;

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct PRINTER_DEFAULTS {
            public IntPtr pDatatype;
            public IntPtr pDevMode;
            public int DesiredAccess;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct PRINTER_INFO_2 {
            public IntPtr pServerName;
            public IntPtr pPrinterName;
            public IntPtr pShareName;
            public IntPtr pPortName;
            public IntPtr pDriverName;
            public IntPtr pComment;
            public IntPtr pLocation;
            public IntPtr pDevMode;
            public IntPtr pSepFile;
            public IntPtr pPrintProcessor;
            public IntPtr pDatatype;
            public IntPtr pParameters;
            public IntPtr pSecurityDescriptor;
            public uint Attributes;
            public uint Priority;
            public uint DefaultPriority;
            public uint StartTime;
            public uint UntilTime;
            public uint Status;
            public uint cJobs;
            public uint AveragePPM;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct PRINTER_INFO_8 {
            public IntPtr pDevMode;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct PRINTER_INFO_9 {
            public IntPtr pDevMode;
        }

        [DllImport("winspool.drv", EntryPoint = "OpenPrinterW", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern bool OpenPrinter(string pPrinterName, out IntPtr phPrinter, ref PRINTER_DEFAULTS pDefault);

        [DllImport("winspool.drv", EntryPoint = "ClosePrinter", SetLastError = true)]
        private static extern bool ClosePrinter(IntPtr hPrinter);

        [DllImport("winspool.drv", EntryPoint = "GetPrinterW", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern bool GetPrinter(IntPtr hPrinter, int Level, IntPtr pPrinter, int cbBuf, out int pcbNeeded);

        [DllImport("winspool.drv", EntryPoint = "SetPrinterW", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern bool SetPrinter(IntPtr hPrinter, int Level, IntPtr pPrinter, int Command);

        [DllImport("winspool.drv", EntryPoint = "DocumentPropertiesW", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern int DocumentProperties(IntPtr hwnd, IntPtr hPrinter, string pDeviceName, IntPtr pDevModeOutput, IntPtr pDevModeInput, int fMode);


        public static byte[] ReadDevMode(string printerName) {
            PRINTER_DEFAULTS defs = new PRINTER_DEFAULTS { DesiredAccess = PRINTER_ALL_ACCESS };
            IntPtr hPrinter;
            if (!OpenPrinter(printerName, out hPrinter, ref defs)) {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "OpenPrinterW failed");
            }
            IntPtr pDevMode = IntPtr.Zero;
            try {
                int dmSize = DocumentProperties(IntPtr.Zero, hPrinter, printerName, IntPtr.Zero, IntPtr.Zero, 0);
                if (dmSize <= 0) {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "DocumentPropertiesW size query failed");
                }
                pDevMode = Marshal.AllocHGlobal(dmSize);
                int rc = DocumentProperties(IntPtr.Zero, hPrinter, printerName, pDevMode, IntPtr.Zero, DM_OUT_BUFFER);
                if (rc < 0) {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "DocumentPropertiesW read failed");
                }
                byte[] bytes = new byte[dmSize];
                Marshal.Copy(pDevMode, bytes, 0, dmSize);
                return bytes;
            } finally {
                if (pDevMode != IntPtr.Zero) {
                    Marshal.FreeHGlobal(pDevMode);
                }
                ClosePrinter(hPrinter);
            }
        }

        public static void WriteDevMode(string printerName, byte[] modifiedDevMode) {
            PRINTER_DEFAULTS defs = new PRINTER_DEFAULTS { DesiredAccess = PRINTER_ALL_ACCESS };
            IntPtr hPrinter;
            if (!OpenPrinter(printerName, out hPrinter, ref defs)) {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "OpenPrinterW failed");
            }
            IntPtr pIn = IntPtr.Zero;
            IntPtr pOut = IntPtr.Zero;
            IntPtr pInfo2 = IntPtr.Zero;
            IntPtr pInfo8 = IntPtr.Zero;
            IntPtr pInfo9 = IntPtr.Zero;
            try {
                if (modifiedDevMode == null || modifiedDevMode.Length < 96) {
                    throw new ArgumentException("DEVMODEW buffer is too small");
                }
                int dmSize = DocumentProperties(IntPtr.Zero, hPrinter, printerName, IntPtr.Zero, IntPtr.Zero, 0);
                if (dmSize <= 0) {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "DocumentPropertiesW size query failed");
                }
                int outSize = Math.Max(dmSize, modifiedDevMode.Length);
                pIn = Marshal.AllocHGlobal(modifiedDevMode.Length);
                Marshal.Copy(modifiedDevMode, 0, pIn, modifiedDevMode.Length);
                pOut = Marshal.AllocHGlobal(outSize);
                int rc = DocumentProperties(IntPtr.Zero, hPrinter, printerName, pOut, pIn, DM_IN_BUFFER | DM_OUT_BUFFER);
                if (rc < 0) {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "DocumentPropertiesW update failed");
                }

                int needed = 0;
                GetPrinter(hPrinter, 2, IntPtr.Zero, 0, out needed);
                if (needed <= 0) {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "GetPrinterW level 2 size failed");
                }
                pInfo2 = Marshal.AllocHGlobal(needed);
                if (!GetPrinter(hPrinter, 2, pInfo2, needed, out needed)) {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "GetPrinterW level 2 failed");
                }
                PRINTER_INFO_2 info2 = (PRINTER_INFO_2)Marshal.PtrToStructure(pInfo2, typeof(PRINTER_INFO_2));
                info2.pDevMode = pOut;
                info2.pSecurityDescriptor = IntPtr.Zero;
                Marshal.StructureToPtr(info2, pInfo2, false);
                if (!SetPrinter(hPrinter, 2, pInfo2, 0)) {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "SetPrinterW level 2 failed");
                }

                PRINTER_INFO_8 info8 = new PRINTER_INFO_8 { pDevMode = pOut };
                pInfo8 = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(PRINTER_INFO_8)));
                Marshal.StructureToPtr(info8, pInfo8, false);
                if (!SetPrinter(hPrinter, 8, pInfo8, 0)) {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "SetPrinterW level 8 failed");
                }

                PRINTER_INFO_9 info9 = new PRINTER_INFO_9 { pDevMode = pOut };
                pInfo9 = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(PRINTER_INFO_9)));
                Marshal.StructureToPtr(info9, pInfo9, false);
                SetPrinter(hPrinter, 9, pInfo9, 0);
            } finally {
                if (pInfo9 != IntPtr.Zero) {
                    Marshal.FreeHGlobal(pInfo9);
                }
                if (pInfo8 != IntPtr.Zero) {
                    Marshal.FreeHGlobal(pInfo8);
                }
                if (pInfo2 != IntPtr.Zero) {
                    Marshal.FreeHGlobal(pInfo2);
                }
                if (pOut != IntPtr.Zero) {
                    Marshal.FreeHGlobal(pOut);
                }
                if (pIn != IntPtr.Zero) {
                    Marshal.FreeHGlobal(pIn);
                }
                ClosePrinter(hPrinter);
            }
        }
    }
}
'@
    Add-Type -TypeDefinition $source -ErrorAction Stop
}

function Invoke-PdPrinter {
    param($Printer, [string[]]$AllNames = @(), [switch]$ReportOnly)
    $keep = Test-PdKeepColour -Name $Printer.Name -AllNames $AllNames
    $e = [ordered]@{ name = $Printer.Name; status = ''; keepColour = $keep; before = ''; after = ''; error = '' }
    if (Test-PdSkipPrinter -Name $Printer.Name -Driver $Printer.Driver) { $e.status = 'skipped'; return $e }
    try {
        $cfg = & $script:PdGetConfig $Printer.Name
        $e.before = Format-PdConfig $cfg
        $e.after = $e.before
        if (Test-PdConfigOk $cfg -KeepColour:$keep) { $e.status = 'unchanged'; return $e }
        if ($ReportOnly) { $e.status = 'drift'; return $e }
        if ((& $script:PdJobCount $Printer.Name) -gt 0) { $e.status = 'busy'; return $e }
        $color = $(if ($cfg.Color -and -not $keep) { $false } else { $null })
        $duplex = $(if ([string]$cfg.Duplex -ne 'OneSided') { 'OneSided' } else { $null })
        try { & $script:PdSetConfig $Printer.Name $color $duplex } catch { $e.error = 'Set-PrintConfiguration: ' + $_.Exception.Message }
        $cfg = & $script:PdGetConfig $Printer.Name
        if (-not (Test-PdConfigOk $cfg -KeepColour:$keep)) {
            & $script:PdSetDevMode $Printer.Name $keep
            $cfg = & $script:PdGetConfig $Printer.Name
        }
        $e.after = Format-PdConfig $cfg
        $e.status = $(if (Test-PdConfigOk $cfg -KeepColour:$keep) { 'changed' } else { 'failed' })
    } catch {
        $e.status = 'failed'; $e.error = $_.Exception.Message
    }
    return $e
}

function Invoke-PdUser {
    param([string]$Sid, [string]$Root, $Drivers, [string[]]$Busy = @(), [switch]$ReportOnly)
    $u = [ordered]@{ sid = $Sid; status = 'compliant'; drift = ''; error = '' }
    $values = @(& $script:PdReadUserValues $Root)
    $all = @($Drivers.Keys) + @($values | ForEach-Object { $_.Name })
    $bad = @($values | Where-Object {
            $drv = $(if ($Drivers.ContainsKey($_.Name)) { $Drivers[$_.Name] } else { '' })
            -not (Test-PdSkipPrinter -Name $_.Name -Driver $drv) -and -not (Test-PdUserDevModeOk $_.Bytes -KeepColour:(Test-PdKeepColour -Name $_.Name -AllNames $all))
        })
    $u.drift = (@($bad | ForEach-Object { "$($_.Key)\$($_.Name)" }) -join ';')
    if ($bad.Count -eq 0) { return $u }
    if ($ReportOnly) { $u.status = 'drift'; return $u }
    # A printer with a job in its queue is left alone, its users' preferences too, until a later run.
    $later = @($bad | Where-Object { ($Busy -contains $_.Name) -or ($Drivers.ContainsKey($_.Name) -and (& $script:PdJobCount $_.Name) -gt 0) })
    foreach ($v in @($bad | Where-Object { $later -notcontains $_ })) { & $script:PdDeleteUserValue $Root $v.Key $v.Name }
    $u.status = $(if ($later.Count -gt 0) { 'busy' } else { 'changed' })
    return $u
}

function Invoke-PdJob {
    param([switch]$ReportOnly)
    $r = [ordered]@{ ExitCode = 2; Status = 'failed'; Mode = $(if ($ReportOnly) { 'report' } else { 'run' }); Printers = @(); Users = @(); Error = '' }
    $errors = [Collections.Generic.List[string]]::new()
    try {
        $hives = @(& $script:PdHiveNames)
        foreach ($stale in @($hives | Where-Object { $_ -like "$($script:PdMountPrefix)*" })) {
            if (-not (& $script:PdUnloadHive $stale)) { $errors.Add("could not unload $stale") }
        }

        $printers = @(& $script:PdGetPrinters)
        $drivers = @{}
        foreach ($p in $printers) { $drivers[$p.Name] = $p.Driver }
        $names = @($printers | ForEach-Object { $_.Name })
        $r.Printers = @(foreach ($p in $printers) { [pscustomobject](Invoke-PdPrinter -Printer $p -AllNames $names -ReportOnly:$ReportOnly) })

        $busy = @($r.Printers | Where-Object { $_.status -eq 'busy' } | ForEach-Object { $_.name })
        $loaded = @($hives | Where-Object { $_ -match '^S-1-(5-21|12-1)-[\d-]+$' })
        $profiles = @(& $script:PdProfiles)
        $sids = [Collections.Generic.List[string]]::new()
        foreach ($s in @($loaded) + @($profiles | ForEach-Object { $_.Sid })) { if ($s -and -not $sids.Contains($s)) { $sids.Add($s) } }
        $users = foreach ($sid in $sids) {
            $root = $sid; $mount = $null; $u = $null
            try {
                if ($loaded -notcontains $sid) {
                    $prof = @($profiles | Where-Object { $_.Sid -eq $sid })[0]
                    $load = [string](& $script:PdLoadHive ($script:PdMountPrefix + $sid) ($prof.Path.TrimEnd('\') + '\NTUSER.DAT'))
                    if ($load -eq 'in-use') {
                        $u = [ordered]@{ sid = $sid; status = 'in-use'; drift = ''; error = '' }
                    } elseif ($load -ne 'ok') {
                        $u = [ordered]@{ sid = $sid; status = 'failed'; drift = ''; error = 'hive load: ' + $load }
                    } else {
                        $mount = $script:PdMountPrefix + $sid; $root = $mount
                    }
                }
                if (-not $u) { $u = Invoke-PdUser -Sid $sid -Root $root -Drivers $drivers -Busy $busy -ReportOnly:$ReportOnly }
            } catch {
                $u = [ordered]@{ sid = $sid; status = 'failed'; drift = ''; error = $_.Exception.Message }
            } finally {
                if ($mount -and -not (& $script:PdUnloadHive $mount)) {
                    $errors.Add("could not unload $mount")
                    if ($u) { $u.status = 'failed' }
                }
            }
            [pscustomobject]$u
        }
        $r.Users = @($users)
    } catch {
        $errors.Add($_.Exception.Message)
    }

    $all = @($r.Printers | ForEach-Object { $_.status }) + @($r.Users | ForEach-Object { $_.status })
    if ($errors.Count -gt 0 -or $all -contains 'failed') { $r.Status = 'failed'; $r.ExitCode = 2 }
    elseif ($all -contains 'drift') { $r.Status = 'drift'; $r.ExitCode = 1 }
    elseif ($all -contains 'busy') { $r.Status = 'busy'; $r.ExitCode = 1 }
    elseif ($all -contains 'changed') { $r.Status = 'changed'; $r.ExitCode = 0 }
    else { $r.Status = 'compliant'; $r.ExitCode = 0 }
    $r.Error = ($errors -join '; ')
    return [pscustomobject]$r
}

function ConvertTo-PdJobLine {
    param([Parameter(Mandatory)]$Result)
    [ordered]@{
        job = 'printer-defaults'; host = $env:COMPUTERNAME; utc = [DateTime]::UtcNow.ToString('o')
        mode = $Result.Mode; status = $Result.Status; printers = @($Result.Printers); users = @($Result.Users); error = $Result.Error
    } | ConvertTo-Json -Compress -Depth 5
}

# Dot-sourcing under test defines functions and changes nothing.
if ($env:RELIAN_DEPLOY_TEST -eq '1' -and $MyInvocation.InvocationName -eq '.') {
    return
}

$jobResult = Invoke-PdJob -ReportOnly:$ReportOnly
Write-Output (ConvertTo-PdJobLine $jobResult)
exit $jobResult.ExitCode
