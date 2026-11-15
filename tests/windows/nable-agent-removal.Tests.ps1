# N-able agent removal module. Registry, service, folder and process calls are seams.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$modulePath = Join-Path $repoRoot 'windows/jobs/nable-agent-removal.ps1'

function Fail { param([string]$Message) [Console]::Error.WriteLine("FAIL $Message"); exit 1 }
function Assert-True { param([bool]$Condition, [string]$Label) if (-not $Condition) { Fail $Label } }
function Assert-Same { param($Actual, $Expected, [string]$Label) if ($Actual -ne $Expected) { Fail "$Label was [$Actual] expected [$Expected]" } }

# Split-Path turns backslashes into slashes on Linux.
function Get-Parent { param([string]$Path) $Path.Substring(0, $Path.LastIndexOf([char]92)) }

$env:RELIAN_DEPLOY_TEST = '1'
. $modulePath

$u64 = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
$u32 = 'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
$pf86 = 'C:\Program Files (x86)'
$amaDir = "$pf86\Advanced Monitoring Agent"
$gpCode = '{11111111-2222-3333-4444-555555555555}'

function New-App { param($Id, $Name, $Publisher = '', $Uninstall = '', [switch]$Msi, $Root = $u32)
    [pscustomobject]@{ Key = "$Root\$Id"; Id = $Id; Name = $Name; Publisher = $Publisher; Uninstall = $Uninstall; Msi = [bool]$Msi }
}
function New-Svc { param($Name, $Path, $DisplayName = $Name) [pscustomobject]@{ Name = $Name; DisplayName = $DisplayName; Path = $Path; ProcessId = 0 } }

# The vendor uninstallers, as the fakes see them: each one removes what it owns.
function Reset-Test {
    $script:Apps = [Collections.Generic.List[object]]::new()
    $script:Svcs = [Collections.Generic.List[object]]::new()
    $script:Dirs = [Collections.Generic.List[string]]::new()
    $script:Runs = [Collections.Generic.List[string]]::new()
    $script:Removed = [Collections.Generic.List[string]]::new()
    $script:UninstallWorks = $true
    $script:MsiWorks = $true
    $script:FolderLocked = $false
}
$script:NaReadUninstall = { $script:Apps.ToArray() }
$script:NaReadServices = { $script:Svcs.ToArray() }
$script:NaFolderParents = { @($pf86, 'C:\ProgramData') }
$script:NaListFolders = { param($Parent) @($script:Dirs | Where-Object { (Get-Parent $_) -eq $Parent -and (Split-Path -Leaf $_) -match $script:NaFolderPattern }) }
$script:NaSettle = { }
$script:NaFileExists = { param($Path) $script:Dirs -contains (Get-Parent $Path) }
$script:NaRun = { param($File, $Arguments)
    $script:Runs.Add("$File $($Arguments -join ' ')")
    if (-not $(if ($File -eq 'msiexec.exe') { $script:MsiWorks } else { $script:UninstallWorks })) { return 1603 }
    if ($File -eq 'msiexec.exe') {
        foreach ($a in @($script:Apps | Where-Object { $_.Id -eq $Arguments[1] })) { [void]$script:Apps.Remove($a) }
    } else {
        foreach ($a in @($script:Apps | Where-Object { $_.Uninstall -like "*$File*" })) { [void]$script:Apps.Remove($a) }
        foreach ($s in @($script:Svcs | Where-Object { $_.Path -like "*$(Get-Parent $File)*" })) { [void]$script:Svcs.Remove($s) }
        [void]$script:Dirs.Remove((Get-Parent $File))
    }
    return 0
}
$script:NaRemoveService = { param($Service) $script:Removed.Add("svc $($Service.Name)"); [void]$script:Svcs.Remove($Service) }
$script:NaRemoveFolder = { param($Path)
    if ($script:FolderLocked) { throw 'The process cannot access the file.' }
    $script:Removed.Add("dir $Path"); [void]$script:Dirs.Remove($Path)
}
$script:NaDeleteKey = { param($Path) $script:Removed.Add("key $Path"); foreach ($a in @($script:Apps | Where-Object { $_.Key -eq $Path })) { [void]$script:Apps.Remove($a) } }

function Add-Protected {
    $script:Apps.Add((New-App '{AAAAAAAA-0000-0000-0000-000000000001}' 'NinjaRMMAgent' 'NinjaRMM LLC' 'MsiExec.exe /X{AAAAAAAA-0000-0000-0000-000000000001}' -Msi))
    $script:Apps.Add((New-App 'S1' 'Sentinel Agent' 'SentinelOne, Inc.' 'C:\Program Files\SentinelOne\uninstall.exe'))
    $script:Apps.Add((New-App 'GSA' 'Global Secure Access Client' 'Microsoft Corporation' 'C:\x\unins000.exe'))
    $script:Apps.Add((New-App 'WG' 'WireGuard' 'WireGuard LLC' 'MsiExec.exe /X{B}'))
    $script:Svcs.Add((New-Svc 'NinjaRMMAgent' '"C:\Program Files (x86)\vendor-office\NinjaRMMAgent.exe" /service'))
    $script:Svcs.Add((New-Svc 'SentinelAgent' '"C:\Program Files\SentinelOne\SentinelAgent.exe"'))
    $script:Svcs.Add((New-Svc 'GlobalSecureAccessTunnelingService' 'C:\Program Files\Global Secure Access Client\x.exe'))
    $script:Svcs.Add((New-Svc 'WireGuardTunnel$office' '"C:\Program Files\WireGuard\wireguard.exe" /tunnelservice x'))
    $script:Svcs.Add((New-Svc 'WazuhSvc' 'C:\Program Files (x86)\ossec-agent\wazuh-agent.exe'))
    $script:Dirs.Add("$pf86\vendor-office")
    $script:Dirs.Add("$pf86\Advanced Monitoring Agent NinjaOne")
}

function Add-Agent {
    $script:Apps.Add((New-App 'Advanced Monitoring Agent_is1' 'Advanced Monitoring Agent' 'Remote Monitoring Services' "`"$amaDir\unins000.exe`""))
    $script:Apps.Add((New-App $gpCode 'Advanced Monitoring Agent GP' 'Remote Monitoring Services' "MsiExec.exe /I$gpCode" -Msi))
    $script:Svcs.Add((New-Svc 'Advanced Monitoring Agent' "`"$amaDir\winagent.exe`""))
    $script:Svcs.Add((New-Svc 'Advanced Monitoring Agent Web Protection' "`"$amaDir\wp\webprotection.exe`""))
    $script:Dirs.Add($amaDir)
}

function Invoke-Job { param([switch]$ReportOnly)
    $r = Invoke-NableRemovalJob -ReportOnly:$ReportOnly
    $line = ConvertTo-NableJobLine $r
    [pscustomobject]@{ Code = $r.ExitCode; Line = $line; Json = ($line | ConvertFrom-Json) }
}

# Clean machine with only protected software: compliant, nothing run or removed.
Reset-Test
Add-Protected
$r = Invoke-Job
Assert-Same $r.Code 0 'clean exit'
Assert-Same $r.Json.status 'compliant' 'clean status'
Assert-Same @($r.Json.folders).Count 0 'an agent-named folder with a protected name is not a target'
Assert-Same $r.Json.job 'nable-agent-removal' 'job name'
Assert-Same $script:Runs.Count 0 'clean runs nothing'
Assert-Same $script:Removed.Count 0 'clean removes nothing'

# Report-only with the agent: drift, exit 1, nothing changed.
Reset-Test
Add-Protected
Add-Agent
$r = Invoke-Job -ReportOnly
Assert-Same $r.Code 1 'report-only exit'
Assert-Same $r.Json.status 'drift' 'report-only status'
Assert-Same @($r.Json.apps).Count 2 'report-only apps'
Assert-Same @($r.Json.services).Count 2 'report-only services'
Assert-Same $script:Runs.Count 0 'report-only runs nothing'

# Vendor uninstallers work: Inno silently, the GP MSI by product code. Nothing protected is touched.
Reset-Test
Add-Protected
Add-Agent
$protectedApps = @($script:Apps | ForEach-Object Key)
$r = Invoke-Job
Assert-Same $r.Code 0 'vendor exit'
Assert-Same $r.Json.status 'removed' 'vendor status'
Assert-True ($script:Runs -contains "$amaDir\unins000.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART") 'inno uninstaller ran silently'
Assert-True ($script:Runs -contains "msiexec.exe /x $gpCode /qn /norestart") 'GP MSI removed by product code'
Assert-Same $script:Runs.Count 2 'only the two agent uninstallers ran'
Assert-Same $script:Removed.Count 0 'no fallback needed'
Assert-Same $script:Apps.Count ($protectedApps.Count - 2) 'protected apps stay'
Assert-Same $script:Svcs.Count 5 'protected services stay'
Assert-Same $script:Dirs.Count 2 'protected folders stay'

# Second run is idempotent: compliant, nothing run.
$script:Runs.Clear()
$r = Invoke-Job
Assert-Same $r.Json.status 'compliant' 'second run compliant'
Assert-Same $script:Runs.Count 0 'second run runs nothing'

# Uninstallers fail: services, folders and keys are removed by hand, and the run reports removed.
Reset-Test
Add-Protected
Add-Agent
$script:UninstallWorks = $false
$script:Svcs.Add((New-Svc 'BASupportExpressStandaloneService_LOGICnow' 'C:\ProgramData\GetSupportService_LOGICnow\BASupSrvc.exe'))
$script:Dirs.Add('C:\ProgramData\GetSupportService_LOGICnow')
$r = Invoke-Job
Assert-Same $r.Code 0 'fallback exit'
Assert-Same $r.Json.status 'removed' 'fallback status'
foreach ($want in @('svc Advanced Monitoring Agent', 'svc Advanced Monitoring Agent Web Protection', 'svc BASupportExpressStandaloneService_LOGICnow',
        "dir $amaDir", 'dir C:\ProgramData\GetSupportService_LOGICnow', "key $u32\Advanced Monitoring Agent_is1")) {
    Assert-True ($script:Removed -contains $want) "fallback removed [$want]"
}
Assert-Same $script:Removed.Count 6 'fallback removed only agent items'
Assert-True (@($r.Json.log) -contains 'uninstall Advanced Monitoring Agent exit 1603') 'log keeps the uninstaller exit code'

# A failed MSI uninstall keeps its key and fails: deleting it would hide an installed product.
Reset-Test
Add-Agent
$script:MsiWorks = $false
$r = Invoke-Job
Assert-Same $r.Code 2 'failed MSI exit'
Assert-Same $r.Json.status 'failed' 'failed MSI status'
Assert-True (-not ($script:Removed -contains "key $u32\$gpCode")) 'failed MSI key kept'
Assert-True (@($r.Json.apps) -contains 'Advanced Monitoring Agent GP') 'failed MSI reported'

# A publisher-matched part installed outside the agent folders, whose uninstaller fails, keeps its key.
Reset-Test
$script:Dirs.Add('C:\Tools\Handler')
$script:Apps.Add((New-App 'RHA' 'Request Handler Agent' 'N-able Technologies' '"C:\Tools\Handler\unins000.exe"'))
$script:UninstallWorks = $false
$r = Invoke-Job
Assert-Same $r.Code 2 'outside-folder part exit'
Assert-Same $r.Json.status 'failed' 'outside-folder part is not reported removed'
Assert-Same $script:Removed.Count 0 'outside-folder part key kept'

# A same-named folder outside Program Files and ProgramData is another product's.
Assert-True (-not (Test-NaServiceEntry (New-Svc 'Worker' 'C:\OtherSoftware\Take Control Agent\worker.exe'))) 'agent folder name elsewhere does not match'
Assert-True (-not (Test-NaServiceEntry (New-Svc 'Worker' "$pf86\Vendor\MspPlatform\worker.exe"))) 'agent folder name deeper down does not match'

# A locked folder: exit 2, failed, the folder named in the report.
Reset-Test
Add-Agent
$script:UninstallWorks = $false
$script:FolderLocked = $true
$r = Invoke-Job
Assert-Same $r.Code 2 'locked exit'
Assert-Same $r.Json.status 'failed' 'locked status'
Assert-Same $r.Json.error 'still present after removal' 'locked error'
Assert-Same @($r.Json.folders).Count 1 'locked folder reported'

# A read that throws is a failure, never compliant.
Reset-Test
$saved = $script:NaReadServices
$script:NaReadServices = { throw 'Access denied' }
$r = Invoke-Job
Assert-Same $r.Code 2 'throwing read exit'
Assert-Same $r.Json.status 'failed' 'throwing read status'
$script:NaReadServices = $saved

# Matching rules.
Assert-True (Test-NaAppEntry (New-App 'x' 'Advanced Monitoring Agent Network Management')) 'network management matches'
Assert-True (Test-NaAppEntry (New-App 'x' 'Request Handler Agent' 'N-able Technologies')) 'part matches by publisher'
Assert-True (-not (Test-NaAppEntry (New-App 'x' 'Request Handler Agent' 'Contoso'))) 'generic name alone does not match'
Assert-True (-not (Test-NaAppEntry (New-App 'x' 'SolarWinds Orion' 'SolarWinds'))) 'other SolarWinds products do not match'
Assert-True (-not (Test-NaAppEntry (New-App 'x' 'GFI ReportCenter Framework' 'GFI Software'))) 'GFI does not match'
Assert-True (-not (Test-NaAppEntry (New-App 'x' '' 'Remote Monitoring Services'))) 'an entry without a name does not match'
Assert-True (Test-NaServiceEntry (New-Svc 'FileCacheServiceAgent' '"C:\Program Files (x86)\MspPlatform\FileCacheServiceAgent\FileCacheServiceAgent.exe"')) 'MspPlatform service matches by folder'
Assert-True (-not (Test-NaServiceEntry (New-Svc 'Other' 'C:\Tools\other.exe --cache "C:\Program Files (x86)\MspPlatform\x"'))) 'a folder in another program''s arguments does not match'
Assert-True (-not (Test-NaAppEntry (New-App 'x' 'Ninja Patch Helper' 'SolarWinds MSP'))) 'a protected name wins over a matching publisher'
Assert-True (-not (Test-NaAppEntry (New-App 'x' 'Advanced Monitoring Agent' '' 'C:\NinjaRMMAgent\unins000.exe'))) 'a protected uninstall path wins over a matching name'
Assert-True (-not (Test-NaServiceEntry (New-Svc 'Advanced Monitoring Agent Ninja' "$amaDir\x.exe"))) 'a protected service name wins'
Assert-True (-not (Test-NaServiceEntry (New-Svc 'SentinelAgent' "$amaDir\SentinelAgent.exe"))) 'a protected service in an agent folder wins'
Assert-Same (Get-NaUninstallCommand (New-App 'NoUninstaller' 'Advanced Monitoring Agent' '' 'C:\x\setup.exe /remove')) $null 'unknown uninstaller is not run'

Write-Output 'nable-agent-removal: ok'
