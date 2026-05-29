# modules/optimizer.ps1
Set-StrictMode -Version Latest

$script:ManagedProcesses = @{}

function Test-IsProtectedProcess {
    param(
        [string]$ProcessName,
        [object]$Config
    )

    if (-not $ProcessName) { return $true }

    if (-not $Config -or -not $Config.protectedProcesses) { return $false }

    try {
        $protected = $Config.protectedProcesses
        if ($protected -is [string]) { $protected = @($protected) }
        return ($protected | ForEach-Object { $_.ToLower() }) -contains $ProcessName.ToLower()
    } catch {
        return $false
    }
}

function Get-ProcessesByNameSafe {
    param(
        [string]$ProcessName
    )

    try {
        return @(Get-Process -Name $ProcessName -ErrorAction Stop)
    }
    catch {
        return @()
    }
}

function Set-ManagedPriority {
    param(
        [System.Diagnostics.Process]$Process,
        [string]$TargetPriority,
        [string]$Reason,
        [object]$Config
    )

    if (-not $Process) { return }

    $processName = $Process.ProcessName.ToLower()

    # Never touch protected/system/EDR-ish processes (your safety guarantee) [1](https://wioccnet-my.sharepoint.com/personal/simon_lukalo_wiocc_net/Documents/Microsoft%20Teams%20Chat%20Files/PilotPackage.zip?web=1)
    if (Test-IsProtectedProcess -ProcessName $processName -Config $Config) {
        return
    }

    # ⚠️ DO NOT use $pid (automatic variable) — use a different name
    $pidKey = [string]$Process.Id

    $currentPriority = $null
    try {
        $currentPriority = [string]$Process.PriorityClass
    }
    catch {
        return
    }

    if (-not $script:ManagedProcesses.ContainsKey($pidKey)) {
        $script:ManagedProcesses[$pidKey] = @{
            ProcessName           = $processName
            OriginalPriority      = $currentPriority
            CurrentAppliedPriority= $null
            LastReason            = $null
        }
    }

    $alreadyApplied = $script:ManagedProcesses[$pidKey].CurrentAppliedPriority

    # If already in desired state, do nothing (avoids noisy logs)
    if ($currentPriority -eq $TargetPriority -and $alreadyApplied -eq $TargetPriority) {
        return
    }

    if ($Config -and $Config.dryRun) {
        $script:ManagedProcesses[$pidKey].CurrentAppliedPriority = $TargetPriority
        $script:ManagedProcesses[$pidKey].LastReason = $Reason

        Write-OptimizerLog -Level "INFO" -Message "DRY-RUN: Would set $($Process.ProcessName) (PID $($Process.Id)) to $TargetPriority" -Data @{
            process         = $Process.ProcessName
            pid             = $Process.Id
            targetPriority  = $TargetPriority
            currentPriority = $currentPriority
            reason          = $Reason
        } -Config $Config

        return
    }

    try {
        # Windows priority classes influence scheduling under contention (your “resource shifting” primitive) [2](https://learn.microsoft.com/en-us/windows/win32/procthread/scheduling-priorities)
        $Process.PriorityClass = $TargetPriority

        $script:ManagedProcesses[$pidKey].CurrentAppliedPriority = $TargetPriority
        $script:ManagedProcesses[$pidKey].LastReason = $Reason

        Write-OptimizerLog -Level "INFO" -Message "Set $($Process.ProcessName) (PID $($Process.Id)) to $TargetPriority" -Data @{
            process          = $Process.ProcessName
            pid              = $Process.Id
            targetPriority   = $TargetPriority
            originalPriority = $script:ManagedProcesses[$pidKey].OriginalPriority
            reason           = $Reason
        } -Config $Config
    }
    catch {
        Write-OptimizerLog -Level "WARN" -Message "Failed to set priority for $($Process.ProcessName) (PID $($Process.Id))" -Data @{
            process        = $Process.ProcessName
            pid            = $Process.Id
            targetPriority = $TargetPriority
            error          = $_.Exception.Message
        } -Config $Config
    }
}

function Restore-ManagedProcess {
    param(
        [string]$targetPid,
        [object]$Config
    )

    if (-not $script:ManagedProcesses.ContainsKey($targetPid)) {
        return
    }

    $entry    = $script:ManagedProcesses[$targetPid]
    $original = $entry.OriginalPriority

    try {
        $proc = Get-Process -Id ([int]$targetPid) -ErrorAction Stop
    }
    catch {
        $script:ManagedProcesses.Remove($targetPid)
        return
    }

    if ($Config -and $Config.dryRun) {
        Write-OptimizerLog -Level "INFO" -Message "DRY-RUN: Would restore $($proc.ProcessName) (PID $targetPid) to $original" -Data @{
            process         = $proc.ProcessName
            pid             = $targetPid
            restorePriority = $original
        } -Config $Config

        $script:ManagedProcesses.Remove($targetPid)
        return
    }

    try {
        $proc.PriorityClass = $original

        Write-OptimizerLog -Level "INFO" -Message "Restored $($proc.ProcessName) (PID $targetPid) to $original" -Data @{
            process         = $proc.ProcessName
            pid             = $targetPid
            restorePriority = $original
        } -Config $Config
    }
    catch {
        Write-OptimizerLog -Level "WARN" -Message "Failed to restore process (PID $targetPid)" -Data @{
            pid   = $targetPid
            error = $_.Exception.Message
        } -Config $Config
    }
    finally {
        $script:ManagedProcesses.Remove($targetPid)
    }
}

function Restore-AllManagedProcesses {
    param(
        [object]$Config
    )

    $managedPidKeys = @($script:ManagedProcesses.Keys)

    foreach ($managedPid in $managedPidKeys) {
        Restore-ManagedProcess -targetPid $managedPid -Config $Config
    }
}

function Sync-DesiredActions {
    param(
        [array]$DesiredActions,
        [object]$Config
    )

    $desiredPidSet = @{}

    foreach ($action in $DesiredActions) {
        $targetPid = [string]$action.Pid
        $desiredPidSet[$targetPid] = $true

        try {
            $proc = Get-Process -Id ([int]$action.Pid) -ErrorAction Stop
            Set-ManagedPriority -Process $proc -TargetPriority $action.TargetPriority -Reason $action.Reason -Config $Config
        }
        catch {
            Write-OptimizerLog -Level "WARN" -Message "Desired process no longer exists (PID $($action.Pid))" -Data @{
                pid     = $action.Pid
                process = $action.ProcessName
            } -Config $Config
        }
    }

    $currentlyManagedKeys = @($script:ManagedProcesses.Keys)

    foreach ($managedPid in $currentlyManagedKeys) {
        if (-not $desiredPidSet.ContainsKey($managedPid)) {
            Restore-ManagedProcess -targetPid $managedPid -Config $Config
        }
    }
}
