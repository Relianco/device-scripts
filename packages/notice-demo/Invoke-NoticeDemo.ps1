# Shows the welcome dialog and installs nothing.
# Notepad is the only process offered for close, so Explorer stays open.
[CmdletBinding()]
param(
    [string]$DeploymentType,
    [string]$Action,
    [string]$PinVersion
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$version = if ([string]::IsNullOrWhiteSpace($PinVersion)) { '1.0.0' } else { $PinVersion }
$title = "Microsoft Teams v$version"
$notice = 'Teams will close for an update. You can wait once. The next run will close it and continue.'
$iconUrl = 'https://raw.githubusercontent.com/Relianco/device-scripts/lane/notice-demo/packages/notice-demo/teams-icon.png'
$iconSha256 = 'af51db0f52e9dfbb635697a3aa62db703a434a03f7694371f709ff0a1a7730a2'

function Set-NoticeDialogText {
    param($Table, [string]$Text)
    if ($null -eq $Table) {
        return $false
    }
    $close = $Table.CloseAppsPrompt
    if ($null -eq $close) {
        return $false
    }
    $fluent = $close.Fluent
    if ($null -eq $fluent) {
        return $false
    }
    $dialog = $fluent.DialogMessage
    $idle = $fluent.DialogMessageNoProcesses
    if ($null -eq $dialog -or $null -eq $idle) {
        return $false
    }
    $dialog.Install = $Text
    $idle.Install = $Text
    $subtitle = $fluent.Subtitle
    if ($null -ne $subtitle) {
        $subtitle.Install = "v$version"
    }
    return $true
}

function Install-NoticeDialogTheme {
    param(
        [Parameter(Mandatory)][string]$ClientExe,
        [Parameter(Mandatory)][string]$MarkPath
    )
    $lib = Split-Path -Parent $ClientExe
    $dll = Join-Path $lib 'RelianDialogTheme.dll'
    $pointer = Join-Path $lib 'relian-dialog-mark.txt'
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($pointer, $MarkPath, $utf8)

    $source = @'
using System;
using System.IO;
using System.Reflection;
using System.Threading;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;

[assembly: AssemblyVersion("1.0.0.0")]

namespace Relian.DialogTheme
{
    public sealed class ThemeDomainManager : AppDomainManager
    {
        public override void InitializeNewDomain(AppDomainSetup appDomainInfo)
        {
            base.InitializeNewDomain(appDomainInfo);
            try
            {
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
            var mark = LoadMark();
            var any = false;
            foreach (Window window in app.Windows)
            {
                any = true;
                Paint(window, "SidebarAccentFill", black);
                Paint(window, "SidebarPanel", black);
                var subtitle = Find(window, "SubtitleTextBlock") as TextBlock;
                var titleBlock = Find(window, "AppTitleTextBlock") as TextBlock;
                if (subtitle != null)
                {
                    var text = (subtitle.Text ?? string.Empty).Trim();
                    var heading = titleBlock == null ? string.Empty : (titleBlock.Text ?? string.Empty);
                    var covered = text.Length > 0 && heading.IndexOf(text, StringComparison.OrdinalIgnoreCase) >= 0;
                    if (string.IsNullOrWhiteSpace(text) || covered || text.IndexOf("Relian", StringComparison.OrdinalIgnoreCase) >= 0 || text.IndexOf("App Installation", StringComparison.OrdinalIgnoreCase) >= 0)
                    {
                        subtitle.Text = string.Empty;
                        subtitle.Visibility = Visibility.Collapsed;
                    }
                }
                if (mark != null)
                {
                    var icon = Find(window, "SidebarIcon");
                    if (icon != null)
                    {
                        var source = icon.GetType().GetProperty("Source");
                        if (source != null && source.CanWrite)
                        {
                            source.SetValue(icon, mark, null);
                        }
                        icon.Width = 20;
                        icon.Height = 20;
                    }
                }
            }
            if (any)
            {
                TryLog("styled");
            }
            return any;
        }

        private static void Paint(DependencyObject root, string name, Brush brush)
        {
            var element = Find(root, name);
            if (element == null)
            {
                return;
            }
            var fill = element.GetType().GetProperty("Fill");
            if (fill != null && fill.CanWrite)
            {
                fill.SetValue(element, brush, null);
                return;
            }
            var background = element.GetType().GetProperty("Background");
            if (background != null && background.CanWrite)
            {
                background.SetValue(element, brush, null);
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
                    var onAccent = label.IndexOf("OnAccent", StringComparison.OrdinalIgnoreCase) >= 0;
                    try
                    {
                        var value = dictionary[key];
                        if (value is SolidColorBrush)
                        {
                            dictionary[key] = onAccent ? (object)white : black;
                        }
                        else if (value is Color)
                        {
                            dictionary[key] = onAccent ? (object)Colors.White : Colors.Black;
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

        private static ImageSource LoadMark()
        {
            try
            {
                var dir = Path.GetDirectoryName(typeof(ThemeDomainManager).Assembly.Location);
                var pointer = Path.Combine(dir, "relian-dialog-mark.txt");
                if (!File.Exists(pointer))
                {
                    return null;
                }
                var path = File.ReadAllText(pointer).Trim();
                if (!File.Exists(path))
                {
                    return null;
                }
                var image = new BitmapImage();
                image.BeginInit();
                image.CacheOption = BitmapCacheOption.OnLoad;
                image.UriSource = new Uri(path, UriKind.Absolute);
                image.EndInit();
                if (image.CanFreeze)
                {
                    image.Freeze();
                }
                return image;
            }
            catch (Exception ex)
            {
                TryLog(ex.Message);
                return null;
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

    if (Test-Path -LiteralPath $dll) {
        Remove-Item -LiteralPath $dll -Force
    }
    Add-Type -TypeDefinition $source -OutputAssembly $dll -ReferencedAssemblies @('System', 'System.Xaml', 'WindowsBase', 'PresentationCore', 'PresentationFramework')
    $fullName = [System.Reflection.AssemblyName]::GetAssemblyName($dll).FullName
    $configPath = "$ClientExe.config"
    [xml]$config = [System.IO.File]::ReadAllText($configPath)
    $runtime = $config.configuration.runtime
    if ($null -eq $runtime) {
        throw 'client config has no runtime element'
    }
    foreach ($name in @('appDomainManagerAssembly', 'appDomainManagerType')) {
        $existing = @($runtime.ChildNodes | Where-Object { $_.LocalName -eq $name })
        foreach ($node in $existing) {
            [void]$runtime.RemoveChild($node)
        }
    }
    $assemblyNode = $config.CreateElement('appDomainManagerAssembly')
    [void]$assemblyNode.SetAttribute('value', $fullName)
    [void]$runtime.AppendChild($assemblyNode)
    $typeNode = $config.CreateElement('appDomainManagerType')
    [void]$typeNode.SetAttribute('value', 'Relian.DialogTheme.ThemeDomainManager')
    [void]$runtime.AppendChild($typeNode)
    $config.Save($configPath)
    Write-Output "Dialog theme helper installed."
}

Write-Output 'Notice demo starting. Notepad is the only program that may close. Nothing will be installed.'
Write-Output 'If a previous panel is still open, click Defer on that one. This panel replaces the colours and the icons.'

$running = @(Get-Process -Name notepad -ErrorAction SilentlyContinue)
if ($running.Count -eq 0) {
    Start-Process -FilePath "$env:SystemRoot\System32\notepad.exe"
    $deadline = (Get-Date).AddSeconds(10)
    do {
        Start-Sleep -Milliseconds 300
        $running = @(Get-Process -Name notepad -ErrorAction SilentlyContinue)
    } while ($running.Count -eq 0 -and (Get-Date) -lt $deadline)
}
if ($running.Count -eq 0) {
    [Console]::Error.WriteLine('Notepad did not start')
    exit 1
}

$assets = Join-Path $PSScriptRoot 'Assets'
$markPath = Join-Path $assets 'RelianMark.png'
$darkIcon = Join-Path $assets 'AppIcon.Dark.png'
if (Test-Path -LiteralPath $darkIcon) {
    Copy-Item -LiteralPath $darkIcon -Destination $markPath -Force
}

$teamsIcon = Join-Path $assets 'teams-icon.png'
try {
    Invoke-WebRequest -Uri $iconUrl -OutFile $teamsIcon -UseBasicParsing
    $downloaded = (Get-FileHash -Algorithm SHA256 -LiteralPath $teamsIcon).Hash.ToLowerInvariant()
    if ($downloaded -ne $iconSha256) {
        throw "teams icon hash mismatch"
    }
    foreach ($name in @('AppIcon.png', 'AppIcon.Dark.png')) {
        Copy-Item -LiteralPath $teamsIcon -Destination (Join-Path $assets $name) -Force
    }
    Write-Output 'Teams icon set for the header.'
} catch {
    Write-Output 'Teams icon was not applied. The header will keep the current icon.'
    [Console]::Error.WriteLine($_.Exception.Message)
}

$configPath = Join-Path $PSScriptRoot 'Config\config.psd1'
if (Test-Path -LiteralPath $configPath) {
    $configText = [System.IO.File]::ReadAllText($configPath)
    $updated = $configText
    if ($updated -notmatch 'FluentAccentColor') {
        $updated = $updated.Replace("DialogStyle = 'Fluent'", "DialogStyle = 'Fluent'`r`n        FluentAccentColor = 0xFF000000")
    }
    if ($updated -notmatch 'DefaultTimeout') {
        $updated = $updated.Replace("DialogStyle = 'Fluent'", "DialogStyle = 'Fluent'`r`n        DefaultTimeout = 600")
    }
    if ($updated -ne $configText) {
        $utf8 = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText($configPath, $updated, $utf8)
    }
}

$adtSession = @{
    AppVendor              = ''
    AppName                = 'Microsoft Teams'
    AppVersion             = $version
    AppProcessesToClose    = @('notepad')
    RequireAdmin           = $false
    DeployAppScriptVersion = '4.1.8'
}

try {
    $moduleRoot = Join-Path $PSScriptRoot 'PSAppDeployToolkit'
    $moduleManifest = Join-Path $moduleRoot 'PSAppDeployToolkit.psd1'
    if (-not (Test-Path -LiteralPath $moduleManifest -PathType Leaf)) {
        throw "missing PSAppDeployToolkit module at $moduleManifest"
    }
    $client = Get-ChildItem -LiteralPath $moduleRoot -Filter 'PSADT.ClientServer.Client.exe' -Recurse -File | Select-Object -First 1
    if ($null -eq $client) {
        throw 'missing PSADT client executable'
    }
    if (Test-Path -LiteralPath $markPath) {
        try {
            Install-NoticeDialogTheme -ClientExe $client.FullName -MarkPath $markPath
        } catch {
            Write-Output 'Dialog theme helper was not installed. The panel will use the accent colour from config.'
            [Console]::Error.WriteLine($_.Exception.Message)
        }
    } else {
        Write-Output 'Relian mark was not found. The bar icon stays the toolkit mark.'
    }
    Get-ChildItem -LiteralPath $moduleRoot -Recurse -File | Unblock-File -ErrorAction Ignore
    Import-Module -FullyQualifiedName @{ ModuleName = $moduleManifest; Guid = '8c3c366b-8606-4576-9f2d-4051144f7ca2'; ModuleVersion = '4.1.8' } -Force
    $adtSession = Remove-ADTHashtableNullOrEmptyValues -Hashtable $adtSession
    $adtSession = Open-ADTSession @adtSession -DeploymentType 'Install' -DeployMode 'Interactive' -PassThru
    $noticeSet = Set-NoticeDialogText -Table (Get-ADTStringTable) -Text $notice
    if ($noticeSet) {
        Write-Output 'Notice text set.'
    } else {
        Write-Output 'Notice text unchanged. The panel will use the toolkit wording.'
    }
    Show-ADTInstallationWelcome -CloseProcesses @{ Name = 'notepad'; Description = 'Notepad' } -AllowDefer -DeferTimes 1 -Title $title -Subtitle "v$version"
    Close-ADTSession -ExitCode 0
    $themeLog = Join-Path $client.DirectoryName 'relian-dialog-theme.log'
    if (Test-Path -LiteralPath $themeLog) {
        Write-Output (Get-Content -LiteralPath $themeLog -Tail 5 | Out-String).Trim()
    }
    Write-Output 'Notice demo finished. Nothing was installed.'
    exit 0
} catch {
    $detail = [string]$_.Exception.Message
    [Console]::Error.WriteLine($detail)
    exit 1
}
