<# .SYNOPSIS
Bounded storage evidence and explicitly requested conservative cleanup. No reboot.
Logical bytes are observations, not guaranteed reclaimable physical space.
#>
[CmdletBinding()]
param([string]$DeploymentType, [string]$Action, [string]$PinVersion,
 [string]$Mode='Report', [string]$TempAgeDays='7', [string]$ProfileAgeDays='180',
 [string]$RemoveProfiles='false', [string]$ExcludeProfiles='', [string]$ComponentCleanup='false',
 [string]$MaxFiles='20000', [string]$MaxSeconds='30')

function Get-SmArguments {
 param([string]$Mode='Report',[string]$TempAgeDays='7',[string]$ProfileAgeDays='180',
 [string]$RemoveProfiles='false',[string]$ExcludeProfiles='', [string]$ComponentCleanup='false',
 [string]$MaxFiles='20000',[string]$MaxSeconds='30')
 if ($Mode -cnotin @('Report','Cleanup')) { throw 'Mode must be Report or Cleanup' }
 $a=@{ Mode=$Mode; ExcludeProfiles=@($ExcludeProfiles.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
 foreach($b in @(@('RemoveProfiles',$RemoveProfiles),@('ComponentCleanup',$ComponentCleanup))) {
  if ($b[1] -cnotin @('true','false')) { throw "$($b[0]) must be true or false" }; $a[$b[0]]=$b[1] -ceq 'true'
 }
 foreach($n in @(@('TempAgeDays',$TempAgeDays,1,365),@('ProfileAgeDays',$ProfileAgeDays,30,3650),@('MaxFiles',$MaxFiles,1,2000000),@('MaxSeconds',$MaxSeconds,1,1800))) {
  if ($n[1] -notmatch '^\d{1,7}$' -or [int]$n[1] -lt $n[2] -or [int]$n[1] -gt $n[3]) { throw "Invalid $($n[0])" }; $a[$n[0]]=[int]$n[1]
 }; return $a
}

function Test-SmProfile {
 param($Profile,[int]$AgeDays,[string[]]$Exclusions,[datetime]$Now=[datetime]::UtcNow)
 $reason='eligible'; $last=$null
 try { if ($Profile.LastUseTime) { $last=([datetime]$Profile.LastUseTime).ToUniversalTime() } } catch {}
 if ($Profile.Loaded -ne $false -or $Profile.Special -ne $false) { $reason='loaded/special/unknown' }
 elseif ($Profile.SID -notmatch '^S-1-(5-21-|12-1-)') { $reason='protected SID' }
 elseif ($Profile.LocalPath -notmatch '^[A-Za-z]:\\Users\\[^\\]+$' -or (Split-Path $Profile.LocalPath -Leaf) -match '^(Public|Default.*|All Users|Administrator|defaultuser.*)$') { $reason='protected path' }
 elseif ($Exclusions -contains $Profile.SID -or $Exclusions -contains $Profile.LocalPath -or $Profile.LocalPath -eq $env:USERPROFILE) { $reason='excluded/current' }
 elseif (-not $last -or $last -gt $Now -or $last -gt $Now.AddDays(-$AgeDays)) { $reason='recent/unknown age' }
 [pscustomobject]@{ SID=$Profile.SID; Path=$Profile.LocalPath; LastUseTime=$last; Eligible=($reason -eq 'eligible'); Reason=$reason; LogicalBytes=$null; SizePartial=$true }
}

# Literal canonical containment and EVERY ancestor checked immediately before deletion.
# Reparse points and offline/recall files are never enumerated or deleted.
function Test-SmSafePath {
 param([string]$Path,[string]$Root)
 try {
  if ($Path.IndexOfAny([char[]]'*?[]') -ge 0 -or $Path -match '(^\\\\|:)+' -and $Path -notmatch '^[A-Za-z]:\\') { return $false }
  $r=[IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar)
  $p=[IO.Path]::GetFullPath($Path)
  if (-not $p.StartsWith($r+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { return $false }
  $cur=$p
  while ($cur) {
   $item=Get-Item -LiteralPath $cur -Force -ErrorAction Stop
   if (([int64]$item.Attributes -band (1024 -bor 4096 -bor 262144 -bor 4194304)) -ne 0) { return $false }
   if ($cur.TrimEnd([IO.Path]::DirectorySeparatorChar) -eq $r) { return $true }
   $cur=[IO.Path]::GetDirectoryName($cur)
  }
 } catch { return $false }; return $false
}

function Get-SmScan {
 param([string[]]$Roots,[int]$FileLimit,[int]$Seconds,[int]$AgeDays)
 $watch=[Diagnostics.Stopwatch]::StartNew(); $files=New-Object Collections.Generic.List[object]; $errors=New-Object Collections.Generic.List[string]
 $folders=@{}; $partial=$false; $visited=0; $skipped=0
 $seen=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
 $queue=New-Object 'Collections.Generic.Queue[object]'
 foreach($root in $Roots) {
  if (Test-Path -LiteralPath $root -PathType Container) { $queue.Enqueue(@($root,$root)) }
 }
 while($queue.Count) {
  if($visited -ge $FileLimit -or $watch.Elapsed.TotalSeconds -ge $Seconds) { $partial=$true; break }
  $pair=$queue.Dequeue(); $dir=$pair[0]; $root=$pair[1]
  if(-not $seen.Add([IO.Path]::GetFullPath($dir))) { continue }
  try {
   if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT -and -not (Test-SmSafePath $dir ([IO.Path]::GetPathRoot($dir)))) { $skipped++; continue }
   $di=Get-Item -LiteralPath $dir -Force -ErrorAction Stop
   if (([int64]$di.Attributes -band (1024 -bor 4096 -bor 262144 -bor 4194304)) -ne 0) { $skipped++; continue }
   # Streaming enumeration; do not materialize an unbounded directory listing.
   foreach($entry in [IO.Directory]::EnumerateFileSystemEntries($dir)) {
    if($visited -ge $FileLimit -or $watch.Elapsed.TotalSeconds -ge $Seconds) { $partial=$true; break }
    $visited++
    try {
     $i=Get-Item -LiteralPath $entry -Force -ErrorAction Stop
     if (([int64]$i.Attributes -band (1024 -bor 4096 -bor 262144 -bor 4194304)) -ne 0) { $skipped++; continue }
     if($i.PSIsContainer) { $queue.Enqueue(@($i.FullName,$root)); continue }
     $f=[pscustomobject]@{ Path=$i.FullName; Root=$root; LogicalBytes=[int64]$i.Length; LastWriteUtc=$i.LastWriteTimeUtc; Old=($i.LastWriteTimeUtc -lt [datetime]::UtcNow.AddDays(-$AgeDays)) }
     $files.Add($f); if(-not $folders.ContainsKey($dir)) { $folders[$dir]=[int64]0 }; $folders[$dir]+=$f.LogicalBytes
    } catch { if($errors.Count -lt 50) { $errors.Add($_.Exception.Message) } }
   }
  } catch { if($errors.Count -lt 50) { $errors.Add($_.Exception.Message) } }
 }
 [pscustomobject]@{ Files=@($files.ToArray()); TopFiles=@($files | Sort-Object LogicalBytes -Descending | Select-Object -First 20); TopFolders=@($folders.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 20 | ForEach-Object { [pscustomobject]@{Path=$_.Key;DirectFileLogicalBytes=$_.Value} }); Partial=$partial; EntriesVisited=$visited; SkippedReparseOrCloud=$skipped; Errors=@($errors.ToArray()); Seconds=$watch.Elapsed.TotalSeconds }
}

function Get-SmGuards {
 $reasons=New-Object Collections.Generic.List[string]; $light=$false
 try {
  if (@(Get-CimInstance Win32_Process -OperationTimeoutSec 5 -ErrorAction Stop | Where-Object { $_.Name -match '^(setup|setuphost|setupprep|dism|sfc|TiWorker|TrustedInstaller|msiexec)\.exe$' }).Count) { $reasons.Add('setup/servicing process'); $light=$true }
  $nativeMarker=Join-Path $env:ProgramData 'Relian\Maintenance\native-active.json'
  if(Test-Path -LiteralPath $nativeMarker -ErrorAction Stop) { $reasons.Add('native-active marker present; verified process reconciliation required'); $light=$true }
  $setup=Get-ItemProperty 'HKLM:\SYSTEM\Setup' -ErrorAction Stop
  foreach($n in @('SystemSetupInProgress','OOBEInProgress','SetupPhase')) { if($setup.$n) { $reasons.Add("Setup $n"); $light=$true } }
  foreach($key in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending','HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired','HKLM:\SYSTEM\Setup\MoSetup\Volatile')) {
   if(Test-Path -LiteralPath $key -ErrorAction Stop) { $reasons.Add($key) }
  }
  $session=Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -ErrorAction Stop
  if($session.PendingFileRenameOperations) { $reasons.Add('pending file rename') }
  foreach($name in @('$WINDOWS.~BT','$WINDOWS.~WS')) { if(Test-Path -LiteralPath (Join-Path $env:SystemDrive $name) -ErrorAction Stop) { $reasons.Add('upgrade staging present') } }
  $state=Join-Path $env:ProgramData 'Relian\FeatureUpgrade\state.json'
  if(Test-Path -LiteralPath $state -ErrorAction Stop) { $s=Get-Content -LiteralPath $state -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop; if($s.status -eq 'staged') { $reasons.Add('feature upgrade staged') } }
 } catch { $reasons.Add('unknown guard: '+$_.Exception.Message); $light=$true }
 [pscustomobject]@{ Safe=($reasons.Count -eq 0); Light=$light; Reasons=@($reasons.ToArray()) }
}

# Protect the local evidence directory before any cleanup is authorized.
function Initialize-SmSecureDirectory {
 param([string]$Path)
 $base=[IO.Path]::GetFullPath($env:ProgramData).TrimEnd('\')
 $full=[IO.Path]::GetFullPath($Path)
 if(-not $full.StartsWith($base+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Evidence path must be under ProgramData' }
 $current=$base
 if(-not (Test-SmSafePath $base ([IO.Path]::GetPathRoot($base)))) { throw 'Reparse ProgramData ancestor refused' }
 foreach($part in $full.Substring($base.Length+1).Split('\')) {
  if(-not $part -or $part -in @('.','..')) { throw 'Invalid evidence directory' }
  $current=Join-Path $current $part
  if(-not (Test-Path -LiteralPath $current -ErrorAction Stop)) { $null=New-Item -ItemType Directory -Path $current -ErrorAction Stop }
  $item=Get-Item -LiteralPath $current -Force -ErrorAction Stop
  if(-not $item.PSIsContainer -or ([int64]$item.Attributes -band 1024) -ne 0) { throw 'Reparse evidence directory refused' }
  $acl=New-Object Security.AccessControl.DirectorySecurity
  $acl.SetSecurityDescriptorSddlForm('O:SYG:SYD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)')
  Set-Acl -LiteralPath $current -AclObject $acl -ErrorAction Stop
 }
 return $full
}
$script:SmPrepareReport={
 $dir=Initialize-SmSecureDirectory (Join-Path $env:ProgramData 'Relian\StorageMaintenance')
 $path=Join-Path $dir ((Get-Date -Format 'yyyyMMddTHHmmss')+'-'+[guid]::NewGuid().ToString('n')+'.json')
 if(-not (Test-SmSafePath $path $dir)) {
  # The new file does not exist yet; validate its ordinary, protected parent.
  if(-not (Test-SmSafePath $dir $env:ProgramData)) { throw 'Unsafe report directory' }
 }
 '{"Status":"started","Note":"Maintenance is running or ended before final evidence persisted"}' | Set-Content -LiteralPath $path -Encoding UTF8 -ErrorAction Stop
 $path
}
$script:SmGuards={ Get-SmGuards }
$script:SmAcquire={ $script:SmMutex=New-Object Threading.Mutex($false,'Global\RelianWindowsMaintenance'); try { $script:SmMutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $true } }
$script:SmRelease={ if($script:SmMutex) { $script:SmMutex.ReleaseMutex(); $script:SmMutex.Dispose() } }
$script:SmVolumes={ @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -OperationTimeoutSec 5 -ErrorAction Stop | Select-Object DeviceID,Size,FreeSpace) }
$script:SmProfiles={ @(Get-CimInstance Win32_UserProfile -OperationTimeoutSec 5 -ErrorAction Stop) }
$script:SmRoots={ @(Join-Path $env:windir 'Temp') }
$script:SmDelete={ param($Path) Remove-Item -LiteralPath $Path -Force -ErrorAction Stop }
$script:SmRemoveProfile={ param($Profile) $Profile | Remove-CimInstance -ErrorAction Stop }
$script:SmProfileHiveLoaded={ param($Sid) Test-Path -LiteralPath ('Registry::HKEY_USERS\'+$Sid) -ErrorAction Stop }
$script:SmDiagnosticRoots={ @($env:ProgramData,$env:ProgramFiles,${env:ProgramFiles(x86)},$env:windir) | Where-Object { $_ } }
$script:SmComponent={
 $logDir=Initialize-SmSecureDirectory (Join-Path $env:ProgramData 'Relian\StorageMaintenance')
 $id=[guid]::NewGuid().ToString('n')
 $markerDir=Initialize-SmSecureDirectory (Join-Path $env:ProgramData 'Relian\Maintenance')
 $markerPath=Join-Path $markerDir 'native-active.json'
 if(Test-Path -LiteralPath $markerPath -ErrorAction Stop) { throw 'Native marker already exists; reconcile exact process identity first' }
 $native=[ordered]@{pid=$null;creationTimeUtc=$null;executable=(Join-Path $env:windir 'System32\dism.exe');phase='startingComponentCleanup';startedUtc=[datetime]::UtcNow.ToString('o');stdoutPath=(Join-Path $logDir ($id+'.stdout.log'));stderrPath=(Join-Path $logDir ($id+'.stderr.log'))}
 $native | ConvertTo-Json -Compress | Set-Content -LiteralPath $markerPath -Encoding UTF8 -ErrorAction Stop
 $p=Start-Process -FilePath (Join-Path $env:windir 'System32\dism.exe') -ArgumentList '/Online /Cleanup-Image /StartComponentCleanup /NoRestart' -RedirectStandardOutput (Join-Path $logDir ($id+'.stdout.log')) -RedirectStandardError (Join-Path $logDir ($id+'.stderr.log')) -PassThru -WindowStyle Hidden
 $native.pid=$p.Id; $native.creationTimeUtc=$p.StartTime.ToUniversalTime().ToString('o'); $native.phase='componentCleanup'
 $native | ConvertTo-Json -Compress | Set-Content -LiteralPath $markerPath -Encoding UTF8 -ErrorAction Stop
 if(-not $p.WaitForExit(300000)) { throw 'Component cleanup still running after five minutes; not terminated; do not start another maintenance job.' }
 # This exact Process instance has exited; never clear a marker on PID lookup alone.
 Remove-Item -LiteralPath $markerPath -Force -ErrorAction Stop
 if($p.ExitCode -notin @(0,3010)) { throw "DISM exit $($p.ExitCode)" }; $p.ExitCode
}
$script:SmEvidence={
 $e=[ordered]@{}
 foreach($class in @('Win32_DiskDrive','Win32_PageFileUsage','Win32_ShadowStorage','Win32_Volume')) {
  try { $e[$class]=@(Get-CimInstance $class -OperationTimeoutSec 5 -ErrorAction Stop | Select-Object -First 20 -Property DeviceID,Model,Status,AllocatedBaseSize,CurrentUsage,AllocatedSpace,UsedSpace,MaxSpace,Capacity,FreeSpace) } catch { $e[$class]=@{Error=$_.Exception.Message} }
 }
 $paths=@('Windows.old','$WINDOWS.~BT','$WINDOWS.~WS','hiberfil.sys','pagefile.sys','Windows\WinSxS','Windows\SoftwareDistribution\Download','Windows\Installer','ProgramData\Package Cache')
 $e['Opportunities']=@($paths | ForEach-Object { $p=Join-Path $env:SystemDrive $_; try { $i=Get-Item -LiteralPath $p -Force -ErrorAction Stop; @{ Path=$p; Present=$true; LogicalBytes=if($i.PSIsContainer){$null}else{$i.Length}; Policy='preserved; no recursive scan' } } catch { @{Path=$p;Present=$null;Error=$_.Exception.Message} } })
 $e['ReservedStorage']='Not queried: servicing command deliberately omitted; inspect with DISM /Get-ReservedStorageState in a separate maintenance window.'
 $e['ComponentStore']='WinSxS logical sizes include hardlinks and are not reclaimable estimates. Optional supported StartComponentCleanup requires clear guards; no ResetBase.'
 $e
}

function Grant-SmThemeReadAccess {
    param([Parameter(Mandatory)][string]$Path)
    $sessions = @(Get-ADTLoggedOnUser -ErrorAction Stop | Where-Object { $_.IsActiveUserSession })
    if (-not $sessions.Count) { throw 'no active user session for dialog theme' }
    foreach ($session in $sessions) {
        [PSADT.ClientServer.ClientPermissions]::Remediate($session.ToRunAsActiveUser(), [IO.FileInfo[]]@($Path))
    }
}

# The user-check package's dialog theme, copied: the runner downloads each package
# as one file by hash, so the two cannot share a file. The mark and subtitle parts
# are left out. The toolkit's client process (PSADT.ClientServer.Client.exe, started
# in the user's session for notice 1, and again through its launcher for the
# countdown) loads this assembly as its AppDomainManager from the .exe.config, so it
# runs inside the process that owns the WPF window although this script runs as
# SYSTEM. A background thread polls the open windows every 150 ms, paints
# SidebarAccentFill and SidebarPanel black, recolours resource keys holding
# "Accent" (OnAccent and Foreground keys white) and whitens text on black buttons.
# It stops about 4 seconds after the last window closes, or after 4000 styled
# polls; what it painted stays. It never touches a dialog result.
function Install-SmDialogTheme {
    param([Parameter(Mandatory)][string]$ClientExe)
    $ErrorActionPreference = 'Stop'
    $dll = Join-Path (Split-Path -Parent $ClientExe) 'RelianRestartNoticeTheme.dll'
    $source = @'
using System;
using System.IO;
using System.Reflection;
using System.Threading;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

[assembly: AssemblyVersion("1.0.0.0")]

namespace Relian.RestartNoticeTheme
{
    public sealed class ThemeDomainManager : AppDomainManager
    {
        public override void InitializeNewDomain(AppDomainSetup appDomainInfo)
        {
            base.InitializeNewDomain(appDomainInfo);
            try
            {
                TryLog("manager loaded");
                var thread = new Thread(Watch);
                thread.IsBackground = true;
                thread.Start();
            }
            catch (Exception ex)
            {
                TryLog(ex.ToString());
            }
        }

        private static void Watch()
        {
            var missing = 0;
            var seen = 0;
            while (seen < 4000 && missing < 25)
            {
                Thread.Sleep(150);
                try
                {
                    var app = Application.Current;
                    if (app == null)
                    {
                        if (seen > 0)
                        {
                            missing++;
                        }
                        continue;
                    }
                    var found = (bool)app.Dispatcher.Invoke(new Func<bool>(StyleOpenWindows));
                    if (found)
                    {
                        seen++;
                        missing = 0;
                    }
                    else if (seen > 0)
                    {
                        missing++;
                    }
                }
                catch (Exception ex)
                {
                    TryLog(ex.Message);
                    if (seen > 0)
                    {
                        missing++;
                    }
                }
            }
        }

        private static bool StyleOpenWindows()
        {
            var app = Application.Current;
            if (app == null || app.Windows.Count == 0)
            {
                return false;
            }
            var black = new SolidColorBrush(Color.FromRgb(0, 0, 0));
            var white = new SolidColorBrush(Color.FromRgb(255, 255, 255));
            black.Freeze();
            white.Freeze();
            Recolor(app.Resources, black, white);
            var any = false;
            foreach (Window window in app.Windows)
            {
                any = true;
                Paint(window, "SidebarAccentFill", black);
                Paint(window, "SidebarPanel", black);
                WhitenBlackButtons(window, white);
            }
            if (any && Interlocked.Exchange(ref styledOnce, 1) == 0)
            {
                TryLog("styled");
            }
            return any;
        }

        private static int styledOnce;

        private static void Paint(DependencyObject root, string name, Brush brush)
        {
            var element = Find(root, name);
            if (element == null)
            {
                return;
            }
            var opacity = element.GetType().GetProperty("Opacity");
            if (opacity != null && opacity.CanWrite)
            {
                opacity.SetValue(element, 1.0, null);
            }
            var fill = element.GetType().GetProperty("Fill");
            if (fill != null && fill.CanWrite)
            {
                fill.SetValue(element, brush, null);
            }
            var background = element.GetType().GetProperty("Background");
            if (background != null && background.CanWrite)
            {
                background.SetValue(element, brush, null);
            }
        }

        private static void WhitenBlackButtons(Window window, Brush white)
        {
            foreach (var name in new[] { "ButtonLeft", "ButtonMiddle", "ButtonRight" })
            {
                var button = Find(window, name) as Button;
                if (button == null || !ButtonLooksBlack(button))
                {
                    continue;
                }
                button.Foreground = white;
                WhitenText(button, white);
            }
        }

        private static bool ButtonLooksBlack(Button button)
        {
            return LooksBlack(button.Background) || LooksBlack(button.BorderBrush) || AnyBlackFill(button);
        }

        private static bool AnyBlackFill(DependencyObject node)
        {
            var border = node as Border;
            if (border != null && LooksBlack(border.Background))
            {
                return true;
            }
            var count = VisualTreeHelper.GetChildrenCount(node);
            for (var i = 0; i < count; i++)
            {
                if (AnyBlackFill(VisualTreeHelper.GetChild(node, i)))
                {
                    return true;
                }
            }
            return false;
        }

        private static bool LooksBlack(Brush brush)
        {
            var solid = brush as SolidColorBrush;
            if (solid == null)
            {
                return false;
            }
            var color = solid.Color;
            return color.A > 200 && color.R < 40 && color.G < 40 && color.B < 40;
        }

        private static void WhitenText(DependencyObject node, Brush white)
        {
            var block = node as TextBlock;
            if (block != null)
            {
                block.Foreground = white;
            }
            var access = node as AccessText;
            if (access != null)
            {
                access.Foreground = white;
            }
            var count = VisualTreeHelper.GetChildrenCount(node);
            for (var i = 0; i < count; i++)
            {
                WhitenText(VisualTreeHelper.GetChild(node, i), white);
            }
        }

        private static FrameworkElement Find(DependencyObject node, string name)
        {
            var named = node as FrameworkElement;
            if (named != null && named.Name == name)
            {
                return named;
            }
            var window = node as Window;
            if (window != null)
            {
                var found = window.FindName(name) as FrameworkElement;
                if (found != null)
                {
                    return found;
                }
            }
            var count = VisualTreeHelper.GetChildrenCount(node);
            for (var i = 0; i < count; i++)
            {
                var child = Find(VisualTreeHelper.GetChild(node, i), name);
                if (child != null)
                {
                    return child;
                }
            }
            return null;
        }

        private static void Recolor(ResourceDictionary dictionary, Brush black, Brush white)
        {
            if (dictionary == null)
            {
                return;
            }
            try
            {
                var keys = new object[dictionary.Keys.Count];
                dictionary.Keys.CopyTo(keys, 0);
                foreach (var key in keys)
                {
                    var label = key == null ? string.Empty : key.ToString();
                    if (label.IndexOf("Accent", StringComparison.OrdinalIgnoreCase) < 0)
                    {
                        continue;
                    }
                    var lightText = label.IndexOf("OnAccent", StringComparison.OrdinalIgnoreCase) >= 0
                        || label.IndexOf("Foreground", StringComparison.OrdinalIgnoreCase) >= 0;
                    try
                    {
                        var value = dictionary[key];
                        if (value is SolidColorBrush)
                        {
                            dictionary[key] = lightText ? (object)white : black;
                        }
                        else if (value is Color)
                        {
                            dictionary[key] = lightText ? (object)Colors.White : Colors.Black;
                        }
                    }
                    catch
                    {
                    }
                }
            }
            catch
            {
            }
            foreach (ResourceDictionary child in dictionary.MergedDictionaries)
            {
                Recolor(child, black, white);
            }
        }

        private static void TryLog(string message)
        {
            try
            {
                var dir = Path.GetDirectoryName(typeof(ThemeDomainManager).Assembly.Location);
                File.AppendAllText(Path.Combine(dir, "relian-dialog-theme.log"), message + Environment.NewLine);
            }
            catch
            {
            }
        }
    }
}
'@

    if (Test-Path -LiteralPath $dll) { Remove-Item -LiteralPath $dll -Force }
    Add-Type -TypeDefinition $source -OutputAssembly $dll -ReferencedAssemblies @('System', 'System.Xaml', 'WindowsBase', 'PresentationCore', 'PresentationFramework')
    Grant-SmThemeReadAccess -Path $dll
    $fullName = [System.Reflection.AssemblyName]::GetAssemblyName($dll).FullName
    # The config is written last, after the assembly exists: a config naming a
    # missing or unreadable assembly would stop the client process from starting.
    $configPath = "$ClientExe.config"
    [xml]$config = [System.IO.File]::ReadAllText($configPath)
    $runtime = $config.configuration.runtime
    if ($null -eq $runtime) { throw 'client config has no runtime element' }
    foreach ($name in @('appDomainManagerAssembly', 'appDomainManagerType')) {
        foreach ($node in @($runtime.ChildNodes | Where-Object { $_.LocalName -eq $name })) { [void]$runtime.RemoveChild($node) }
    }
    $assemblyNode = $config.CreateElement('appDomainManagerAssembly')
    [void]$assemblyNode.SetAttribute('value', $fullName)
    [void]$runtime.AppendChild($assemblyNode)
    $typeNode = $config.CreateElement('appDomainManagerType')
    [void]$typeNode.SetAttribute('value', 'Relian.RestartNoticeTheme.ThemeDomainManager')
    [void]$runtime.AppendChild($typeNode)
    $config.Save($configPath)
    Write-Verbose 'dialog theme installed'
}


$script:SmUiOpen=$false
$script:SmThemeError=$null
$script:SmUi={ param($Step)
 if(-not $script:SmUiOpen) {
  $module=Join-Path $PSScriptRoot 'PSAppDeployToolkit\PSAppDeployToolkit.psd1'
  Import-Module -FullyQualifiedName @{ModuleName=$module;ModuleVersion='4.1.8';Guid='8c3c366b-8606-4576-9f2d-4051144f7ca2'} -Force -ErrorAction Stop
  if(-not @(Get-ADTLoggedOnUser | Where-Object { $_.IsActiveUserSession }).Count) { return 'noUser' }
  try {
   $client=Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'PSAppDeployToolkit') -Filter 'PSADT.ClientServer.Client.exe' -Recurse -File | Select-Object -First 1
   if(-not $client) { throw 'Toolkit client not found' }; Install-SmDialogTheme $client.FullName
  } catch { $script:SmThemeError=$_.Exception.Message }
  $null=Open-ADTSession -AppName 'Relian storage maintenance' -AppVersion '1' -DeploymentType Install -DeployMode Interactive -PassThru
  $script:SmUiOpen=$true
 }
 Show-ADTInstallationProgress -StatusMessage $Step
 if($script:SmThemeError) { 'shown; black theme unavailable: '+$script:SmThemeError } else { 'shown' }
}

function ConvertTo-SmSummary {
 param($Report,[string]$ReportPath)
 $summary=[ordered]@{SchemaVersion=1;Status=$Report.Status;Mode=$Report.Mode;ReportPath=$ReportPath;ActionCount=$Report.Actions.Count;GuardReasons=@($Report.Guards.Reasons | Select-Object -First 5);PartialScan=if($Report.Scan){$Report.Scan.Partial}else{$true};FreeSpaceDelta=$Report.FreeSpaceDelta;Notifications=@($Report.Notifications | Select-Object -First 3);Errors=@($Report.Errors | Select-Object -First 3)}
 $json=$summary | ConvertTo-Json -Depth 6 -Compress
 if([Text.Encoding]::UTF8.GetByteCount($json) -gt 8000) {
  $summary.GuardReasons=@('See full local report'); $summary.Notifications=@('See full local report'); $summary.Errors=@('See full local report'); $summary.FreeSpaceDelta=@()
  $json=$summary | ConvertTo-Json -Depth 6 -Compress
 }
 return $json
}

function Invoke-SmMaintenance {
 param($A)
 $r=[ordered]@{ SchemaVersion=1; Timestamp=[datetime]::UtcNow.ToString('o'); Mode=$A.Mode; Status='complete'; ReportPath=$null; Guards=$null; Before=@(); After=@(); FreeSpaceDelta=@(); Profiles=@(); Scan=$null; Actions=@(); Notifications=@(); Errors=@(); Omissions=@('User documents/downloads, rollback/recovery, installer cache and Windows components are never deleted.','Logical sizes exclude unreadable/reparse/cloud entries; hardlinks, compression and sparse files make reclaimable bytes uncertain.','App caches are reported as opportunities only; no application cache reset.','Directory ranking counts direct files, not recursively accumulated subtree sizes; categories may overlap.','Upgrade staging blocks cleanup conservatively even after Setup exits; review staging and reboot state in a maintenance window before retrying.'); Evidence=$null }
 $acquired=$false
 try {
  $acquired=& $script:SmAcquire
  if(-not $acquired) { $r.Status='busy'; return [pscustomobject]$r }
  $g=& $script:SmGuards; $r.Guards=$g
  $r.ReportPath=& $script:SmPrepareReport
  try { $r.Notifications+=& $script:SmUi 'Checking free space and upgrade safety before storage inspection.' } catch { $r.Notifications+=('failed: '+$_.Exception.Message) }
  try { $r.Before=@(& $script:SmVolumes) } catch { $r.Errors+=$_.Exception.Message }
  if($g.Light) {
   $r.Status='partial'; $r.Scan=[pscustomobject]@{Partial=$true;Files=@();Reason='Upgrade active or guard unknown: light volume summary only'}
   $r.Omissions+='Profile, cache, health and recursive scans withheld to avoid competing with Setup.'
  } else {
   try { $r.Evidence=& $script:SmEvidence } catch { $r.Errors+=$_.Exception.Message }
   $profiles=@(); try { $profiles=@(& $script:SmProfiles) } catch { $r.Errors+=$_.Exception.Message }
   if($profiles.Count -gt 200) { $r.Status='partial'; $r.Omissions+='Profile list capped at 200.'; $profiles=@($profiles | Select-Object -First 200) }
   $r.Evidence['ApplicationCachePolicy']='Per-profile Edge/Chrome/WebView Cache, Code Cache, GPUCache, ShaderCache, CacheStorage, Teams LocalCache and Adobe AcroCef are report-only. Outlook OST, OfficeFileCache, Wef and offline documents are preserved.'
   $r.Profiles=@($profiles | ForEach-Object { Test-SmProfile $_ $A.ProfileAgeDays $A.ExcludeProfiles })
   # One globally bounded scan: safe temps plus profile trees (diagnostic only).
   $roots=@(& $script:SmRoots); $roots+=@($profiles | Where-Object { $_.LocalPath -match '^[A-Za-z]:\\Users\\[^\\]+$' -and $_.Special -eq $false } | ForEach-Object { $_.LocalPath.TrimEnd('\')+'\AppData\Local\Temp' }); $scanRoots=@(& $script:SmRoots)+@($profiles | Where-Object { $_.LocalPath -match '^[A-Za-z]:\\Users\\[^\\]+$' } | ForEach-Object { $_.LocalPath })
   try { $r.Notifications+=& $script:SmUi 'Measuring bounded folders and old temporary files; cloud placeholders are skipped.' } catch { $r.Notifications+=('failed: '+$_.Exception.Message) }
   $scanRoots+=@(& $script:SmDiagnosticRoots)
   $scanRoots+=@($r.Before | Where-Object { $_.DeviceID -match '^[A-Za-z]:$' } | ForEach-Object { $_.DeviceID+'\' })
   $scan=Get-SmScan $scanRoots $A.MaxFiles $A.MaxSeconds $A.TempAgeDays; $r.Scan=$scan
   foreach($f in $scan.Files) { $f | Add-Member -NotePropertyName CleanupRoot -NotePropertyValue $null; foreach($tempRoot in $roots) { if($f.Path.StartsWith($tempRoot.TrimEnd('\')+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { $f.CleanupRoot=$tempRoot; break } } }
   if($scan.Partial -or $scan.Errors.Count) { $r.Status='partial' }
   $cacheFiles=@($scan.Files | Where-Object { $_.Path -match '(?i)\\(Cache|Code Cache|GPUCache|ShaderCache|CacheStorage)\\|\\MSTeams_[^\\]+\\LocalCache\\|\\Adobe\\AcroCef\\' })
   $r.Evidence['ApplicationCaches']=@($cacheFiles | Group-Object { if($_.Path -match '(?i)^(.+?\\(?:Cache|Code Cache|GPUCache|ShaderCache|CacheStorage))\\') { $Matches[1] } else { $_.Root } } | Sort-Object Count -Descending | Select-Object -First 30 | ForEach-Object { @{Path=$_.Name;ObservedLogicalBytes=($_.Group | Measure-Object LogicalBytes -Sum).Sum;Partial=$scan.Partial;Policy='report only; close owning application and review before manual cleanup';ReclaimableBytes=$null} })
   foreach($p in $r.Profiles) { $pf=@($scan.Files | Where-Object { $_.Root -eq $p.Path }); $p.LogicalBytes=($pf | Measure-Object LogicalBytes -Sum).Sum; $p.SizePartial=$scan.Partial }
   if($A.Mode -eq 'Cleanup') {
    if(-not $g.Safe) { $r.Status='withheld' }
    else {
     $cleanupWatch=[Diagnostics.Stopwatch]::StartNew()
     foreach($f in @($scan.Files | Where-Object { $_.Old -and $_.CleanupRoot })) {
      if($cleanupWatch.Elapsed.TotalSeconds -ge $A.MaxSeconds) { $r.Status='partial'; $r.Omissions+='Cleanup time budget exhausted; remaining actions withheld.'; break }
      $step=[ordered]@{Kind='temp';Path=$f.Path;Status='withheld';LogicalBytes=$f.LogicalBytes;Error=$null}
      try {
       if(-not (& $script:SmGuards).Safe) { throw 'Servicing guard changed; cleanup stopped' }
       if(-not (Test-SmSafePath $f.Path $f.CleanupRoot)) { throw 'Unsafe path or attributes' }
       $i=Get-Item -LiteralPath $f.Path -Force -ErrorAction Stop
       if($i.PSIsContainer -or $i.LastWriteTimeUtc -ge [datetime]::UtcNow.AddDays(-$A.TempAgeDays)) { throw 'File no longer age eligible' }
       & $script:SmDelete $f.Path; $step.Status='deleted'
      } catch { $step.Error=$_.Exception.Message; $r.Status='partial' }
      $r.Actions+=[pscustomobject]$step
      if($step.Error -like 'Servicing guard changed*') { break }
     }
     if($A.RemoveProfiles) {
      foreach($candidate in @($r.Profiles | Where-Object { $_.Eligible })) {
       if($cleanupWatch.Elapsed.TotalSeconds -ge $A.MaxSeconds) { $r.Status='partial'; $r.Omissions+='Profile cleanup time budget exhausted.'; break }
       $step=[ordered]@{Kind='profile';Path=$candidate.Path;Status='withheld';Error=$null}
       try {
        if(-not (& $script:SmGuards).Safe) { throw 'Servicing guard changed' }
        $fresh=@(& $script:SmProfiles | Where-Object { $_.SID -eq $candidate.SID })
        if(& $script:SmProfileHiveLoaded $candidate.SID) { throw 'Profile hive is loaded' }
        if($fresh.Count -ne 1 -or -not (Test-SmProfile $fresh[0] $A.ProfileAgeDays $A.ExcludeProfiles).Eligible -or $fresh[0].LocalPath -ne $candidate.Path) { throw 'Profile revalidation failed' }
        # Profile root and all ancestors must be ordinary directories.
        if(-not (Test-SmSafePath $candidate.Path ([IO.Path]::GetPathRoot($candidate.Path)))) { throw 'Unsafe profile path' }
        & $script:SmRemoveProfile $fresh[0]; $step.Status='removedByCim'
       } catch { $step.Error=$_.Exception.Message; $r.Status='partial' }; $r.Actions+=[pscustomobject]$step
      }
     }
     if($A.ComponentCleanup) {
      $step=[ordered]@{Kind='componentCleanup';Status='withheld';Error=$null}
      try { if(-not (& $script:SmGuards).Safe) { throw 'Servicing guard changed' }; $step['ExitCode']=& $script:SmComponent; $step.Status='commandCompleted' } catch { $step.Error=$_.Exception.Message; $r.Status='partial' }; $r.Actions+=[pscustomobject]$step
     }
    }
   }
   # Full file list is internal only; output bounded top lists and category totals.
   $r.Scan=[pscustomobject]@{Partial=$scan.Partial;EntriesVisited=$scan.EntriesVisited;Seconds=$scan.Seconds;SkippedReparseOrCloud=$scan.SkippedReparseOrCloud;Errors=$scan.Errors;TopFiles=$scan.TopFiles;TopFolders=$scan.TopFolders;TempCategories=@($roots | ForEach-Object { $root=$_; $fs=@($scan.Files | Where-Object {$_.CleanupRoot -eq $root}); @{Root=$root;LogicalBytes=($fs | Measure-Object LogicalBytes -Sum).Sum;AgeQualifiedLogicalBytes=($fs | Where-Object {$_.Old} | Measure-Object LogicalBytes -Sum).Sum;ReclaimableBytes=$null} })}
  }
  try { $r.Notifications+=& $script:SmUi ('Storage inspection '+$r.Status+'. Checking final free-space measurements.') } catch { $r.Notifications+=('failed: '+$_.Exception.Message) }
  try { $r.After=@(& $script:SmVolumes); $r.FreeSpaceDelta=@($r.After | ForEach-Object { $after=$_; $before=@($r.Before | Where-Object {$_.DeviceID -eq $after.DeviceID}); if($before.Count -eq 1) { @{DeviceID=$after.DeviceID;Bytes=([int64]$after.FreeSpace-[int64]$before[0].FreeSpace);IncludesConcurrentActivity=$true} } }) } catch { $r.Errors+=$_.Exception.Message }
 } catch { $r.Status='failed'; $r.Errors+=$_.Exception.Message }
 finally { if($acquired) { & $script:SmRelease } }
 if($r.Errors.Count -and $r.Status -eq 'complete') { $r.Status='partial' }
 return [pscustomobject]$r
}

if($env:RELIAN_DEPLOY_TEST -ne '1') {
 $ErrorActionPreference='Stop'
 if($Action -eq 'Uninstall' -or $DeploymentType -eq 'Uninstall') { Write-Output '{"Status":"notApplicable","Reason":"Maintenance has no uninstall action"}'; exit 0 }
 try {
  $a=Get-SmArguments -Mode $Mode -TempAgeDays $TempAgeDays -ProfileAgeDays $ProfileAgeDays -RemoveProfiles $RemoveProfiles -ExcludeProfiles $ExcludeProfiles -ComponentCleanup $ComponentCleanup -MaxFiles $MaxFiles -MaxSeconds $MaxSeconds
  $r=Invoke-SmMaintenance $a
  if($script:SmUiOpen) { try { Close-ADTInstallationProgress } catch { $r.Notifications+=('close failed: '+$_.Exception.Message) } }
  Write-Host "Storage maintenance: $($r.Status); mode $($r.Mode); actions $($r.Actions.Count). Free-space delta includes concurrent system activity."
  $reportPath=$r.ReportPath
  try {
   if(-not $reportPath) { throw 'Report destination unavailable' }
   $reportDir=Split-Path -Parent $reportPath
   if(-not (Test-SmSafePath $reportPath $reportDir)) { throw 'Report path changed or became unsafe' }
   $r | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $reportPath -Encoding UTF8 -ErrorAction Stop
  } catch { $r.Errors+=('Report file write failed: '+$_.Exception.Message); $r.Status='failed' }
  ConvertTo-SmSummary $r $reportPath
  if($r.Status -eq 'failed') { exit 1 }; exit 0
 } catch { Write-Error $_; exit 1 }
}
