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
$script:FieldKey = -join @('FAKEFIELDKEY', '3333', 'NOTREAL')
$script:FieldName = 'autoelevateLicenseKey'

# NinjaOne's Ninja-Property-Get (module NJCliPSh) is the boundary: it runs ninjarmm-cli with the
# field name. The fake records every argument it is handed, which stands for that command line.
$script:FieldCalls = [System.Collections.Generic.List[string]]::new()
function Ninja-Property-Get {
    param([Parameter(Position = 0)][string]$Name)
    $script:FieldCalls.Add($Name)
    if ($Name -ceq $script:FieldName) { return ($script:FieldKey + "`r`n") }
    throw 'field not found'
}
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

# PowerShell module logging (event 4103) records every value a cmdlet is bound to, so the key must
# not pass through a cmdlet pipeline. These wrappers shadow the cmdlets and note any key they see.
$script:PipelineKeyHits = [System.Collections.Generic.List[string]]::new()
function Test-HoldsFakeKey { param($Value) return ([string]$Value) -match 'FAKE[A-Z]*KEY' }
function Where-Object {
    param([Parameter(ValueFromPipeline = $true)]$InputObject, [Parameter(Position = 0)][scriptblock]$FilterScript)
    process {
        if (Test-HoldsFakeKey $InputObject) { $script:PipelineKeyHits.Add('Where-Object') }
        $InputObject | Microsoft.PowerShell.Core\Where-Object -FilterScript $FilterScript
    }
}
function ForEach-Object {
    param([Parameter(ValueFromPipeline = $true)]$InputObject, [Parameter(Position = 0)][scriptblock]$Process)
    process {
        if (Test-HoldsFakeKey $InputObject) { $script:PipelineKeyHits.Add('ForEach-Object') }
        $InputObject | Microsoft.PowerShell.Core\ForEach-Object -Process $Process
    }
}

try {
    # 1. The key, from -LicenseKey or AE_LICENSE_KEY, on a fresh or an installed device,
    #    is on no argument list handed to a process hook, nor in the report.
    foreach ($source in @('argument', 'environment', 'field')) {
        foreach ($installed in @($false, $true)) {
            Reset-Case -Installed $installed
            if ($source -eq 'field') {
                $script:FieldCalls.Clear()
                $key = Select-AutoElevateKey -Argument '' -Field $script:FieldName
                $want = $script:FieldKey
                if ($key -cne $want) { Fail "[field] the key was not read from the field (got $($key.Length) characters)" }
                if (($script:FieldCalls -join '|') -cne $script:FieldName) { Fail "[field] Ninja-Property-Get calls: $($script:FieldCalls -join '|')" }
            } elseif ($source -eq 'environment') {
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
            if (@($script:HookArgs | Where-Object { $_ -match '^msiexec ' -and $_ -match '(^|\s)/l' }).Count) { Fail "[$label] msiexec writes a log (/l), which would hold the key" }
            foreach ($prop in @('COMPANY_NAME="Example Company"', 'COMPANY_INITIALS="EC"', 'LOCATION_NAME="Main Office"', 'ELEVATION_MODE="live"')) {
                if (-not $all.Contains($prop)) { Fail "[$label] msiexec lacks $prop" }
            }
        }
    }

    if ($script:PipelineKeyHits.Count) { Fail "the key went through a cmdlet pipeline (module logging 4103 would record it): $($script:PipelineKeyHits -join ', ')" }

    # 1b. Precedence: a LicenseKey argument, then AE_LICENSE_KEY, then the field. The field is
    #     read only when both are empty, so a caller that passes the key causes no NinjaOne call.
    $script:FieldCalls.Clear()
    if ((Select-AutoElevateKey -Argument $script:ArgKey -Field $script:FieldName) -cne $script:ArgKey -or $script:FieldCalls.Count) { Fail 'argument must win over the field, with no field read' }
    $env:AE_LICENSE_KEY = $script:EnvKey
    $got = Select-AutoElevateKey -Argument '' -Field $script:FieldName
    Remove-Item -LiteralPath 'Env:AE_LICENSE_KEY'
    if ($got -cne $script:EnvKey -or $script:FieldCalls.Count) { Fail 'AE_LICENSE_KEY must win over the field, with no field read' }
    if ((Select-AutoElevateKey -Argument '' -Field '') -ne '' -or $script:FieldCalls.Count) { Fail 'no field named: no field read, empty key' }

    # 1c. A field name that is not a NinjaOne field name is refused before any call; an unreadable
    #     field gives an empty key and an error naming the field, never a throw or a value.
    $script:AutoElevateErrorLog = [System.Collections.Generic.List[string]]::new()
    foreach ($bad in @('a b', 'x;y', '-Name', ('a' * 101))) {
        if ((Select-AutoElevateKey -Argument '' -Field $bad) -ne '') { Fail "bad field name [$bad] gave a key" }
    }
    if ($script:FieldCalls.Count) { Fail "bad field names reached Ninja-Property-Get: $($script:FieldCalls -join '|')" }
    if ($script:AutoElevateErrorLog.Count -ne 4) { Fail "bad field names logged $($script:AutoElevateErrorLog.Count) errors" }
    $script:AutoElevateErrorLog.Clear()
    if ((Select-AutoElevateKey -Argument '' -Field 'missingField') -ne '') { Fail 'an unreadable field gave a key' }
    if (($script:AutoElevateErrorLog -join ' ') -notmatch 'missingField') { Fail "unreadable field error: $($script:AutoElevateErrorLog -join ' ')" }

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

    # 3c. Runner 374 Reinstall = Uninstall step, then Install step, each with the same arguments.
    #     An Uninstall that carries registration values is the first half of a re-registration: it
    #     must not remove the agent when the key is not there yet (an org field takes minutes to
    #     reach the agent), or the device is left without AutoElevate.
    Reset-Case -Installed $true
    $code = [int](Invoke-AutoElevateAction -DeploymentType 'Uninstall' -Action 'Uninstall' -PinVersion '2.11.1959' -InstallerUrl 'https://example.invalid/AESetup.msi' -InstallerSha256 $script:GoodSha -CancelPath '' -MarkerRoot $script:MarkerRoot -LicenseKey '' -CompanyName 'Example Company' -LocationName 'Main Office')
    if ($code -ne 1 -or $script:Calls -contains 'msiexec uninstall') { Fail "uninstall with names and no key: exit $code calls $($script:Calls -join ', ')" }
    Reset-Case -Installed $true
    $code = [int](Invoke-AutoElevateAction -DeploymentType 'Uninstall' -Action 'Uninstall' -PinVersion '2.11.1959' -InstallerUrl 'https://example.invalid/AESetup.msi' -InstallerSha256 $script:GoodSha -CancelPath '' -MarkerRoot $script:MarkerRoot -LicenseKey $script:FieldKey -CompanyName 'Example Company' -LocationName 'Main Office')
    if ($code -ne 0 -or $script:Calls -notcontains 'msiexec uninstall') { Fail "uninstall with names and the key: exit $code calls $($script:Calls -join ', ')" }
    Reset-Case -Installed $true
    $code = [int](Invoke-AutoElevateAction -DeploymentType 'Uninstall' -Action 'Uninstall' -PinVersion '2.11.1959' -InstallerUrl 'https://example.invalid/AESetup.msi' -InstallerSha256 $script:GoodSha -CancelPath '' -MarkerRoot $script:MarkerRoot)
    if ($code -ne 0 -or $script:Calls -notcontains 'msiexec uninstall') { Fail "plain uninstall: exit $code calls $($script:Calls -join ', ')" }

    # 4. End to end, as runner 374 starts it: a child process with only LicenseKeyField on its command
    #    line finds Ninja-Property-Get by module autoload (NJCliPSh, as on a NinjaOne device), gets the
    #    key, and moves on to the next check. No names, so it stops before the registry and the download.
    $modules = Join-Path $script:Root 'modules'
    New-Item -ItemType Directory -Path (Join-Path $modules 'NJCliPSh') -Force | Out-Null
    $fake = "function Ninja-Property-Get { param([Parameter(Position = 0)][string]`$Name) if (`$Name -ceq '$script:FieldName') { '$script:FieldKey' } else { throw 'no field' } }"
    Set-Content -LiteralPath (Join-Path $modules 'NJCliPSh/NJCliPSh.psm1') -Value $fake
    $childArgs = @('-NoProfile', '-NonInteractive', '-File', $scriptPath, '-DeploymentType', 'Install', '-Action', 'Install', '-PinVersion', '2.11.1959', '-InstallerUrl', 'https://example.invalid/AESetup.msi', '-InstallerSha256', $script:GoodSha, '-LicenseKeyField', $script:FieldName)
    if (($childArgs -join ' ').Contains($script:FieldKey)) { Fail 'the child command line holds the key' }
    $savedPath = $env:PSModulePath
    $savedTest = $env:RELIAN_DEPLOY_TEST
    try {
        $env:PSModulePath = $modules + [IO.Path]::PathSeparator + $savedPath
        Remove-Item -LiteralPath 'Env:RELIAN_DEPLOY_TEST'
        $out = (& (Get-Process -Id $PID).Path @childArgs 2>&1 | Out-String)
        $childExit = $LASTEXITCODE
    } finally {
        $env:PSModulePath = $savedPath
        $env:RELIAN_DEPLOY_TEST = $savedTest
    }
    if ($out.Contains($script:FieldKey)) { Fail 'child output holds the key' }
    if ($childExit -ne 1 -or $out -notmatch 'registration needs CompanyName and LocationName') { Fail "child did not get the key from the field (exit $childExit): $out" }

    # 4b. The names can come from NinjaOne fields too (CompanyNameField, LocationNameField), so one
    #     condition on a shared policy serves every organization. ElevationMode LIVE (wrong case) is
    #     the next check after the key and the names, so reaching it proves all three were read.
    $fake = "function Ninja-Property-Get { param([Parameter(Position = 0)][string]`$Name) switch -CaseSensitive (`$Name) { '$script:FieldName' { '$script:FieldKey' } 'aeCompany' { 'Example Company' } 'aeLocation' { 'Main Office' } default { throw 'no field' } } }"
    Set-Content -LiteralPath (Join-Path $modules 'NJCliPSh/NJCliPSh.psm1') -Value $fake
    $childArgs += @('-CompanyNameField', 'aeCompany', '-LocationNameField', 'aeLocation', '-ElevationMode', 'LIVE')
    try {
        $env:PSModulePath = $modules + [IO.Path]::PathSeparator + $savedPath
        Remove-Item -LiteralPath 'Env:RELIAN_DEPLOY_TEST'
        $out = (& (Get-Process -Id $PID).Path @childArgs 2>&1 | Out-String)
        $childExit = $LASTEXITCODE
    } finally {
        $env:PSModulePath = $savedPath
        $env:RELIAN_DEPLOY_TEST = $savedTest
    }
    if ($childExit -ne 1 -or $out -notmatch 'ElevationMode must be audit, live or policy') { Fail "child did not get the names from the fields (exit $childExit): $out" }

    # 4c. A name given as an argument wins over its field, and that field is not read.
    $script:FieldCalls.Clear()
    if ((Select-AutoElevateName -Value 'Given Co' -Field 'aeCompany') -cne 'Given Co' -or $script:FieldCalls.Count) { Fail 'CompanyName argument must win over CompanyNameField' }
    if ((Select-AutoElevateName -Value '' -Field '') -ne '' -or $script:FieldCalls.Count) { Fail 'no name field: no read' }

} finally {
    Remove-Item -LiteralPath 'Env:AE_LICENSE_KEY' -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $script:Root) { Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Output 'autoelevate-key-off-cmdline tests passed'
exit 0
