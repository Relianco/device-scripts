# Shows the Relian welcome dialog and installs nothing.
# Notepad is the only process offered for close, so Explorer stays open.
[CmdletBinding()]
param(
    [string]$DeploymentType,
    [string]$Action,
    [string]$PinVersion
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$notice = 'Teams will close for an update. You can wait once. The next run will close it and continue.'

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
    return $true
}

Write-Output 'Notice demo starting. Notepad is the only program that may close. Nothing will be installed.'

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

$configPath = Join-Path $PSScriptRoot 'Config\config.psd1'
if (Test-Path -LiteralPath $configPath) {
    $configText = [System.IO.File]::ReadAllText($configPath)
    if ($configText -notmatch 'DefaultTimeout') {
        $updated = $configText.Replace("DialogStyle = 'Fluent'", "DialogStyle = 'Fluent'`r`n        DefaultTimeout = 600")
        $utf8 = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText($configPath, $updated, $utf8)
    }
}

$adtSession = @{
    AppVendor              = 'Relian'
    AppName                = 'Microsoft Teams'
    AppVersion             = $(if ([string]::IsNullOrWhiteSpace($PinVersion)) { '1.0.0' } else { $PinVersion })
    AppProcessesToClose    = @('notepad')
    RequireAdmin           = $false
    DeployAppScriptVersion = '4.1.8'
}

try {
    $moduleManifest = Join-Path $PSScriptRoot 'PSAppDeployToolkit\PSAppDeployToolkit.psd1'
    if (-not (Test-Path -LiteralPath $moduleManifest -PathType Leaf)) {
        throw "missing PSAppDeployToolkit module at $moduleManifest"
    }
    Get-ChildItem -LiteralPath (Split-Path -Parent $moduleManifest) -Recurse -File | Unblock-File -ErrorAction Ignore
    Import-Module -FullyQualifiedName @{ ModuleName = $moduleManifest; Guid = '8c3c366b-8606-4576-9f2d-4051144f7ca2'; ModuleVersion = '4.1.8' } -Force
    $adtSession = Remove-ADTHashtableNullOrEmptyValues -Hashtable $adtSession
    # Interactive is explicit so a running Notepad is not required for the panel to appear.
    $adtSession = Open-ADTSession @adtSession -DeploymentType 'Install' -DeployMode 'Interactive' -PassThru
    $noticeSet = Set-NoticeDialogText -Table (Get-ADTStringTable) -Text $notice
    if ($noticeSet) {
        Write-Output 'Notice text set.'
    } else {
        Write-Output 'Notice text unchanged. The panel will use the toolkit wording.'
    }
    Show-ADTInstallationWelcome -CloseProcesses @{ Name = 'notepad'; Description = 'Notepad' } -AllowDefer -DeferTimes 1
    Close-ADTSession -ExitCode 0
    Write-Output 'Notice demo finished. Nothing was installed.'
    exit 0
} catch {
    $detail = [string]$_.Exception.Message
    [Console]::Error.WriteLine($detail)
    if ($detail -match '(^|\D)1602(\D|$)') {
        exit 1
    }
    exit 1
}
