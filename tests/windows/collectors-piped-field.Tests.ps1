# The four NinjaOne collectors are job modules run by windows/runner/Invoke-RelianJob.ps1. Each writes one
# JSON value to a custom field. On Windows PowerShell 5.1 a native argument loses its embedded double
# quotes, so the value must be piped to Ninja-Property-Set-Piped. Mocked: each collector's write block is
# cut out with the AST and run with both cmdlets stubbed. Then one collector runs through the real loader
# in a child process. No network.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Fail { param([string]$Message) [Console]::Error.WriteLine("FAIL $Message"); exit 1 }
function Assert-True { param([bool]$Condition, [string]$Label) if (-not $Condition) { Fail $Label } }

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$json = '{"drives":[{"name":"a b","note":"say \"hi\""}],"version":"1.0"}'
function Write-Status { param([string]$Message, [string]$Level = 'INFO') $script:status += "$Level|$Message`n" }

# Runs the cut block; pipeline objects and host lines come back apart, and a throw is kept.
function Invoke-Block {
    param($Block)
    $script:viaArg = $null; $script:viaPipe = $null; $script:status = ''
    # Streamed into a list, so the lines printed before a throw are kept.
    $all = [Collections.Generic.List[object]]::new(); $thrown = $null
    try { . $Block 6>&1 | ForEach-Object { $all.Add($_) } } catch { $thrown = $_ }
    [pscustomobject]@{
        Out    = @($all | Where-Object { $_ -isnot [Management.Automation.InformationRecord] })
        Host   = (@($all | Where-Object { $_ -is [Management.Automation.InformationRecord] }) -join "`n")
        Thrown = $thrown
    }
}

$collectors = @(
    @{ File = 'cpu-benchmark'; Field = 'relian_cpu_benchmark'; Prefix = 'BENCHMARK_RESULT' },
    @{ File = 'hardware-inventory'; Field = 'relian_hardware_inventory'; Prefix = 'INVENTORY_RESULT' },
    @{ File = 'network-audit'; Field = 'relian_network_audit'; Prefix = 'NETWORK_AUDIT_RESULT' },
    @{ File = 'storage-health'; Field = 'relian_storage_health'; Prefix = 'STORAGE_HEALTH_RESULT' }
)
foreach ($c in $collectors) {
    $path = Join-Path $repoRoot "windows/collectors/$($c.File).ps1"
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)

    # A job module: the loader passes only -ReportOnly, and an exit would end the loader's process.
    $params = @(if ($ast.ParamBlock) { $ast.ParamBlock.Parameters })
    Assert-True (@($params | Where-Object { $_.Name.VariablePath.UserPath -eq 'ReportOnly' -and $_.StaticType -eq [switch] }).Count -eq 1) "$($c.File): needs param([switch]`$ReportOnly)"
    Assert-True (@($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ExitStatementAst] }, $true)).Count -eq 0) "$($c.File): a job module must not exit"

    $tries = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.TryStatementAst] -and
        @($n.Body.FindAll({ param($x) $x -is [System.Management.Automation.Language.CommandAst] -and $x.GetCommandName() -like 'Ninja-Property-Set*' }, $true)).Count }, $true))
    if ($tries.Count -lt 1) { Fail "$($c.File): no try block writes the field" }
    $block = [scriptblock]::Create($tries[-1].Extent.Text) # pre-order: the last match is the innermost try

    function Ninja-Property-Set { param($Name, $Value) $script:viaArg = @($Name, $Value) }
    function Ninja-Property-Set-Piped { param([Parameter(Position = 0)]$Name, [Parameter(ValueFromPipeline = $true)]$Value) process { $script:viaPipe = @($Name, $Value) } }

    # Write: the JSON is piped unchanged, and stdout gets one short summary line.
    $ReportOnly = [switch]$false
    $r = Invoke-Block $block
    if ($r.Thrown) { Fail "$($c.File): the write threw: $($r.Thrown)" }
    if ($null -ne $script:viaArg) { Fail "$($c.File): Ninja-Property-Set must not receive the value as an argument" }
    if ($null -eq $script:viaPipe -or $script:viaPipe[0] -cne $c.Field -or $script:viaPipe[1] -cne $json) { Fail "$($c.File): the JSON must reach Ninja-Property-Set-Piped for $($c.Field) unchanged" }
    Assert-True ($r.Out.Count -eq 1) "$($c.File): one summary line on stdout, got $($r.Out.Count)"
    $summary = "$($r.Out[0])" | ConvertFrom-Json
    Assert-True ($summary.field -ceq $c.Field -and $summary.written -eq $true -and $summary.bytes -eq $json.Length) "$($c.File): summary [$($r.Out[0])]"

    # -ReportOnly: nothing is written, the JSON is printed, and the summary says not written.
    $ReportOnly = [switch]$true
    $r = Invoke-Block $block
    if ($r.Thrown) { Fail "$($c.File): -ReportOnly threw: $($r.Thrown)" }
    Assert-True ($null -eq $script:viaArg -and $null -eq $script:viaPipe) "$($c.File): -ReportOnly must not write the field"
    Assert-True ($r.Host.Contains("$($c.Prefix):$json")) "$($c.File): -ReportOnly prints the JSON"
    Assert-True ($r.Out.Count -eq 1 -and ("$($r.Out[0])" | ConvertFrom-Json).written -eq $false) "$($c.File): -ReportOnly summary [$($r.Out -join '|')]"

    # Piped cmdlet missing: warn, print the result, and throw so the loader exits 1. Nothing is written.
    $ReportOnly = [switch]$false
    Remove-Item -LiteralPath Function:\Ninja-Property-Set-Piped
    $r = Invoke-Block $block
    Assert-True ($null -ne $r.Thrown) "$($c.File): a failed field write must throw"
    if ($null -ne $script:viaArg -or $null -ne $script:viaPipe) { Fail "$($c.File): nothing may be written when the piped cmdlet is missing" }
    if ($script:status -notmatch 'WARN\|Could not write to custom field' -or -not $r.Host.Contains("$($c.Prefix):$json")) { Fail "$($c.File): missing-cmdlet path must warn and print the result" }
    Assert-True ($r.Out.Count -eq 0) "$($c.File): no summary after a failed write"
    Remove-Item -LiteralPath Function:\Ninja-Property-Set
}

# End to end: storage-health through the real loader in a child process. Its CIM calls are each caught,
# so it runs on Linux too. The cache and download are the loader's seams; the field cmdlet is a stub.
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('relian-collector-test-' + [guid]::NewGuid().ToString('n'))
[void](New-Item -ItemType Directory -Path $tempRoot)
$loaderPath = Join-Path $repoRoot 'windows/runner/Invoke-RelianJob.ps1'
$modulePath = Join-Path $repoRoot 'windows/collectors/storage-health.ps1'
$sha = [Security.Cryptography.SHA256]::Create()
$moduleHash = ([BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($modulePath))) -replace '-', '').ToLowerInvariant()
$fieldFile = Join-Path $tempRoot 'field.txt'
$wrapper = Join-Path $tempRoot 'wrapper.ps1'
@"
param([switch]`$ReportOnly)
`$report = [bool]`$ReportOnly # dot-sourcing the loader resets -ReportOnly in this scope to its own default
`$env:RELIAN_DEPLOY_TEST = '1'
. '$loaderPath'
`$env:RELIAN_DEPLOY_TEST = `$null
`$script:CacheRoot = '$(Join-Path $tempRoot 'Relian/Jobs')'
`$script:ReadSddl = { param(`$Path) 'O:SYG:SYD:P(A;OICI;FA;;;SY)' }
`$script:ProtectDirectory = { param(`$Path) }
`$script:DownloadFile = { param(`$Url, `$Destination) [IO.File]::Copy('$modulePath', `$Destination, `$true) }
function Ninja-Property-Set-Piped { param([Parameter(Position = 0)]`$Name, [Parameter(ValueFromPipeline = `$true)]`$Value)
    process { if (`$env:RELIAN_FAIL_FIELD) { throw 'field write refused' }; [IO.File]::WriteAllText('$fieldFile', "`$Name=`$Value") } }
exit (Invoke-RelianJob -ModuleUrl 'https://example.invalid/storage-health.ps1' -ModuleSha256 '$moduleHash' -ReportOnly:`$report)
"@ | Set-Content -LiteralPath $wrapper
$pwshPath = (Get-Process -Id $PID).Path
$errFile = Join-Path $tempRoot 'stderr.txt'
function Invoke-Child { param([string[]]$Extra)
    # Windows PowerShell 5.1 turns redirected native stderr into errors, which Stop would throw.
    $ErrorActionPreference = 'Continue'
    $out =& $pwshPath -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $wrapper @Extra 2>$errFile
    [pscustomobject]@{ Code = $LASTEXITCODE; Out = @($out); Err = [IO.File]::ReadAllText($errFile) }
}

$r = Invoke-Child @()
Assert-True ($r.Code -eq 0) "loader: storage-health exit [$($r.Code)] $($r.Err)"
$summary = $r.Out[-1] | ConvertFrom-Json
Assert-True ($summary.field -ceq 'relian_storage_health' -and $summary.written -eq $true) "loader: last stdout line is the summary [$($r.Out[-1])]"
$written = [IO.File]::ReadAllText($fieldFile)
Assert-True ($written.StartsWith('relian_storage_health={')) "loader: field write [$written]"
Assert-True ($null -ne ($written.Substring('relian_storage_health='.Length) | ConvertFrom-Json).totalDrives) 'loader: the field holds the full JSON'
Assert-True ($summary.bytes -eq $written.Length - 'relian_storage_health='.Length) 'loader: summary bytes match the field'

Remove-Item -LiteralPath $fieldFile
$r = Invoke-Child @('-ReportOnly')
Assert-True ($r.Code -eq 0) "loader: -ReportOnly exit [$($r.Code)] $($r.Err)"
Assert-True (-not (Test-Path -LiteralPath $fieldFile)) 'loader: -ReportOnly writes no field'
Assert-True (($r.Out[-1] | ConvertFrom-Json).written -eq $false) "loader: -ReportOnly summary [$($r.Out[-1])]"

# A thrown module error ends the run with exit 1 and the reason on stderr, not a silent exit 0.
$env:RELIAN_FAIL_FIELD = '1'
$r = Invoke-Child @()
$env:RELIAN_FAIL_FIELD = $null
Assert-True ($r.Code -eq 1) "loader: failed field write exit [$($r.Code)]"
Assert-True ($r.Err -match 'field write refused') "loader: the reason reaches stderr [$($r.Err)]"

Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
Write-Host 'collectors-piped-field: OK'
