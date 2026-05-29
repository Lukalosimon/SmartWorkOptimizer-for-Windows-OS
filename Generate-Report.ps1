param(
    [string]$BasePath = "C:\SmartWorkOptimizer",
    [int]$DaysBack = 7
)

$ErrorActionPreference = "Stop"

# ---------------------------
# Smooth data
# ---------------------------
function Smooth {
    param($Data)

    if ($Data.Count -lt 3) { return $Data }

    $out = @()

    for ($i=0; $i -lt $Data.Count; $i++) {

        $start = [Math]::Max(0, $i-2)
        $end = [Math]::Min($Data.Count-1, $i+2)

        $subset = $Data[$start..$end]
        $avg = ($subset | Measure-Object -Average).Average

        $out += [math]::Round($avg,2)
    }

    return $out
}

# ---------------------------
# SVG Chart
# ---------------------------
function Build-Chart {
    param($Data, $Title, $Color)

    if ($Data.Count -lt 2) {
        return "<div>No data</div>"
    }

    $w=800
    $h=200
    $pad=20

    $max = ($Data | Measure-Object -Maximum).Maximum
    if ($max -eq 0) { $max = 1 }

    $pts = @()

    for ($i=0; $i -lt $Data.Count; $i++) {

        $x = $pad + (($w-2*$pad) * ($i / ($Data.Count-1)))
        $y = $h - ($pad + (($Data[$i]/$max)*($h-2*$pad)))

        $pts += "$x,$y"
    }

    $poly = $pts -join " "

    return @"
<div>
<h3>$Title</h3>
<svg width="$w" height="$h">
<polyline points="$poly"
style="fill:none;stroke:$Color;stroke-width:3"/>
</svg>
</div>
"@
}

# ---------------------------
# MAIN
# ---------------------------
$logsPath = Join-Path $BasePath "logs"
$reportsPath = Join-Path $BasePath "reports"

if (-not (Test-Path $reportsPath)) {
    New-Item $reportsPath -ItemType Directory | Out-Null
}

# ---------------------------
# UTF8 writer
# ---------------------------
function Write-File {
    param($Path, $Content)

    $enc = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText($Path, $Content, $enc)
}

# ---------------------------
# Read logs
# ---------------------------
function Get-Logs {
    param(
        [Parameter(Mandatory=$true)]
        [string]$LogsPath,
        [int]$DaysBack = 7
    )

    if (-not (Test-Path $LogsPath)) {
        return @()
    }

    $events = @()
    $cutoff = (Get-Date).AddDays(-$DaysBack)

    Get-ChildItem -Path $LogsPath -Filter *.jsonl -File | Where-Object { $_.LastWriteTime -ge $cutoff } | Sort-Object Name | ForEach-Object {
        Get-Content -Path $_.FullName | ForEach-Object {
            if ([string]::IsNullOrWhiteSpace($_)) { return }
            try {
                $obj = $_ | ConvertFrom-Json -ErrorAction Stop
            } catch {
                return
            }
            $events += $obj
        }
    }

    return $events
}

$events = Get-Logs $logsPath

$heartbeats = @(
    $events | Where-Object { $_.message -like "Heartbeat*" -and $_.data }
)

if ($heartbeats.Count -lt 1) {

    $html = "<html><body>No Data Found</body></html>"

    Write-File (Join-Path $reportsPath "dashboard.html") $html
    exit
}

# ---------------------------
# Extract metrics
# ---------------------------
$cpu = @()
$ram = @()
$appCounts = @{}
$appSwitches = 0
$prev = $null

foreach ($h in $heartbeats) {

    $cpu += [double]$h.data.cpuPercent
    $ram += [double]$h.data.freeRamMB

    $app = $h.data.activeApp
    if (-not $app) { $app = "None" }

    if (-not $appCounts.ContainsKey($app)) {
        $appCounts[$app] = 0
    }

    $appCounts[$app]++

    if ($prev -and $prev -ne $app) { $appSwitches++ }
    $prev = $app
}

# smooth
$cpu = Smooth $cpu
$ram = Smooth $ram

# KPIs
$avgCpu = [math]::Round(($cpu | Measure-Object -Average).Average,2)
$maxCpu = [math]::Round(($cpu | Measure-Object -Maximum).Maximum,2)

$avgRam = [math]::Round(($ram | Measure-Object -Average).Average,2)
$minRam = [math]::Round(($ram | Measure-Object -Minimum).Minimum,2)

# top apps
$topApps = $appCounts.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 5

$appRows=""
foreach ($a in $topApps) {
    $appRows += "<tr><td>$($a.Key)</td><td>$($a.Value)</td></tr>"
}

# charts
$cpuChart = Build-Chart $cpu "CPU Trend" "#ef4444"
$ramChart = Build-Chart $ram "RAM Trend" "#22c55e"

# ---------------------------
# HTML
# ---------------------------
$html = @"
<html>
<head>
<title>SmartWorkOptimizer</title>
<style>
body{background:#0f172a;color:white;font-family:Segoe UI}
.card{background:#1e293b;margin:10px;padding:15px;border-radius:10px;display:inline-block}
table{color:white}
</style>
</head>

<body>

<h1>SmartWorkOptimizer Dashboard</h1>

<div class="card">Avg CPU: $avgCpu %</div>
<div class="card">Peak CPU: $maxCpu %</div>
<div class="card">Avg RAM: $avgRam MB</div>
<div class="card">Min RAM: $minRam MB</div>
<div class="card">App Switches: $appSwitches</div>

<br><br>

$cpuChart
$ramChart

<h2>Top Apps</h2>
<table border="1">
<tr><th>App</th><th>Count</th></tr>
$appRows
</table>

</body>
</html>
"@

# save
$out = Join-Path $reportsPath "dashboard.html"
Write-File $out $html

Write-Host "✅ REPORT FIXED AND GENERATED: $out"
 
