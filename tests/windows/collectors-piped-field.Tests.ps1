# The four NinjaOne collectors write one JSON line to a custom field. On Windows PowerShell 5.1 a native
# argument loses its embedded double quotes, so the value must be piped to Ninja-Property-Set-Piped.
# Mocked: each collector's write block is cut out with the AST and run with both cmdlets stubbed.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Fail { param([string]$Message) [Console]::Error.WriteLine("FAIL $Message"); exit 1 }

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$json = '{"drives":[{"name":"a b","note":"say \"hi\""}],"version":"1.0"}'
function Write-Status { param([string]$Message, [string]$Level = 'INFO') $script:status += "$Level|$Message`n" }

foreach ($c in @(
    @{ File = 'cpu-benchmark'; Field = 'relian_cpu_benchmark' },
    @{ File = 'hardware-inventory'; Field = 'relian_hardware_inventory' },
    @{ File = 'network-audit'; Field = 'relian_network_audit' },
    @{ File = 'storage-health'; Field = 'relian_storage_health' }
)) {
    $path = Join-Path $repoRoot "windows/collectors/$($c.File).ps1"
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
    $tries = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.TryStatementAst] -and
        @($n.Body.FindAll({ param($x) $x -is [System.Management.Automation.Language.CommandAst] -and $x.GetCommandName() -like 'Ninja-Property-Set*' }, $true)).Count }, $true))
    if ($tries.Count -lt 1) { Fail "$($c.File): no try block writes the field" }
    $block = [scriptblock]::Create($tries[-1].Extent.Text) # pre-order: the last match is the innermost try

    $script:viaArg = $null; $script:viaPipe = $null; $script:status = ''
    function Ninja-Property-Set { param($Name, $Value) $script:viaArg = @($Name, $Value) }
    function Ninja-Property-Set-Piped { param([Parameter(Position = 0)]$Name, [Parameter(ValueFromPipeline = $true)]$Value) process { $script:viaPipe = @($Name, $Value) } }
    . $block
    if ($null -ne $script:viaArg) { Fail "$($c.File): Ninja-Property-Set must not receive the value as an argument" }
    if ($null -eq $script:viaPipe -or $script:viaPipe[0] -cne $c.Field -or $script:viaPipe[1] -cne $json) { Fail "$($c.File): the JSON must reach Ninja-Property-Set-Piped for $($c.Field) unchanged" }

    # Piped cmdlet missing: the existing catch reports and prints the result line; nothing is written.
    Remove-Item -LiteralPath Function:\Ninja-Property-Set-Piped
    $script:viaArg = $null; $script:viaPipe = $null; $script:status = ''
    $out = . $block 6>&1 | Out-String
    if ($null -ne $script:viaArg -or $null -ne $script:viaPipe) { Fail "$($c.File): nothing may be written when the piped cmdlet is missing" }
    if ($script:status -notmatch 'WARN\|Could not write to custom field' -or $out -notmatch [regex]::Escape($json)) { Fail "$($c.File): missing-cmdlet path must warn and print the result" }
    Remove-Item -LiteralPath Function:\Ninja-Property-Set
}
Write-Host 'collectors-piped-field: OK'
