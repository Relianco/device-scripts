$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$scriptPath = Join-Path $repoRoot 'windows/packages/virtio-guest-tools/Invoke-VirtioGuestTools.ps1'
$releasePath = Join-Path $repoRoot 'windows/releases/virtio-guest-tools.json'

function Assert($ok, [string]$message) { if (-not $ok) { [Console]::Error.WriteLine("FAIL $message"); exit 1 } }

foreach ($path in @($scriptPath, $releasePath)) { Assert (Test-Path -LiteralPath $path) "$path does not exist" }

$env:RELIAN_DEPLOY_TEST = '1'
. $scriptPath

# Pin record and inlined defaults agree.
$release = Get-Content -LiteralPath $releasePath -Raw -Encoding utf8 | ConvertFrom-Json
Assert ($InstallerUrl -ceq [string]$release.url -and $InstallerSha256 -ceq [string]$release.sha256) 'script defaults do not match the release file'
Assert ($InstallerUrl -ceq ('https://relianpub.blob.core.windows.net/pub/sec/virtio-win-guest-tools-' + [string]$release.version + '-' + [string]$release.sha256 + '.exe')) 'installer URL is not the content-addressed blob of the pin'
$source = [string]$release.sourceUrl
Assert ($source.StartsWith('https://') -and $source.EndsWith('/' + [string]$release.file) -and $source -match ('/virtio-win-' + [regex]::Escape([string]$release.version) + '-\d+/')) 'sourceUrl is not the vendor archive file of the pinned version'
Assert ((Test-VgPinHash $InstallerSha256) -and -not (Test-VgPinHash ('0' * 64)) -and -not (Test-VgPinHash 'ABC')) 'pin hash check'

# PCI hardware IDs are built here: public vendor and device numbers, not a real machine's identifiers.
function Pci([string]$Vendor, [string]$Device) { 'PCI\VEN_' + $Vendor + '&DEV_' + $Device }

# A fake VM. Every machine hook is replaced; nothing is installed.
function New-Fake {
    param(
        [string]$Manufacturer = 'QEMU',
        [string[]]$Pnp = @((Pci '1AF4' '1004'), (Pci '1AF4' '1003')),
        [string]$Installed = '',
        [bool]$Agent = $false,
        [int]$InstallerExit = 0,
        [bool]$AgentStarts = $true
    )
    $f = [pscustomobject]@{
        Manufacturer = $Manufacturer; Pnp = $Pnp; Installed = $Installed; InstallerExit = $InstallerExit; AgentStarts = $AgentStarts
        Services = @{}; Calls = [System.Collections.Generic.List[string]]::new()
    }
    if ($Agent) {
        $f.Services['QEMU-GA'] = [pscustomobject]@{ Status = 'Stopped'; StartType = 'Manual' }
        $f.Services['QEMU Guest Agent VSS Provider'] = [pscustomobject]@{ Status = 'Stopped'; StartType = 'Disabled' }
    }
    $script:Fake = $f
    $script:VgComputer = { [pscustomobject]@{ Manufacturer = $script:Fake.Manufacturer; Model = 'Standard PC' } }
    $script:VgPnpIds = { $script:Fake.Pnp }
    $script:VgInstalledVersion = { $script:Fake.Installed }
    $script:VgGetService = { param($Name) $script:Fake.Services[$Name] }
    $script:VgSetStartType = { param($Name, $Type) $script:Fake.Calls.Add("start-type $Name $Type"); $script:Fake.Services[$Name].StartType = $Type }
    $script:VgStartService = {
        param($Name)
        $script:Fake.Calls.Add("start $Name")
        if ($script:Fake.AgentStarts) { $script:Fake.Services[$Name].Status = 'Running' } else { throw 'Cannot start service' }
    }
    $script:DownloadFile = { param($Url, $Destination) $script:Fake.Calls.Add('download'); Copy-Item -LiteralPath $script:Payload -Destination $Destination }
    $script:RetryDelay = { param($Seconds) }
    $f | Add-Member -NotePropertyName VssOption -NotePropertyValue ''
    $script:VgGetVssOption = { $script:Fake.VssOption }
    $script:VgSetVssOption = { param([int]$Value) $script:Fake.Calls.Add("vss-option $Value"); $script:Fake.VssOption = [string]$Value }
    $script:VgRunInstaller = {
        param($Path, $LogPath, $Mode)
        $script:Fake.Calls.Add('install')
        $script:Fake | Add-Member -NotePropertyName Mode -NotePropertyValue $Mode -Force
        if ($script:Fake.InstallerExit -in @(0, 3010, 1641)) {
            $script:Fake.Installed = '0.1.302'
            $script:Fake.Services['QEMU-GA'] = [pscustomobject]@{ Status = 'Stopped'; StartType = 'Automatic' }
            $script:Fake.Services['QEMU Guest Agent VSS Provider'] = [pscustomobject]@{ Status = 'Stopped'; StartType = 'Manual' }
        }
        return $script:Fake.InstallerExit
    }
    return $f
}

$dir = Join-Path ([System.IO.Path]::GetTempPath()) ('relian-vg-test-' + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $dir | Out-Null
$script:Payload = Join-Path $dir 'payload.exe'
[System.IO.File]::WriteAllText($script:Payload, 'fake bundle')
$sha = (Get-FileHash -Algorithm SHA256 -LiteralPath $script:Payload).Hash.ToLowerInvariant()
function Run { param([string]$Action = 'Install', [string]$Pin = '0.1.302', [string]$Sha = $sha, [string]$Url = 'https://example.invalid/virtio-win-guest-tools.exe', [string]$Vss = '')
    Invoke-VgMain -Action $Action -PinVersion $Pin -InstallerUrl $Url -InstallerSha256 $Sha -CancelPath '' -LogRoot $dir -VssOption $Vss }
function Calls { $script:Fake.Calls -join ',' }

try {
    # Fresh QEMU guest: download, install, agent set to automatic and started, VSS provider left demand-start.
    $f = New-Fake
    $r = Run
    Assert ($r.ExitCode -eq 0 -and $r.Result.Status -eq 'installed') "fresh install: $($r.ExitCode) $($r.Result.Status)"
    Assert ((Calls) -ceq 'download,install,start QEMU-GA') "fresh install calls: $(Calls)"
    Assert ($r.Result.InstalledVersion -eq '0.1.302' -and $r.Result.AgentRunning -and -not $r.Result.RebootRequired) 'fresh install result'
    Assert ($f.Services['QEMU Guest Agent VSS Provider'].StartType -eq 'Manual') 'VSS provider not demand-start'

    # Second run is a no-op apart from service checks.
    $f.Calls.Clear()
    $r = Run
    Assert ($r.ExitCode -eq 0 -and $r.Result.Status -eq 'current' -and (Calls) -ceq '') "second run: $($r.Result.Status) $(Calls)"

    # Older bundle: update. A disabled agent and VSS provider are re-enabled.
    $f = New-Fake -Installed '0.1.285' -Agent $true
    $r = Run -Action 'Update'
    Assert ($r.ExitCode -eq 0 -and $r.Result.Status -eq 'updated' -and $r.Result.PreviousVersion -eq '0.1.285') "update: $($r.Result.Status)"
    $f = New-Fake -Installed '0.1.302' -Agent $true
    $r = Run
    Assert ($r.ExitCode -eq 0 -and $r.Result.Status -eq 'current') "current with stopped agent: $($r.Result.Status)"
    Assert ((Calls) -ceq 'start-type QEMU-GA Automatic,start-type QEMU Guest Agent VSS Provider Manual,start QEMU-GA') "service repair calls: $(Calls)"

    # Current bundle but the agent service is gone: reinstall.
    $f = New-Fake -Installed '0.1.302'
    $r = Run
    Assert ((Calls) -clike 'download,install,*' -and $f.Mode -eq '/repair') "missing agent service repairs: $(Calls) $($f.Mode)"
    $f = New-Fake -Installed '0.1.285'
    $r = Run
    Assert ($f.Mode -eq '/install') 'older bundle uses /install'

    # Reboot requested by the installer is reported, never acted on.
    $f = New-Fake -InstallerExit 3010
    $r = Run
    Assert ($r.ExitCode -eq 0 -and $r.Result.RebootRequired) 'exit 3010 is success with RebootRequired'

    # Installer failure.
    $f = New-Fake -InstallerExit 1603
    $r = Run
    Assert ($r.ExitCode -eq 1 -and $r.Result.InstallerExit -eq 1603) 'installer failure exits 1'

    # Not a QEMU guest: nothing happens.
    $f = New-Fake -Manufacturer 'Dell Inc.' -Pnp @((Pci '8086' '15BB'))
    $r = Run
    Assert ($r.ExitCode -eq 0 -and $r.Result.Status -eq 'notQemuGuest' -and (Calls) -ceq '') "non-QEMU: $($r.Result.Status) $(Calls)"
    # SMBIOS overridden but VirtIO devices present: still a guest.
    $f = New-Fake -Manufacturer 'Custom' -Pnp @((Pci '1AF4' '1041'))
    Assert ((Run).Result.Status -eq 'installed') 'VirtIO PCI device marks a guest'

    # No virtio-serial channel: the agent cannot start. Installed, exit 0, told why.
    $f = New-Fake -Pnp @((Pci '1AF4' '1004')) -AgentStarts $false
    $r = Run
    Assert ($r.ExitCode -eq 0 -and $r.Result.Status -eq 'agentChannelMissing' -and -not $r.Result.AgentRunning) "no channel: $($r.ExitCode) $($r.Result.Status)"
    # Channel present but the agent will not start: failure.
    $f = New-Fake -AgentStarts $false
    $r = Run
    Assert ($r.ExitCode -eq 1) 'agent that does not start with a channel exits 1'

    # Refusals before any download.
    $f = New-Fake
    Assert ((Run -Action 'Uninstall').ExitCode -eq 1 -and (Calls) -ceq '') 'uninstall refused'
    Assert ((Run -Sha ('1' * 64)).ExitCode -eq 1 -and (Calls) -ceq '') 'placeholder hash refused'
    Assert ((Run -Url (-join @('https://', 'user', '@', 'example.invalid/x.exe'))).ExitCode -eq 1 -and (Calls) -ceq '') 'userinfo URL refused'
    Assert ((Run -Url 'http://example.invalid/x.exe').ExitCode -eq 1 -and (Calls) -ceq '') 'plain http refused'
    Assert ((Run -Pin 'abc').ExitCode -eq 1 -and (Calls) -ceq '') 'bad pin refused'
    $r = Run -Pin ''
    Assert ($r.ExitCode -eq 0 -and (Calls) -ceq '') 'empty pin does nothing'
    $r = Run -Pin '' -Url (-join @('https://', 'user', '@', 'example.invalid/x.exe')) -Action 'Uninstall'
    Assert ($r.ExitCode -eq 0 -and (Calls) -ceq '') 'empty pin exits 0 before URL and action checks'

    # Hash mismatch: one download, no retry, no install.
    $f = New-Fake
    $r = Run -Sha ('a' * 63 + 'b')
    Assert ($r.ExitCode -eq 1 -and (Calls) -ceq 'download') "hash mismatch: $(Calls)"

    # Transient download errors are tried three times; anything else once.
    $f = New-Fake
    $script:DownloadFile = { param($Url, $Destination) $script:Fake.Calls.Add('download'); throw [System.Net.WebException]::new('timed out', [System.Net.WebExceptionStatus]::Timeout) }
    $r = Run
    Assert ($r.ExitCode -eq 1 -and (Calls) -ceq 'download,download,download') "transient download retries: $(Calls)"
    $f = New-Fake
    $script:DownloadFile = { param($Url, $Destination) $script:Fake.Calls.Add('download'); throw [System.Net.Http.HttpRequestException]::new('not found', $null, [System.Net.HttpStatusCode]::NotFound) }
    $r = Run
    Assert ($r.ExitCode -eq 1 -and (Calls) -ceq 'download') "404 is not retried: $(Calls)"
    $f = New-Fake
    $script:DownloadFile = { param($Url, $Destination) $script:Fake.Calls.Add('download'); throw [System.Net.Http.HttpRequestException]::new('busy', $null, [System.Net.HttpStatusCode]::ServiceUnavailable) }
    $r = Run
    Assert ((Calls) -ceq 'download,download,download') "503 is retried: $(Calls)"
    $f = New-Fake
    $script:DownloadFile = { param($Url, $Destination) $script:Fake.Calls.Add('download'); throw 'network down' }
    $r = Run
    Assert ($r.ExitCode -eq 1 -and (Calls) -ceq 'download') "unclassified error is not retried: $(Calls)"

    # Cancel before download.
    $f = New-Fake
    $env:RELIAN_DEPLOY_CANCEL = '1'
    $r = Run
    $env:RELIAN_DEPLOY_CANCEL = $null
    Assert ($r.ExitCode -eq 130 -and (Calls) -ceq '') 'cancel'

    # Pin above what the bundle installs: fail rather than loop.
    $f = New-Fake
    $r = Run -Pin '0.1.400'
    Assert ($r.ExitCode -eq 1) 'still below the pin after install'

    # VssOption: empty leaves it alone; a value is written after install and only when it differs.
    $f = New-Fake
    $r = Run
    Assert (-not ((Calls) -match 'vss-option')) 'empty VssOption writes nothing'
    $f = New-Fake
    $r = Run -Vss '5'
    Assert ($r.ExitCode -eq 0 -and $r.Result.VssOption -eq '5' -and (Calls) -ceq 'download,install,start QEMU-GA,vss-option 5') "VssOption 5: $(Calls)"
    $f.Calls.Clear()
    $r = Run -Vss '5'
    Assert ((Calls) -ceq '' -and $r.Result.Status -eq 'current') "VssOption already 5 is a no-op: $(Calls)"
    $f = New-Fake
    Assert ((Run -Vss '9').ExitCode -eq 1 -and (Calls) -ceq '') 'bad VssOption refused before download'

    # A download error is reported.
    $f = New-Fake
    $script:DownloadFile = { param($Url, $Destination) throw 'boom' }
    $r = Run
    Assert ($r.Result.DownloadError -match 'boom') 'download error reported'

    # Version compare is numeric.
    Assert ((Compare-VgVersion '0.1.99' '0.1.302') -lt 0 -and (Compare-VgVersion '0.1.302' '0.1.302') -eq 0) 'numeric version compare'
} finally {
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
}

# The installer is silent, never restarts, and logs.
$text = Get-Content -LiteralPath $scriptPath -Raw
Assert ($text.Contains('@($Mode, ''/quiet'', ''/norestart'', ''/log''')) 'installer arguments'
Assert ($text -notmatch '(?i)Restart-Computer|shutdown(\.exe)?\s+/r') 'the package must not reboot'
Assert ($text -match "-UserAgent 'relian-device-scripts'") 'download must not send a Mozilla User-Agent (fedorapeople bot check)'

Write-Output 'virtio-guest-tools tests passed'
exit 0
