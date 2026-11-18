# Read-only N-able MSI log reader. The directory listing and the file read are seams; the logs are synthetic.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$modulePath = Join-Path $repoRoot 'windows/jobs/read-nable-msi-log.ps1'

function Fail { param([string]$Message) [Console]::Error.WriteLine("FAIL $Message"); exit 1 }
function Assert-True { param([bool]$Condition, [string]$Label) if (-not $Condition) { Fail $Label } }
function Assert-Same { param($Actual, $Expected, [string]$Label) if ($Actual -ne $Expected) { Fail "$Label was [$Actual] expected [$Expected]" } }

$env:RELIAN_DEPLOY_TEST = '1'
. $modulePath

$script:Files = @(); $script:Bytes = @{}
$script:RmList = { $script:Files }
$script:RmReadBytes = { param($Path) , [byte[]]$script:Bytes[$Path] }
$machine = 'm' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$script:RmMachine = $machine
function New-Log { param($Name, $Text, [string]$Enc = 'utf16', [DateTime]$When = [DateTime]::UtcNow)
    $bytes = if ($Enc -eq 'utf16') { [byte[]](@(0xFF, 0xFE) + [Text.Encoding]::Unicode.GetBytes($Text)) } else { [Text.Encoding]::GetEncoding(28591).GetBytes($Text) }
    $path = "C:\fake\$Name"; $script:Bytes[$path] = $bytes
    [pscustomobject]@{ Name = $Name; FullName = $path; Length = [int64]$bytes.Length; LastWriteTimeUtc = $When }
}
function Invoke-Read { $r = Invoke-ReadMsiLogJob; [pscustomobject]@{ Code = $r.ExitCode; Line = $r.Line; Json = ($r.Line | ConvertFrom-Json) } }

$userName = 'u' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$userPath = "C:\Users\$userName\AppData\x.txt"
$secretA = 'p' + [guid]::NewGuid().ToString('N').Substring(0, 8); $secretB = 't' + [guid]::NewGuid().ToString('N').Substring(0, 8); $otherUser = 'v' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$body = @(1..30 | ForEach-Object { "MSI (s) (00:00): filler line $_" })
$body += @(
    'Action start 10:00:01: InstallInitialize.',
    'Action ended 10:00:02: InstallInitialize. Return value 1.',
    'Action start 10:00:03: RemoveAgentCA.',
    'MSI (s) (00:00): Note: 1: 2 3: 4',
    "CustomAction RemoveAgentCA returned actual error code 1603 (note this may not be 100% accurate) $userPath",
    'Action ended 10:00:04: RemoveAgentCA. Return value 3.',
    'Action start 10:00:05: Rollback.',
    'Action ended 10:00:06: Rollback. Return value 3.',
    "Error 1722. There is a problem with this Windows Installer package. contact admin@example.com or 192.0.2.10 on $machine as S-1-5-21-111-222-333-1001",
    'Property(S): REMOVE = ALL',
    'Property(S): INSTALLLEVEL = 1',
    'Property(S): UILevel = 2',
    'Property(S): INSTALLDIR = C:\Program Files\Agent\',
    "Property(S): ADMINPASSWORD = $secretA and more",
    "Property(S): TargetDir = C:\Users\$otherUser\Agent",
    "Property(S): LOGONUSER = svc",
    "cmd SERVICE_TOKEN=$secretB other=1",
    ('x' * 500)
)
$text = $body -join "`r`n"

# UTF-16 LE with BOM, picks the newest of two files.
$script:Files = @((New-Log 'nable-msi-old.log' 'old' -When ([DateTime]::UtcNow.AddDays(-1))), (New-Log 'nable-msi-new.log' $text))
$r = Invoke-Read
$j = $r.Json
Assert-Same $r.Code 0 'exit'
Assert-Same (($j.PSObject.Properties.Name) -join ',') 'job,status,file,sizeBytes,lastWriteUtc,encoding,lineCount,firstReturnValue3,errorLines,customActions,properties,tail,truncated,error' 'output keys'
Assert-Same $j.job 'read-nable-msi-log' 'job'
Assert-Same $j.file 'nable-msi-new.log' 'newest file'
Assert-Same $j.encoding 'UTF-16LE-BOM' 'utf16 detected'
Assert-Same $j.lineCount $body.Count 'line count'
Assert-True ($j.sizeBytes -gt 0 -and $r.Line -match '"lastWriteUtc":"\d{4}-\d\d-\d\dT[\d:]+Z"') 'size and time'

# First Return value 3: 12 before, 6 after.
Assert-Same @($j.firstReturnValue3).Count 2 'both Return value 3 lines'
$w = @($j.firstReturnValue3)[0]
Assert-Same $w.line 36 'line number of first'
Assert-Same @($w.context).Count 19 'window is 12 + 1 + 6'
Assert-True (@($w.context)[12] -like '*RemoveAgentCA. Return value 3.') 'matching line sits after 12 before'

# Custom-action pairing and return values.
$ca = @($j.customActions)
Assert-Same ($ca | Where-Object name -eq 'InstallInitialize').returnValue 1 'paired value 1'
Assert-Same ($ca | Where-Object name -eq 'RemoveAgentCA').returnValue 3 'paired value 3'
Assert-Same ($ca | Where-Object name -eq 'Rollback').returnValue 3 'rollback paired'

# Error lines and properties.
Assert-Same @($j.errorLines | Where-Object { $_ -like '*returned actual error code 1603*' }).Count 1 'custom action error line'
Assert-Same @($j.errorLines | Where-Object { $_ -like '*Error 1722*' }).Count 1 'Error #### line'
Assert-Same $j.properties.REMOVE 'ALL' 'REMOVE'
Assert-Same $j.properties.INSTALLLEVEL '1' 'INSTALLLEVEL'
Assert-Same $j.properties.UILevel '2' 'UILevel'
Assert-Same $j.properties.INSTALLDIR 'C:\Program Files\Agent\' 'install dir'
Assert-Same $j.properties.TargetDir 'C:\Users\<user>\Agent' 'target dir user masked'
$names = @($j.properties.PSObject.Properties.Name)
Assert-True (-not ($names -contains 'LOGONUSER' -or $names -contains 'ADMINPASSWORD')) 'only deciding properties'

# Redaction across every section, and the 300-character cap.
$all = $r.Line
foreach ($leak in $userName, 'admin@example.com', '192.0.2.10', $machine, 'S-1-5-21-111', $secretA, $secretB, $otherUser) { Assert-True (-not $all.Contains($leak)) "redacted $leak" }
foreach ($mark in 'Users\\\\<user>', '<email>', '<ip>', '<machine>', '<sid>', 'SERVICE_TOKEN=<redacted>') { Assert-True ($all -match $mark) "mask $mark present" }
Assert-Same (Get-RmRedacted "Property(S): ADMINPASSWORD = $secretA and more") 'Property(S): ADMINPASSWORD = <redacted>' 'secret property value'
Assert-Same @($j.tail).Count 40 'tail of 40'
Assert-Same @($j.tail)[39].Length 300 'line cap'

# ANSI decode (non-ASCII byte kept, no BOM, no NULs).
$script:Files = @(New-Log 'nable-msi-ansi.log' "first caf$([char]0xE9)`nAction start 1:2:3: A.`nAction ended 1:2:4: A. Return value 1.`n" 'ansi')
$j = (Invoke-Read).Json
Assert-Same $j.encoding 'ANSI' 'ansi detected'
Assert-Same $j.lineCount 3 'ansi line count'
Assert-Same @($j.tail)[0] "first caf$([char]0xE9)" 'ansi text decoded'
# UTF-16 LE without a BOM.
$script:Bytes['C:\fake\n.log'] = [Text.Encoding]::Unicode.GetBytes("line one`r`nline two`r`n")
$script:Files = @([pscustomobject]@{ Name = 'n.log'; FullName = 'C:\fake\n.log'; Length = 10; LastWriteTimeUtc = [DateTime]::UtcNow })
$j = (Invoke-Read).Json
Assert-Same $j.encoding 'UTF-16LE' 'bom-less utf16 detected'
Assert-Same @($j.tail)[1] 'line two' 'bom-less utf16 text'

# Truncation: the cap on error lines, and the JSON size limit.
$many = (1..80 | ForEach-Object { "Error $($_ + 1000). thing" }) -join "`n"
$script:Files = @(New-Log 'nable-msi-many.log' $many 'ansi')
$j = (Invoke-Read).Json
Assert-Same @($j.errorLines).Count 40 'error lines capped'
Assert-Same $j.truncated $true 'truncated flag on cap'
$script:Files = @(New-Log 'nable-msi-big.log' ((1..200 | ForEach-Object { 'z' * 290 }) -join "`n") 'ansi')
$script:RmJsonCap = 3000
$r = Invoke-Read
Assert-True ($r.Line.Length -le 3000) 'json line under the cap'
Assert-Same $r.Json.truncated $true 'truncated flag on size'
$script:RmJsonCap = 60000

# No log, and a read failure.
$script:Files = @()
$r = Invoke-Read
Assert-Same $r.Code 0 'no log exit'
Assert-Same $r.Json.status 'ok' 'no log status'
Assert-True ($null -eq $r.Json.file) 'file null'
Assert-True ($r.Json.error -like 'no nable-msi log*') 'note says no log'
$script:Files = @([pscustomobject]@{ Name = 'x.log'; FullName = 'C:\fake\missing.log'; Length = 1; LastWriteTimeUtc = [DateTime]::UtcNow })
$script:RmReadBytes = { param($Path) throw 'sharing violation' }
$r = Invoke-Read
Assert-Same $r.Code 2 'read failure exit'
Assert-Same $r.Json.status 'failed' 'read failure status'

# The module never writes or starts a process (comments excluded), reads one directory and takes only -ReportOnly.
$code = (Get-Content -LiteralPath $modulePath | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
foreach ($bad in 'Remove-', 'Set-Content', 'Set-Item', 'New-Item', 'Out-File', 'Add-Content', 'Start-Process', 'WriteAllText', 'WriteAllBytes', 'FileAccess\]::Write', 'FileMode\]::Create', '\.Delete\(', 'msiexec') {
    Assert-True ($code -notmatch $bad) "module source has no $bad"
}
$params = ([regex]::Matches((Get-Content -LiteralPath $modulePath -Raw), '(?ms)^param\((.*?)\)\s*$') | Select-Object -First 1).Groups[1].Value
Assert-Same $params '[switch]$ReportOnly' 'only -ReportOnly is accepted'
Assert-Same @([regex]::Matches($code, 'C:\\ProgramData[^''"]*')).Count 1 'one directory only'

Write-Output 'read-nable-msi-log: ok'
