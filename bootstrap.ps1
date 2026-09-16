<#
.SYNOPSIS
    Relian Bootstrap Script for NinjaOne
    Downloads and executes collector scripts from a Git repository.

.DESCRIPTION
    This is the ONE script uploaded to NinjaOne. When executed, it:
    1. Reads the git deploy token from NinjaOne org custom field
    2. Downloads the requested script from the Git repository
    3. Executes the script
    4. Reports execution status back via custom fields

.PARAMETER ScriptName
    Required. The relative path of the script to execute (e.g., "collectors/cpu-benchmark")

.PARAMETER RepoUrl
    Optional. Git repository URL. Defaults to the Relian device-scripts repo.

.PARAMETER Branch
    Optional. Git branch to use. Defaults to "main".

.PARAMETER userDataJson
    Optional. Base64-encoded JSON forwarded unchanged to the downloaded script.

.NOTES
    Requirements: Windows PowerShell 5.1+
    Timeout: 5 minutes
    No external module dependencies
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$ScriptName,

    [Parameter(Mandatory = $false)]
    [string]$RepoUrl = "https://github.com/Relianco/device-scripts",

    [Parameter(Mandatory = $false)]
    [string]$Branch = "main",

    [Parameter(Mandatory = $false)]
    [string]$userDataJson
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# Timeout: 5 minutes
$TimeoutSeconds = 300
$StartTime = Get-Date

function Write-Status {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$Level] $timestamp - $Message"
}

function Test-Timeout {
    $elapsed = (Get-Date) - $StartTime
    if ($elapsed.TotalSeconds -ge $TimeoutSeconds) {
        Write-Status "Execution timeout reached ($TimeoutSeconds seconds)" "ERROR"
        exit 1
    }
}

# Validate script path - prevent directory traversal
function Test-ScriptPath {
    param([string]$Path)
    if ($Path -match '\.\.[\\/]' -or $Path -match '^[\\/]' -or $Path -match '[<>"|?*]') {
        Write-Status "Invalid script path: contains directory traversal or invalid characters" "ERROR"
        exit 1
    }
    # Ensure it doesn't start with / or \
    if ($Path.StartsWith('/') -or $Path.StartsWith('\')) {
        Write-Status "Invalid script path: must be relative" "ERROR"
        exit 1
    }
    return $true
}

# Main execution
try {
    Write-Status "Relian Bootstrap v1.0 starting"
    Write-Status "Requested script: $ScriptName"

    # Validate script path
    Test-ScriptPath -Path $ScriptName | Out-Null

    # Ensure .ps1 extension
    $scriptFile = $ScriptName
    if (-not $scriptFile.EndsWith('.ps1')) {
        $scriptFile = "$scriptFile.ps1"
    }

    # Read deploy token from NinjaOne org custom field
    $deployToken = $null
    try {
        $deployToken = Ninja-Property-Get relian_git_deploy_token 2>$null
    } catch {
        Write-Status "No deploy token found in org custom fields (non-critical for public repos)" "WARN"
    }

    # Create temp directory
    $tempDir = Join-Path $env:TEMP "relian_scripts_$(Get-Random)"
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    Write-Status "Temp directory: $tempDir"

    $scriptPath = $null

    try {
        Test-Timeout

        # Try git clone first, fall back to raw URL download
        $gitAvailable = $false
        try {
            $gitVersion = & git --version 2>$null
            if ($LASTEXITCODE -eq 0) {
                $gitAvailable = $true
            }
        } catch {
            $gitAvailable = $false
        }

        if ($gitAvailable) {
            Write-Status "Git available, cloning repository"

            $cloneUrl = $RepoUrl
            if ($deployToken) {
                # Insert token into URL for authentication
                $cloneUrl = $RepoUrl -replace 'https://', "https://x-access-token:$deployToken@"
            }

            $cloneDir = Join-Path $tempDir "repo"
            & git clone --depth 1 --branch $Branch --single-branch $cloneUrl $cloneDir 2>&1 | Out-Null

            if ($LASTEXITCODE -ne 0) {
                Write-Status "Git clone failed, falling back to direct download" "WARN"
                $gitAvailable = $false
            } else {
                $scriptPath = Join-Path $cloneDir $scriptFile
            }
        }

        if (-not $gitAvailable) {
            Write-Status "Downloading script via direct URL"

            # Build raw URL for the specific file
            $rawUrl = "$RepoUrl/raw/$Branch/$scriptFile"

            $downloadPath = Join-Path $tempDir (Split-Path $scriptFile -Leaf)

            $headers = @{}
            if ($deployToken) {
                $headers["Authorization"] = "token $deployToken"
            }

            try {
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                Invoke-WebRequest -Uri $rawUrl -OutFile $downloadPath -Headers $headers -UseBasicParsing
                $scriptPath = $downloadPath
            } catch {
                Write-Status "Failed to download script: $_" "ERROR"
                exit 1
            }
        }

        Test-Timeout

        # Verify script exists
        if (-not $scriptPath -or -not (Test-Path $scriptPath)) {
            Write-Status "Script not found at: $scriptPath" "ERROR"
            exit 1
        }

        Write-Status "Executing: $scriptFile"

        # Execute the script
        $scriptArguments = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath)
        if ($PSBoundParameters.ContainsKey('userDataJson')) {
            $scriptArguments += @('-userDataJson', $userDataJson)
        }
        $scriptOutput = & powershell.exe @scriptArguments 2>&1
        $scriptExitCode = $LASTEXITCODE

        if ($scriptOutput) {
            Write-Host $scriptOutput
        }

        Test-Timeout

        # Write execution metadata to relian_last_collection
        $collectionData = Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ"
        try {
            Ninja-Property-Set relian_last_collection $collectionData
        } catch {
            Write-Status "Could not update relian_last_collection: $_" "WARN"
        }

        if ($scriptExitCode -ne 0) {
            Write-Status "Script exited with code: $scriptExitCode" "ERROR"
            exit $scriptExitCode
        }

        Write-Status "Script completed successfully"

    } finally {
        # Cleanup temp directory
        if (Test-Path $tempDir) {
            Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            Write-Status "Cleaned up temp directory"
        }
    }

} catch {
    Write-Status "Bootstrap error: $_" "ERROR"
    Write-Status $_.ScriptStackTrace "ERROR"
    exit 1
}
