# File parameters are not Mandatory. A mandatory parameter prompts when this
# file is dot-sourced under RELIAN_DEPLOY_TEST.
#
# Network path test: before/after timings for a remote-access change, measured as the
# signed-in user. Nothing runs at install time except the arm step.
#
# Install (runner, SYSTEM): copies this script and the settings to
#   %ProgramData%\Relian\NetTest and registers the one-shot task \Relian\Relian NetTest.
#   It fires DelayMinutes after the next logon (and once DelayMinutes from now when someone
#   is already signed in).
# Run (that task, SYSTEM): saves the original state, switches through the scenarios, has a
#   user-context task (Mode Measure) measure each one, restores every setting it changed,
#   writes results-<RunId>.json, then removes both tasks.
#   office, or remote without the tunnel: gsa (Private Access on) and direct (off).
#   remote with the tunnel:               gsa (tunnel stopped, its NRPT rules removed,
#                                         Private Access on) and wireguard (tunnel up,
#                                         Private Access off).
# Report (runner, PackageArguments Mode=Report): prints a summary of the newest results;
#   Page=1.. prints the raw JSON in 9,000-character pages.
# Uninstall (runner): restores what a broken run left changed and removes the tasks.
#   Results files stay.
#
# Settings it may change during a run, always restored in a finally block, and again by the
# next run or by Uninstall if the device lost power mid-run: the user's
# IsPrivateAccessDisabledByUser value, the tunnel service state, the tunnel's NRPT rules
# (tag "Relian WireGuard client: "), the WireGuard network guard task's enabled state.
# It restarts the Global Secure Access services and the user's tray app so the value is
# re-read. On file shares it reads; it writes only one test file per WriteTestDirs entry.
[CmdletBinding()]
param(
    [string]$DeploymentType,
    [string]$Action,
    [string]$PinVersion,
    [string]$Mode = '',
    [string]$Scenario = '',
    [string]$RunId = '',
    [string]$ExpectGsa = '',
    [string]$Page = '0',
    [string]$TcpTargets = '',
    [string]$DnsNames = '',
    [string]$ListPaths = '',
    [string]$ReadFiles = '',
    [string]$WriteTestDirs = '',
    [string]$OfficePrefixes = '',
    [string]$TunnelName = '',
    [string]$DelayMinutes = '10',
    [string]$TestFileMB = '100',
    [string]$MaxFallbackMB = '200'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:NptVersion = '1.0.0'
$script:NptRoot = "$env:ProgramData\Relian\NetTest"
$script:NptTaskPath = '\Relian\'
$script:NptRunTask = 'Relian NetTest'
$script:NptMeasureTask = 'Relian NetTest Measure'
$script:NptGuardTask = 'Relian-WireGuardNetworkGuard'
$script:NptNrptTag = 'Relian WireGuard client: '
$script:NptGsaKey = 'Software\Microsoft\Global Secure Access Client'
$script:NptGsaValue = 'IsPrivateAccessDisabledByUser'
$script:NptTrayExe = "$env:ProgramFiles\Global Secure Access Client\TrayApp\GlobalSecureAccessClient.exe"
$script:NptPageSize = 9000

# ---------- pure helpers ----------

function ConvertTo-NptList {
    param([AllowEmptyString()][string]$Text)
    return @(([string]$Text -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
}

function Get-NptSettingsErrors {
    param($Settings)
    $errors = [System.Collections.Generic.List[string]]::new()
    foreach ($t in @(ConvertTo-NptList -Text $Settings.TcpTargets)) {
        if ($t -notmatch '^[A-Za-z0-9.-]+:\d{1,5}$' -or [int]($t -split ':')[1] -gt 65535) { $errors.Add("bad TcpTargets entry $t") }
    }
    if (@(ConvertTo-NptList -Text $Settings.TcpTargets).Count -eq 0) { $errors.Add('TcpTargets is empty') }
    foreach ($n in @(ConvertTo-NptList -Text $Settings.DnsNames)) {
        if ($n -notmatch '^[A-Za-z0-9.-]+$') { $errors.Add("bad DnsNames entry $n") }
    }
    foreach ($name in @('ListPaths', 'ReadFiles', 'WriteTestDirs')) {
        foreach ($p in @(ConvertTo-NptList -Text $Settings.$name)) {
            if ($p -notmatch '^\\\\[A-Za-z0-9.-]+\\[^\\/:*?"<>|]+(\\[^\\/:*?"<>|]+)*$' -or $p -match '\\\.\.?(\\|$)') { $errors.Add("bad $name entry $p") }
        }
    }
    foreach ($p in @(ConvertTo-NptList -Text $Settings.OfficePrefixes)) {
        if ($p -notmatch '^\d{1,3}(\.\d{1,3}){0,3}\.$') { $errors.Add("bad OfficePrefixes entry $p") }
    }
    if ([string]$Settings.TunnelName -ne '' -and $Settings.TunnelName -notmatch '^[A-Za-z0-9_=+.-]{1,32}$') { $errors.Add('bad TunnelName') }
    foreach ($pair in @(@('DelayMinutes', 0, 120), @('TestFileMB', 1, 1024), @('MaxFallbackMB', 1, 2048))) {
        $v = [string]$Settings.($pair[0]); $n = 0
        if (-not [int]::TryParse($v, [ref]$n) -or $n -lt $pair[1] -or $n -gt $pair[2]) { $errors.Add("$($pair[0]) must be $($pair[1])-$($pair[2])") }
    }
    return , $errors
}

function Get-NptMedian {
    param([double[]]$Values)
    if ($null -eq $Values -or $Values.Count -eq 0) { return $null }
    $s = @($Values | Sort-Object)
    $m = [int][math]::Floor($s.Count / 2)
    if ($s.Count % 2 -eq 1) { return [math]::Round($s[$m], 1) }
    return [math]::Round(($s[$m - 1] + $s[$m]) / 2, 1)
}

# Global Secure Access answers a Private Access FQDN with a synthetic address in 6.6.0.0/16.
function Test-NptGsaAddress {
    param([AllowEmptyString()][string]$Ip)
    return ([string]$Ip -match '^6\.6\.\d{1,3}\.\d{1,3}$')
}

function Get-NptLocation {
    param([string[]]$Addresses, [string[]]$Prefixes)
    foreach ($a in @($Addresses)) {
        foreach ($p in @($Prefixes)) { if ($p -and ([string]$a).StartsWith($p)) { return 'office' } }
    }
    return 'remote'
}

# Tunnel '' leaves the tunnel alone; Nrpt 'off' removes the tunnel's tagged NRPT rules.
# Office 'direct' keeps the NRPT rules on (review suggestion declined): that is the production
# office state, where the network guard stops the tunnel and the rules stay. If their DNS
# servers fail there, the measurement should show it.
function Get-NptScenarios {
    param([string]$Location, [bool]$HasTunnel)
    $stop = if ($HasTunnel) { 'Stopped' } else { '' }
    if ($Location -eq 'remote' -and $HasTunnel) {
        return @(
            [pscustomobject]@{ Name = 'gsa'; PaDisabled = 0; Tunnel = 'Stopped'; Nrpt = 'off'; ExpectGsa = $true },
            [pscustomobject]@{ Name = 'wireguard'; PaDisabled = 1; Tunnel = 'Running'; Nrpt = 'on'; ExpectGsa = $false }
        )
    }
    return @(
        [pscustomobject]@{ Name = 'gsa'; PaDisabled = 0; Tunnel = $stop; Nrpt = 'off'; ExpectGsa = $true },
        [pscustomobject]@{ Name = 'direct'; PaDisabled = 1; Tunnel = $stop; Nrpt = 'on'; ExpectGsa = $false }
    )
}

function ConvertFrom-NptKlist {
    param([AllowEmptyString()][string]$Text)
    $servers = [System.Collections.Generic.List[string]]::new()
    foreach ($line in ([string]$Text -split "`r?`n")) {
        if ($line -match '^\s*Server:\s*(\S+)\s*@\s*(\S+)') {
            if (-not $servers.Contains($Matches[1])) { $servers.Add($Matches[1]) }
        }
    }
    return $servers.ToArray()
}

function Get-NptPage {
    param([AllowEmptyString()][string]$Text, [int]$Page, [int]$Size)
    $pages = [int][math]::Ceiling($Text.Length / [double]$Size)
    if ($Page -lt 1 -or $Page -gt $pages) { return [pscustomobject]@{ Pages = $pages; Text = '' } }
    $start = ($Page - 1) * $Size
    return [pscustomobject]@{ Pages = $pages; Text = $Text.Substring($start, [math]::Min($Size, $Text.Length - $start)) }
}

function Get-NptSummary {
    param($Results)
    $o = [System.Collections.Generic.List[string]]::new()
    $o.Add(('NETTEST {0} user={1} run={2} location={3} metered={4} battery={5}' -f $Results.computer, $Results.user, $Results.runId, $Results.location, $Results.metered, $Results.onBattery))
    foreach ($s in @($Results.scenarios)) {
        $m = $s.measure
        if ($null -eq $m) { $o.Add("[$($s.name)] no measurement: $($s.error)"); continue }
        $o.Add(('[{0}] settled={1} in {2}s gsaDns={3} tunnel={4} pa={5}' -f $s.name, $m.settled, $m.settleSeconds, $m.gsaDns, $m.tunnel, $m.paValue))
        foreach ($d in @($m.dns)) { $o.Add(('  dns {0} = {1}' -f $d.name, (@($d.answers) -join ','))) }
        foreach ($t in @($m.tcp)) { $o.Add(('  tcp {0}:{1} ip={2} if={3} ok={4}/{5} median={6}ms gsa={7}' -f $t.host, $t.port, $t.ip, $t.routeInterface, $t.ok, $t.tries, $t.medianMs, $t.gsa)) }
        foreach ($l in @($m.lists)) { $o.Add(('  list {0} {1}ms entries={2} {3}' -f $l.path, $l.ms, $l.entries, $l.error)) }
        foreach ($r in @($m.reads)) { $o.Add(('  read {0} {1}MB {2}s {3}MB/s {4} {5}' -f $r.path, $r.mb, $r.seconds, $r.mbps, $r.mode, $r.error)) }
        if ($m.readsSkipped) { $o.Add("  reads skipped: $($m.readsSkipped)") }
        $o.Add(('  kerberos tickets={0}' -f @($m.klist).Count))
    }
    if ($Results.restore) { $o.Add(('restore errors=[{0}] verify={1}' -f (@($Results.restore.errors) -join '; '), $Results.restore.verified)) }
    return ($o -join "`n")
}

# ---------- side-effect seams (mocked in tests) ----------

$script:SetPaValue = {
    param([string]$Sid, $Value)
    $key = "Registry::HKEY_USERS\$Sid\$($script:NptGsaKey)"
    if ($null -eq $Value) {
        if (Test-Path -LiteralPath $key) { Remove-ItemProperty -LiteralPath $key -Name $script:NptGsaValue -ErrorAction SilentlyContinue }
        return
    }
    if (-not (Test-Path -LiteralPath $key)) { New-Item -Path $key -Force | Out-Null }
    New-ItemProperty -LiteralPath $key -Name $script:NptGsaValue -PropertyType DWord -Value ([int]$Value) -Force | Out-Null
}

$script:GetPaValue = {
    param([string]$Sid)
    $v = Get-ItemProperty -LiteralPath "Registry::HKEY_USERS\$Sid\$($script:NptGsaKey)" -Name $script:NptGsaValue -ErrorAction SilentlyContinue
    if ($null -eq $v) { return $null }
    return [int]$v.($script:NptGsaValue)
}

$script:GetTunnelStatus = {
    param([string]$Name)
    if (-not $Name) { return '' }
    $s = Get-Service -Name "WireGuardTunnel`$$Name" -ErrorAction SilentlyContinue
    if ($null -eq $s) { return '' }
    return [string]$s.Status
}

$script:SetTunnel = {
    param([string]$Name, [string]$State)
    $svc = "WireGuardTunnel`$$Name"
    if ($State -eq 'Running') { Start-Service -Name $svc } else { Stop-Service -Name $svc -Force }
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline -and [string](Get-Service -Name $svc).Status -ne $State) { Start-Sleep -Seconds 1 }
}

$script:GetGuardState = {
    $t = Get-ScheduledTask -TaskPath $script:NptTaskPath -TaskName $script:NptGuardTask -ErrorAction SilentlyContinue
    if ($null -eq $t) { return '' }
    return [string]$t.State
}

$script:SetGuardEnabled = {
    param([bool]$Enabled)
    if ($Enabled) { Enable-ScheduledTask -TaskPath $script:NptTaskPath -TaskName $script:NptGuardTask | Out-Null }
    else { Disable-ScheduledTask -TaskPath $script:NptTaskPath -TaskName $script:NptGuardTask | Out-Null }
}

$script:GetNrpt = {
    return @(Get-DnsClientNrptRule -ErrorAction SilentlyContinue | Where-Object { ([string]$_.Comment).StartsWith($script:NptNrptTag) } |
            ForEach-Object { [pscustomobject]@{ Name = [string]$_.Name; Namespace = @($_.Namespace); NameServers = @($_.NameServers); Comment = [string]$_.Comment } })
}

$script:AddNrpt = {
    param($Rule)
    Add-DnsClientNrptRule -Namespace $Rule.Namespace -NameServers $Rule.NameServers -Comment $Rule.Comment | Out-Null
}

$script:RemoveNrpt = {
    param($Rule)
    Remove-DnsClientNrptRule -Name $Rule.Name -Force
}

# Tries every running service; throws afterwards when any restart failed.
$script:RestartGsa = {
    $failed = @()
    foreach ($s in @(Get-Service -Name 'GlobalSecureAccess*' -ErrorAction SilentlyContinue | Where-Object Status -eq 'Running')) {
        try { Restart-Service -Name $s.Name -Force -ErrorAction Stop } catch { $failed += "$($s.Name): $($_.Exception.Message)" }
    }
    Clear-DnsClientCache -ErrorAction SilentlyContinue
    if ($failed.Count) { throw ($failed -join '; ') }
}

# ---------- restore (shared by Run, the next Run, and Uninstall) ----------

function Get-NptRuleKey {
    param($Rule)
    return ((@($Rule.Namespace) -join '|') + '#' + $Rule.Comment)
}

function Set-NptNrpt {
    param([bool]$On, $Original)
    $current = @(& $script:GetNrpt)
    if ($On) {
        $have = @($current | ForEach-Object { Get-NptRuleKey -Rule $_ })
        foreach ($r in @($Original)) { if ($have -notcontains (Get-NptRuleKey -Rule $r)) { & $script:AddNrpt -Rule $r } }
    } else {
        foreach ($r in $current) { & $script:RemoveNrpt -Rule $r }
    }
}

function Invoke-NptRestore {
    param($Original)
    $errors = [System.Collections.Generic.List[string]]::new()
    $steps = @(
        @('pa', { & $script:SetPaValue -Sid $Original.sid -Value $Original.paValue }),
        @('nrpt', { if (@($Original.nrpt).Count -gt 0) { Set-NptNrpt -On $true -Original $Original.nrpt } }),
        @('tunnel', { if ($Original.tunnel -in @('Running', 'Stopped') -and (& $script:GetTunnelStatus -Name $Original.tunnelName) -ne $Original.tunnel) { & $script:SetTunnel -Name $Original.tunnelName -State $Original.tunnel } }),
        @('guard', { if ($Original.guard -ne '' -and $Original.guard -ne 'Disabled') { & $script:SetGuardEnabled -Enabled $true } }),
        @('gsa', { & $script:RestartGsa })
    )
    foreach ($step in $steps) {
        try { & $step[1] } catch { $errors.Add("$($step[0]): $($_.Exception.Message)") }
    }
    return $errors.ToArray()
}

# Restores the state an interrupted run saved. The file is deleted only after a clean restore,
# so a failed restore keeps the true original for the next attempt. Returns $true when clean.
function Invoke-NptRecover {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $true }
    $errors = @(Invoke-NptRestore -Original (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json))
    Write-NptLog "restore of saved state: errors=[$($errors -join '; ')]"
    if ($errors.Count) { return $false }
    Remove-Item -LiteralPath $Path -Force
    return $true
}

# ---------- device helpers ----------

function Read-NptSettings {
    return (Get-Content -LiteralPath (Join-Path $script:NptRoot 'settings.json') -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Write-NptJson {
    param([string]$Path, $Object)
    $tmp = "$Path.tmp"
    [System.IO.File]::WriteAllText($tmp, ($Object | ConvertTo-Json -Depth 8 -Compress), [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Write-NptLog {
    param([string]$Message)
    try { Add-Content -LiteralPath (Join-Path $script:NptRoot 'run.log') -Value ('{0} {1}' -f (Get-Date -Format s), $Message) -Encoding UTF8 } catch { }
}

function Get-NptConsoleUser {
    $u = [string](Get-CimInstance -ClassName Win32_ComputerSystem).UserName
    if ($u) { return $u }
    foreach ($p in @(Get-CimInstance -ClassName Win32_Process -Filter "Name='explorer.exe'")) {
        $o = Invoke-CimMethod -InputObject $p -MethodName GetOwner
        if ($o.ReturnValue -eq 0 -and $o.User) { return "$($o.Domain)\$($o.User)" }
    }
    return ''
}

function Get-NptPhysicalAddresses {
    return @(Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' } | ForEach-Object { $_.IPv4Address.IPAddress })
}

function Set-NptAcl {
    param([string]$Path, [bool]$UsersWrite)
    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetOwner([System.Security.Principal.SecurityIdentifier]'S-1-5-32-544')
    $acl.SetAccessRuleProtection($true, $false)
    $rules = @(@('S-1-5-18', 'FullControl'), @('S-1-5-32-544', 'FullControl'), @('S-1-5-32-545', $(if ($UsersWrite) { 'Modify' } else { 'ReadAndExecute' })))
    foreach ($r in $rules) {
        $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new([System.Security.Principal.SecurityIdentifier]$r[0], $r[1], 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Get-NptPowerShell {
    return (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
}

# ---------- Mode Measure (user context) ----------

function Measure-NptTcp {
    param([string]$HostName, [int]$Port, [hashtable]$AliasByIp)
    $r = [ordered]@{ host = $HostName; port = $Port; ip = ''; gsa = $false; routeInterface = ''; routeSource = ''; localAddress = ''; localInterface = ''; tries = 10; ok = 0; medianMs = $null; minMs = $null; error = '' }
    try {
        $ip = @([System.Net.Dns]::GetHostAddresses($HostName) | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1)
        if ($ip.Count -eq 0) { throw 'no IPv4 answer' }
        $r.ip = $ip[0].ToString()
    } catch { $r.error = "dns: $($_.Exception.Message)"; return [pscustomobject]$r }
    $r.gsa = Test-NptGsaAddress -Ip $r.ip
    try {
        $route = @(Find-NetRoute -RemoteIPAddress $r.ip -ErrorAction Stop | Where-Object { $_.PSObject.Properties['IPAddress'] } | Select-Object -First 1)
        if ($route.Count) { $r.routeInterface = [string]$route[0].InterfaceAlias; $r.routeSource = [string]$route[0].IPAddress }
    } catch { }
    $ms = [System.Collections.Generic.List[double]]::new()
    for ($i = 0; $i -lt $r.tries; $i++) {
        $c = [System.Net.Sockets.TcpClient]::new()
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            if ($c.ConnectAsync($ip[0], $Port).Wait(3000) -and $c.Connected) {
                $ms.Add($sw.Elapsed.TotalMilliseconds)
                if (-not $r.localAddress) {
                    $r.localAddress = $c.Client.LocalEndPoint.Address.ToString()
                    if ($AliasByIp.ContainsKey($r.localAddress)) { $r.localInterface = $AliasByIp[$r.localAddress] }
                }
            }
        } catch { } finally { $c.Dispose() }
    }
    $r.ok = $ms.Count
    if ($ms.Count) { $r.medianMs = Get-NptMedian -Values $ms.ToArray(); $r.minMs = [math]::Round(($ms | Measure-Object -Minimum).Minimum, 1) }
    return [pscustomobject]$r
}

function Read-NptFile {
    param([string]$Path, [int]$CapSeconds = 180)
    $r = [ordered]@{ path = $Path; mb = $null; seconds = $null; mbps = $null; mode = ''; error = '' }
    $buffer = New-Object byte[] (1MB)
    foreach ($mode in @('unbuffered', 'buffered')) {
        # 0x20000000 is FILE_FLAG_NO_BUFFERING, so the SMB client cache does not answer the read.
        $opt = if ($mode -eq 'unbuffered') { [System.IO.FileOptions]0x20000000 } else { [System.IO.FileOptions]::SequentialScan }
        $total = 0L
        try {
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $fs = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite, 1, $opt)
            try {
                while (($n = $fs.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    $total += $n
                    if ($sw.Elapsed.TotalSeconds -gt $CapSeconds) { $r.error = 'stopped at time cap'; break }
                }
            } finally { $fs.Dispose() }
            $r.mode = $mode
            $r.mb = [math]::Round($total / 1MB, 1); $r.seconds = [math]::Round($sw.Elapsed.TotalSeconds, 2)
            if ($r.seconds -gt 0) { $r.mbps = [math]::Round($r.mb / $r.seconds, 2) }
            return [pscustomobject]$r
        } catch { $r.error = "$mode read: $($_.Exception.Message)" }
    }
    return [pscustomobject]$r
}

# Writes the test file once per run (the first scenario that reaches the share). If the user
# cannot write, it falls back to the largest existing file up to MaxFallbackMB, found once.
function Get-NptWriteTarget {
    param([string]$Dir, [int]$SizeMB, [int]$MaxMB, [string]$Work, [string]$Id)
    $file = Join-Path $Dir ('{0}MB.bin' -f $SizeMB)
    $memo = Join-Path $Work ('{0}-target-{1}.json' -f $Id, ([System.BitConverter]::ToString([System.Security.Cryptography.SHA1]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Dir))) -replace '-', '').Substring(0, 8))
    if (Test-Path -LiteralPath $memo) { return (Get-Content -LiteralPath $memo -Raw | ConvertFrom-Json) }
    $t = [ordered]@{ dir = $Dir; path = ''; source = ''; writeSeconds = $null; writeMbps = $null; error = '' }
    try {
        if ((Test-Path -LiteralPath $file) -and (Get-Item -LiteralPath $file).Length -eq ([int64]$SizeMB * 1MB)) {
            $t.path = $file; $t.source = 'existing test file'
        } else {
            $created = $false
            try {
                if (-not (Test-Path -LiteralPath $Dir)) { New-Item -ItemType Directory -Path $Dir -ErrorAction Stop | Out-Null }
                $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
                $chunk = New-Object byte[] (1MB)
                $sw = [System.Diagnostics.Stopwatch]::StartNew()
                $fs = [System.IO.FileStream]::new($file, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None, 1MB, [System.IO.FileOptions]::WriteThrough)
                $created = $true
                try { for ($i = 0; $i -lt $SizeMB; $i++) { $rng.GetBytes($chunk); $fs.Write($chunk, 0, $chunk.Length) } } finally { $fs.Dispose() }
                $t.writeSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 2)
                if ($t.writeSeconds -gt 0) { $t.writeMbps = [math]::Round($SizeMB / $t.writeSeconds, 2) }
                $t.path = $file; $t.source = 'created by this run'
            } catch {
                $t.error = "write: $($_.Exception.Message)"
                # Only a file this run created is removed.
                if ($created) { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
            }
        }
        if (-not $t.path) {
            $root = Split-Path -Parent $Dir
            $best = $null; $seen = 0
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $queue = [System.Collections.Generic.Queue[object]]::new(); $queue.Enqueue(@($root, 0))
            while ($queue.Count -and $seen -lt 3000 -and $sw.Elapsed.TotalSeconds -lt 60) {
                $item = $queue.Dequeue()
                try {
                    foreach ($e in ([System.IO.DirectoryInfo]::new($item[0])).EnumerateFileSystemInfos()) {
                        $seen++
                        if ($e -is [System.IO.DirectoryInfo]) { if ($item[1] -lt 2) { $queue.Enqueue(@($e.FullName, $item[1] + 1)) } }
                        elseif ($e.Length -le ([int64]$MaxMB * 1MB) -and ($null -eq $best -or $e.Length -gt $best.Length)) { $best = $e }
                        if ($seen -ge 3000) { break }
                    }
                } catch { }
            }
            if ($best) { $t.path = $best.FullName; $t.source = "largest of $seen entries searched" }
        }
    } catch { $t.error = $_.Exception.Message }
    Write-NptJson -Path $memo -Object $t
    return [pscustomobject]$t
}

function Test-NptMetered {
    try {
        $null = [Windows.Networking.Connectivity.NetworkInformation,Windows.Networking.Connectivity,ContentType=WindowsRuntime]
        $p = [Windows.Networking.Connectivity.NetworkInformation]::GetInternetConnectionProfile()
        if ($null -eq $p) { return $null }
        $c = $p.GetConnectionCost()
        return ([string]$c.NetworkCostType -ne 'Unrestricted' -or $c.Roaming -or $c.OverDataLimit)
    } catch { return $null }
}

function Restart-NptTray {
    $session = (Get-Process -Id $PID).SessionId
    $tray = @(Get-Process -Name 'GlobalSecureAccessClient' -ErrorAction SilentlyContinue | Where-Object SessionId -eq $session)
    if ($tray.Count -eq 0) { return 'not running' }
    $tray | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    if (Test-Path -LiteralPath $script:NptTrayExe) { Start-Process -FilePath $script:NptTrayExe; return 'restarted' }
    return 'stopped; exe not found'
}

function Invoke-NptMeasure {
    param($Settings, [string]$Name, [string]$Id, [bool]$Expect)
    $work = Join-Path $script:NptRoot 'work'
    $m = [ordered]@{ scenario = $Name; user = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name; start = (Get-Date -Format o) }
    $m.tray = try { Restart-NptTray } catch { "error: $($_.Exception.Message)" }
    $names = @(ConvertTo-NptList -Text $Settings.DnsNames)
    $m.settled = $null; $m.settleSeconds = $null; $m.gsaDns = $null
    if ($names.Count) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        do {
            & ipconfig.exe /flushdns | Out-Null
            $ips = @(try { [System.Net.Dns]::GetHostAddresses($names[0]) | ForEach-Object { $_.ToString() } } catch { })
            $m.gsaDns = [bool](@($ips | Where-Object { Test-NptGsaAddress -Ip $_ }).Count)
            if ($m.gsaDns -eq $Expect -and $ips.Count) { break }
            Start-Sleep -Seconds 5
        } while ($sw.Elapsed.TotalSeconds -lt 120)
        $m.settled = ($m.gsaDns -eq $Expect); $m.settleSeconds = [int]$sw.Elapsed.TotalSeconds
    }
    $m.paValue = (Get-ItemProperty -LiteralPath "HKCU:\$($script:NptGsaKey)" -Name $script:NptGsaValue -ErrorAction SilentlyContinue | ForEach-Object { $_.($script:NptGsaValue) })
    $m.tunnel = if ($Settings.TunnelName) { @(Get-Service -Name "WireGuardTunnel`$$($Settings.TunnelName)" -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.Status }) -join '' } else { '' }
    $m.gsaServices = @(Get-Service -Name 'GlobalSecureAccess*' -ErrorAction SilentlyContinue | ForEach-Object { "$($_.Name)=$($_.Status)" })
    if ($Name -eq 'restore') {
        $m.end = (Get-Date -Format o)
        Write-NptJson -Path (Join-Path $work "$Id-$Name.json") -Object $m
        return
    }
    $aliasByIp = @{}
    foreach ($a in @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue)) { $aliasByIp[[string]$a.IPAddress] = [string]$a.InterfaceAlias }
    $m.interfaces = @($aliasByIp.Keys | Where-Object { $_ -notlike '127.*' -and $_ -notlike '169.254.*' } | ForEach-Object { '{0} ip={1}' -f $aliasByIp[$_], $_ })
    $m.defaultRoutes = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | ForEach-Object { '{0} gw={1} metric={2}' -f $_.InterfaceAlias, $_.NextHop, ($_.RouteMetric + $_.InterfaceMetric) })
    $m.dns = @(foreach ($n in $names) {
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $ans = @(try { [System.Net.Dns]::GetHostAddresses($n) | ForEach-Object { $_.ToString() } } catch { 'error' })
            [pscustomobject]@{ name = $n; answers = $ans; ms = [math]::Round($sw.Elapsed.TotalMilliseconds, 1); gsa = [bool](@($ans | Where-Object { Test-NptGsaAddress -Ip $_ }).Count) }
        })
    $m.tcp = @(foreach ($t in @(ConvertTo-NptList -Text $Settings.TcpTargets)) { $hp = $t -split ':'; Measure-NptTcp -HostName $hp[0] -Port ([int]$hp[1]) -AliasByIp $aliasByIp })
    $m.lists = @(foreach ($p in @(ConvertTo-NptList -Text $Settings.ListPaths)) {
            $sw = [System.Diagnostics.Stopwatch]::StartNew(); $n = $null; $err = ''
            try { $n = [System.IO.Directory]::GetFileSystemEntries($p).Length } catch { $err = $_.Exception.Message }
            [pscustomobject]@{ path = $p; ms = [math]::Round($sw.Elapsed.TotalMilliseconds, 1); entries = $n; error = $err }
        })
    $metered = Test-NptMetered
    $m.metered = $metered
    $m.reads = @(); $m.readsSkipped = ''; $m.writeTargets = @()
    if ($metered -eq $true) {
        $m.readsSkipped = 'metered connection'
    } else {
        $files = [System.Collections.Generic.List[string]]::new()
        foreach ($f in @(ConvertTo-NptList -Text $Settings.ReadFiles)) { $files.Add($f) }
        foreach ($d in @(ConvertTo-NptList -Text $Settings.WriteTestDirs)) {
            $wt = Get-NptWriteTarget -Dir $d -SizeMB ([int]$Settings.TestFileMB) -MaxMB ([int]$Settings.MaxFallbackMB) -Work $work -Id $Id
            $m.writeTargets += $wt
            if ($wt.path) { $files.Add([string]$wt.path) }
        }
        $m.reads = @(foreach ($f in $files) { Read-NptFile -Path $f })
    }
    $m.smb = @(try { Get-SmbConnection -ErrorAction Stop | ForEach-Object { '{0}\{1} dialect={2}' -f $_.ServerName, $_.ShareName, $_.Dialect } } catch { "error: $($_.Exception.Message)" })
    $m.tcp445 = @(Get-NetTCPConnection -RemotePort 445 -State Established -ErrorAction SilentlyContinue | ForEach-Object {
            $alias = if ($aliasByIp.ContainsKey([string]$_.LocalAddress)) { $aliasByIp[[string]$_.LocalAddress] } else { '' }
            '{0} via {1} ({2}) gsa={3}' -f $_.RemoteAddress, $_.LocalAddress, $alias, (Test-NptGsaAddress -Ip ([string]$_.RemoteAddress))
        })
    $m.klist = @(try { ConvertFrom-NptKlist -Text ((& klist.exe) -join "`n") } catch { })
    $m.end = (Get-Date -Format o)
    Write-NptJson -Path (Join-Path $work "$Id-$Name.json") -Object $m
}

# The orchestrator waits for the measurement file; on any failure an error file ends the wait at once.
function Invoke-NptMeasureEntry {
    param([string]$Name, [string]$Id, [bool]$Expect)
    try {
        Invoke-NptMeasure -Settings (Read-NptSettings) -Name $Name -Id $Id -Expect $Expect
        return 0
    } catch {
        Write-NptJson -Path (Join-Path (Join-Path $script:NptRoot 'work') "$Id-$Name.json") -Object @{ scenario = $Name; error = $_.Exception.Message }
        return 1
    }
}

# ---------- Mode Run (SYSTEM, from the logon task) ----------

$script:StartMeasure = {
    param([string]$User, [string]$Arguments)
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 30) -MultipleInstances IgnoreNew
    $principal = New-ScheduledTaskPrincipal -UserId $User -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskPath $script:NptTaskPath -TaskName $script:NptMeasureTask -Action (New-ScheduledTaskAction -Execute (Get-NptPowerShell) -Argument $Arguments) -Principal $principal -Settings $settings -Force | Out-Null
    Start-ScheduledTask -TaskPath $script:NptTaskPath -TaskName $script:NptMeasureTask | Out-Null
}

# Stops the measurement task and waits until it is no longer running.
$script:StopMeasure = {
    Stop-ScheduledTask -TaskPath $script:NptTaskPath -TaskName $script:NptMeasureTask -ErrorAction SilentlyContinue | Out-Null
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline -and [string](Get-ScheduledTask -TaskPath $script:NptTaskPath -TaskName $script:NptMeasureTask -ErrorAction SilentlyContinue).State -eq 'Running') { Start-Sleep -Seconds 2 }
}

# Returns the measurement. Throws on a timeout (after stopping the task, so the next scenario
# never changes the network under a measurement still running) or when Measure wrote an error file.
function Invoke-NptUserTask {
    param([string]$User, [string]$Name, [string]$Id, [bool]$Expect, [int]$TimeoutSeconds = 1500, [int]$PollSeconds = 5)
    $work = Join-Path $script:NptRoot 'work'
    $out = Join-Path $work "$Id-$Name.json"
    Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
    $arg = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Mode Measure -Scenario {1} -RunId {2} -ExpectGsa {3}' -f (Join-Path $script:NptRoot 'Invoke-NetPathTest.ps1'), $Name, $Id, $(if ($Expect) { 'true' } else { 'false' })
    & $script:StartMeasure -User $User -Arguments $arg
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $PollSeconds
        if (Test-Path -LiteralPath $out) {
            $m = $null
            try { $m = Get-Content -LiteralPath $out -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
            if ($null -ne $m) {
                if ($m.PSObject.Properties['error']) { throw "measure: $($m.error)" }
                return $m
            }
        }
    }
    & $script:StopMeasure
    throw "no measurement for $Name within $TimeoutSeconds s"
}

function Remove-NptTasks {
    foreach ($n in @($script:NptMeasureTask, $script:NptRunTask)) {
        Unregister-ScheduledTask -TaskPath $script:NptTaskPath -TaskName $n -Confirm:$false -ErrorAction SilentlyContinue
    }
}

# The tasks go only after a clean restore. Otherwise the logon task stays as the recovery entry
# point: the next logon restores the saved state first and, with results already written, stops there.
function Complete-NptRun {
    param([AllowEmptyCollection()][string[]]$Errors)
    if (@($Errors).Count -eq 0) { Remove-NptTasks; return 'removed' }
    Write-NptLog 'restore not clean; tasks kept so the next logon retries the restore'
    return 'kept'
}

function Invoke-NptRun {
    $settings = Read-NptSettings
    $user = Get-NptConsoleUser
    if (-not $user) { Write-NptLog 'no signed-in user; waiting for the next logon'; return 0 }
    $lock = $null
    try { $lock = [System.IO.File]::Open((Join-Path $script:NptRoot 'run.lock'), 'OpenOrCreate', 'ReadWrite', 'None') } catch { Write-NptLog 'another run holds the lock'; return 0 }
    try {
        $origPath = Join-Path $script:NptRoot 'original-state.json'
        $hadSaved = Test-Path -LiteralPath $origPath
        if (-not (Invoke-NptRecover -Path $origPath)) { return 0 }
        # Saved state next to written results: the measurement is done and this run only recovered.
        if ($hadSaved -and @(Get-ChildItem -LiteralPath $script:NptRoot -Filter 'results-*.json' -ErrorAction SilentlyContinue).Count) { [void](Complete-NptRun -Errors @()); return 0 }
        $sid = ([System.Security.Principal.NTAccount]$user).Translate([System.Security.Principal.SecurityIdentifier]).Value
        $id = Get-Date -Format 'yyyyMMdd-HHmmss'
        $orig = [ordered]@{
            sid = $sid; paValue = (& $script:GetPaValue -Sid $sid); tunnelName = [string]$settings.TunnelName
            tunnel = (& $script:GetTunnelStatus -Name $settings.TunnelName); guard = (& $script:GetGuardState); nrpt = @(& $script:GetNrpt)
        }
        Write-NptJson -Path $origPath -Object $orig
        $location = Get-NptLocation -Addresses (Get-NptPhysicalAddresses) -Prefixes (ConvertTo-NptList -Text $settings.OfficePrefixes)
        $battery = @(Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue)
        $results = [ordered]@{
            version = $script:NptVersion; computer = $env:COMPUTERNAME; user = $user; runId = $id; start = (Get-Date -Format o)
            location = $location; onBattery = [bool](@($battery | Where-Object BatteryStatus -eq 1).Count); metered = $null
            original = $orig; scenarios = @(); restore = $null
        }
        Write-NptLog "run $id user=$user location=$location tunnel=$($orig.tunnel) pa=$($orig.paValue) guard=$($orig.guard)"
        try {
            if ($orig.guard -ne '' -and $orig.guard -ne 'Disabled') { & $script:SetGuardEnabled -Enabled $false }
            foreach ($s in @(Get-NptScenarios -Location $location -HasTunnel ($orig.tunnel -ne ''))) {
                $entry = [ordered]@{ name = $s.Name; plan = $s; gsaRestart = ''; measure = $null; error = '' }
                try {
                    & $script:SetPaValue -Sid $sid -Value $s.PaDisabled
                    if (@($orig.nrpt).Count) { Set-NptNrpt -On ($s.Nrpt -eq 'on') -Original $orig.nrpt }
                    if ($s.Tunnel) { & $script:SetTunnel -Name $settings.TunnelName -State $s.Tunnel }
                    # A failed restart is recorded; the settle check in Measure shows whether the value took.
                    $entry.gsaRestart = try { & $script:RestartGsa; 'ok' } catch { "error: $($_.Exception.Message)" }
                    Start-Sleep -Seconds 15
                    $entry.measure = Invoke-NptUserTask -User $user -Name $s.Name -Id $id -Expect $s.ExpectGsa
                    if ($null -ne $entry.measure -and $null -ne $entry.measure.metered) { $results.metered = $entry.measure.metered }
                } catch { $entry.error = $_.Exception.Message }
                Write-NptLog "scenario $($s.Name) error=[$($entry.error)]"
                $results.scenarios += [pscustomobject]$entry
            }
        } finally {
            $errors = @(Invoke-NptRestore -Original ([pscustomobject]$orig))
            $verified = $null
            # The tray re-reads the restored value; DNS shows whether Private Access is back as it was.
            try {
                Start-Sleep -Seconds 15
                $v = Invoke-NptUserTask -User $user -Name 'restore' -Id $id -Expect ($null -eq $orig.paValue -or [int]$orig.paValue -eq 0) -TimeoutSeconds 300
                $verified = $v.settled
            } catch { $errors += "verify: $($_.Exception.Message)" }
            if ($verified -eq $false) { $errors += 'verify: DNS did not return to the original Private Access path' }
            $now = [ordered]@{ paValue = (& $script:GetPaValue -Sid $sid); tunnel = (& $script:GetTunnelStatus -Name $settings.TunnelName); guard = (& $script:GetGuardState); nrptCount = @(& $script:GetNrpt).Count }
            $results.restore = [ordered]@{ errors = @($errors); verified = $verified; after = $now }
            if (@($errors).Count -eq 0) { Remove-Item -LiteralPath $origPath -Force -ErrorAction SilentlyContinue }
        }
        $results.end = (Get-Date -Format o)
        $path = Join-Path $script:NptRoot "results-$id.json"
        Write-NptJson -Path $path -Object $results
        Write-NptLog "wrote $path"
        Get-ChildItem -LiteralPath (Join-Path $script:NptRoot 'work') -Filter "$id-*" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
        [void](Complete-NptRun -Errors $errors)
        [Console]::Out.WriteLine((Get-NptSummary -Results ([pscustomobject]$results | ConvertTo-Json -Depth 8 | ConvertFrom-Json)))
        return 0
    } finally { $lock.Dispose() }
}

# ---------- runner modes ----------

function Invoke-NptInstall {
    param($Settings)
    $errors = Get-NptSettingsErrors -Settings $Settings
    if ($errors.Count) { [Console]::Error.WriteLine(($errors -join '; ')); return 1 }
    foreach ($d in @($script:NptRoot, (Join-Path $script:NptRoot 'work'))) { if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }
    Set-NptAcl -Path $script:NptRoot -UsersWrite $false
    Set-NptAcl -Path (Join-Path $script:NptRoot 'work') -UsersWrite $true
    $target = Join-Path $script:NptRoot 'Invoke-NetPathTest.ps1'
    if ($PSCommandPath -ne $target) { Copy-Item -LiteralPath $PSCommandPath -Destination $target -Force }
    Write-NptJson -Path (Join-Path $script:NptRoot 'settings.json') -Object $Settings
    $delay = [int]$Settings.DelayMinutes
    $triggers = @(New-ScheduledTaskTrigger -AtLogOn)
    $triggers[0].Delay = 'PT{0}M' -f $delay
    $user = Get-NptConsoleUser
    if ($user) { $triggers += New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes([math]::Max($delay, 1)) }
    $arg = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Mode Run' -f $target
    $taskSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 2) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskPath $script:NptTaskPath -TaskName $script:NptRunTask -Action (New-ScheduledTaskAction -Execute (Get-NptPowerShell) -Argument $arg) -Trigger $triggers -Principal (New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest) -Settings $taskSettings -Force | Out-Null
    Write-NptLog "armed: delay=$delay userNow=$user"
    [Console]::Out.WriteLine((@{ armed = $true; task = "$($script:NptTaskPath)$($script:NptRunTask)"; delayMinutes = $delay; signedInNow = $user; root = $script:NptRoot; version = $script:NptVersion } | ConvertTo-Json -Compress))
    return 0
}

function Invoke-NptUninstall {
    if (-not (Test-Path -LiteralPath $script:NptRoot)) { Remove-NptTasks; [Console]::Out.WriteLine('{"disarmed":true,"restoreErrors":[],"resultsKept":0}'); return 0 }
    # Stop a run in flight first (its finally block then does not run), and wait for its lock,
    # so the restore below is the last writer.
    foreach ($n in @($script:NptRunTask, $script:NptMeasureTask)) {
        Stop-ScheduledTask -TaskPath $script:NptTaskPath -TaskName $n -ErrorAction SilentlyContinue | Out-Null
    }
    $lock = $null
    $deadline = (Get-Date).AddSeconds(60)
    while ($null -eq $lock -and (Get-Date) -lt $deadline) {
        try { $lock = [System.IO.File]::Open((Join-Path $script:NptRoot 'run.lock'), 'OpenOrCreate', 'ReadWrite', 'None') } catch { Start-Sleep -Seconds 2 }
    }
    if ($null -eq $lock) { [Console]::Error.WriteLine('a run still holds the lock; nothing changed'); return 1 }
    try {
        $origPath = Join-Path $script:NptRoot 'original-state.json'
        $clean = Invoke-NptRecover -Path $origPath
    } finally { $lock.Dispose() }
    # Keep the tasks, script and saved state: the next run retries the restore before anything else.
    if (-not $clean) { [Console]::Error.WriteLine('restore failed; original-state.json, tasks and script kept, see run.log'); return 1 }
    Remove-NptTasks
    $restored = @()
    foreach ($f in @('Invoke-NetPathTest.ps1', 'settings.json', 'run.lock')) { Remove-Item -LiteralPath (Join-Path $script:NptRoot $f) -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath (Join-Path $script:NptRoot 'work') -Recurse -Force -ErrorAction SilentlyContinue
    [Console]::Out.WriteLine((@{ disarmed = $true; restoreErrors = @($restored); resultsKept = @(Get-ChildItem -LiteralPath $script:NptRoot -Filter 'results-*.json' -ErrorAction SilentlyContinue).Count } | ConvertTo-Json -Compress))
    return 0
}

function Invoke-NptReport {
    param([int]$PageNumber)
    $latest = @(Get-ChildItem -LiteralPath $script:NptRoot -Filter 'results-*.json' -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -Last 1)
    if ($latest.Count -eq 0) {
        $task = Get-ScheduledTask -TaskPath $script:NptTaskPath -TaskName $script:NptRunTask -ErrorAction SilentlyContinue
        $log = Join-Path $script:NptRoot 'run.log'
        $tail = if (Test-Path -LiteralPath $log) { (Get-Content -LiteralPath $log -Tail 20) -join "`n" } else { '' }
        [Console]::Out.WriteLine(("NETTEST {0} no results yet; task={1}`n{2}" -f $env:COMPUTERNAME, $(if ($task) { $task.State } else { 'absent' }), $tail))
        return 0
    }
    $text = Get-Content -LiteralPath $latest[0].FullName -Raw -Encoding UTF8
    if ($PageNumber -ge 1) {
        $p = Get-NptPage -Text $text -Page $PageNumber -Size $script:NptPageSize
        [Console]::Out.WriteLine(("NETTEST-PAGE {0}/{1} {2}" -f $PageNumber, $p.Pages, $latest[0].Name))
        [Console]::Out.WriteLine($p.Text)
        return 0
    }
    $summary = Get-NptSummary -Results ($text | ConvertFrom-Json)
    $pages = (Get-NptPage -Text $text -Page 0 -Size $script:NptPageSize).Pages
    [Console]::Out.WriteLine(("{0}`nfile={1} pages={2}" -f $summary.Substring(0, [math]::Min($summary.Length, 8500)), $latest[0].FullName, $pages))
    return 0
}

if ($env:RELIAN_DEPLOY_TEST -eq '1' -and $MyInvocation.InvocationName -eq '.') {
    return
}

if ($Mode -eq 'Run') { exit ([int](@(Invoke-NptRun)[-1])) }
if ($Mode -eq 'Measure') {
    if ($Scenario -notmatch '^[a-z]{1,16}$' -or $RunId -notmatch '^\d{8}-\d{6}$') { exit 1 }
    exit ([int](@(Invoke-NptMeasureEntry -Name $Scenario -Id $RunId -Expect ($ExpectGsa -eq 'true'))[-1]))
}
foreach ($name in @('DeploymentType', 'Action', 'PinVersion')) {
    if (-not $PSBoundParameters.ContainsKey($name)) {
        [Console]::Error.WriteLine("missing parameter $name")
        exit 1
    }
}
# An empty pin is a no-op, as with every runner package.
if ([string]::IsNullOrWhiteSpace($PinVersion)) { exit 0 }
if ($Mode -eq 'Report') {
    $n = 0
    if (-not [int]::TryParse($Page, [ref]$n)) { exit 1 }
    exit ([int](@(Invoke-NptReport -PageNumber $n)[-1]))
}
if ($Mode -ne '') { [Console]::Error.WriteLine("unknown Mode $Mode"); exit 1 }
if ($Action -eq 'Uninstall' -or $DeploymentType -eq 'Uninstall') { exit ([int](@(Invoke-NptUninstall)[-1])) }
$s = [pscustomobject]@{
    TcpTargets = $TcpTargets; DnsNames = $DnsNames; ListPaths = $ListPaths; ReadFiles = $ReadFiles; WriteTestDirs = $WriteTestDirs
    OfficePrefixes = $OfficePrefixes; TunnelName = $TunnelName; DelayMinutes = $DelayMinutes; TestFileMB = $TestFileMB; MaxFallbackMB = $MaxFallbackMB
}
exit ([int](@(Invoke-NptInstall -Settings $s)[-1]))
