# Copilot Instructions

## Project Purpose

PowerPerf is a PowerShell script that automatically switches the Windows power plan between **Balanced** and **Best Performance** based on current CPU clock speed. It serves as a workaround for CPU throttling on systems where the power plan alone doesn't prevent it.

## Architecture

The core logic follows a polling loop:

1. Read the current CPU effective speed via `Get-Counter '\Processor Information(_Total)\% Processor Performance'` × max MHz
2. Compare against a configurable threshold (default 1 GHz)
3. If below threshold **and on AC power**, toggle the Windows 11 Power Mode overlay (Balanced → BestPerformance) to re-trigger CPU boost
4. Sleep for the polling interval, then repeat

**Windows 11 Power Mode** (Settings → Power & battery) is controlled via `PowerSetActiveOverlayScheme` / `PowerGetEffectiveOverlayScheme` in `powrprof.dll` — **not** via `powercfg /setactive`. No elevation is required for the overlay API.

Overlay GUIDs:
- **BestPowerEfficiency**: `961cc777-2710-4466-a890-bac6b5f13734`
- **Balanced**: `00000000-0000-0000-0000-000000000000`
- **BestPerformance**: `ded574b5-45a0-4f42-8737-46345c09c238`

## Key Conventions

- Use `Get-CimInstance Win32_Processor` (preferred over the deprecated `Get-WmiObject`)
- CPU speed is read from `CurrentClockSpeed` (in MHz) for the base value; effective speed uses the `% Processor Performance` counter
- All threshold values and polling intervals are defined as parameters — never hardcoded inline
- Use P/Invoke (`Add-Type`) to call `powrprof.dll` for Power Mode; avoid `powercfg` for mode switching
- Guard `Add-Type` with `if (-not ([System.Management.Automation.PSTypeName]'TypeName').Type)` to survive `Import-Module -Force`
- The monitor loop runs continuously; handle `Ctrl+C` gracefully with a `try/finally` block
- Prefer `Write-Verbose` for diagnostic output; use `Write-Host` (suppressed via `SuppressMessageAttribute`) for monitor status lines
- `-WhatIf` always bypasses the elevation guard so actions can be previewed without admin rights

## File Layout

```
PowerPerf/
├── PowerPerf/
│   ├── PowerPerf.psm1   # Module — all functions
│   └── PowerPerf.psd1   # Module manifest
└── PowerPerf.ps1        # CLI entry point — imports the module and dispatches commands
```

## Module Functions

| Function | Description |
|---|---|
| `Get-CpuSpeed` | Returns `CurrentGHz`, `EffectiveGHz` (via perf counter), `MaxGHz`, `LoadPct` |
| `Get-PowerMode` | Returns the active Windows 11 Power Mode: `Name`, `KnownName`, `GUID` |
| `Set-PowerMode` | Sets Power Mode by `-Mode` (named) or `-GUID` (custom). No elevation required. Supports `-WhatIf` |
| `Get-AvailablePowerModes` | Lists all known Power Modes including `IsActive` flag |
| `Get-PowerSource` | Returns `Source` (AC/Battery), `IsOnAC`, `HasBattery`, `Charging`, `ChargePercent`, `RemainingMin`, `BatterySaver` |
| `Start-CpuBoostMonitor` | Polls CPU speed every N seconds; toggles Power Mode to re-trigger boost. AC-only — pauses on battery |
| `Register-PowerPerfTask` | Registers a Task Scheduler task to run `-Monitor` at logon. Requires elevation. Supports `-WhatIf` |
| `Unregister-PowerPerfTask` | Removes the Task Scheduler task. Requires elevation. Supports `-WhatIf` |

## Running / Testing

```powershell
# Show CPU speed + power source + active power mode (default)
.\PowerPerf.ps1

# Show only CPU speed / power mode / power source
.\PowerPerf.ps1 -ShowCpu
.\PowerPerf.ps1 -ShowMode
.\PowerPerf.ps1 -ShowPowerSource

# List all available power modes
.\PowerPerf.ps1 -ListModes

# Switch power mode (no elevation required)
.\PowerPerf.ps1 -SetMode BestPerformance
.\PowerPerf.ps1 -SetMode Balanced -WhatIf

# Start the CPU boost monitor (runs until Ctrl+C)
.\PowerPerf.ps1 -Monitor
.\PowerPerf.ps1 -Monitor -ThresholdGHz 1.5 -IntervalSeconds 10 -CooldownSeconds 30

# Register / remove the logon scheduled task (requires elevation)
.\PowerPerf.ps1 -RegisterTask
.\PowerPerf.ps1 -RegisterTask -Force -ThresholdGHz 1.5  # overwrite with custom params
.\PowerPerf.ps1 -RegisterTask -WhatIf                   # preview without elevation
.\PowerPerf.ps1 -UnregisterTask
.\PowerPerf.ps1 -UnregisterTask -WhatIf
```

Use the module directly in other scripts:

```powershell
Import-Module .\PowerPerf
$speed  = Get-CpuSpeed
$source = Get-PowerSource
Set-PowerMode -Mode BestPerformance
Register-PowerPerfTask -ScriptPath 'C:\Tools\PowerPerf\PowerPerf.ps1'
```

## Elevation Check

`Register-PowerPerfTask` and `Unregister-PowerPerfTask` require an elevated session (Task Scheduler APIs need admin). `Set-PowerMode` does **not** require elevation (overlay API). The check pattern:

```powershell
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $WhatIfPreference) { Write-Error '...'; return }
```

`-WhatIf` always bypasses the elevation guard so actions can be previewed without admin rights.
