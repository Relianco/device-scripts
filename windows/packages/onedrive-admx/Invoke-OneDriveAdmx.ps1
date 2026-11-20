<#
.SYNOPSIS
    Refreshes OneDrive.admx and its en-US OneDrive.adml in a domain's Group Policy Central Store.
.DESCRIPTION
    Runs through the Relian deploy runner (NinjaOne script 374) as SYSTEM on a domain controller, Windows
    PowerShell 5.1. The runner decodes the base64 JSON in -PackageArguments and passes each key as a named
    parameter. All values are strings:
      Mode        Plan (default) reports and changes nothing. Apply writes.
      AdmxUrl, AdmxSha256, AdmlUrl, AdmlSha256
                  Optional, all four or none. A pinned https download of the two files, for a DC without OneDrive.
                  Without them the newest machine-wide OneDrive install on this device is the source:
                  %ProgramFiles%\Microsoft OneDrive\<version>\adm (and the x86 folder).

    The store is <SYSVOL>\<domain>\Policies\PolicyDefinitions on this DC. It must already exist, with an
    en-US folder; nothing is created there. Only OneDrive.admx and en-US\OneDrive.adml are read or written.
    Every other file in the store is left alone. A source file must parse as the right XML root and carry its
    SHA256 in the report; a download is checked against its pinned hash before anything is written.

    Apply: files that already match the source byte for byte are left alone (idempotent, no backup). Otherwise
    the current OneDrive.admx/.adml are copied to C:\Relian\AdmxBackup\<UTC timestamp>\ (new folder every run,
    SYSTEM and Administrators only, hash-checked; both files when either changes) before any write. Then the .adml is written, then the .admx
    (a new template never meets old strings), each through a temp file in the store and a replace. Last, both
    files are read back and compared with the source. Rollback: copy the backup files back.

    An empty -PinVersion exits 0 and changes nothing. Action Uninstall is refused.
    Prints one JSON line, at most 4000 bytes. Exit 0 for a plan, no change or a verified apply; 1 otherwise.
#>
[CmdletBinding()]
param(
    [string]$DeploymentType = '',
    [string]$Action = '',
    [string]$PinVersion = '',
    [string]$Mode = 'Plan',
    [string]$AdmxUrl = '',
    [string]$AdmxSha256 = '',
    [string]$AdmlUrl = '',
    [string]$AdmlSha256 = ''
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$script:OaMaxBytes = 4000
$script:OaMaxFile = 2MB
$script:OaBackupRoot = 'C:\Relian\AdmxBackup'

# Seams. Tests replace these; the defaults touch the DC.
$script:OaIsDc = { [int](Get-CimInstance -ClassName Win32_ComputerSystem).DomainRole -ge 4 }
$script:OaStoreDir = {
    $sysvol = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon\Parameters').SysVol
    Join-Path $sysvol ((Get-CimInstance -ClassName Win32_ComputerSystem).Domain + '\Policies\PolicyDefinitions')
}
$script:OaInstallRoots = {
    @($env:ProgramFiles, [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')) | Where-Object { $_ } | ForEach-Object { Join-Path $_ 'Microsoft OneDrive' }
}
$script:OaDownload = {
    param($Url)
    $tls = [int][Net.ServicePointManager]::SecurityProtocol; if ($tls -ne 0 -and ($tls -band 3072) -eq 0) { [Net.ServicePointManager]::SecurityProtocol = $tls -bor 3072 }
    $temp = [IO.Path]::GetTempFileName()
    try {
        Invoke-WebRequest -Uri $Url -OutFile $temp -UseBasicParsing -TimeoutSec 120 -MaximumRedirection 0
        , [IO.File]::ReadAllBytes($temp)
    } finally { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
}
$script:OaDelay = { param($Seconds) Start-Sleep -Seconds $Seconds }
$script:OaNow = { [DateTime]::UtcNow }
$script:OaProtectDir = {
    param($Path)
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetSecurityDescriptorSddlForm('O:SYG:SYD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)')
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Get-OaSha256([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256CryptoServiceProvider]::new()
    try { ([BitConverter]::ToString($sha.ComputeHash($Bytes)) -replace '-', '').ToLowerInvariant() } finally { $sha.Dispose() }
}

# Returns the root element's revision attribute, or throws when the bytes are not that kind of document.
function Get-OaRevision([byte[]]$Bytes, [string]$Root) {
    if ($Bytes.Length -eq 0 -or $Bytes.Length -gt $script:OaMaxFile) { throw 'file is empty or over 2 MiB' }
    $settings = New-Object Xml.XmlReaderSettings
    $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $stream = New-Object IO.MemoryStream (, $Bytes)
    $reader = [Xml.XmlReader]::Create($stream, $settings)
    try {
        $doc = New-Object Xml.XmlDocument
        $doc.XmlResolver = $null
        $doc.Load($reader)
    } finally { $reader.Dispose() }
    if ($doc.DocumentElement.LocalName -cne $Root) { throw "root element is not $Root" }
    [string]$doc.DocumentElement.GetAttribute('revision')
}

function Get-OaState([string]$Path, [string]$Root) {
    $state = @{ present = $false; sha256 = $null; date = $null; revision = $null }
    if (-not [IO.File]::Exists($Path)) { return $state }
    $bytes = [IO.File]::ReadAllBytes($Path)
    $state.present = $true
    $state.sha256 = Get-OaSha256 $bytes
    $state.date = ([IO.File]::GetLastWriteTimeUtc($Path)).ToString('yyyy-MM-dd')
    try { $state.revision = Get-OaRevision $bytes $Root } catch { $state.revision = 'unreadable' }
    $state
}

# A timeout, connection or DNS failure (no HTTP response), or HTTP 408, 429, 500, 502, 503, 504.
function Test-OaRetryable($Exception) {
    $response = $Exception.PSObject.Properties['Response']
    if ($response -and $response.Value) { return @(408, 429, 500, 502, 503, 504) -contains [int]$response.Value.StatusCode }
    $true
}

function Test-OaHttpsNoUserInfo([string]$Url) {
    if ($Url -match '\A\s*[a-z][a-z0-9+.-]*:[\\/]{2}[^\\/?#]*@') { return $false }
    $uri = $null
    [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri) -and $uri.Scheme -eq 'https'
}

# Newest machine-wide install that holds both files. Folder names that are not a plain version are skipped.
function Find-OaInstallSource {
    $found = @()
    foreach ($root in @(& $script:OaInstallRoots)) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($dir in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
            $version = $null
            if ($dir.Name -notmatch '\A\d+(\.\d+){1,3}\z' -or -not [Version]::TryParse($dir.Name, [ref]$version)) { continue }
            $admx = Join-Path $dir.FullName 'adm\OneDrive.admx'
            $adml = @((Join-Path $dir.FullName 'adm\en-US\OneDrive.adml'), (Join-Path $dir.FullName 'adm\OneDrive.adml')) | Where-Object { [IO.File]::Exists($_) } | Select-Object -First 1
            if ([IO.File]::Exists($admx) -and $adml) { $found += [pscustomobject]@{ Version = $version; Name = $dir.Name; Admx = $admx; Adml = $adml } }
        }
    }
    $found | Sort-Object Version -Descending | Select-Object -First 1
}

function Get-OaSource {
    param($Params)
    $given = @($Params.AdmxUrl, $Params.AdmxSha256, $Params.AdmlUrl, $Params.AdmlSha256 | Where-Object { $_ })
    if ($given.Count -eq 0) {
        $install = Find-OaInstallSource
        if (-not $install) { throw 'no machine-wide OneDrive install with adm files on this device, and no download given' }
        return @{ from = 'install'; version = $install.Name
                  admx = [IO.File]::ReadAllBytes($install.Admx); adml = [IO.File]::ReadAllBytes($install.Adml) }
    }
    if ($given.Count -ne 4) { throw 'give all of AdmxUrl, AdmxSha256, AdmlUrl, AdmlSha256 or none' }
    # Validate all four values before the first download.
    foreach ($kind in 'Admx', 'Adml') {
        if ($Params.($kind + 'Sha256') -cnotmatch '\A[0-9a-f]{64}\z') { throw "$($kind)Sha256 is not 64 lowercase hex characters" }
        if (-not (Test-OaHttpsNoUserInfo $Params.($kind + 'Url'))) { throw "$($kind)Url is not https without userinfo" }
    }
    $out = @{ from = 'download'; version = $null }
    foreach ($kind in 'Admx', 'Adml') {
        $url = $Params.($kind + 'Url'); $pin = $Params.($kind + 'Sha256')
        $bytes = $null
        for ($attempt = 1; $null -eq $bytes; $attempt++) {
            try { $bytes = [byte[]](& $script:OaDownload $url) } catch {
                if ($attempt -ge 3 -or -not (Test-OaRetryable $_.Exception)) { throw }
                & $script:OaDelay (@(5, 20)[$attempt - 1])
            }
        }
        if ((Get-OaSha256 $bytes) -ne $pin) { throw "hash mismatch for the $kind download" }
        $out[$kind.ToLowerInvariant()] = $bytes
    }
    $out
}

function Invoke-OaMain {
    param(
        [string]$Action = '', [string]$PinVersion = 'pinned', [string]$Mode = 'Plan',
        [string]$AdmxUrl = '', [string]$AdmxSha256 = '', [string]$AdmlUrl = '', [string]$AdmlSha256 = ''
    )
    $result = [ordered]@{ job = 'onedrive-admx'; status = 'failed'; mode = $Mode; source = $null; files = @(); backup = $null; error = $null }
    if ([string]::IsNullOrWhiteSpace($PinVersion)) { $result.status = 'disabled'; return @{ ExitCode = 0; Result = $result } }
    try {
        if ($Action -eq 'Uninstall') { throw 'Uninstall is not supported: restore from C:\Relian\AdmxBackup' }
        if ($Mode -cne 'Plan' -and $Mode -cne 'Apply') { throw 'Mode must be Plan or Apply' }
        if (-not (& $script:OaIsDc)) { throw 'this device is not a domain controller' }
        $store = & $script:OaStoreDir
        $lang = Join-Path $store 'en-US'
        if (-not (Test-Path -LiteralPath $lang -PathType Container)) { throw 'the store or its en-US folder does not exist; nothing is created' }

        $src = Get-OaSource @{ AdmxUrl = $AdmxUrl; AdmxSha256 = $AdmxSha256; AdmlUrl = $AdmlUrl; AdmlSha256 = $AdmlSha256 }
        $result.source = [ordered]@{ from = $src.from; version = $src.version }
        # adml first: a new template must not meet old strings.
        $plan = foreach ($f in @(@{ Name = 'OneDrive.adml'; Dir = $lang; Bytes = $src.adml; Root = 'policyDefinitionResources' },
                                 @{ Name = 'OneDrive.admx'; Dir = $store; Bytes = $src.admx; Root = 'policyDefinitions' })) {
            $newRev = Get-OaRevision $f.Bytes $f.Root
            $path = Join-Path $f.Dir $f.Name
            $before = Get-OaState $path $f.Root
            $newSha = Get-OaSha256 $f.Bytes
            $act = if (-not $before.present) { 'create' } elseif ($before.sha256 -eq $newSha) { 'none' } else { 'replace' }
            [pscustomobject]@{ Spec = $f; Path = $path; Before = $before; NewSha = $newSha; NewRev = $newRev; Act = $act }
        }
        $result.files = @($plan | ForEach-Object {
            [ordered]@{ name = $_.Spec.Name; action = $_.Act; currentDate = $_.Before.date; currentRevision = $_.Before.revision
                        currentSha256 = $_.Before.sha256; newRevision = $_.NewRev; newSha256 = $_.NewSha }
        })
        $changes = @($plan | Where-Object { $_.Act -ne 'none' })
        if ($changes.Count -eq 0) { $result.status = 'current'; return @{ ExitCode = 0; Result = $result } }
        if ($Mode -ne 'Apply') { $result.status = 'plan'; return @{ ExitCode = 0; Result = $result } }

        $stamp = (& $script:OaNow).ToString('yyyyMMddTHHmmssZ')
        $backup = Join-Path $script:OaBackupRoot $stamp
        [void](New-Item -ItemType Directory -Path $script:OaBackupRoot -Force)
        # New folder, never reused: a clash is an error, not an overwrite.
        [void](New-Item -ItemType Directory -Path $backup)
        & $script:OaProtectDir $backup
        $result.backup = $backup
        # Both existing files, even when only one changes: the backup is a complete restore set.
        foreach ($c in @($plan | Where-Object { $_.Before.present })) {
            $copy = Join-Path $backup $c.Spec.Name
            [IO.File]::Copy($c.Path, $copy)
            if ((Get-OaSha256 ([IO.File]::ReadAllBytes($copy))) -ne $c.Before.sha256) { throw "backup of $($c.Spec.Name) does not match" }
        }
        foreach ($c in $changes) {
            $temp = $c.Path + '.relian-new'
            try {
                [IO.File]::WriteAllBytes($temp, $c.Spec.Bytes)
                if ($c.Act -eq 'replace') { [IO.File]::Replace($temp, $c.Path, [NullString]::Value) } else { [IO.File]::Move($temp, $c.Path) }
            } finally { if ([IO.File]::Exists($temp)) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue } }
        }
        $verified = @()
        foreach ($c in $plan) {
            $after = Get-OaState $c.Path $c.Spec.Root
            if ($after.sha256 -ne $c.NewSha) { throw "read-back of $($c.Spec.Name) does not match the source" }
            $verified += [ordered]@{ name = $c.Spec.Name; date = $after.date; revision = $after.revision; sha256 = $after.sha256 }
        }
        $result.files = $verified
        $result.status = 'applied'
        return @{ ExitCode = 0; Result = $result }
    } catch {
        $message = [string]$_.Exception.Message
        foreach ($u in @($AdmxUrl, $AdmlUrl)) { if ($u) { $message = $message.Replace($u, 'a download URL') } }
        $result.error = $message
        return @{ ExitCode = 1; Result = $result }
    }
}

function ConvertTo-OaLine($Result) {
    $line = ConvertTo-Json -InputObject $Result -Depth 4 -Compress
    if ([Text.Encoding]::UTF8.GetByteCount($line) -gt $script:OaMaxBytes) {
        $Result.files = @(); $Result.error = 'output too large'
        $line = ConvertTo-Json -InputObject $Result -Depth 4 -Compress
    }
    $line
}

if ($env:RELIAN_DEPLOY_TEST -eq '1' -and $MyInvocation.InvocationName -eq '.') {
    return
}

$run = Invoke-OaMain -Action $Action -PinVersion $PinVersion -Mode $Mode -AdmxUrl $AdmxUrl -AdmxSha256 $AdmxSha256 -AdmlUrl $AdmlUrl -AdmlSha256 $AdmlSha256
Write-Output (ConvertTo-OaLine $run.Result)
exit $run.ExitCode
