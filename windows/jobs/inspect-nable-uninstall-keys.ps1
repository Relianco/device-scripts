# Diagnostic module, run by windows/runner/Invoke-RelianJob.ps1 as SYSTEM. Strictly read-only: it lists the
# leftover N-able Add/Remove Programs keys with everything nable-agent-removal looks at (uninstaller paths, whether
# they exist, the Windows Installer registration and its cached package) so a key that job keeps can be understood.
# It writes no registry value or key, no file, starts no process and runs no msiexec. -ReportOnly is accepted
# because the loader forwards it, and ignored. Exit 0 ok, 2 when the registry cannot be read. Prints one JSON line.
[CmdletBinding()]
param([switch]$ReportOnly)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Copied from nable-agent-removal.ps1: a module runs from its hashed bytes and cannot load a sibling file.
$script:NaNamePattern = '(?i)\A(Advanced Monitoring Agent\b.*|Take Control Agent\b.*|N-able Take Control\b.*|BeAnywhere Support Express\b.*)\z'
$script:NaPartPattern = '(?i)\A(Request Handler Agent|File Cache Service Agent|Patch Management Service Controller)\z'
$script:NaPublisherPattern = '(?i)\A(Remote Monitoring Services|SolarWinds MSP|N-able Technologies|LogicNow( Ltd)?|BeAnywhere)\z'
$script:NaServicePattern = '(?i)\A(Advanced Monitoring Agent.*|BASupportExpress.*|GetSupportService.*)\z'
$script:NaProtectedPattern = '(?i)ninja|sentinel|global secure access|wireguard|wazuh'

$script:IkRoots = @(
    @{ View = '64'; Path = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' },
    @{ View = 'WOW6432Node'; Path = 'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall' }
)
$script:IkProductsRoot = 'SOFTWARE\Classes\Installer\Products'
$script:IkUserDataRoot = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products'
$script:IkKnownValues = @('DisplayName', 'DisplayVersion', 'Publisher', 'WindowsInstaller', 'InstallLocation', 'UninstallString', 'QuietUninstallString')

function Open-IkHklm {
    [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
}

# Seam: one record per Uninstall subkey, all values as strings.
$script:IkReadUninstall = {
    $hklm = Open-IkHklm
    foreach ($root in $script:IkRoots) {
        $parent = $hklm.OpenSubKey($root.Path)
        if (-not $parent) { continue }
        try {
            foreach ($sub in $parent.GetSubKeyNames()) {
                $key = $parent.OpenSubKey($sub)
                if (-not $key) { continue }
                try {
                    $names = @($key.GetValueNames())
                    $get = { param($n) $v = $key.GetValue($n, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames); if ($null -eq $v) { '' } else { [string]$v } }
                    [pscustomobject]@{
                        View = $root.View; Root = $root.Path; Id = $sub
                        Name = & $get 'DisplayName'; Version = & $get 'DisplayVersion'; Publisher = & $get 'Publisher'
                        WindowsInstaller = & $get 'WindowsInstaller'; InstallLocation = & $get 'InstallLocation'
                        Uninstall = & $get 'UninstallString'; QuietUninstall = & $get 'QuietUninstallString'
                        OtherValues = @($names | Where-Object { $_ -and ($script:IkKnownValues -notcontains $_) })
                        HasSubKeys = ($key.SubKeyCount -gt 0)
                    }
                } finally { $key.Dispose() }
            }
        } finally { $parent.Dispose() }
    }
}

# Seam: the Windows Installer registration of one packed product code.
$script:IkReadInstaller = {
    param($Packed)
    $hklm = Open-IkHklm
    $exists = {
        param($Path)
        $k = $hklm.OpenSubKey($Path)
        if ($k) { $k.Dispose(); return $true }
        return $false
    }
    $pkg = $null
    $props = $hklm.OpenSubKey("$script:IkUserDataRoot\$Packed\InstallProperties")
    if ($props) {
        try { $pkg = [string]$props.GetValue('LocalPackage') } finally { $props.Dispose() }
    }
    [pscustomobject]@{
        Products = (& $exists "$script:IkProductsRoot\$Packed")
        UserData = (& $exists "$script:IkUserDataRoot\$Packed")
        InstallProperties = ($null -ne $props)
        LocalPackage = $pkg
    }
}

$script:IkReadServices = {
    foreach ($s in @(Get-CimInstance -ClassName Win32_Service -ErrorAction Stop)) {
        [pscustomobject]@{ Name = [string]$s.Name; DisplayName = [string]$s.DisplayName; State = [string]$s.State; Path = [string]$s.PathName }
    }
}

$script:IkTestPath = { param($Path) Test-Path -LiteralPath $Path }

function Get-IkText {
    param([AllowNull()]$Text)
    $t = ([string]$Text) -replace '(?i)C:\\Users\\[^\\]+', 'C:\Users\<user>'
    return $t.Substring(0, [Math]::Min($t.Length, 300))
}

function Test-IkProtected { param([AllowEmptyString()][string]$Text) return $Text -match $script:NaProtectedPattern }

function Test-IkApp {
    param($Entry)
    if (-not $Entry.Name -or (Test-IkProtected "$($Entry.Name) $($Entry.Publisher) $($Entry.Uninstall)")) { return $false }
    return ($Entry.Name -match $script:NaNamePattern) -or ($Entry.Name -match $script:NaPartPattern -and $Entry.Publisher -match $script:NaPublisherPattern)
}

function Get-IkExecutable {
    param([AllowEmptyString()][string]$Command)
    ([regex]::Match($Command, '\A\s*(?:"(?<e>[^"]+)"|(?<e>.+?\.exe)(?=\s|\z)|(?<e>\S+))')).Groups['e'].Value
}

function ConvertTo-IkPackedGuid {
    param([string]$Guid)
    $m = [regex]::Match($Guid, '\A\{([0-9A-Fa-f]{8})-([0-9A-Fa-f]{4})-([0-9A-Fa-f]{4})-([0-9A-Fa-f]{4})-([0-9A-Fa-f]{12})\}\z')
    if (-not $m.Success) { throw "not a product code: $Guid" }
    $rev = { param($t) $a = $t.ToCharArray(); [Array]::Reverse($a); -join $a }
    $tail = ($m.Groups[4].Value + $m.Groups[5].Value) -replace '(.)(.)', '$2$1'
    return ((& $rev $m.Groups[1].Value) + (& $rev $m.Groups[2].Value) + (& $rev $m.Groups[3].Value) + $tail).ToUpperInvariant()
}

# "true", "false", "unknown" (the test threw) or "none" (no path to test).
function Get-IkExists {
    param([string]$Path)
    if (-not $Path) { return 'none' }
    # Registry values are read unexpanded; the file system needs the expanded path.
    try { if (& $script:IkTestPath ([Environment]::ExpandEnvironmentVariables($Path))) { return 'true' } else { return 'false' } } catch { return 'unknown' }
}

function Get-IkPathCheck {
    param([AllowEmptyString()][string]$Path)
    [ordered]@{ path = (Get-IkText $Path); exists = (Get-IkExists $Path) }
}

function Get-IkRecord {
    param($Entry)
    $uninstallExe = Get-IkExecutable "$($Entry.Uninstall)"
    $quietExe = Get-IkExecutable "$($Entry.QuietUninstall)"
    $msi = $null
    if ($Entry.Id -match '\A\{[0-9A-Fa-f-]{36}\}\z' -and ($Entry.WindowsInstaller -eq '1' -or $Entry.Uninstall -match '(?i)msiexec')) {
        $packed = ConvertTo-IkPackedGuid $Entry.Id
        $reg = & $script:IkReadInstaller $packed
        $pkg = if ($null -eq $reg.LocalPackage) { $null } else { [string]$reg.LocalPackage }
        $msi = [ordered]@{
            packedCode = $packed
            productsKeyExists = [bool]$reg.Products
            userDataProductExists = [bool]$reg.UserData
            installPropertiesExists = [bool]$reg.InstallProperties
            localPackage = $(if ($null -eq $pkg) { $null } else { Get-IkPathCheck $pkg })
        }
    }
    [ordered]@{
        keyPath = Get-IkText "HKLM\$($Entry.Root)\$($Entry.Id) [$($Entry.View) view]"
        displayName = Get-IkText $Entry.Name; displayVersion = Get-IkText $Entry.Version; publisher = Get-IkText $Entry.Publisher
        windowsInstaller = Get-IkText $Entry.WindowsInstaller; installLocation = Get-IkPathCheck $Entry.InstallLocation
        uninstallString = Get-IkText $Entry.Uninstall; uninstallExecutable = Get-IkPathCheck $uninstallExe
        quietUninstallString = Get-IkText $Entry.QuietUninstall; quietUninstallExecutable = Get-IkPathCheck $quietExe
        msi = $msi
        otherValueNames = @($Entry.OtherValues | ForEach-Object { Get-IkText $_ })
        hasSubKeys = [bool]$Entry.HasSubKeys
    }
}

function Invoke-InspectJob {
    $keys = @(); $services = @(); $problem = ''; $exitCode = 0
    try {
        $keys = @(& $script:IkReadUninstall | Where-Object { Test-IkApp $_ } | ForEach-Object { Get-IkRecord $_ })
    } catch {
        $exitCode = 2; $problem = "registry read failed: $($_.Exception.Message)"
    }
    if ($exitCode -eq 0) {
        # A service read that fails leaves the key list intact; the error field says so.
        try {
            $services = @(& $script:IkReadServices | Where-Object {
                $_.Name -match $script:NaServicePattern -and -not (Test-IkProtected "$($_.Name) $($_.DisplayName) $($_.Path)")
            } | ForEach-Object { [ordered]@{ name = (Get-IkText $_.Name); displayName = (Get-IkText $_.DisplayName); state = (Get-IkText $_.State); path = (Get-IkText $_.Path) } })
        } catch { $problem = "service read failed: $($_.Exception.Message)" }
    }
    [pscustomobject]@{
        ExitCode = $exitCode
        Line = ([ordered]@{ job = 'inspect-nable-uninstall-keys'; status = $(if ($exitCode -eq 0) { 'ok' } else { 'failed' }); keys = @($keys); services = @($services); error = (Get-IkText $problem) } | ConvertTo-Json -Compress -Depth 6)
    }
}

# Dot-sourcing under test defines functions and changes nothing.
if ($env:RELIAN_DEPLOY_TEST -eq '1' -and $MyInvocation.InvocationName -eq '.') {
    return
}

$result = Invoke-InspectJob
Write-Output $result.Line
exit $result.ExitCode
