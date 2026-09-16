<#
.SYNOPSIS
    Relian Bootstrap v2 - RMM-agnostic script loader for Windows.

.DESCRIPTION
    One script uploaded to any RMM. Downloads collector scripts from GitHub,
    verifies integrity via SHA256 checksums, executes them, and reports results
    directly to the Relian platform via an authenticated HTTPS callback.

    RMMs (NinjaOne, SyncroMSP, etc.) serve only as a delivery mechanism.
    Results flow directly to Relian's API - no RMM custom field dependency.

.PARAMETER ScriptName
    Required. Comma-separated collector names or a profile name from profiles.json.
    Examples: "full-audit", "cpu-benchmark,storage-health", "collectors/cpu-benchmark"

.PARAMETER ParametersBase64
    Optional. Base64 UTF-8 JSON object of named parameters. Selects single-script mode:
    ScriptName is a relative script path, and the exact child exit code is returned.
    Values are passed as data, including booleans and arrays; no expression evaluation.
    Use an encoded empty object (e30=) for scripts without parameters.
.PARAMETER userDataJson
    Optional. Legacy shorthand for one named userDataJson parameter. Selects single-script mode.
.PARAMETER CallbackUrl
    Optional. Relian platform callback endpoint URL.

.PARAMETER CallbackToken
    Optional. Hex token for callback authentication.

.PARAMETER RepoUrl
    Optional. Git repository URL. Defaults to the Relian device-scripts repo.

.PARAMETER Branch
    Optional. Git branch to use. Defaults to "main".

.NOTES
    Requirements: Windows PowerShell 5.1+
    Timeout: 5 minutes per collector
    No external module dependencies
    Version: 2.0
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$ScriptName,

    [Parameter(Mandatory = $false)]
    [string]$CallbackUrl = "",

    [Parameter(Mandatory = $false)]
    [string]$CallbackToken = "",

    [Parameter(Mandatory = $false)]
    [string]$RepoUrl = "https://github.com/Relianco/device-scripts",

    [Parameter(Mandatory = $false)]
    [string]$Branch = "main",

    [Parameter(Mandatory = $false)]
    [string]$ParametersBase64,

    [Parameter(Mandatory = $false)]
    [string]$userDataJson
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# Timeout per collector: 5 minutes
$TimeoutSeconds = 300

# Local results directory
$ResultsDir = Join-Path $env:ProgramData "Relian\results"

# ============================================================================
# LOGGING
# ============================================================================

function Write-Status {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$Level] $timestamp - $Message"
}

# ============================================================================
# SECURITY
# ============================================================================

function Test-ScriptPath {
    param([string]$Path)
    if ($Path -match '\.\.' -or $Path -match '^[\\/]' -or $Path -match '[<>"|?*]') {
        Write-Status "Invalid script path: $Path" "ERROR"
        return $false
    }
    return $true
}

# ============================================================================
# RMM AUTO-DETECTION
# ============================================================================

function Get-RmmPlatform {
    # NinjaOne
    try {
        $null = Get-Command Ninja-Property-Get -ErrorAction Stop
        Write-Status "RMM detected: NinjaOne"
        return "ninjaone"
    } catch { }

    # SyncroMSP
    try {
        Import-Module SyncroMSP -ErrorAction Stop
        Write-Status "RMM detected: SyncroMSP"
        return "syncro"
    } catch { }

    Write-Status "No RMM detected - standalone mode"
    return "standalone"
}

function Write-RmmField {
    param([string]$Platform, [string]$FieldName, [string]$Value)
    if ($Platform -eq "ninjaone") {
        try { Ninja-Property-Set $FieldName $Value } catch {
            Write-Status "NinjaOne field write failed ($FieldName): $_" "WARN"
        }
    }
    # Future: SyncroMSP Set-Asset-Field
}

# ============================================================================
# SCRIPT NAME RESOLUTION
# ============================================================================

function Resolve-ScriptNames {
    param([string]$RequestedNames, [hashtable]$Profiles)

    # Check if it's a profile name
    if ($Profiles.ContainsKey($RequestedNames)) {
        $scripts = $Profiles[$RequestedNames]
        Write-Status "Profile '$RequestedNames' resolved to: $($scripts -join ', ')"
        return $scripts
    }

    # Split on commas
    $names = $RequestedNames -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    $resolved = @()

    foreach ($name in $names) {
        # Prepend collectors/ if not already pathed
        if ($name -notmatch '[\\/]') {
            $name = "collectors/$name"
        }
        # Append .ps1 if missing
        if (-not $name.EndsWith('.ps1')) {
            $name = "$name.ps1"
        }
        $resolved += $name
    }

    return $resolved
}

# ============================================================================
# DOWNLOAD HELPERS
# ============================================================================

function Get-RawUrl {
    param([string]$FilePath)
    return "$RepoUrl/raw/$Branch/$FilePath"
}

function Get-FileFromGitHub {
    param([string]$FilePath, [string]$OutPath, [string]$DeployToken)

    $url = Get-RawUrl -FilePath $FilePath
    $headers = @{}
    if ($DeployToken) {
        $headers["Authorization"] = "token $DeployToken"
    }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $url -OutFile $OutPath -Headers $headers -UseBasicParsing
}

# ============================================================================
# CHECKSUM VERIFICATION
# ============================================================================

function Get-ChecksumManifest {
    param([string]$TempDir, [string]$DeployToken)

    $manifestPath = Join-Path $TempDir "checksums.sha256"
    try {
        Get-FileFromGitHub -FilePath "checksums.sha256" -OutPath $manifestPath -DeployToken $DeployToken
    } catch {
        Write-Status "Could not download checksum manifest: $_" "WARN"
        return @{}
    }

    $checksums = @{}
    foreach ($line in (Get-Content $manifestPath)) {
        if ($line -match '^([a-f0-9]{64})\s+(.+)$') {
            $hash = $Matches[1]
            $file = $Matches[2] -replace '^\.\/', ''
            $checksums[$file] = $hash
        }
    }

    Write-Status "Loaded $($checksums.Count) checksums from manifest"
    return $checksums
}

function Test-FileChecksum {
    param([string]$FilePath, [string]$ExpectedHash)

    if (-not $ExpectedHash) {
        Write-Status "No checksum for $(Split-Path $FilePath -Leaf) - skipping verification" "WARN"
        return $true
    }

    $actualHash = (Get-FileHash -Path $FilePath -Algorithm SHA256).Hash.ToLower()
    if ($actualHash -eq $ExpectedHash) {
        Write-Status "Checksum OK: $(Split-Path $FilePath -Leaf)"
        return $true
    }

    Write-Status "Checksum MISMATCH: $(Split-Path $FilePath -Leaf) (expected $ExpectedHash, got $actualHash)" "ERROR"
    return $false
}

# ============================================================================
# REPORTING
# ============================================================================

function Send-CallbackResult {
    param(
        [string]$Collector,
        [string]$JsonData,
        [string]$Hostname
    )

    if (-not $CallbackUrl -or -not $CallbackToken) { return $false }

    $body = @{
        token     = $CallbackToken
        collector = $Collector
        data      = ($JsonData | ConvertFrom-Json)
        hostname  = $Hostname
        timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    } | ConvertTo-Json -Depth 10 -Compress

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $response = Invoke-WebRequest -Uri $CallbackUrl -Method POST `
            -ContentType "application/json" -Body $body -UseBasicParsing

        if ($response.StatusCode -eq 200) {
            Write-Status "Callback POST success for $Collector"
            return $true
        }
        Write-Status "Callback POST returned status $($response.StatusCode)" "WARN"
        return $false
    } catch {
        Write-Status "Callback POST failed for $Collector`: $_" "ERROR"
        return $false
    }
}

function Save-LocalResult {
    param([string]$Collector, [string]$JsonData)

    if (-not (Test-Path $ResultsDir)) {
        New-Item -ItemType Directory -Path $ResultsDir -Force | Out-Null
    }

    $dateStr = Get-Date -Format "yyyy-MM-dd"
    $fileName = "$Collector-$dateStr.json"
    $filePath = Join-Path $ResultsDir $fileName

    Set-Content -Path $filePath -Value $JsonData -Encoding UTF8
    Write-Status "Local result saved: $filePath"
}

function Invoke-ParameterizedScript {
    param([string]$TempDir, [string]$DeployToken, [hashtable]$Parameters)
    if ($ScriptName -notmatch '^(?!.*(?:^|/)\.\.?(?:/|$))[a-zA-Z0-9_.-]+(?:/[a-zA-Z0-9_.-]+)*$') { throw 'Invalid script path' }
    $scriptFile = $ScriptName
    if (-not $scriptFile.EndsWith('.ps1')) { $scriptFile += '.ps1' }
    $localPath = Join-Path $TempDir 'target.ps1'
    Get-FileFromGitHub -FilePath $scriptFile -OutPath $localPath -DeployToken $DeployToken
    $checksums = Get-ChecksumManifest -TempDir $TempDir -DeployToken $DeployToken
    if (-not (Test-FileChecksum -FilePath $localPath -ExpectedHash $checksums[$scriptFile])) { throw 'Script checksum mismatch' }

    $requestPath = Join-Path $TempDir 'request.json'
    @{ scriptPath = $localPath; parameters = $Parameters } | ConvertTo-Json -Depth 32 | Set-Content -Path $requestPath -Encoding UTF8
    $runnerPath = Join-Path $TempDir 'invoke.ps1'
    @'
param([string]$RequestPath)
$ErrorActionPreference = 'Stop'
try {
    $request = Get-Content -LiteralPath $RequestPath -Raw | ConvertFrom-Json
    $parameters = @{}
    foreach ($property in $request.parameters.PSObject.Properties) { $parameters[$property.Name] = $property.Value }
    $global:LASTEXITCODE = 0
    & $request.scriptPath @parameters
    exit $global:LASTEXITCODE
} catch {
    Write-Error $_ -ErrorAction Continue
    exit 1
}
'@ | Set-Content -Path $runnerPath -Encoding UTF8

    $job = Start-Job -ScriptBlock {
        param($RunnerPath, $RequestPath)
        $output = @(& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $RunnerPath -RequestPath $RequestPath 2>&1 | ForEach-Object { "$_" })
        [pscustomobject]@{ Output = $output; ExitCode = $LASTEXITCODE }
    } -ArgumentList $runnerPath, $requestPath
    try {
        $completed = $job | Wait-Job -Timeout $TimeoutSeconds
        if (-not $completed -or $job.State -ne 'Completed') { throw 'Script timed out or execution job failed' }
        $result = Receive-Job -Job $job -ErrorAction Stop
        if ($null -eq $result -or $null -eq $result.ExitCode) { throw 'Script returned no exit status' }
        foreach ($line in $result.Output) { Write-Host $line }
        return [int]$result.ExitCode
    } finally {
        if ($job.State -eq 'Running') { Stop-Job -Job $job -ErrorAction SilentlyContinue }
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    }
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

try {
    Write-Status "Relian Bootstrap v2.0 starting"
    Write-Status "ScriptName: $ScriptName"
    if ($CallbackUrl) { Write-Status "Callback: $CallbackUrl" }

    $scriptParameters = $null
    if ($PSBoundParameters.ContainsKey('ParametersBase64')) {
        if ($PSBoundParameters.ContainsKey('userDataJson')) { throw 'Use ParametersBase64 or userDataJson, not both' }
        $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($ParametersBase64))
        $parsed = ConvertFrom-Json -InputObject $json -ErrorAction Stop
        if ($null -eq $parsed -or -not $json.TrimStart().StartsWith('{') -or $parsed -isnot [pscustomobject]) { throw 'ParametersBase64 must be a JSON object' }
        $scriptParameters = @{}
        foreach ($property in $parsed.PSObject.Properties) {
            if ($property.Name -notmatch '^[a-zA-Z][a-zA-Z0-9_]*$') { throw 'Invalid script parameter name' }
            $scriptParameters[$property.Name] = $property.Value
        }
    } elseif ($PSBoundParameters.ContainsKey('userDataJson')) {
        $scriptParameters = @{ userDataJson = $userDataJson }
    }

    $hostname = $env:COMPUTERNAME

    # Detect RMM platform
    $rmmPlatform = Get-RmmPlatform

    # Read deploy token from RMM if available
    $deployToken = $null
    if ($rmmPlatform -eq "ninjaone") {
        try { $deployToken = Ninja-Property-Get relian_git_deploy_token 2>$null } catch { }
    }

    # Create temp directory
    $tempDir = Join-Path $env:TEMP "relian_bootstrap_$(Get-Random)"
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

    try {
        if ($null -ne $scriptParameters) {
            $scriptExitCode = Invoke-ParameterizedScript -TempDir $tempDir -DeployToken $deployToken -Parameters $scriptParameters
            exit $scriptExitCode
        }

        # Download profiles.json
        $profiles = @{}
        try {
            $profilesPath = Join-Path $tempDir "profiles.json"
            Get-FileFromGitHub -FilePath "profiles.json" -OutPath $profilesPath -DeployToken $deployToken
            $profilesRaw = Get-Content $profilesPath -Raw | ConvertFrom-Json
            # Convert PSObject to hashtable
            foreach ($prop in $profilesRaw.PSObject.Properties) {
                $profiles[$prop.Name] = @($prop.Value)
            }
            Write-Status "Loaded $($profiles.Count) profiles"
        } catch {
            Write-Status "Could not load profiles.json: $_" "WARN"
        }

        # Resolve script names
        $scriptFiles = Resolve-ScriptNames -RequestedNames $ScriptName -Profiles $profiles

        if ($scriptFiles.Count -eq 0) {
            Write-Status "No scripts resolved from: $ScriptName" "ERROR"
            exit 1
        }

        Write-Status "Resolved $($scriptFiles.Count) collector(s): $($scriptFiles -join ', ')"

        # Download checksum manifest
        $checksums = Get-ChecksumManifest -TempDir $tempDir -DeployToken $deployToken

        # Track results
        $summary = @()

        # Execute each collector
        foreach ($scriptFile in $scriptFiles) {
            $collectorStart = Get-Date
            $collectorName = [System.IO.Path]::GetFileNameWithoutExtension(($scriptFile -split '[\\/]')[-1])

            Write-Status "--- Collector: $collectorName ---"

            # Validate path
            if (-not (Test-ScriptPath -Path $scriptFile)) {
                $summary += @{ collector = $collectorName; status = "skipped"; reason = "invalid path" }
                continue
            }

            # Download collector script
            $localPath = Join-Path $tempDir (Split-Path $scriptFile -Leaf)
            try {
                Get-FileFromGitHub -FilePath $scriptFile -OutPath $localPath -DeployToken $deployToken
            } catch {
                Write-Status "Failed to download $scriptFile`: $_" "ERROR"
                $summary += @{ collector = $collectorName; status = "failed"; reason = "download error" }
                continue
            }

            # Verify checksum (skip on mismatch, don't abort)
            $expectedHash = $checksums[$scriptFile]
            if (-not (Test-FileChecksum -FilePath $localPath -ExpectedHash $expectedHash)) {
                Write-Status "Skipping $collectorName due to checksum mismatch" "WARN"
                $summary += @{ collector = $collectorName; status = "skipped"; reason = "checksum mismatch" }
                continue
            }

            # Execute with timeout
            Write-Status "Executing: $collectorName"
            $collectorOutput = $null
            $exitCode = 0

            try {
                $job = Start-Job -ScriptBlock {
                    param($Path)
                    $output = @(& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Path 2>&1 | ForEach-Object { "$_" })
                    [pscustomobject]@{ Output = $output; ExitCode = $LASTEXITCODE }
                } -ArgumentList $localPath

                $completed = $job | Wait-Job -Timeout $TimeoutSeconds
                if (-not $completed -or $job.State -eq 'Running') {
                    Stop-Job -Job $job -ErrorAction SilentlyContinue
                    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
                    Write-Status "$collectorName timed out after ${TimeoutSeconds}s" "ERROR"
                    $summary += @{ collector = $collectorName; status = "failed"; reason = "timeout" }
                    continue
                }

                $result = Receive-Job -Job $job -ErrorAction Stop
                if ($null -eq $result -or $null -eq $result.ExitCode) { throw 'Collector returned no exit status' }
                $collectorOutput = $result.Output
                $exitCode = [int]$result.ExitCode
                Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
            } catch {
                Write-Status "Execution error for $collectorName`: $_" "ERROR"
                $summary += @{ collector = $collectorName; status = "failed"; reason = "execution error: $_" }
                continue
            }

            if ($exitCode -ne 0) {
                $summary += @{ collector = $collectorName; status = "failed"; reason = "exit code $exitCode" }
                continue
            }

            $elapsed = [math]::Round(((Get-Date) - $collectorStart).TotalSeconds, 1)

            # Extract JSON from output (last line that looks like JSON)
            $jsonResult = $null
            $outputLines = @($collectorOutput | Where-Object { $_ -is [string] })
            for ($i = $outputLines.Count - 1; $i -ge 0; $i--) {
                if ($outputLines[$i] -match '^\s*\{') {
                    $jsonResult = $outputLines[$i]
                    break
                }
            }

            if (-not $jsonResult) {
                Write-Status "No JSON output from $collectorName" "ERROR"
                $summary += @{ collector = $collectorName; status = "failed"; reason = "no JSON output"; durationSec = $elapsed }
                continue
            }

            # Validate JSON
            try {
                $null = $jsonResult | ConvertFrom-Json
            } catch {
                Write-Status "Invalid JSON from $collectorName" "ERROR"
                $summary += @{ collector = $collectorName; status = "failed"; reason = "invalid JSON"; durationSec = $elapsed }
                continue
            }

            Write-Status "$collectorName completed in ${elapsed}s"

            # Report results (all channels, failures don't block each other)

            # 1. HTTPS callback (primary)
            $callbackSent = Send-CallbackResult -Collector $collectorName -JsonData $jsonResult -Hostname $hostname

            # 2. RMM custom field (optional fallback)
            $rmmFieldName = "relian_$($collectorName -replace '-', '_')"
            Write-RmmField -Platform $rmmPlatform -FieldName $rmmFieldName -Value $jsonResult

            # 3. Local file (always)
            Save-LocalResult -Collector $collectorName -JsonData $jsonResult

            $summary += @{
                collector   = $collectorName
                status      = "success"
                durationSec = $elapsed
                callback    = $callbackSent
            }
        }

        # Update RMM last collection timestamp
        Write-RmmField -Platform $rmmPlatform -FieldName "relian_last_collection" -Value (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")

        # Write execution summary
        Write-Status "=== Execution Summary ==="
        foreach ($entry in $summary) {
            $statusIcon = if ($entry.status -eq "success") { "OK" } else { "FAIL" }
            $detail = if ($entry.reason) { " ($($entry.reason))" } else { "" }
            $duration = if ($entry.durationSec) { " [${($entry.durationSec)}s]" } else { "" }
            Write-Status "  [$statusIcon] $($entry.collector)$detail$duration"
        }

        $failed = @($summary | Where-Object { $_.status -ne "success" })
        if ($failed.Count -gt 0) {
            Write-Status "$($failed.Count)/$($summary.Count) collectors failed" "WARN"
            exit 1
        }

        Write-Status "All $($summary.Count) collectors completed successfully"

    } finally {
        # Cleanup
        if (Test-Path $tempDir) {
            Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

} catch {
    Write-Status "Bootstrap error: $_" "ERROR"
    Write-Status $_.ScriptStackTrace "ERROR"
    exit 1
}
