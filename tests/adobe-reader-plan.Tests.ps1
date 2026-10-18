$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$PSNativeCommandUseErrorActionPreference = $false

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'packages/adobe-reader/Invoke-AdobeReader.ps1'
$releasePath = Join-Path $repoRoot 'releases/adobe-reader.json'

function Fail {
    param([string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) {
        $Message = 'assertion failed'
    }
    [Console]::Error.WriteLine("FAIL $Message")
    exit 1
}

if (-not (Test-Path -LiteralPath $scriptPath)) {
    Fail 'Invoke-AdobeReader.ps1 does not exist'
}
if (-not (Test-Path -LiteralPath $releasePath)) {
    Fail 'releases/adobe-reader.json does not exist'
}

$release = Get-Content -LiteralPath $releasePath -Raw | ConvertFrom-Json
$expectedUrl = 'https://ardownload2.adobe.com/pub/adobe/acrobat/win/AcrobatDC/2600222031/AcroRdrDCx642600222031_en_US.exe'
$expectedSha = '86e98feb3f2afa66656a85cbbc6fb71d6a3217ebf8fdc21f4d1a54d21cb45028'
$expectedFile = 'AcroRdrDCx642600222031_en_US.exe'
if ([string]$release.name -ne 'Adobe Acrobat Reader') { Fail 'release name' }
if ([string]$release.channel -ne 'Continuous') { Fail 'release channel' }
if ([string]$release.platform -ne 'Windows') { Fail 'release platform' }
if ([string]$release.arch -ne 'x64') { Fail 'release arch' }
if ([string]$release.language -ne 'en_US') { Fail 'release language' }
if ([string]$release.version -ne '26.2.22031.0') { Fail 'release version' }
if ([string]$release.file -ne $expectedFile) { Fail 'release file' }
if ([string]$release.url -cne $expectedUrl) { Fail 'release url' }
if ([string]$release.sha256 -cne $expectedSha) { Fail 'release sha256' }
if ([int64]$release.size -ne 789419184) { Fail 'release size' }
if ([string]$release.hashAlgorithm -ne 'SHA256') { Fail 'release hash algorithm' }
if ([string]$release.source -cne 'https://ardownload2.adobe.com/pub/adobe/acrobat/win/AcrobatDC/') { Fail 'release source' }
if ([string]$release.sha256 -cnotmatch '^[0-9a-f]{64}$') { Fail 'release sha256 is not lowercase hex' }

$scriptText = [System.IO.File]::ReadAllText($scriptPath)
$urlHits = ([regex]::Matches($scriptText, [regex]::Escape($expectedUrl))).Count
if ($urlHits -ne 1) {
    Fail "installer URL appears $urlHits times"
}
if ($scriptText -notlike '*-cnotmatch*') {
    Fail 'pin hash does not use -cnotmatch'
}
if ($scriptText.Contains('-notmatch')) {
    Fail 'pin hash uses -notmatch'
}
if ($scriptText -match 'Mandatory\s*=') {
    Fail 'a parameter is Mandatory'
}
foreach ($banned in @('ISX_SERIALNUMBER', 'Ninja', 'USERPROFILE', 'Stop-Process', '/home/')) {
    if ($scriptText.Contains($banned)) {
        Fail "script contains $banned"
    }
}
if ($scriptText -notlike "*if (`$env:RELIAN_DEPLOY_TEST -eq '1' -or `$MyInvocation.InvocationName -eq '.')*") {
    Fail 'test mode does not return when the environment variable is set'
}
if ($scriptText -notlike '*Adobe Acrobat Reader*') {
    Fail 'script does not name Adobe Acrobat Reader'
}
if ($scriptText -notlike '*8c3c366b-8606-4576-9f2d-4051144f7ca2*') {
    Fail 'PSAppDeployToolkit guid is missing'
}
if ($scriptText -notlike '*relian-adobe-reader-*') {
    Fail 'cache prefix is missing'
}

$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) {
    Fail 'Invoke-AdobeReader.ps1 did not parse'
}
$wanted = @('DeploymentType', 'Action', 'PinVersion', 'InstallerUrl', 'InstallerSha256', 'CancelPath', 'MarkerRoot')
$found = @{}
foreach ($parameter in $ast.ParamBlock.Parameters) {
    $name = $parameter.Name.VariablePath.UserPath
    $found[$name] = $true
    $typeName = $parameter.StaticType.Name
    if ($typeName -ne 'String') {
        Fail "$name is $typeName, expected String"
    }
    foreach ($attr in $parameter.Attributes) {
        if ($attr.TypeName.Name -ne 'Parameter') {
            continue
        }
        foreach ($named in $attr.NamedArguments) {
            if ($named.ArgumentName -eq 'Mandatory' -and $named.Argument.Extent.Text -match 'true') {
                Fail "$name is Mandatory"
            }
        }
    }
}
foreach ($name in $wanted) {
    if (-not $found.ContainsKey($name)) {
        Fail "missing parameter $name"
    }
}

$env:RELIAN_DEPLOY_TEST = '1'
. $scriptPath

if (-not (Get-Command Get-AdobeReaderPlan -ErrorAction SilentlyContinue)) {
    Fail 'Get-AdobeReaderPlan was not defined'
}
if (-not (Get-Command Invoke-AdobeReaderAction -ErrorAction SilentlyContinue)) {
    Fail 'Invoke-AdobeReaderAction was not defined'
}
if ($InstallerUrl -cne [string]$release.url) {
    Fail 'InstallerUrl default does not match releases/adobe-reader.json'
}
if ($InstallerSha256 -cne [string]$release.sha256) {
    Fail 'InstallerSha256 default does not match releases/adobe-reader.json'
}
if ((Format-AdobeReaderVersion -Version ([version]'26.002.22031')) -cne '26.2.22031.0') {
    Fail 'adobe continuous version did not normalize'
}

function New-AdobeReaderUserInfoUrl {
    return -join @('https://', 'user', '@', 'example.invalid/AcroRdrDCx642600222031_en_US.exe')
}

function Assert-Plan {
    param(
        $Plan,
        [hashtable]$Expect,
        [string]$Label
    )
    $names = @('ExitCode', 'RunInstaller', 'UninstallProduct', 'WriteMarker', 'ClearMarker', 'Log')
    foreach ($name in $names) {
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
    foreach ($name in @('RunInstaller', 'WriteMarker', 'Log')) {
        $actual = [string]$Plan.$name
        $want = [string]$Expect[$name]
        if ($actual -cne $want) {
            Fail "$Label $name '$actual' expected '$want'"
        }
    }
    foreach ($name in @('UninstallProduct', 'ClearMarker')) {
        if ([bool]$Plan.$name -ne [bool]$Expect[$name]) {
            Fail "$Label $name '$($Plan.$name)' expected '$($Expect[$name])'"
        }
    }
}

function New-Expect {
    param(
        $ExitCode = $null,
        [string]$RunInstaller = '',
        [bool]$UninstallProduct = $false,
        [string]$WriteMarker = '',
        [bool]$ClearMarker = $false,
        [string]$Log = ''
    )
    return @{
        ExitCode         = $ExitCode
        RunInstaller     = $RunInstaller
        UninstallProduct = $UninstallProduct
        WriteMarker      = $WriteMarker
        ClearMarker      = $ClearMarker
        Log              = $Log
    }
}

$pin = '26.2.22031.0'
$older = '26.2.22030.0'
$newer = '26.2.22032.0'

$installRows = @(
    @{
        Label = 'empty pin'
        Pin = ''
        Installed = $newer
        Marker = $newer
        Expect = (New-Expect -ExitCode 0)
    }
    @{
        Label = 'unparseable pin'
        Pin = 'nope'
        Installed = ''
        Marker = ''
        Expect = (New-Expect -ExitCode 1)
    }
    @{
        Label = 'missing app'
        Pin = $pin
        Installed = ''
        Marker = ''
        Expect = (New-Expect -RunInstaller 'install' -Log 'Install')
    }
    @{
        Label = 'older than pin'
        Pin = $pin
        Installed = $older
        Marker = $older
        Expect = (New-Expect -RunInstaller 'install' -Log 'Install')
    }
    @{
        Label = 'equal pin missing marker'
        Pin = $pin
        Installed = $pin
        Marker = ''
        Expect = (New-Expect -WriteMarker $pin)
    }
    @{
        Label = 'equal pin with marker'
        Pin = $pin
        Installed = $pin
        Marker = $pin
        Expect = (New-Expect)
    }
    @{
        Label = 'vendor newer than pin'
        Pin = $pin
        Installed = $newer
        Marker = $pin
        Expect = (New-Expect -WriteMarker $newer)
    }
    @{
        Label = 'vendor newer marker already advanced'
        Pin = $pin
        Installed = $newer
        Marker = $newer
        Expect = (New-Expect)
    }
    @{
        Label = 'adobe continuous build equals the pin'
        Pin = '26.002.22031'
        Installed = $pin
        Marker = ''
        Expect = (New-Expect -WriteMarker $pin)
    }
    @{
        Label = 'adobe continuous build with marker'
        Pin = '26.002.22031'
        Installed = $pin
        Marker = $pin
        Expect = (New-Expect)
    }
    @{
        Label = 'three-part pin'
        Pin = '26.2.22031'
        Installed = $pin
        Marker = ''
        Expect = (New-Expect -WriteMarker $pin)
    }
)

foreach ($row in $installRows) {
    foreach ($action in @('Install', 'Update')) {
        $plan = Get-AdobeReaderPlan -Action $action -PinVersion $row.Pin -InstalledVersion $row.Installed -MarkerVersion $row.Marker
        Assert-Plan -Plan $plan -Expect $row.Expect -Label "$action $($row.Label)"
    }
}

$whitespace = Get-AdobeReaderPlan -Action 'Install' -PinVersion '   ' -InstalledVersion $pin -MarkerVersion ''
Assert-Plan -Plan $whitespace -Expect (New-Expect -ExitCode 0) -Label 'whitespace pin'

$badInstalled = Get-AdobeReaderPlan -Action 'Install' -PinVersion $pin -InstalledVersion 'nope' -MarkerVersion ''
Assert-Plan -Plan $badInstalled -Expect (New-Expect -ExitCode 1) -Label 'invalid installed version'

$badMarker = Get-AdobeReaderPlan -Action 'Install' -PinVersion $pin -InstalledVersion $pin -MarkerVersion 'nope'
Assert-Plan -Plan $badMarker -Expect (New-Expect -ExitCode 1) -Label 'invalid marker version'

$reinstall = Get-AdobeReaderPlan -Action 'Reinstall' -PinVersion $pin -InstalledVersion $pin -MarkerVersion $pin
Assert-Plan -Plan $reinstall -Expect (New-Expect -ExitCode 1) -Label 'Reinstall'

$unknown = Get-AdobeReaderPlan -Action 'Nope' -PinVersion $pin -InstalledVersion '' -MarkerVersion ''
Assert-Plan -Plan $unknown -Expect (New-Expect -ExitCode 1) -Label 'unknown action'

$repairRows = @(
    @{
        Label = 'Repair missing app'
        Pin = $pin; Installed = ''; Marker = ''
        Expect = (New-Expect -RunInstaller 'install' -Log 'Repair')
    }
    @{
        Label = 'Repair equal'
        Pin = $pin; Installed = $pin; Marker = $pin
        Expect = (New-Expect -RunInstaller 'install' -Log 'Repair')
    }
    @{
        Label = 'Repair older than pin'
        Pin = $pin; Installed = $older; Marker = $older
        Expect = (New-Expect -RunInstaller 'install' -Log 'Repair')
    }
    @{
        Label = 'Repair vendor newer'
        Pin = $pin; Installed = $newer; Marker = $pin
        Expect = (New-Expect -WriteMarker $newer)
    }
)
foreach ($row in $repairRows) {
    $plan = Get-AdobeReaderPlan -Action 'Repair' -PinVersion $row.Pin -InstalledVersion $row.Installed -MarkerVersion $row.Marker
    Assert-Plan -Plan $plan -Expect $row.Expect -Label $row.Label
}

$uninstallRows = @(
    @{
        Label = 'Uninstall installed Reader'
        Pin = $pin; Installed = $newer; Marker = $newer
        Expect = (New-Expect -UninstallProduct $true -ClearMarker $true -Log 'Uninstall')
    }
    @{
        Label = 'Uninstall marker only'
        Pin = $pin; Installed = ''; Marker = $pin
        Expect = (New-Expect -ClearMarker $true -Log 'Uninstall')
    }
    @{
        Label = 'Uninstall nothing'
        Pin = $pin; Installed = ''; Marker = ''
        Expect = (New-Expect -ExitCode 0)
    }
)
foreach ($row in $uninstallRows) {
    $plan = Get-AdobeReaderPlan -Action 'Uninstall' -PinVersion $row.Pin -InstalledVersion $row.Installed -MarkerVersion $row.Marker
    Assert-Plan -Plan $plan -Expect $row.Expect -Label $row.Label
}

if (-not (Test-AdobeReaderPinHash -Hash $expectedSha)) {
    Fail 'release sha256 was rejected'
}
foreach ($badHash in @('', '   ', ('0' * 64), ('a' * 64), ('b' * 64), $expectedSha.ToUpperInvariant(), ($expectedSha.Substring(0, 63) + 'A'), 'abc')) {
    if (Test-AdobeReaderPinHash -Hash $badHash) {
        Fail 'placeholder or uppercase hash was accepted'
    }
}
if (-not (Test-AdobeReaderPinHash -Hash (('0' * 63) + '1'))) {
    Fail 'a non-repeating lowercase hash was rejected'
}

$keptPins = @(
    @{ Action = 'Uninstall'; Pin = ''; Hash = $expectedSha }
    @{ Action = 'Uninstall'; Pin = $pin; Hash = '' }
    @{ Action = 'Uninstall'; Pin = $pin; Hash = '   ' }
    @{ Action = 'Reinstall'; Pin = $pin; Hash = '' }
    @{ Action = 'Install'; Pin = '   '; Hash = $expectedSha }
)
foreach ($row in $keptPins) {
    $early = @(Get-AdobeReaderPreDispatchCode -Action $row.Action -PinVersion $row.Pin -InstallerUrl (New-AdobeReaderUserInfoUrl) -InstallerSha256 $row.Hash)
    if ($early.Count -ne 1 -or [int]$early[-1] -ne 0) {
        Fail "$($row.Action) empty pin or hash predispatch returned $($early -join ',')"
    }
}
$blocked = @(Get-AdobeReaderPreDispatchCode -Action 'Uninstall' -PinVersion $pin -InstallerUrl (New-AdobeReaderUserInfoUrl) -InstallerSha256 $expectedSha)
if ($blocked.Count -ne 1 -or [int]$blocked[-1] -ne 1) {
    Fail "userinfo predispatch returned $($blocked -join ',')"
}
foreach ($badHash in @(('0' * 64), ('a' * 64), $expectedSha.ToUpperInvariant())) {
    $early = @(Get-AdobeReaderPreDispatchCode -Action 'Install' -PinVersion $pin -InstallerUrl 'https://example.invalid/AcroRdrDCx642600222031_en_US.exe' -InstallerSha256 $badHash)
    if ($early.Count -ne 1 -or [int]$early[-1] -ne 1) {
        Fail "bad hash predispatch returned $($early -join ',')"
    }
}
$reinstallEarly = @(Get-AdobeReaderPreDispatchCode -Action 'Reinstall' -PinVersion $pin -InstallerUrl 'https://example.invalid/AcroRdrDCx642600222031_en_US.exe' -InstallerSha256 $expectedSha)
if ($reinstallEarly.Count -ne 1 -or [int]$reinstallEarly[-1] -ne 1) {
    Fail "Reinstall predispatch returned $($reinstallEarly -join ',')"
}
$continue = @(Get-AdobeReaderPreDispatchCode -Action 'Install' -PinVersion $pin -InstallerUrl 'https://example.invalid/AcroRdrDCx642600222031_en_US.exe' -InstallerSha256 $expectedSha)
if ($continue.Count -ne 0) {
    Fail "install predispatch returned $($continue -join ',')"
}

$installArgs = @(Get-AdobeReaderInstallArgumentList)
$expectedInstallArgs = @('/sAll', '/rs', '/msi', 'EULA_ACCEPT=YES')
if ($installArgs.Count -ne $expectedInstallArgs.Count) {
    Fail "install arguments $($installArgs -join ' ')"
}
for ($i = 0; $i -lt $expectedInstallArgs.Count; $i++) {
    if ([string]$installArgs[$i] -cne $expectedInstallArgs[$i]) {
        Fail "install arguments $($installArgs -join ' ')"
    }
}
foreach ($extra in @('/qn', '/quiet', '/norestart', $expectedFile)) {
    if ($installArgs -contains $extra) {
        Fail "install arguments include $extra"
    }
}

$readerCode = '{11111111-1111-4111-8111-111111111111}'
$readerDcCode = '{22222222-2222-4222-8222-222222222222}'
$reader64Code = '{33333333-3333-4333-8333-333333333333}'
$readerTrimCode = '{CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC}'
$acrobatCode = '{44444444-4444-4444-8444-444444444444}'
$acrobat64Code = '{55555555-5555-4555-8555-555555555555}'
$proCode = '{66666666-6666-4666-8666-666666666666}'
$standardCode = '{77777777-7777-4777-8777-777777777777}'
$proDcCode = '{88888888-8888-4888-8888-888888888888}'
$notepadCode = '{99999999-9999-4999-8999-999999999999}'
$lowerCode = '{AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA}'
$notReaderCode = '{BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB}'

$catalog = @(
    [pscustomobject]@{ DisplayName = 'Adobe Acrobat Reader'; ProductCode = $readerCode; DisplayVersion = $older }
    [pscustomobject]@{ DisplayName = 'Adobe Acrobat Reader DC'; ProductCode = $readerDcCode; DisplayVersion = '26.002.22031' }
    [pscustomobject]@{ DisplayName = 'Adobe Acrobat Reader (64-bit)'; ProductCode = $reader64Code; DisplayVersion = '26.2.22029.0' }
    [pscustomobject]@{ DisplayName = ' Adobe Acrobat Reader '; ProductCode = $readerTrimCode; DisplayVersion = '26.2.22028.0' }
    [pscustomobject]@{ DisplayName = 'Adobe Acrobat'; ProductCode = $acrobatCode; DisplayVersion = '99.0.0.0' }
    [pscustomobject]@{ DisplayName = 'Adobe Acrobat (64-bit)'; ProductCode = $acrobat64Code; DisplayVersion = '99.0.0.0' }
    [pscustomobject]@{ DisplayName = 'Adobe Acrobat Pro'; ProductCode = $proCode; DisplayVersion = '99.0.0.0' }
    [pscustomobject]@{ DisplayName = 'Adobe Acrobat Standard'; ProductCode = $standardCode; DisplayVersion = '99.0.0.0' }
    [pscustomobject]@{ DisplayName = 'Adobe Acrobat Pro DC'; ProductCode = $proDcCode; DisplayVersion = '99.0.0.0' }
    [pscustomobject]@{ DisplayName = 'Notepad'; ProductCode = $notepadCode; DisplayVersion = '10.0.0.0' }
    [pscustomobject]@{ DisplayName = 'adobe acrobat reader'; ProductCode = $lowerCode; DisplayVersion = '99.0.0.0' }
    [pscustomobject]@{ DisplayName = 'Not Adobe Acrobat Reader'; ProductCode = $notReaderCode; DisplayVersion = '99.0.0.0' }
)
$selected = @(Get-AdobeReaderMsiProductCode -Products $catalog)
$wantedCodes = @($readerCode, $readerDcCode, $reader64Code, $readerTrimCode)
$rejectedCodes = @($acrobatCode, $acrobat64Code, $proCode, $standardCode, $proDcCode, $notepadCode, $lowerCode, $notReaderCode)
if ($selected.Count -ne $wantedCodes.Count) {
    Fail "product selection returned $($selected -join ',')"
}
foreach ($code in $wantedCodes) {
    if ($selected -notcontains $code) {
        Fail "product selection missed $code"
    }
}
foreach ($code in $rejectedCodes) {
    if ($selected -contains $code) {
        Fail "product selection returned $code"
    }
}
if ((Get-AdobeReaderInstalledVersionFromProducts -Products $catalog) -cne $pin) {
    Fail "installed Reader version is '$(Get-AdobeReaderInstalledVersionFromProducts -Products $catalog)'"
}
$acrobatOnly = @(
    [pscustomobject]@{ DisplayName = 'Adobe Acrobat'; ProductCode = $acrobatCode; DisplayVersion = '99.0.0.0' }
    [pscustomobject]@{ DisplayName = 'Adobe Acrobat Pro DC'; ProductCode = $proDcCode; DisplayVersion = '26.002.22032' }
)
if (-not [string]::IsNullOrWhiteSpace((Get-AdobeReaderInstalledVersionFromProducts -Products $acrobatOnly))) {
    Fail 'Acrobat counted as the installed Reader version'
}
$nonGuid = Get-AdobeReaderUninstallArgumentList -ProductCode 'Adobe Acrobat'
if ($null -ne $nonGuid) {
    Fail 'a non-guid product code produced uninstall arguments'
}
$uninstallArgs = @(Get-AdobeReaderUninstallArgumentList -ProductCode $readerCode)
if ($uninstallArgs.Count -ne 3 -or [string]$uninstallArgs[0] -cne '/x' -or [string]$uninstallArgs[1] -cne $readerCode -or [string]$uninstallArgs[2] -cne '/qn') {
    Fail "uninstall arguments $($uninstallArgs -join ' ')"
}
$msiexecPath = Get-AdobeReaderMsiexecPath
if (-not $msiexecPath.EndsWith('msiexec.exe')) {
    Fail "msiexec path $msiexecPath"
}
if ([string]::IsNullOrWhiteSpace([string]$env:SystemRoot)) {
    if ($msiexecPath -cne 'msiexec.exe') {
        Fail "msiexec path $msiexecPath"
    }
} else {
    $expectedMsiexec = Join-Path $env:SystemRoot 'System32\msiexec.exe'
    if ($msiexecPath -cne $expectedMsiexec) {
        Fail "msiexec path $msiexecPath"
    }
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

$root = Join-Path ([System.IO.Path]::GetTempPath()) ('adobe-reader-plan-' + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $root -Force | Out-Null
$good = $utf8.GetBytes('adobe-reader-payload')
$goodSha = Get-Sha $good
$script:DownloadCount = 0
$script:ProductListCalls = 0
$script:ProcessExit = 0
$script:ProcessCalls = [System.Collections.Generic.List[object]]::new()

function Reset-Action {
    param([string]$MarkerText = '')
    $script:DownloadCount = 0
    $script:ProductListCalls = 0
    $script:ProcessExit = 0
    $script:ProcessCalls = [System.Collections.Generic.List[object]]::new()
    $script:AdobeReaderErrorLog = [System.Collections.Generic.List[string]]::new()
    Remove-Item -LiteralPath 'Env:RELIAN_DEPLOY_CANCEL' -ErrorAction SilentlyContinue
    $script:MarkerRoot = Join-Path $root ('marker-' + [guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Path $script:MarkerRoot -Force | Out-Null
    if (-not [string]::IsNullOrWhiteSpace($MarkerText)) {
        [System.IO.File]::WriteAllText((Join-Path $script:MarkerRoot 'marker.txt'), $MarkerText, $utf8)
    }
    $script:InstallerPath = Join-Path $script:MarkerRoot $expectedFile
    $script:DownloadFile = {
        param($Url, $Destination)
        $script:DownloadCount++
        [System.IO.File]::WriteAllBytes($Destination, $good)
    }
    $script:RetryDelay = { param($Seconds) }
    $script:ReadInstalledVersion = { return '26.2.22031.0' }
    $script:ListMsiProducts = {
        $script:ProductListCalls++
        return @()
    }
    $script:StartProcess = {
        param(
            [string]$FilePath,
            [string[]]$ArgumentList
        )
        $argsCopy = [System.Collections.Generic.List[string]]::new()
        foreach ($item in @($ArgumentList)) {
            if ($null -eq $item) {
                continue
            }
            $argsCopy.Add([string]$item)
        }
        $script:ProcessCalls.Add([pscustomobject]@{
                FilePath     = [string]$FilePath
                ArgumentList = $argsCopy.ToArray()
            })
        return [int]$script:ProcessExit
    }
}

function Get-MarkerText {
    $path = Join-Path $script:MarkerRoot 'marker.txt'
    if (-not (Test-Path -LiteralPath $path)) {
        return ''
    }
    return [System.IO.File]::ReadAllText($path)
}

function Get-LogText {
    $path = Join-Path $script:MarkerRoot 'toolkit.log'
    if (-not (Test-Path -LiteralPath $path)) {
        return ''
    }
    return [System.IO.File]::ReadAllText($path)
}

function Assert-InstallCall {
    param([string]$Label)
    if ($script:ProcessCalls.Count -ne 1) {
        Fail "$Label started $($script:ProcessCalls.Count) processes"
    }
    $call = $script:ProcessCalls[0]
    if ([string]$call.FilePath -cne $script:InstallerPath) {
        Fail "$Label file path $($call.FilePath)"
    }
    $actual = @($call.ArgumentList)
    if ($actual.Count -ne 4) {
        Fail "$Label arguments $($actual -join ' ')"
    }
    for ($i = 0; $i -lt 4; $i++) {
        if ([string]$actual[$i] -cne $expectedInstallArgs[$i]) {
            Fail "$Label arguments $($actual -join ' ')"
        }
    }
    if ($actual -contains $script:InstallerPath) {
        Fail "$Label put the installer path in the argument list"
    }
}

Reset-Action
$code = Invoke-AdobeReaderAction -Action 'Install' -PinVersion '' -InstalledVersion $newer -MarkerRoot $script:MarkerRoot -InstallerUrl 'https://example.invalid/AcroRdrDCx642600222031_en_US.exe' -InstallerSha256 $goodSha -InstallerPath $script:InstallerPath
if ($code -ne 0 -or $script:DownloadCount -ne 0 -or $script:ProcessCalls.Count -ne 0) {
    Fail "empty pin action returned $code after $($script:DownloadCount) downloads and $($script:ProcessCalls.Count) processes"
}

Reset-Action -MarkerText $pin
$code = Invoke-AdobeReaderAction -Action 'Update' -PinVersion $pin -InstalledVersion $newer -MarkerRoot $script:MarkerRoot -InstallerUrl 'https://example.invalid/AcroRdrDCx642600222031_en_US.exe' -InstallerSha256 $goodSha -InstallerPath $script:InstallerPath
if ($code -ne 0 -or $script:DownloadCount -ne 0 -or $script:ProcessCalls.Count -ne 0) {
    Fail "vendor-newer action returned $code after $($script:DownloadCount) downloads and $($script:ProcessCalls.Count) processes"
}
if ((Get-MarkerText) -cne $newer) {
    Fail "vendor-newer marker is '$(Get-MarkerText)'"
}
if ((Get-LogText) -ne '') {
    Fail "vendor-newer logged '$(Get-LogText)'"
}

Reset-Action
$code = Invoke-AdobeReaderAction -Action 'Install' -PinVersion $pin -InstalledVersion '' -MarkerRoot $script:MarkerRoot -InstallerUrl 'https://example.invalid/AcroRdrDCx642600222031_en_US.exe' -InstallerSha256 $goodSha -InstallerPath $script:InstallerPath
if ($code -ne 0 -or $script:DownloadCount -ne 1) {
    Fail "install returned $code after $($script:DownloadCount) downloads"
}
Assert-InstallCall -Label 'install'
if ((Get-MarkerText) -cne $pin) {
    Fail "install marker is '$(Get-MarkerText)'"
}
if ((Get-LogText) -cne "Install`n") {
    Fail "install log is '$(Get-LogText)'"
}

Reset-Action
$code = Invoke-AdobeReaderAction -Action 'Update' -PinVersion $pin -InstalledVersion $older -MarkerRoot $script:MarkerRoot -InstallerUrl 'https://example.invalid/AcroRdrDCx642600222031_en_US.exe' -InstallerSha256 $goodSha -InstallerPath $script:InstallerPath
if ($code -ne 0 -or (Get-LogText) -cne "Install`n") {
    Fail "update log is '$(Get-LogText)' code $code"
}
Assert-InstallCall -Label 'update'

Reset-Action
$script:ReadInstalledVersion = { return $newer }
$code = Invoke-AdobeReaderAction -Action 'Install' -PinVersion $pin -InstalledVersion '' -MarkerRoot $script:MarkerRoot -InstallerUrl 'https://example.invalid/AcroRdrDCx642600222031_en_US.exe' -InstallerSha256 $goodSha -InstallerPath $script:InstallerPath
if ($code -ne 0 -or (Get-MarkerText) -cne $newer -or (Get-LogText) -cne "Install`n") {
    Fail "post-install vendor-newer marker '$(Get-MarkerText)' log '$(Get-LogText)' code $code"
}

Reset-Action
$code = Invoke-AdobeReaderAction -Action 'Repair' -PinVersion $pin -InstalledVersion '' -MarkerRoot $script:MarkerRoot -InstallerUrl 'https://example.invalid/AcroRdrDCx642600222031_en_US.exe' -InstallerSha256 $goodSha -InstallerPath $script:InstallerPath
if ($code -ne 0 -or $script:DownloadCount -ne 1) {
    Fail "repair missing returned $code after $($script:DownloadCount) downloads"
}
Assert-InstallCall -Label 'repair'
if ((Get-MarkerText) -cne $pin) {
    Fail "repair marker is '$(Get-MarkerText)'"
}
if ((Get-LogText) -cne "Repair`n") {
    Fail "repair log is '$(Get-LogText)'"
}

Reset-Action -MarkerText $pin
$code = Invoke-AdobeReaderAction -Action 'Repair' -PinVersion $pin -InstalledVersion $newer -MarkerRoot $script:MarkerRoot -InstallerUrl 'https://example.invalid/AcroRdrDCx642600222031_en_US.exe' -InstallerSha256 $goodSha -InstallerPath $script:InstallerPath
if ($code -ne 0 -or $script:DownloadCount -ne 0 -or $script:ProcessCalls.Count -ne 0 -or (Get-MarkerText) -cne $newer -or (Get-LogText) -ne '') {
    Fail "repair vendor-newer marker '$(Get-MarkerText)' log '$(Get-LogText)' code $code"
}

Reset-Action
$script:ProcessExit = 3010
$code = Invoke-AdobeReaderAction -Action 'Install' -PinVersion $pin -InstalledVersion '' -MarkerRoot $script:MarkerRoot -InstallerUrl 'https://example.invalid/AcroRdrDCx642600222031_en_US.exe' -InstallerSha256 $goodSha -InstallerPath $script:InstallerPath
if ($code -ne 0 -or (Get-MarkerText) -cne $pin) {
    Fail "3010 returned $code marker '$(Get-MarkerText)'"
}

Reset-Action
$script:ProcessExit = 1603
$code = Invoke-AdobeReaderAction -Action 'Install' -PinVersion $pin -InstalledVersion '' -MarkerRoot $script:MarkerRoot -InstallerUrl 'https://example.invalid/AcroRdrDCx642600222031_en_US.exe' -InstallerSha256 $goodSha -InstallerPath $script:InstallerPath
if ($code -ne 1 -or (Get-MarkerText) -ne '' -or (Get-LogText) -ne '') {
    Fail "1603 returned $code marker '$(Get-MarkerText)' log '$(Get-LogText)'"
}

Reset-Action -MarkerText $pin
$script:ListMsiProducts = {
    $script:ProductListCalls++
    return @(
        [pscustomobject]@{ DisplayName = 'Adobe Acrobat Pro DC'; ProductCode = $proDcCode; DisplayVersion = '99.0.0.0' }
        [pscustomobject]@{ DisplayName = 'Adobe Acrobat Reader DC'; ProductCode = $readerDcCode; DisplayVersion = $pin }
        [pscustomobject]@{ DisplayName = 'Adobe Acrobat'; ProductCode = $acrobatCode; DisplayVersion = '99.0.0.0' }
        [pscustomobject]@{ DisplayName = 'Adobe Acrobat Reader'; ProductCode = $readerCode; DisplayVersion = $older }
        [pscustomobject]@{ DisplayName = 'Notepad'; ProductCode = $notepadCode; DisplayVersion = '10.0.0.0' }
    )
}
$code = Invoke-AdobeReaderAction -Action 'Uninstall' -PinVersion $pin -InstalledVersion $pin -MarkerRoot $script:MarkerRoot -InstallerUrl 'https://example.invalid/AcroRdrDCx642600222031_en_US.exe' -InstallerSha256 $goodSha -InstallerPath $script:InstallerPath
if ($code -ne 0 -or $script:DownloadCount -ne 0 -or $script:ProcessCalls.Count -ne 2) {
    Fail "uninstall returned $code after $($script:DownloadCount) downloads and $($script:ProcessCalls.Count) processes"
}
$seenCodes = [System.Collections.Generic.List[string]]::new()
foreach ($call in $script:ProcessCalls) {
    if ([string]$call.FilePath -cne $msiexecPath) {
        Fail "uninstall file path $($call.FilePath)"
    }
    $actual = @($call.ArgumentList)
    if ($actual.Count -ne 3 -or [string]$actual[0] -cne '/x' -or [string]$actual[2] -cne '/qn') {
        Fail "uninstall arguments $($actual -join ' ')"
    }
    $seenCodes.Add([string]$actual[1])
}
if ($seenCodes[0] -cne $readerDcCode -or $seenCodes[1] -cne $readerCode) {
    Fail "uninstall codes $($seenCodes -join ',')"
}
foreach ($bannedCode in @($acrobatCode, $proDcCode, $notepadCode)) {
    if ($seenCodes -contains $bannedCode) {
        Fail "uninstall removed $bannedCode"
    }
}
if (Test-Path -LiteralPath (Join-Path $script:MarkerRoot 'marker.txt')) {
    Fail 'uninstall left the marker'
}
if ((Get-LogText) -cne "Uninstall`n") {
    Fail "uninstall log is '$(Get-LogText)'"
}

Reset-Action -MarkerText $pin
$code = Invoke-AdobeReaderAction -Action 'Uninstall' -PinVersion $pin -InstalledVersion '' -MarkerRoot $script:MarkerRoot -InstallerUrl 'https://example.invalid/AcroRdrDCx642600222031_en_US.exe' -InstallerSha256 $goodSha -InstallerPath $script:InstallerPath
if ($code -ne 0 -or $script:ProcessCalls.Count -ne 0 -or $script:ProductListCalls -ne 0 -or (Test-Path -LiteralPath (Join-Path $script:MarkerRoot 'marker.txt')) -or (Get-LogText) -cne "Uninstall`n") {
    Fail "marker-only uninstall code $code processes $($script:ProcessCalls.Count) log '$(Get-LogText)'"
}

Reset-Action -MarkerText $pin
$script:ListMsiProducts = {
    $script:ProductListCalls++
    return @([pscustomobject]@{ DisplayName = 'Adobe Acrobat'; ProductCode = $acrobatCode; DisplayVersion = '99.0.0.0' })
}
$code = Invoke-AdobeReaderAction -Action 'Uninstall' -PinVersion $pin -InstalledVersion $pin -MarkerRoot $script:MarkerRoot -InstallerUrl 'https://example.invalid/AcroRdrDCx642600222031_en_US.exe' -InstallerSha256 $goodSha -InstallerPath $script:InstallerPath
if ($code -ne 1 -or $script:ProcessCalls.Count -ne 0 -or (Get-MarkerText) -cne $pin) {
    Fail "acrobat-only uninstall returned $code marker '$(Get-MarkerText)'"
}

Reset-Action -MarkerText $pin
$code = Invoke-AdobeReaderAction -Action 'Uninstall' -PinVersion $pin -InstalledVersion $pin -MarkerRoot $script:MarkerRoot -InstallerUrl 'https://example.invalid/AcroRdrDCx642600222031_en_US.exe' -InstallerSha256 '' -InstallerPath $script:InstallerPath
if ($code -ne 0 -or $script:DownloadCount -ne 0 -or $script:ProcessCalls.Count -ne 0 -or $script:ProductListCalls -ne 0 -or (Get-MarkerText) -cne $pin) {
    Fail "empty-hash uninstall returned $code marker '$(Get-MarkerText)' downloads $($script:DownloadCount) processes $($script:ProcessCalls.Count)"
}

Reset-Action -MarkerText $pin
$code = Invoke-AdobeReaderAction -Action 'Reinstall' -PinVersion $pin -InstalledVersion $pin -MarkerRoot $script:MarkerRoot -InstallerUrl (New-AdobeReaderUserInfoUrl) -InstallerSha256 '' -InstallerPath $script:InstallerPath
if ($code -ne 0 -or $script:DownloadCount -ne 0 -or $script:ProcessCalls.Count -ne 0 -or (Get-MarkerText) -cne $pin) {
    Fail "empty-hash Reinstall returned $code marker '$(Get-MarkerText)'"
}

Reset-Action -MarkerText $pin
$code = Invoke-AdobeReaderAction -Action 'Uninstall' -PinVersion $pin -InstalledVersion $pin -MarkerRoot $script:MarkerRoot -InstallerUrl (New-AdobeReaderUserInfoUrl) -InstallerSha256 $goodSha -InstallerPath $script:InstallerPath
if ($code -ne 1 -or $script:DownloadCount -ne 0 -or $script:ProcessCalls.Count -ne 0 -or (Get-MarkerText) -cne $pin) {
    Fail "userinfo uninstall returned $code marker '$(Get-MarkerText)'"
}
if (($script:AdobeReaderErrorLog -join "`n") -like '*https://*') {
    Fail 'userinfo error included a URL'
}

Reset-Action -MarkerText $pin
$script:DownloadFile = {
    param($Url, $Destination)
    $script:DownloadCount++
    [System.IO.File]::WriteAllBytes($Destination, $utf8.GetBytes('other'))
}
$code = Invoke-AdobeReaderAction -Action 'Install' -PinVersion $pin -InstalledVersion '' -MarkerRoot $script:MarkerRoot -InstallerUrl 'https://example.invalid/AcroRdrDCx642600222031_en_US.exe' -InstallerSha256 $goodSha -InstallerPath $script:InstallerPath
if ($code -ne 1 -or $script:DownloadCount -ne 1 -or $script:ProcessCalls.Count -ne 0 -or (Get-MarkerText) -cne $pin) {
    Fail "mismatch action returned $code after $($script:ProcessCalls.Count) processes marker '$(Get-MarkerText)'"
}

Reset-Action
foreach ($badHash in @(('0' * 64), ('a' * 64), $goodSha.ToUpperInvariant())) {
    $code = Invoke-AdobeReaderAction -Action 'Install' -PinVersion $pin -InstalledVersion '' -MarkerRoot $script:MarkerRoot -InstallerUrl 'https://example.invalid/AcroRdrDCx642600222031_en_US.exe' -InstallerSha256 $badHash -InstallerPath $script:InstallerPath
    if ($code -ne 1 -or $script:DownloadCount -ne 0 -or $script:ProcessCalls.Count -ne 0) {
        Fail "bad hash action returned $code after $($script:DownloadCount) downloads"
    }
}

Reset-Action -MarkerText $pin
$code = Invoke-AdobeReaderAction -Action 'Reinstall' -PinVersion $pin -InstalledVersion $pin -MarkerRoot $script:MarkerRoot -InstallerUrl 'https://example.invalid/AcroRdrDCx642600222031_en_US.exe' -InstallerSha256 $goodSha -InstallerPath $script:InstallerPath
if ($code -ne 1 -or $script:DownloadCount -ne 0 -or $script:ProcessCalls.Count -ne 0 -or (Get-MarkerText) -cne $pin) {
    Fail "Reinstall action returned $code marker '$(Get-MarkerText)'"
}

$keptTest = $env:RELIAN_DEPLOY_TEST
Remove-Item -LiteralPath 'Env:RELIAN_DEPLOY_TEST' -ErrorAction SilentlyContinue
$processMarker = Join-Path $root 'process-marker'
New-Item -ItemType Directory -Path $processMarker -Force | Out-Null
$processFile = Join-Path $processMarker 'marker.txt'
[System.IO.File]::WriteAllText($processFile, '9.9.9.9', $utf8)

$reinstallOutput = & pwsh -NoProfile -File $scriptPath -DeploymentType 'Install' -Action 'Reinstall' -PinVersion $pin -MarkerRoot $processMarker -InstallerUrl 'https://example.invalid/AcroRdrDCx642600222031_en_US.exe' -InstallerSha256 $expectedSha 2>&1 | Out-String
if ($LASTEXITCODE -ne 1) {
    Fail "Reinstall process exited $LASTEXITCODE"
}
if ($reinstallOutput -match 'PSAppDeployToolkit') {
    Fail 'Reinstall process reached PSAppDeployToolkit'
}
if ([System.IO.File]::ReadAllText($processFile) -cne '9.9.9.9') {
    Fail 'Reinstall process changed the marker'
}

& pwsh -NoProfile -File $scriptPath -DeploymentType 'Install' -Action 'Install' -PinVersion '' -MarkerRoot $processMarker -InstallerUrl 'https://example.invalid/AcroRdrDCx642600222031_en_US.exe' -InstallerSha256 $expectedSha
if ($LASTEXITCODE -ne 0) {
    Fail "empty pin process exited $LASTEXITCODE"
}
if ([System.IO.File]::ReadAllText($processFile) -cne '9.9.9.9') {
    Fail 'empty pin process changed the marker'
}

$emptyHashOutput = & pwsh -NoProfile -File $scriptPath -DeploymentType 'Install' -Action 'Uninstall' -PinVersion $pin -MarkerRoot $processMarker -InstallerUrl 'https://example.invalid/AcroRdrDCx642600222031_en_US.exe' -InstallerSha256 '' 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) {
    Fail "empty hash process exited $LASTEXITCODE"
}
if ($emptyHashOutput -match 'PSAppDeployToolkit') {
    Fail 'empty hash process reached PSAppDeployToolkit'
}
if ([System.IO.File]::ReadAllText($processFile) -cne '9.9.9.9') {
    Fail 'empty hash process changed the marker'
}

$userInfoOutput = & pwsh -NoProfile -File $scriptPath -DeploymentType 'Install' -Action 'Install' -PinVersion $pin -MarkerRoot $processMarker -InstallerUrl (New-AdobeReaderUserInfoUrl) -InstallerSha256 $expectedSha 2>&1 | Out-String
if ($LASTEXITCODE -ne 1) {
    Fail "userinfo process exited $LASTEXITCODE"
}
if ($userInfoOutput -notlike '*refusing a URL that contains userinfo for installer*') {
    Fail 'userinfo process did not report the refusal'
}
if ($userInfoOutput -like '*https://*') {
    Fail 'userinfo process included a URL'
}
if ([System.IO.File]::ReadAllText($processFile) -cne '9.9.9.9') {
    Fail 'userinfo process changed the marker'
}

$placeholderOutput = & pwsh -NoProfile -File $scriptPath -DeploymentType 'Install' -Action 'Install' -PinVersion $pin -MarkerRoot $processMarker -InstallerUrl 'https://example.invalid/AcroRdrDCx642600222031_en_US.exe' -InstallerSha256 ('0' * 64) 2>&1 | Out-String
if ($LASTEXITCODE -ne 1) {
    Fail "placeholder hash process exited $LASTEXITCODE"
}
if ($placeholderOutput -notlike '*installer hash is not a 64-character lowercase hex pin*') {
    Fail 'placeholder hash process did not report the hash'
}
if ($placeholderOutput -match 'PSAppDeployToolkit') {
    Fail 'placeholder hash process reached PSAppDeployToolkit'
}

$env:RELIAN_DEPLOY_TEST = '1'
& pwsh -NoProfile -File $scriptPath -DeploymentType 'Install' -Action 'Reinstall' -PinVersion $pin -MarkerRoot $processMarker -InstallerUrl 'https://example.invalid/AcroRdrDCx642600222031_en_US.exe' -InstallerSha256 $expectedSha
if ($LASTEXITCODE -ne 0) {
    Fail "test-mode Reinstall process exited $LASTEXITCODE"
}
if ([System.IO.File]::ReadAllText($processFile) -cne '9.9.9.9') {
    Fail 'test-mode Reinstall process changed the marker'
}
if ($null -ne $keptTest) {
    $env:RELIAN_DEPLOY_TEST = $keptTest
}

Remove-Item -LiteralPath $root -Recurse -Force
Write-Output 'adobe-reader-plan tests passed'
exit 0
