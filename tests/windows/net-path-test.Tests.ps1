$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$scriptPath = Join-Path $repoRoot 'windows/packages/net-path-test/Invoke-NetPathTest.ps1'

function Fail {
    param([string]$Message)
    [Console]::Error.WriteLine("FAIL $Message")
    exit 1
}

$env:RELIAN_DEPLOY_TEST = '1'
. $scriptPath

if ((Get-Content -LiteralPath $scriptPath -Raw) -match 'Mandatory\s*=') { Fail 'a parameter is Mandatory' }

# Settings validation.
function New-Settings {
    param([hashtable]$Over = @{})
    $s = [ordered]@{
        TcpTargets = 'fs.corp.example.invalid:445, 192.0.2.10:3389'; DnsNames = 'fs.corp.example.invalid'
        ListPaths = '\\fs.corp.example.invalid\data$'; ReadFiles = '\\fs\data$\_RelianTest\100MB.bin'; WriteTestDirs = '\\files.example.invalid\main\_RelianTest'
        OfficePrefixes = '192.0.2., 198.51.100.'; TunnelName = 'office'; DelayMinutes = '10'; TestFileMB = '100'; MaxFallbackMB = '200'
    }
    foreach ($k in $Over.Keys) { $s[$k] = $Over[$k] }
    return [pscustomobject]$s
}
if ((Get-NptSettingsErrors -Settings (New-Settings)).Count -ne 0) { Fail "good settings rejected: $(Get-NptSettingsErrors -Settings (New-Settings))" }
foreach ($bad in @(
        @{ TcpTargets = '' }, @{ TcpTargets = 'host:99999' }, @{ TcpTargets = 'host 445' }, @{ DnsNames = 'a;b' },
        @{ ListPaths = 'C:\data' }, @{ ReadFiles = '\\fs\data$\..\x' }, @{ WriteTestDirs = '\\fs' }, @{ OfficePrefixes = '192.0.2' },
        @{ TunnelName = 'a b' }, @{ DelayMinutes = '-1' }, @{ TestFileMB = 'x' }, @{ MaxFallbackMB = '0' })) {
    if ((Get-NptSettingsErrors -Settings (New-Settings $bad)).Count -eq 0) { Fail "bad settings accepted: $($bad.Keys) = $($bad.Values)" }
}
if ((Get-NptSettingsErrors -Settings (New-Settings @{ TunnelName = ''; WriteTestDirs = ''; ReadFiles = '' })).Count -ne 0) { Fail 'optional values must be optional' }

# Pure helpers.
if ((Get-NptMedian -Values @(5, 1, 3)) -ne 3) { Fail 'odd median' }
if ((Get-NptMedian -Values @(4, 1, 3, 2)) -ne 2.5) { Fail 'even median' }
if ($null -ne (Get-NptMedian -Values @())) { Fail 'empty median' }
if (-not (Test-NptGsaAddress -Ip '6.6.0.22') -or (Test-NptGsaAddress -Ip '16.6.0.22') -or (Test-NptGsaAddress -Ip '192.0.2.5')) { Fail 'gsa address check' }
if ((Get-NptLocation -Addresses @('203.0.113.9', '192.0.2.44') -Prefixes @('192.0.2.')) -ne 'office') { Fail 'office location' }
if ((Get-NptLocation -Addresses @('10.0.0.84') -Prefixes @('192.0.2.', '198.51.100.')) -ne 'remote') { Fail 'remote location' }

$s = @(Get-NptScenarios -Location 'remote' -HasTunnel $true)
if (($s.Name -join ',') -ne 'gsa,wireguard') { Fail 'remote tunnel scenarios' }
if ($s[0].Tunnel -ne 'Stopped' -or $s[0].PaDisabled -ne 0 -or $s[0].Nrpt -ne 'off' -or -not $s[0].ExpectGsa) { Fail 'remote gsa scenario' }
if ($s[1].Tunnel -ne 'Running' -or $s[1].PaDisabled -ne 1 -or $s[1].Nrpt -ne 'on' -or $s[1].ExpectGsa) { Fail 'wireguard scenario' }
$s = @(Get-NptScenarios -Location 'office' -HasTunnel $true)
if (($s.Name -join ',') -ne 'gsa,direct' -or $s[1].Tunnel -ne 'Stopped' -or $s[1].PaDisabled -ne 1 -or $s[1].Nrpt -ne 'on' -or $s[0].Nrpt -ne 'off') { Fail 'office scenarios with a tunnel' }
$s = @(Get-NptScenarios -Location 'office' -HasTunnel $false)
if ($s[0].Tunnel -ne '' -or $s[1].Tunnel -ne '') { Fail 'no tunnel must leave the tunnel alone' }

$klist = "Cached Tickets: (2)`r`n`r`n#0>`tClient: user @ CORP.EXAMPLE`r`n`tServer: krbtgt/CORP.EXAMPLE @ CORP.EXAMPLE`r`n#1>`tClient: user @ CORP.EXAMPLE`r`n`tServer: cifs/fs.corp.example.invalid @ CORP.EXAMPLE`r`n#2>`tServer: cifs/fs.corp.example.invalid @ CORP.EXAMPLE"
$servers = ConvertFrom-NptKlist -Text $klist
if (($servers -join ',') -ne 'krbtgt/CORP.EXAMPLE,cifs/fs.corp.example.invalid') { Fail "klist parse: $($servers -join ',')" }
if (@(ConvertFrom-NptKlist -Text '').Count -ne 0) { Fail 'empty klist' }

$p = Get-NptPage -Text ('a' * 20001) -Page 3 -Size 9000
if ($p.Pages -ne 3 -or $p.Text.Length -ne 2001) { Fail 'last page' }
if ((Get-NptPage -Text 'abc' -Page 2 -Size 9000).Text -ne '') { Fail 'page past the end' }

$results = '{"computer":"PC1","user":"CORP\\u","runId":"20261116-091000","location":"remote","metered":false,"onBattery":false,
  "scenarios":[{"name":"gsa","error":"","measure":{"settled":true,"settleSeconds":5,"gsaDns":true,"tunnel":"Stopped","paValue":0,
   "dns":[{"name":"fs","answers":["6.6.0.2"]}],"tcp":[{"host":"fs","port":445,"ip":"6.6.0.2","routeInterface":"Wi-Fi","ok":10,"tries":10,"medianMs":80.5,"gsa":true}],
   "lists":[{"path":"\\\\fs\\d","ms":120,"entries":4,"error":""}],"reads":[{"path":"\\\\fs\\d\\f","mb":100,"seconds":20,"mbps":5,"mode":"unbuffered","error":""}],"readsSkipped":"","klist":["krbtgt/X"]}},
   {"name":"wireguard","error":"no measurement","measure":null}],
  "restore":{"errors":[],"verified":true}}' | ConvertFrom-Json
$sum = Get-NptSummary -Results $results
foreach ($needle in @('location=remote', '[gsa] settled=True', 'tcp fs:445 ip=6.6.0.2 if=Wi-Fi ok=10/10 median=80.5ms gsa=True', 'read \\fs\d\f 100MB 20s 5MB/s unbuffered', '[wireguard] no measurement', 'restore errors=[] verify=True')) {
    if ($sum.IndexOf($needle, [System.StringComparison]::Ordinal) -lt 0) { Fail "summary missing $needle" }
}

# Restore: every saved value goes back, a missing value is removed, and one failing step does not stop the rest.
$calls = [System.Collections.Generic.List[string]]::new()
$script:SetPaValue = { param($Sid, $Value) $calls.Add("pa $Sid $(if ($null -eq $Value) { 'remove' } else { $Value })") }
$script:GetNrpt = { @([pscustomobject]@{ Name = 'x'; Namespace = @('.corp.example.invalid'); NameServers = @('192.0.2.5'); Comment = 'Relian WireGuard client: office' }) }
$script:AddNrpt = { param($Rule) $calls.Add("nrpt add $($Rule.Namespace -join ',')") }
$script:RemoveNrpt = { param($Rule) $calls.Add("nrpt remove $($Rule.Name)") }
$script:GetTunnelStatus = { param($Name) 'Stopped' }
$script:SetTunnel = { param($Name, $State) $calls.Add("tunnel $Name $State") }
$script:SetGuardEnabled = { param($Enabled) $calls.Add("guard $Enabled") }
$script:RestartGsa = { throw 'service busy' }
$orig = [pscustomobject]@{
    sid = 'S-1-5-21-1-2-3-1001'; paValue = $null; tunnelName = 'office'; tunnel = 'Running'; guard = 'Ready'
    nrpt = @([pscustomobject]@{ Namespace = @('.corp.example.invalid'); NameServers = @('192.0.2.5'); Comment = 'Relian WireGuard client: office' },
        [pscustomobject]@{ Namespace = @('files.example.invalid'); NameServers = @('192.0.2.5'); Comment = 'Relian WireGuard client: office' })
}
$errs = Invoke-NptRestore -Original $orig
$want = 'pa S-1-5-21-1-2-3-1001 remove|nrpt add files.example.invalid|tunnel office Running|guard True'
if (($calls -join '|') -ne $want) { Fail "restore calls: $($calls -join '|')" }
if (@($errs).Count -ne 1 -or @($errs)[0] -notlike 'gsa: *service busy*') { Fail "restore errors: $($errs -join ';')" }

$calls.Clear()
$script:RestartGsa = { $calls.Add('gsa') }
$orig.paValue = 1; $orig.tunnel = ''; $orig.guard = 'Disabled'; $orig.nrpt = @()
$errs = Invoke-NptRestore -Original $orig
if (($calls -join '|') -ne 'pa S-1-5-21-1-2-3-1001 1|gsa' -or @($errs).Count -ne 0) { Fail "restore without tunnel: $($calls -join '|')" }

# Scenario NRPT switch: off removes only tagged rules the seam returns; on re-adds what is missing.
$calls.Clear()
Set-NptNrpt -On $false -Original @()
if (($calls -join '|') -ne 'nrpt remove x') { Fail "nrpt off: $($calls -join '|')" }

# Recovery of an interrupted run: a failed restore keeps the saved original; a clean one removes it.
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("npt-" + [guid]::NewGuid().ToString('N') + '.json')
try {
    '{"sid":"S-1-5-21-1-2-3-1001","paValue":1,"tunnelName":"","tunnel":"","guard":"","nrpt":[]}' | Set-Content -LiteralPath $tmp
    $script:RestartGsa = { throw 'service busy' }
    if (Invoke-NptRecover -Path $tmp) { Fail 'recover reported clean after a failed restore' }
    if (-not (Test-Path -LiteralPath $tmp)) { Fail 'recover deleted the saved original after a failed restore' }
    $script:RestartGsa = { }
    if (-not (Invoke-NptRecover -Path $tmp)) { Fail 'recover reported failure after a clean restore' }
    if (Test-Path -LiteralPath $tmp) { Fail 'recover kept the saved original after a clean restore' }
    if (-not (Invoke-NptRecover -Path $tmp)) { Fail 'recover without a saved state must be clean' }
} finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }

# Uninstall stops a run in flight and takes its lock before it restores anything.
$src = Get-Content -LiteralPath $scriptPath -Raw
$body = $src.Substring($src.IndexOf('function Invoke-NptUninstall'))
$iStop = $body.IndexOf('Stop-ScheduledTask'); $iLock = $body.IndexOf('run.lock'); $iRecover = $body.IndexOf('Invoke-NptRecover')
if ($iStop -lt 0 -or $iLock -lt $iStop -or $iRecover -lt $iLock) { Fail 'uninstall must stop the tasks, then lock, then restore' }
$iKeep = $body.IndexOf('if (-not $clean) {'); $iRemove = $body.IndexOf('Remove-NptTasks', [math]::Max($iKeep, 0))
if ($iKeep -lt $iRecover -or $iRemove -lt $iKeep -or $body.Substring($iKeep, $iRemove - $iKeep) -notmatch 'return 1') { Fail 'a failed restore must exit 1 before uninstall removes anything' }

# Review fixes that need a device to exercise, held in place by source checks.
if ($src.Contains('IPv4DefaultGateway.NextHop')) { Fail 'a gateway-less adapter would throw under StrictMode' }
if (-not $src.Contains('if ($verified -eq $false) { $errors +=')) { Fail 'a failed restore verification must keep the saved state' }

# Measurement hand-off, report output and exit codes, against a temporary root.
$root = Join-Path ([System.IO.Path]::GetTempPath()) ('npt-root-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $root 'work') -Force | Out-Null
$savedRoot = $script:NptRoot
$script:NptRoot = $root
try {
    # A measurement that fails (here: no settings.json) writes an error file and returns 1.
    $rc = @(Invoke-NptMeasureEntry -Name 'gsa' -Id '20261116-091000' -Expect $true)
    if ($rc.Count -ne 1 -or $rc[0] -ne 1) { Fail "measure entry returned [$rc]" }
    $ef = Join-Path $root 'work/20261116-091000-gsa.json'
    if (-not (Test-Path -LiteralPath $ef) -or -not (Get-Content -LiteralPath $ef -Raw | ConvertFrom-Json).error) { Fail 'failed measurement wrote no error file' }

    # The orchestrator turns that error file into an exception at once, without the timeout.
    $script:StopMeasure = { $calls.Add('stop') }
    $script:StartMeasure = { param($User, $Arguments) Set-Content -LiteralPath (Join-Path $root 'work/20261116-091000-direct.json') -Value '{"scenario":"direct","error":"boom"}' }
    $calls.Clear(); $msg = ''
    try { Invoke-NptUserTask -User 'u' -Name 'direct' -Id '20261116-091000' -Expect $false -TimeoutSeconds 30 -PollSeconds 1 | Out-Null } catch { $msg = $_.Exception.Message }
    if ($msg -ne 'measure: boom') { Fail "error file not raised: [$msg]" }

    # A timeout stops the measurement task before it throws.
    $script:StartMeasure = { param($User, $Arguments) }
    $calls.Clear(); $msg = ''
    try { Invoke-NptUserTask -User 'u' -Name 'gsa' -Id '20261116-091001' -Expect $true -TimeoutSeconds 1 -PollSeconds 1 | Out-Null } catch { $msg = $_.Exception.Message }
    if ($msg -notlike 'no measurement*' -or ($calls -join '|') -ne 'stop') { Fail "timeout did not stop the task: [$msg] [$($calls -join '|')]" }

    # A good measurement comes back as the object.
    $script:StartMeasure = { param($User, $Arguments) Set-Content -LiteralPath (Join-Path $root 'work/20261116-091002-gsa.json') -Value '{"scenario":"gsa","settled":true}' }
    $m = Invoke-NptUserTask -User 'u' -Name 'gsa' -Id '20261116-091002' -Expect $true -TimeoutSeconds 30 -PollSeconds 1
    if (-not $m.settled) { Fail 'measurement object not returned' }

    # Report prints to the console and returns only the exit code.
    $results | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $root 'results-20261116-091000.json')
    $sw = [System.IO.StringWriter]::new(); $orig = [Console]::Out; [Console]::SetOut($sw)
    try { $rc = @(Invoke-NptReport -PageNumber 0); $rc1 = @(Invoke-NptReport -PageNumber 1) } finally { [Console]::SetOut($orig) }
    if ($rc.Count -ne 1 -or $rc[0] -ne 0 -or $rc1.Count -ne 1 -or $rc1[0] -ne 0) { Fail "report returned [$rc] [$rc1]" }
    $printed = $sw.ToString()
    foreach ($needle in @('NETTEST PC1', 'pages=1', 'NETTEST-PAGE 1/1', '"runId"')) {
        if ($printed.IndexOf($needle, [System.StringComparison]::Ordinal) -lt 0) { Fail "report output missing $needle" }
    }
} finally {
    $script:NptRoot = $savedRoot
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

# An empty pin exits 0 before any action, including Uninstall. The child runs the real entry point.
$env:RELIAN_DEPLOY_TEST = $null
foreach ($act in @('Install', 'Uninstall')) {
    $out = & pwsh -NoProfile -File $scriptPath -DeploymentType $act -Action $act -PinVersion '' 2>&1
    if ($LASTEXITCODE -ne 0 -or @($out).Count -ne 0) { Fail "empty pin $act exited $LASTEXITCODE with [$out]" }
}

Write-Output 'net-path-test tests passed'
exit 0
