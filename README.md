# SmartWorkOptimizer for Windows OS

SmartWorkOptimizer collects lightweight telemetry (heartbeats), monitors the active
application and system metrics, and generates an HTML dashboard report.

## Features
- Collects heartbeat events and active application info
- Generates CPU and RAM trend SVG charts and top-app usage tables
- Smooths time series data for clearer visualization

## Quickstart

Prerequisites:
- PowerShell (Windows PowerShell or PowerShell Core)

Run the report generator from the project root:

```powershell
cd 'C:\SmartWorkOptimizer'
.\Generate-Report.ps1 -BasePath 'C:\SmartWorkOptimizer' -DaysBack 7
```

The dashboard will be written to `reports/dashboard.html`.

## Logs
Logs are newline-delimited JSON files stored in the `logs/` directory. Each
line should be a JSON object representing an event (example files are included
in the `logs/` folder).

## Development
- Main script: `Generate-Report.ps1`
- Helper modules: `modules/`

## Author
Simon Lukalo — lukalosp@gmail.com

---
Feel free to edit this README or add a LICENSE file before publishing.
