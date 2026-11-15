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
if (@($errs).Count -ne 1 -or $errs[0] -notlike 'gsa: *service busy*') { Fail "restore errors: $($errs -join ';')" }

$calls.Clear()
$script:RestartGsa = { $calls.Add('gsa') }
$orig.paValue = 1; $orig.tunnel = ''; $orig.guard = 'Disabled'; $orig.nrpt = @()
$errs = Invoke-NptRestore -Original $orig
if (($calls -join '|') -ne 'pa S-1-5-21-1-2-3-1001 1|gsa' -or @($errs).Count -ne 0) { Fail "restore without tunnel: $($calls -join '|')" }

# Scenario NRPT switch: off removes only tagged rules the seam returns; on re-adds what is missing.
$calls.Clear()
Set-NptNrpt -On $false -Original @()
if (($calls -join '|') -ne 'nrpt remove x') { Fail "nrpt off: $($calls -join '|')" }

# The public repo must not carry a client host or user name in this package.
$src = Get-Content -LiteralPath $scriptPath -Raw
foreach ($word in @('sitka', 'slgarchive', 'slgmain', 'svfs', 'svdc')) {
    if ($src -match "(?i)$word") { Fail "client name $word in package" }
}

Write-Output 'net-path-test tests passed'
exit 0
