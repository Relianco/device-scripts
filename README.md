# device-scripts
Cross-platform scripts for automated device data collection, hardware benchmarking, and endpoint management. Run via bootstrap or standalone.

## Windows bootstrap

Upload `bootstrap.ps1` once to your RMM and run it as SYSTEM when the target script needs machine privileges. Select scripts with `-ScriptName`, choose the GitHub repository with `-RepoUrl`, and pin tested releases with a full commit hash in `-Branch`.

To pass named parameters, encode a JSON object as UTF-8 base64 and supply `-ParametersBase64`. This selects single-script mode: the path is relative to the repository, parameter values are passed as data, and the child script's exit code is returned. Booleans and arrays retain their types.

```powershell
$parameters = @{ userDataJson = $encodedAdRequest }
$encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(
    ($parameters | ConvertTo-Json -Depth 32 -Compress)
))
.\bootstrap.ps1 -ScriptName 'lab/Edit-ADUser.ps1' `
    -RepoUrl 'https://github.com/Relianco/device-scripts' `
    -Branch '<40-character-tested-commit>' -ParametersBase64 $encoded
```

Use `-ParametersBase64 e30=` for a single script with no parameters. The optional `-userDataJson` argument is shorthand for forwarding that one parameter; do not combine it with `-ParametersBase64`.

Without either parameter argument, bootstrap uses the existing collector mode: profile names from `profiles.json`, comma-separated collector names, checksum verification when a manifest is available, and optional `-CallbackUrl` / `-CallbackToken` reporting. Single-script mode streams output to the RMM without requiring collector JSON output or sending collector callbacks. Both modes enforce the five-minute execution timeout and clean up downloaded files.

Keep the UTF-8 BOM when writing the script to disk for Windows PowerShell 5.1. Parameter payloads can contain sensitive data; do not log the encoded request or save it in reusable RMM presets.

Run local dispatch regressions with `python3 tests/test_bootstrap.py` (requires PowerShell 7). Windows PowerShell 5.1 is also verified on the disposable AD lab before deployment.
