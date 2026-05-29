# Rules engine: group boost + stability + cooldown + safety clamp

Set-StrictMode -Version Latest

function Invoke-OptimizationRules {
    param(
        [object]$ActiveProcess,
        [hashtable]$Metrics,
        [object]$Config
    )

    $actions = New-Object System.Collections.Generic.List[object]

    if (-not $ActiveProcess) {
        return $actions
    }

    # -------------------------------
    # 1) Compatibility layer:
    #    Support both old ActiveProcess shape and new ActiveInfo shape
    # -------------------------------

    # Active name (always available in both versions)
    $activeName = ($ActiveProcess.ProcessName | ForEach-Object { $_.ToString().ToLower() })

    # Determine PID group:
    # - If new version provides .Pids (process group), use it
    # - Else fall back to single PID
    $activePids = @()
    if ($ActiveProcess.PSObject.Properties.Name -contains "Pids" -and $ActiveProcess.Pids) {
        $activePids = @($ActiveProcess.Pids | ForEach-Object { [int]$_ })
    }
    else {
        $activePids = @([int]$ActiveProcess.Id)
    }

    # Focus intelligence:
    # - If new version provides stability/cooldown, honor it
    # - Else assume stable and out of cooldown (old behavior)
    $isStable = $true
    $outOfCooldown = $true

    if ($ActiveProcess.PSObject.Properties.Name -contains "IsStable") {
        $isStable = [bool]$ActiveProcess.IsStable
    }
    if ($ActiveProcess.PSObject.Properties.Name -contains "OutOfCooldown") {
        $outOfCooldown = [bool]$ActiveProcess.OutOfCooldown
    }

    # If focus is not stable OR still in cooldown, do nothing (prevents thrashing)
    if (-not $isStable -or -not $outOfCooldown) {
        return $actions
    }

    # -------------------------------
    # 2) Priority app detection
    # -------------------------------
    $isPriorityApp = $false
    $targetPriority = "Normal"

    if ($Config -and $Config.priorityApps) {
        foreach ($app in $Config.priorityApps.PSObject.Properties) {
            if ($app.Name.ToLower() -eq $activeName) {
                $isPriorityApp = $true
                $targetPriority = [string]$app.Value
                break
            }
        }
    }

    # -------------------------------
    # 3) Pressure signal (your original logic)
    # -------------------------------
    $cpuThreshold = 80
    $minFreeRamMB = 800
    if ($Config -and $Config.thresholds) {
        if ($Config.thresholds.cpuPercent) { $cpuThreshold = [int]$Config.thresholds.cpuPercent }
        if ($Config.thresholds.minFreeRamMB) { $minFreeRamMB = [int]$Config.thresholds.minFreeRamMB }
    }

    $underPressure = ($Metrics.CPUPercent -ge $cpuThreshold) -or
                     ($Metrics.FreeRamMB -le $minFreeRamMB)

    # -------------------------------
    # 4) Safety clamp (prevents accidental over-prioritization)
    #    Windows warns HIGH should be used with care. [2](https://learn.microsoft.com/en-us/windows/win32/procthread/scheduling-priorities)
    # -------------------------------
    $maxBoostPriority = "AboveNormal"  # sane default for enterprise endpoints
    if ($Config -and $Config.focusEngine -and $Config.focusEngine.maxBoostPriority) {
        $maxBoostPriority = [string]$Config.focusEngine.maxBoostPriority
    }

    $order = @("Idle","BelowNormal","Normal","AboveNormal","High")
    if ($order -contains $targetPriority -and $order -contains $maxBoostPriority) {
        if ($order.IndexOf($targetPriority) -gt $order.IndexOf($maxBoostPriority)) {
            $targetPriority = $maxBoostPriority
        }
    }
    else {
        # If config has unexpected value, fall back safely
        $targetPriority = "AboveNormal"
    }

    # -------------------------------
    # 5) Boost active workload group (YOUR UNIQUE IDEA)
    #    Not just one PID: boost active PID + child processes (if provided).
    # -------------------------------
    if ($isPriorityApp -and ((($Config -and $Config.behavior -and $Config.behavior.boostWhenActive) -or $underPressure))) {
        foreach ($targetpid in $activePids) {
            $actions.Add([pscustomobject]@{
                Pid = [int]$targetpid
                ProcessName = $ActiveProcess.ProcessName
                TargetPriority = $targetPriority
                Reason = "Focus-stable active workload boost ($activeName)"
            })
        }
    }

    # -------------------------------
    # 6) Lower background apps (your original behavior, unchanged)
    # -------------------------------
    $shouldLowerBackground = $false

    if ($Config -and $Config.behavior -and $Config.behavior.lowerBackgroundAppsOnlyWhenPriorityAppActive) {
        $shouldLowerBackground = $isPriorityApp
    }
    else {
        $shouldLowerBackground = $true
    }

    if ($shouldLowerBackground -and $Config -and $Config.backgroundApps) {
        foreach ($bg in $Config.backgroundApps.PSObject.Properties) {
            $bgName = $bg.Name.ToLower()

            if ($bgName -eq $activeName) {
                continue
            }

            $procs = Get-ProcessesByNameSafe -ProcessName $bgName

            foreach ($proc in $procs) {
                $actions.Add([pscustomobject]@{
                    Pid = $proc.Id
                    ProcessName = $proc.ProcessName
                    TargetPriority = [string]$bg.Value
                    Reason = "Background deprioritized while $activeName active"
                })
            }
        }
    }

    return $actions
}
