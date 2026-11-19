# Intune runs this file with no arguments, as SYSTEM, in 64-bit PowerShell.
# Detected once Invoke-NinjaReset.ps1 -Apply true has finished a reset and written its marker, so the reset runs
# once per device. Delete the marker to run it again.
$marker = Join-Path $env:ProgramData 'Relian\ninja-reset\done.txt'
if (Test-Path -LiteralPath $marker) {
    Write-Output 'Relian Ninja reset done'
    exit 0
}
exit 1
