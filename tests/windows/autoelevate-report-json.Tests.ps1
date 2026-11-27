$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$env:RELIAN_DEPLOY_TEST = '1'
$path = Join-Path $PSScriptRoot '../../windows/packages/autoelevate/Invoke-AutoElevate.ps1'
. $path
function Assert($ok, $message) { if (-not $ok) { throw "FAIL $message" } }

$script:AutoElevateSecret = [guid]::NewGuid().ToString('n')
$command = 'msiexec /i "C:\Cache\setup.msi" LICENSE_KEY="[redacted]" COMPANY_NAME="Example Company"'
$rawCommand = 'LICENSE_KEY="' + $script:AutoElevateSecret + '" KEEP="value"'
$script:AutoElevateReport = [ordered]@{
    Package='autoelevate'; Status='ok'; MsiCommand=$command
    Nested=[pscustomobject]@{ Message=$rawCommand; Plain=('prefix '+$script:AutoElevateSecret+' suffix'); Count=2; Enabled=$true; Missing=$null }
    Rows=@([ordered]@{ Message='LICENSE_KEY="unknown-key" NEXT="unchanged"' })
    Empty=@(); Single=@('one'); Nulls=@($null, 1)
}
# Execute the real output statement without dispatching the installer entrypoint.
$tokens=$null; $errors=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
Assert ($errors.Count -eq 0) 'package parses'
$outputStatement=$ast.EndBlock.Statements[-2]
$json = & ([scriptblock]::Create($outputStatement.Extent.Text))
try { $parsed = ConvertFrom-Json -InputObject $json -ErrorAction Stop }
catch { throw 'FAIL final package output must remain valid JSON after redaction' }
Assert ($parsed.MsiCommand -ceq $command) 'already-redacted quoted command survives JSON encoding'
Assert ($json -notmatch [regex]::Escape($script:AutoElevateSecret) -and $json -notmatch 'unknown-key') 'known and property-form secrets absent from serialized output'
Assert ($parsed.Nested.Message -ceq 'LICENSE_KEY="[redacted]" KEEP="value"' -and $parsed.Nested.Plain -ceq 'prefix [redacted] suffix') 'nested object strings redacted before encoding'
Assert ($parsed.Rows[0].Message -ceq 'LICENSE_KEY="[redacted]" NEXT="unchanged"') 'dictionary nested in array redacted'
Assert ($parsed.Nested.Count -eq 2 -and $parsed.Nested.Enabled -is [bool] -and $null -eq $parsed.Nested.Missing) 'scalar types preserved'
Assert ($parsed.Empty.Count -eq 0 -and $parsed.Single.Count -eq 1 -and $parsed.Single[0] -ceq 'one' -and $parsed.Nulls.Count -eq 2 -and $null -eq $parsed.Nulls[0]) 'empty/single/null arrays preserved'
Assert ($script:AutoElevateReport.Nested.Message -ceq $rawCommand) 'serialization does not mutate report'
Write-Output 'autoelevate-report-json tests passed'
