# File parameters are not Mandatory. A mandatory parameter prompts when this
# file is dot-sourced under RELIAN_DEPLOY_TEST.
# The installer pins are windows/releases/wireguard-client.json. The runner copies
# this script alone, so the values are inlined.
#
# Installs WireGuard for Windows and one split tunnel as a service. The private key
# is generated on the device by wg.exe, lives only in the tunnel config inside a
# folder that SYSTEM and Administrators alone can read, and is never printed.
# The run prints one JSON line with the PUBLIC key; the operator adds that key as a
# peer on the server. Optional: NRPT rules that send chosen DNS namespaces to the
# office DNS servers, and turning off Global Secure Access Private Access for the
# users whose hives are loaded.
[CmdletBinding()]
param(
    [string]$DeploymentType,
    [string]$Action,
    [string]$PinVersion,
    [string]$InstallerUrl = 'https://download.wireguard.com/windows-client/wireguard-amd64-1.1.1.msi',
    [string]$InstallerSha256 = '7bfed60ad61b785c914b38b61555a975488e1d3ec472dbfb2fcdf498fca75242',
    [string]$ArmInstallerUrl = 'https://download.wireguard.com/windows-client/wireguard-arm64-1.1.1.msi',
    [string]$ArmInstallerSha256 = '8336335c738d4aff040fa9d11b752da65a80b6f41d3262d6ba5e82f97ebd1bd4',
    [string]$CancelPath = '',
    [string]$Mode = '',
    [string]$TunnelName = '',
    [string]$Address = '',
    [string]$ServerPublicKey = '',
    [string]$Endpoint = '',
    [string]$AllowedIPs = '',
    [string]$PersistentKeepalive = '25',
    [string]$NrptNamespaces = '',
    [string]$NrptServers = '',
    [string]$DisableGsaPrivateAccess = 'false'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:WgcErrors = [System.Collections.Generic.List[string]]::new()
$script:NrptTagPrefix = 'Relian WireGuard client: '

function Write-WgcError {
    param([string]$Message)
    $script:WgcErrors.Add($Message)
    if ($env:RELIAN_DEPLOY_TEST -ne '1') {
        [Console]::Error.WriteLine($Message)
    }
}

function Test-WgcKey {
    param([AllowEmptyString()][string]$Key)
    if ($Key -cnotmatch '^[A-Za-z0-9+/]{43}=$') {
        return $false
    }
    try {
        return ([Convert]::FromBase64String($Key)).Length -eq 32
    } catch {
        return $false
    }
}

function Test-WgcTunnelName {
    param([AllowEmptyString()][string]$Name)
    # Becomes the service name WireGuardTunnel$<name> and the file name <name>.conf.
    return $Name -cmatch '^[a-z][a-z0-9-]{0,31}$'
}

function Test-WgcIpv4Cidr {
    param([AllowEmptyString()][string]$Cidr)
    if ($Cidr -cnotmatch '^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})/(\d{1,2})$') {
        return $false
    }
    foreach ($i in 1..4) {
        if ([int]$Matches[$i] -gt 255) {
            return $false
        }
    }
    return [int]$Matches[5] -le 32
}

function ConvertTo-WgcList {
    param([AllowEmptyString()][string]$Text)
    return @($Text -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
}

function Test-WgcEndpoint {
    param([AllowEmptyString()][string]$Endpoint)
    if ($Endpoint -cnotmatch '^([A-Za-z0-9.-]{1,253}):(\d{1,5})$') {
        return $false
    }
    $port = [int]$Matches[2]
    return $port -ge 1 -and $port -le 65535
}

function Test-WgcNamespace {
    param([AllowEmptyString()][string]$Namespace)
    # NRPT suffix (.example.invalid) or an exact name (host.example.invalid).
    return $Namespace -cmatch '^\.?[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$'
}

function Test-WgcIpv4 {
    param([AllowEmptyString()][string]$Ip)
    return (Test-WgcIpv4Cidr -Cidr "$Ip/32")
}

# Pure. Returns a list of reasons; empty means valid.
function Get-WgcSettingsErrors {
    param($Settings)
    $errors = [System.Collections.Generic.List[string]]::new()
    if (-not (Test-WgcTunnelName -Name $Settings.TunnelName)) { $errors.Add('TunnelName must be lower case letters, digits, or dashes') }
    if (-not (Test-WgcIpv4Cidr -Cidr $Settings.Address)) { $errors.Add('Address must be an IPv4 CIDR such as 192.0.2.10/32') }
    if (-not (Test-WgcKey -Key $Settings.ServerPublicKey)) { $errors.Add('ServerPublicKey is not a WireGuard key') }
    if (-not (Test-WgcEndpoint -Endpoint $Settings.Endpoint)) { $errors.Add('Endpoint must be host:port') }
    $allowed = @(ConvertTo-WgcList -Text $Settings.AllowedIPs)
    if ($allowed.Count -eq 0) {
        $errors.Add('AllowedIPs is empty')
    }
    foreach ($a in $allowed) {
        if (-not (Test-WgcIpv4Cidr -Cidr $a)) {
            $errors.Add("AllowedIPs entry $a is not an IPv4 CIDR")
        } elseif ($a -ceq '0.0.0.0/0') {
            # A full tunnel would also take the DNS and the endpoint route. Out of scope.
            $errors.Add('AllowedIPs must not contain 0.0.0.0/0')
        }
    }
    if ($Settings.PersistentKeepalive -cnotmatch '^\d{1,5}$' -or [int]$Settings.PersistentKeepalive -gt 65535) {
        $errors.Add('PersistentKeepalive must be 0-65535')
    }
    $namespaces = @(ConvertTo-WgcList -Text $Settings.NrptNamespaces)
    $servers = @(ConvertTo-WgcList -Text $Settings.NrptServers)
    foreach ($n in $namespaces) {
        if (-not (Test-WgcNamespace -Namespace $n)) { $errors.Add("NRPT namespace $n is not a DNS name") }
    }
    foreach ($s in $servers) {
        if (-not (Test-WgcIpv4 -Ip $s)) { $errors.Add("NRPT server $s is not an IPv4 address") }
    }
    if (($namespaces.Count -gt 0) -ne ($servers.Count -gt 0)) {
        $errors.Add('NrptNamespaces and NrptServers go together')
    }
    if (@('true', 'false') -cnotcontains $Settings.DisableGsaPrivateAccess) {
        $errors.Add('DisableGsaPrivateAccess must be true or false')
    }
    return ,$errors
}

# Pure. No DNS line: name resolution is done with NRPT, which is deterministic on a split tunnel.
function Get-WgcConfigText {
    param([string]$PrivateKey, $Settings)
    $allowed = (@(ConvertTo-WgcList -Text $Settings.AllowedIPs) -join ', ')
    $lines = @(
        '[Interface]',
        "PrivateKey = $PrivateKey",
        "Address = $($Settings.Address)",
        '',
        '[Peer]',
        "PublicKey = $($Settings.ServerPublicKey)",
        "Endpoint = $($Settings.Endpoint)",
        "AllowedIPs = $allowed"
    )
    if ([int]$Settings.PersistentKeepalive -gt 0) {
        $lines += "PersistentKeepalive = $([int]$Settings.PersistentKeepalive)"
    }
    return (($lines -join "`r`n") + "`r`n")
}

# Pure. The existing key is kept so the server peer stays valid across runs.
function Get-WgcPrivateKeyFromConfig {
    param([AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) {
        return ''
    }
    $m = [regex]::Match($Text, '(?m)^\s*PrivateKey\s*=\s*([A-Za-z0-9+/]{43}=)\s*$')
    if ($m.Success -and (Test-WgcKey -Key $m.Groups[1].Value)) {
        return $m.Groups[1].Value
    }
    return ''
}

# Pure. Which tagged rules to remove and which namespaces to add.
function Get-WgcNrptPlan {
    param(
        [object[]]$Existing = @(),
        [string[]]$Namespaces = @(),
        [string[]]$Servers = @(),
        [string]$Tag
    )
    $want = @{}
    foreach ($n in $Namespaces) { $want[$n.ToLowerInvariant()] = $true }
    $serverText = ($Servers -join ',')
    $remove = [System.Collections.Generic.List[object]]::new()
    $have = @{}
    foreach ($rule in $Existing) {
        if ([string]$rule.Comment -cne $Tag) {
            # Never touch a rule this package did not write.
            continue
        }
        $ns = @($rule.Namespace)[0].ToLowerInvariant()
        $same = $want.ContainsKey($ns) -and ((@($rule.NameServers) -join ',') -ceq $serverText) -and -not $have.ContainsKey($ns)
        if ($same) {
            $have[$ns] = $true
        } else {
            $remove.Add($rule)
        }
    }
    $add = @($Namespaces | Where-Object { -not $have.ContainsKey($_.ToLowerInvariant()) })
    return [pscustomobject]@{ Remove = @($remove); Add = $add }
}

function Test-WgcPinHash {
    param([string]$Sha256)
    $text = $Sha256.Trim()
    if ($text -cnotmatch '^[0-9a-f]{64}$') {
        return $false
    }
    return $text -cnotmatch '^(.)\1{63}$'
}

function Test-WgcUrlHasUserInfo {
    param([string]$Url)
    try {
        $uri = [Uri]$Url
        return $uri.IsAbsoluteUri -and -not [string]::IsNullOrEmpty($uri.UserInfo)
    } catch {
        return $false
    }
}

function Test-WgcCancelled {
    param([string]$CancelPath)
    if ($env:RELIAN_DEPLOY_CANCEL -eq '1') {
        return $true
    }
    return -not [string]::IsNullOrWhiteSpace($CancelPath) -and (Test-Path -LiteralPath $CancelPath)
}

function Get-WgcProgramFiles {
    $root = $env:ProgramFiles
    if ([string]::IsNullOrWhiteSpace($root)) {
        $root = 'C:\Program Files'
    }
    return [IO.Path]::Combine($root, 'WireGuard')
}

function Get-WgcConfigRoot {
    $root = $env:ProgramData
    if ([string]::IsNullOrWhiteSpace($root)) {
        $root = 'C:\ProgramData'
    }
    return [IO.Path]::Combine($root, 'Relian', 'WireGuard')
}

# ---- Side effects. Each is a script block so the tests replace it. ----

$script:GetArch = {
    return [string]$env:PROCESSOR_ARCHITECTURE
}

$script:GetInstalledVersion = {
    foreach ($root in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($key in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            $props = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
            if ($null -eq $props) { continue }
            $names = @($props.PSObject.Properties.Name)
            if ($names -contains 'DisplayName' -and [string]$props.DisplayName -ceq 'WireGuard' -and $names -contains 'DisplayVersion') {
                return [string]$props.DisplayVersion
            }
        }
    }
    return ''
}

$script:DownloadFile = {
    param($Url, $Destination)
    $tlsNow = [int][Net.ServicePointManager]::SecurityProtocol; if ($tlsNow -ne 0 -and ($tlsNow -band 15360) -eq 0) { [Net.ServicePointManager]::SecurityProtocol = $tlsNow -bor 3072 }
    Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing
}

$script:GetFileSha256 = {
    param($Path)
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

# msiexec is waited on and never killed. DO_NOT_LAUNCH keeps the manager UI closed.
$script:InvokeMsiExec = {
    param($InstallerPath)
    $exe = Join-Path $env:SystemRoot 'System32\msiexec.exe'
    $process = Start-Process -FilePath $exe -ArgumentList @('/i', ('"{0}"' -f $InstallerPath), '/qn', '/norestart', 'DO_NOT_LAUNCH=1') -Wait -PassThru -WindowStyle Hidden
    return [int]$process.ExitCode
}

# Runs wg.exe with optional stdin and returns stdout. Output is never written to a log.
$script:InvokeWg = {
    param([string[]]$Arguments, [string]$StdIn = '')
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = Join-Path (Get-WgcProgramFiles) 'wg.exe'
    $startInfo.Arguments = ($Arguments -join ' ')
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    $proc = [System.Diagnostics.Process]::Start($startInfo)
    try {
        if ($StdIn -ne '') { $proc.StandardInput.Write($StdIn + "`n") }
        $proc.StandardInput.Close()
        $out = $proc.StandardOutput.ReadToEndAsync()
        $null = $proc.StandardError.ReadToEndAsync()
        $proc.WaitForExit()
        if ($proc.ExitCode -ne 0) { throw 'wg.exe failed' }
        return ([string]$out.Result).Trim()
    } finally {
        $proc.Dispose()
    }
}

# Creates the folder with SYSTEM and Administrators only, before any file is written.
$script:EnsureSecureFolder = {
    param($Path)
    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'config folder is a reparse point' }
    } else {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
    $acl = [System.Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    $inherit = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
        $id = [System.Security.Principal.SecurityIdentifier]::new($sid)
        $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($id, 'FullControl', $inherit, 'None', 'Allow'))
    }
    $acl.SetOwner([System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
    Set-Acl -LiteralPath $Path -AclObject $acl
    # Files already there drop any explicit ACL and take only the folder's, so an older loose ACL cannot survive.
    if (@(Get-ChildItem -LiteralPath $Path -File -Force).Count -gt 0) {
        $icacls = Join-Path $env:SystemRoot 'System32\icacls.exe'
        & $icacls (Join-Path $Path '*') '/reset' '/C' '/Q' | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'could not reset config file ACLs' }
    }
}

$script:ReadConfig = {
    param($Path)
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    return [IO.File]::ReadAllText($Path)
}

# Write beside the target, then replace, so a half-written config never starts.
$script:WriteConfig = {
    param($Path, $Text)
    $tmp = "$Path.new"
    [IO.File]::WriteAllText($tmp, $Text, [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

$script:GetService = {
    param($Name)
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $svc) { return $null }
    return [pscustomobject]@{ Name = $svc.Name; Status = [string]$svc.Status; StartType = [string]$svc.StartType }
}

$script:InstallTunnelService = {
    param($ConfigPath)
    $exe = Join-Path (Get-WgcProgramFiles) 'wireguard.exe'
    $p = Start-Process -FilePath $exe -ArgumentList @('/installtunnelservice', ('"{0}"' -f $ConfigPath)) -Wait -PassThru -WindowStyle Hidden
    return [int]$p.ExitCode
}

$script:UninstallTunnelService = {
    param($TunnelName)
    $exe = Join-Path (Get-WgcProgramFiles) 'wireguard.exe'
    $p = Start-Process -FilePath $exe -ArgumentList @('/uninstalltunnelservice', $TunnelName) -Wait -PassThru -WindowStyle Hidden
    return [int]$p.ExitCode
}

$script:RestartService = {
    param($Name)
    Restart-Service -Name $Name -Force
}

$script:GetNrptRules = {
    return @(Get-DnsClientNrptRule -ErrorAction SilentlyContinue)
}

$script:AddNrptRule = {
    param($Namespace, [string[]]$Servers, $Comment)
    Add-DnsClientNrptRule -Namespace $Namespace -NameServers $Servers -Comment $Comment | Out-Null
}

$script:RemoveNrptRule = {
    param($Rule)
    Remove-DnsClientNrptRule -Name $Rule.Name -Force
}

# Loaded user hives only. A user who is not signed in keeps the default until the next run.
$script:SetGsaPrivateAccess = {
    param([bool]$Disabled)
    $count = 0
    foreach ($hive in @(Get-ChildItem -LiteralPath 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue)) {
        if ($hive.PSChildName -cnotmatch '^S-1-(5-21|12-1)-[0-9-]+$') { continue }
        $key = "Registry::HKEY_USERS\$($hive.PSChildName)\Software\Microsoft\Global Secure Access Client"
        if ($Disabled) {
            if (-not (Test-Path -LiteralPath $key)) { New-Item -Path $key -Force | Out-Null }
            New-ItemProperty -LiteralPath $key -Name 'IsPrivateAccessDisabledByUser' -PropertyType DWord -Value 1 -Force | Out-Null
            $count++
        } elseif (Test-Path -LiteralPath $key) {
            $v = Get-ItemProperty -LiteralPath $key -Name 'IsPrivateAccessDisabledByUser' -ErrorAction SilentlyContinue
            if ($null -ne $v -and [int]$v.IsPrivateAccessDisabledByUser -eq 1) {
                Remove-ItemProperty -LiteralPath $key -Name 'IsPrivateAccessDisabledByUser'
                $count++
            }
        }
    }
    return $count
}

$script:GetLatestHandshake = {
    param($TunnelName)
    try {
        $text = & $script:InvokeWg -Arguments @('show', $TunnelName, 'latest-handshakes')
        $epoch = [int64](($text -split '\s+')[-1])
        if ($epoch -le 0) { return $null }
        return [int64]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $epoch)
    } catch {
        return $null
    }
}

$script:RetryDelay = {
    param($Seconds)
    Start-Sleep -Seconds ([int]$Seconds)
}

# Retry only timeouts, connection and DNS failures, and HTTP 408, 429, 500, 502, 503, 504.
function Test-WgcDownloadIsTransient {
    param($Exception)
    $current = $Exception
    for ($guard = 0; $null -ne $current -and $guard -lt 8; $guard++) {
        $names = @($current.PSObject.Properties.Name)
        $status = $null
        if ($names -contains 'StatusCode' -and $null -ne $current.StatusCode) {
            $status = $current.StatusCode
        } elseif ($names -contains 'Response' -and $null -ne $current.Response -and @($current.Response.PSObject.Properties.Name) -contains 'StatusCode') {
            $status = $current.Response.StatusCode
        }
        if ($null -ne $status) {
            try { $code = [int]$status } catch { $code = 0 }
            if ($code -ge 100 -and $code -le 599) {
                return @(408, 429, 500, 502, 503, 504) -contains $code
            }
        }
        if ($current -is [System.TimeoutException] -or $current -is [System.Net.Sockets.SocketException]) {
            return $true
        }
        if ($current -is [System.Net.WebException] -and @('Timeout', 'NameResolutionFailure', 'ConnectFailure', 'ReceiveFailure', 'SendFailure', 'ConnectionClosed', 'KeepAliveFailure') -contains [string]$current.Status) {
            return $true
        }
        $current = $current.InnerException
    }
    return $false
}

function Save-WgcInstaller {
    param([string]$Url, [string]$Sha256, [string]$Destination)
    $delays = @(5, 20)
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $thrown = $null
        try {
            [void](& $script:DownloadFile -Url $Url -Destination $Destination)
        } catch {
            $thrown = $_.Exception
        }
        if ($null -eq $thrown) {
            if ((& $script:GetFileSha256 -Path $Destination) -ceq $Sha256) {
                return $true
            }
            Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
            # A hash mismatch is not retried.
            Write-WgcError 'hash mismatch for installer'
            return $false
        }
        Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
        if (-not (Test-WgcDownloadIsTransient -Exception $thrown) -or $attempt -eq 3) {
            break
        }
        [void](& $script:RetryDelay -Seconds $delays[$attempt - 1])
    }
    Write-WgcError 'download failed for installer'
    return $false
}

# The hash for this device's architecture, and the name of its URL field.
# The URL itself is read only after the empty-hash no-op.
function Get-WgcApplicablePin {
    param($Pins, [string]$Arch)
    if ($Arch -ceq 'ARM64') {
        return [pscustomobject]@{ UrlField = 'ArmUrl'; Sha256 = [string]$Pins.ArmSha256 }
    }
    return [pscustomobject]@{ UrlField = 'Url'; Sha256 = [string]$Pins.Sha256 }
}

function Invoke-WireGuardClientAction {
    param([string]$Action, [string]$PinVersion, [string]$CancelPath, $Settings, $Pins)

    $report = [ordered]@{
        mode = $Action; tunnelName = $Settings.TunnelName; address = $Settings.Address; publicKey = $null
        installedVersion = $null; service = $null; latestHandshakeSecondsAgo = $null
        nrptNamespaces = @(); gsaHivesChanged = 0; errors = $script:WgcErrors
    }
    $result = { param($Code) [pscustomobject]@{ ExitCode = [int]$Code; Report = $report } }

    # An empty pin, or an empty hash for this device's architecture, disables the package.
    $applicable = Get-WgcApplicablePin -Pins $Pins -Arch ([string](& $script:GetArch))
    if ([string]::IsNullOrWhiteSpace($PinVersion) -or [string]::IsNullOrWhiteSpace($applicable.Sha256)) {
        return (& $result 0)
    }
    if (@('Install', 'Update', 'Repair', 'Uninstall', 'Check') -cnotcontains $Action) {
        Write-WgcError "action $Action is not supported"
        return (& $result 1)
    }
    # Only actions that may download check the pin. Uninstall and Check never download.
    if (@('Install', 'Update', 'Repair') -ccontains $Action -and ((Test-WgcUrlHasUserInfo -Url ([string]$Pins.($applicable.UrlField))) -or -not (Test-WgcPinHash -Sha256 $applicable.Sha256))) {
        Write-WgcError 'invalid installer pin'
        return (& $result 1)
    }
    if (-not (Test-WgcTunnelName -Name $Settings.TunnelName)) {
        Write-WgcError 'TunnelName must be lower case letters, digits, or dashes'
        return (& $result 1)
    }
    $folder = Get-WgcConfigRoot
    $configPath = [IO.Path]::Combine($folder, "$($Settings.TunnelName).conf")
    $serviceName = 'WireGuardTunnel$' + $Settings.TunnelName
    $tag = $script:NrptTagPrefix + $Settings.TunnelName

    if ($Action -ceq 'Uninstall') {
        if ($null -ne (& $script:GetService -Name $serviceName)) {
            $code = [int](& $script:UninstallTunnelService -TunnelName $Settings.TunnelName)
            if ($code -ne 0) {
                Write-WgcError "uninstalltunnelservice failed with $code"
                return (& $result 1)
            }
        }
        $plan = Get-WgcNrptPlan -Existing @(& $script:GetNrptRules) -Namespaces @() -Servers @() -Tag $tag
        foreach ($rule in $plan.Remove) { & $script:RemoveNrptRule -Rule $rule }
        $report.gsaHivesChanged = [int](& $script:SetGsaPrivateAccess -Disabled $false)
        if (Test-Path -LiteralPath $configPath) { Remove-Item -LiteralPath $configPath -Force }
        return (& $result 0)
    }

    $installed = [string](& $script:GetInstalledVersion)
    $report.installedVersion = $installed
    if ($Action -ceq 'Check') {
        $report.service = & $script:GetService -Name $serviceName
        $report.publicKey = $null
        $key = Get-WgcPrivateKeyFromConfig -Text ([string](& $script:ReadConfig -Path $configPath))
        if ($key -ne '') { $report.publicKey = [string](& $script:InvokeWg -Arguments @('pubkey') -StdIn $key) }
        $key = $null
        $report.nrptNamespaces = @(@(& $script:GetNrptRules) | Where-Object { [string]$_.Comment -ceq $tag } | ForEach-Object { @($_.Namespace)[0] })
        $report.latestHandshakeSecondsAgo = & $script:GetLatestHandshake -TunnelName $Settings.TunnelName
        return (& $result 0)
    }

    $settingErrors = Get-WgcSettingsErrors -Settings $Settings
    if ($settingErrors.Count -gt 0) {
        foreach ($e in $settingErrors) { Write-WgcError $e }
        return (& $result 1)
    }

    # 1. Installer, when missing or below the pin.
    $pin = [version]$PinVersion
    $have = $null
    if ($installed -ne '') { try { $have = [version]$installed } catch { $have = $null } }
    if ($null -eq $have -or $have.CompareTo($pin) -lt 0) {
        $url = [string]$Pins.($applicable.UrlField)
        $sha = $applicable.Sha256
        if (Test-WgcCancelled -CancelPath $CancelPath) { return (& $result 130) }
        $cache = Join-Path ([IO.Path]::GetTempPath()) ('relian-wireguard-' + [guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path $cache -Force | Out-Null
        try {
            $msi = Join-Path $cache ([IO.Path]::GetFileName(([Uri]$url).AbsolutePath))
            if (-not (Save-WgcInstaller -Url $url -Sha256 $sha -Destination $msi)) { return (& $result 1) }
            $code = [int](& $script:InvokeMsiExec -InstallerPath $msi)
            if ($code -ne 0 -and $code -ne 3010) {
                Write-WgcError "installer failed with $code"
                return (& $result 1)
            }
        } finally {
            Remove-Item -LiteralPath $cache -Recurse -Force -ErrorAction SilentlyContinue
        }
        $report.installedVersion = [string](& $script:GetInstalledVersion)
    }

    # 2. Folder ACL first, then the key and the config.
    & $script:EnsureSecureFolder -Path $folder
    $current = [string](& $script:ReadConfig -Path $configPath)
    $privateKey = Get-WgcPrivateKeyFromConfig -Text $current
    if ($privateKey -eq '') {
        $privateKey = [string](& $script:InvokeWg -Arguments @('genkey'))
        if (-not (Test-WgcKey -Key $privateKey)) {
            $privateKey = $null
            Write-WgcError 'wg.exe genkey returned no key'
            return (& $result 1)
        }
    }
    $wanted = Get-WgcConfigText -PrivateKey $privateKey -Settings $Settings
    $report.publicKey = [string](& $script:InvokeWg -Arguments @('pubkey') -StdIn $privateKey)
    $privateKey = $null
    $changed = $wanted -cne $current
    if ($changed) {
        & $script:WriteConfig -Path $configPath -Text $wanted
    }
    $wanted = $null
    $current = $null

    # 3. Tunnel service.
    $svc = & $script:GetService -Name $serviceName
    if ($null -eq $svc) {
        $code = [int](& $script:InstallTunnelService -ConfigPath $configPath)
        if ($code -ne 0) {
            Write-WgcError "installtunnelservice failed with $code"
            return (& $result 1)
        }
    } elseif ($changed -and $svc.Status -ceq 'Running') {
        # Only a running tunnel is restarted. A tunnel the network guard stopped stays stopped.
        & $script:RestartService -Name $serviceName
    }
    $report.service = & $script:GetService -Name $serviceName

    # 4. NRPT rules carrying this package's tag.
    $namespaces = @(ConvertTo-WgcList -Text $Settings.NrptNamespaces)
    $servers = @(ConvertTo-WgcList -Text $Settings.NrptServers)
    $plan = Get-WgcNrptPlan -Existing @(& $script:GetNrptRules) -Namespaces $namespaces -Servers $servers -Tag $tag
    foreach ($rule in $plan.Remove) { & $script:RemoveNrptRule -Rule $rule }
    foreach ($n in $plan.Add) { & $script:AddNrptRule -Namespace $n -Servers $servers -Comment $tag }
    $report.nrptNamespaces = $namespaces

    # 5. GSA Private Access, only when asked.
    if ($Settings.DisableGsaPrivateAccess -ceq 'true') {
        $report.gsaHivesChanged = [int](& $script:SetGsaPrivateAccess -Disabled $true)
    }
    $report.latestHandshakeSecondsAgo = & $script:GetLatestHandshake -TunnelName $Settings.TunnelName
    return (& $result 0)
}

if ($env:RELIAN_DEPLOY_TEST -eq '1' -and $MyInvocation.InvocationName -eq '.') {
    return
}

$pins = [pscustomobject]@{ Url = $InstallerUrl; Sha256 = $InstallerSha256; ArmUrl = $ArmInstallerUrl; ArmSha256 = $ArmInstallerSha256 }
# An empty hash for this device's architecture is a no-op before parameter validation.
if ([string]::IsNullOrWhiteSpace((Get-WgcApplicablePin -Pins $pins -Arch ([string](& $script:GetArch))).Sha256)) {
    exit 0
}
foreach ($name in @('DeploymentType', 'Action', 'PinVersion')) {
    if (-not $PSBoundParameters.ContainsKey($name)) {
        [Console]::Error.WriteLine("missing parameter $name")
        exit 1
    }
}

$runAction = $Action
if ($Mode -ceq 'Check') {
    $runAction = 'Check'
}
$settings = [pscustomobject]@{
    TunnelName = $TunnelName; Address = $Address; ServerPublicKey = $ServerPublicKey; Endpoint = $Endpoint
    AllowedIPs = $AllowedIPs; PersistentKeepalive = $PersistentKeepalive; NrptNamespaces = $NrptNamespaces
    NrptServers = $NrptServers; DisableGsaPrivateAccess = $DisableGsaPrivateAccess
}
try {
    $out = Invoke-WireGuardClientAction -Action $runAction -PinVersion $PinVersion -CancelPath $CancelPath -Settings $settings -Pins $pins
    $code = $out.ExitCode
    $report = $out.Report
} catch {
    # The exception text could quote a config line. Do not print it.
    [Console]::Error.WriteLine('WireGuard client package failed')
    $code = 1
    $report = [ordered]@{ mode = $runAction; errors = @('unhandled error') }
}
[Console]::Out.WriteLine(($report | ConvertTo-Json -Compress -Depth 4))
exit $code
