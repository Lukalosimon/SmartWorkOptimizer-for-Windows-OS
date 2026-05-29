Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Prevent duplicate instances
$mutexName = "Global\SmartWorkOptimizerMutex"
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$createdNew)

if (-not $createdNew) {
    Write-Host "SmartWorkOptimizer is already running."
    exit
}

try {
    # Load modules
    . "$PSScriptRoot\modules\logging.ps1"
    . "$PSScriptRoot\modules\monitor.ps1"
    . "$PSScriptRoot\modules\activewindow.ps1"
    . "$PSScriptRoot\modules\optimizer.ps1"
    . "$PSScriptRoot\modules\rules.ps1"

    # Load config
    $config = Get-Content "$PSScriptRoot\config.json" -Raw | ConvertFrom-Json

    # Initialize logging
    Initialize-Logging -BasePath $PSScriptRoot

    Write-OptimizerLog -Level "INFO" -Message "SmartWorkOptimizer started" -Data @{
        dryRun = $config.dryRun
        scanIntervalSeconds = $config.scanIntervalSeconds
    } -Config $config

    while ($true) {
        try {
            # ✅ Get metrics (enhanced monitor metrics supported)
            $metrics = Get-SystemMetrics

            # ✅ Get active process info WITH CONFIG (enables stability/cooldown + PID group)
            $active = Get-ActiveProcessInfo -Config $config

            # ✅ Safe active app handling
            $activeName = if ($active) { $active.ProcessName } else { "None" }

            # ✅ Extra focus intelligence fields (only exist if using new activewindow.ps1)
            $isStable = if ($active -and ($active.PSObject.Properties.Name -contains "IsStable")) { [bool]$active.IsStable } else { $true }
            $outOfCooldown = if ($active -and ($active.PSObject.Properties.Name -contains "OutOfCooldown")) { [bool]$active.OutOfCooldown } else { $true }
            $focusAge = if ($active -and ($active.PSObject.Properties.Name -contains "FocusAgeSeconds")) { [double]$active.FocusAgeSeconds } else { 0 }
            $cooldownLeft = if ($active -and ($active.PSObject.Properties.Name -contains "CooldownRemainingSec")) { [double]$active.CooldownRemainingSec } else { 0 }

            # ✅ LIVE CONSOLE OUTPUT (includes focus stability signals)
            Write-Host ("Active: {0} | CPU: {1}% | RAM: {2}MB | Stable: {3} | CooldownOK: {4}" -f `
                $activeName, $metrics.CPUPercent, $metrics.FreeRamMB, $isStable, $outOfCooldown)

            # ✅ Logging (heartbeat stays compatible with your report engine)
            Write-OptimizerLog -Level "INFO" -Message "Heartbeat + Metrics" -Data @{
                activeApp          = $activeName
                activePid          = if ($active) { $active.Id } else { $null }

                # Focus intelligence telemetry (doesn't break older reports)
                focusStable        = $isStable
                focusAgeSeconds    = $focusAge
                cooldownOK         = $outOfCooldown
                cooldownRemaining  = $cooldownLeft
                activeGroupCount   = if ($active -and ($active.PSObject.Properties.Name -contains "Pids") -and $active.Pids) { @($active.Pids).Count } else { 1 }

                cpuPercent         = $metrics.CPUPercent
                freeRamMB          = $metrics.FreeRamMB
                diskPercent        = $metrics.DiskPercent
                networkBytesPerSec = $metrics.NetworkBytesPerSec

                # Enhanced monitor fields (if present)
                topCpuProcess      = if ($metrics.ContainsKey("TopCPUProcess")) { $metrics.TopCPUProcess } else { $null }
                topCpuTime         = if ($metrics.ContainsKey("TopCPUTime")) { $metrics.TopCPUTime } else { $null }
                isUnderPressure    = if ($metrics.ContainsKey("IsUnderPressure")) { $metrics.IsUnderPressure } else { $null }

            } -Config $config

            # ✅ FAILSAFE CHECK (unchanged)
            $failsafeTriggered = $false

            if ($metrics.CPUPercent -ge $config.failsafe.cpuPercent) {
                $failsafeTriggered = $true
                Write-OptimizerLog -Level "WARN" -Message "Failsafe triggered: CPU too high" -Data @{
                    cpuPercent = $metrics.CPUPercent
                    threshold  = $config.failsafe.cpuPercent
                } -Config $config
            }

            if ($metrics.FreeRamMB -le $config.failsafe.minFreeRamMB) {
                $failsafeTriggered = $true
                Write-OptimizerLog -Level "WARN" -Message "Failsafe triggered: RAM too low" -Data @{
                    freeRamMB  = $metrics.FreeRamMB
                    threshold  = $config.failsafe.minFreeRamMB
                } -Config $config
            }

            # ✅ If failsafe triggers → restore everything (unchanged safety behavior)
            if ($failsafeTriggered) {
                Restore-AllManagedProcesses -Config $config
                Start-Sleep -Seconds $config.scanIntervalSeconds
                continue
            }

            # ✅ Apply rules
$desiredActions = Invoke-OptimizationRules `
    -ActiveProcess $active `
    -Metrics $metrics `
    -Config $config

# ✅ Apply changes safely
Sync-DesiredActions -DesiredActions $desiredActions -Config $config

# ✅ Start cooldown safely
if ($active -and $desiredActions -and @($desiredActions).Count -gt 0) {
    if ($active.PSObject.Properties.Name -contains "MarkApplied" -and $active.MarkApplied) {
        & $active.MarkApplied
    }
}
        }
        
        catch {
            Write-OptimizerLog -Level "ERROR" -Message "Main loop error" -Data @{
                error = $_.Exception.Message
            } -Config $config
        }

        Start-Sleep -Seconds $config.scanIntervalSeconds
    }
}
finally {
    try {
        if ($config -and $config.behavior.restoreOnExit) {
            Restore-AllManagedProcesses -Config $config
        }
    } catch {}

    if ($mutex) {
        $mutex.ReleaseMutex() | Out-Null
        $mutex.Dispose()
    }
}
