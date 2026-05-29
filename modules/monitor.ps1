# SmartWorkOptimizer — Enhanced System Metrics (lightweight + intelligent signals)

Set-StrictMode -Version Latest

function Get-SystemMetrics {

    $cpu = 0
    $disk = 0
    $network = 0
    $freeRamMB = 0
    $topCpuProcess = "Unknown"
    $topCpuValue = 0

    # ✅ CPU usage (system-wide)
    try {
        $cpuSample = Get-Counter '\Processor(_Total)\% Processor Time'
        $cpu = $cpuSample.CounterSamples.CookedValue
    } catch {}

    # ✅ Disk usage
    try {
        $diskSample = Get-Counter '\PhysicalDisk(_Total)\% Disk Time'
        $disk = $diskSample.CounterSamples.CookedValue
    } catch {}

    # ✅ Network usage
    try {
        $netSamples = Get-Counter '\Network Interface(*)\Bytes Total/sec'
        if ($netSamples.CounterSamples) {
            $network = ($netSamples.CounterSamples | Measure-Object -Property CookedValue -Sum).Sum
        }
    } catch {}

    # ✅ Free RAM
    try {
        $os = Get-CimInstance Win32_OperatingSystem
        $freeRamMB = [math]::Round($os.FreePhysicalMemory / 1024, 2)
    } catch {}

    # ✅ Top CPU-consuming process (lightweight)
    try {
        $topProc = Get-Process | Sort-Object CPU -Descending | Select-Object -First 1
        if ($topProc) {
            $topCpuProcess = $topProc.ProcessName
            $topCpuValue = [math]::Round($topProc.CPU, 2)
        }
    } catch {}

    # ✅ Derived system pressure (KEY for your intelligence)
    $isUnderPressure = $false

    if ($cpu -ge 80 -or $freeRamMB -le 800) {
        $isUnderPressure = $true
    }

    # ✅ Return enriched metrics
    return @{
        CPUPercent          = [math]::Round($cpu, 2)
        DiskPercent         = [math]::Round($disk, 2)
        NetworkBytesPerSec  = [math]::Round($network, 2)
        FreeRamMB           = [math]::Round($freeRamMB, 2)

        # 🔥 NEW (intelligence layer)
        TopCPUProcess       = $topCpuProcess
        TopCPUTime          = $topCpuValue
        IsUnderPressure     = $isUnderPressure
    }
}
