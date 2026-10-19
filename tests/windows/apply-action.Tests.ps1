$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$scriptPath = Join-Path $repoRoot 'windows/packages/apply-action/Invoke-ApplyAction.ps1'
$releasePath = Join-Path $repoRoot 'windows/releases/apply-action.json'
$actionRoot = Join-Path $repoRoot 'windows/actions'

function Fail {
    param([string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) {
        $Message = 'test failed'
    }
    [Console]::Error.WriteLine("FAIL $Message")
    exit 1
}

if (-not (Test-Path -LiteralPath $scriptPath)) {
    Fail 'Invoke-ApplyAction.ps1 does not exist'
}

$env:RELIAN_DEPLOY_TEST = '1'
. $scriptPath

if (-not (Get-Command Invoke-ApplyActionAction -ErrorAction SilentlyContinue)) {
    Fail 'Invoke-ApplyActionAction was not defined'
}

$utf8 = [System.Text.UTF8Encoding]::new($false)

function Get-Sha {
    param([byte[]]$Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function New-HttpFailure {
    param([int]$Status, [string]$Message)
    $exception = [System.Net.Http.HttpRequestException]::new(
        $Message,
        $null,
        [System.Net.HttpStatusCode]$Status
    )
    throw $exception
}

$root = Join-Path ([System.IO.Path]::GetTempPath()) ('apply-action-' + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $root -Force | Out-Null
$dest = Join-Path $root 'payload.json'
$markerRoot = Join-Path $root 'marker'
$script:DownloadCount = 0
$script:DownloadUrls = [System.Collections.Generic.List[string]]::new()
$script:Sleeps = [System.Collections.Generic.List[int]]::new()
$script:RegistryWrites = [System.Collections.Generic.List[object]]::new()
$script:ServiceLookups = 0
$script:ServiceConfigs = 0
$script:ServicePresent = $false
$script:PayloadBytes = $utf8.GetBytes('{}')

function Reset-Hooks {
    $script:DownloadCount = 0
    $script:DownloadUrls.Clear()
    $script:Sleeps.Clear()
    $script:RegistryWrites.Clear()
    $script:ServiceLookups = 0
    $script:ServiceConfigs = 0
    $script:ServicePresent = $false
    $script:ApplyActionErrorLog.Clear()
    $script:DownloadFile = {
        param($Url, $Destination)
        $script:DownloadCount++
        $script:DownloadUrls.Add([string]$Url)
        [System.IO.File]::WriteAllBytes($Destination, $script:PayloadBytes)
    }
    $script:WriteRegistry = {
        param($Operation, $FullPath, $Name, $Type, $Value)
        $script:RegistryWrites.Add([pscustomobject]@{
                Operation = [string]$Operation
                FullPath  = [string]$FullPath
                Name      = [string]$Name
                Type      = [string]$Type
                Value     = $Value
            })
        return 0
    }
    Remove-Item -LiteralPath 'Env:RELIAN_DEPLOY_CANCEL' -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $markerRoot) {
        Remove-Item -LiteralPath $markerRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Path $markerRoot -Force | Out-Null
}

$script:RetryDelay = {
    param($Seconds)
    $script:Sleeps.Add([int]$Seconds)
}

$script:DownloadFile = {
    param($Url, $Destination)
    $script:DownloadCount++
    $script:DownloadUrls.Add([string]$Url)
    [System.IO.File]::WriteAllBytes($Destination, $script:PayloadBytes)
}

$script:WriteRegistry = {
    param($Operation, $FullPath, $Name, $Type, $Value)
    $script:RegistryWrites.Add([pscustomobject]@{
            Operation = [string]$Operation
            FullPath  = [string]$FullPath
            Name      = [string]$Name
            Type      = [string]$Type
            Value     = $Value
        })
    return 0
}

$script:TestServicePresent = {
    param($Name)
    $script:ServiceLookups++
    return [bool]$script:ServicePresent
}

$script:ConfigureService = {
    param($Name, $Startup, $State)
    $script:ServiceConfigs++
    return 0
}

function New-Sample {
    param([string]$Json)
    $bytes = $utf8.GetBytes($Json)
    return [pscustomobject]@{
        Bytes = $bytes
        Sha   = (Get-Sha $bytes)
    }
}

$oneStep = New-Sample -Json '{"schema":1,"id":"sample","title":"Sample","description":"One value.","steps":[{"kind":"registry","op":"set","hive":"HKLM","path":"SOFTWARE\\Test","name":"Alpha","type":"dword","value":1}]}'
$threeSteps = New-Sample -Json '{"schema":1,"id":"sample","title":"Sample","description":"Three values.","steps":[{"kind":"registry","op":"set","hive":"HKLM","path":"SOFTWARE\\Test","name":"Alpha","type":"dword","value":1},{"kind":"registry","op":"set","hive":"HKLM","path":"SOFTWARE\\Test","name":"Beta","type":"dword","value":2},{"kind":"registry","op":"set","hive":"HKLM","path":"SOFTWARE\\Test","name":"Gamma","type":"dword","value":3}]}'
$badKind = New-Sample -Json '{"schema":1,"id":"sample","title":"Sample","description":"Bad kind.","steps":[{"kind":"firewall","op":"set"}]}'
$badSchema = New-Sample -Json '{"schema":2,"id":"sample","title":"Sample","description":"Bad schema.","steps":[{"kind":"registry","op":"set","hive":"HKLM","path":"SOFTWARE\\Test","name":"Alpha","type":"dword","value":1}]}'
$stringDword = New-Sample -Json '{"schema":1,"id":"sample","title":"Sample","description":"String dword.","steps":[{"kind":"registry","op":"set","hive":"HKLM","path":"SOFTWARE\\Test","name":"Alpha","type":"dword","value":"1"}]}'
$hkcu = New-Sample -Json '{"schema":1,"id":"sample","title":"Sample","description":"Current user.","steps":[{"kind":"registry","op":"set","hive":"HKCU","path":"SOFTWARE\\Test","name":"Alpha","type":"dword","value":1}]}'
$serviceFail = New-Sample -Json '{"schema":1,"id":"sample","title":"Sample","description":"Service must exist.","steps":[{"kind":"service","name":"SampleSvc","startup":"disabled","state":"stopped","missing":"fail"}]}'
$serviceSkip = New-Sample -Json '{"schema":1,"id":"sample","title":"Sample","description":"Service may be absent.","steps":[{"kind":"service","name":"SampleSvc","startup":"disabled","missing":"skip"}]}'
$withUndo = New-Sample -Json '{"schema":1,"id":"sample","title":"Sample","description":"Has undo.","steps":[{"kind":"registry","op":"set","hive":"HKLM","path":"SOFTWARE\\Test","name":"Alpha","type":"dword","value":1}],"undo":[{"kind":"registry","op":"remove-value","hive":"HKLM","path":"SOFTWARE\\Test","name":"Alpha"}]}'
$userInfoBase = -join @('https://', 'user', '@', 'example.invalid/actions')
$plainBase = 'https://example.invalid/actions'

try {
    Reset-Hooks
    $code = Invoke-ApplyActionAction -Action 'Install' -PinVersion '' -ActionBaseUrl $userInfoBase -MarkerRoot $markerRoot
    if ($code -ne 0 -or $script:DownloadCount -ne 0 -or $script:DownloadUrls.Count -ne 0) {
        Fail "blank pin returned $code with $($script:DownloadCount) downloads"
    }

    Reset-Hooks
    $code = Invoke-ApplyActionAction -Action 'Uninstall' -PinVersion 'long-paths:   ' -ActionBaseUrl $userInfoBase -MarkerRoot $markerRoot
    if ($code -ne 0 -or $script:DownloadCount -ne 0) {
        Fail "empty hash side returned $code"
    }

    Reset-Hooks
    $code = [int](Save-ApplyActionPayload -Url $userInfoBase -Destination $dest -Sha256 '   ' -Label 'action')
    if ($code -ne 0 -or $script:DownloadCount -ne 0) {
        Fail "Save with an empty hash returned $code"
    }

    Reset-Hooks
    $code = Invoke-ApplyActionAction -Action 'Install' -PinVersion ('sample:' + $oneStep.Sha) -ActionBaseUrl $userInfoBase -MarkerRoot $markerRoot
    if ($code -ne 1 -or $script:DownloadCount -ne 0) {
        Fail "userinfo base returned $code with $($script:DownloadCount) downloads"
    }

    Reset-Hooks
    $upper = $oneStep.Sha.ToUpperInvariant()
    $code = Invoke-ApplyActionAction -Action 'Install' -PinVersion ('sample:' + $upper) -ActionBaseUrl $plainBase -MarkerRoot $markerRoot
    if ($code -ne 1 -or $script:DownloadCount -ne 0) {
        Fail "uppercase hash returned $code"
    }

    Reset-Hooks
    $code = Invoke-ApplyActionAction -Action 'Install' -PinVersion ('sample:' + ('a' * 64)) -ActionBaseUrl $plainBase -MarkerRoot $markerRoot
    if ($code -ne 1 -or $script:DownloadCount -ne 0) {
        Fail "repeated nibble returned $code"
    }

    Reset-Hooks
    $code = Invoke-ApplyActionAction -Action 'Install' -PinVersion ('..:' + $oneStep.Sha) -ActionBaseUrl $plainBase -MarkerRoot $markerRoot
    if ($code -ne 1 -or $script:DownloadCount -ne 0) {
        Fail "dotdot id returned $code"
    }

    Reset-Hooks
    $code = Invoke-ApplyActionAction -Action 'Install' -PinVersion $oneStep.Sha -ActionBaseUrl $plainBase -MarkerRoot $markerRoot
    if ($code -ne 1 -or $script:DownloadCount -ne 0) {
        Fail "pin without a colon returned $code"
    }

    Reset-Hooks
    $script:PayloadBytes = $utf8.GetBytes('not-the-file')
    $code = Invoke-ApplyActionAction -Action 'Install' -PinVersion ('sample:' + $oneStep.Sha) -ActionBaseUrl $plainBase -MarkerRoot $markerRoot
    if ($code -ne 1 -or $script:DownloadCount -ne 1 -or $script:Sleeps.Count -ne 0 -or $script:RegistryWrites.Count -ne 0) {
        Fail "hash mismatch returned $code downloads=$($script:DownloadCount) writes=$($script:RegistryWrites.Count)"
    }
    $markerPath = Join-Path $markerRoot 'marker.txt'
    if (Test-Path -LiteralPath $markerPath) {
        Fail 'hash mismatch wrote a marker'
    }

    Reset-Hooks
    $script:DownloadFile = {
        param($Url, $Destination)
        $script:DownloadCount++
        $script:DownloadUrls.Add([string]$Url)
        if ($script:DownloadCount -lt 3) {
            New-HttpFailure -Status 503 -Message 'unavailable'
        }
        [System.IO.File]::WriteAllBytes($Destination, $oneStep.Bytes)
    }
    $code = [int](Save-ApplyActionPayload -Url ($plainBase + '/sample.json') -Destination $dest -Sha256 $oneStep.Sha -Label 'action')
    if ($code -ne 0 -or $script:DownloadCount -ne 3 -or @($script:Sleeps) -join ',' -ne '5,20') {
        Fail "503 retry returned $code delays=$(@($script:Sleeps) -join ',')"
    }

    Reset-Hooks
    $script:DownloadFile = {
        param($Url, $Destination)
        $script:DownloadCount++
        New-HttpFailure -Status 404 -Message 'missing'
    }
    $code = [int](Save-ApplyActionPayload -Url ($plainBase + '/sample.json') -Destination $dest -Sha256 $oneStep.Sha -Label 'action')
    if ($code -ne 1 -or $script:DownloadCount -ne 1 -or $script:Sleeps.Count -ne 0) {
        Fail "404 was retried count=$($script:DownloadCount)"
    }

    Reset-Hooks
    $script:DownloadFile = {
        param($Url, $Destination)
        $script:DownloadCount++
        $socket = [System.Net.Sockets.SocketException]::new([System.Net.Sockets.SocketError]::AddressAlreadyInUse)
        throw $socket
    }
    $code = [int](Save-ApplyActionPayload -Url ($plainBase + '/sample.json') -Destination $dest -Sha256 $oneStep.Sha -Label 'action')
    if ($code -ne 1 -or $script:DownloadCount -ne 1 -or $script:Sleeps.Count -ne 0) {
        Fail "AddressAlreadyInUse was retried"
    }

    Reset-Hooks
    $script:DownloadFile = {
        param($Url, $Destination)
        $script:DownloadCount++
        throw [System.Threading.Tasks.TaskCanceledException]::new('canceled')
    }
    $code = [int](Save-ApplyActionPayload -Url ($plainBase + '/sample.json') -Destination $dest -Sha256 $oneStep.Sha -Label 'action')
    if ($code -ne 1 -or $script:DownloadCount -ne 1) {
        Fail 'a bare TaskCanceledException was retried'
    }

    Reset-Hooks
    $script:PayloadBytes = $badKind.Bytes
    $code = Invoke-ApplyActionAction -Action 'Install' -PinVersion ('sample:' + $badKind.Sha) -ActionBaseUrl $plainBase -MarkerRoot $markerRoot
    if ($code -ne 1 -or $script:RegistryWrites.Count -ne 0) {
        Fail "unknown kind returned $code writes=$($script:RegistryWrites.Count)"
    }

    Reset-Hooks
    $script:PayloadBytes = $badSchema.Bytes
    $code = Invoke-ApplyActionAction -Action 'Install' -PinVersion ('sample:' + $badSchema.Sha) -ActionBaseUrl $plainBase -MarkerRoot $markerRoot
    if ($code -ne 1 -or $script:RegistryWrites.Count -ne 0) {
        Fail "bad schema returned $code"
    }

    Reset-Hooks
    $script:PayloadBytes = $stringDword.Bytes
    $code = Invoke-ApplyActionAction -Action 'Install' -PinVersion ('sample:' + $stringDword.Sha) -ActionBaseUrl $plainBase -MarkerRoot $markerRoot
    if ($code -ne 1 -or $script:RegistryWrites.Count -ne 0) {
        Fail "string dword returned $code"
    }

    Reset-Hooks
    $script:PayloadBytes = $hkcu.Bytes
    $code = Invoke-ApplyActionAction -Action 'Install' -PinVersion ('sample:' + $hkcu.Sha) -ActionBaseUrl $plainBase -MarkerRoot $markerRoot
    if ($code -ne 1 -or $script:RegistryWrites.Count -ne 0) {
        Fail "HKCU returned $code"
    }

    Reset-Hooks
    $script:PayloadBytes = $threeSteps.Bytes
    $script:WriteRegistry = {
        param($Operation, $FullPath, $Name, $Type, $Value)
        $script:RegistryWrites.Add([pscustomobject]@{ Name = [string]$Name })
        if ($script:RegistryWrites.Count -ge 2) {
            return 1
        }
        return 0
    }
    [System.IO.File]::WriteAllText((Join-Path $markerRoot 'marker.txt'), "old`n", $utf8)
    $code = Invoke-ApplyActionAction -Action 'Install' -PinVersion ('sample:' + $threeSteps.Sha) -ActionBaseUrl $plainBase -MarkerRoot $markerRoot
    if ($code -ne 1 -or $script:RegistryWrites.Count -ne 2 -or [string]$script:RegistryWrites[0].Name -ne 'Alpha') {
        Fail "second-step failure returned $code writes=$($script:RegistryWrites.Count)"
    }
    $markerText = [System.IO.File]::ReadAllText((Join-Path $markerRoot 'marker.txt'))
    if ($markerText -ne "old`n") {
        Fail 'failed step replaced the marker'
    }

    Reset-Hooks
    $script:PayloadBytes = $serviceFail.Bytes
    $script:ServicePresent = $false
    $code = Invoke-ApplyActionAction -Action 'Install' -PinVersion ('sample:' + $serviceFail.Sha) -ActionBaseUrl $plainBase -MarkerRoot $markerRoot
    if ($code -ne 1 -or $script:ServiceConfigs -ne 0) {
        Fail "missing service fail returned $code configs=$($script:ServiceConfigs)"
    }

    Reset-Hooks
    $script:PayloadBytes = $serviceSkip.Bytes
    $script:ServicePresent = $false
    $code = Invoke-ApplyActionAction -Action 'Install' -PinVersion ('sample:' + $serviceSkip.Sha) -ActionBaseUrl $plainBase -MarkerRoot $markerRoot
    if ($code -ne 0 -or $script:ServiceConfigs -ne 0) {
        Fail "missing service skip returned $code"
    }

    Reset-Hooks
    $script:PayloadBytes = $oneStep.Bytes
    $code = Invoke-ApplyActionAction -Action 'Uninstall' -PinVersion ('sample:' + $oneStep.Sha) -ActionBaseUrl $plainBase -MarkerRoot $markerRoot
    if ($code -ne 1 -or $script:DownloadCount -ne 1 -or $script:RegistryWrites.Count -ne 0) {
        Fail "uninstall without undo returned $code"
    }
    if (Test-Path -LiteralPath (Join-Path $markerRoot 'marker.txt')) {
        Fail 'uninstall without undo wrote a marker'
    }

    Reset-Hooks
    $script:PayloadBytes = $oneStep.Bytes
    $code = Invoke-ApplyActionAction -Action 'Install' -PinVersion ('sample:' + $oneStep.Sha) -ActionBaseUrl $plainBase -MarkerRoot $markerRoot
    if ($code -ne 0 -or $script:RegistryWrites.Count -ne 1) {
        Fail "install returned $code writes=$($script:RegistryWrites.Count)"
    }
    $expectedMarker = 'sample ' + $oneStep.Sha + "`n"
    $markerText = [System.IO.File]::ReadAllText((Join-Path $markerRoot 'marker.txt'))
    if ($markerText -ne $expectedMarker) {
        Fail 'install marker text did not match'
    }
    if ([string]$script:RegistryWrites[0].FullPath -ne 'HKLM:\SOFTWARE\Test' -or [string]$script:RegistryWrites[0].Name -ne 'Alpha') {
        Fail 'install wrote the wrong value'
    }

    Reset-Hooks
    $script:PayloadBytes = $oneStep.Bytes
    $code = Invoke-ApplyActionAction -Action 'Repair' -PinVersion ('sample:' + $oneStep.Sha) -ActionBaseUrl $plainBase -MarkerRoot $markerRoot
    if ($code -ne 0 -or $script:RegistryWrites.Count -ne 1) {
        Fail "repair returned $code"
    }

    Reset-Hooks
    $script:PayloadBytes = $oneStep.Bytes
    $code = Invoke-ApplyActionAction -Action 'Reinstall' -PinVersion ('sample:' + $oneStep.Sha) -ActionBaseUrl $plainBase -MarkerRoot $markerRoot
    if ($code -ne 1 -or $script:DownloadCount -ne 0) {
        Fail "reinstall returned $code downloads=$($script:DownloadCount)"
    }

    Reset-Hooks
    $script:PayloadBytes = $withUndo.Bytes
    $code = Invoke-ApplyActionAction -Action 'Uninstall' -PinVersion ('sample:' + $withUndo.Sha) -ActionBaseUrl $plainBase -MarkerRoot $markerRoot
    if ($code -ne 0 -or $script:RegistryWrites.Count -ne 1 -or [string]$script:RegistryWrites[0].Operation -ne 'remove-value') {
        Fail "undo returned $code"
    }
    if (Test-Path -LiteralPath (Join-Path $markerRoot 'marker.txt')) {
        Fail 'undo left the marker in place'
    }

    $release = Get-Content -LiteralPath $releasePath -Raw | ConvertFrom-Json
    if ($ActionBaseUrl -ne [string]$release.actionBaseUrl) {
        Fail 'script base URL does not match the release file'
    }
    if (@($release.PSObject.Properties.Name) -contains 'sha256') {
        Fail 'release file has a sha256'
    }

    $expected = @{
        'long-paths'                       = @(@{ Path = 'SYSTEM\CurrentControlSet\Control\FileSystem'; Name = 'LongPathsEnabled'; Value = 1 })
        'fast-startup-off'                 = @(@{ Path = 'SYSTEM\CurrentControlSet\Control\Session Manager\Power'; Name = 'HiberbootEnabled'; Value = 0 })
        'edge-startup-boost-off'           = @(@{ Path = 'SOFTWARE\Policies\Microsoft\Edge'; Name = 'StartupBoostEnabled'; Value = 0 })
        'cloud-kerberos-ticket'            = @(@{ Path = 'Software\Microsoft\Windows\CurrentVersion\Policies\System\Kerberos\Parameters'; Name = 'CloudKerberosTicketRetrievalEnabled'; Value = 1 })
        'teams-avd-media'                  = @(@{ Path = 'SOFTWARE\Microsoft\Teams'; Name = 'IsWVDEnvironment'; Value = 1 })
        'fslogix-cleanup-invalid-sessions' = @(@{ Path = 'SOFTWARE\FSLogix\Apps'; Name = 'CleanupInvalidSessions'; Value = 1 })
        'fslogix-no-roam-recycle-bin'      = @(@{ Path = 'SOFTWARE\FSLogix\Apps'; Name = 'RoamRecycleBin'; Value = 0 })
        'azure-ad-sso-zone'                = @(@{ Path = 'Software\Microsoft\Windows\CurrentVersion\Internet Settings\ZoneMap\Domains\microsoftazuread-sso.com\autologon'; Name = 'https'; Value = 1 })
        'onedrive-dehydrate-team-sites'    = @(@{ Path = 'SOFTWARE\Policies\Microsoft\OneDrive'; Name = 'DehydrateSyncedTeamSites'; Value = 1 })
        'mapped-drive-reconnect'           = @(@{ Path = 'SYSTEM\CurrentControlSet\Control\NetworkProvider'; Name = 'RestoreConnection'; Value = 1 })
        'avd-logon-timeouts'               = @(
            @{ Path = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer'; Name = 'AppReadinessPreShellTimeoutMs'; Value = 30000 },
            @{ Path = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'; Name = 'FirstLogonTimeout'; Value = 30 },
            @{ Path = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'; Name = 'DelayedDesktopSwitchTimeout'; Value = 30 },
            @{ Path = 'SOFTWARE\FSLogix\Apps'; Name = 'CleanupInvalidSessions'; Value = 1 }
        )
    }

    $files = @(Get-ChildItem -LiteralPath $actionRoot -Filter '*.json' | Sort-Object -Property Name)
    if ($files.Count -ne 11) {
        Fail "catalog has $($files.Count) files"
    }
    foreach ($file in $files) {
        $id = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
        if (-not $expected.ContainsKey($id)) {
            Fail "unexpected catalog file $($file.Name)"
        }
        $rawBytes = [System.IO.File]::ReadAllBytes($file.FullName)
        if ($rawBytes.Length -ge 3 -and $rawBytes[0] -eq 239 -and $rawBytes[1] -eq 187 -and $rawBytes[2] -eq 191) {
            Fail "$id has a BOM"
        }
        $doc = [System.IO.File]::ReadAllText($file.FullName) | ConvertFrom-Json
        if ([int64]$doc.schema -ne 1 -or [string]$doc.id -cne $id) {
            Fail "$id schema or id does not match the file name"
        }
        if ([string]::IsNullOrWhiteSpace([string]$doc.title) -or [string]::IsNullOrWhiteSpace([string]$doc.description)) {
            Fail "$id is missing a title or description"
        }
        $steps = @($doc.steps)
        $want = @($expected[$id])
        if ($steps.Count -ne $want.Count) {
            Fail "$id has $($steps.Count) steps"
        }
        for ($i = 0; $i -lt $steps.Count; $i++) {
            $step = $steps[$i]
            if ([string]$step.kind -ne 'registry' -or [string]$step.op -ne 'set' -or [string]$step.hive -cne 'HKLM') {
                Fail "$id step $i is not an HKLM registry set"
            }
            if ([string]$step.type -ne 'dword' -or $step.value -is [string]) {
                Fail "$id step $i is not a numeric dword"
            }
            if ([string]$step.path -cne [string]$want[$i].Path -or [string]$step.name -cne [string]$want[$i].Name -or [int64]$step.value -ne [int64]$want[$i].Value) {
                Fail "$id step $i value does not match"
            }
        }
        $problem = Test-ApplyActionDocument -Document $doc -ExpectedId $id
        if (-not [string]::IsNullOrWhiteSpace($problem)) {
            Fail "$id failed validation: $problem"
        }

        Reset-Hooks
        $payload = $rawBytes
        $fileSha = Get-Sha $payload
        $script:DownloadFile = {
            param($Url, $Destination)
            $script:DownloadCount++
            [System.IO.File]::WriteAllBytes($Destination, $payload)
        }.GetNewClosure()
        $code = Invoke-ApplyActionAction -Action 'Install' -PinVersion ($id + ':' + $fileSha) -ActionBaseUrl $plainBase -MarkerRoot $markerRoot
        if ($code -ne 0 -or $script:RegistryWrites.Count -ne $steps.Count) {
            Fail "$id apply returned $code writes=$($script:RegistryWrites.Count)"
        }
    }
} finally {
    Remove-Item -LiteralPath 'Env:RELIAN_DEPLOY_CANCEL' -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $root) {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Output 'apply-action tests passed'
exit 0
