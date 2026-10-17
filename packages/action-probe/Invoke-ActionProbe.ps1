# Script parameters are not Mandatory: a mandatory param block prompts when this
# file is dot-sourced under RELIAN_DEPLOY_TEST. The runner passes DeploymentType,
# Action, and PinVersion. MarkerRoot is optional; the default is
# $env:ProgramData\Relian\action-probe so the marker survives the work directory.
[CmdletBinding()]
param(
    [ValidateSet('Install', 'Uninstall', 'Repair')]
    [string]$DeploymentType,

    [ValidateSet('Install', 'Update', 'Repair', 'Reinstall', 'Uninstall')]
    [string]$Action,

    [string]$PinVersion,

    [string]$MarkerRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Convert-ProbeExit {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [int]$ToolkitExit
    )

    if ($ToolkitExit -eq 1602) {
        return 1
    }
    return [int]$ToolkitExit
}

function Write-ProbeText {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text
    )
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $Text, $utf8)
}

function Add-ProbeLogLine {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Line
    )
    $prefix = ''
    if (Test-Path -LiteralPath $Path) {
        $prefix = [System.IO.File]::ReadAllText($Path)
        if ($prefix.Length -gt 0 -and -not $prefix.EndsWith("`n")) {
            $prefix += "`n"
        }
    }
    Write-ProbeText -Path $Path -Text ($prefix + $Line + "`n")
}

function Remove-ProbeFile {
    param([Parameter(Mandatory)][string]$Path)
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Force
    }
}

function Read-ProbeMarker {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{
            Exists = $false
            Parseable = $false
            Version = $null
        }
    }
    $text = [System.IO.File]::ReadAllText($Path).Trim()
    try {
        return [pscustomobject]@{
            Exists = $true
            Parseable = $true
            Version = [version]$text
        }
    } catch {
        return [pscustomobject]@{
            Exists = $true
            Parseable = $false
            Version = $null
        }
    }
}

function Write-ProbeInstall {
    param(
        [Parameter(Mandatory)][string]$MarkerPath,
        [Parameter(Mandatory)][string]$SentinelPath,
        [Parameter(Mandatory)][string]$LogPath,
        [Parameter(Mandatory)][string]$PinText
    )
    Write-ProbeText -Path $MarkerPath -Text ($PinText.Trim() + "`n")
    Write-ProbeText -Path $SentinelPath -Text 'ok'
    Add-ProbeLogLine -Path $LogPath -Line 'Install'
}

function Get-ProbeMarkerRoot {
    if (-not [string]::IsNullOrWhiteSpace($MarkerRoot)) {
        return $MarkerRoot
    }
    return (Join-Path (Join-Path $env:ProgramData 'Relian') 'action-probe')
}

function Invoke-ProbeAction {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Install', 'Update', 'Repair', 'Reinstall', 'Uninstall')]
        [string]$Action,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$PinVersion,

        [Parameter(Mandatory)]
        [string]$MarkerRoot
    )

    $pin = $null
    try {
        $pin = [version]$PinVersion
    } catch {
        return 1
    }

    if (-not (Test-Path -LiteralPath $MarkerRoot)) {
        [void](New-Item -ItemType Directory -Path $MarkerRoot -Force)
    }

    $markerPath = Join-Path $MarkerRoot 'marker.txt'
    $sentinelPath = Join-Path $MarkerRoot 'sentinel.txt'
    $logPath = Join-Path $MarkerRoot 'toolkit.log'
    $sentinelExists = Test-Path -LiteralPath $sentinelPath

    if ($Action -eq 'Uninstall') {
        $markerExists = Test-Path -LiteralPath $markerPath
        if ($markerExists -or $sentinelExists) {
            Remove-ProbeFile -Path $markerPath
            Remove-ProbeFile -Path $sentinelPath
            Add-ProbeLogLine -Path $logPath -Line 'Uninstall'
        }
        return 0
    }

    if ($Action -eq 'Reinstall') {
        Remove-ProbeFile -Path $markerPath
        Remove-ProbeFile -Path $sentinelPath
        Add-ProbeLogLine -Path $logPath -Line 'Uninstall'
        Write-ProbeInstall -MarkerPath $markerPath -SentinelPath $sentinelPath -LogPath $logPath -PinText $PinVersion
        return 0
    }

    $marker = Read-ProbeMarker -Path $markerPath
    if ($Action -eq 'Repair') {
        if (-not $marker.Exists) {
            Write-ProbeInstall -MarkerPath $markerPath -SentinelPath $sentinelPath -LogPath $logPath -PinText $PinVersion
            return 0
        }
        if (-not $marker.Parseable) {
            return 1
        }
        if ($marker.Version -ne $pin) {
            return 1
        }
        if (-not $sentinelExists) {
            Write-ProbeText -Path $sentinelPath -Text 'ok'
            Add-ProbeLogLine -Path $logPath -Line 'Repair'
        }
        return 0
    }

    if (-not $marker.Exists) {
        Write-ProbeInstall -MarkerPath $markerPath -SentinelPath $sentinelPath -LogPath $logPath -PinText $PinVersion
        return 0
    }
    if (-not $marker.Parseable) {
        return 1
    }
    if ($marker.Version -lt $pin) {
        Write-ProbeInstall -MarkerPath $markerPath -SentinelPath $sentinelPath -LogPath $logPath -PinText $PinVersion
        return 0
    }
    if ($marker.Version -gt $pin) {
        return 0
    }
    if (-not $sentinelExists) {
        Write-ProbeText -Path $sentinelPath -Text 'ok'
    }
    return 0
}

function Install-ADTDeployment {
    [CmdletBinding()]
    param()

    try {
        if ($adtSession.AppProcessesToClose.Count -gt 0) {
            Show-ADTInstallationWelcome -CloseProcesses $adtSession.AppProcessesToClose
        }
    } catch {
        if ([string]$_.Exception.Message -match '(^|\D)1602(\D|$)') {
            $script:ToolkitExit = 1602
        }
        throw
    }

    $script:ProbeExit = [int](Invoke-ProbeAction -Action $Action -PinVersion $PinVersion -MarkerRoot (Get-ProbeMarkerRoot))
    if ($script:ProbeExit -ne 0) {
        throw "Action probe failed with exit $($script:ProbeExit)"
    }
}

function Uninstall-ADTDeployment {
    [CmdletBinding()]
    param()

    try {
        if ($adtSession.AppProcessesToClose.Count -gt 0) {
            Show-ADTInstallationWelcome -CloseProcesses $adtSession.AppProcessesToClose
        }
    } catch {
        if ([string]$_.Exception.Message -match '(^|\D)1602(\D|$)') {
            $script:ToolkitExit = 1602
        }
        throw
    }

    $script:ProbeExit = [int](Invoke-ProbeAction -Action $Action -PinVersion $PinVersion -MarkerRoot (Get-ProbeMarkerRoot))
    if ($script:ProbeExit -ne 0) {
        throw "Action probe failed with exit $($script:ProbeExit)"
    }
}

function Repair-ADTDeployment {
    [CmdletBinding()]
    param()

    try {
        if ($adtSession.AppProcessesToClose.Count -gt 0) {
            Show-ADTInstallationWelcome -CloseProcesses $adtSession.AppProcessesToClose
        }
    } catch {
        if ([string]$_.Exception.Message -match '(^|\D)1602(\D|$)') {
            $script:ToolkitExit = 1602
        }
        throw
    }

    $script:ProbeExit = [int](Invoke-ProbeAction -Action $Action -PinVersion $PinVersion -MarkerRoot (Get-ProbeMarkerRoot))
    if ($script:ProbeExit -ne 0) {
        throw "Action probe failed with exit $($script:ProbeExit)"
    }
}

if ($env:RELIAN_DEPLOY_TEST -eq '1' -and $MyInvocation.InvocationName -eq '.') {
    return
}

foreach ($name in @('DeploymentType', 'Action', 'PinVersion')) {
    $value = Get-Variable -Name $name -ValueOnly
    if ([string]::IsNullOrWhiteSpace([string]$value)) {
        [Console]::Error.WriteLine("missing parameter $name")
        exit 1
    }
}

$script:ProbeExit = 0
$script:ToolkitExit = 0
$adtSession = @{
    AppVendor = 'Relian'
    AppName = 'Action Probe'
    AppVersion = $PinVersion
    AppProcessesToClose = @()
    RequireAdmin = $true
    DeployAppScriptFriendlyName = $MyInvocation.MyCommand.Name
    DeployAppScriptParameters = $PSBoundParameters
    DeployAppScriptVersion = '4.1.8'
}

try {
    $moduleManifest = "$PSScriptRoot\PSAppDeployToolkit\PSAppDeployToolkit.psd1"
    if (-not (Test-Path -LiteralPath $moduleManifest -PathType Leaf)) {
        throw "missing PSAppDeployToolkit module at $moduleManifest"
    }
    Get-ChildItem -LiteralPath (Split-Path -Parent $moduleManifest) -Recurse -File | Unblock-File -ErrorAction Ignore
    Import-Module -FullyQualifiedName @{ ModuleName = $moduleManifest; Guid = '8c3c366b-8606-4576-9f2d-4051144f7ca2'; ModuleVersion = '4.1.8' } -Force
    $adtSession = Open-ADTSession @adtSession -DeploymentType $DeploymentType -PassThru
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 60008
}

try {
    $null = & "$($adtSession.DeploymentType)-ADTDeployment"
    $processExit = [int](Convert-ProbeExit -ToolkitExit 0)
    Close-ADTSession -ExitCode $processExit
    exit $processExit
} catch {
    $toolkitExit = 60001
    if ($script:ProbeExit -ne 0) {
        $toolkitExit = $script:ProbeExit
    } else {
        $detail = [string]$_.Exception.Message
        if ($script:ToolkitExit -eq 1602 -or $detail -match '(^|\D)1602(\D|$)') {
            $toolkitExit = 1602
        }
    }
    $processExit = [int](Convert-ProbeExit -ToolkitExit $toolkitExit)
    # 1602 is a toolkit user-cancel. Exit with the mapped code and do not write the marker.
    try {
        Close-ADTSession -ExitCode $processExit
    } catch {
        exit $processExit
    }
    exit $processExit
}
