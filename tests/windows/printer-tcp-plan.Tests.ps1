$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$scriptPath = Join-Path $repoRoot 'windows/packages/printer-tcp/Invoke-PrinterTcp.ps1'
$releasePath = Join-Path $repoRoot 'windows/releases/printer-tcp.json'

function Fail {
    param([string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) {
        $Message = 'test failed'
    }
    [Console]::Error.WriteLine("FAIL $Message")
    exit 1
}

if (-not (Test-Path -LiteralPath $scriptPath)) {
    Fail 'Invoke-PrinterTcp.ps1 does not exist'
}
if (-not (Test-Path -LiteralPath $releasePath)) {
    Fail 'windows/releases/printer-tcp.json does not exist'
}

$env:RELIAN_DEPLOY_TEST = '1'
. $scriptPath

foreach ($command in @(
        'Get-PrinterTcpPlan',
        'Invoke-PrinterTcpAction',
        'Save-PrinterTcpPayload',
        'Test-PrinterTcpDownloadIsTransient',
        'Test-PrinterTcpCatalogSignature',
        'Get-PrinterTcpChainStatusNames',
        'Test-PrinterTcpOuterSignature',
        'Get-PrinterTcpPnpUtilArgumentList',
        'Get-PrinterTcpExpandArgumentList',
        'Get-PrinterTcpSfxArgumentList',
        'Find-PrinterTcpStagedInf',
        'Get-PrinterTcpFileSha256',
        'Test-PrinterTcpSameDriverVersion',
        'Get-PrinterTcpPortSettings',
        'Find-PrinterTcpDriverInf',
        'Get-PrinterTcpModel',
        'Test-PrinterTcpQueueName',
        'Test-PrinterTcpIpv4'
    )) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        Fail "$command was not defined"
    }
}

$release = Get-Content -LiteralPath $releasePath -Raw -Encoding utf8 | ConvertFrom-Json
if ([string]$release.name -cne 'printer-tcp') {
    Fail "name '$($release.name)'"
}
$releaseDrivers = @($release.drivers)
$models = Get-PrinterTcpModels
if (@($models).Count -ne 2 -or $releaseDrivers.Count -ne 2) {
    Fail 'model catalog must contain exactly two drivers'
}
$scriptText = Get-Content -LiteralPath $scriptPath -Raw -Encoding utf8
foreach ($driver in $releaseDrivers) {
    $model = Get-PrinterTcpModel -Id ([string]$driver.id)
    if ($null -eq $model) {
        Fail "script is missing model $($driver.id)"
    }
    if ([string]$model.SourceUrl -cne [string]$driver.sourceUrl) {
        Fail "source URL for $($driver.id)"
    }
    if ([string]$model.Sha256 -cne [string]$driver.sha256) {
        Fail "sha256 for $($driver.id)"
    }
    if ([string]$model.DriverName -cne [string]$driver.driverName) {
        Fail "driver name for $($driver.id)"
    }
    if ([string]$model.File -cne [string]$driver.file) {
        Fail "file name for $($driver.id)"
    }
    if ([string]$model.Version -cne [string]$driver.version) {
        Fail "version for $($driver.id)"
    }
    if ([string]$model.Inf -cne [string]$driver.inf) {
        Fail "inf for $($driver.id)"
    }
    if ([string]$model.Catalog -cne [string]$driver.catalog) {
        Fail "catalog for $($driver.id)"
    }
    if ([string]$model.Stage -cne [string]$driver.stage) {
        Fail "stage for $($driver.id)"
    }
    if ($null -eq $driver.size) {
        Fail "size missing for $($driver.id)"
    }
    if ([int64]$model.Size -ne [int64]$driver.size) {
        Fail "size for $($driver.id)"
    }
    if (-not $scriptText.Contains([string]$driver.sha256)) {
        Fail "sha256 for $($driver.id) is not inlined"
    }
    if (-not $scriptText.Contains([string]$driver.sourceUrl)) {
        Fail "source URL for $($driver.id) is not inlined"
    }
}

$brother = Get-PrinterTcpModel -Id 'BrotherHlL2370Dw'
$konica = Get-PrinterTcpModel -Id 'KonicaUniversalPcl'
if ($null -eq $brother -or $null -eq $konica) {
    Fail 'known model was missing'
}
if ($brother.DriverName -cne 'Brother HL-L2370DW series') {
    Fail 'Brother driver name dropped series'
}
if ($konica.DriverName -cne 'KONICA MINOLTA Universal PCL') {
    Fail 'Konica driver name is not the unversioned name'
}
if ($brother.Stage -cne 'Cab' -or $konica.Stage -cne 'SevenZipSfx') {
    Fail 'stage does not match the pin'
}
if (-not [string]::IsNullOrEmpty([string]$brother.Referer)) {
    Fail 'Brother set a Referer'
}
$konicaReferer = 'https://onyxweb.mykonicaminolta.com/OneStopProductSupport?appMode=Public&target=Drivers'
if ([string]$konica.Referer -cne $konicaReferer) {
    Fail 'Konica Referer does not match the support page'
}
if ($null -ne (Get-PrinterTcpModel -Id 'BrotherHlL2370DwExtra')) {
    Fail 'unknown model id was accepted'
}
if ($null -ne (Get-PrinterTcpModel -Id 'brotherhll2370dw')) {
    Fail 'model id match was not case sensitive'
}

if ($scriptText -match 'Ninja-Property-Get|Ninja-Property-Set|NinjaOne') {
    Fail 'script calls Ninja'
}
if ($scriptText -match 'Mandatory\s*=') {
    Fail 'a parameter is Mandatory'
}
if ($scriptText.ToLowerInvariant().Contains('/install')) {
    Fail 'pnputil install switch is present'
}
if ($scriptText.Contains('Remove-PrinterDriver') -or $scriptText.Contains('/delete-driver')) {
    Fail 'script removes the shared driver'
}
foreach ($banned in @('Restart-Service', 'Stop-Service', 'SetDefaultPrinter', 'net stop')) {
    if ($scriptText.Contains($banned)) {
        Fail "script contains $banned"
    }
}
if ($scriptText -match '(?i)(^|[^A-Za-z0-9])-split([^A-Za-z0-9]|$)') {
    Fail 'address parsing uses -split'
}
if ($scriptText -match '(?i)(^|[^A-Za-z])-SNMP([^A-Za-z]|$)') {
    Fail 'port creation passes -SNMP'
}
if ($scriptText -notmatch 'prnport\.vbs') {
    Fail 'snmp is not disabled with prnport.vbs'
}
if (-not $scriptText.Contains('-md')) {
    Fail 'snmp disable does not pass -md'
}
if ($scriptText.Contains('Set-CimInstance')) {
    Fail 'snmp disable writes a read-only CIM property'
}
if ($scriptText.Contains('Get-CimInstance')) {
    Fail 'snmp disable reads a printer port with CIM'
}
if ($scriptText.Contains('-me')) {
    Fail 'snmp disable passes -me'
}
$prn = @(Get-PrinterTcpPrnPortArgumentList -ScriptPath 'C:\Program Files\prnport.vbs' -PortName 'IP_192.0.2.10')
if ($prn.Count -ne 6 -or
    $prn[0] -cne '//nologo' -or
    $prn[1] -cne '"C:\Program Files\prnport.vbs"' -or
    $prn[2] -cne '-t' -or
    $prn[3] -cne '-r' -or
    $prn[4] -cne '"IP_192.0.2.10"' -or
    $prn[5] -cne '-md') {
    Fail "prnport arguments $($prn -join ' ')"
}
if (($prn -join ' ').Contains('-me')) {
    Fail 'prnport arguments enable snmp'
}
$emptyScript = Get-PrinterTcpPrnPortArgumentList -ScriptPath '' -PortName 'IP_192.0.2.10'
if ($null -ne $emptyScript) {
    Fail 'empty script path did not return null'
}
if (($emptyScript -join ' ').Contains('-me')) {
    Fail 'empty script path contains -me'
}
$emptyPort = Get-PrinterTcpPrnPortArgumentList -ScriptPath 'C:\Program Files\prnport.vbs' -PortName ''
if ($null -ne $emptyPort) {
    Fail 'empty port name did not return null'
}
if (($emptyPort -join ' ').Contains('-me')) {
    Fail 'empty port name contains -me'
}
foreach ($paramName in @('DeploymentType', 'Action', 'PinVersion', 'CancelPath', 'MarkerRoot', 'PrinterName', 'PrinterAddress', 'PrinterModel')) {
    if ($scriptText -notmatch ('\$' + $paramName + '\s*=\s*''''')) {
        Fail "missing empty default for $paramName"
    }
}
if ($script:DownloadFile.ToString() -notmatch 'Tls12') {
    Fail 'download does not set TLS 1.2'
}
if ($script:DownloadFile.ToString() -notmatch 'Referer') {
    Fail 'download does not accept a Referer'
}

$markerRootDefault = Get-PrinterTcpDefaultMarkerRoot
if ((Split-Path -Leaf $markerRootDefault) -cne 'printer-tcp') {
    Fail "marker root leaf '$markerRootDefault'"
}
if ((Split-Path -Leaf (Split-Path -Parent $markerRootDefault)) -cne 'Relian') {
    Fail "marker root parent '$markerRootDefault'"
}

if (-not (Test-PrinterTcpCatalogSignature -Status 'Valid' -Subject 'CN=Anything')) {
    Fail 'Valid catalog was rejected'
}
$whql = 'CN=Microsoft Windows Hardware Compatibility Publisher, O=Microsoft Corporation, C=US'
if (Test-PrinterTcpCatalogSignature -Status 'NotTimeValid' -Subject $whql) {
    Fail 'NotTimeValid is not a signature status'
}
if (-not (Test-PrinterTcpCatalogSignature -Status 'UnknownError' -Subject $whql -ChainStatus @('NotTimeValid'))) {
    Fail 'expired untimestamped WHQL catalog was rejected'
}
if (-not (Test-PrinterTcpCatalogSignature -Status 'NotTrusted' -Subject $whql -ChainStatus @('NotTimeValid', 'NotTimeNested'))) {
    Fail 'NotTrusted expired WHQL catalog was rejected'
}
if (Test-PrinterTcpCatalogSignature -Status 'UnknownError' -Subject 'CN=KONICA MINOLTA' -ChainStatus @('NotTimeValid')) {
    Fail 'expired catalog without the WHQL publisher was accepted'
}
if (Test-PrinterTcpCatalogSignature -Status 'UnknownError' -Subject $whql -ChainStatus @('NotTimeValid', 'UntrustedRoot')) {
    Fail 'expired WHQL catalog with another chain failure was accepted'
}
if (Test-PrinterTcpCatalogSignature -Status 'UnknownError' -Subject $whql -ChainStatus @('NotTimeValid') -HasTimestamp $true) {
    Fail 'timestamped expired catalog was accepted'
}
if (Test-PrinterTcpCatalogSignature -Status 'HashMismatch' -Subject $whql -ChainStatus @('NotTimeValid')) {
    Fail 'hash mismatch was accepted because the chain expired'
}
foreach ($status in @('NotSigned', 'HashMismatch', 'NotTrusted', 'UnknownError')) {
    if (Test-PrinterTcpCatalogSignature -Status $status -Subject $whql) {
        Fail "catalog status $status was accepted"
    }
}
if (@(Get-PrinterTcpChainStatusNames -Certificate $null).Count -ne 0) {
    Fail 'null certificate produced chain status'
}

$microsoftSubject = 'CN=Microsoft Code Signing PCA 2011, O=Microsoft Corporation, C=US'
if (-not (Test-PrinterTcpOuterSignature -ModelId 'BrotherHlL2370Dw' -Status 'Valid' -Subject $microsoftSubject)) {
    Fail 'Brother outer signature was rejected'
}
if (Test-PrinterTcpOuterSignature -ModelId 'BrotherHlL2370Dw' -Status 'Valid' -Subject 'CN=KONICA MINOLTA') {
    Fail 'Brother outer signature accepted the wrong publisher'
}
if (Test-PrinterTcpOuterSignature -ModelId 'BrotherHlL2370Dw' -Status 'NotTimeValid' -Subject $microsoftSubject) {
    Fail 'Brother outer signature accepted NotTimeValid'
}
if (-not (Test-PrinterTcpOuterSignature -ModelId 'KonicaUniversalPcl' -Status 'Valid' -Subject 'CN=KONICA MINOLTA, O=KONICA MINOLTA')) {
    Fail 'Konica outer signature was rejected'
}
if (Test-PrinterTcpOuterSignature -ModelId 'KonicaUniversalPcl' -Status 'Valid' -Subject $whql) {
    Fail 'Konica outer signature accepted the WHQL publisher'
}
if (Test-PrinterTcpOuterSignature -ModelId 'KonicaUniversalPcl' -Status 'NotTimeValid' -Subject 'CN=KONICA MINOLTA') {
    Fail 'Konica outer signature accepted NotTimeValid'
}
if (Test-PrinterTcpOuterSignature -ModelId 'KonicaUniversalPcl' -Status 'NotSigned' -Subject 'CN=KONICA MINOLTA') {
    Fail 'unsigned Konica outer file was accepted'
}

if (-not (Test-PrinterTcpQueueName -Name 'Front Desk')) {
    Fail 'Front Desk was rejected'
}
if (-not (Test-PrinterTcpQueueName -Name ('A' * 220))) {
    Fail '220 character name was rejected'
}
if (Test-PrinterTcpQueueName -Name ('A' * 221)) {
    Fail '221 character name was accepted'
}
if ((Test-PrinterTcpQueueName -Name ' Front Desk') -or (Test-PrinterTcpQueueName -Name 'Front Desk ')) {
    Fail 'untrimmed queue name was accepted'
}
foreach ($ch in @("`t", "`r", "`n", '|', '\', '/', ':', '*', '?', '"', '<', '>')) {
    if (Test-PrinterTcpQueueName -Name ('Front' + $ch + 'Desk')) {
        Fail "queue name accepted char $([int][char]$ch)"
    }
}
if (-not (Test-PrinterTcpIpv4 -Address '192.0.2.10') -or -not (Test-PrinterTcpIpv4 -Address '192.0.2.11')) {
    Fail 'documentation address was rejected'
}
foreach ($badAddress in @(
        '192.0.2.010',
        '192.0.2.011',
        '192.0.2.256',
        '192.0.2',
        '192.0.2.10.11',
        '192.0.2.10a',
        ' 192.0.2.10',
        '192.0.2.10 '
    )) {
    if (Test-PrinterTcpIpv4 -Address $badAddress) {
        Fail "address '$badAddress' was accepted"
    }
}

if (-not (Test-PrinterTcpRemovablePortName -PortName 'IP_192.0.2.10')) {
    Fail 'IP_192.0.2.10 was not removable'
}
foreach ($portName in @('IP_192.0.2.10extra', 'IP_192.0.2', 'LocalPort', 'TCP_192.0.2.10')) {
    if (Test-PrinterTcpRemovablePortName -PortName $portName) {
        Fail "port '$portName' was removable"
    }
}

$port = Get-PrinterTcpPortSettings -Address '192.0.2.10'
if ($port.Name -cne 'IP_192.0.2.10' -or $port.PrinterHostAddress -cne '192.0.2.10' -or
    [int]$port.PortNumber -ne 9100 -or [bool]$port.SnmpEnabled) {
    Fail 'port settings were not RAW 9100 with SNMP disabled'
}

$pnp = @(Get-PrinterTcpPnpUtilArgumentList -InfPath 'C:\driver-extract\BROHL17A.INF')
if ($pnp.Count -ne 2 -or $pnp[0] -cne '/add-driver' -or $pnp[1] -cne '"C:\driver-extract\BROHL17A.INF"') {
    Fail "pnputil arguments $($pnp -join ' ')"
}
$pnpSpace = @(Get-PrinterTcpPnpUtilArgumentList -InfPath 'C:\driver extract\BROHL17A.INF')
if ($pnpSpace.Count -ne 2 -or $pnpSpace[1] -cne '"C:\driver extract\BROHL17A.INF"') {
    Fail "quoted pnputil arguments $($pnpSpace -join ' ')"
}
$expand = @(Get-PrinterTcpExpandArgumentList -CabPath 'C:\Temp\a.cab' -Destination 'C:\Temp\out')
if ($expand.Count -ne 3 -or $expand[0] -cne '-F:*' -or $expand[1] -cne '"C:\Temp\a.cab"' -or $expand[2] -cne '"C:\Temp\out"') {
    Fail "expand arguments $($expand -join ' ')"
}
$expandSpace = @(Get-PrinterTcpExpandArgumentList -CabPath 'C:\Temp\driver extract\a.cab' -Destination 'C:\Temp\driver extract')
if ($expandSpace.Count -ne 3 -or $expandSpace[1] -cne '"C:\Temp\driver extract\a.cab"' -or $expandSpace[2] -cne '"C:\Temp\driver extract"') {
    Fail "quoted expand arguments $($expandSpace -join ' ')"
}
if ($null -ne (Get-PrinterTcpPnpUtilArgumentList -InfPath 'C:\driver-extract\FAX\KOUWNJ1_.inf')) {
    Fail 'pnputil arguments were built for FAX'
}

$sfx = @(Get-PrinterTcpSfxArgumentList -Directory 'C:\driver-extract')
if ($sfx.Count -ne 2 -or $sfx[0] -cne '-y' -or $sfx[1] -cne '-oC:\driver-extract') {
    Fail "sfx arguments $($sfx -join ' ')"
}
if ($sfx[1].StartsWith('-o ')) {
    Fail 'sfx -o had a space'
}
$sfxSpace = @(Get-PrinterTcpSfxArgumentList -Directory 'C:\driver extract')
if ($sfxSpace.Count -ne 2 -or $sfxSpace[1] -cne '-o"C:\driver extract"') {
    Fail "quoted sfx arguments $($sfxSpace -join ' ')"
}

$findRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('printer-tcp-find-' + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $findRoot -Force | Out-Null
try {
    foreach ($rel in @('FAX', 'V4', 'WebView2', 'Win_x86', 'Driver/Win_x64', 'fax/Win_x64')) {
        $dir = Join-Path $findRoot $rel
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $dir 'KOUWNJ1_.inf'), 'inf')
    }
    [System.IO.File]::WriteAllText((Join-Path $findRoot 'BROHL17A.INF'), 'inf')
    $foundKonica = Find-PrinterTcpDriverInf -Root $findRoot -InfName 'KOUWNJ1_.inf'
    $foundNorm = $foundKonica.Replace('\', '/')
    if ($foundNorm -notlike '*/Driver/Win_x64/*') {
        Fail "Konica inf '$foundKonica'"
    }
    if ($foundNorm -match '/FAX/|/fax/|/V4/|/WebView2/') {
        Fail "Konica inf used an excluded path '$foundKonica'"
    }
    $foundBrother = Find-PrinterTcpDriverInf -Root $findRoot -InfName 'BROHL17A.INF'
    if ((Split-Path -Leaf $foundBrother) -cne 'BROHL17A.INF') {
        Fail "Brother inf '$foundBrother'"
    }
    $onlyFax = Join-Path $findRoot 'only-fax'
    New-Item -ItemType Directory -Path (Join-Path $onlyFax 'FAX') -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $onlyFax 'FAX/KOUWNJ1_.inf'), 'inf')
    if (-not [string]::IsNullOrWhiteSpace((Find-PrinterTcpDriverInf -Root $onlyFax -InfName 'KOUWNJ1_.inf'))) {
        Fail 'FAX inf was selected'
    }
    $store = Join-Path $findRoot 'store'
    $olderDir = Join-Path $store 'older'
    $newerDir = Join-Path $store 'newer'
    New-Item -ItemType Directory -Path $olderDir -Force | Out-Null
    New-Item -ItemType Directory -Path $newerDir -Force | Out-Null
    $olderInf = Join-Path $olderDir 'BROHL17A.INF'
    $newerInf = Join-Path $newerDir 'BROHL17A.INF'
    [System.IO.File]::WriteAllText($olderInf, 'pinned-inf')
    [System.IO.File]::WriteAllText($newerInf, 'other-inf')
    [System.IO.File]::SetLastWriteTimeUtc($olderInf, [datetime]::UtcNow.AddMinutes(-10))
    [System.IO.File]::SetLastWriteTimeUtc($newerInf, [datetime]::UtcNow)
    if (-not [string]::IsNullOrWhiteSpace((Find-PrinterTcpStagedInf -Root $store -InfName 'brohl17a.inf'))) {
        Fail 'staged inf was chosen without a hash'
    }
    $pinnedSha = (Get-FileHash -LiteralPath $olderInf -Algorithm SHA256).Hash
    $staged = Find-PrinterTcpStagedInf -Root $store -InfName 'brohl17a.inf' -Sha256 $pinnedSha.ToLowerInvariant()
    if ($staged -cne $olderInf) {
        Fail "staged inf '$staged'"
    }
    $otherSha = (Get-FileHash -LiteralPath $newerInf -Algorithm SHA256).Hash
    if ((Find-PrinterTcpStagedInf -Root $store -InfName 'brohl17a.inf' -Sha256 $otherSha) -cne $newerInf) {
        Fail 'other inf hash was not found'
    }
    if (-not [string]::IsNullOrWhiteSpace((Find-PrinterTcpStagedInf -Root $store -InfName 'brohl17a.inf' -Sha256 ('a' * 64)))) {
        Fail 'unmatched inf hash was returned'
    }
    if (-not [string]::IsNullOrWhiteSpace((Find-PrinterTcpStagedInf -Root $store -InfName 'missing.inf'))) {
        Fail 'missing staged inf was returned'
    }
    if (-not [string]::IsNullOrWhiteSpace((Find-PrinterTcpStagedInf -Root '' -InfName 'BROHL17A.INF'))) {
        Fail 'empty store root returned an inf'
    }
} finally {
    if (Test-Path -LiteralPath $findRoot) {
        Remove-Item -LiteralPath $findRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function New-Printer {
    param([string]$Name, [string]$DriverName, [string]$PortName, [string]$HostAddress = '')
    return [pscustomobject]@{
        Name        = $Name
        DriverName  = $DriverName
        PortName    = $PortName
        HostAddress = $HostAddress
    }
}

function New-Port {
    param([string]$Name)
    return [pscustomobject]@{ Name = $Name }
}

function New-Marker {
    param([string]$Name, [string]$Address, [string]$Model)
    return [pscustomobject]@{ name = $Name; address = $Address; model = $Model }
}

function New-Expect {
    param(
        $ExitCode = $null,
        [bool]$EnsureDriver = $false,
        [bool]$CreatePort = $false,
        [bool]$CreateQueue = $false,
        [bool]$UpdateQueue = $false,
        [string]$PreviousDriver = '',
        [string]$PreviousPort = '',
        [bool]$RemoveQueue = $false,
        [bool]$RemovePort = $false,
        [bool]$WriteMarker = $false,
        [bool]$ClearMarker = $false
    )
    return @{
        ExitCode       = $ExitCode
        EnsureDriver   = $EnsureDriver
        CreatePort     = $CreatePort
        CreateQueue    = $CreateQueue
        UpdateQueue    = $UpdateQueue
        PreviousDriver = $PreviousDriver
        PreviousPort   = $PreviousPort
        RemoveQueue    = $RemoveQueue
        RemovePort     = $RemovePort
        WriteMarker    = $WriteMarker
        ClearMarker    = $ClearMarker
    }
}

function Assert-Plan {
    param($Plan, [hashtable]$Expect, [string]$Label)
    foreach ($name in @(
            'ExitCode', 'EnsureDriver', 'CreatePort', 'CreateQueue', 'UpdateQueue',
            'PreviousDriver', 'PreviousPort', 'RemoveQueue', 'RemovePort', 'WriteMarker', 'ClearMarker'
        )) {
        if ($Plan.PSObject.Properties.Name -notcontains $name) {
            Fail "$Label missing property $name"
        }
    }
    $exit = $Plan.ExitCode
    $wantExit = $Expect.ExitCode
    $exitSame = ($null -eq $exit -and $null -eq $wantExit) -or ($null -ne $exit -and $null -ne $wantExit -and [int]$exit -eq [int]$wantExit)
    if (-not $exitSame) {
        Fail "$Label ExitCode '$exit' expected '$wantExit'"
    }
    foreach ($name in @(
            'EnsureDriver', 'CreatePort', 'CreateQueue', 'UpdateQueue', 'RemoveQueue',
            'RemovePort', 'WriteMarker', 'ClearMarker'
        )) {
        if ([bool]$Plan.$name -ne [bool]$Expect[$name]) {
            Fail "$Label $name '$($Plan.$name)' expected '$($Expect[$name])'"
        }
    }
    foreach ($name in @('PreviousDriver', 'PreviousPort')) {
        if ([string]$Plan.$name -cne [string]$Expect[$name]) {
            Fail "$Label $name '$($Plan.$name)' expected '$($Expect[$name])'"
        }
    }
}

function Get-Plan {
    param(
        [string]$Action = 'Install',
        [string]$PinVersion = '1.6.0.0',
        [string]$PrinterName = 'Front Desk',
        [string]$PrinterAddress = '192.0.2.10',
        [string]$PrinterModel = 'BrotherHlL2370Dw',
        [string]$SourceUrl = '',
        $MarkerPrinters = $null,
        $ExistingPrinters = $null,
        $ExistingPorts = $null,
        [bool]$DriverInstalled = $false,
        $InstalledDriverVersion = ''
    )
    return Get-PrinterTcpPlan -Action $Action -PinVersion $PinVersion -PrinterName $PrinterName -PrinterAddress $PrinterAddress -PrinterModel $PrinterModel -SourceUrl $SourceUrl -MarkerPrinters $MarkerPrinters -ExistingPrinters $ExistingPrinters -ExistingPorts $ExistingPorts -DriverInstalled $DriverInstalled -InstalledDriverVersion $InstalledDriverVersion
}

foreach ($action in @('Install', 'Update', 'Repair', 'Uninstall', 'Reinstall')) {
    Assert-Plan -Plan (Get-Plan -Action $action -PrinterName '') -Expect (New-Expect -ExitCode 0) -Label "$action empty name"
    Assert-Plan -Plan (Get-Plan -Action $action -PrinterAddress '') -Expect (New-Expect -ExitCode 0) -Label "$action empty address"
    Assert-Plan -Plan (Get-Plan -Action $action -PrinterModel '') -Expect (New-Expect -ExitCode 0) -Label "$action empty model"
    Assert-Plan -Plan (Get-Plan -Action $action -PinVersion '') -Expect (New-Expect -ExitCode 0) -Label "$action empty pin"
    Assert-Plan -Plan (Get-Plan -Action $action -PinVersion '   ') -Expect (New-Expect -ExitCode 0) -Label "$action whitespace pin"
    Assert-Plan -Plan (Get-Plan -Action $action -PrinterName '   ') -Expect (New-Expect -ExitCode 0) -Label "$action whitespace name"
}

Assert-Plan -Plan (Get-Plan -PrinterModel 'OtherModel') -Expect (New-Expect -ExitCode 1) -Label 'unknown model'
Assert-Plan -Plan (Get-Plan -PrinterName ' Front Desk') -Expect (New-Expect -ExitCode 1) -Label 'untrimmed name'
Assert-Plan -Plan (Get-Plan -PrinterName ('A' * 221)) -Expect (New-Expect -ExitCode 1) -Label 'long name'
Assert-Plan -Plan (Get-Plan -PrinterName ('A' * 220)) -Expect (New-Expect -EnsureDriver $true -CreatePort $true -CreateQueue $true -WriteMarker $true) -Label '220 character name'
Assert-Plan -Plan (Get-Plan -PrinterName ('Front' + '|' + 'Desk')) -Expect (New-Expect -ExitCode 1) -Label 'pipe in name'
Assert-Plan -Plan (Get-Plan -PrinterAddress '192.0.2.010') -Expect (New-Expect -ExitCode 1) -Label 'leading zero'
Assert-Plan -Plan (Get-Plan -Action 'Reinstall') -Expect (New-Expect -ExitCode 1) -Label 'Reinstall'
Assert-Plan -Plan (Get-Plan -Action 'Nope') -Expect (New-Expect -ExitCode 1) -Label 'unknown action'

function New-UserInfoUrl {
    return -join @('https://', 'user', '@', 'example.invalid/driver.cab')
}

Assert-Plan -Plan (Get-Plan -SourceUrl (New-UserInfoUrl)) -Expect (New-Expect -ExitCode 1) -Label 'userinfo'
Assert-Plan -Plan (Get-Plan -SourceUrl 'http://example.invalid/driver.cab') -Expect (New-Expect -ExitCode 1) -Label 'http url'
$savedBrotherSha = [string]$brother.Sha256
$brother.Sha256 = ''
foreach ($action in @('Install', 'Update', 'Repair', 'Uninstall', 'Reinstall')) {
    Assert-Plan -Plan (Get-Plan -Action $action -SourceUrl (New-UserInfoUrl)) -Expect (New-Expect -ExitCode 0) -Label "$action empty hash"
}
$brother.Sha256 = '   '
Assert-Plan -Plan (Get-Plan -Action 'Install' -SourceUrl (New-UserInfoUrl)) -Expect (New-Expect -ExitCode 0) -Label 'whitespace hash'
$brother.Sha256 = $savedBrotherSha

$create = New-Expect -EnsureDriver $true -CreatePort $true -CreateQueue $true -WriteMarker $true
foreach ($action in @('Install', 'Update')) {
    Assert-Plan -Plan (Get-Plan -Action $action) -Expect $create -Label "$action missing queue"
}
Assert-Plan -Plan (Get-Plan -Action 'Repair') -Expect $create -Label 'Repair missing queue'
Assert-Plan -Plan (Get-Plan -DriverInstalled $true -InstalledDriverVersion '1.6.0.0') -Expect (New-Expect -CreatePort $true -CreateQueue $true -WriteMarker $true) -Label 'driver already installed'
Assert-Plan -Plan (Get-Plan -DriverInstalled $true -InstalledDriverVersion '1.0.0.0') -Expect (New-Expect -EnsureDriver $true -CreatePort $true -CreateQueue $true -WriteMarker $true) -Label 'driver name with an older version'

$readyMarker = @(New-Marker -Name 'Front Desk' -Address '192.0.2.10' -Model 'BrotherHlL2370Dw')
$readyPrinter = @(New-Printer -Name 'Front Desk' -DriverName 'Brother HL-L2370DW series' -PortName 'IP_192.0.2.10' -HostAddress '192.0.2.10')
$readyPort = @(New-Port -Name 'IP_192.0.2.10')
Assert-Plan -Plan (Get-Plan -MarkerPrinters $readyMarker -ExistingPrinters $readyPrinter -ExistingPorts $readyPort -DriverInstalled $true -InstalledDriverVersion '1.6.0.0') -Expect (New-Expect -ExitCode 0) -Label 'already installed'
Assert-Plan -Plan (Get-Plan -MarkerPrinters $readyMarker -ExistingPrinters $readyPrinter -ExistingPorts $readyPort -DriverInstalled $true) -Expect (New-Expect -EnsureDriver $true) -Label 'blank installed version'
Assert-Plan -Plan (Get-Plan -MarkerPrinters $readyMarker -ExistingPrinters $readyPrinter -ExistingPorts $readyPort -DriverInstalled $true -InstalledDriverVersion '1.0.0.0') -Expect (New-Expect -EnsureDriver $true) -Label 'installed driver version differs'
$brotherRawPlan = ([uint64]1 -shl 48) -bor ([uint64]6 -shl 32)
Assert-Plan -Plan (Get-Plan -MarkerPrinters $readyMarker -ExistingPrinters $readyPrinter -ExistingPorts $readyPort -DriverInstalled $true -InstalledDriverVersion $brotherRawPlan) -Expect (New-Expect -ExitCode 0) -Label 'uint64 installed version matches'
Assert-Plan -Plan (Get-Plan -Action 'Repair' -MarkerPrinters $readyMarker -ExistingPrinters $readyPrinter -ExistingPorts $readyPort -DriverInstalled $true -InstalledDriverVersion '1.6.0.0') -Expect (New-Expect -EnsureDriver $true) -Label 'Repair present'

$unmanaged = @(New-Printer -Name 'Front Desk' -DriverName 'Other Driver' -PortName 'IP_192.0.2.10' -HostAddress '192.0.2.10')
Assert-Plan -Plan (Get-Plan -ExistingPrinters $unmanaged -ExistingPorts $readyPort -DriverInstalled $true) -Expect (New-Expect -ExitCode 1) -Label 'unmanaged queue'
Assert-Plan -Plan (Get-Plan -Action 'Repair' -ExistingPrinters $unmanaged -ExistingPorts $readyPort -DriverInstalled $true) -Expect (New-Expect -ExitCode 1) -Label 'Repair unmanaged queue'

$oldDriver = @(New-Printer -Name 'Front Desk' -DriverName 'Old Driver' -PortName 'IP_192.0.2.10' -HostAddress '192.0.2.10')
Assert-Plan -Plan (Get-Plan -MarkerPrinters $readyMarker -ExistingPrinters $oldDriver -ExistingPorts $readyPort -DriverInstalled $true -InstalledDriverVersion '1.6.0.0') -Expect (New-Expect -UpdateQueue $true -PreviousDriver 'Old Driver' -PreviousPort 'IP_192.0.2.10' -WriteMarker $true) -Label 'managed driver differs'

$oldAddress = @(New-Marker -Name 'Front Desk' -Address '192.0.2.10' -Model 'BrotherHlL2370Dw')
$movedPrinter = @(New-Printer -Name 'Front Desk' -DriverName 'Brother HL-L2370DW series' -PortName 'IP_192.0.2.10' -HostAddress '192.0.2.10')
Assert-Plan -Plan (Get-Plan -PrinterAddress '192.0.2.11' -MarkerPrinters $oldAddress -ExistingPrinters $movedPrinter -ExistingPorts $readyPort -DriverInstalled $true -InstalledDriverVersion '1.6.0.0') -Expect (New-Expect -CreatePort $true -UpdateQueue $true -PreviousDriver 'Brother HL-L2370DW series' -PreviousPort 'IP_192.0.2.10' -WriteMarker $true) -Label 'managed address differs'
$wrongHost = @([pscustomobject]@{ Name = 'IP_192.0.2.10'; HostAddress = '198.51.100.20' })
Assert-Plan -Plan (Get-Plan -ExistingPorts $wrongHost -DriverInstalled $true -InstalledDriverVersion '1.6.0.0') -Expect (New-Expect -ExitCode 1) -Label 'port host differs'
$sameHost = @([pscustomobject]@{ Name = 'IP_192.0.2.10'; HostAddress = '192.0.2.10' })
Assert-Plan -Plan (Get-Plan -ExistingPorts $sameHost -DriverInstalled $true -InstalledDriverVersion '1.6.0.0') -Expect (New-Expect -CreateQueue $true -WriteMarker $true) -Label 'port host matches'
$konicaMarker = @(New-Marker -Name 'Front Desk' -Address '192.0.2.10' -Model 'KonicaUniversalPcl')
$konicaPrinter = @(New-Printer -Name 'Front Desk' -DriverName 'KONICA MINOLTA Universal PCL' -PortName 'IP_192.0.2.10' -HostAddress '192.0.2.10')
$konicaRawPlan = ([uint64]3 -shl 48) -bor ([uint64]9 -shl 32) -bor ([uint64]1203 -shl 16) -bor ([uint64]500)
Assert-Plan -Plan (Get-Plan -PinVersion '3.9.1203.500' -PrinterModel 'KonicaUniversalPcl' -MarkerPrinters $konicaMarker -ExistingPrinters $konicaPrinter -ExistingPorts $readyPort -DriverInstalled $true -InstalledDriverVersion $konicaRawPlan) -Expect (New-Expect -ExitCode 0) -Label 'Konica uint64 version matches'
Assert-Plan -Plan (Get-Plan -PinVersion '3.9.1203.500' -PrinterModel 'KonicaUniversalPcl' -MarkerPrinters $konicaMarker -ExistingPrinters $konicaPrinter -ExistingPorts $readyPort -DriverInstalled $true -InstalledDriverVersion '3.9.1203.0') -Expect (New-Expect -EnsureDriver $true) -Label 'Konica version differs'

Assert-Plan -Plan (Get-Plan -Action 'Uninstall' -MarkerPrinters $readyMarker -ExistingPrinters $readyPrinter -ExistingPorts $readyPort) -Expect (New-Expect -RemoveQueue $true -RemovePort $true -ClearMarker $true) -Label 'Uninstall owned queue'
Assert-Plan -Plan (Get-Plan -Action 'Uninstall' -SourceUrl (New-UserInfoUrl) -MarkerPrinters $readyMarker -ExistingPrinters $readyPrinter -ExistingPorts $readyPort) -Expect (New-Expect -RemoveQueue $true -RemovePort $true -ClearMarker $true) -Label 'Uninstall userinfo'
Assert-Plan -Plan (Get-Plan -Action 'Uninstall' -ExistingPrinters $readyPrinter -ExistingPorts $readyPort) -Expect (New-Expect -ExitCode 0) -Label 'Uninstall unmanaged queue'
$shared = @(
    (New-Printer -Name 'Front Desk' -DriverName 'Brother HL-L2370DW series' -PortName 'IP_192.0.2.10')
    (New-Printer -Name 'South Desk' -DriverName 'Brother HL-L2370DW series' -PortName 'IP_192.0.2.10')
)
Assert-Plan -Plan (Get-Plan -Action 'Uninstall' -MarkerPrinters $readyMarker -ExistingPrinters $shared -ExistingPorts $readyPort) -Expect (New-Expect -RemoveQueue $true -ClearMarker $true) -Label 'Uninstall shared port'
Assert-Plan -Plan (Get-Plan -Action 'Uninstall' -MarkerPrinters $readyMarker -ExistingPorts $readyPort) -Expect (New-Expect -RemovePort $true -ClearMarker $true) -Label 'Uninstall queue already gone'
$argumentOnly = @(New-Port -Name 'IP_192.0.2.11')
Assert-Plan -Plan (Get-Plan -Action 'Uninstall' -PrinterAddress '192.0.2.11' -MarkerPrinters $readyMarker -ExistingPrinters $readyPrinter -ExistingPorts $argumentOnly) -Expect (New-Expect -RemoveQueue $true -ClearMarker $true) -Label 'Uninstall leaves the argument port'
$bothPorts = @(
    (New-Port -Name 'IP_192.0.2.10')
    (New-Port -Name 'IP_192.0.2.11')
)
$sharedRecorded = @(
    (New-Printer -Name 'Front Desk' -DriverName 'Brother HL-L2370DW series' -PortName 'IP_192.0.2.10')
    (New-Printer -Name 'South Desk' -DriverName 'Brother HL-L2370DW series' -PortName 'IP_192.0.2.10')
)
Assert-Plan -Plan (Get-Plan -Action 'Uninstall' -PrinterAddress '192.0.2.11' -MarkerPrinters $readyMarker -ExistingPrinters $sharedRecorded -ExistingPorts $bothPorts) -Expect (New-Expect -RemoveQueue $true -ClearMarker $true) -Label 'Uninstall shared recorded port'
$blankAddress = @(New-Marker -Name 'Front Desk' -Address '' -Model 'BrotherHlL2370Dw')
Assert-Plan -Plan (Get-Plan -Action 'Uninstall' -PrinterAddress '192.0.2.11' -MarkerPrinters $blankAddress -ExistingPrinters $readyPrinter -ExistingPorts $bothPorts) -Expect (New-Expect -RemoveQueue $true -ClearMarker $true) -Label 'Uninstall blank recorded address'
$ownedMove = Get-Plan -Action 'Uninstall' -PrinterAddress '192.0.2.11' -MarkerPrinters $readyMarker -ExistingPrinters $readyPrinter -ExistingPorts $bothPorts
if (-not [bool]$ownedMove.RemovePort -or [string]$ownedMove.RemovePortName -cne 'IP_192.0.2.10') {
    Fail "uninstall recorded port '$($ownedMove.RemovePortName)' remove=$($ownedMove.RemovePort)"
}

class PrinterTcpFakeHttpException : System.Exception {
    [object]$Response
    PrinterTcpFakeHttpException([int]$Status) : base('status') {
        $this.Response = [pscustomobject]@{ StatusCode = $Status }
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

$utf8 = [System.Text.UTF8Encoding]::new($false)
$script:GoodBytes = $utf8.GetBytes('printer-tcp-payload')
$sha = [System.Security.Cryptography.SHA256]::Create()
try {
    $script:GoodSha = ([System.BitConverter]::ToString($sha.ComputeHash($script:GoodBytes))).Replace('-', '').ToLowerInvariant()
} finally {
    $sha.Dispose()
}

$downloadRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('printer-tcp-download-' + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $downloadRoot -Force | Out-Null
$dest = Join-Path $downloadRoot 'payload.bin'
$script:DownloadCount = 0
$script:Sleeps = [System.Collections.Generic.List[int]]::new()
$script:Referers = [System.Collections.Generic.List[string]]::new()

function Reset-Download {
    $script:DownloadCount = 0
    $script:Sleeps = [System.Collections.Generic.List[int]]::new()
    $script:Referers = [System.Collections.Generic.List[string]]::new()
    $script:PrinterTcpErrorLog = [System.Collections.Generic.List[string]]::new()
    if (Test-Path -LiteralPath $dest) {
        Remove-Item -LiteralPath $dest -Force
    }
    Remove-Item -LiteralPath 'Env:RELIAN_DEPLOY_CANCEL' -ErrorAction SilentlyContinue
    $script:RetryDelay = {
        param($Seconds)
        $script:Sleeps.Add([int]$Seconds)
    }
    $script:DownloadFile = {
        param($Url, $Destination, $Referer)
        $script:DownloadCount++
        $script:Referers.Add([string]$Referer)
        [System.IO.File]::WriteAllBytes($Destination, $script:GoodBytes)
    }
}

try {
    Reset-Download
    $code = [int](Save-PrinterTcpPayload -Url 'https://example.invalid/driver.cab' -Destination $dest -Sha256 $script:GoodSha -Label 'BrotherHlL2370Dw')
    if ($code -ne 0 -or -not (Test-Path -LiteralPath $dest) -or $script:Referers[0] -cne '') {
        Fail "matching hash returned $code"
    }

    Reset-Download
    $code = [int](Save-PrinterTcpPayload -Url 'https://example.invalid/driver.cab' -Destination $dest -Sha256 $script:GoodSha.ToUpperInvariant() -Label 'BrotherHlL2370Dw')
    if ($code -ne 0 -or -not (Test-Path -LiteralPath $dest)) {
        Fail "uppercase hash returned $code"
    }

    Reset-Download
    $script:DownloadFile = {
        param($Url, $Destination, $Referer)
        $script:DownloadCount++
        [System.IO.File]::WriteAllBytes($Destination, $utf8.GetBytes('other-bytes'))
    }
    $code = [int](Save-PrinterTcpPayload -Url 'https://example.invalid/driver.cab' -Destination $dest -Sha256 $script:GoodSha -Label 'BrotherHlL2370Dw')
    $logged = $script:PrinterTcpErrorLog -join "`n"
    if ($code -ne 1 -or (Test-Path -LiteralPath $dest) -or $script:DownloadCount -ne 1 -or $script:Sleeps.Count -ne 0) {
        Fail "mismatch returned $code after $($script:DownloadCount) downloads"
    }
    if ($logged -like '*https://*' -or $logged -notlike '*BrotherHlL2370Dw*') {
        Fail 'mismatch error did not name the model id'
    }

    Reset-Download
    $code = [int](Save-PrinterTcpPayload -Url (New-UserInfoUrl) -Destination $dest -Sha256 $script:GoodSha -Label 'BrotherHlL2370Dw')
    if ($code -ne 1 -or $script:DownloadCount -ne 0) {
        Fail "userinfo returned $code after $($script:DownloadCount) downloads"
    }
    if (($script:PrinterTcpErrorLog -join "`n") -notlike '*userinfo*' -or ($script:PrinterTcpErrorLog -join "`n") -like '*https://*') {
        Fail 'userinfo error was not a label-only message'
    }

    Reset-Download
    $code = [int](Save-PrinterTcpPayload -Url 'http://example.invalid/driver.cab' -Destination $dest -Sha256 $script:GoodSha -Label 'BrotherHlL2370Dw')
    if ($code -ne 1 -or $script:DownloadCount -ne 0) {
        Fail "http returned $code after $($script:DownloadCount) downloads"
    }
    if (($script:PrinterTcpErrorLog -join "`n") -like '*http://*') {
        Fail 'http error included a URL'
    }

    Reset-Download
    $code = [int](Save-PrinterTcpPayload -Url (New-UserInfoUrl) -Destination $dest -Sha256 '' -Label 'BrotherHlL2370Dw')
    if ($code -ne 0 -or $script:DownloadCount -ne 0) {
        Fail "empty hash returned $code"
    }

    Reset-Download
    $code = [int](Save-PrinterTcpPayload -Url 'https://example.invalid/driver.cab' -Destination $dest -Sha256 $script:GoodSha -Label 'KonicaUniversalPcl' -Referer $konicaReferer)
    if ($code -ne 0 -or $script:Referers.Count -ne 1 -or $script:Referers[0] -cne $konicaReferer) {
        Fail 'Referer was not forwarded'
    }

    foreach ($status in @(408, 429, 500, 502, 503, 504)) {
        if (-not (Test-PrinterTcpDownloadIsTransient -ErrorRecord ([PrinterTcpFakeHttpException]::new($status)))) {
            Fail "HTTP $status was not retried"
        }
    }
    if (Test-PrinterTcpDownloadIsTransient -ErrorRecord ([PrinterTcpFakeHttpException]::new(404))) {
        Fail 'HTTP 404 was retried'
    }
    if (-not (Test-PrinterTcpDownloadIsTransient -ErrorRecord ([System.TimeoutException]::new('timed out')))) {
        Fail 'timeout was not retried'
    }
    $dns = [System.Net.WebException]::new('dns', [System.Net.WebExceptionStatus]::NameResolutionFailure)
    if (-not (Test-PrinterTcpDownloadIsTransient -ErrorRecord $dns)) {
        Fail 'name resolution failure was not retried'
    }

    Reset-Download
    $script:DownloadFile = {
        param($Url, $Destination, $Referer)
        $script:DownloadCount++
        New-HttpFailure -Status 404 -Message 'https://example.invalid/missing'
    }
    $code = [int](Save-PrinterTcpPayload -Url 'https://example.invalid/driver.cab' -Destination $dest -Sha256 $script:GoodSha -Label 'BrotherHlL2370Dw')
    if ($code -ne 1 -or $script:DownloadCount -ne 1 -or $script:Sleeps.Count -ne 0) {
        Fail "404 returned $code after $($script:DownloadCount) downloads"
    }
    if (($script:PrinterTcpErrorLog -join "`n") -like '*https://*') {
        Fail '404 error included a URL'
    }

    Reset-Download
    $script:Attempt = 0
    $script:DownloadFile = {
        param($Url, $Destination, $Referer)
        $script:DownloadCount++
        $script:Attempt++
        if ($script:Attempt -lt 3) {
            New-HttpFailure -Status 503 -Message 'https://example.invalid/busy'
        }
        [System.IO.File]::WriteAllBytes($Destination, $script:GoodBytes)
    }
    $code = [int](Save-PrinterTcpPayload -Url 'https://example.invalid/driver.cab' -Destination $dest -Sha256 $script:GoodSha -Label 'BrotherHlL2370Dw')
    if ($code -ne 0 -or $script:DownloadCount -ne 3 -or $script:Sleeps.Count -ne 2 -or $script:Sleeps[0] -ne 5 -or $script:Sleeps[1] -ne 20) {
        Fail "503 retries returned $code sleeps $($script:Sleeps -join ',')"
    }

    Reset-Download
    $script:DownloadFile = {
        param($Url, $Destination, $Referer)
        $script:DownloadCount++
        New-HttpFailure -Status 503 -Message 'https://example.invalid/busy'
    }
    $code = [int](Save-PrinterTcpPayload -Url 'https://example.invalid/driver.cab' -Destination $dest -Sha256 $script:GoodSha -Label 'KonicaUniversalPcl' -Referer $konicaReferer)
    if ($code -ne 1 -or $script:DownloadCount -ne 3 -or $script:Sleeps.Count -ne 2) {
        Fail "exhausted 503 returned $code after $($script:DownloadCount) downloads"
    }

    Reset-Download
    $script:Attempt = 0
    $script:DownloadFile = {
        param($Url, $Destination, $Referer)
        $script:DownloadCount++
        $script:Attempt++
        if ($script:Attempt -eq 1) {
            throw $dns
        }
        [System.IO.File]::WriteAllBytes($Destination, $script:GoodBytes)
    }
    $code = [int](Save-PrinterTcpPayload -Url 'https://example.invalid/driver.cab' -Destination $dest -Sha256 $script:GoodSha -Label 'BrotherHlL2370Dw')
    if ($code -ne 0 -or $script:DownloadCount -ne 2 -or $script:Sleeps.Count -ne 1 -or $script:Sleeps[0] -ne 5) {
        Fail "dns then success returned $code"
    }
} finally {
    Remove-Item -LiteralPath 'Env:RELIAN_DEPLOY_CANCEL' -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $downloadRoot) {
        Remove-Item -LiteralPath $downloadRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$script:OriginalBrotherUrl = [string]$brother.SourceUrl
$script:OriginalBrotherSha = [string]$brother.Sha256
$script:OriginalKonicaUrl = [string]$konica.SourceUrl
$script:OriginalKonicaSha = [string]$konica.Sha256
$script:Root = Join-Path ([System.IO.Path]::GetTempPath()) ('printer-tcp-plan-' + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
$script:MarkerRoot = Join-Path $script:Root 'marker'

function Restore-Models {
    $brother.SourceUrl = $script:OriginalBrotherUrl
    $brother.Sha256 = $script:OriginalBrotherSha
    $konica.SourceUrl = $script:OriginalKonicaUrl
    $konica.Sha256 = $script:OriginalKonicaSha
}

function Reset-Case {
    Restore-Models
    $script:DownloadCount = 0
    $script:Referers = [System.Collections.Generic.List[string]]::new()
    $script:PrinterTcpErrorLog = [System.Collections.Generic.List[string]]::new()
    $script:BadDownload = $false
    $script:FailNextSet = $false
    $script:LayoutOk = $false
    $script:ExpandKinds = [System.Collections.Generic.List[string]]::new()
    $script:SfxArgs = @()
    $script:PnpPaths = [System.Collections.Generic.List[string]]::new()
    $script:SignaturePaths = [System.Collections.Generic.List[string]]::new()
    $script:AddCalls = [System.Collections.Generic.List[object]]::new()
    $script:DriverCalls = [System.Collections.Generic.List[object]]::new()
    $script:PortCalls = [System.Collections.Generic.List[object]]::new()
    $script:SetCalls = [System.Collections.Generic.List[object]]::new()
    $script:RemovePrinterCalls = [System.Collections.Generic.List[string]]::new()
    $script:RemovePortCalls = [System.Collections.Generic.List[string]]::new()
    $script:LivePrinters = [System.Collections.Generic.List[object]]::new()
    $script:LivePorts = [System.Collections.Generic.List[object]]::new()
    $script:DriverNames = [System.Collections.Generic.List[string]]::new()
    $script:DriverVersions = @{}
    $script:StagedQueries = [System.Collections.Generic.List[string]]::new()
    $script:StagedSources = [System.Collections.Generic.List[string]]::new()
    $script:FindStagedInf = {
        param($InfName, $SourceInf)
        $script:StagedQueries.Add([string]$InfName)
        $script:StagedSources.Add([string]$SourceInf)
        return 'C:\Windows\System32\DriverStore\FileRepository\staged\' + [string]$InfName
    }
    Remove-Item -LiteralPath 'Env:RELIAN_DEPLOY_CANCEL' -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $script:MarkerRoot) {
        Remove-Item -LiteralPath $script:MarkerRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Path $script:MarkerRoot -Force | Out-Null
    $script:DownloadFile = {
        param($Url, $Destination, $Referer)
        $script:DownloadCount++
        $script:Referers.Add([string]$Referer)
        $parent = Split-Path -Parent $Destination
        if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        if ($script:BadDownload) {
            [System.IO.File]::WriteAllBytes($Destination, $utf8.GetBytes('bad-bytes'))
            return
        }
        [System.IO.File]::WriteAllBytes($Destination, $script:GoodBytes)
    }
    $script:GetPrinters = {
        return ,$script:LivePrinters.ToArray()
    }
    $script:GetPrinterPorts = {
        return ,$script:LivePorts.ToArray()
    }
    $script:GetInstalledDriverNames = {
        $list = [System.Collections.Generic.List[object]]::new()
        foreach ($name in @($script:DriverNames)) {
            $version = ''
            if ($null -ne $script:DriverVersions -and $script:DriverVersions.ContainsKey([string]$name)) {
                $version = $script:DriverVersions[[string]$name]
            }
            $list.Add([pscustomobject]@{
                    Name          = [string]$name
                    DriverVersion = $version
                })
        }
        return ,$list.ToArray()
    }
    $script:AddPrinterPort = {
        param($Name, $PrinterHostAddress, $PortNumber, $SnmpEnabled)
        $script:PortCalls.Add([pscustomobject]@{
                Name               = [string]$Name
                PrinterHostAddress = [string]$PrinterHostAddress
                PortNumber         = [int]$PortNumber
                SnmpEnabled        = [bool]$SnmpEnabled
            })
        $script:LivePorts.Add([pscustomobject]@{ Name = [string]$Name; HostAddress = [string]$PrinterHostAddress })
    }
    $script:AddPrinter = {
        param($Name, $DriverName, $PortName)
        $script:AddCalls.Add([pscustomobject]@{
                Name       = [string]$Name
                DriverName = [string]$DriverName
                PortName   = [string]$PortName
            })
        $script:LivePrinters.Add([pscustomobject]@{
                Name       = [string]$Name
                DriverName = [string]$DriverName
                PortName   = [string]$PortName
            })
    }
    $script:AddPrinterDriver = {
        param($Name, $InfPath)
        $script:DriverCalls.Add([pscustomobject]@{
                Name    = [string]$Name
                InfPath = [string]$InfPath
            })
        return 0
    }
    $script:SetPrinter = {
        param($Name, $DriverName, $PortName)
        $script:SetCalls.Add([pscustomobject]@{
                Name       = [string]$Name
                DriverName = [string]$DriverName
                PortName   = [string]$PortName
            })
        if ($script:FailNextSet) {
            $script:FailNextSet = $false
            throw 'set failed'
        }
        foreach ($printer in $script:LivePrinters) {
            if ([string]::Equals([string]$printer.Name, [string]$Name, [System.StringComparison]::OrdinalIgnoreCase)) {
                $printer.DriverName = [string]$DriverName
                $printer.PortName = [string]$PortName
            }
        }
    }
    $script:RemovePrinter = {
        param($Name)
        $script:RemovePrinterCalls.Add([string]$Name)
        $kept = [System.Collections.Generic.List[object]]::new()
        foreach ($printer in $script:LivePrinters) {
            if ([string]::Equals([string]$printer.Name, [string]$Name, [System.StringComparison]::OrdinalIgnoreCase)) {
                continue
            }
            $kept.Add($printer)
        }
        $script:LivePrinters = $kept
    }
    $script:RemovePrinterPort = {
        param($Name)
        $script:RemovePortCalls.Add([string]$Name)
        $kept = [System.Collections.Generic.List[object]]::new()
        foreach ($port in $script:LivePorts) {
            if ([string]::Equals([string]$port.Name, [string]$Name, [System.StringComparison]::OrdinalIgnoreCase)) {
                continue
            }
            $kept.Add($port)
        }
        $script:LivePorts = $kept
    }
    $script:ExpandCab = {
        param($CabPath, $Destination)
        $script:ExpandKinds.Add('Cab')
        $inf = @(
            '[SourceDisksNames.amd64]'
            '1 = %Disk1%,,,"amd64"'
            '2 = %Disk1%,,,'
            ''
            '[SourceDisksFiles]'
            'payload.dll = 1'
            'readme.chm = 2'
        ) -join "`r`n"
        [System.IO.File]::WriteAllText((Join-Path $Destination 'BROHL17A.INF'), $inf)
        [System.IO.File]::WriteAllBytes((Join-Path $Destination 'payload.dll'), [byte[]]@(1))
        [System.IO.File]::WriteAllBytes((Join-Path $Destination 'readme.chm'), [byte[]]@(2))
        [System.IO.File]::WriteAllBytes((Join-Path $Destination 'BROHL17A.CAT'), [byte[]]@(3))
    }
    $script:ExpandSfx = {
        param($ExePath, $Destination)
        $script:ExpandKinds.Add('Sfx')
        $script:SfxArgs = @(Get-PrinterTcpSfxArgumentList -Directory $Destination)
        foreach ($rel in @('FAX', 'V4', 'WebView2', 'Win_x86', 'Driver/Win_x64')) {
            $dir = Join-Path $Destination $rel
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $inf = @(
                '[SourceDisksNames]'
                '1 = "KONICA MINOLTA Universal PCL",,,'
                ''
                '[SourceDisksFiles]'
                'kofile.dll = 1'
            ) -join "`r`n"
            [System.IO.File]::WriteAllText((Join-Path $dir 'KOUWNJ1_.inf'), $inf)
            [System.IO.File]::WriteAllBytes((Join-Path $dir 'kofile.dll'), [byte[]]@(9))
            [System.IO.File]::WriteAllBytes((Join-Path $dir 'KOUWNJ1_.CAT'), [byte[]]@(8))
        }
    }
    $script:GetAuthenticodeSignature = {
        param($Path)
        $script:SignaturePaths.Add([string]$Path)
        $leaf = [System.IO.Path]::GetFileName($Path)
        if ($leaf -ceq 'BROHL17A.CAT') {
            $dir = Split-Path -Parent $Path
            $moved = Join-Path $dir 'amd64/payload.dll'
            $stayed = Join-Path $dir 'readme.chm'
            $left = Join-Path $dir 'payload.dll'
            if ((Test-Path -LiteralPath $moved) -and (Test-Path -LiteralPath $stayed) -and -not (Test-Path -LiteralPath $left)) {
                $script:LayoutOk = $true
            }
            return [pscustomobject]@{ Status = 'Valid'; Subject = $whql }
        }
        if ($leaf -ceq 'KOUWNJ1_.CAT') {
            $norm = $Path.Replace('\', '/')
            $dir = Split-Path -Parent $Path
            $dll = Join-Path $dir 'kofile.dll'
            if ($norm.Contains('/Win_x64/') -and $norm -notmatch '/FAX/|/V4/|/WebView2/' -and (Test-Path -LiteralPath $dll)) {
                $script:LayoutOk = $true
            }
            return [pscustomobject]@{
                Status       = 'UnknownError'
                Subject      = $whql
                ChainStatus  = @('NotTimeValid')
                HasTimestamp = $false
            }
        }
        if ($Path -like '*.exe') {
            return [pscustomobject]@{ Status = 'Valid'; Subject = 'CN=KONICA MINOLTA, O=KONICA MINOLTA' }
        }
        return [pscustomobject]@{ Status = 'Valid'; Subject = 'CN=Microsoft Corporation, O=Microsoft Corporation' }
    }
    $script:InvokePnpUtil = {
        param($InfPath)
        $script:PnpPaths.Add([string]$InfPath)
        $leaf = [System.IO.Path]::GetFileName($InfPath)
        if ($leaf -ceq 'KOUWNJ1_.inf') {
            $script:DriverNames.Add('KONICA MINOLTA Universal PCL')
            $script:DriverVersions['KONICA MINOLTA Universal PCL'] = '3.9.1203.500'
        } else {
            $script:DriverNames.Add('Brother HL-L2370DW series')
            $script:DriverVersions['Brother HL-L2370DW series'] = '1.6.0.0'
        }
        return 0
    }
}

function Use-FakePins {
    $brother.Sha256 = $script:GoodSha
    $brother.SourceUrl = 'https://example.invalid/brother.cab'
    $konica.Sha256 = $script:GoodSha
    $konica.SourceUrl = 'https://example.invalid/konica.exe'
}

function Read-Marker {
    $path = Join-Path $script:MarkerRoot 'marker.json'
    if (-not (Test-Path -LiteralPath $path)) {
        return @()
    }
    $parsed = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json
    if ($null -eq $parsed -or $null -eq $parsed.printers) {
        return @()
    }
    return @($parsed.printers)
}

function Invoke-Case {
    param(
        [string]$Action = 'Install',
        [string]$PinVersion = '1.6.0.0',
        [string]$PrinterName = 'Front Desk',
        [string]$PrinterAddress = '192.0.2.10',
        [string]$PrinterModel = 'BrotherHlL2370Dw',
        [string]$CancelPath = ''
    )
    return [int](Invoke-PrinterTcpAction -DeploymentType $Action -Action $Action -PinVersion $PinVersion -CancelPath $CancelPath -MarkerRoot $script:MarkerRoot -PrinterName $PrinterName -PrinterAddress $PrinterAddress -PrinterModel $PrinterModel)
}

try {
    $unused = Join-Path $script:Root 'unused-marker'
    $emptyCode = [int](Invoke-PrinterTcpAction -DeploymentType 'Install' -Action 'Install' -PinVersion '1.6.0.0' -PrinterName '' -PrinterAddress '192.0.2.10' -PrinterModel 'BrotherHlL2370Dw' -MarkerRoot $unused)
    if ($emptyCode -ne 0 -or (Test-Path -LiteralPath $unused)) {
        Fail "empty name returned $emptyCode"
    }
    $emptyPin = [int](Invoke-PrinterTcpAction -DeploymentType 'Uninstall' -Action 'Uninstall' -PinVersion '' -PrinterName 'Front Desk' -PrinterAddress '192.0.2.10' -PrinterModel 'BrotherHlL2370Dw' -MarkerRoot $unused)
    if ($emptyPin -ne 0 -or (Test-Path -LiteralPath $unused)) {
        Fail "empty pin returned $emptyPin"
    }

    $runner = & pwsh -NoProfile -File $scriptPath -DeploymentType 'Install' -Action 'Install' -PinVersion '1.6.0.0'
    if ($LASTEXITCODE -ne 0) {
        Fail "runner invocation exited $LASTEXITCODE"
    }
    $runnerUninstall = & pwsh -NoProfile -File $scriptPath -DeploymentType 'Uninstall' -Action 'Uninstall' -PinVersion '1.6.0.0'
    if ($LASTEXITCODE -ne 0) {
        Fail "runner uninstall exited $LASTEXITCODE"
    }
    & pwsh -NoProfile -File $scriptPath | Out-Null
    if ($LASTEXITCODE -ne 1) {
        Fail "missing parameters exited $LASTEXITCODE"
    }

    Reset-Case
    Use-FakePins
    $code = Invoke-Case
    $marked = @(Read-Marker)
    if ($code -ne 0 -or $script:DownloadCount -ne 1 -or $script:Referers[0] -cne '' -or -not $script:LayoutOk) {
        Fail "Brother install returned $code downloads $($script:DownloadCount) layout $($script:LayoutOk)"
    }
    if ($script:ExpandKinds.Count -ne 1 -or $script:ExpandKinds[0] -cne 'Cab') {
        Fail 'Brother install did not expand the cab'
    }
    if ($script:PnpPaths.Count -ne 1 -or $script:PnpPaths[0] -notlike '*BROHL17A.INF*') {
        Fail 'Brother pnputil path was wrong'
    }
    $stagedInf = 'C:\Windows\System32\DriverStore\FileRepository\staged\BROHL17A.INF'
    if ($script:DriverCalls.Count -ne 1 -or $script:DriverCalls[0].Name -cne 'Brother HL-L2370DW series' -or
        $script:DriverCalls[0].InfPath -cne $stagedInf -or $script:DriverCalls[0].InfPath -ceq $script:PnpPaths[0]) {
        Fail 'Brother driver was not registered from the driver store INF'
    }
    if ($script:StagedQueries.Count -ne 1 -or $script:StagedQueries[0] -cne 'BROHL17A.INF') {
        Fail 'staged inf lookup did not use the model inf name'
    }
    if ($script:StagedSources.Count -ne 1 -or $script:StagedSources[0] -cne $script:PnpPaths[0]) {
        Fail 'staged inf lookup did not use the extracted inf'
    }
    $pnpArgs = @(Get-PrinterTcpPnpUtilArgumentList -InfPath $script:PnpPaths[0])
    if ($pnpArgs -contains '/install') {
        Fail 'pnputil was passed /install'
    }
    if ($script:AddCalls.Count -ne 1 -or $script:AddCalls[0].Name -cne 'Front Desk' -or
        $script:AddCalls[0].DriverName -cne 'Brother HL-L2370DW series' -or $script:AddCalls[0].PortName -cne 'IP_192.0.2.10') {
        Fail 'Brother queue was not created with the allowlisted driver'
    }
    if ($script:SetCalls.Count -ne 0) {
        Fail 'new queue called Set-Printer'
    }
    if ($script:PortCalls.Count -ne 1 -or $script:PortCalls[0].Name -cne 'IP_192.0.2.10' -or
        [int]$script:PortCalls[0].PortNumber -ne 9100 -or [bool]$script:PortCalls[0].SnmpEnabled) {
        Fail 'Brother port was not 9100 with SNMP disabled'
    }
    if ($marked.Count -ne 1 -or [string]$marked[0].name -cne 'Front Desk' -or [string]$marked[0].address -cne '192.0.2.10' -or [string]$marked[0].model -cne 'BrotherHlL2370Dw') {
        Fail 'Brother marker was not written after success'
    }

    $again = Invoke-Case
    if ($again -ne 0 -or $script:DownloadCount -ne 1 -or $script:SetCalls.Count -ne 0 -or $script:AddCalls.Count -ne 1) {
        Fail "second install returned $again downloads $($script:DownloadCount)"
    }

    $south = Invoke-Case -PrinterName 'South Desk' -PrinterAddress '192.0.2.11'
    $both = @(Read-Marker)
    if ($south -ne 0 -or $both.Count -ne 2) {
        Fail "second queue returned $south marker count $($both.Count)"
    }
    $names = @($both | ForEach-Object { [string]$_.name })
    if ($names -notcontains 'Front Desk' -or $names -notcontains 'South Desk') {
        Fail "marker names $($names -join ',')"
    }

    $removed = Invoke-Case -Action 'Uninstall' -PrinterName 'Front Desk' -PrinterAddress '192.0.2.10'
    $left = @(Read-Marker)
    if ($removed -ne 0 -or $script:RemovePrinterCalls.Count -ne 1 -or $script:RemovePrinterCalls[0] -cne 'Front Desk') {
        Fail 'uninstall did not remove the owned queue'
    }
    if ($script:RemovePortCalls -notcontains 'IP_192.0.2.10') {
        Fail 'uninstall left an unused port'
    }
    if ($left.Count -ne 1 -or [string]$left[0].name -cne 'South Desk') {
        Fail 'uninstall removed the other marker entry'
    }
    if ($script:PnpPaths.Count -ne 1) {
        Fail 'uninstall removed the shared driver'
    }

    Reset-Case
    Use-FakePins
    $script:LivePrinters.Add([pscustomobject]@{
            Name       = 'Front Desk'
            DriverName = 'Old Driver'
            PortName   = 'USB001'
        })
    $code = Invoke-Case
    if ($code -ne 1 -or $script:DownloadCount -ne 0 -or $script:SetCalls.Count -ne 0) {
        Fail "unmanaged queue returned $code sets $($script:SetCalls.Count)"
    }
    if (@(Read-Marker).Count -ne 0) {
        Fail 'unmanaged queue wrote a marker'
    }

    Reset-Case
    Use-FakePins
    $script:DriverNames.Add('Brother HL-L2370DW series')
    $script:DriverVersions['Brother HL-L2370DW series'] = '1.6.0.0'
    $script:LivePrinters.Add([pscustomobject]@{
            Name       = 'Front Desk'
            DriverName = 'Old Driver'
            PortName   = 'IP_192.0.2.10'
        })
    $script:LivePorts.Add([pscustomobject]@{ Name = 'IP_192.0.2.10'; HostAddress = '192.0.2.10' })
    Write-PrinterTcpMarkerName -Root $script:MarkerRoot -Name 'Front Desk' -Address '192.0.2.10' -Model 'BrotherHlL2370Dw'
    $script:FailNextSet = $true
    $code = Invoke-Case
    if ($code -ne 1 -or $script:SetCalls.Count -ne 2 -or $script:DownloadCount -ne 0) {
        Fail "failed update returned $code sets $($script:SetCalls.Count)"
    }
    if ($script:SetCalls[0].DriverName -cne 'Brother HL-L2370DW series' -or $script:SetCalls[0].PortName -cne 'IP_192.0.2.10') {
        Fail 'update did not apply the pinned driver'
    }
    if ($script:SetCalls[1].DriverName -cne 'Old Driver' -or $script:SetCalls[1].PortName -cne 'IP_192.0.2.10') {
        Fail 'failed update did not restore the previous driver and port'
    }
    $still = @(Read-Marker)
    if ($still.Count -ne 1 -or [string]$still[0].address -cne '192.0.2.10' -or [string]$still[0].model -cne 'BrotherHlL2370Dw') {
        Fail 'failed update changed the marker'
    }

    Reset-Case
    Use-FakePins
    $script:DriverNames.Add('Brother HL-L2370DW series')
    $script:DriverVersions['Brother HL-L2370DW series'] = '1.6.0.0'
    $script:LivePrinters.Add([pscustomobject]@{
            Name       = 'Front Desk'
            DriverName = 'Brother HL-L2370DW series'
            PortName   = 'IP_192.0.2.10'
        })
    $script:LivePorts.Add([pscustomobject]@{ Name = 'IP_192.0.2.10'; HostAddress = '192.0.2.10' })
    Write-PrinterTcpMarkerName -Root $script:MarkerRoot -Name 'Front Desk' -Address '192.0.2.10' -Model 'BrotherHlL2370Dw'
    $code = Invoke-Case -PrinterAddress '192.0.2.11'
    $moved = @(Read-Marker)
    if ($code -ne 0 -or $script:SetCalls.Count -ne 1 -or $script:SetCalls[0].PortName -cne 'IP_192.0.2.11') {
        Fail 'address change did not update the queue'
    }
    if ($script:PortCalls.Count -ne 1 -or $script:PortCalls[0].PrinterHostAddress -cne '192.0.2.11' -or [bool]$script:PortCalls[0].SnmpEnabled) {
        Fail 'address change did not create the new port'
    }
    if ($moved.Count -ne 1 -or [string]$moved[0].address -cne '192.0.2.11') {
        Fail 'address change did not update the marker'
    }
    if ($script:RemovePortCalls.Count -ne 0) {
        Fail 'address change removed a port'
    }

    Reset-Case
    Use-FakePins
    $script:DriverNames.Add('Brother HL-L2370DW series')
    $script:LivePrinters.Add([pscustomobject]@{
            Name       = 'Front Desk'
            DriverName = 'Brother HL-L2370DW series'
            PortName   = 'IP_192.0.2.10'
        })
    $script:LivePrinters.Add([pscustomobject]@{
            Name       = 'South Desk'
            DriverName = 'Brother HL-L2370DW series'
            PortName   = 'IP_192.0.2.10'
        })
    $script:LivePorts.Add([pscustomobject]@{ Name = 'IP_192.0.2.10'; HostAddress = '192.0.2.10' })
    Write-PrinterTcpMarkerName -Root $script:MarkerRoot -Name 'Front Desk' -Address '192.0.2.10' -Model 'BrotherHlL2370Dw'
    Write-PrinterTcpMarkerName -Root $script:MarkerRoot -Name 'South Desk' -Address '192.0.2.10' -Model 'BrotherHlL2370Dw'
    $code = Invoke-Case -Action 'Uninstall'
    $sharedLeft = @(Read-Marker)
    if ($code -ne 0 -or $script:RemovePrinterCalls.Count -ne 1 -or $script:RemovePortCalls.Count -ne 0) {
        Fail 'shared port was removed'
    }
    if ($sharedLeft.Count -ne 1 -or [string]$sharedLeft[0].name -cne 'South Desk') {
        Fail 'shared uninstall changed the other marker'
    }

    Reset-Case
    Use-FakePins
    $code = Invoke-Case -Action 'Reinstall'
    if ($code -ne 1 -or $script:DownloadCount -ne 0 -or @(Read-Marker).Count -ne 0) {
        Fail "Reinstall returned $code"
    }

    Reset-Case
    Use-FakePins
    $brother.Sha256 = ''
    $brother.SourceUrl = New-UserInfoUrl
    $code = Invoke-Case
    if ($code -ne 0 -or $script:DownloadCount -ne 0 -or $script:AddCalls.Count -ne 0) {
        Fail "empty hash install returned $code after $($script:DownloadCount) downloads"
    }

    Reset-Case
    Use-FakePins
    $brother.Sha256 = ''
    $brother.SourceUrl = New-UserInfoUrl
    $script:DriverNames.Add('Brother HL-L2370DW series')
    $script:LivePrinters.Add([pscustomobject]@{
            Name       = 'Front Desk'
            DriverName = 'Brother HL-L2370DW series'
            PortName   = 'IP_192.0.2.10'
        })
    $script:LivePorts.Add([pscustomobject]@{ Name = 'IP_192.0.2.10'; HostAddress = '192.0.2.10' })
    Write-PrinterTcpMarkerName -Root $script:MarkerRoot -Name 'Front Desk' -Address '192.0.2.10' -Model 'BrotherHlL2370Dw'
    $code = Invoke-Case -Action 'Uninstall'
    if ($code -ne 0 -or $script:DownloadCount -ne 0 -or $script:RemovePrinterCalls.Count -ne 0 -or @(Read-Marker).Count -ne 1) {
        Fail "empty hash uninstall returned $code"
    }

    Reset-Case
    Use-FakePins
    $brother.SourceUrl = New-UserInfoUrl
    $script:DriverNames.Add('Brother HL-L2370DW series')
    $script:LivePrinters.Add([pscustomobject]@{
            Name       = 'Front Desk'
            DriverName = 'Brother HL-L2370DW series'
            PortName   = 'IP_192.0.2.10'
        })
    $script:LivePorts.Add([pscustomobject]@{ Name = 'IP_192.0.2.10'; HostAddress = '192.0.2.10' })
    Write-PrinterTcpMarkerName -Root $script:MarkerRoot -Name 'Front Desk' -Address '192.0.2.10' -Model 'BrotherHlL2370Dw'
    $code = Invoke-Case -Action 'Uninstall'
    if ($code -ne 0 -or $script:DownloadCount -ne 0 -or $script:RemovePrinterCalls.Count -ne 1 -or @(Read-Marker).Count -ne 0) {
        Fail "userinfo uninstall returned $code"
    }

    Reset-Case
    Use-FakePins
    $brother.SourceUrl = New-UserInfoUrl
    $code = Invoke-Case
    if ($code -ne 1 -or $script:DownloadCount -ne 0) {
        Fail "userinfo action returned $code after $($script:DownloadCount) downloads"
    }
    if (($script:PrinterTcpErrorLog -join "`n") -notlike '*userinfo*' -or ($script:PrinterTcpErrorLog -join "`n") -like '*https://*') {
        Fail 'userinfo action error included a URL'
    }

    Reset-Case
    Use-FakePins
    $brother.SourceUrl = 'http://example.invalid/brother.cab'
    $code = Invoke-Case
    if ($code -ne 1 -or $script:DownloadCount -ne 0 -or ($script:PrinterTcpErrorLog -join "`n") -like '*http://*') {
        Fail 'http action downloaded or logged a URL'
    }

    Reset-Case
    Use-FakePins
    $script:BadDownload = $true
    $code = Invoke-Case
    if ($code -ne 1 -or $script:DownloadCount -ne 1 -or $script:PnpPaths.Count -ne 0 -or $script:SignaturePaths.Count -ne 0) {
        Fail "hash mismatch action returned $code"
    }
    $mismatch = $script:PrinterTcpErrorLog -join "`n"
    if ($mismatch -notlike '*BrotherHlL2370Dw*' -or $mismatch -like '*https://*') {
        Fail 'hash mismatch action did not name the model id'
    }
    if (@(Read-Marker).Count -ne 0) {
        Fail 'hash mismatch wrote a marker'
    }

    Reset-Case
    Use-FakePins
    $env:RELIAN_DEPLOY_CANCEL = '1'
    $code = Invoke-Case
    if ($code -ne 130 -or $script:DownloadCount -ne 0 -or $script:AddCalls.Count -ne 0) {
        Fail "cancel returned $code"
    }

    Reset-Case
    Use-FakePins
    $konica.Sha256 = $script:GoodSha
    $konica.SourceUrl = 'https://example.invalid/konica.exe'
    $code = Invoke-Case -PrinterModel 'KonicaUniversalPcl' -PinVersion '3.9.1203.500' -PrinterAddress '192.0.2.11'
    if ($code -ne 0 -or $script:DownloadCount -ne 1 -or $script:Referers.Count -ne 1 -or $script:Referers[0] -cne $konicaReferer) {
        Fail "Konica install returned $code referer '$($script:Referers -join ',')'"
    }
    if ($script:ExpandKinds.Count -ne 1 -or $script:ExpandKinds[0] -cne 'Sfx' -or -not $script:LayoutOk) {
        Fail 'Konica install did not extract with the sfx arguments before the catalog check'
    }
    if ($script:SfxArgs.Count -ne 2 -or $script:SfxArgs[0] -cne '-y' -or -not $script:SfxArgs[1].StartsWith('-o') -or $script:SfxArgs[1].StartsWith('-o ')) {
        Fail "Konica sfx arguments $($script:SfxArgs -join ' ')"
    }
    if ($script:PnpPaths.Count -ne 1) {
        Fail 'Konica pnputil was not called once'
    }
    $konicaNorm = $script:PnpPaths[0].Replace('\', '/')
    if ($konicaNorm -notlike '*/Win_x64/*' -or $konicaNorm -match '/FAX/|/V4/|/WebView2/') {
        Fail "Konica pnputil path '$($script:PnpPaths[0])'"
    }
    if ($script:AddCalls.Count -ne 1 -or $script:AddCalls[0].DriverName -cne 'KONICA MINOLTA Universal PCL' -or $script:AddCalls[0].PortName -cne 'IP_192.0.2.11') {
        Fail 'Konica queue was not created on 9100'
    }
    $konicaMarker = @(Read-Marker)
    if ($konicaMarker.Count -ne 1 -or [string]$konicaMarker[0].model -cne 'KonicaUniversalPcl' -or [string]$konicaMarker[0].address -cne '192.0.2.11') {
        Fail 'Konica marker was wrong'
    }

    Reset-Case
    Use-FakePins
    $script:DriverNames.Add('Brother HL-L2370DW series')
    $script:LivePrinters.Add([pscustomobject]@{
            Name       = 'Front Desk'
            DriverName = 'Brother HL-L2370DW series'
            PortName   = 'IP_192.0.2.10'
        })
    $script:LivePorts.Add([pscustomobject]@{ Name = 'IP_192.0.2.10'; HostAddress = '192.0.2.10' })
    Write-PrinterTcpMarkerName -Root $script:MarkerRoot -Name 'Front Desk' -Address '192.0.2.10' -Model 'BrotherHlL2370Dw'
    $code = Invoke-Case -Action 'Repair'
    if ($code -ne 0 -or $script:DownloadCount -ne 1 -or $script:PnpPaths.Count -ne 1 -or $script:SetCalls.Count -ne 0) {
        Fail "Repair returned $code downloads $($script:DownloadCount) sets $($script:SetCalls.Count)"
    }

    Reset-Case
    Use-FakePins
    $script:LivePrinters.Add([pscustomobject]@{
            Name       = 'Front Desk'
            DriverName = 'Brother HL-L2370DW series'
            PortName   = 'IP_192.0.2.10'
        })
    $script:LivePorts.Add([pscustomobject]@{ Name = 'IP_192.0.2.10'; HostAddress = '192.0.2.10' })
    $script:LivePorts.Add([pscustomobject]@{ Name = 'IP_192.0.2.11'; HostAddress = '192.0.2.11' })
    Write-PrinterTcpMarkerName -Root $script:MarkerRoot -Name 'Front Desk' -Address '192.0.2.10' -Model 'BrotherHlL2370Dw'
    $code = Invoke-Case -Action 'Uninstall' -PrinterAddress '192.0.2.11'
    if ($code -ne 0 -or $script:RemovePrinterCalls.Count -ne 1 -or @(Read-Marker).Count -ne 0) {
        Fail "moved uninstall returned $code"
    }
    if ($script:RemovePortCalls -notcontains 'IP_192.0.2.10' -or $script:RemovePortCalls -contains 'IP_192.0.2.11') {
        Fail "moved uninstall removed $($script:RemovePortCalls -join ',')"
    }

    $brotherRaw = ([uint64]1 -shl 48) -bor ([uint64]6 -shl 32)
    $konicaRaw = ([uint64]3 -shl 48) -bor ([uint64]9 -shl 32) -bor ([uint64]1203 -shl 16) -bor ([uint64]500)
    $oldRaw = ([uint64]1 -shl 48)
    if (-not (Test-PrinterTcpSameDriverVersion -Installed '1.6.0.0' -Pinned '1.6.0.0')) {
        Fail 'dotted pin did not match itself'
    }
    if (-not (Test-PrinterTcpSameDriverVersion -Installed '1.6.0' -Pinned '1.6.0.0')) {
        Fail 'three-part version did not match the pin'
    }
    if (-not (Test-PrinterTcpSameDriverVersion -Installed $brotherRaw -Pinned '1.6.0.0')) {
        Fail 'uint64 Brother version did not match 1.6.0.0'
    }
    if (-not (Test-PrinterTcpSameDriverVersion -Installed ([string]$brotherRaw) -Pinned '1.6.0.0')) {
        Fail 'decimal Brother version did not match 1.6.0.0'
    }
    if (-not (Test-PrinterTcpSameDriverVersion -Installed $konicaRaw -Pinned '3.9.1203.500')) {
        Fail 'uint64 Konica version did not match 3.9.1203.500'
    }
    foreach ($installed in @('', '   ', 'not-a-version', '1.0.0.0', $oldRaw, 0)) {
        if (Test-PrinterTcpSameDriverVersion -Installed $installed -Pinned '1.6.0.0') {
            Fail "installed '$installed' counted as the Brother pin"
        }
    }

    Reset-Case
    Use-FakePins
    $script:DriverNames.Add('Brother HL-L2370DW series')
    $script:DriverVersions = @{ 'Brother HL-L2370DW series' = '1.0.0.0' }
    $script:LivePrinters.Add([pscustomobject]@{
            Name       = 'Front Desk'
            DriverName = 'Brother HL-L2370DW series'
            PortName   = 'IP_192.0.2.10'
        })
    $script:LivePorts.Add([pscustomobject]@{ Name = 'IP_192.0.2.10'; HostAddress = '192.0.2.10' })
    Write-PrinterTcpMarkerName -Root $script:MarkerRoot -Name 'Front Desk' -Address '192.0.2.10' -Model 'BrotherHlL2370Dw'
    $code = Invoke-Case
    if ($code -ne 0 -or $script:DownloadCount -ne 1 -or $script:SetCalls.Count -ne 0) {
        Fail "older installed driver returned $code downloads $($script:DownloadCount) sets $($script:SetCalls.Count)"
    }
} finally {
    Restore-Models
    Remove-Item -LiteralPath 'Env:RELIAN_DEPLOY_CANCEL' -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $script:Root) {
        Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Output 'printer-tcp-plan tests passed'
exit 0
