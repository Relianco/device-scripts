# Standalone or Invoke-RelianRunner package. No provider APIs or toolkit dependency.
[CmdletBinding()]
param(
    [string]$DeploymentType = 'Install',
    [string]$Action = 'Install',
    [string]$PinVersion = '2.34.222',
    [string]$InstallerPath = '',
    [string]$InstallerUrl = '',
    [string]$InstallerSha256 = 'd274b91fea1b14c4fbb59391c38905dbaa64ce57ba7fa226fedf523e06205413',
    [string]$CancelPath = ''
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function ConvertTo-GsaVersion {
    param([string]$Text)
    if ($Text -notmatch '^\d+\.\d+\.\d+(\.\d+)?$') { throw 'Unreadable GSA version; refusing to change installed clients.' }
    $v = [version]$Text
    return [version]::new($v.Major, $v.Minor, $v.Build, [Math]::Max(0, $v.Revision))
}

function Select-GsaBundles {
    param([object[]]$Entries)
    $matches = @($Entries | Where-Object {
        $_.PSObject.Properties['DisplayName'] -and $_.PSObject.Properties['Publisher'] -and
        $_.Publisher -eq 'Microsoft Corporation' -and
        $_.DisplayName -match '^Global Secure Access Client(?: Installer \d+\.\d+\.\d+(?:\.\d+)? \(x64\))?$'
    })
    $bundles = @($matches | Where-Object { $_.PSObject.Properties['BundleCachePath'] })
    if ($matches.Count -gt 0 -and $bundles.Count -eq 0) {
        throw 'GSA is registered without a cached bundle. Repair its uninstall registration before replacing it.'
    }
    return $bundles
}

$script:GetGsaInstalled = {
    # Explicit views work under both 32-bit and 64-bit PowerShell. No Win32_Product.
    $entries = @(
        foreach ($view in @([Microsoft.Win32.RegistryView]::Registry64, [Microsoft.Win32.RegistryView]::Registry32)) {
            $hive = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $view)
            try {
                $root = $hive.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')
                if ($null -eq $root) { continue }
                try {
                    foreach ($name in $root.GetSubKeyNames()) {
                        $key = $root.OpenSubKey($name)
                        if ($null -eq $key) { throw 'Uninstall registration changed during discovery; retry.' }
                        try {
                            $entry = @{}
                            foreach ($field in @('DisplayName', 'Publisher', 'DisplayVersion', 'BundleCachePath', 'WindowsInstaller')) {
                                $value = $key.GetValue($field)
                                if ($null -ne $value) { $entry[$field] = $value }
                            }
                            [pscustomobject]$entry
                        } finally { $key.Dispose() }
                    }
                } finally { $root.Dispose() }
            } finally { $hive.Dispose() }
        }
    )
    Select-GsaBundles -Entries $entries
}

function Assert-GsaMicrosoftSignature {
    param([string]$Path)
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne 'Valid' -or $null -eq $signature.SignerCertificate -or
        $signature.SignerCertificate.Subject -notmatch '(?:^|,\s*)O=Microsoft Corporation(?:,|$)') {
        throw 'GSA executable does not have a valid Microsoft signature.'
    }
}

$script:ValidateGsaUninstaller = {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.Path]::IsPathRooted($Path) -or
        [IO.Path]::GetExtension($Path) -ne '.exe' -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw 'Cached GSA uninstaller is missing; no client was removed.'
    }
    Assert-GsaMicrosoftSignature -Path $Path
}

$script:PrepareGsaInstaller = {
    param($InstallerPath, $InstallerUrl, $InstallerSha256, $Destination, $PinVersion)
    # Stage and verify first: removing GSA may interrupt the network.
    if (-not [string]::IsNullOrWhiteSpace($InstallerPath)) {
        Copy-Item -LiteralPath $InstallerPath -Destination $Destination
    } else {
        Invoke-WebRequest -Uri $InstallerUrl -OutFile $Destination -UseBasicParsing | Out-Null
    }
    if ((Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash -ine $InstallerSha256) {
        throw 'GSA installer hash mismatch; no client was removed.'
    }
    $actual = ConvertTo-GsaVersion ([Diagnostics.FileVersionInfo]::GetVersionInfo($Destination).ProductVersion)
    if ($actual -ne (ConvertTo-GsaVersion $PinVersion)) { throw 'GSA installer version does not match PinVersion.' }
    Assert-GsaMicrosoftSignature -Path $Destination
    return $Destination
}

$script:RunGsaProcess = {
    param($Path, $Arguments)
    $process = Start-Process -FilePath $Path -ArgumentList $Arguments -Wait -PassThru -WindowStyle Hidden
    return [int]$process.ExitCode
}

function Test-GsaCancelled {
    param([string]$CancelPath)
    return ($env:RELIAN_DEPLOY_CANCEL -eq '1' -or
        (-not [string]::IsNullOrWhiteSpace($CancelPath) -and (Test-Path -LiteralPath $CancelPath)))
}

function Invoke-GsaAction {
    param([string]$Action, [string]$PinVersion, [string]$InstallerPath, [string]$InstallerUrl,
        [string]$InstallerSha256, [string]$CancelPath)
    if ([string]::IsNullOrWhiteSpace($InstallerSha256) -or [string]::IsNullOrWhiteSpace($PinVersion)) { return 0 }
    $cache = ''
    $phase = 'validating parameters'
    try {
        if ($InstallerSha256 -notmatch '^[0-9a-fA-F]{64}$') { throw 'Invalid installer SHA256.' }
        if ($Action -notin @('Install', 'Update')) { throw 'GSA supports Install and Update only.' }
        $pin = ConvertTo-GsaVersion $PinVersion
        if (-not [string]::IsNullOrWhiteSpace($InstallerUrl)) {
            $uri = [uri]$InstallerUrl
            if (-not $uri.IsAbsoluteUri -or $uri.Scheme -ne 'https' -or $uri.UserInfo -ne '') {
                throw 'InstallerUrl must be HTTPS without userinfo.'
            }
        }
        $phase = 'reading GSA bundle registration and versions'
        $installed = @(& $script:GetGsaInstalled)
        $older = @(); $current = $false
        foreach ($entry in $installed) {
            if (-not $entry.PSObject.Properties['DisplayVersion']) { throw 'GSA version missing.' }
            $version = ConvertTo-GsaVersion $entry.DisplayVersion
            if ($version -lt $pin) { $older += $entry } else { $current = $true }
        }
        # Do not run an old bundle against a coexisting current client: its uninstall
        # chain can remove shared components. Require manual repair of that state.
        if ($current -and $older.Count -gt 0) { throw 'Old and current GSA bundles coexist; refusing to remove shared components.' }
        if ($current) { Write-Host 'GSA is already at or above the target version.'; return 0 }
        if (Test-GsaCancelled $CancelPath) { return 130 }
        if ([string]::IsNullOrWhiteSpace($InstallerPath) -and [string]::IsNullOrWhiteSpace($InstallerUrl)) {
            throw 'Supply InstallerPath or InstallerUrl for the pinned GSA installer.'
        }
        if ($InstallerPath -and $InstallerUrl) { throw 'Supply only one installer source.' }
        $cache = Join-Path ([IO.Path]::GetTempPath()) ('relian-gsa-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $cache | Out-Null
        $phase = 'staging the replacement and verifying its hash, version, and Microsoft signature'
        $payload = & $script:PrepareGsaInstaller -InstallerPath $InstallerPath -InstallerUrl $InstallerUrl -InstallerSha256 $InstallerSha256 -Destination (Join-Path $cache 'GlobalSecureAccessInstaller.exe') -PinVersion $PinVersion
        $phase = 'validating cached Microsoft bundle uninstallers'
        # Validate all uninstallers before making any change.
        foreach ($entry in $older) { & $script:ValidateGsaUninstaller -Path ([string]$entry.BundleCachePath) }
        foreach ($entry in $older) {
            if (Test-GsaCancelled $CancelPath) { return 130 }
            $phase = 'removing an older GSA bundle'
            Write-Host ('Removing GSA {0} before installing {1}.' -f $entry.DisplayVersion, $PinVersion)
            $code = & $script:RunGsaProcess -Path $entry.BundleCachePath -Arguments @('/uninstall', '/quiet', '/norestart')
            if ($null -eq $code) { throw 'GSA uninstaller returned no exit code.' }
            if ($code -ne 0) {
                if ($code -eq 3010 -or $code -eq 1641) { Write-Host 'GSA removal requires a reboot. Reboot and rerun this package to install the replacement.' }
                return [int]$code
            }
        }
        $phase = 'confirming old GSA registration was removed'
        if ($older.Count -gt 0 -and @(& $script:GetGsaInstalled).Count -gt 0) {
            throw 'GSA is still registered after removal; replacement was not started.'
        }
        if (Test-GsaCancelled $CancelPath) { return 130 }
        $phase = 'installing the replacement'
        Write-Host ('Installing GSA {0}.' -f $PinVersion)
        $code = & $script:RunGsaProcess -Path $payload -Arguments @('/install', '/quiet', '/norestart')
        if ($null -eq $code) { throw 'GSA installer returned no exit code.' }
        if ($code -ne 0) { return [int]$code }
        $phase = 'verifying the installed GSA version'
        $after = @(& $script:GetGsaInstalled)
        if ($after.Count -eq 0) { throw 'GSA installer succeeded but no client is registered.' }
        foreach ($entry in $after) {
            if ((ConvertTo-GsaVersion $entry.DisplayVersion) -lt $pin) { throw 'GSA is still below the target version.' }
        }
        return 0
    } catch {
        # Do not echo exception text: download errors can contain URL query credentials.
        Write-Warning ('GSA replacement failed while {0}. Check the source, installer logs, and registration; no automatic retry.' -f $phase)
        return 1
    } finally {
        if ($cache -and (Test-Path -LiteralPath $cache)) { Remove-Item -LiteralPath $cache -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

if ($env:RELIAN_DEPLOY_TEST -eq '1' -and $MyInvocation.InvocationName -eq '.') { return }
exit (Invoke-GsaAction -Action $Action -PinVersion $PinVersion -InstallerPath $InstallerPath -InstallerUrl $InstallerUrl -InstallerSha256 $InstallerSha256 -CancelPath $CancelPath)
