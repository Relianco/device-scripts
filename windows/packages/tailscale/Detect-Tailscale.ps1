# Runs with no arguments, like the other Detect scripts.
# Exit 0 when Tailscale is installed at or above the pin and the node is Running.
# Exit 1 otherwise. The tag is not checked here; Invoke-Tailscale.ps1 checks it.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Test-RelianTailscalePresent {
    param(
        [string]$InstalledVersion,
        [string]$BackendState,
        [string]$PinVersion = '1.104.4'
    )
    try {
        $installed = [version]$InstalledVersion.Trim()
        $pin = [version]$PinVersion
    } catch {
        return $false
    }
    return $installed.CompareTo($pin) -ge 0 -and $BackendState -ceq 'Running'
}

function Get-RelianTailscaleInstalledVersion {
    $best = $null
    foreach ($root in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')) {
        if (-not (Test-Path -LiteralPath $root)) {
            continue
        }
        foreach ($key in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            try {
                $props = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop
            } catch {
                continue
            }
            $names = @($props.PSObject.Properties.Name)
            if ($names -notcontains 'DisplayName' -or [string]$props.DisplayName -cne 'Tailscale') { continue }
            if ($names -notcontains 'Publisher' -or [string]$props.Publisher -cne 'Tailscale Inc.') { continue }
            if ($names -notcontains 'DisplayVersion') { continue }
            try {
                $parsed = [version]([string]$props.DisplayVersion).Trim()
            } catch {
                continue
            }
            if ($null -eq $best -or $parsed.CompareTo($best) -gt 0) {
                $best = $parsed
            }
        }
    }
    if ($null -eq $best) {
        return ''
    }
    return $best.ToString()
}

function Get-RelianTailscaleBackendState {
    $root = $env:ProgramFiles
    if ([string]::IsNullOrWhiteSpace($root)) {
        $root = 'C:\Program Files'
    }
    $exe = Join-Path $root 'Tailscale\tailscale.exe'
    if (-not (Test-Path -LiteralPath $exe)) {
        return ''
    }
    $status = ((& $exe status --json 2>$null) -join "`n") | ConvertFrom-Json
    if (@($status.PSObject.Properties.Name) -notcontains 'BackendState') {
        return ''
    }
    return [string]$status.BackendState
}

if ($env:RELIAN_DEPLOY_TEST -eq '1') {
    return
}

$present = $false
try {
    $present = [bool](Test-RelianTailscalePresent -InstalledVersion (Get-RelianTailscaleInstalledVersion) -BackendState (Get-RelianTailscaleBackendState))
} catch {
    $present = $false
}
# Exit 0 with empty stdout counts as not installed, so print a line.
if ($present) {
    Write-Output 'Relian Tailscale'
    exit 0
}
exit 1
