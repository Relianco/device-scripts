$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# The license key never reaches a process command line (msiexec or any other hook).
# Windows logs command lines (Sysmon 1, Security 4688), so the key goes to the registry
# from this process instead, where the MSI AppSearch reads it (LICENSE_KEY_REG).
# Mocks only. No network, no registry, no msiexec.
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$scriptPath = Join-Path $repoRoot 'windows/packages/autoelevate/Invoke-AutoElevate.ps1'

function Fail {
    param([string]$Message)
    [Console]::Error.WriteLine("FAIL $Message")
    exit 1
}

$env:RELIAN_DEPLOY_TEST = '1'
. $scriptPath

# Obviously fake keys, built at run time so the repo holds no key-shaped literal.
$script:ArgKey = -join @('FAKEARGKEY', '0000', 'NOTREAL')
$script:EnvKey = -join @('FAKEENVKEY', '1111', 'NOTREAL')
$utf8 = [System.Text.UTF8Encoding]::new($false)
$script:GoodBytes = $utf8.GetBytes('autoelevate-installer')
$sha = [System.Security.Cryptography.SHA256]::Create()
$script:GoodSha = ([System.BitConverter]::ToString($sha.ComputeHash($script:GoodBytes))).Replace('-', '').ToLowerInvariant()
$sha.Dispose()
$script:Root = Join-Path ([System.IO.Path]::GetTempPath()) ('autoelevate-keyoff-' + [guid]::NewGuid().ToString('n'))
$script:MarkerRoot = Join-Path $script:Root 'marker'

function Reset-Case {
    param([bool]$Installed)
    $script:HookArgs = [System.Collections.Generic.List[string]]::new()
    $script:Calls = [System.Collections.Generic.List[string]]::new()
    $script:Reg = [System.Collections.Generic.List[string]]::new()
    $script:MsiExit = 0
    $script:PriorKey = $null
    $script:AutoElevateErrorLog = [System.Collections.Generic.List[string]]::new()
    $script:InstalledVersion = if ($Installed) { '2.8.2' } else { '' }
    $script:ServiceState = if ($Installed) { @{ AutoElevateAgent = 'Running'; AEDelayedStartService = 'Running' } } else { @{} }
    if (Test-Path -LiteralPath $script:MarkerRoot) { Remove-Item -LiteralPath $script:MarkerRoot -Recurse -Force }
    New-Item -ItemType Directory -Path $script:MarkerRoot -Force | Out-Null
    $script:RetryDelay = { param($Seconds) }
    $script:ServiceWait = { param($Seconds) }
    $script:DownloadFile = {
        param($Url, $Destination)
        $script:HookArgs.Add("download $Url $Destination")
        [System.IO.File]::WriteAllBytes($Destination, $script:GoodBytes)
    }
    $script:GetInstalledAutoElevateVersion = { return [string]$script:InstalledVersion }
    $script:GetAutoElevateProductCode = { return '{11111111-2222-3333-4444-555555555555}' }
    $script:GetAutoElevateRegistration = { return [pscustomobject]@{ Values = [ordered]@{}; HasLicenseKey = $false; HasSettings = $false } }
    $script:GetAutoElevateService = {
        param($Name)
        if (-not $script:ServiceState.ContainsKey($Name)) { return $null }
        return [pscustomobject]@{ Name = $Name; Status = $script:ServiceState[$Name]; StartType = 'Auto'; CanStop = $true; ProcessId = 4242; Recovery = 'none' }
    }
    $script:StopAutoElevateService = { param($Name) $script:HookArgs.Add("sc stop $Name"); $script:ServiceState[$Name] = 'Stopped' }
    $script:StartAutoElevateService = { param($Name) $script:HookArgs.Add("sc start $Name"); $script:ServiceState[$Name] = 'Running' }
    $script:InvokeMsiExec = {
        param($Mode, $ArgumentList)
        $script:Calls.Add("msiexec $Mode")
        $script:HookArgs.Add('msiexec ' + (@($ArgumentList) -join ' '))
        if ($script:MsiExit -ne 0) { return $script:MsiExit }
        $script:InstalledVersion = '2.11.1959'
        $script:ServiceState['AutoElevateAgent'] = 'Running'
        return 0
    }
    # Fake HKLM base key: records the view, subkey, value name, data and kind it is handed.
    $script:OpenAutoElevateRegistryBase = {
        param($View)
        $script:Calls.Add('registry')
        $script:Reg.Add("open $View")
        $sub = [pscustomobject]@{}
        $sub | Add-Member ScriptMethod GetValue { param($n, $d) if ($null -ne $script:PriorKey) { return $script:PriorKey } return $d }
        $sub | Add-Member ScriptMethod SetValue { param($n, $v, $k) $script:Reg.Add("set $n=$v ($k)") }
        $sub | Add-Member ScriptMethod DeleteValue { param($n, $throw) $script:Reg.Add("delete $n") }
        $sub | Add-Member ScriptMethod Dispose { }
        $base = [pscustomobject]@{ Sub = $sub }
        $base | Add-Member ScriptMethod CreateSubKey { param($p) $script:Reg.Add("create $p"); return $this.Sub }
        $base | Add-Member ScriptMethod OpenSubKey { param($p, $w) $script:Reg.Add("opensub $p $w"); return $this.Sub }
        $base | Add-Member ScriptMethod Dispose { }
        return $base
    }
}

function Invoke-Case {
    param([string]$LicenseKey)
    return [int](Invoke-AutoElevateAction -DeploymentType 'Install' -Action 'Install' -PinVersion '2.11.1959' -InstallerUrl 'https://example.invalid/AESetup.msi' -InstallerSha256 $script:GoodSha -CancelPath '' -MarkerRoot $script:MarkerRoot -LicenseKey $LicenseKey -CompanyName 'Example Company' -CompanyInitials 'EC' -LocationName 'Main Office' -ElevationMode 'live')
}

try {
    # 1. The key, from -LicenseKey or AE_LICENSE_KEY, on a fresh or an installed device,
    #    is on no argument list handed to a process hook, nor in the report.
    foreach ($source in @('argument', 'environment')) {
        foreach ($installed in @($false, $true)) {
            Reset-Case -Installed $installed
            if ($source -eq 'environment') {
                $env:AE_LICENSE_KEY = $script:EnvKey
                $key = Select-AutoElevateKey -Argument ''
                Remove-Item -LiteralPath 'Env:AE_LICENSE_KEY'
                $want = $script:EnvKey
            } else {
                $key = Select-AutoElevateKey -Argument $script:ArgKey
                $want = $script:ArgKey
            }
            $label = "$source, installed=$installed"
            $code = Invoke-Case -LicenseKey $key
            if ($code -ne 0) { Fail "[$label] exit $code errors $($script:AutoElevateErrorLog -join '; ')" }
            if ($script:Calls -notcontains 'msiexec install') { Fail "[$label] msiexec did not run" }
            $all = $script:HookArgs -join "`n"
            if ($all.Contains($want)) { Fail "[$label] key on a process argument list: $(ConvertTo-AutoElevateRedacted -Text $all)" }
            if ($all -match 'LICENSE_KEY') { Fail "[$label] LICENSE_KEY property still passed: $(ConvertTo-AutoElevateRedacted -Text $all)" }
            $msi = [string]$script:AutoElevateReport.MsiCommand
            if ($msi.Contains($want) -or $msi -match 'LICENSE_KEY') { Fail "[$label] report MsiCommand names the key: $msi" }
            foreach ($prop in @('COMPANY_NAME="Example Company"', 'COMPANY_INITIALS="EC"', 'LOCATION_NAME="Main Office"', 'ELEVATION_MODE="live"')) {
                if (-not $all.Contains($prop)) { Fail "[$label] msiexec lacks $prop" }
            }
        }
    }

    # 2. The key is written from this process to HKLM\SOFTWARE\AutoElevate LicenseKey,
    #    REG_SZ, 64-bit view (the AESetup.msi RegLocator row, type 18), before msiexec.
    Reset-Case -Installed $false
    $code = Invoke-Case -LicenseKey $script:ArgKey
    if ($code -ne 0) { Fail "registry write case exit $code" }
    $want = @('open Registry64', 'create SOFTWARE\AutoElevate', ('set LicenseKey=' + $script:ArgKey + ' (String)'))
    if (($script:Reg -join '|') -cne ($want -join '|')) { Fail "registry calls: $(ConvertTo-AutoElevateRedacted -Text ($script:Reg -join '|'))" }
    if ($script:Calls.IndexOf('registry') -lt 0 -or $script:Calls.IndexOf('registry') -gt $script:Calls.IndexOf('msiexec install')) { Fail "registry write not before msiexec: $($script:Calls -join ', ')" }

    # 2b. A registered upgrade with no key writes nothing to the registry.
    Reset-Case -Installed $true
    $script:GetAutoElevateRegistration = { return [pscustomobject]@{ Values = [ordered]@{ CompanyName = 'Example Company'; LocationName = 'Main Office' }; HasLicenseKey = $true; HasSettings = $true } }
    $code = [int](Invoke-AutoElevateAction -DeploymentType 'Install' -Action 'Install' -PinVersion '2.11.1959' -InstallerUrl 'https://example.invalid/AESetup.msi' -InstallerSha256 $script:GoodSha -CancelPath '' -MarkerRoot $script:MarkerRoot)
    if ($code -ne 0 -or $script:Reg.Count -ne 0) { Fail "registered upgrade exit $code registry $($script:Reg -join '|')" }

    # 2c. A registry write that throws exits 1 before msiexec and restarts the stopped services.
    Reset-Case -Installed $true
    $script:OpenAutoElevateRegistryBase = { param($View) throw 'access denied' }
    $code = Invoke-Case -LicenseKey $script:ArgKey
    if ($code -ne 1 -or $script:Calls -contains 'msiexec install') { Fail "registry throw exit $code calls $($script:Calls -join ', ')" }
    if ($script:ServiceState['AutoElevateAgent'] -ne 'Running') { Fail 'registry throw left the agent stopped' }

    # 3. msiexec fails on a fresh device: the value written is removed.
    Reset-Case -Installed $false
    $script:MsiExit = 1603
    $code = Invoke-Case -LicenseKey $script:ArgKey
    if ($code -ne 1) { Fail "fresh 1603 exit $code" }
    $want = @('open Registry64', 'create SOFTWARE\AutoElevate', ('set LicenseKey=' + $script:ArgKey + ' (String)'), 'open Registry64', 'opensub SOFTWARE\AutoElevate True', 'delete LicenseKey')
    if (($script:Reg -join '|') -cne ($want -join '|')) { Fail "fresh 1603 registry calls: $(ConvertTo-AutoElevateRedacted -Text ($script:Reg -join '|'))" }
    if ((($script:AutoElevateErrorLog -join ' ') + (ConvertTo-Json -InputObject $script:AutoElevateReport -Compress)).Contains($script:ArgKey)) { Fail 'fresh 1603 leaked the key' }

    # 3b. msiexec fails on an installed device: the key the agent had before is put back.
    $oldKey = -join @('FAKEOLDKEY', '2222', 'NOTREAL')
    Reset-Case -Installed $true
    $script:PriorKey = $oldKey
    $script:MsiExit = 1603
    $code = Invoke-Case -LicenseKey $script:ArgKey
    if ($code -ne 1) { Fail "installed 1603 exit $code" }
    $want = @('open Registry64', 'create SOFTWARE\AutoElevate', ('set LicenseKey=' + $script:ArgKey + ' (String)'), 'open Registry64', 'create SOFTWARE\AutoElevate', ('set LicenseKey=' + $oldKey + ' (String)'))
    if (($script:Reg -join '|') -cne ($want -join '|')) { Fail "installed 1603 did not restore the old key: $(($script:Reg -join '|').Replace($script:ArgKey, '[new]'))" }

} finally {
    Remove-Item -LiteralPath 'Env:AE_LICENSE_KEY' -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $script:Root) { Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Output 'autoelevate-key-off-cmdline tests passed'
exit 0
