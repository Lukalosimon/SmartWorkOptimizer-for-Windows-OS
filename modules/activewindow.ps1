# modules/activewindow.ps1
# SmartWorkOptimizer — Focus-aware Active Window Detector (Stable + Cooldown + Process Group)
Set-StrictMode -Version Latest

# Load Win32 API safely (only once)
if (-not ("Win32Foreground" -as [type])) {
    try {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public class Win32Foreground {
    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern int GetWindowThreadProcessId(IntPtr hWnd, out int lpdwProcessId);
}
'@ -ErrorAction Stop
    } catch {
        Write-Verbose "Add-Type failed for Win32Foreground: $_"
    }
}

# --- Focus state (this is what makes it "intelligent") ---
# We keep these in script scope so they persist across loop iterations.
$script:LastForegroundPid     = $null
$script:LastFocusChangeTime   = Get-Date
$script:LastAppliedTime       = Get-Date "2000-01-01"

function Get-ProcessTreePids {
    param([int]$RootPid)

    # Build a parent->children map using CIM (safe + no invasive hooks)
    try {
        $procs = Get-CimInstance Win32_Process | Select-Object ProcessId, ParentProcessId
    } catch {
        return @($RootPid)
    }

    $childrenMap = @{}
    foreach ($p in $procs) {
        $ppid = [int]$p.ParentProcessId
        if (-not $childrenMap.ContainsKey($ppid)) { $childrenMap[$ppid] = @() }
        $childrenMap[$ppid] += [int]$p.ProcessId
    }

    $stack = New-Object System.Collections.Generic.Stack[int]
    $stack.Push($RootPid)

    $seen = New-Object 'System.Collections.Generic.HashSet[int]'
    [void]$seen.Add($RootPid)

    while ($stack.Count -gt 0) {
        $cur = $stack.Pop()
        if ($childrenMap.ContainsKey($cur)) {
            foreach ($c in $childrenMap[$cur]) {
                if ($seen.Add($c)) { $stack.Push($c) }
            }
        }
    }

    return $seen.ToArray()
}

function Get-ActiveProcessInfo {
    param(
        # Optional config input so we can use focusEngine settings when present
        [object]$Config = $null
    )

# PSScriptAnalyzer disable=PSPossibleIncorrectComparisonWithNull

    try {
        # 1) Get active window handle
        $hwnd = [Win32Foreground]::GetForegroundWindow()
        if ([System.IntPtr]::Zero -eq $hwnd) { return $null }

        # 2) Get PID of the active window
        $processId = 0
        [Win32Foreground]::GetWindowThreadProcessId($hwnd, [ref]$processId) | Out-Null
        if ($processId -le 0) { return $null }

        # 3) Load process
        $proc = Get-Process -Id $processId -ErrorAction Stop

        # 4) Pull focusEngine settings (with safe defaults if config is missing)
        [int]$stabilitySeconds = 2
        [int]$cooldownSeconds  = 3
        [bool]$boostTree       = $true

        if ($Config -and $Config.focusEngine) {
            $fe = $Config.focusEngine

            # stabilitySeconds: validate numeric and non-negative
            if ($fe.PSObject.Properties.Match('stabilitySeconds').Count -gt 0) {
                $raw = $fe.stabilitySeconds
                $parsed = 0
                if ([int]::TryParse([string]$raw, [ref]$parsed) -and $parsed -ge 0) {
                    $stabilitySeconds = $parsed
                }
            }

            # cooldownSeconds: validate numeric and non-negative
            if ($fe.PSObject.Properties.Match('cooldownSeconds').Count -gt 0) {
                $raw = $fe.cooldownSeconds
                $parsed = 0
                if ([int]::TryParse([string]$raw, [ref]$parsed) -and $parsed -ge 0) {
                    $cooldownSeconds = $parsed
                }
            }

            # boostWholeProcessTree: coerce to boolean safely
            if ($fe.PSObject.Properties.Match('boostWholeProcessTree').Count -gt 0) {
                $raw = $fe.boostWholeProcessTree
                $boolVal = $null
                try {
                    if ($raw -is [bool]) { $boolVal = $raw }
                    else {
                        $parsedInt = 0
                        if ([int]::TryParse([string]$raw, [ref]$parsedInt)) {
                            $boolVal = ($parsedInt -ne 0)
                        }
                        else {
                            $parsedBool = $false
                            if ([System.Boolean]::TryParse([string]$raw, [ref]$parsedBool)) {
                                $boolVal = $parsedBool
                            }
                            else {
                                $boolVal = [bool]$raw
                            }
                        }
                    }
                } catch { $boolVal = $true }

                if ($null -ne $boolVal) { $boostTree = [bool]$boolVal }
            }
        }

        # 5) Track focus changes to measure stability
        $now = Get-Date
        if ([int]$proc.Id -ne $script:LastForegroundPid) {
            $script:LastForegroundPid   = [int]$proc.Id
            $script:LastFocusChangeTime = $now
        }

        $focusAgeSeconds = [math]::Round(($now - $script:LastFocusChangeTime).TotalSeconds, 2)
        $sinceApplied    = [math]::Round(($now - $script:LastAppliedTime).TotalSeconds, 2)

        $isStable = ($focusAgeSeconds -ge $stabilitySeconds)
        $outOfCooldown = ($sinceApplied -ge $cooldownSeconds)

        $cooldownRemaining = 0
        if (-not $outOfCooldown) {
            $cooldownRemaining = [math]::Round(($cooldownSeconds - $sinceApplied), 2)
            if ($cooldownRemaining -lt 0) { $cooldownRemaining = 0 }
        }

        # 6) Build PID group (active PID + its children) if enabled
        $pids = @([int]$proc.Id)
        if ($boostTree) {
            $pids = Get-ProcessTreePids -RootPid ([int]$proc.Id)
        }

        # 7) Return object (KEEP your original fields + add new ones)
        return [pscustomobject]@{
            # ORIGINAL fields (unchanged)
            Id          = $proc.Id
            ProcessName = $proc.ProcessName.ToLower()
            Name        = $proc.ProcessName

            # NEW fields (for "intelligent" engine)
            Pids                 = $pids
            IsStable             = $isStable
            OutOfCooldown        = $outOfCooldown
            FocusAgeSeconds      = $focusAgeSeconds
            CooldownRemainingSec = $cooldownRemaining

            # Call this AFTER you apply optimization so cooldown starts
            MarkApplied = {
                $script:LastAppliedTime = Get-Date
            }
        }
    }
    catch {
        return $null
    }
}

# PSScriptAnalyzer enable=PSPossibleIncorrectComparisonWithNull
