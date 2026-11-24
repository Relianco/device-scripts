# reset-wazuh-enrollment module tests. The service, registry and ACL calls are faked behind seams;
# the agent folder and the backups are real files in a temp directory.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$modulePath = Join-Path $repoRoot 'windows/jobs/reset-wazuh-enrollment.ps1'

function Fail { param([string]$Message) [Console]::Error.WriteLine("FAIL $Message"); exit 1 }
function Assert-True { param([bool]$Condition, [string]$Label) if (-not $Condition) { Fail $Label } }
function Assert-Same { param($Actual, $Expected, [string]$Label) if ("$Actual" -ne "$Expected") { Fail "$Label was [$Actual] expected [$Expected]" } }

$env:RELIAN_DEPLOY_TEST = '1'
. $modulePath

$tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ('reset-wazuh-' + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $tmpRoot
$keyBytes = [Text.Encoding]::ASCII.GetBytes("001 PC-01 any 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef`n")

function Reset-Test {
    param([string]$Service = 'Running', $Keys = $keyBytes, [switch]$AuthdPass, [string]$InstallLocation = 'agent', [switch]$NoUninstall)
    $script:Case = Join-Path $tmpRoot ([Guid]::NewGuid().ToString('N'))
    $script:AgentDir = Join-Path $script:Case 'ossec-agent'
    $null = New-Item -ItemType Directory -Path $script:AgentDir -Force
    if ($null -ne $Keys) { [IO.File]::WriteAllBytes((Join-Path $script:AgentDir 'client.keys'), [byte[]]$Keys) }
    if ($AuthdPass) { [IO.File]::WriteAllText((Join-Path $script:AgentDir 'authd.pass'), 'enrolment-secret') }
    $script:FakeService = $Service
    $script:StopLeaves = ''
    $script:Log = [Collections.Generic.List[string]]::new()
    $script:FakeEntries = @()
    if (-not $NoUninstall) {
        $loc = $(if ($InstallLocation -eq 'agent') { $script:AgentDir } else { $InstallLocation })
        $script:FakeEntries = @(
            [pscustomobject]@{ DisplayName = 'Other App'; InstallLocation = $script:Case },
            [pscustomobject]@{ DisplayName = 'Wazuh Agent'; InstallLocation = $loc }
        )
    }
    $script:WrDefaultRoots = @((Join-Path $script:Case 'x86'), (Join-Path $script:Case 'x64'))
    $script:WrBackupDir = Join-Path $script:Case 'ProgramData\Relian\wazuh'
}

$script:WrReadUninstall = { $script:Log.Add('read-uninstall'); return @($script:FakeEntries) }
$script:WrServiceStatus = { return $script:FakeService }
$script:WrStopService = {
    param([int]$Seconds)
    $script:Log.Add("stop $Seconds")
    if ($script:StopLeaves) { $script:FakeService = $script:StopLeaves } else { $script:FakeService = 'Stopped' }
}
$script:WrStartService = { $script:Log.Add('start'); $script:FakeService = 'Running' }
$script:WrProtect = {
    param([string]$Path)
    $len = $(if (Test-Path -LiteralPath $Path -PathType Leaf) { (Get-Item -LiteralPath $Path).Length } else { 'dir' })
    $script:Log.Add("protect $(Split-Path -Leaf $Path) $len")
}

function Keys { return (Get-Item -LiteralPath (Join-Path $script:AgentDir 'client.keys')).Length }
function Backups { if (Test-Path -LiteralPath $script:WrBackupDir) { @(Get-ChildItem -LiteralPath $script:WrBackupDir -File) } else { @() } }

# Check mode (-ReportOnly): reports and changes nothing.
Reset-Test -AuthdPass
$r = Invoke-WrJob -ReportOnly
Assert-Same $r.Mode 'report' 'report mode'
Assert-Same $r.Status 'drift' 'enrolled agent reports drift'
Assert-Same $r.ExitCode 1 'drift exit'
Assert-Same $r.Service 'Running' 'service status reported'
Assert-Same $r.KeysLength $keyBytes.Length 'client.keys length reported'
Assert-Same $r.AuthdPass $true 'authd.pass presence reported'
Assert-Same $r.AgentDir $script:AgentDir 'agent dir from the uninstall entry'
Assert-Same $r.DirSource 'uninstall' 'dir source'
Assert-Same (Keys) $keyBytes.Length 'report keeps client.keys'
Assert-Same (@(Backups).Count) 0 'report writes no backup'
Assert-True (-not ($script:Log -match '^(stop|start|protect)')) 'report touches no service or ACL'

# No InstallLocation: the package default folder, x86 first.
Reset-Test -InstallLocation ''
$x86 = Join-Path $script:WrDefaultRoots[0] 'ossec-agent'
$null = New-Item -ItemType Directory -Path $x86 -Force
[IO.File]::WriteAllBytes((Join-Path $x86 'client.keys'), [byte[]](1, 2, 3))
$r = Invoke-WrJob -ReportOnly
Assert-Same $r.AgentDir $x86 'default dir under Program Files (x86)'
Assert-Same $r.DirSource 'default' 'default dir source'
Assert-Same $r.KeysLength 3 'default dir keys length'
Assert-Same $r.AuthdPass $false 'no authd.pass'

# Already empty keys: nothing to reset.
Reset-Test -Keys ([byte[]]@())
$r = Invoke-WrJob -ReportOnly
Assert-Same $r.Status 'unchanged' 'empty keys unchanged'
Assert-Same $r.ExitCode 0 'empty keys exit'

# No agent: failed, exit 2.
Reset-Test -NoUninstall -Service ''
Remove-Item -LiteralPath $script:AgentDir -Recurse -Force
$r = Invoke-WrJob -ReportOnly
Assert-Same $r.Status 'failed' 'no agent fails'
Assert-Same $r.ExitCode 2 'no agent exit'

# The JSON line never carries the key or the secret.
Reset-Test -AuthdPass
$line = ConvertTo-WrJobLine (Invoke-WrJob -ReportOnly)
Assert-True ($line -notmatch '0123456789abcdef|enrolment-secret') 'line has no file contents'
Assert-True (-not $line.Contains("`n")) 'one line'
$doc = $line | ConvertFrom-Json
Assert-Same $doc.job 'reset-wazuh-enrollment' 'job name in line'
Assert-Same $doc.keysLength $keyBytes.Length 'keysLength in line'

# Apply: stop (bounded), backup with its ACL set before content, truncate, service left stopped.
Reset-Test -AuthdPass
$r = Invoke-WrJob
Assert-Same $r.Mode 'run' 'run mode'
Assert-Same $r.Status 'reset' 'apply status'
Assert-Same $r.ExitCode 0 'apply exit'
Assert-Same $r.KeysLength $keyBytes.Length 'apply reports length before'
Assert-Same $r.KeysAfter 0 'apply reports length after'
Assert-Same (Keys) 0 'client.keys truncated to 0 bytes'
Assert-True (Test-Path -LiteralPath (Join-Path $script:AgentDir 'client.keys')) 'client.keys kept, not deleted'
Assert-Same $script:FakeService 'Stopped' 'service left stopped'
Assert-Same $r.Service 'Stopped' 'service reported stopped'
Assert-True (-not ($script:Log -contains 'start')) 'apply does not start the service'
Assert-Same (@($script:Log | Where-Object { $_ -like 'stop *' }))[0] 'stop 60' 'stop wait is bounded at 60 seconds'
$bak = @(Backups)
Assert-Same $bak.Count 1 'one backup'
Assert-True ($bak[0].Name -cmatch '\Aclient\.keys\.bak-\d{8}T\d{6}Z\z') 'backup name has a UTC timestamp'
Assert-Same $r.Backup $bak[0].FullName 'backup path reported'
Assert-Same ([Convert]::ToBase64String([IO.File]::ReadAllBytes($bak[0].FullName))) ([Convert]::ToBase64String($keyBytes)) 'backup holds the old keys'
Assert-True ($script:Log -contains "protect $($bak[0].Name) 0") 'backup ACL set while the file is still empty'
Assert-True ($script:Log -contains 'protect wazuh dir') 'backup folder ACL set'
Assert-True ([array]::IndexOf($script:Log.ToArray(), 'protect wazuh dir') -lt [array]::IndexOf($script:Log.ToArray(), "protect $($bak[0].Name) 0")) 'folder protected before the file'

# Undo as documented in the module header brings the old keys back.
[IO.File]::WriteAllBytes((Join-Path $script:AgentDir 'client.keys'), [IO.File]::ReadAllBytes($r.Backup))
Assert-Same (Keys) $keyBytes.Length 'undo restores client.keys'

# Already empty: no stop, no backup.
Reset-Test -Keys ([byte[]]@())
$r = Invoke-WrJob
Assert-Same $r.Status 'unchanged' 'apply on empty keys unchanged'
Assert-Same $r.ExitCode 0 'apply on empty keys exit'
Assert-True (-not ($script:Log -match '^(stop|protect)')) 'empty keys: no stop, no backup'

# The service does not stop in time: nothing copied or truncated, failed.
Reset-Test
$script:StopLeaves = 'StopPending'
$r = Invoke-WrJob
Assert-Same $r.Status 'failed' 'stop timeout fails'
Assert-Same $r.ExitCode 2 'stop timeout exit'
Assert-Same (Keys) $keyBytes.Length 'stop timeout keeps client.keys'
Assert-Same (@(Backups).Count) 0 'stop timeout writes no backup'

# A backup that cannot be protected: keys kept, the service started again.
Reset-Test
$saved = $script:WrProtect
$script:WrProtect = { param([string]$Path) if (Test-Path -LiteralPath $Path -PathType Leaf) { throw 'acl denied' } }
$r = Invoke-WrJob
$script:WrProtect = $saved
Assert-Same $r.Status 'failed' 'acl failure fails'
Assert-Same $r.ExitCode 2 'acl failure exit'
Assert-Same (Keys) $keyBytes.Length 'acl failure keeps client.keys'
Assert-Same $script:FakeService 'Running' 'acl failure starts the service again'
Assert-True (-not (@(Backups) | Where-Object { $_.Length -gt 0 })) 'acl failure leaves no backup content'

# A backup that reads back different: keys kept, the service started again.
Reset-Test
$savedCopy = $script:WrCopyInto
$script:WrCopyInto = { param([string]$Source, [string]$Destination) [IO.File]::WriteAllBytes($Destination, [byte[]](1, 2)) }
$r = Invoke-WrJob
$script:WrCopyInto = $savedCopy
Assert-Same $r.Status 'failed' 'bad backup fails'
Assert-Same (Keys) $keyBytes.Length 'bad backup keeps client.keys'
Assert-Same $script:FakeService 'Running' 'bad backup starts the service again'

# A backup folder that is a reparse point is refused before anything is written.
Reset-Test
$savedReparse = $script:WrIsReparse
$script:WrIsReparse = { param([string]$Path) return $Path -eq $script:WrBackupDir }
$null = New-Item -ItemType Directory -Path $script:WrBackupDir -Force
$r = Invoke-WrJob
$script:WrIsReparse = $savedReparse
Assert-Same $r.Status 'failed' 'reparse backup folder fails'
Assert-Same (Keys) $keyBytes.Length 'reparse keeps client.keys'
Assert-Same (@(Backups).Count) 0 'reparse writes no backup'

Remove-Item -LiteralPath $tmpRoot -Recurse -Force
Write-Output 'reset-wazuh-enrollment tests passed'
