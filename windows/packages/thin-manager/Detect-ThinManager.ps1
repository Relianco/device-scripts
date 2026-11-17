# Intune runs this file with no arguments.
# There is no Thin Manager product install. Exit 0 only when the common Startup
# shortcut matches. A shortcut file that does not match is not installed.
# The package marker is not the product.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:RelianThinManagerShortcutName = 'RelianThinManager.lnk'
$script:RelianThinManagerDescription = 'Relian Thin Manager'
$script:RelianThinManagerShellScript = 'C:\Relian\shell.ps1'

function Get-RelianThinManagerPowerShellPath {
    $root = $env:SystemRoot
    if ([string]::IsNullOrWhiteSpace($root)) {
        $root = 'C:\Windows'
    }
    $root = $root.TrimEnd('\')
    return ($root + '\system32\WindowsPowerShell\v1.0\powershell.exe')
}

function Convert-RelianThinManagerIconLocation {
    param([string]$IconLocation)
    if ([string]::IsNullOrWhiteSpace($IconLocation)) {
        return ''
    }
    $text = $IconLocation.Trim()
    if ($text.EndsWith(',0')) {
        $text = $text.Substring(0, $text.Length - 2)
    }
    return $text
}

function Get-RelianThinManagerPropertyText {
    param(
        $Object,
        [string]$Name
    )
    if ($null -eq $Object) {
        return ''
    }
    $value = $null
    if ($Object -is [System.Collections.IDictionary]) {
        if (-not $Object.Contains($Name)) {
            return ''
        }
        $value = $Object[$Name]
    } else {
        $names = @($Object.PSObject.Properties.Name)
        if ($names -notcontains $Name) {
            return ''
        }
        $value = $Object.$Name
    }
    if ($null -eq $value) {
        return ''
    }
    return [string]$value
}

function Get-RelianThinManagerShortcutSpec {
    $powershell = Get-RelianThinManagerPowerShellPath
    $shell = $script:RelianThinManagerShellScript
    return [pscustomobject]@{
        TargetPath   = $powershell
        Arguments    = ('-ExecutionPolicy Bypass -WindowStyle Hidden -NoProfile -File "' + $shell + '"')
        Description  = $script:RelianThinManagerDescription
        IconLocation = $powershell
    }
}

function Test-RelianThinManagerShortcutMatches {
    param(
        $Shortcut,
        $Spec
    )
    if ($null -eq $Shortcut -or $null -eq $Spec) {
        return $false
    }
    $target = Convert-RelianThinManagerIconLocation -IconLocation (Get-RelianThinManagerPropertyText -Object $Shortcut -Name 'TargetPath')
    $icon = Convert-RelianThinManagerIconLocation -IconLocation (Get-RelianThinManagerPropertyText -Object $Shortcut -Name 'IconLocation')
    $wantTarget = Convert-RelianThinManagerIconLocation -IconLocation (Get-RelianThinManagerPropertyText -Object $Spec -Name 'TargetPath')
    $wantIcon = Convert-RelianThinManagerIconLocation -IconLocation (Get-RelianThinManagerPropertyText -Object $Spec -Name 'IconLocation')
    if (-not $target.Equals($wantTarget, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }
    if (-not $icon.Equals($wantIcon, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }
    $arguments = Get-RelianThinManagerPropertyText -Object $Shortcut -Name 'Arguments'
    $description = Get-RelianThinManagerPropertyText -Object $Shortcut -Name 'Description'
    $wantArguments = Get-RelianThinManagerPropertyText -Object $Spec -Name 'Arguments'
    $wantDescription = Get-RelianThinManagerPropertyText -Object $Spec -Name 'Description'
    if (-not $arguments.Equals($wantArguments, [System.StringComparison]::Ordinal)) {
        return $false
    }
    if (-not $description.Equals($wantDescription, [System.StringComparison]::Ordinal)) {
        return $false
    }
    return $true
}

function Test-RelianThinManagerInstalled {
    param($Entry)
    # A marker version, or a shortcut file that merely exists, is not presence.
    if ($null -eq $Entry) {
        return $false
    }
    $spec = Get-RelianThinManagerShortcutSpec
    try {
        return [bool](Test-RelianThinManagerShortcutMatches -Shortcut $Entry -Spec $spec)
    } catch {
        return $false
    }
}

function Get-RelianThinManagerStartupShortcutPath {
    # %ProgramData%\Microsoft\Windows\Start Menu\Programs\StartUp\RelianThinManager.lnk
    $programData = $env:ProgramData
    if ([string]::IsNullOrWhiteSpace($programData)) {
        $programData = [Environment]::GetFolderPath('CommonApplicationData')
    }
    if ([string]::IsNullOrWhiteSpace($programData)) {
        $programData = 'C:\ProgramData'
    }
    $programData = $programData.TrimEnd('\')
    return ($programData + '\Microsoft\Windows\Start Menu\Programs\StartUp\' + $script:RelianThinManagerShortcutName)
}

function Read-RelianThinManagerStartupShortcut {
    $path = Get-RelianThinManagerStartupShortcutPath
    if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path)) {
        return $null
    }
    $item = Get-Item -LiteralPath $path -Force
    if ($item.PSIsContainer) {
        return $null
    }
    $shell = New-Object -ComObject WScript.Shell
    $link = $shell.CreateShortcut($path)
    return [pscustomobject]@{
        TargetPath   = [string]$link.TargetPath
        Arguments    = [string]$link.Arguments
        Description  = [string]$link.Description
        IconLocation = [string]$link.IconLocation
    }
}

if ($env:RELIAN_DEPLOY_TEST -eq '1') {
    return
}

$present = $false
try {
    $shortcut = Read-RelianThinManagerStartupShortcut
    $present = [bool](Test-RelianThinManagerInstalled -Entry $shortcut)
} catch {
    $present = $false
}
# Intune treats exit 0 with empty stdout as not installed. Stderr is also a failure.
if ($present) {
    Write-Output 'Relian Thin Manager startup'
    exit 0
}
exit 1
