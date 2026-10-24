$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$cpuPath = Join-Path $repoRoot 'windows/collectors/cpu-benchmark.ps1'
$hardwarePath = Join-Path $repoRoot 'windows/collectors/hardware-inventory.ps1'
$networkPath = Join-Path $repoRoot 'windows/collectors/network-audit.ps1'
$storagePath = Join-Path $repoRoot 'windows/collectors/storage-health.ps1'
$bootstrapPath = Join-Path $repoRoot 'windows/bootstrap.ps1'
$readmePath = Join-Path $repoRoot 'README.md'

function Fail {
    param([Parameter(Mandatory)][string]$Message)
    [Console]::Error.WriteLine("FAIL $Message")
    exit 1
}

function Get-Sha256Hex {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '')
    } finally {
        $sha.Dispose()
    }
}

function ConvertTo-ScriptArguments {
    param([Parameter(Mandatory)][string]$Json)
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($Json)
    return [Convert]::ToBase64String($bytes)
}

function Assert-FileParamHasNoMandatory {
    param([Parameter(Mandatory)][string]$Path)
    $text = [System.IO.File]::ReadAllText($Path)
    $paramAt = $text.IndexOf('param(')
    if ($paramAt -lt 0) {
        Fail "no file param in $Path"
    }
    $functionAt = $text.IndexOf('function ', $paramAt)
    if ($functionAt -lt 0) {
        Fail "no function after param in $Path"
    }
    $between = $text.Substring($paramAt, $functionAt - $paramAt)
    if ($between.Contains('Mandatory')) {
        Fail "Mandatory in file param of $Path"
    }
}

function Assert-TextExcludes {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$Needle
    )
    $text = [System.IO.File]::ReadAllText($Path)
    foreach ($item in $Needle) {
        if ($text.Contains($item)) {
            Fail "$Path contains $item"
        }
    }
}

function Invoke-BootstrapProcess {
    param([AllowEmptyCollection()][string[]]$Argument = @())
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = 'pwsh'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = $repoRoot
    $psi.ArgumentList.Add('-NoProfile')
    $psi.ArgumentList.Add('-NonInteractive')
    $psi.ArgumentList.Add('-File')
    $psi.ArgumentList.Add($bootstrapPath)
    if ($psi.Environment.ContainsKey('RELIAN_DEPLOY_TEST')) {
        [void]$psi.Environment.Remove('RELIAN_DEPLOY_TEST')
    }
    foreach ($arg in @($Argument)) {
        $psi.ArgumentList.Add($arg)
    }
    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi
    try {
        [void]$proc.Start()
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()
        [void]$proc.WaitForExit()
        return @{
            ExitCode = [int]$proc.ExitCode
            Stdout = [string]$stdoutTask.Result
            Stderr = [string]$stderrTask.Result
        }
    } finally {
        $proc.Dispose()
    }
}

$env:RELIAN_DEPLOY_TEST = '1'
. $cpuPath
. $hardwarePath
. $networkPath
. $storagePath
. $bootstrapPath

foreach ($name in @(
        'Invoke-CpuBenchmark',
        'New-CpuBenchmarkResult',
        'Invoke-HardwareInventory',
        'New-NetworkAuditResult',
        'New-StorageHealthResult',
        'Test-CollectorBootstrapUrl',
        'Get-CollectorBootstrapPlan',
        'Invoke-CollectorBootstrapDownload',
        'Invoke-CollectorBootstrap'
    )) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
        Fail "missing command $name"
    }
}

$sharedBan = @(
    'Ninja-Property-Get',
    'Ninja-Property-Set',
    'relian_git_deploy_token',
    'BENCHMARK_RESULT:',
    'INVENTORY_RESULT:',
    'NETWORK_AUDIT_RESULT:',
    'STORAGE_HEALTH_RESULT:'
)
foreach ($path in @($cpuPath, $hardwarePath, $networkPath, $storagePath, $bootstrapPath)) {
    Assert-TextExcludes -Path $path -Needle $sharedBan
    Assert-FileParamHasNoMandatory -Path $path
}
Assert-TextExcludes -Path $bootstrapPath -Needle @(
    'relian_last_collection',
    'relian_cpu_benchmark',
    'relian_hardware_inventory',
    'relian_network_audit',
    'relian_storage_health',
    'git clone',
    'Authorization',
    'ScriptName',
    'RepoUrl'
)

$script:cpuInfo = @{
    cpuModel = 'Test CPU'
    cores = 4
    threads = 8
    baseClock = 2400
    maxClock = 3800
    architecture = 'AMD64'
}
$script:singleCalls = 0
$script:multiCalls = 0
$script:multiThreads = $null

function Get-CpuInfo {
    return $script:cpuInfo
}

function Get-SingleThreadScore {
    $script:singleCalls = $script:singleCalls + 1
    return 11
}

function Get-MultiThreadScore {
    param([int]$ThreadCount)
    $script:multiCalls = $script:multiCalls + 1
    $script:multiThreads = $ThreadCount
    return 22
}

function ConvertFrom-CpuJson {
    param([Parameter(Mandatory)]$Output)
    $items = @($Output)
    if ($items.Count -ne 1) {
        Fail "expected one success object, got $($items.Count)"
    }
    $text = [string]$items[0]
    if ($text -match 'RESULT:') {
        Fail "success output is a RESULT line: $text"
    }
    if ($text -notmatch '^\{.*\}$') {
        Fail "success output is not one JSON object: $text"
    }
    if ($text -notmatch '"timestamp":"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z"') {
        Fail "cpu timestamp text missing in $text"
    }
    return ($text | ConvertFrom-Json)
}

$skipped = ConvertFrom-CpuJson (Invoke-CpuBenchmark -SkipBenchmark)
if ($script:singleCalls -ne 0 -or $script:multiCalls -ne 0) {
    Fail 'SkipBenchmark called a score function'
}
if ($null -ne $skipped.singleThread -or $null -ne $skipped.multiThread) {
    Fail 'SkipBenchmark scores were not null'
}
if ([string]$skipped.cpuModel -ne 'Test CPU') {
    Fail 'SkipBenchmark dropped cpuModel'
}
if ([string]$skipped.version -ne '1.0') {
    Fail "cpu version '$($skipped.version)'"
}
if ($null -eq $skipped.timestamp) {
    Fail 'cpu timestamp was null'
}

$scored = ConvertFrom-CpuJson (Invoke-CpuBenchmark)
if ($script:singleCalls -ne 1 -or $script:multiCalls -ne 1) {
    Fail "score calls single=$($script:singleCalls) multi=$($script:multiCalls)"
}
if ([int]$script:multiThreads -ne 8) {
    Fail "multi-thread count '$($script:multiThreads)'"
}
if ([int]$scored.singleThread -ne 11 -or [int]$scored.multiThread -ne 22) {
    Fail 'benchmark scores were not 11 and 22'
}
if ([string]$scored.version -ne '1.0') {
    Fail 'scored cpu version'
}

$script:hwCalls = @{
    Cpu = 0
    Memory = 0
    Storage = 0
    Motherboard = 0
    Gpu = 0
    Network = 0
    Battery = 0
}

function Get-CpuDetails {
    $script:hwCalls.Cpu = $script:hwCalls.Cpu + 1
    return @{ ok = $true }
}
function Get-MemoryDetails {
    $script:hwCalls.Memory = $script:hwCalls.Memory + 1
    return @{ ok = $true }
}
function Get-StorageDetails {
    $script:hwCalls.Storage = $script:hwCalls.Storage + 1
    return @{ ok = $true }
}
function Get-MotherboardDetails {
    $script:hwCalls.Motherboard = $script:hwCalls.Motherboard + 1
    return @{ ok = $true }
}
function Get-GpuDetails {
    $script:hwCalls.Gpu = $script:hwCalls.Gpu + 1
    return @{ ok = $true }
}
function Get-NetworkDetails {
    $script:hwCalls.Network = $script:hwCalls.Network + 1
    return @{ ok = $true }
}
function Get-BatteryDetails {
    $script:hwCalls.Battery = $script:hwCalls.Battery + 1
    return @{ ok = $true }
}

function Reset-HardwareCalls {
    foreach ($key in @($script:hwCalls.Keys)) {
        $script:hwCalls[$key] = 0
    }
}

function Assert-HardwareCalls {
    param([AllowEmptyCollection()][string[]]$Expected = @())
    foreach ($key in @($script:hwCalls.Keys)) {
        $want = 0
        if ($Expected -contains $key) {
            $want = 1
        }
        if ([int]$script:hwCalls[$key] -ne $want) {
            Fail "section $key calls=$($script:hwCalls[$key]) expected $want"
        }
    }
}

Reset-HardwareCalls
$memoryOnly = @(Invoke-HardwareInventory -Section 'Memory')
if ($memoryOnly.Count -ne 1) {
    Fail 'memory inventory did not emit one object'
}
$memoryJson = [string]$memoryOnly[0] | ConvertFrom-Json
Assert-HardwareCalls -Expected @('Memory')
foreach ($key in @('cpu', 'storage', 'motherboard', 'gpu', 'network', 'battery')) {
    if ($null -ne $memoryJson.$key) {
        Fail "memory inventory kept $key"
    }
}
if ($null -eq $memoryJson.memory) {
    Fail 'memory section was null'
}

Reset-HardwareCalls
$cpuGpu = @(Invoke-HardwareInventory -Section 'cpu,Gpu')
if ($cpuGpu.Count -ne 1) {
    Fail 'cpu,Gpu inventory did not emit one object'
}
$cpuGpuJson = [string]$cpuGpu[0] | ConvertFrom-Json
Assert-HardwareCalls -Expected @('Cpu', 'Gpu')
if ($null -eq $cpuGpuJson.cpu -or $null -eq $cpuGpuJson.gpu) {
    Fail 'cpu,Gpu dropped a requested section'
}
if ($null -ne $cpuGpuJson.memory) {
    Fail 'cpu,Gpu called memory'
}

Reset-HardwareCalls
$diskWrote = [System.Collections.Generic.List[object]]::new()
$diskThrew = $false
try {
    Invoke-HardwareInventory -Section 'Disk' | ForEach-Object { [void]$diskWrote.Add($_) }
} catch {
    $diskThrew = $true
}
if (-not $diskThrew) {
    Fail 'invalid section did not throw'
}
if ($diskWrote.Count -ne 0) {
    Fail 'invalid section wrote JSON'
}
Assert-HardwareCalls -Expected @()

Reset-HardwareCalls
$emptySection = @(Invoke-HardwareInventory -Section '')
if ($emptySection.Count -ne 1) {
    Fail 'empty section list did not emit one object'
}
Assert-HardwareCalls -Expected @('Cpu', 'Memory', 'Storage', 'Motherboard', 'Gpu', 'Network', 'Battery')

Reset-HardwareCalls
$blankTokenWrote = [System.Collections.Generic.List[object]]::new()
$blankTokenThrew = $false
try {
    Invoke-HardwareInventory -Section 'Cpu,' | ForEach-Object { [void]$blankTokenWrote.Add($_) }
} catch {
    $blankTokenThrew = $true
}
if (-not $blankTokenThrew) {
    Fail 'empty section token did not throw'
}
if ($blankTokenWrote.Count -ne 0) {
    Fail 'empty section token wrote JSON'
}
Assert-HardwareCalls -Expected @()

$networkAdapters = @(
    @{
        name = 'Ethernet'
        status = 'Connected'
        type = 'Ethernet'
        dnsServers = @('10.0.0.1')
    },
    @{
        name = 'Wi-Fi Adapter'
        status = 'Connected'
        type = 'WiFi'
        dnsServers = @('10.0.0.2')
    }
)

$allNet = (New-NetworkAuditResult -Adapters $networkAdapters -AdapterName '') | ConvertFrom-Json
if ([int]$allNet.totalAdapters -ne 2) {
    Fail "empty adapter filter total=$($allNet.totalAdapters)"
}
$allNetNames = @(@($allNet.adapters) | ForEach-Object { [string]$_.name })
if ($allNetNames -notcontains 'Ethernet' -or $allNetNames -notcontains 'Wi-Fi Adapter') {
    Fail 'empty adapter filter dropped an adapter'
}

$oneNet = (New-NetworkAuditResult -Adapters $networkAdapters -AdapterName 'ethernet') | ConvertFrom-Json
$oneNetAdapters = @($oneNet.adapters)
if ($oneNetAdapters.Count -ne 1) {
    Fail "ethernet filter count=$($oneNetAdapters.Count)"
}
if ([string]$oneNetAdapters[0].name -ne 'Ethernet') {
    Fail 'ethernet filter kept the wrong adapter'
}
if ($oneNet.hasEthernet -ne $true -or $oneNet.hasWifi -ne $false) {
    Fail 'ethernet filter flags'
}
if ([string]$oneNet.primaryDns -ne '10.0.0.1') {
    Fail "ethernet primary DNS '$($oneNet.primaryDns)'"
}

$missingNet = (New-NetworkAuditResult -Adapters $networkAdapters -AdapterName 'missing') | ConvertFrom-Json
if ([int]$missingNet.totalAdapters -ne 0) {
    Fail 'missing adapter filter was not empty'
}
if ($null -ne $missingNet.primaryDns) {
    Fail 'missing adapter filter kept primary DNS'
}
if ($missingNet.hasEthernet -ne $false -or $missingNet.hasWifi -ne $false) {
    Fail 'missing adapter filter flags'
}

$storageDrives = @(
    @{
        DiskNumber = '0'
        smartStatus = 'OK'
        model = 'disk-zero'
    },
    @{
        DiskNumber = '1'
        smartStatus = 'Warning'
        model = 'disk-one'
    }
)

$allStorageText = [string](New-StorageHealthResult -Drives $storageDrives -DiskNumber '')
if ($allStorageText.Contains('DiskNumber')) {
    Fail 'storage JSON included DiskNumber'
}
$allStorage = $allStorageText | ConvertFrom-Json
if ([int]$allStorage.totalDrives -ne 2) {
    Fail "storage total=$($allStorage.totalDrives)"
}
if ([string]$allStorage.healthySummary -ne '1/2 healthy') {
    Fail "storage summary '$($allStorage.healthySummary)'"
}
foreach ($drive in @($allStorage.drives)) {
    foreach ($prop in @($drive.PSObject.Properties.Name)) {
        if ($prop -eq 'DiskNumber') {
            Fail 'parsed storage drive kept DiskNumber'
        }
    }
}

$oneStorage = (New-StorageHealthResult -Drives $storageDrives -DiskNumber '1') | ConvertFrom-Json
if ([int]$oneStorage.totalDrives -ne 1) {
    Fail "disk 1 total=$($oneStorage.totalDrives)"
}
if ([string]$oneStorage.healthySummary -ne '0/1 healthy') {
    Fail "disk 1 summary '$($oneStorage.healthySummary)'"
}
$oneStorageDrives = @($oneStorage.drives)
if ($oneStorageDrives.Count -ne 1 -or [string]$oneStorageDrives[0].model -ne 'disk-one') {
    Fail 'disk 1 filter kept the wrong drive'
}

if (-not (Test-CollectorBootstrapUrl -Url 'https://user:secret@example.com/a.ps1')) {
    Fail 'userinfo URL was not detected'
}
if (Test-CollectorBootstrapUrl -Url 'collectors/cpu-benchmark.ps1') {
    Fail 'relative URL was treated as userinfo'
}

$userInfoPlan = Get-CollectorBootstrapPlan -ScriptUrl 'https://user:secret@example.com/a.ps1' -ScriptSha256 '' -ScriptArguments '@@@'
if ([int]$userInfoPlan.ExitCode -ne 1 -or $userInfoPlan.Download -ne $false -or $null -ne $userInfoPlan.Arguments) {
    Fail 'userinfo plan should exit 1 without download or arguments'
}

$emptyHashPlan = Get-CollectorBootstrapPlan -ScriptUrl 'https://example.com/a.ps1' -ScriptSha256 ' ' -ScriptArguments '@@@'
if ([int]$emptyHashPlan.ExitCode -ne 0 -or $emptyHashPlan.Download -ne $false -or $null -ne $emptyHashPlan.Arguments) {
    Fail 'empty hash plan should exit 0 without reading arguments'
}

$badArgsPlan = Get-CollectorBootstrapPlan -ScriptUrl 'https://example.com/a.ps1' -ScriptSha256 'abc' -ScriptArguments '@@@'
if ([int]$badArgsPlan.ExitCode -ne 1 -or $badArgsPlan.Download -ne $false) {
    Fail 'invalid arguments should exit 1 without download'
}

$actionPlan = Get-CollectorBootstrapPlan -ScriptUrl 'https://example.com/a.ps1' -ScriptSha256 'abc' -ScriptArguments (ConvertTo-ScriptArguments '{"Action":"Install"}')
if ([int]$actionPlan.ExitCode -ne 1 -or $actionPlan.Download -ne $false) {
    Fail 'reserved Action should exit 1'
}

$pairJson = '{"SkipBenchmark":"true","AdapterName":"Ethernet"}'
$pairPlan = Get-CollectorBootstrapPlan -ScriptUrl 'https://example.com/a.ps1' -ScriptSha256 'abc' -ScriptArguments (ConvertTo-ScriptArguments $pairJson)
if ($null -ne $pairPlan.ExitCode -or $pairPlan.Download -ne $true) {
    Fail 'valid arguments should download'
}
$pairs = @($pairPlan.Arguments)
if ($pairs.Count -ne 2) {
    Fail "expected two argument pairs, got $($pairs.Count)"
}
if ([string]$pairs[0].Name -ne 'SkipBenchmark' -or [string]$pairs[0].Value -ne 'true' -or $pairs[0].Value -isnot [string]) {
    Fail 'SkipBenchmark pair was not a string true'
}
if ([string]$pairs[1].Name -ne 'AdapterName' -or [string]$pairs[1].Value -ne 'Ethernet' -or $pairs[1].Value -isnot [string]) {
    Fail 'AdapterName pair was not a string'
}

$emptyArgsPlan = Get-CollectorBootstrapPlan -ScriptUrl 'https://example.com/a.ps1' -ScriptSha256 'abc' -ScriptArguments ''
if ($null -ne $emptyArgsPlan.ExitCode -or $emptyArgsPlan.Download -ne $true) {
    Fail 'empty arguments should still download'
}
if ($null -eq $emptyArgsPlan.Arguments -or @($emptyArgsPlan.Arguments).Count -ne 0) {
    Fail 'empty arguments should be an empty list'
}

$helloBytes = [System.Text.UTF8Encoding]::new($false).GetBytes('hello')
$helloHash = Get-Sha256Hex -Bytes $helloBytes

function New-DownloadTemp {
    return Join-Path ([System.IO.Path]::GetTempPath()) ('collector-stdout-' + [guid]::NewGuid().ToString('n'))
}

function Reset-DownloadStubs {
    param([Parameter(Mandatory)][scriptblock]$Download)
    $script:downloadCalls = 0
    $script:retryDelays = [System.Collections.Generic.List[int]]::new()
    $script:DownloadCollector = $Download
    $script:RetryDelay = {
        param($Seconds)
        [void]$script:retryDelays.Add([int]$Seconds)
    }
}

$dest = New-DownloadTemp
try {
    Reset-DownloadStubs -Download {
        param($Url, $Destination)
        $script:downloadCalls = $script:downloadCalls + 1
        [System.IO.File]::WriteAllBytes($Destination, [byte[]]$script:helloBytes)
    }
    $script:helloBytes = $helloBytes
    $code = [int](Invoke-CollectorBootstrapDownload -Url 'https://example.com/a.ps1' -Destination $dest -ExpectedSha256 $helloHash)
    if ($code -ne 0 -or $script:downloadCalls -ne 1 -or $script:retryDelays.Count -ne 0) {
        Fail "matching hash code=$code calls=$($script:downloadCalls) delays=$($script:retryDelays.Count)"
    }
} finally {
    if (Test-Path -LiteralPath $dest) {
        Remove-Item -LiteralPath $dest -Force
    }
}

$dest = New-DownloadTemp
try {
    Reset-DownloadStubs -Download {
        param($Url, $Destination)
        $script:downloadCalls = $script:downloadCalls + 1
        [System.IO.File]::WriteAllBytes($Destination, [byte[]]$script:helloBytes)
    }
    $code = [int](Invoke-CollectorBootstrapDownload -Url 'https://example.com/a.ps1' -Destination $dest -ExpectedSha256 '00')
    if ($code -ne 1 -or $script:downloadCalls -ne 1) {
        Fail "hash mismatch code=$code calls=$($script:downloadCalls)"
    }
} finally {
    if (Test-Path -LiteralPath $dest) {
        Remove-Item -LiteralPath $dest -Force
    }
}

$dest = New-DownloadTemp
try {
    Reset-DownloadStubs -Download {
        param($Url, $Destination)
        $script:downloadCalls = $script:downloadCalls + 1
        if ($script:downloadCalls -eq 1) {
            throw [System.Net.WebException]::new('timed out', [System.Net.WebExceptionStatus]::Timeout)
        }
        [System.IO.File]::WriteAllBytes($Destination, [byte[]]$script:helloBytes)
    }
    $code = [int](Invoke-CollectorBootstrapDownload -Url 'https://example.com/a.ps1' -Destination $dest -ExpectedSha256 $helloHash)
    $delayText = ($script:retryDelays -join ',')
    if ($code -ne 0 -or $script:downloadCalls -ne 2 -or $delayText -ne '5') {
        Fail "transient retry code=$code calls=$($script:downloadCalls) delays=$delayText"
    }
} finally {
    if (Test-Path -LiteralPath $dest) {
        Remove-Item -LiteralPath $dest -Force
    }
}

$dest = New-DownloadTemp
try {
    Reset-DownloadStubs -Download {
        param($Url, $Destination)
        $script:downloadCalls = $script:downloadCalls + 1
        throw 'plain failure'
    }
    $code = [int](Invoke-CollectorBootstrapDownload -Url 'https://example.com/a.ps1' -Destination $dest -ExpectedSha256 $helloHash)
    if ($code -ne 1 -or $script:downloadCalls -ne 1) {
        Fail "plain failure code=$code calls=$($script:downloadCalls)"
    }
} finally {
    if (Test-Path -LiteralPath $dest) {
        Remove-Item -LiteralPath $dest -Force
    }
}

function Reset-RunStubs {
    param(
        [Parameter(Mandatory)][scriptblock]$Download,
        [Parameter(Mandatory)][scriptblock]$Start
    )
    $script:downloadCalls = 0
    $script:startCalls = 0
    $script:startedNames = [System.Collections.Generic.List[string]]::new()
    $script:DownloadCollector = $Download
    $script:StartCollector = $Start
}

$noDownload = {
    param($Url, $Destination)
    $script:downloadCalls = $script:downloadCalls + 1
    throw 'download was not allowed'
}
$noStart = {
    param($ScriptPath, $Arguments)
    $script:startCalls = $script:startCalls + 1
    return 9
}

Reset-RunStubs -Download $noDownload -Start $noStart
$userInfoCode = [int](Invoke-CollectorBootstrap -ScriptUrl 'https://user:secret@example.com/a.ps1' -ScriptSha256 '' -ScriptArguments '@@@')
if ($userInfoCode -ne 1 -or $script:downloadCalls -ne 0 -or $script:startCalls -ne 0) {
    Fail "userinfo run code=$userInfoCode download=$($script:downloadCalls) start=$($script:startCalls)"
}

Reset-RunStubs -Download $noDownload -Start $noStart
$emptyCode = [int](Invoke-CollectorBootstrap -ScriptUrl 'https://example.com/a.ps1' -ScriptSha256 ' ' -ScriptArguments '@@@')
if ($emptyCode -ne 0 -or $script:downloadCalls -ne 0 -or $script:startCalls -ne 0) {
    Fail "empty hash run code=$emptyCode download=$($script:downloadCalls) start=$($script:startCalls)"
}

Reset-RunStubs -Download $noDownload -Start $noStart
$badRun = [int](Invoke-CollectorBootstrap -ScriptUrl 'https://example.com/a.ps1' -ScriptSha256 'abc' -ScriptArguments '@@@')
if ($badRun -ne 1 -or $script:downloadCalls -ne 0 -or $script:startCalls -ne 0) {
    Fail "invalid argument run code=$badRun download=$($script:downloadCalls) start=$($script:startCalls)"
}

Reset-RunStubs -Download {
    param($Url, $Destination)
    $script:downloadCalls = $script:downloadCalls + 1
    [System.IO.File]::WriteAllBytes($Destination, [byte[]]$script:helloBytes)
} -Start {
    param($ScriptPath, $Arguments)
    $script:startCalls = $script:startCalls + 1
    foreach ($pair in @($Arguments)) {
        [void]$script:startedNames.Add([string]$pair.Name)
    }
    return 7
}
$forwarded = ConvertTo-ScriptArguments $pairJson
$started = [int](Invoke-CollectorBootstrap -ScriptUrl 'https://example.com/a.ps1' -ScriptSha256 $helloHash -ScriptArguments $forwarded)
$startedNames = $script:startedNames -join ','
if ($started -ne 7 -or $script:startCalls -ne 1 -or $startedNames -ne 'SkipBenchmark,AdapterName') {
    Fail "start forwarding code=$started calls=$($script:startCalls) names=$startedNames"
}

Reset-RunStubs -Download {
    param($Url, $Destination)
    $script:downloadCalls = $script:downloadCalls + 1
    [System.IO.File]::WriteAllBytes($Destination, [byte[]]$script:helloBytes)
} -Start $noStart
$mismatchRun = [int](Invoke-CollectorBootstrap -ScriptUrl 'https://example.com/a.ps1' -ScriptSha256 '00' -ScriptArguments '')
if ($mismatchRun -ne 1 -or $script:startCalls -ne 0 -or $script:downloadCalls -ne 1) {
    Fail "run hash mismatch code=$mismatchRun download=$($script:downloadCalls) start=$($script:startCalls)"
}

$missingParams = Invoke-BootstrapProcess
if ($missingParams.ExitCode -ne 1) {
    Fail "bootstrap without parameters exited $($missingParams.ExitCode)"
}

$emptyProcess = Invoke-BootstrapProcess -Argument @(
    '-ScriptUrl', 'https://example.com/cpu-benchmark.ps1',
    '-ScriptSha256', ' '
)
if ($emptyProcess.ExitCode -ne 0) {
    Fail "bootstrap empty hash exited $($emptyProcess.ExitCode) stderr=$($emptyProcess.Stderr)"
}

$userInfoProcess = Invoke-BootstrapProcess -Argument @(
    '-ScriptUrl', 'https://user:secret@example.com/a.ps1',
    '-ScriptSha256', 'abc'
)
if ($userInfoProcess.ExitCode -ne 1) {
    Fail "bootstrap userinfo exited $($userInfoProcess.ExitCode)"
}

$readme = [System.IO.File]::ReadAllText($readmePath)
$collectorsAt = $readme.IndexOf("## Collectors")
$layoutAt = $readme.IndexOf("## Layout")
if ($collectorsAt -lt 0 -or $layoutAt -lt $collectorsAt) {
    Fail 'Collectors section missing'
}
$collectors = $readme.Substring($collectorsAt, $layoutAt - $collectorsAt)
if (-not $collectors.Contains('downloads one collector by URL and SHA256')) {
    Fail 'Collectors section does not describe the URL download'
}
if (-not $collectors.Contains('does not write a NinjaOne field')) {
    Fail 'Collectors section still implies a NinjaOne write'
}
$deployAt = $readme.IndexOf("## Deploy runner")
$shellAt = $readme.IndexOf("## Shell runners")
if ($deployAt -lt 0 -or $shellAt -lt $deployAt) {
    Fail 'Deploy runner section missing'
}
$deploy = $readme.Substring($deployAt, $shellAt - $deployAt)
if (-not $deploy.Contains('bootstrap.ps1 remains the collector loader')) {
    Fail 'deploy runner lost the collector loader sentence'
}

Write-Output 'collector-stdout tests passed'
