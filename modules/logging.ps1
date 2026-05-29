# modules/logging.ps1
Set-StrictMode -Version Latest

function Initialize-Logging {
    param(
        [string]$BasePath
    )

    $script:LogFolder = Join-Path $BasePath "logs"

    if (-not (Test-Path $script:LogFolder)) {
        New-Item -Path $script:LogFolder -ItemType Directory -Force | Out-Null
    }

    $date = Get-Date -Format 'yyyy-MM-dd'

    $script:TextLogFile = Join-Path $script:LogFolder "$date.log"
    $script:JsonLogFile = Join-Path $script:LogFolder "$date.jsonl"

    # ✅ Session correlation ID (used across lifecycle)
    $script:SessionId = [guid]::NewGuid().ToString()
}

function Write-OptimizerLog {
    param(
        [string]$Level = "INFO",
        [string]$Message,
        [hashtable]$Data = @{},
        [string]$Component = "core",     # ✅ NEW
        [string]$EventType = "general",  # ✅ NEW
        [object]$Config
    )

    $timestamp = (Get-Date).ToString("s")

    # ✅ Per-event correlation ID
    $correlationId = [guid]::NewGuid().ToString()

    # ✅ TEXT LOG (human readable)
    if ($Config -and $Config.logText) {

        $line = "$timestamp [$Level] [$Component] [$EventType] $Message"

        try {
            [System.IO.File]::AppendAllText($script:TextLogFile, $line + "`n")
        } catch { Write-Verbose "Write-OptimizerLog text append failed: $_" }
    }

    # ✅ STRUCTURED JSON LOG (machine readable)
    if ($Config -and $Config.logJson) {

        $payload = [ordered]@{
    timestamp      = $timestamp
    level          = $Level
    component      = $Component
    eventType      = $EventType
    message        = $Message

    sessionId      = $script:SessionId
    correlationId  = $correlationId

    host           = $env:COMPUTERNAME   # ✅ NEW
    processId      = $PID                # ✅ NEW

    data           = $Data
}

        try {
            $json = $payload | ConvertTo-Json -Depth 8 -Compress
            [System.IO.File]::AppendAllText($script:JsonLogFile, $json + "`n")
        } catch { Write-Verbose "Write-OptimizerLog json append failed: $_" }
    }
}
