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

function New-App { param($Id, $Name, $Publisher = '', $Uninstall = '', [switch]$Msi, $Root = $u32, $InstallLocation = '')
    [pscustomobject]@{ Key = "$Root\$Id"; Id = $Id; Name = $Name; Publisher = $Publisher; Uninstall = $Uninstall; Msi = [bool]$Msi; InstallLocation = $InstallLocation }
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
    $script:Files = [Collections.Generic.List[string]]::new()
    $script:Products = [Collections.Generic.List[string]]::new()
    $script:LocalPackages = @{}
    $script:BackupDirs = [Collections.Generic.List[string]]::new()
    $script:NaBackupDir = Join-Path $script:TmpRoot ([guid]::NewGuid().ToString('N'))
}
$script:TmpRoot = Join-Path ([IO.Path]::GetTempPath()) ('na-backup-' + [guid]::NewGuid().ToString('N'))
$script:NaProtectDir = { param($Path) $script:BackupDirs.Add($Path) }
$script:NaReadKeyValues = { param($Path) @(@{ name = 'DisplayName'; kind = 'String'; data = "of $Path" }, @{ name = 'WindowsInstaller'; kind = 'DWord'; data = 1 }, @{ name = 'Bin'; kind = 'Binary'; data = 'AQID' }) }
$script:NaPathExists = { param($Path) ($script:Dirs -contains $Path) -or ($script:Dirs -contains (Get-Parent $Path)) -or ($script:Files -contains $Path) }
$script:NaHasProduct = { param($Packed) $script:Products -contains $Packed }
$script:NaReadLocalPackage = { param($Packed) $script:LocalPackages[$Packed] }
$script:NaDeleteProduct = { param($Packed) $script:Removed.Add("product $Packed"); [void]$script:Products.Remove($Packed) }
$script:NaReadUninstall = { $script:Apps.ToArray() }
$script:NaReadServices = { $script:Svcs.ToArray() }
$script:NaFolderParents = { @($pf86, 'C:\ProgramData') }
$script:NaListFolders = { param($Parent) @($script:Dirs | Where-Object { $_.StartsWith("$Parent\") -and $_.Substring($Parent.Length + 1) -match $script:NaFolderPattern }) }
$script:NaSettle = { }
$script:NaFileExists = { param($Path) ($script:Dirs -contains (Get-Parent $Path)) -or ($script:Files -contains $Path) }
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
# The publisher only confirms a listed part name; it never selects a product by itself.
foreach ($p in @('Remote Monitoring Services', 'SolarWinds MSP', 'N-able Technologies', 'LogicNow Ltd', 'BeAnywhere')) {
    Assert-True (-not (Test-NaAppEntry (New-App 'x' 'Backup Manager' $p))) "another product from [$p] does not match"
}
Assert-True (Test-NaAppEntry (New-App 'x' 'File Cache Service Agent' 'SolarWinds MSP')) 'file cache part matches by publisher'
Assert-True (Test-NaAppEntry (New-App 'x' 'Patch Management Service Controller' 'N-able Technologies')) 'patch part matches by publisher'
Reset-Test
Add-Agent
$script:Apps.Add((New-App 'BM' 'Backup Manager' 'N-able Technologies' '"C:\Program Files\Backup Manager\unins000.exe"'))
$r = Invoke-Job
Assert-True (-not ($script:Runs -like '*Backup Manager*')) 'another product from the vendor is not uninstalled'
Assert-True (@($script:Apps | Where-Object Id -eq 'BM').Count -eq 1) 'another product from the vendor keeps its key'
Assert-True (Test-NaServiceEntry (New-Svc 'FileCacheServiceAgent' '"C:\Program Files (x86)\MspPlatform\FileCacheServiceAgent\FileCacheServiceAgent.exe"')) 'MspPlatform service matches by folder'
Assert-True (-not (Test-NaServiceEntry (New-Svc 'Other' 'C:\Tools\other.exe --cache "C:\Program Files (x86)\MspPlatform\x"'))) 'a folder in another program''s arguments does not match'
Assert-True (-not (Test-NaAppEntry (New-App 'x' 'Ninja Patch Helper' 'SolarWinds MSP'))) 'a protected name wins over a matching publisher'
Assert-True (-not (Test-NaAppEntry (New-App 'x' 'Advanced Monitoring Agent' '' 'C:\NinjaRMMAgent\unins000.exe'))) 'a protected uninstall path wins over a matching name'
Assert-True (-not (Test-NaServiceEntry (New-Svc 'Advanced Monitoring Agent Ninja' "$amaDir\x.exe"))) 'a protected service name wins'
Assert-True (-not (Test-NaServiceEntry (New-Svc 'SentinelAgent' "$amaDir\SentinelAgent.exe"))) 'a protected service in an agent folder wins'
Assert-Same (Get-NaUninstallCommand (New-App 'NoUninstaller' 'Advanced Monitoring Agent' '' 'C:\x\setup.exe /remove')) $null 'unknown uninstaller is not run'

# A vendor root holds other products: only the agent's own subfolder of it is a target.
Reset-Test
$script:Dirs.Add("$pf86\N-able Technologies")
$script:Dirs.Add("$pf86\N-able Technologies\Backup Manager")
$r = Invoke-Job
Assert-Same $r.Json.status 'compliant' 'a vendor root with another product is not a target'
Reset-Test
Add-Agent
$script:UninstallWorks = $false
$script:Dirs.Add("$pf86\SolarWinds MSP")
$script:Dirs.Add("$pf86\SolarWinds MSP\Ecosystem Agent")
$r = Invoke-Job
Assert-True ($script:Removed -contains "dir $pf86\SolarWinds MSP\Ecosystem Agent") 'the agent subfolder of a vendor root is removed'
Assert-True (-not ($script:Removed -contains "dir $pf86\SolarWinds MSP")) 'the vendor root is kept'
Assert-True (-not (Test-NaServiceEntry (New-Svc 'Backup' "$pf86\N-able Technologies\Backup Manager\x.exe"))) 'a service of another vendor product does not match'
Assert-True (Test-NaServiceEntry (New-Svc 'PME' "$pf86\SolarWinds MSP\PME\x.exe")) 'a service in an agent subfolder of a vendor root matches'

# The process to stop is read live: a stopped service or a shared host process is never killed.
$live = @([pscustomobject]@{ Name = 'Agent'; ProcessId = 0 }, [pscustomobject]@{ Name = 'Other'; ProcessId = 40 })
Assert-Same (Get-NaServiceKillId 'Agent' $live) 0 'a stopped service kills nothing, even if its old PID now runs something else'
$live = @([pscustomobject]@{ Name = 'Agent'; ProcessId = 40 }, [pscustomobject]@{ Name = 'Other'; ProcessId = 40 })
Assert-Same (Get-NaServiceKillId 'Agent' $live) 0 'a process hosting another service is not killed'
$live = @([pscustomobject]@{ Name = 'Agent'; ProcessId = 40 }, [pscustomobject]@{ Name = 'Other'; ProcessId = 41 })
Assert-Same (Get-NaServiceKillId 'Agent' $live) 40 'a hung service alone in its process is killed'
Assert-Same (Get-NaServiceKillId 'Gone' $live) 0 'a missing service kills nothing'

# A service another product depends on is not force-stopped: -Force would stop that product too.
$svcs = @((New-Svc 'Advanced Monitoring Agent' "$amaDir\winagent.exe"), (New-Svc 'AMA Helper' "$amaDir\helper.exe"), (New-Svc 'SentinelAgent' 'C:\Program Files\SentinelOne\s.exe'))
Assert-True (Test-NaStopAllowed @('AMA Helper') $svcs) 'an agent dependent allows the stop'
Assert-True (-not (Test-NaStopAllowed @('AMA Helper', 'SentinelAgent') $svcs)) 'a protected dependent refuses the stop'
Assert-True (-not (Test-NaStopAllowed @('Unknown') $svcs)) 'an unknown dependent refuses the stop'
Reset-Test
Add-Agent
$script:UninstallWorks = $false
$script:NaRemoveService = { param($Service) throw 'dependent' }
$r = Invoke-Job
Assert-Same $r.Code 2 'a refused service stop fails the run'
Assert-True (@($r.Json.log) -contains 'service kept: Advanced Monitoring Agent') 'a refused service stop is logged'
$script:NaRemoveService = { param($Service) $script:Removed.Add("svc $($Service.Name)"); [void]$script:Svcs.Remove($Service) }

# Folder cleanup spares a process that hosts a non-agent service.
$procs = @([pscustomobject]@{ Id = 10; Path = "$amaDir\winagent.exe" }, [pscustomobject]@{ Id = 11; Path = "$amaDir\shared.exe" },
    [pscustomobject]@{ Id = 12; Path = 'C:\Windows\other.exe' }, [pscustomobject]@{ Id = 13; Path = '' })
$svcs = @([pscustomobject]@{ Name = 'Advanced Monitoring Agent'; DisplayName = ''; Path = "$amaDir\winagent.exe"; ProcessId = 10 },
    [pscustomobject]@{ Name = 'WazuhSvc'; DisplayName = ''; Path = "$amaDir\shared.exe"; ProcessId = 11 })
$ids = @(Get-NaFolderKillIds $amaDir $procs $svcs)
Assert-Same ($ids -join ',') '10' 'only the agent process in the folder is killed'

# A folder a remaining service runs from is kept: a protected service there, or a refused removal.
Reset-Test
Add-Agent
$script:UninstallWorks = $false
$script:Svcs.Add((New-Svc 'SentinelAgent' "`"$amaDir\SentinelAgent.exe`""))
$r = Invoke-Job
Assert-Same $r.Code 2 'a folder with a protected service fails the run'
Assert-True (-not ($script:Removed -contains "dir $amaDir")) 'a folder with a protected service is kept'
Assert-True (@(@($r.Json.log) -like "folder kept:*").Count -eq 1) 'a kept folder is logged'
Assert-True (-not (Test-NaFolderInUse $amaDir @((New-Svc 'Other' "$amaDir Two\x.exe")))) 'a sibling folder with a longer name is not in use'

# Dependents are collected at every depth, and a cycle ends.
$savedDeps = $script:NaReadDependents
$script:NaReadDependents = { param($Name) @{ 'A' = @('B'); 'B' = @('C', 'A'); 'C' = @('B', 'D') }[$Name] }
Assert-Same ((@(Get-NaAllDependents 'A') | Sort-Object) -join ',') 'B,C,D' 'an indirect dependent is collected and a cycle ends'
$script:NaReadDependents = $savedDeps

# Folder removal deletes a link inside the folder, never the files the link points to.
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("na-tree-" + [guid]::NewGuid().ToString('N'))
$agent = Join-Path $tmp 'agent'; $outside = Join-Path $tmp 'outside'
$null = New-Item -ItemType Directory -Path (Join-Path $agent 'sub'), $outside
Set-Content -LiteralPath (Join-Path $outside 'keep.txt') -Value 'x'
$readOnly = Join-Path (Join-Path $agent 'sub') 'a.txt'
Set-Content -LiteralPath $readOnly -Value 'x'
Set-ItemProperty -LiteralPath $readOnly -Name IsReadOnly -Value $true
$linkType = if ([IO.Path]::DirectorySeparatorChar -eq [char]92) { 'Junction' } else { 'SymbolicLink' }
$null = New-Item -ItemType $linkType -Path (Join-Path $agent 'link') -Target $outside
try {
    Remove-NaTree $agent
    Assert-True (-not (Test-Path -LiteralPath $agent)) 'the agent folder is removed, read-only files too'
    Assert-True (Test-Path -LiteralPath (Join-Path $outside 'keep.txt')) 'a file behind a link inside the folder survives'
} finally {
    [IO.Directory]::Delete($tmp, $true)
}

# Orphan Add/Remove Programs keys. The packed product code format, with known GUIDs.
Assert-Same (ConvertTo-NaPackedGuid '{90120000-0030-0000-0000-0000000FF1CE}') '00002109030000000000000000F01FEC' 'packed GUID, Office'
$msiCode = '{12345678-9ABC-DEF0-1234-56789ABCDEF0}'
$msiPacked = '87654321CBA90FED21436587A9CBED0F'
Assert-Same (ConvertTo-NaPackedGuid $msiCode) $msiPacked 'packed GUID, mixed digits'
Assert-Same (ConvertTo-NaPackedGuid $msiCode.ToLower()) $msiPacked.ToUpper() 'packed GUID is upper case'
$threw = $false; try { $null = ConvertTo-NaPackedGuid 'not-a-guid' } catch { $threw = $true }
Assert-True $threw 'a malformed product code throws'

function Get-BackupFiles { @(if (Test-Path -LiteralPath $script:NaBackupDir) { Get-ChildItem -LiteralPath $script:NaBackupDir -Filter 'backup-*.json' }) }

# No uninstaller at all: the key is backed up, then deleted, and the run reports removed.
Reset-Test
Add-Protected
$script:Apps.Add((New-App 'GPNoUninst' 'Advanced Monitoring Agent GP' 'Remote Monitoring Services'))
$protectedKeys = @($script:Apps | Where-Object Id -ne 'GPNoUninst' | ForEach-Object Key)
$script:NaDeleteKey = { param($Path) $script:BackupAtDelete = @(Get-BackupFiles).Count; $script:Removed.Add("key $Path"); foreach ($a in @($script:Apps | Where-Object { $_.Key -eq $Path })) { [void]$script:Apps.Remove($a) } }
$r = Invoke-Job
Assert-Same $r.Code 0 'orphan without uninstaller exit'
Assert-Same $r.Json.status 'removed' 'orphan without uninstaller status'
Assert-True ($script:Removed -contains "key $u32\GPNoUninst") 'orphan without uninstaller key deleted'
Assert-Same $script:Runs.Count 0 'nothing to run for a key without an uninstaller'
Assert-Same $script:BackupAtDelete 1 'the backup exists before the delete'
$files = @(Get-BackupFiles)
Assert-Same $files.Count 1 'one backup file'
Assert-Same @($r.Json.backups).Count 1 'the output names the backup'
Assert-Same $r.Json.backups[0] $files[0].Name 'the output names the backup file'
$doc = Get-Content -LiteralPath $files[0].FullName -Raw | ConvertFrom-Json
Assert-Same $doc.key "HKLM\$u32\GPNoUninst" 'the backup holds the key path'
Assert-Same @($doc.values).Count 3 'the backup holds every value'
Assert-Same $doc.values[0].data "of $u32\GPNoUninst" 'the backup holds the value data'
Assert-Same $script:BackupDirs.Count 1 'the backup folder is locked down'
Assert-Same @($script:Apps | ForEach-Object Key | Where-Object { $protectedKeys -notcontains $_ }).Count 0 'only the orphan went'
Assert-Same @($script:Apps).Count $protectedKeys.Count 'protected keys stay'
$script:NaDeleteKey = { param($Path) $script:Removed.Add("key $Path"); foreach ($a in @($script:Apps | Where-Object { $_.Key -eq $Path })) { [void]$script:Apps.Remove($a) } }

# A backup is a new file each time and never overwrites one.
$p1 = Write-NaBackup 'K\a' @(@{ name = 'x'; kind = 'String'; data = '1' })
$p2 = Write-NaBackup 'K\a' @(@{ name = 'x'; kind = 'String'; data = '1' })
Assert-True ($p1 -ne $p2) 'two backups get two names'
$p3 = Write-NaBackup 'K\empty' @()
Assert-True (Test-Path -LiteralPath (Join-Path $script:NaBackupDir $p3)) 'a key with no values is backed up'

# MSI uninstall returns 1603 and the install folder is gone: key removed, and the Products entry too
# when the cached package is missing.
Reset-Test
$script:Apps.Add((New-App $msiCode 'Advanced Monitoring Agent GP' 'Remote Monitoring Services' "MsiExec.exe /I$msiCode" -Msi -InstallLocation "$pf86\Advanced Monitoring Agent GP\"))
$script:Products.Add($msiPacked)
$script:LocalPackages[$msiPacked] = 'C:\Windows\Installer\1a2b3c.msi'
$script:MsiWorks = $false
$r = Invoke-Job
Assert-Same $r.Code 0 '1603 with files gone exit'
Assert-Same $r.Json.status 'removed' '1603 with files gone status'
Assert-True ($script:Runs -contains "msiexec.exe /x $msiCode /qn /norestart") '1603 case ran the uninstaller first'
Assert-True ($script:Removed -contains "key $u32\$msiCode") '1603 with files gone key deleted'
Assert-True ($script:Removed -contains "product $msiPacked") 'Products entry removed when the cached package is missing'
Assert-Same @($r.Json.left).Count 0 'nothing left to report'

# The cached package is still on disk: the Products entry stays and is reported.
Reset-Test
$script:Apps.Add((New-App $msiCode 'Advanced Monitoring Agent GP' 'Remote Monitoring Services' "MsiExec.exe /I$msiCode" -Msi -InstallLocation "$pf86\Advanced Monitoring Agent GP"))
$script:Products.Add($msiPacked)
$script:LocalPackages[$msiPacked] = 'C:\Windows\Installer\1a2b3c.msi'
$script:Files.Add('C:\Windows\Installer\1a2b3c.msi')
$script:MsiWorks = $false
$r = Invoke-Job
Assert-Same $r.Json.status 'removed' 'package on disk: the uninstall key is still removed'
Assert-True (-not ($script:Removed -contains "product $msiPacked")) 'Products entry kept while the cached package exists'
Assert-Same @($r.Json.left).Count 1 'the kept Products entry is reported'
Assert-True ($r.Json.left[0] -like "*$msiPacked*cached package on disk*") 'the report names the entry and why'

# An absent LocalPackage value counts as a missing package. A product with no Products entry is not an error.
Reset-Test
$script:Apps.Add((New-App $msiCode 'Advanced Monitoring Agent GP' 'Remote Monitoring Services' '' -Msi -InstallLocation 'C:\Gone\GP'))
$script:Products.Add($msiPacked)
$script:MsiWorks = $false
$r = Invoke-Job
Assert-True ($script:Removed -contains "product $msiPacked") 'an absent LocalPackage value counts as missing'
Reset-Test
$script:Apps.Add((New-App $msiCode 'Advanced Monitoring Agent GP' 'Remote Monitoring Services' '' -Msi -InstallLocation 'C:\Gone\GP'))
$script:MsiWorks = $false
$r = Invoke-Job
Assert-Same $r.Code 0 'no Products entry: still removed'
Assert-Same @($script:Removed | Where-Object { $_ -like 'product*' }).Count 0 'no Products entry: nothing to delete'

# 1603 with the install folder or the uninstaller target still on disk: nothing is deleted, the run fails.
Reset-Test
$script:Dirs.Add('C:\Tools\GP')
$script:Apps.Add((New-App $msiCode 'Advanced Monitoring Agent GP' 'Remote Monitoring Services' "MsiExec.exe /I$msiCode" -Msi -InstallLocation 'C:\Tools\GP'))
$script:Products.Add($msiPacked)
$script:MsiWorks = $false
$r = Invoke-Job
Assert-Same $r.Code 2 '1603 with the folder on disk exit'
Assert-Same $script:Removed.Count 0 '1603 with the folder on disk deletes nothing'
Assert-Same @(Get-BackupFiles).Count 0 '1603 with the folder on disk writes no backup'
Reset-Test
$script:Files.Add('C:\Tools\GP\unins000.exe')
$script:Apps.Add((New-App 'GPI' 'Advanced Monitoring Agent GP' 'Remote Monitoring Services' '"C:\Tools\GP\unins000.exe"' -InstallLocation 'C:\Gone\GP'))
$script:UninstallWorks = $false
$r = Invoke-Job
Assert-Same $r.Code 2 '1603 with the uninstaller target on disk exit'
Assert-Same $script:Removed.Count 0 '1603 with the uninstaller target on disk deletes nothing'
# A failed uninstall with no path to check proves nothing.
Reset-Test
$script:Apps.Add((New-App $msiCode 'Advanced Monitoring Agent GP' 'Remote Monitoring Services' "MsiExec.exe /I$msiCode" -Msi))
$script:MsiWorks = $false
$r = Invoke-Job
Assert-Same $r.Code 2 '1603 with no known path exit'
Assert-Same $script:Removed.Count 0 '1603 with no known path deletes nothing'

# A service that is still installed blocks the delete.
Reset-Test
$script:Apps.Add((New-App 'GPNoUninst' 'Advanced Monitoring Agent GP' 'Remote Monitoring Services'))
$script:Svcs.Add((New-Svc 'Advanced Monitoring Agent' "`"$amaDir\winagent.exe`""))
$script:NaRemoveService = { param($Service) throw 'dependent' }
$r = Invoke-Job
Assert-Same $r.Code 2 'a remaining service exit'
Assert-True (-not ($script:Removed -contains "key $u32\GPNoUninst")) 'a remaining service blocks the key delete'
Assert-Same @(Get-BackupFiles).Count 0 'a remaining service writes no backup'
$script:NaRemoveService = { param($Service) $script:Removed.Add("svc $($Service.Name)"); [void]$script:Svcs.Remove($Service) }

# A backup that cannot be written blocks the delete, and the run fails.
Reset-Test
$blocker = Join-Path $script:TmpRoot 'blocker'
$null = New-Item -ItemType Directory -Path $script:TmpRoot -Force
Set-Content -LiteralPath $blocker -Value 'x'
$script:NaBackupDir = Join-Path $blocker 'sub'
$script:Apps.Add((New-App $msiCode 'Advanced Monitoring Agent GP' 'Remote Monitoring Services'))
$script:Products.Add($msiPacked)
$r = Invoke-Job
Assert-Same $r.Code 2 'backup failure exit'
Assert-Same $r.Json.status 'failed' 'backup failure status'
Assert-Same $script:Removed.Count 0 'backup failure deletes nothing, not the Products entry either'
Assert-True (@(@($r.Json.log) -like 'uninstall key kept:*').Count -eq 1) 'backup failure is logged'
# So does a key whose values cannot be read.
Reset-Test
$script:Apps.Add((New-App 'GPNoUninst' 'Advanced Monitoring Agent GP' 'Remote Monitoring Services'))
$script:NaReadKeyValues = { param($Path) throw 'Access denied' }
$r = Invoke-Job
Assert-Same $r.Code 2 'unreadable key exit'
Assert-Same $script:Removed.Count 0 'unreadable key deletes nothing'
$script:NaReadKeyValues = { param($Path) @(@{ name = 'DisplayName'; kind = 'String'; data = "of $Path" }) }

# A protected name is never touched, even with nothing else about it.
Reset-Test
Add-Protected
$script:Apps.Add((New-App 'NinjaNoUninst' 'Advanced Monitoring Agent Ninja' 'Remote Monitoring Services'))
$r = Invoke-Job
Assert-Same $r.Json.status 'compliant' 'a protected key without an uninstaller is not a target'
Assert-Same $script:Removed.Count 0 'a protected key without an uninstaller is not deleted'
Assert-Same (Get-NaOrphanReason (New-App 'x' 'Advanced Monitoring Agent Wazuh' 'Remote Monitoring Services') @() @()) $null 'a protected entry has no orphan reason'
# The matching rules are not loosened: another vendor product without an uninstaller stays.
Reset-Test
$script:Apps.Add((New-App 'BM' 'Backup Manager' 'N-able Technologies'))
$r = Invoke-Job
Assert-Same $r.Json.status 'compliant' 'another vendor product is not a target'
Assert-Same $script:Removed.Count 0 'another vendor product keeps its key'

# -ReportOnly writes and deletes nothing, and reports the orphan as drift.
Reset-Test
$script:Apps.Add((New-App $msiCode 'Advanced Monitoring Agent GP' 'Remote Monitoring Services'))
$script:Products.Add($msiPacked)
$r = Invoke-Job -ReportOnly
Assert-Same $r.Code 1 'report-only orphan exit'
Assert-Same $r.Json.status 'drift' 'report-only orphan status'
Assert-True (@($r.Json.apps) -contains 'Advanced Monitoring Agent GP') 'report-only names the orphan'
Assert-Same $script:Removed.Count 0 'report-only deletes nothing'
Assert-True (-not (Test-Path -LiteralPath $script:NaBackupDir)) 'report-only writes no backup'
Assert-Same $script:BackupDirs.Count 0 'report-only creates no folder'

# Registry reads that return nothing: an entry without an InstallLocation property, empty strings, no services.
$bare = [pscustomobject]@{ Key = "$u32\X"; Id = 'X'; Name = 'Advanced Monitoring Agent'; Publisher = ''; Uninstall = ''; Msi = $false }
Assert-Same (Get-NaOrphanReason $bare @() @()) 'no uninstaller' 'an entry without an InstallLocation property is read safely'
$bare.Uninstall = '"C:\Gone\x.exe" /u'
Assert-Same (Get-NaOrphanReason $bare @($bare.Key) @()) 'uninstall failed, files gone' 'a missing target alone proves a failed uninstall orphaned'
Assert-Same (Get-NaOrphanReason $bare @() @()) $null 'an uninstaller that never ran proves nothing'
$bare.Uninstall = ''
Assert-Same (Get-NaOrphanReason $bare @() @($null)) $null 'a service in the list blocks'

[IO.Directory]::Delete($script:TmpRoot, $true)
Write-Output 'nable-agent-removal: ok'
