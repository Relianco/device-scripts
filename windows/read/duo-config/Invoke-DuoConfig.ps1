<#
.SYNOPSIS
    Reports the Duo Authentication for Windows Logon install and its settings on this device. Read-only.
.DESCRIPTION
    Prints one JSON line: the installed Duo Windows Logon products and versions, and for each of Duo's two
    settings keys (HKLM\SOFTWARE\Duo Security\DuoCredProv, written by the installer, and
    HKLM\SOFTWARE\Policies\Duo Security\DuoCredProv, written by Group Policy or Intune, which wins) whether it
    exists, its values and whether standard users can read it. Both keys are read in the 64-bit view.

    Nothing secret leaves the device. Number values are shown as they are. Of the text values only Host and
    HttpProxyHost are shown; IKey is masked to its first and last four characters; SKey is reported as present,
    its length (40 is the plain key from the Duo Admin Panel; Windows Logon 6.0.1 and later encrypt it in the
    installer key) and the first 8 hex characters of its SHA-256, so two devices or a device and the vault can
    be compared without the key. Any other text value is reported by length only.
    No file, registry, service or custom-field write, no download.
#>
# Parameters are not Mandatory: a mandatory param block prompts when this file is dot-sourced under test.
[CmdletBinding()]
param(
    [string]$DeploymentType,
    [string]$Action,
    [string]$PinVersion
)
$ProgressPreference = 'SilentlyContinue'

$script:DuoKeys = [ordered]@{ default = 'SOFTWARE\Duo Security\DuoCredProv'; policy = 'SOFTWARE\Policies\Duo Security\DuoCredProv' }
$script:ShownText = @('Host', 'HttpProxyHost')
# Standard users: Users, Everyone, Authenticated Users, Interactive.
$script:UserSids = @('S-1-5-32-545', 'S-1-1-0', 'S-1-5-11', 'S-1-5-4')

function Open-DuoKey {
    param([string]$SubKey)
    $hklm = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
    return $hklm.OpenSubKey($SubKey, $false)
}

# Seams. Tests replace them.
$script:ReadKey = {
    param($SubKey)
    $key = Open-DuoKey $SubKey
    if ($null -eq $key) { return $null }
    try {
        $values = @{}
        foreach ($name in $key.GetValueNames()) { $values[$name] = $key.GetValue($name, $null, 'DoNotExpandEnvironmentNames') }
        return $values
    } finally { $key.Close() }
}
$script:ReadProducts = {
    foreach ($root in @('SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')) {
        $key = Open-DuoKey $root
        if ($null -eq $key) { continue }
        try {
            foreach ($sub in $key.GetSubKeyNames()) {
                $entry = $key.OpenSubKey($sub, $false)
                if ($null -eq $entry) { continue }
                try {
                    $name = [string]$entry.GetValue('DisplayName', '')
                    if ($name -like 'Duo Authentication for Windows Logon*') {
                        [pscustomobject]@{ DisplayName = $name; DisplayVersion = [string]$entry.GetValue('DisplayVersion', '') }
                    }
                } finally { $entry.Close() }
            }
        } finally { $key.Close() }
    }
}
$script:UsersCanRead = {
    param($SubKey)
    $key = Open-DuoKey $SubKey
    if ($null -eq $key) { return $null }
    try {
        return (Test-DuoUsersCanRead @($key.GetAccessControl().GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])))
    } finally { $key.Close() }
}

# $true when a standard-user group may read values and none of those groups is denied it: a standard interactive user is
# in all four groups, so any such Deny wins.
function Test-DuoUsersCanRead {
    param($Rules)
    $allow = $false
    foreach ($rule in @($Rules)) {
        $read = ([int]$rule.RegistryRights -band [int][Security.AccessControl.RegistryRights]::QueryValues) -ne 0
        if (-not $read -or $script:UserSids -notcontains $rule.IdentityReference.Value) { continue }
        if ([string]$rule.AccessControlType -eq 'Deny') { return $false }
        $allow = $true
    }
    return $allow
}

function Get-DuoFingerprint {
    param([string]$Value)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value)) } finally { $sha.Dispose() }
    return ([BitConverter]::ToString($hash, 0, 4) -replace '-', '').ToLowerInvariant()
}

function ConvertTo-DuoValues {
    param($Values)
    $out = [ordered]@{}
    foreach ($name in @($Values.Keys | Sort-Object)) {
        $value = $Values[$name]
        if ($value -is [int] -or $value -is [long]) {
            $out[$name] = $value
        } elseif ($name -eq 'SKey') {
            $text = [string]$value
            $out[$name] = [ordered]@{ present = ($text.Length -gt 0); length = $text.Length; sha256prefix = (Get-DuoFingerprint $text) }
        } elseif ($name -eq 'IKey') {
            $text = [string]$value
            if ($text.Length -ge 12) { $out[$name] = $text.Substring(0, 4) + '...' + $text.Substring($text.Length - 4) } else { $out[$name] = [ordered]@{ length = $text.Length } }
        } elseif ($script:ShownText -contains $name) {
            $out[$name] = [string]$value
        } else {
            $out[$name] = [ordered]@{ length = ([string]$value).Length }
        }
    }
    return $out
}

function Invoke-DuoConfig {
    $report = [ordered]@{ version = '1'; timestamp = [datetime]::UtcNow.ToString('o'); status = 'ok'; products = @(); error = $null }
    try {
        foreach ($p in @(& $script:ReadProducts)) { $report.products += [ordered]@{ name = $p.DisplayName; version = $p.DisplayVersion } }
        foreach ($which in $script:DuoKeys.Keys) {
            $path = $script:DuoKeys[$which]
            $values = & $script:ReadKey $path
            if ($null -eq $values) {
                $report[$which] = [ordered]@{ exists = $false; values = $null; usersCanRead = $null }
            } else {
                $report[$which] = [ordered]@{ exists = $true; values = (ConvertTo-DuoValues $values); usersCanRead = (& $script:UsersCanRead $path) }
            }
        }
    } catch {
        $report.status = 'failed'
        $report.error = $_.Exception.GetType().Name
    }
    return ($report | ConvertTo-Json -Compress -Depth 5)
}

if ($env:RELIAN_DEPLOY_TEST -eq '1' -and $MyInvocation.InvocationName -eq '.') { return }
if ($Action -eq 'Uninstall') { Write-Output '{"status":"nothingToUninstall"}'; exit 0 }
if (@('Install', 'Update', 'Repair', 'Reinstall') -notcontains $Action) { [Console]::Error.WriteLine('Unsupported action.'); exit 1 }
$line = Invoke-DuoConfig
Write-Output $line
if ($line.Contains('"status":"ok"')) { exit 0 }
exit 1
