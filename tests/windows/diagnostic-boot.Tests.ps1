$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
function Assert($Condition,$Label) { if (-not $Condition) { throw "FAIL $Label" } }
$root=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$env:RELIAN_DEPLOY_TEST='1'
. (Join-Path $root 'windows/packages/diagnose-feature-upgrade/Invoke-DiagnoseFeatureUpgrade.ps1')
$temp=Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('n'))
$null=New-Item -ItemType Directory -Path $temp
try {
    $log=Join-Path $temp 'setupapi.dev.log'
    [IO.File]::WriteAllText($log, (@('>>> Device install sample.inf','!!! first driver failure sample.sys') + @(1..20 | ForEach-Object { "routine $_" }) + @('!!! last driver failure other.sys') + @(1..20 | ForEach-Object { "later routine $_" })) -join "`n")
    $r=Read-DiagnosticLog $log
    Assert (($r.matches -join ' ') -match 'first driver failure sample.sys' -and ($r.matches -join ' ') -match 'last driver failure other.sys') 'first and last driver errors survive routine trailing records'
    $dump=Join-Path $temp 'setupmem.dmp'
    $sensitive=[guid]::NewGuid().ToString('n')
    [IO.File]::WriteAllText($dump,$sensitive)
    $r=Read-DiagnosticFileMetadata $dump
    Assert ($r.status -eq 'present' -and $r.sizeBytes -eq 32 -and $r.lastWriteUtc) 'dump metadata available'
    Assert (($r.Keys | Sort-Object) -join ',' -eq 'lastWriteUtc,sizeBytes,status') 'metadata allowlist only'
    Assert (($r | ConvertTo-Json) -notmatch $sensitive) 'dump contents absent'
    $r=Read-DiagnosticFileMetadata (Join-Path $temp 'missing.dmp')
    Assert ($r.status -eq 'missing') 'missing dump explicit'
} finally { Remove-Item -LiteralPath $temp -Recurse -Force }
Write-Output 'diagnostic-boot tests passed'
$script:failEvents=$false
function Get-CimInstance {
    param($ClassName,$Filter,$Property,$OperationTimeoutSec,$ErrorAction)
    Assert ($ClassName -eq 'Win32_NTLogEvent' -and $OperationTimeoutSec -eq 5) 'bounded read-only event query'
    Assert ($Filter -match "Logfile='System'" -and $Filter -match 'TimeGenerated >=' -and $Filter -match 'EventCode=41' -and $Filter -match 'EventCode=1001' -and $Filter -match 'EventCode=6008') 'filtered System boot event window'
    Assert (($Property -join ',') -eq 'TimeGenerated,SourceName,EventCode,Message') 'event properties allowlisted'
    if ($script:failEvents) { throw [UnauthorizedAccessException]::new('private exception detail') }
    foreach ($i in 1..12) { [pscustomobject]@{TimeGenerated=[datetime]::UtcNow.AddMinutes($i);SourceName='Microsoft-Windows-WER-SystemErrorReporting';EventCode=1001;Message=('sample.sys 0x0000007e ' * 100);Unrequested='excluded'} }
}
$r=Read-DiagnosticBootEvents
Assert ($r.status -eq 'collected' -and $r.events.Count -eq 8) 'eight most recent events only'
Assert ([datetime]$r.events[0].timestamp -gt [datetime]$r.events[7].timestamp) 'events newest first'
Assert ($r.events[0].message.Length -le 510 -and $r.events[0].message -match 'sample.sys') 'bounded useful event text'
Assert (($r.events[0].Keys -join ',') -eq 'timestamp,source,id,message') 'event fields allowlisted'
$report=[ordered]@{version='5';section='Boot';bootEvents=$r;logs=@();notes=@()}
$json=ConvertTo-BoundedDiagnosticJson $report
Assert ([Text.Encoding]::UTF8.GetByteCount($json) -le 8000 -and ($json | ConvertFrom-Json).bootEvents.events.Count -eq 8) 'Boot events fit valid transport JSON'
$script:failEvents=$true
$r=Read-DiagnosticBootEvents
Assert ($r.status -eq 'unavailable' -and ($r | ConvertTo-Json) -notmatch 'private exception') 'event failures sanitized'
Write-Output 'diagnostic-boot event tests passed'
# Exercise serialized UTF-8 budget with all three verbose driver logs and events.
$eventMessage=([string][char]0x6F22) * 500
$events=@(1..8 | ForEach-Object { [ordered]@{timestamp='2026-01-01T01:00:00Z';source='Microsoft-Windows-WER-SystemErrorReporting';id=1001;message=$eventMessage} })
$logs=@(1..3 | ForEach-Object { @{label="drivers-$_";status='read';matches=@(('!!! sample.sys ' + $eventMessage),('!!! other.sys ' + $eventMessage));tail=@($eventMessage)} })
$report=[ordered]@{version='5';section='Boot';setupMemoryDump=@{status='present';sizeBytes=12345;lastWriteUtc='2026-01-01T00:00:00Z'};bootEvents=@{status='collected';events=$events};logs=$logs;notes=@()}
$json=ConvertTo-BoundedDiagnosticJson $report
$parsed=$json | ConvertFrom-Json
Assert ([Text.Encoding]::UTF8.GetByteCount($json) -le 8000 -and $parsed.truncated) 'combined Unicode events and logs bounded after serialization'
Assert ($parsed.setupMemoryDump.sizeBytes -eq 12345 -and $parsed.bootEvents.events.Count -eq 8 -and $parsed.logs.Count -eq 3) 'budget retains metadata and bounded evidence collections'
Assert ((Protect-DiagnosticText ('password=' + [guid]::NewGuid().ToString('n')) -Max 500) -eq '[sensitive line omitted]') 'event sanitizer excludes sensitive message'
Write-Output 'diagnostic-boot transport tests passed'
