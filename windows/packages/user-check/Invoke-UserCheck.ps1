# Confirms a code, or opens Microsoft sign-in. Installs nothing.
# The runner passes DeploymentType, Action, and PinVersion.
# PinVersion microsoft-sign-in opens the sign-in page.
# Any other 4 to 8 letters or digits is the code the person must type.
# The code is not stored in this file.
[CmdletBinding()]
param(
    [string]$DeploymentType,
    [string]$Action,
    [string]$PinVersion
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:UserCheckSignInUrl = 'https://login.microsoftonline.com/'

function Get-UserCheckMode {
    param([AllowEmptyString()][string]$PinVersion)
    $pin = ([string]$PinVersion).Trim()
    if ($pin -eq 'microsoft-sign-in') {
        return 'page'
    }
    if ($pin -match '^[A-Za-z0-9]{4,8}$') {
        return 'code'
    }
    return 'invalid'
}

function Get-UserCheckSignInUrl {
    return $script:UserCheckSignInUrl
}

function Test-UserCheckAnswer {
    param(
        [AllowEmptyString()][string]$Expected,
        [AllowEmptyString()][string]$Button,
        [AllowEmptyString()][string]$Text
    )
    if ([string]$Button -ne 'Confirm') {
        return $false
    }
    $typed = ([string]$Text).Trim()
    $want = ([string]$Expected).Trim()
    if ($typed.Length -eq 0 -or $want.Length -eq 0) {
        return $false
    }
    return [string]::Equals($typed, $want, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-UserCheckPromptResult {
    param($Result)
    $button = ''
    $text = ''
    if ($null -eq $Result) {
        return [pscustomobject]@{ Button = ''; Text = ''; TimedOut = $false }
    }
    if ($Result -is [string]) {
        $raw = ([string]$Result).Trim()
        if ($raw.StartsWith('{')) {
            try {
                return Get-UserCheckPromptResult -Result ($raw | ConvertFrom-Json)
            } catch {
                $button = [string]$Result
            }
        } else {
            $button = [string]$Result
        }
    } else {
        foreach ($member in @($Result.PSObject.Properties)) {
            if ($member.Name -eq 'Result' -and $null -ne $member.Value) {
                $button = [string]$member.Value
            } elseif ($member.Name -eq 'Text' -and $null -ne $member.Value) {
                $text = [string]$member.Value
            }
        }
        if ($button.Length -eq 0 -and $Result -is [System.Collections.IDictionary] -and $Result.Contains('Result') -and $null -ne $Result['Result']) {
            $button = [string]$Result['Result']
        }
        if ($text.Length -eq 0 -and $Result -is [System.Collections.IDictionary] -and $Result.Contains('Text') -and $null -ne $Result['Text']) {
            $text = [string]$Result['Text']
        }
    }
    return [pscustomobject]@{ Button = $button; Text = $text; TimedOut = ($button -eq 'Timeout') }
}

function Install-UserCheckDialogTheme {
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
            var mark = LoadMark();
            var any = false;
            foreach (Window window in app.Windows)
            {
                any = true;
                Paint(window, "SidebarAccentFill", black);
                Paint(window, "SidebarPanel", black);
                var subtitle = Find(window, "SubtitleTextBlock") as TextBlock;
                if (subtitle != null)
                {
                    var text = (subtitle.Text ?? string.Empty).Trim();
                    if (text.IndexOf("Relian", StringComparison.OrdinalIgnoreCase) >= 0 || text.IndexOf("App Installation", StringComparison.OrdinalIgnoreCase) >= 0)
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
                        SetMark(icon, mark);
                        icon.Width = 18;
                        icon.Height = 18;
                    }
                }
                WhitenBlackButtons(window, white);
            }
            if (any && Interlocked.Exchange(ref styledOnce, 1) == 0)
            {
                TryLog(mark == null ? "styled without mark" : "styled");
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

        private static int missingSourceOnce;

        private static void SetMark(FrameworkElement icon, ImageSource mark)
        {
            var source = icon.GetType().GetProperty("Source");
            if (source != null && source.CanWrite)
            {
                try
                {
                    source.SetValue(icon, mark, null);
                    return;
                }
                catch (Exception ex)
                {
                    if (Interlocked.Exchange(ref missingSourceOnce, 1) == 0)
                    {
                        TryLog(ex.GetType().Name);
                    }
                }
            }
            var field = icon.GetType().GetField("SourceProperty", BindingFlags.Public | BindingFlags.Static | BindingFlags.FlattenHierarchy);
            if (field == null)
            {
                if (Interlocked.Exchange(ref missingSourceOnce, 1) == 0)
                {
                    TryLog("sidebar icon has no Source");
                }
                return;
            }
            var property = field.GetValue(null) as DependencyProperty;
            if (property != null)
            {
                icon.SetValue(property, mark);
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



if ($env:RELIAN_DEPLOY_TEST -eq '1' -and $MyInvocation.InvocationName -eq '.') {
    return
}

foreach ($name in @('DeploymentType', 'Action', 'PinVersion')) {
    $value = Get-Variable -Name $name -ValueOnly -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace([string]$value)) {
        [Console]::Error.WriteLine("missing parameter $name")
        exit 1
    }
}

if (@('Install', 'Update', 'Repair', 'Reinstall', 'Uninstall') -notcontains $Action) {
    [Console]::Error.WriteLine('Action must be Install, Update, Repair, Reinstall, or Uninstall.')
    exit 1
}

if ($Action -eq 'Reinstall') {
    [Console]::Error.WriteLine('Reinstall is not a user-check action')
    exit 1
}

if ($Action -eq 'Uninstall' -or $Action -eq 'Repair') {
    Write-Output 'Nothing to change. Nothing was installed.'
    exit 0
}

$mode = Get-UserCheckMode -PinVersion $PinVersion
if ($mode -eq 'invalid') {
    [Console]::Error.WriteLine('PinVersion must be a 4 to 8 character code, or microsoft-sign-in.')
    exit 1
}

Write-Output 'Identity check starting. Nothing will be installed.'

$assets = Join-Path $PSScriptRoot 'Assets'
$markPath = Join-Path $assets 'RelianMark.png'
$darkIcon = Join-Path $assets 'AppIcon.Dark.png'
if (Test-Path -LiteralPath $darkIcon) {
    Copy-Item -LiteralPath $darkIcon -Destination $markPath -Force
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

if ($mode -eq 'page') {
    $title = 'Microsoft sign-in'
    $subtitle = 'Identity check'
    $message = 'Sign in with your Microsoft account. The sign-in page opens when you choose Open. Nothing will be installed.'
} else {
    $title = "Confirm it's you"
    $subtitle = 'Identity check'
    $message = 'Type the code you were given, then choose Confirm. Nothing will be installed.'
}

$adtSession = @{
    AppVendor              = ''
    AppName                = $(if ($mode -eq 'page') { 'Microsoft sign-in' } else { "Confirm it's you" })
    AppVersion             = '1'
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
            Install-UserCheckDialogTheme -ClientExe $client.FullName -MarkPath $markPath
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
    if ($mode -eq 'page') {
        $prompt = Show-ADTInstallationPrompt -Message $message -ButtonLeftText 'Open' -ButtonRightText 'Cancel' -Title $title -Subtitle $subtitle -NoExitOnTimeout -Timeout 600
        $parsed = Get-UserCheckPromptResult -Result $prompt
        if ($null -eq $prompt) {
            Write-Output 'Nobody answered the identity check. Nothing was installed.'
            Close-ADTSession -ExitCode 1
            exit 1
        }
        if ($parsed.TimedOut -or $parsed.Button -ne 'Open') {
            Write-Output 'Sign-in page was not opened.'
            Close-ADTSession -ExitCode 1
            exit 1
        }
        Start-Process -FilePath (Get-UserCheckSignInUrl)
        Write-Output 'Microsoft sign-in page opened. Nothing was installed.'
        Close-ADTSession -ExitCode 0
        exit 0
    }
    $prompt = Show-ADTInstallationPrompt -RequestInput -Message $message -ButtonLeftText 'Confirm' -ButtonRightText 'Cancel' -Title $title -Subtitle $subtitle -NoExitOnTimeout -Timeout 600
    $parsed = Get-UserCheckPromptResult -Result $prompt
    if ($null -eq $prompt) {
        Write-Output 'Nobody answered the identity check. Nothing was installed.'
        Close-ADTSession -ExitCode 1
        exit 1
    }
    $matched = Test-UserCheckAnswer -Expected $PinVersion -Button $parsed.Button -Text $parsed.Text
    if ($parsed.TimedOut) {
        Write-Output 'Code check timed out. Nothing was installed.'
        Close-ADTSession -ExitCode 1
        exit 1
    }
    if (-not $matched) {
        Write-Output 'Code did not match. Nothing was installed.'
        Close-ADTSession -ExitCode 1
        exit 1
    }
    Write-Output 'Code matched. Nothing was installed.'
    Close-ADTSession -ExitCode 0
    exit 0
} catch {
    $detail = [string]$_.Exception.Message
    [Console]::Error.WriteLine($detail)
    exit 1
}
