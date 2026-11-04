# Windows Update evidence and explicit conservative repair. Never reboots or starts Setup.
[CmdletBinding()]
param([string]$DeploymentType,[string]$Action,[string]$PinVersion,[string]$Mode='Report',
 [string]$ResetCache='false',[string]$RepairImage='false',[string]$Notify='true',[string]$Scan='false',
 [string]$ScanTimeoutSeconds='120',[string]$NativeTimeoutSeconds='1200')
function Get-UmOptions {
 param([string]$Mode='Report',[string]$ResetCache='false',[string]$RepairImage='false',[string]$Notify='true',[string]$Scan='false',[string]$ScanTimeoutSeconds='120',[string]$NativeTimeoutSeconds='1200')
 if($Mode -cnotin @('Report','Repair')) { throw 'Invalid Mode' }
 $a=@{Mode=$Mode}
 foreach($n in @('ResetCache','RepairImage','Notify','Scan')) { $v=Get-Variable $n -ValueOnly; if($v -cnotin @('true','false')) { throw "Invalid $n" }; $a[$n]=$v -ceq 'true' }
 foreach($n in @('ScanTimeoutSeconds','NativeTimeoutSeconds')) { $v=Get-Variable $n -ValueOnly; if($v -notmatch '^\d{1,4}$' -or [int]$v -lt 10 -or [int]$v -gt 3600) { throw "Invalid $n" }; $a[$n]=[int]$v }
 if($Mode -eq 'Report' -and ($a.ResetCache -or $a.RepairImage)) { throw 'Repair options require Repair mode' }; $a
}
function Get-UmLifecycle {
 param($Edition,$Build,$Release,[datetime]$Now=[datetime]::UtcNow)
 $end=$null
 if($Edition -eq 'Professional' -and $Build -eq '22621' -and $Release -eq '22H2') { $end='2024-10-08' }
 if($Edition -eq 'Professional' -and $Build -eq '22631' -and $Release -eq '23H2') { $end='2025-11-11' }
 $status='unknown'; if($end) { $status='supportedAtObservation'; if($Now.Date -ge [datetime]$end) { $status='outOfSupport' } }
 @{status=$status;endOfServicing=$end;checkedDate='2026-11-04';source='https://learn.microsoft.com/en-us/lifecycle/products/windows-11-home-and-pro'}
}
function Get-UmServicePlan {
 param($Services)
 foreach($s in $Services) { if($s.StartMode -eq 'Disabled' -and $s.Name -in @('wuauserv','BITS','CryptSvc')) { $mode='Manual'; if($s.Name -eq 'CryptSvc') { $mode='Automatic' }; @{Name=$s.Name;Original=$s;StartupType=$mode} } }
}
function Test-UmSafePath {
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
   $cur=[IO.Path]::GetDirectoryName($cur)
  }
 } catch { return $false }; return $true
}

# Residual rollback folders are safe only with independent completed-upgrade evidence.
function Get-UmUpgradeDirectoryState {
 param($DirectoryCreatedUtc,[int]$CurrentBuild,$PriorBuilds,[datetime]$InstalledUtc,[datetime]$BootUtc)
 if(-not @($DirectoryCreatedUtc).Count) { return 'absent' }
 if($InstalledUtc.Year -lt 2000 -or $BootUtc -lt $InstalledUtc -or -not @($PriorBuilds | Where-Object { $_ -match '^\d+$' -and [int]$_ -lt $CurrentBuild }).Count) { return 'unknownStaging' }
 foreach($created in $DirectoryCreatedUtc) { if(-not $created -or [datetime]$created -gt $InstalledUtc) { return 'unknownStaging' } }
 'completedResidual'
}
function Get-UmGuards {
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
  $created=@(); foreach($name in @('$WINDOWS.~BT','$WINDOWS.~WS')) { $path=Join-Path $env:SystemDrive $name; if(Test-Path -LiteralPath $path -ErrorAction Stop) { $created+=(Get-Item -LiteralPath $path -Force -ErrorAction Stop).CreationTimeUtc } }
  if($created.Count) {
   $os=Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
   $prior=@(Get-ChildItem 'HKLM:\SYSTEM\Setup' -ErrorAction Stop | Where-Object { $_.PSChildName -like 'Source OS*' } | ForEach-Object { (Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction Stop).CurrentBuild })
   $installed=([datetime]'1970-01-01Z').AddSeconds([double]$os.InstallDate)
   $boot=(Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec 5 -ErrorAction Stop).LastBootUpTime.ToUniversalTime()
   if((Get-UmUpgradeDirectoryState $created ([int]$os.CurrentBuild) $prior $installed $boot) -ne 'completedResidual') { $reasons.Add('unknown upgrade staging; completion not established') }
  }
  $state=Join-Path $env:ProgramData 'Relian\FeatureUpgrade\state.json'
  if(Test-Path -LiteralPath $state -ErrorAction Stop) { $s=Get-Content -LiteralPath $state -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop; if($s.status -eq 'staged') { $reasons.Add('feature upgrade staged') } }
 } catch { $reasons.Add('unknown guard: evidence unavailable'); $light=$true }
 [pscustomobject]@{ Safe=($reasons.Count -eq 0); Light=$light; Reasons=@($reasons.ToArray()) }
}

# Protect the local evidence directory before any cleanup is authorized.
function Initialize-UmSecureDirectory {
 param([string]$Path)
 $base=[IO.Path]::GetFullPath($env:ProgramData).TrimEnd('\')
 $full=[IO.Path]::GetFullPath($Path)
 if(-not $full.StartsWith($base+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Evidence path must be under ProgramData' }
 $current=$base
 if(-not (Test-UmSafePath $base ([IO.Path]::GetPathRoot($base)))) { throw 'Reparse ProgramData ancestor refused' }
 foreach($part in $full.Substring($base.Length+1).Split('\')) {
  if(-not $part -or $part -in @('.','..')) { throw 'Invalid evidence directory' }
  $current=Join-Path $current $part
  if(-not (Test-Path -LiteralPath $current -ErrorAction Stop)) { $null=New-Item -ItemType Directory -Path $current -ErrorAction Stop }
  $item=Get-Item -LiteralPath $current -Force -ErrorAction Stop
  if(-not $item.PSIsContainer -or ([int64]$item.Attributes -band 1024) -ne 0) { throw 'Reparse evidence directory refused' }
  if($current -eq (Join-Path $base 'Relian')) { continue }
  $acl=New-Object Security.AccessControl.DirectorySecurity
  $acl.SetSecurityDescriptorSddlForm('O:SYG:SYD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)')
  Set-Acl -LiteralPath $current -AclObject $acl -ErrorAction Stop
 }
 return $full
}
function Grant-UmThemeReadAccess {
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
function Install-UmDialogTheme {
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
    Grant-UmThemeReadAccess -Path $dll
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


$script:UmUiOpen=$false
$script:UmThemeError=$null
$script:UmUi={ param($Step)
 if(-not $script:UmUiOpen) {
  $module=Join-Path $PSScriptRoot 'PSAppDeployToolkit\PSAppDeployToolkit.psd1'
  Import-Module -FullyQualifiedName @{ModuleName=$module;ModuleVersion='4.1.8';Guid='8c3c366b-8606-4576-9f2d-4051144f7ca2'} -Force -ErrorAction Stop
  if(-not @(Get-ADTLoggedOnUser | Where-Object { $_.IsActiveUserSession }).Count) { return 'noUser' }
  try {
   $client=Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'PSAppDeployToolkit') -Filter 'PSADT.ClientServer.Client.exe' -Recurse -File | Select-Object -First 1
   if(-not $client) { throw 'Toolkit client not found' }; Install-UmDialogTheme $client.FullName
  } catch { $script:UmThemeError=$_.Exception.Message }
  $null=Open-ADTSession -AppName 'Relian update maintenance' -AppVersion '1' -DeploymentType Install -DeployMode Interactive -PassThru
  $script:UmUiOpen=$true
 }
 Show-ADTInstallationProgress -StatusMessage $Step
 if($script:UmThemeError) { 'shown; black theme unavailable: '+$script:UmThemeError } else { 'shown' }
}

# Every checkpoint validates ordinary ancestors and repairs restrictive ACLs before writing.
function Write-UmJson {
 param($Value,[string]$Path)
 $dir=Initialize-UmSecureDirectory (Split-Path $Path -Parent)
 if(-not (Test-UmSafePath $dir $env:ProgramData)) { throw 'Unsafe evidence directory' }
 foreach($f in @($Path,($Path+'.tmp'))) { if(Test-Path -LiteralPath $f) { if(-not (Test-UmSafePath $f $dir)) { throw 'Unsafe evidence file' }; $fileAcl=New-Object Security.AccessControl.FileSecurity; $fileAcl.SetSecurityDescriptorSddlForm('O:SYG:SYD:P(A;;FA;;;SY)(A;;FA;;;BA)'); Set-Acl -LiteralPath $f -AclObject $fileAcl -ErrorAction Stop } }
 if(Test-Path -LiteralPath ($Path+'.tmp')) { Remove-Item -LiteralPath ($Path+'.tmp') -ErrorAction Stop }
 $Value | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath ($Path+'.tmp') -Encoding UTF8 -ErrorAction Stop
 if(Test-Path -LiteralPath $Path) { [IO.File]::Replace(($Path+'.tmp'),$Path,$null) } else { [IO.File]::Move(($Path+'.tmp'),$Path) }
}
$script:UmPrepare={
 $script:UmRunDir=Initialize-UmSecureDirectory (Join-Path $env:ProgramData ('Relian\Maintenance\Update\'+[guid]::NewGuid().ToString('n')))
 Join-Path $script:UmRunDir 'report.json'
}
$script:UmSave={ param($r) Write-UmJson $r $r.reportPath }
$script:UmGuard={ Get-UmGuards }
$script:UmAcquire={ $script:UmMutex=New-Object Threading.Mutex($false,'Global\RelianWindowsMaintenance'); try { $script:UmMutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $true } }
$script:UmRelease={ if($script:UmMutex) { $script:UmMutex.ReleaseMutex(); $script:UmMutex.Dispose() } }
$script:UmSnapshot={
 $os=Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
 $services=@(Get-CimInstance Win32_Service -OperationTimeoutSec 5 -ErrorAction Stop | Where-Object { $_.Name -in @('wuauserv','BITS','CryptSvc','UsoSvc','WaaSMedicSvc','TrustedInstaller') -or $_.Name -match '^Ninja' } | Select-Object Name,StartMode,State,ExitCode)
 $serviceConfig=@(); foreach($svc in $services) { if($svc.Name -in @('wuauserv','BITS','CryptSvc')) { $cfg=Get-ItemProperty ('HKLM:\SYSTEM\CurrentControlSet\Services\'+$svc.Name) -ErrorAction Stop; $serviceConfig+=@{Name=$svc.Name;Start=$cfg.Start;DelayedAutoStart=$cfg.DelayedAutoStart} } }
 $policy=@(); foreach($key in @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate','HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU','HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Update')) {
  if(Test-Path $key -ErrorAction Stop) { $values=@{}; $k=Get-Item $key -ErrorAction Stop; foreach($n in $k.GetValueNames()) { if($n -match '^(NoAutoUpdate|AUOptions|SetDisableUXWUAccess|DisableWindowsUpdateAccess|UseWUServer|DoNotConnectToWindowsUpdateInternetLocations|TargetReleaseVersion|TargetReleaseVersionInfo|ProductVersion|.*Pause.*|.*Defer.*|.*Source.*|.*Safeguard.*)$') { $values[$n]=$k.GetValue($n) } elseif($n -in @('WUServer','WUStatusServer')) { $values[$n]='configured (address omitted)' } }; $policy+=@{key=$key;values=$values;ownership='observed; effective management owner unconfirmed'} }
 }
 @{os=@{edition=$os.EditionID;build=$os.CurrentBuild;release=$os.DisplayVersion;ubr=$os.UBR};osLifecycle=(Get-UmLifecycle $os.EditionID $os.CurrentBuild $os.DisplayVersion);services=$services;serviceConfig=$serviceConfig;policy=$policy;volumes=@(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -OperationTimeoutSec 5 | Select-Object DeviceID,FreeSpace,Size);featureOffer='notEstablished';managementAction='Preserve policy, targeting, pauses and safeguards; consult administrator. AUOptions=2 is notify before download; UI restriction does not establish failed detection.'}
}
$script:UmEvents={ @(Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-WindowsUpdateClient/Operational';StartTime=[datetime]::Now.AddDays(-14)} -MaxEvents 30 -ErrorAction Stop | Select-Object TimeCreated,Id,LevelDisplayName) }
function Assert-UmSafe { $g=& $script:UmGuard; if(-not $g.Safe) { throw 'Guard blocked or unknown' } }
# ServiceController sends SCM control without Start/Stop-Service pending-status waits.
$script:UmGetController={ param($name) $c=New-Object ServiceProcess.ServiceController($name); $c.Refresh(); $c }
$script:UmControl={ param($name,$desired) $c=& $script:UmGetController $name; try { if($desired -eq 'Running') { $c.Start() } else { $c.Stop() } } finally { $c.Dispose() } }
$script:UmDelay={ Start-Sleep -Milliseconds 200 }
$script:UmMilliseconds={ [diagnostics.stopwatch]::GetTimestamp()*1000.0/[diagnostics.stopwatch]::Frequency }
function Get-UmServiceStatus {
 param($Name)
 $svc=& $script:UmGetController $Name
 try { [string]$svc.Status } finally { if($svc.PSObject.Methods['Dispose']) { $svc.Dispose() } }
}
function Invoke-UmServiceState {
 param([string]$Name,[string]$Desired,[int]$Seconds=20)
 $step=@{phase='serviceControl';service=$Name;desired=$Desired;outcome='incomplete';errorCategory=$null}
 try {
  $start=& $script:UmMilliseconds
  $status=Get-UmServiceStatus $Name
  if($status -eq $Desired) { $step.outcome='alreadyInState'; return $step }
  & $script:UmControl $Name $Desired
  while(((& $script:UmMilliseconds)-$start) -lt $Seconds*1000) {
   $status=Get-UmServiceStatus $Name
   if($status -eq $Desired) { $step.outcome='reachedState'; return $step }
   & $script:UmDelay
  }
  $step.outcome='timeout'; $step.errorCategory='pendingServiceTimeout'
 } catch { $step.outcome='failed'; $step.errorCategory=$_.Exception.GetType().Name }
 $step
}
$script:UmService={ param($s,$r)
 Assert-UmSafe
 $step=@{phase='serviceConfiguration';service=$s.Name;outcome='incomplete'}; $r.actions+=$step
 try { Set-Service -Name $s.Name -StartupType $s.StartupType -ErrorAction Stop; $step.outcome='enabled' }
 catch { $step.outcome='failed'; $step.errorCategory=$_.Exception.GetType().Name; & $script:UmSave $r; throw 'Service configuration failed' }
 & $script:UmSave $r; Assert-UmSafe
 $step=Invoke-UmServiceState $s.Name 'Running'; $r.actions+=$step; & $script:UmSave $r
 if($step.outcome -notin @('alreadyInState','reachedState')) { throw 'Service start incomplete' }
}
$script:UmCache={ param($r)
 $running=@(); $failure=$null
 try {
  foreach($name in @('BITS','wuauserv','CryptSvc')) {
   Assert-UmSafe; $status=Get-UmServiceStatus $name
   if($status -eq 'Running') { $running+=$name }
   $step=Invoke-UmServiceState $name 'Stopped'; $r.actions+=$step; & $script:UmSave $r
   if($step.outcome -notin @('alreadyInState','reachedState')) { throw 'Cache service stop incomplete' }
  }
  foreach($relative in @('SoftwareDistribution','System32\catroot2')) {
   Assert-UmSafe; $path=Join-Path $env:windir $relative
   if(-not (Test-UmSafePath $path $env:windir)) { throw 'Unsafe cache path' }
   $backup=$path+'.relian-backup-'+[datetime]::UtcNow.ToString('yyyyMMddTHHmmss')+'-'+[guid]::NewGuid().ToString('n')
   $step=@{phase='cacheRename';cache=$relative;outcome='incomplete'}; $r.actions+=$step
   try { Move-Item -LiteralPath $path -Destination $backup -ErrorAction Stop; $step.outcome='renamed' }
   catch { $step.outcome='failed'; $step.errorCategory=$_.Exception.GetType().Name; throw 'Cache rename failed' }
   $r.cacheBackups+=@{source=$relative;backup=$backup;restore='Manual recovery only; never overwrite regenerated cache'}; & $script:UmSave $r
  }
 } catch { $failure='Cache reset incomplete'; $r.errors+=@{phase='cacheReset';category=$_.Exception.GetType().Name} }
 finally {
  foreach($name in $running) {
   $step=Invoke-UmServiceState $name 'Running'; $step.phase='cacheServiceRestoration'; $r.actions+=$step
   if($step.outcome -notin @('alreadyInState','reachedState')) { $failure='Service restoration incomplete' }
   try { & $script:UmSave $r } catch { $failure='Restoration checkpoint failed' }
  }
 }
 if($failure) { throw $failure }
}
# No parameterless WaitForExit: redirected managed pumps may await descendants forever.
function Complete-UmExitedProcess {
 param($Process)
 if(-not $Process.HasExited) { throw 'Process not exited' }
 @{outcome='commandCompleted';exitCode=$Process.ExitCode;outputComplete='notEstablished'}
}
function Invoke-UmProcess {
 param([string]$Executable,[string]$Arguments,[int]$Timeout,[string]$Phase,$r,[switch]$ScanOnly)
 Assert-UmSafe
 $null=Initialize-UmSecureDirectory $script:UmRunDir
 $stdout=Join-Path $script:UmRunDir ($Phase+'.stdout.txt'); $stderr=Join-Path $script:UmRunDir ($Phase+'.stderr.txt')
 foreach($file in @($stdout,$stderr)) { if(Test-Path -LiteralPath $file) { throw 'Native output collision' } }
 $p=Start-Process -FilePath $Executable -ArgumentList $Arguments -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr -ErrorAction Stop
 $marker=Join-Path $env:ProgramData 'Relian\Maintenance\native-active.json'
 $record=@{pid=$p.Id;creationTimeUtc=$p.StartTime.ToUniversalTime().ToString('o');executable=$Executable;phase=$Phase;startedUtc=[datetime]::UtcNow.ToString('o');stdoutPath=$stdout;stderrPath=$stderr}
 try { Write-UmJson $record $marker } catch { $r.actions+=@{phase=$Phase;outcome='markerWriteFailedChildMayRun';pid=$p.Id}; throw 'Native marker unavailable; child may remain active' }
 $clock=[diagnostics.stopwatch]::StartNew()
 while(-not $p.HasExited -and $clock.Elapsed.TotalSeconds -lt $Timeout) { Start-Sleep -Milliseconds 200; $p.Refresh() }
 if(-not $p.HasExited) {
  if($ScanOnly) { try { $p.Kill(); $null=$p.WaitForExit(2000) } catch {} }
  if(-not $p.HasExited) { return @{outcome='nativeStillRunning';pid=$p.Id;stdoutPath=$stdout;stderrPath=$stderr} }
  Remove-Item -LiteralPath $marker -ErrorAction Stop
  return @{outcome='scanTimeout';stdoutPath=$stdout;stderrPath=$stderr}
 }
 $completed=Complete-UmExitedProcess $p
 $code=$completed.exitCode
 Remove-Item -LiteralPath $marker -ErrorAction Stop
 @{outcome='commandCompleted';exitCode=$code;stdoutPath=$stdout;stderrPath=$stderr;outputComplete='notEstablished'}
}
$script:UmNative={ param($phase,$a,$r)
 if($phase -eq 'DISM') { Invoke-UmProcess (Join-Path $env:windir 'System32\dism.exe') '/Online /Cleanup-Image /RestoreHealth' $a.NativeTimeoutSeconds 'DISM' $r }
 else { Invoke-UmProcess (Join-Path $env:windir 'System32\sfc.exe') '/scannow' $a.NativeTimeoutSeconds 'SFC' $r }
}
$script:UmSearch={ param($a,$r)
 # Fixed helper only; COM runs in a cancellable separate PowerShell process.
 $body=@'
$ErrorActionPreference='Stop'
try {
 $session=New-Object -ComObject Microsoft.Update.Session
 $searcher=$session.CreateUpdateSearcher()
 $result=$searcher.Search("IsInstalled=0 and Type='Software'")
 $out=@{resultCode=[int]$result.ResultCode;count=$result.Updates.Count;serverSelection=[int]$searcher.ServerSelection;warnings=@($result.Warnings | ForEach-Object { @{hresult=$_.HResult} });updates=@($result.Updates | Select-Object -First 30 | ForEach-Object { @{title=$_.Title;kb=@($_.KBArticleIDs)} })}
 $out.outcome='scanFailed'; if([int]$result.ResultCode -eq 2) { $out.outcome='scanSucceeded'; if($result.Updates.Count -eq 0) { $out.outcome='scanSucceededNoApplicableUpdates' } }
} catch { $out=@{outcome='scanFailed';hresult=$_.Exception.HResult} }
$out | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'scan-result.json') -Encoding UTF8
'@
 $helper=Join-Path $script:UmRunDir 'search.ps1'; Write-UmJson @{state='searchPrepared'} (Join-Path $script:UmRunDir 'search-state.json')
 $body | Set-Content -LiteralPath $helper -Encoding UTF8 -ErrorAction Stop
 $result=Invoke-UmProcess (Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe') ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$helper+'"') $a.ScanTimeoutSeconds 'search' $r -ScanOnly
 if($result.outcome -ne 'commandCompleted' -or $result.exitCode -ne 0) { return $result }
 Get-Content -LiteralPath (Join-Path $script:UmRunDir 'scan-result.json') -Raw -ErrorAction Stop | ConvertFrom-Json
}
function Invoke-UmMaintenance {
 param($a)
 $r=@{schemaVersion=1;runId=[guid]::NewGuid().ToString('n');mode=$a.Mode;status='reported';reportPath=$null;updateCurrency='notEstablished';featureOffer='notEstablished';guard=$null;before=$null;after=$null;actions=@();cacheBackups=@();scan=@{outcome='notRequested'};rebootRequired=$false;notification=@();errors=@();omissions=@('No Ninja history; no authoritative release currency comparison; no feature offer guarantee')}
 $locked=$false; $changed=$false
 try {
  $r.reportPath=& $script:UmPrepare; & $script:UmSave $r
  if($env:RELIAN_DEPLOY_TEST -ne '1') { Write-Host ('Update maintenance report: '+$r.reportPath) }
  $r.guard=& $script:UmGuard; $r.before=& $script:UmSnapshot
  if($r.guard.Safe) { try { $r.recentUpdateEvents=@(& $script:UmEvents) } catch { $r.omissions+='Update event history unavailable' } } else { $r.omissions+='Busy/unknown: low-impact evidence only' }; & $script:UmSave $r
  if($a.Notify) { try { $r.notification+=& $script:UmUi 'Inspecting Windows Update services, policy and release lifecycle.' } catch { $r.notification+='UI unavailable' } }
  if(-not $r.guard.Safe) { $r.status='deferred'; return $r }
  if($a.Mode -eq 'Report' -and -not $a.Scan) { return $r }
  $locked=& $script:UmAcquire; if(-not $locked) { $r.status='deferred'; $r.errors+='Maintenance mutex busy'; return $r }
  if($a.Mode -eq 'Repair') {
   $r.plan=@(Get-UmServicePlan $r.before.services); & $script:UmSave $r
   foreach($s in $r.plan) { Assert-UmSafe; & $script:UmSave $r; $changed=$true; & $script:UmService $s $r; $r.actions+=@{phase='service';name=$s.Name;outcome='enabledAndRunning'}; & $script:UmSave $r }
   if($a.ResetCache) { Assert-UmSafe; & $script:UmSave $r; $changed=$true; & $script:UmCache $r; $r.actions+=@{phase='cache';outcome='renamed; not proof of repair'}; & $script:UmSave $r }
   if($a.RepairImage) {
    foreach($phase in @('DISM','SFC')) {
     Assert-UmSafe; if($a.Notify) { try { $r.notification+=& $script:UmUi ('Running '+$phase+'; servicing may continue beyond observation timeout.') } catch { $r.notification+='UI unavailable' } }
     $changed=$true; $n=& $script:UmNative $phase $a $r; $r.actions+=@{phase=$phase;result=$n}; & $script:UmSave $r
     if($n.outcome -eq 'nativeStillRunning') { $r.status='deferred'; return $r }
     if($n.exitCode -eq 3010) { $r.rebootRequired=$true; $r.status='deferred'; return $r }
     if($n.outcome -ne 'commandCompleted' -or $n.exitCode -ne 0) { throw 'Image repair incomplete' }
    }
   }
  }
  Assert-UmSafe; $r.scan=& $script:UmSearch $a $r; & $script:UmSave $r
  if($r.scan.outcome -eq 'nativeStillRunning') { $r.status='deferred'; return $r }
  if($r.scan.outcome -notin @('scanSucceeded','scanSucceededNoApplicableUpdates')) { throw 'Update scan incomplete' }
  $r.after=& $script:UmSnapshot
  if(@(Get-UmServicePlan $r.after.services).Count) { throw 'Disabled required services remain after repair' }
  if($a.Mode -eq 'Repair' -and $changed) { $r.status='repaired' }
 } catch { if($changed) { $r.status='partial' } else { $r.status='failed' }; $r.errors+=@{phase='maintenance';category=$_.Exception.GetType().Name;detail='Operation incomplete; consult structured actions'} }
 finally {
  if($locked) { & $script:UmRelease }
  try { & $script:UmSave $r } catch { $r.status='failed'; $r.errors+='Report checkpoint failed' }
 }
 return $r
}
if($env:RELIAN_DEPLOY_TEST -ne '1') {
 $ErrorActionPreference='Stop'
 if($Action -eq 'Uninstall' -or $DeploymentType -eq 'Uninstall') { '{"status":"nothingToUninstall"}'; exit 0 }
 try {
  $a=Get-UmOptions -Mode $Mode -ResetCache $ResetCache -RepairImage $RepairImage -Notify $Notify -Scan $Scan -ScanTimeoutSeconds $ScanTimeoutSeconds -NativeTimeoutSeconds $NativeTimeoutSeconds
  $r=Invoke-UmMaintenance $a
  if($script:UmUiOpen) { try { Close-ADTInstallationProgress } catch { $r.notification+='UI close failed' }; try { & $script:UmSave $r } catch { $r.status='failed' } }
  $summary=@{schemaVersion=$r.schemaVersion;runId=$r.runId;mode=$r.mode;status=$r.status;reportPath=$r.reportPath;guard=$r.guard;actions=$r.actions;scan=@{outcome=$r.scan.outcome;count=$r.scan.count;hresult=$r.scan.hresult};rebootRequired=$r.rebootRequired;notification=$r.notification;updateCurrency=$r.updateCurrency;osLifecycle=$r.before.osLifecycle;truncation=$false;omissions=$r.omissions}
  $json=$summary | ConvertTo-Json -Depth 8 -Compress
  if([text.encoding]::UTF8.GetByteCount($json) -gt 7500) { $summary.guard=@{Safe=$r.guard.Safe;Reasons=@('See durable report')}; $summary.actions=@{count=$r.actions.Count;details='See durable report'}; $summary.truncation=$true; $json=$summary | ConvertTo-Json -Depth 8 -Compress }
  Write-Output $json
  if($r.status -eq 'deferred') { exit 2 }; if($r.status -in @('failed','partial')) { exit 1 }; exit 0
 } catch { Write-Output '{"status":"failed","reason":"Invalid options or initialization failed"}'; exit 1 }
}
