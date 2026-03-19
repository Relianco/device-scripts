<#
.SYNOPSIS
    Relian CPU Benchmark Collector
    Runs lightweight CPU benchmarks and writes results to NinjaOne custom fields.

.DESCRIPTION
    Performs single-threaded and multi-threaded CPU benchmarks using a prime sieve.
    Normalizes scores to approximate Passmark scale.
    Writes JSON results to the relian_cpu_benchmark NinjaOne custom field.

.NOTES
    Requirements: Windows PowerShell 5.1+
    Duration: ~20 seconds total
    Impact: Minimal — CPU spikes are brief (<10s per test)
    Version: 1.0
#>

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Write-Status {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$Level] $timestamp - $Message"
}

# Prime sieve benchmark — compute-bound, deterministic workload
function Invoke-PrimeSieve {
    param([int]$Limit = 100000)

    $sieve = New-Object bool[] ($Limit + 1)
    for ($i = 2; $i * $i -le $Limit; $i++) {
        if (-not $sieve[$i]) {
            for ($j = $i * $i; $j -le $Limit; $j += $i) {
                $sieve[$j] = $true
            }
        }
    }

    $count = 0
    for ($i = 2; $i -le $Limit; $i++) {
        if (-not $sieve[$i]) { $count++ }
    }
    return $count
}

# Single-threaded benchmark
function Get-SingleThreadScore {
    Write-Status "Running single-thread benchmark..."

    $iterations = 0
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $targetMs = 8000  # 8 seconds

    while ($sw.ElapsedMilliseconds -lt $targetMs) {
        Invoke-PrimeSieve -Limit 100000 | Out-Null
        $iterations++
    }

    $sw.Stop()
    $elapsed = $sw.Elapsed.TotalSeconds

    # Calibration: i7-10700K @ 3.8GHz does ~45 iterations in 8s
    # Passmark single-thread for i7-10700K is ~2820
    $scaleFactor = 2820.0 / 45.0
    $score = [math]::Round($iterations * $scaleFactor)

    Write-Status "Single-thread: $iterations iterations in $([math]::Round($elapsed, 1))s = score $score"
    return $score
}

# Multi-threaded benchmark
function Get-MultiThreadScore {
    param([int]$ThreadCount)

    Write-Status "Running multi-thread benchmark ($ThreadCount threads)..."

    $targetMs = 8000  # 8 seconds
    $scriptBlock = {
        param($Limit, $TargetMs)

        $sieveFunc = {
            param([int]$L)
            $s = New-Object bool[] ($L + 1)
            for ($i = 2; $i * $i -le $L; $i++) {
                if (-not $s[$i]) {
                    for ($j = $i * $i; $j -le $L; $j += $i) {
                        $s[$j] = $true
                    }
                }
            }
            $c = 0
            for ($i = 2; $i -le $L; $i++) {
                if (-not $s[$i]) { $c++ }
            }
            return $c
        }

        $iters = 0
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while ($sw.ElapsedMilliseconds -lt $TargetMs) {
            & $sieveFunc $Limit | Out-Null
            $iters++
        }
        $sw.Stop()
        return $iters
    }

    # Start parallel jobs
    $jobs = @()
    for ($t = 0; $t -lt $ThreadCount; $t++) {
        $jobs += Start-Job -ScriptBlock $scriptBlock -ArgumentList 100000, $targetMs
    }

    # Wait for all jobs (timeout 30s)
    $jobs | Wait-Job -Timeout 30 | Out-Null

    $totalIterations = 0
    foreach ($job in $jobs) {
        if ($job.State -eq 'Completed') {
            $result = Receive-Job -Job $job
            if ($result -is [int]) {
                $totalIterations += $result
            }
        }
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    }

    # Calibration: i7-10700K (8C/16T) does ~45*16 = ~720 total iterations
    # Passmark multi-thread for i7-10700K is ~18200
    $scaleFactor = 18200.0 / 720.0
    $score = [math]::Round($totalIterations * $scaleFactor)

    Write-Status "Multi-thread: $totalIterations total iterations across $ThreadCount threads = score $score"
    return $score
}

# Collect CPU info
function Get-CpuInfo {
    $cpu = Get-CimInstance -ClassName Win32_Processor | Select-Object -First 1

    return @{
        cpuModel     = ($cpu.Name -replace '\s+', ' ').Trim()
        cores        = [int]$cpu.NumberOfCores
        threads      = [int]$cpu.NumberOfLogicalProcessors
        baseClock    = [int]$cpu.MaxClockSpeed
        maxClock     = [int]$cpu.MaxClockSpeed
        architecture = $env:PROCESSOR_ARCHITECTURE
    }
}

# Main
try {
    Write-Status "Relian CPU Benchmark v1.0 starting"

    # Gather CPU info
    $cpuInfo = Get-CpuInfo
    Write-Status "CPU: $($cpuInfo.cpuModel) ($($cpuInfo.cores)C/$($cpuInfo.threads)T)"

    # Run benchmarks
    $singleScore = Get-SingleThreadScore
    $multiScore = Get-MultiThreadScore -ThreadCount $cpuInfo.threads

    # Build result JSON
    $result = @{
        singleThread = $singleScore
        multiThread  = $multiScore
        cpuModel     = $cpuInfo.cpuModel
        cores        = $cpuInfo.cores
        threads      = $cpuInfo.threads
        baseClock    = $cpuInfo.baseClock
        maxClock     = $cpuInfo.maxClock
        architecture = $cpuInfo.architecture
        timestamp    = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        version      = "1.0"
    }

    $json = $result | ConvertTo-Json -Compress
    Write-Status "Results: $json"

    # Write to NinjaOne custom field
    try {
        Ninja-Property-Set relian_cpu_benchmark $json
        Write-Status "Benchmark results written to relian_cpu_benchmark custom field"
    } catch {
        Write-Status "Could not write to custom field: $_" "WARN"
        # Still output the JSON so it can be captured from stdout
        Write-Host "BENCHMARK_RESULT:$json"
    }

    Write-Status "CPU benchmark complete"

} catch {
    Write-Status "Benchmark error: $_" "ERROR"
    Write-Status $_.ScriptStackTrace "ERROR"
    exit 1
}
