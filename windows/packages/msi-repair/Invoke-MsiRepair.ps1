<#
.SYNOPSIS
    Repairs one installed Windows Installer product machine-wide, or reports evidence about it.

.DESCRIPTION
    Run as SYSTEM by the Relian deploy runner. Downloads nothing.
    Product: -ProductCode (a GUID in braces) or -DisplayName (exact match against the HKLM Uninstall keys,
    64- and 32-bit views). A name must resolve to exactly one Windows Installer product, else exit 1
    and the candidates are listed.
    -RepairMode is one of /fa (default, reinstall all files) or /fomus (reinstall files that are missing
    or older, plus all machine/user registry and shortcuts; "omus" is the Windows Installer
    REINSTALLMODE default). Other flag sets are refused.
    Sources: https://learn.microsoft.com/windows/win32/msi/command-line-options (/f options)
             https://learn.microsoft.com/windows/win32/msi/reinstallmode
    -Section Evidence (read-only, any action): the product, whether its cached MSI exists, and the last
      10 MsiInstaller events for it. Nothing is changed.
    -Action Install, Update, Repair or Reinstall: msiexec /f<mode> <code> /qn /norestart /l*v <log>.
      msiexec is waited for and never killed. Success is exit code 0 or 3010 (reboot needed, not done).
      Refused when the cached MSI (LocalPackage) is missing, because repair would need the original
      media, unless -SourcePath names an MSI whose ProductCode matches.
    An empty -PinVersion does nothing and exits 0.
    Prints one JSON line of at most 8,000 bytes. Exit 0 or 1.
#>
[CmdletBinding()]
param(
    [string]$DeploymentType = '',
    [string]$Action = '',
    [string]$PinVersion = '',
    [string]$Section = '',
    [string]$ProductCode = '',
    [string]$DisplayName = '',
    [string]$RepairMode = '',
    [string]$SourcePath = ''
)

$ErrorActionPreference = 'Stop'
$script:MrModes = @('/fa', '/fomus')
$script:MrGuid = '\A\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}\z'
$script:MrEventIds = @(1035, 11729, 1004, 1001, 1033, 11708)

# Seams: tests replace these. The defaults touch the real machine.
$script:MrEntries = {
    foreach ($p in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall') {
        foreach ($k in @(Get-ChildItem -LiteralPath $p -ErrorAction SilentlyContinue)) {
            $v = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
            [pscustomobject]@{ Key = $k.PSChildName; Name = [string]$v.DisplayName; Version = [string]$v.DisplayVersion; Msi = ($v.WindowsInstaller -eq 1 -and $k.PSChildName -match $script:MrGuid) }
        }
    }
}
# ProductInfo property of an installed product (LocalPackage, InstallSource); $null when unknown.
$script:MrProductInfo = {
    param([string]$Code, [string]$Name)
    $i = $null
    try { $i = New-Object -ComObject WindowsInstaller.Installer; $v = [string]$i.ProductInfo($Code, $Name); if ($v) { $v } else { $null } }
    catch { $null }
    finally { if ($i) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($i) } }
}
$script:MrFileExists = { param([string]$Path) [IO.File]::Exists($Path) }
# Value of one Property-table row of an MSI file.
$script:MrMsiProperty = {
    param([string]$Path, [string]$Name)
    $i = New-Object -ComObject WindowsInstaller.Installer
    $db = $i.OpenDatabase($Path, 0)
    $view = $db.OpenView("SELECT ``Value`` FROM ``Property`` WHERE ``Property``='$Name'")
    $view.Execute()
    $rec = $view.Fetch()
    if ($rec) { $rec.StringData(1) }
    $view.Close()
}
$script:MrEvents = {
    @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'MsiInstaller'; Id = $script:MrEventIds } -MaxEvents 300 -ErrorAction SilentlyContinue |
        ForEach-Object { [pscustomobject]@{ Id = [int]$_.Id; TimeCreated = $_.TimeCreated; Message = [string]$_.Message } })
}
$script:MrLogPath = {
    $dir = Join-Path $env:ProgramData 'Relian\msi-repair'
    [void][IO.Directory]::CreateDirectory($dir)
    Join-Path $dir ((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ') + '.log')
}
$script:MrRun = {
    param([string]$ArgumentString)
    # Waits for msiexec however long it takes; it is never killed.
    (Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\msiexec.exe') -ArgumentList $ArgumentString -Wait -PassThru -WindowStyle Hidden).ExitCode
}
$script:MrLogLines = { param([string]$Path) @(Get-Content -LiteralPath $Path -Tail 600 -ErrorAction Stop) }

function Protect-MrText {
    param([string]$Text, [int]$Max = 300)
    if ($Text -match '(?i)password|passwd|\bpwd\s*=|secret|token|authorization|bearer|credential|api.?key|accountkey|product.?key') { return '[sensitive line omitted]' }
    $t = $Text -replace '(?i)[a-z][a-z0-9+.-]*://\S+', '[url omitted]'
    $t = $t -replace '(?i)([a-z]:\\Users\\)[^\\\s]+', '$1[redacted]'
    $t = ($t -replace '[\x00-\x08\x0B\x0C\x0E-\x1F]', ' ').Trim()
    if ($t.Length -gt $Max) { return $t.Substring(0, $Max) + '[clipped]' }
    return $t
}

function ConvertTo-MrJson {
    param($Result, [int]$MaxBytes = 8000)
    $json = ConvertTo-Json -InputObject $Result -Depth 6 -Compress
    # Drop the bulky lists, largest first, until the line fits.
    foreach ($key in 'events', 'logErrors', 'candidates') {
        if ([Text.Encoding]::UTF8.GetByteCount($json) -le $MaxBytes) { break }
        if ($Result.Contains($key)) { $Result[$key] = @(); $Result['truncated'] = $true; $json = ConvertTo-Json -InputObject $Result -Depth 6 -Compress }
    }
    if ([Text.Encoding]::UTF8.GetByteCount($json) -gt $MaxBytes) { return '{"package":"msi-repair","status":"error","reason":"output too large"}' }
    return $json
}

function Get-MrArguments {
    param([string]$Mode, [string]$Target, [string]$LogPath)
    "$Mode $Target /qn /norestart /l*v `"$LogPath`""
}

# Returns @{ Product; Error; Candidates }.
function Resolve-MrProduct {
    param([string]$ProductCode, [string]$DisplayName)
    $entries = @(& $script:MrEntries)
    if ($ProductCode) {
        if ($ProductCode -notmatch $script:MrGuid) { return @{ Error = 'ProductCode must be a GUID in braces' } }
        $hit = @($entries | Where-Object { $_.Msi -and $_.Key -eq $ProductCode })
        if ($hit.Count -eq 0) { return @{ Error = 'ProductCode is not an installed Windows Installer product' } }
        return @{ Product = $hit[0] }
    }
    $named = @($entries | Where-Object { $_.Name -eq $DisplayName } | Sort-Object Key -Unique)
    $msi = @($named | Where-Object { $_.Msi })
    if ($msi.Count -eq 1) { return @{ Product = $msi[0] } }
    $pool = if ($msi.Count -gt 1) { $msi } else { @($entries | Where-Object { $_.Msi -and $_.Name -and $_.Name.IndexOf($DisplayName, [StringComparison]::OrdinalIgnoreCase) -ge 0 }) }
    $cand = @($pool | Select-Object -First 10 | ForEach-Object { [ordered]@{ name = (Protect-MrText $_.Name 120); version = $_.Version; code = $_.Key } })
    $why = if ($msi.Count -gt 1) { 'DisplayName matches more than one Windows Installer product' }
           elseif ($named.Count -gt 0) { 'DisplayName matches no Windows Installer product (not an MSI install)' }
           else { 'DisplayName matches no installed product' }
    return @{ Error = $why; Candidates = $cand }
}

function Get-MrEvents {
    param($Product)
    $mine = @(& $script:MrEvents | Where-Object {
        $_.Message.IndexOf($Product.Key, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
        ($Product.Name -and $_.Message.IndexOf($Product.Name, [StringComparison]::OrdinalIgnoreCase) -ge 0) } |
        Sort-Object TimeCreated -Descending | Select-Object -First 10)
    @($mine | ForEach-Object { [ordered]@{ id = $_.Id; time = ([datetime]$_.TimeCreated).ToUniversalTime().ToString('o'); message = (Protect-MrText $_.Message 200) } })
}

function Invoke-MrMain {
    param([string]$PinVersion = '', [string]$Action = '', [string]$Section = '', [string]$ProductCode = '', [string]$DisplayName = '', [string]$RepairMode = '', [string]$SourcePath = '')
    $r = [ordered]@{ package = 'msi-repair'; status = 'error' }
    # An empty pin is the fleet's off switch: do nothing, for every action and section.
    if (-not $PinVersion) { $r.status = 'noPin'; return @{ ExitCode = 0; Result = $r } }
    $fail = { param($why) $r.reason = $why; return @{ ExitCode = 1; Result = $r } }
    if ($Section -and $Section -ne 'Evidence') { return & $fail 'Section must be empty or Evidence' }
    $evidence = $Section -eq 'Evidence'
    if (-not $evidence) {
        if ($Action -eq 'Uninstall') { $r.status = 'nothingToUninstall'; return @{ ExitCode = 0; Result = $r } }
        if (@('Install', 'Update', 'Repair', 'Reinstall') -notcontains $Action) { return & $fail 'Unsupported action' }
    }
    if ([bool]$ProductCode -eq [bool]$DisplayName) { return & $fail 'Give exactly one of ProductCode or DisplayName' }
    $mode = if ($RepairMode) { $RepairMode.ToLowerInvariant() } else { '/fa' }
    if ($script:MrModes -notcontains $mode) { return & $fail ('RepairMode must be one of: ' + ($script:MrModes -join ', ')) }

    $res = Resolve-MrProduct -ProductCode $ProductCode -DisplayName $DisplayName
    if ($res.Error) {
        $r.reason = $res.Error
        if ($res.Candidates) { $r.candidates = $res.Candidates }
        return @{ ExitCode = 1; Result = $r }
    }
    $p = $res.Product
    $local = & $script:MrProductInfo $p.Key 'LocalPackage'
    $cached = [bool]($local -and (& $script:MrFileExists $local))
    $r.product = [ordered]@{ name = (Protect-MrText $p.Name 200); version = $p.Version; code = $p.Key; installSource = (Protect-MrText ([string](& $script:MrProductInfo $p.Key 'InstallSource')) 200); cachedMsiPresent = $cached }

    if ($evidence) {
        $r.status = 'evidence'
        $r.events = @(Get-MrEvents $p)
        return @{ ExitCode = 0; Result = $r }
    }

    $target = $p.Key
    if (-not $cached) {
        if (-not $SourcePath) { return & $fail 'The cached MSI (LocalPackage) is missing, so repair would need the original install media. Pass SourcePath, an MSI with the same ProductCode.' }
        if ($SourcePath -notmatch '(?i)\.msi\z' -or $SourcePath -notmatch '\A([A-Za-z]:\\|\\\\)' -or -not (& $script:MrFileExists $SourcePath)) { return & $fail 'SourcePath must be an existing absolute path to an .msi file' }
        $code = $null
        try { $code = [string](& $script:MrMsiProperty $SourcePath 'ProductCode') } catch { return & $fail 'SourcePath could not be read as an MSI' }
        if ($code -ne $p.Key) { return & $fail 'SourcePath ProductCode does not match the product' }
        $target = '"' + $SourcePath + '"'
    }

    $log = & $script:MrLogPath
    $exit = [int](& $script:MrRun (Get-MrArguments -Mode $mode -Target $target -LogPath $log))
    $r.exitCode = $exit
    $r.repairMode = $mode
    $r.log = $log
    $r.rebootRequired = $exit -eq 3010
    $r.logErrors = @()
    try {
        $r.logErrors = @(& $script:MrLogLines $log | Where-Object { $_ -match '(?i)return value 3|\berror\b|failed' } | Select-Object -Last 8 | ForEach-Object { Protect-MrText $_ 200 })
    } catch { $r.logNote = 'log not readable' }
    if ($exit -eq 0 -or $exit -eq 3010) { $r.status = 'repaired'; return @{ ExitCode = 0; Result = $r } }
    $r.reason = "msiexec exited $exit"
    return @{ ExitCode = 1; Result = $r }
}

if ($env:RELIAN_DEPLOY_TEST -eq '1' -and $MyInvocation.InvocationName -eq '.') { return }

try {
    $run = Invoke-MrMain -PinVersion $PinVersion -Action $Action -Section $Section -ProductCode $ProductCode -DisplayName $DisplayName -RepairMode $RepairMode -SourcePath $SourcePath
} catch {
    $run = @{ ExitCode = 1; Result = [ordered]@{ package = 'msi-repair'; status = 'error'; reason = $_.Exception.GetType().Name } }
}
Write-Output (ConvertTo-MrJson $run.Result)
exit $run.ExitCode
