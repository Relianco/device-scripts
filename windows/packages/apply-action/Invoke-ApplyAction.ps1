# Script parameters are not Mandatory: a mandatory param block prompts when this
# file is dot-sourced under RELIAN_DEPLOY_TEST. The runner passes DeploymentType,
# Action, and PinVersion. PinVersion is <id>:<64 lowercase hex>. The hash is of
# windows/actions/<id>.json. ActionBaseUrl and MarkerRoot are optional.
[CmdletBinding()]
param(
    [ValidateSet('Install', 'Uninstall', 'Repair')]
    [string]$DeploymentType,

    [ValidateSet('Install', 'Update', 'Repair', 'Reinstall', 'Uninstall')]
    [string]$Action,

    [string]$PinVersion,

    [string]$MarkerRoot,

    [string]$ActionBaseUrl = 'https://raw.githubusercontent.com/Relianco/device-scripts/main/windows/actions',

    [string]$CancelPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:ApplyActionErrorLog = [System.Collections.Generic.List[string]]::new()

function Add-ApplyActionError {
    param([string]$Message)
    if ($null -eq $script:ApplyActionErrorLog) {
        $script:ApplyActionErrorLog = [System.Collections.Generic.List[string]]::new()
    }
    $script:ApplyActionErrorLog.Add($Message)
    if ($env:RELIAN_DEPLOY_TEST -ne '1') {
        [Console]::Error.WriteLine($Message)
    }
}

function Test-ApplyActionUrlHasUserInfo {
    param([string]$Url)
    try {
        $uri = [Uri]$Url
        if (-not $uri.IsAbsoluteUri) {
            return $false
        }
        return -not [string]::IsNullOrEmpty($uri.UserInfo)
    } catch {
        return $false
    }
}

function Test-ApplyActionCancelled {
    param([string]$CancelPath)
    if ($env:RELIAN_DEPLOY_CANCEL -eq '1') {
        return $true
    }
    if ([string]::IsNullOrWhiteSpace($CancelPath)) {
        return $false
    }
    return [bool](Test-Path -LiteralPath $CancelPath)
}

function Get-ApplyActionHttpStatus {
    param($Exception)
    $current = $Exception
    $guard = 0
    while ($null -ne $current -and $guard -lt 8) {
        $guard++
        $code = $null
        $names = @($current.PSObject.Properties.Name)
        if ($names -contains 'StatusCode' -and $null -ne $current.StatusCode) {
            try {
                $parsed = [int]$current.StatusCode
                if ($parsed -ge 100 -and $parsed -le 599) {
                    $code = $parsed
                }
            } catch {
                $code = $null
            }
        }
        if ($null -eq $code -and $names -contains 'Response' -and $null -ne $current.Response) {
            $response = $current.Response
            $responseNames = @($response.PSObject.Properties.Name)
            if ($responseNames -contains 'StatusCode' -and $null -ne $response.StatusCode) {
                try {
                    $parsed = [int]$response.StatusCode
                    if ($parsed -ge 100 -and $parsed -le 599) {
                        $code = $parsed
                    }
                } catch {
                    $code = $null
                }
            }
        }
        if ($null -ne $code) {
            return $code
        }
        $current = $current.InnerException
    }
    return $null
}

function Test-ApplyActionSocketIsTransient {
    param($Exception)
    if ($Exception -isnot [System.Net.Sockets.SocketException]) {
        return $false
    }
    # Timeout, connection, and DNS only. AddressAlreadyInUse is not retried.
    $code = $Exception.SocketErrorCode
    $retry = @(
        [System.Net.Sockets.SocketError]::TimedOut,
        [System.Net.Sockets.SocketError]::ConnectionReset,
        [System.Net.Sockets.SocketError]::ConnectionAborted,
        [System.Net.Sockets.SocketError]::ConnectionRefused,
        [System.Net.Sockets.SocketError]::HostNotFound
    )
    return $retry -contains $code
}

function Test-ApplyActionTransientTransport {
    param($Exception)
    $webTransient = @(
        'Timeout', 'NameResolutionFailure', 'ProxyNameResolutionFailure', 'ConnectFailure',
        'ReceiveFailure', 'SendFailure', 'PipelineFailure', 'ConnectionClosed', 'KeepAliveFailure'
    )
    # SecureConnectionError is a connection failure and stays retryable.
    $requestTransient = @('NameResolutionError', 'ConnectionError', 'SecureConnectionError', 'ResponseEnded')
    $current = $Exception
    $guard = 0
    while ($null -ne $current -and $guard -lt 8) {
        $guard++
        # A bare TaskCanceledException is not a timeout. Retry only when a TimeoutException is inside it.
        if ($current -is [System.TimeoutException] -or (Test-ApplyActionSocketIsTransient -Exception $current)) {
            return $true
        }
        if ($current -is [System.Net.WebException] -and $webTransient -contains [string]$current.Status) {
            return $true
        }
        $names = @($current.PSObject.Properties.Name)
        if ($names -contains 'HttpRequestError' -and $null -ne $current.HttpRequestError -and $requestTransient -contains [string]$current.HttpRequestError) {
            return $true
        }
        $current = $current.InnerException
    }
    return $false
}

function Test-ApplyActionDownloadIsTransient {
    param($ErrorRecord)
    $exception = $null
    if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) {
        $exception = $ErrorRecord.Exception
    } elseif ($ErrorRecord -is [System.Exception]) {
        $exception = $ErrorRecord
    }
    if ($null -eq $exception) {
        return $false
    }
    $status = Get-ApplyActionHttpStatus -Exception $exception
    if ($null -ne $status) {
        return @(408, 429, 500, 502, 503, 504) -contains $status
    }
    return [bool](Test-ApplyActionTransientTransport -Exception $exception)
}

function Test-ApplyActionPinHash {
    param([string]$Sha256)
    $text = $Sha256.Trim()
    # -cnotmatch is case-sensitive, so uppercase hex is not a pin.
    if ($text -cnotmatch '^[0-9a-f]{64}$') {
        return $false
    }
    # 64 identical nibbles, including 64 zeros or 64 a's, is a placeholder.
    if ($text -cnotmatch '^(.)\1{63}$') {
        return $true
    }
    return $false
}

function Save-ApplyActionPayload {
    param(
        [string]$Url,
        [string]$Destination,
        [string]$Sha256,
        [string]$Label,
        [string]$CancelPath
    )

    # An empty hash downloads nothing, even when the URL contains userinfo.
    # A non-empty hash still refuses userinfo before any download.
    if ([string]::IsNullOrWhiteSpace($Sha256)) {
        return 0
    }
    if (Test-ApplyActionUrlHasUserInfo -Url $Url) {
        Add-ApplyActionError -Message "refusing a URL that contains userinfo for $Label"
        return 1
    }
    if (-not (Test-ApplyActionPinHash -Sha256 $Sha256)) {
        Add-ApplyActionError -Message "invalid hash for $Label"
        return 1
    }

    $expected = $Sha256.Trim()
    $delays = @(5, 20)
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        if (Test-ApplyActionCancelled -CancelPath $CancelPath) {
            return 130
        }
        $thrown = $null
        try {
            [void](& $script:DownloadFile -Url $Url -Destination $Destination)
        } catch {
            $thrown = $_
        }
        $exists = Test-Path -LiteralPath $Destination
        if ($null -eq $thrown -and $exists) {
            $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $Destination).Hash.ToLowerInvariant()
            if (-not $actual.Equals($expected, [System.StringComparison]::Ordinal)) {
                Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
                Add-ApplyActionError -Message "hash mismatch for $Label"
                return 1
            }
            return 0
        }
        if ($exists) {
            Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
        }
        $status = $null
        $transient = $false
        if ($null -ne $thrown) {
            $status = Get-ApplyActionHttpStatus -Exception $thrown.Exception
            $transient = [bool](Test-ApplyActionDownloadIsTransient -ErrorRecord $thrown)
        }
        if (-not $transient -or $attempt -eq 3) {
            if ($null -ne $status) {
                Add-ApplyActionError -Message "download failed with HTTP $status for $Label"
            } elseif ($null -eq $thrown) {
                Add-ApplyActionError -Message "download wrote no file for $Label"
            } else {
                Add-ApplyActionError -Message "download failed for $Label"
            }
            return 1
        }
        if (Test-ApplyActionCancelled -CancelPath $CancelPath) {
            return 130
        }
        [void](& $script:RetryDelay -Seconds $delays[$attempt - 1])
        if (Test-ApplyActionCancelled -CancelPath $CancelPath) {
            return 130
        }
    }
    Add-ApplyActionError -Message "download failed for $Label"
    return 1
}

function Resolve-ApplyActionPin {
    param([AllowEmptyString()][string]$PinVersion)
    if ([string]::IsNullOrWhiteSpace($PinVersion)) {
        return [pscustomobject]@{ Empty = $true; Invalid = $false; Id = ''; Hash = ''; Reason = '' }
    }
    $text = $PinVersion.Trim()
    $colon = $text.IndexOf(':')
    if ($colon -lt 0) {
        return [pscustomobject]@{ Empty = $false; Invalid = $true; Id = ''; Hash = ''; Reason = 'pin is missing a colon' }
    }
    $id = $text.Substring(0, $colon)
    $hash = $text.Substring($colon + 1).Trim()
    if ([string]::IsNullOrWhiteSpace($hash)) {
        return [pscustomobject]@{ Empty = $true; Invalid = $false; Id = ''; Hash = ''; Reason = '' }
    }
    if ($id -cnotmatch '^[a-z0-9]+(-[a-z0-9]+)*$') {
        return [pscustomobject]@{ Empty = $false; Invalid = $true; Id = ''; Hash = ''; Reason = 'invalid action id' }
    }
    if (-not (Test-ApplyActionPinHash -Sha256 $hash)) {
        return [pscustomobject]@{ Empty = $false; Invalid = $true; Id = $id; Hash = ''; Reason = 'invalid hash' }
    }
    return [pscustomobject]@{ Empty = $false; Invalid = $false; Id = $id; Hash = $hash; Reason = '' }
}

function Get-ApplyActionUrl {
    param(
        [string]$BaseUrl,
        [string]$Id
    )
    $base = $BaseUrl.TrimEnd('/')
    return ($base + '/' + $Id + '.json')
}

function Get-ApplyActionMarkerPath {
    param([string]$Root)
    return Join-Path $Root 'marker.txt'
}

function Write-ApplyActionMarker {
    param(
        [string]$Root,
        [string]$Id,
        [string]$Hash
    )
    if (-not (Test-Path -LiteralPath $Root)) {
        New-Item -ItemType Directory -Path $Root -Force | Out-Null
    }
    $path = Get-ApplyActionMarkerPath -Root $Root
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($path, ($Id + ' ' + $Hash + "`n"), $utf8)
}

function Remove-ApplyActionMarker {
    param([string]$Root)
    if ([string]::IsNullOrWhiteSpace($Root)) {
        return
    }
    $path = Get-ApplyActionMarkerPath -Root $Root
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force
    }
}

function Get-ApplyActionDefaultMarkerRoot {
    $programData = $env:ProgramData
    if ([string]::IsNullOrWhiteSpace($programData)) {
        $programData = [Environment]::GetFolderPath('CommonApplicationData')
    }
    if ([string]::IsNullOrWhiteSpace($programData)) {
        $programData = [System.IO.Path]::GetTempPath()
    }
    return Join-Path $programData 'Relian\apply-action'
}

function Test-ApplyActionHasProperty {
    param(
        $Object,
        [string]$Name
    )
    if ($null -eq $Object) {
        return $false
    }
    return @($Object.PSObject.Properties.Name) -contains $Name
}

function Test-ApplyActionRegistryPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }
    if ($Path.Contains('/') -or $Path.Contains(':')) {
        return $false
    }
    $segments = @($Path.Split('\'))
    if ($segments.Count -eq 0) {
        return $false
    }
    foreach ($segment in $segments) {
        if ([string]::IsNullOrWhiteSpace($segment) -or $segment -eq '.' -or $segment -eq '..') {
            return $false
        }
    }
    $first = [string]$segments[0]
    if ($first -cmatch '^(HKLM|HKCU|HKU|HKCR|HKEY_)') {
        return $false
    }
    return $true
}

function Test-ApplyActionInteger {
    param(
        $Value,
        [uint64]$Maximum
    )
    if ($null -eq $Value -or $Value -is [string] -or $Value -is [bool] -or $Value -is [double] -or $Value -is [float] -or $Value -is [decimal]) {
        return $false
    }
    $whole = $Value -is [byte] -or $Value -is [int16] -or $Value -is [int] -or $Value -is [long] -or $Value -is [uint16] -or $Value -is [uint32] -or $Value -is [uint64]
    if (-not $whole) {
        return $false
    }
    if ($Value -lt 0) {
        return $false
    }
    return ([uint64]$Value) -le $Maximum
}

function Test-ApplyActionStep {
    param($Step)
    if (-not (Test-ApplyActionHasProperty -Object $Step -Name 'kind')) {
        return 'step is missing a kind'
    }
    $kind = [string]$Step.kind
    if ($kind -eq 'registry') {
        if (-not (Test-ApplyActionHasProperty -Object $Step -Name 'op')) {
            return 'registry step is missing an op'
        }
        $op = [string]$Step.op
        if ($op -ne 'set' -and $op -ne 'remove-value') {
            return 'registry op is not set or remove-value'
        }
        if (-not (Test-ApplyActionHasProperty -Object $Step -Name 'hive') -or [string]$Step.hive -cne 'HKLM') {
            return 'registry hive must be HKLM'
        }
        if (-not (Test-ApplyActionHasProperty -Object $Step -Name 'path') -or -not (Test-ApplyActionRegistryPath -Path ([string]$Step.path))) {
            return 'registry path is not allowed'
        }
        if (-not (Test-ApplyActionHasProperty -Object $Step -Name 'name') -or [string]::IsNullOrWhiteSpace([string]$Step.name) -or ([string]$Step.name).Contains('\')) {
            return 'registry value name is not allowed'
        }
        if ($op -eq 'remove-value') {
            return $null
        }
        if (-not (Test-ApplyActionHasProperty -Object $Step -Name 'type')) {
            return 'registry step is missing a type'
        }
        $type = [string]$Step.type
        $allowed = @('dword', 'qword', 'sz', 'expand-sz', 'multi-sz')
        if ($allowed -notcontains $type) {
            return 'registry type is not allowed'
        }
        if (-not (Test-ApplyActionHasProperty -Object $Step -Name 'value')) {
            return 'registry step is missing a value'
        }
        if ($type -eq 'dword' -or $type -eq 'qword') {
            $maximum = [uint64]4294967295
            if ($type -eq 'qword') {
                $maximum = [uint64]::MaxValue
            }
            if (-not (Test-ApplyActionInteger -Value $Step.value -Maximum $maximum)) {
                return 'registry number is not an integer in range'
            }
            return $null
        }
        if ($type -eq 'sz' -or $type -eq 'expand-sz') {
            if ($Step.value -isnot [string]) {
                return 'registry string value is not a string'
            }
            return $null
        }
        if ($Step.value -is [string]) {
            return 'multi-sz value must be an array'
        }
        foreach ($item in @($Step.value)) {
            if ($item -isnot [string]) {
                return 'multi-sz value must be strings'
            }
        }
        return $null
    }
    if ($kind -eq 'service') {
        if (-not (Test-ApplyActionHasProperty -Object $Step -Name 'name') -or [string]$Step.name -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$') {
            return 'service name is not allowed'
        }
        $startup = ''
        $state = ''
        if (Test-ApplyActionHasProperty -Object $Step -Name 'startup') {
            $startup = [string]$Step.startup
        }
        if (Test-ApplyActionHasProperty -Object $Step -Name 'state') {
            $state = [string]$Step.state
        }
        if ([string]::IsNullOrWhiteSpace($startup) -and [string]::IsNullOrWhiteSpace($state)) {
            return 'service step needs a startup or a state'
        }
        if (-not [string]::IsNullOrWhiteSpace($startup) -and @('automatic', 'manual', 'disabled') -notcontains $startup) {
            return 'service startup is not allowed'
        }
        if (-not [string]::IsNullOrWhiteSpace($state) -and @('running', 'stopped') -notcontains $state) {
            return 'service state is not allowed'
        }
        if (Test-ApplyActionHasProperty -Object $Step -Name 'missing') {
            $missing = [string]$Step.missing
            if ($missing -ne 'fail' -and $missing -ne 'skip') {
                return 'service missing policy is not allowed'
            }
        }
        return $null
    }
    return 'unknown kind'
}

function Test-ApplyActionDocument {
    param(
        $Document,
        [string]$ExpectedId
    )
    if ($null -eq $Document) {
        return 'document is empty'
    }
    if (-not (Test-ApplyActionHasProperty -Object $Document -Name 'schema') -or -not (Test-ApplyActionInteger -Value $Document.schema -Maximum 1) -or [int64]$Document.schema -ne 1) {
        return 'schema is not 1'
    }
    if (-not (Test-ApplyActionHasProperty -Object $Document -Name 'id') -or [string]$Document.id -cne $ExpectedId) {
        return 'action id does not match the pin'
    }
    if (-not (Test-ApplyActionHasProperty -Object $Document -Name 'title') -or [string]::IsNullOrWhiteSpace([string]$Document.title) -or $Document.title -isnot [string]) {
        return 'title is missing'
    }
    if (-not (Test-ApplyActionHasProperty -Object $Document -Name 'description') -or [string]::IsNullOrWhiteSpace([string]$Document.description) -or $Document.description -isnot [string]) {
        return 'description is missing'
    }
    if (-not (Test-ApplyActionHasProperty -Object $Document -Name 'steps')) {
        return 'steps are missing'
    }
    $steps = @($Document.steps)
    if ($steps.Count -lt 1) {
        return 'steps are empty'
    }
    foreach ($step in $steps) {
        $problem = Test-ApplyActionStep -Step $step
        if (-not [string]::IsNullOrWhiteSpace($problem)) {
            return $problem
        }
    }
    if (Test-ApplyActionHasProperty -Object $Document -Name 'undo') {
        $undoSteps = @($Document.undo)
        if ($undoSteps.Count -lt 1) {
            return $null
        }
        foreach ($step in $undoSteps) {
            $problem = Test-ApplyActionStep -Step $step
            if (-not [string]::IsNullOrWhiteSpace($problem)) {
                return $problem
            }
        }
    }
    return $null
}

function Test-ApplyActionRegistryValueAbsent {
    param($ErrorRecord)
    if ($ErrorRecord -isnot [System.Management.Automation.ErrorRecord]) {
        return $false
    }
    if ($ErrorRecord.CategoryInfo.Category -eq [System.Management.Automation.ErrorCategory]::ObjectNotFound) {
        return $true
    }
    $exception = $ErrorRecord.Exception
    if ($exception -is [System.Management.Automation.ItemNotFoundException]) {
        return $true
    }
    # Windows Remove-ItemProperty: PSArgumentException, "Property <name> does not exist at path <path>."
    if ($exception -is [System.ArgumentException] -and [regex]::IsMatch([string]$exception.Message, '^Property .+ does not exist')) {
        return $true
    }
    return $false
}

function Write-ApplyActionRegistryReal {
    param(
        [string]$Operation,
        [string]$FullPath,
        [string]$Name,
        [string]$Type,
        $Value
    )
    if ($Operation -eq 'remove-value') {
        if (-not (Test-Path -LiteralPath $FullPath)) {
            return 0
        }
        # An already-absent value is success. Access denied and other failures are not.
        try {
            Remove-ItemProperty -LiteralPath $FullPath -Name $Name -ErrorAction Stop
        } catch {
            if (Test-ApplyActionRegistryValueAbsent -ErrorRecord $_) {
                return 0
            }
            return 1
        }
        return 0
    }
    if (-not (Test-Path -LiteralPath $FullPath)) {
        New-Item -Path $FullPath -Force | Out-Null
    }
    $propertyType = switch ($Type) {
        'dword' { 'DWord' }
        'qword' { 'QWord' }
        'sz' { 'String' }
        'expand-sz' { 'ExpandString' }
        'multi-sz' { 'MultiString' }
        default { '' }
    }
    if ([string]::IsNullOrWhiteSpace($propertyType)) {
        return 1
    }
    New-ItemProperty -LiteralPath $FullPath -Name $Name -Value $Value -PropertyType $propertyType -Force | Out-Null
    return 0
}

function Invoke-ApplyActionStep {
    param($Step)
    $kind = [string]$Step.kind
    if ($kind -eq 'registry') {
        $relative = ([string]$Step.path).Trim('\')
        $full = 'HKLM:\' + $relative
        $type = ''
        $value = $null
        if ([string]$Step.op -eq 'set') {
            $type = [string]$Step.type
            $value = $Step.value
        }
        try {
            $result = & $script:WriteRegistry -Operation ([string]$Step.op) -FullPath $full -Name ([string]$Step.name) -Type $type -Value $value
        } catch {
            Add-ApplyActionError -Message 'registry write failed'
            return 1
        }
        if ($null -ne $result -and [int]$result -ne 0) {
            Add-ApplyActionError -Message 'registry write failed'
            return 1
        }
        return 0
    }
    if ($kind -eq 'service') {
        $name = [string]$Step.name
        $present = $false
        try {
            $present = [bool](& $script:TestServicePresent -Name $name)
        } catch {
            Add-ApplyActionError -Message 'service lookup failed'
            return 1
        }
        $missing = 'fail'
        if (Test-ApplyActionHasProperty -Object $Step -Name 'missing') {
            if (-not [string]::IsNullOrWhiteSpace([string]$Step.missing)) {
                $missing = [string]$Step.missing
            }
        }
        if (-not $present) {
            if ($missing -eq 'skip') {
                return 0
            }
            Add-ApplyActionError -Message 'service is not installed'
            return 1
        }
        $startup = ''
        $state = ''
        if (Test-ApplyActionHasProperty -Object $Step -Name 'startup') {
            $startup = [string]$Step.startup
        }
        if (Test-ApplyActionHasProperty -Object $Step -Name 'state') {
            $state = [string]$Step.state
        }
        try {
            $result = & $script:ConfigureService -Name $name -Startup $startup -State $state
        } catch {
            Add-ApplyActionError -Message 'service change failed'
            return 1
        }
        if ($null -ne $result -and [int]$result -ne 0) {
            Add-ApplyActionError -Message 'service change failed'
            return 1
        }
        return 0
    }
    Add-ApplyActionError -Message 'unknown kind'
    return 1
}

function Get-ApplyActionUndoPath {
    param([string]$Root)
    return (Join-Path $Root 'undo.json')
}

function Remove-ApplyActionUndo {
    param([string]$Root)
    if ([string]::IsNullOrWhiteSpace($Root)) {
        return
    }
    $path = Get-ApplyActionUndoPath -Root $Root
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force
    }
}

# Windows PowerShell 5.1 ConvertTo-Json unwraps a one-element array.
# Undo files keep "undo" as an array on 5.1 and on pwsh.
function ConvertTo-ApplyActionJson {
    param($Value)

    if ($null -eq $Value) {
        return 'null'
    }
    $scalar = $Value -is [string] -or $Value -is [bool] -or $Value -is [byte] -or $Value -is [int16] -or $Value -is [int] -or $Value -is [long] -or $Value -is [uint16] -or $Value -is [uint32] -or $Value -is [uint64] -or $Value -is [decimal] -or $Value -is [double] -or $Value -is [float]
    if ($scalar) {
        return (ConvertTo-Json -InputObject $Value -Compress)
    }
    if ($Value -is [System.Collections.IList]) {
        $parts = [System.Collections.Generic.List[string]]::new()
        foreach ($item in $Value) {
            [void]$parts.Add((ConvertTo-ApplyActionJson -Value $item))
        }
        return ('[' + ($parts.ToArray() -join ',') + ']')
    }
    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($prop in @($Value.PSObject.Properties)) {
        $name = ConvertTo-Json -InputObject ([string]$prop.Name) -Compress
        [void]$parts.Add($name + ':' + (ConvertTo-ApplyActionJson -Value $prop.Value))
    }
    return ('{' + ($parts.ToArray() -join ',') + '}')
}

function Write-ApplyActionUndo {
    param(
        [string]$Root,
        [string]$Id,
        [string]$Hash,
        $Steps
    )
    if (-not (Test-Path -LiteralPath $Root)) {
        New-Item -ItemType Directory -Path $Root -Force | Out-Null
    }
    # A generic list stays one object, so a single step is not unwrapped.
    $undo = [System.Collections.Generic.List[object]]::new()
    foreach ($step in @($Steps)) {
        if ($null -ne $step) {
            [void]$undo.Add($step)
        }
    }
    $record = [pscustomobject]@{
        id   = $Id
        hash = $Hash
        undo = $undo
    }
    $path = Get-ApplyActionUndoPath -Root $Root
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($path, (ConvertTo-ApplyActionJson -Value $record), $utf8)
}

function Test-ApplyActionDocumentHasUndo {
    param($Document)
    if (-not (Test-ApplyActionHasProperty -Object $Document -Name 'undo')) {
        return $false
    }
    if ($null -eq $Document.undo) {
        return $false
    }
    return @($Document.undo).Count -gt 0
}

function Test-ApplyActionUndoRecord {
    param(
        $Record,
        [string]$Id,
        [string]$Hash
    )
    if ($null -eq $Record -or $Record -is [System.Array]) {
        return $false
    }
    if (-not (Test-ApplyActionHasProperty -Object $Record -Name 'id')) {
        return $false
    }
    if (-not (Test-ApplyActionHasProperty -Object $Record -Name 'hash')) {
        return $false
    }
    if (-not (Test-ApplyActionHasProperty -Object $Record -Name 'undo')) {
        return $false
    }
    if ([string]$Record.id -cne $Id -or [string]$Record.hash -cne $Hash) {
        return $false
    }
    if ($null -eq $Record.undo) {
        return $false
    }
    return $true
}

function Invoke-ApplyActionUninstall {
    param(
        [string]$Id,
        [string]$Hash,
        [string]$MarkerRoot,
        [string]$CancelPath
    )
    # Retained at install time. No URL is built and nothing is downloaded.
    if ([string]::IsNullOrWhiteSpace($MarkerRoot)) {
        $MarkerRoot = Get-ApplyActionDefaultMarkerRoot
    }
    $undoPath = Get-ApplyActionUndoPath -Root $MarkerRoot
    $record = $null
    $readable = $false
    if (Test-Path -LiteralPath $undoPath) {
        try {
            $raw = [System.IO.File]::ReadAllText($undoPath)
            $record = $raw | ConvertFrom-Json
            $readable = $true
        } catch {
            $readable = $false
        }
    }
    if (-not $readable -or -not (Test-ApplyActionUndoRecord -Record $record -Id $Id -Hash $Hash)) {
        Add-ApplyActionError -Message 'uninstall has no undo'
        return 1
    }
    # 5.1 ConvertFrom-Json turns a one-element array into one object.
    $steps = [System.Collections.Generic.List[object]]::new()
    foreach ($step in @($record.undo)) {
        [void]$steps.Add($step)
    }
    foreach ($step in $steps) {
        $problem = Test-ApplyActionStep -Step $step
        if (-not [string]::IsNullOrWhiteSpace($problem)) {
            Add-ApplyActionError -Message $problem
            return 1
        }
    }
    foreach ($step in $steps) {
        if (Test-ApplyActionCancelled -CancelPath $CancelPath) {
            return 130
        }
        $stepCode = [int](Invoke-ApplyActionStep -Step $step)
        if ($stepCode -ne 0) {
            return 1
        }
    }
    Remove-ApplyActionMarker -Root $MarkerRoot
    Remove-ApplyActionUndo -Root $MarkerRoot
    return 0
}

function Invoke-ApplyActionAction {
    param(
        [string]$DeploymentType,
        [AllowEmptyString()][string]$Action,
        [AllowEmptyString()][string]$PinVersion,
        [string]$ActionBaseUrl,
        [string]$MarkerRoot,
        [string]$CancelPath
    )

    # Empty hash exits before a URL is built, for every action.
    $pin = Resolve-ApplyActionPin -PinVersion $PinVersion
    if ($pin.Empty) {
        return 0
    }
    if ($pin.Invalid) {
        Add-ApplyActionError -Message $pin.Reason
        return 1
    }

    $known = @('Install', 'Update', 'Repair', 'Reinstall', 'Uninstall')
    if ([string]::IsNullOrWhiteSpace($Action) -or $known -notcontains $Action) {
        Add-ApplyActionError -Message 'missing or unknown action'
        return 1
    }
    # The runner sends Uninstall and then Install. This package does not.
    if ($Action -eq 'Reinstall') {
        Add-ApplyActionError -Message 'reinstall is split by the runner'
        return 1
    }
    # Uninstall runs before the URL is built. A userinfo URL does not block it.
    if ($Action -eq 'Uninstall') {
        return [int](Invoke-ApplyActionUninstall -Id $pin.Id -Hash $pin.Hash -MarkerRoot $MarkerRoot -CancelPath $CancelPath)
    }

    if ([string]::IsNullOrWhiteSpace($ActionBaseUrl)) {
        $ActionBaseUrl = 'https://raw.githubusercontent.com/Relianco/device-scripts/main/windows/actions'
    }
    $url = Get-ApplyActionUrl -BaseUrl $ActionBaseUrl -Id $pin.Id
    $destination = Join-Path ([System.IO.Path]::GetTempPath()) ('apply-action-' + [guid]::NewGuid().ToString('n') + '.json')
    try {
        $downloaded = [int](Save-ApplyActionPayload -Url $url -Destination $destination -Sha256 $pin.Hash -Label 'action' -CancelPath $CancelPath)
        if ($downloaded -ne 0) {
            return $downloaded
        }
        $raw = [System.IO.File]::ReadAllText($destination)
        try {
            $document = $raw | ConvertFrom-Json
        } catch {
            Add-ApplyActionError -Message 'action file is not JSON'
            return 1
        }
        $problem = Test-ApplyActionDocument -Document $document -ExpectedId $pin.Id
        if (-not [string]::IsNullOrWhiteSpace($problem)) {
            Add-ApplyActionError -Message $problem
            return 1
        }

        if ([string]::IsNullOrWhiteSpace($MarkerRoot)) {
            $MarkerRoot = Get-ApplyActionDefaultMarkerRoot
        }
        foreach ($step in @($document.steps)) {
            if (Test-ApplyActionCancelled -CancelPath $CancelPath) {
                return 130
            }
            $stepCode = [int](Invoke-ApplyActionStep -Step $step)
            if ($stepCode -ne 0) {
                return 1
            }
        }
        Write-ApplyActionMarker -Root $MarkerRoot -Id $pin.Id -Hash $pin.Hash
        if (Test-ApplyActionDocumentHasUndo -Document $document) {
            Write-ApplyActionUndo -Root $MarkerRoot -Id $pin.Id -Hash $pin.Hash -Steps $document.undo
        } else {
            Remove-ApplyActionUndo -Root $MarkerRoot
        }
        return 0
    } finally {
        if (Test-Path -LiteralPath $destination) {
            Remove-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue
        }
    }
}

$script:DownloadFile = {
    param($Url, $Destination)
    $parent = Split-Path -Parent $Destination
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing
}

$script:RetryDelay = {
    param($Seconds)
    Start-Sleep -Seconds ([int]$Seconds)
}

$script:WriteRegistry = {
    param($Operation, $FullPath, $Name, $Type, $Value)
    return (Write-ApplyActionRegistryReal -Operation $Operation -FullPath $FullPath -Name $Name -Type $Type -Value $Value)
}

$script:TestServicePresent = {
    param($Name)
    return $null -ne (Get-Service -Name $Name -ErrorAction SilentlyContinue)
}

$script:ConfigureService = {
    param($Name, $Startup, $State)
    if (-not [string]::IsNullOrWhiteSpace($Startup)) {
        $startupType = switch ($Startup) {
            'automatic' { 'Automatic' }
            'manual' { 'Manual' }
            'disabled' { 'Disabled' }
            default { '' }
        }
        if ([string]::IsNullOrWhiteSpace($startupType)) {
            return 1
        }
        Set-Service -Name $Name -StartupType $startupType
    }
    if ($State -eq 'running') {
        Start-Service -Name $Name
    } elseif ($State -eq 'stopped') {
        Stop-Service -Name $Name -Force
    }
    return 0
}

if ($env:RELIAN_DEPLOY_TEST -eq '1' -and $MyInvocation.InvocationName -eq '.') {
    return
}

# An empty hash is a no-op before parameter validation. The URL is not built.
$earlyPin = Resolve-ApplyActionPin -PinVersion ([string]$PinVersion)
if ($earlyPin.Empty) {
    exit 0
}

foreach ($name in @('DeploymentType', 'Action', 'PinVersion')) {
    if (-not $PSBoundParameters.ContainsKey($name)) {
        [Console]::Error.WriteLine("missing parameter $name")
        exit 1
    }
}

try {
    $applyExit = [int](Invoke-ApplyActionAction -DeploymentType $DeploymentType -Action $Action -PinVersion $PinVersion -ActionBaseUrl $ActionBaseUrl -MarkerRoot $MarkerRoot -CancelPath $CancelPath)
    exit $applyExit
} catch {
    $detail = [string]$_.Exception.Message
    if ($detail -match '://') {
        $detail = 'apply action failed'
    }
    [Console]::Error.WriteLine($detail)
    exit 1
}
