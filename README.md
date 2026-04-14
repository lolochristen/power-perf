# PowerPerf

A PowerShell module and CLI script that fights CPU throttling on Windows 11 by automatically toggling the Power Mode overlay to re-trigger CPU boost.

> **Why does this exist?**
> On many **Lenovo laptops** (and other notebooks) the CPU throttles down to very low clock speeds even when plugged in, and simply setting the Windows power plan to "Best Performance" is not enough to prevent it. The only reliable workaround found is to *switch the Power Mode away and back again* — this re-signals Windows to apply boost, and the CPU recovers within seconds. PowerPerf automates that toggle in the background.
>
> This tool **should not be necessary**. It is a workaround for a firmware/driver/OS interaction bug. Ideally Lenovo (or Microsoft) would fix the underlying throttling behaviour. Until then, PowerPerf fills the gap.

---

## How It Works

PowerPerf polls the **effective CPU clock speed** every few seconds using the Windows `% Processor Performance` performance counter multiplied by the processor's maximum frequency. If the effective speed drops below a configurable threshold (default: 1 GHz) while on AC power, it:

1. Switches the Windows 11 **Power Mode** overlay to *Balanced*
2. Immediately switches it back to *Best Performance*

This toggle re-triggers the CPU boost mechanism without requiring any user interaction.

Power Mode is controlled via the `PowerSetActiveOverlayScheme` / `PowerGetEffectiveOverlayScheme` APIs in `powrprof.dll` — the same setting exposed in **Settings → System → Power & battery → Power mode**. This is distinct from the legacy power *plan* (`powercfg /setactive`) and does **not** require Administrator privileges.

---

## Requirements

- Windows 10/11
- PowerShell 5.1 or later (PowerShell 7+ supported)

---

## File Layout

```
PowerPerf/
├── PowerPerf/
│   ├── PowerPerf.psm1   # Module — all functions
│   └── PowerPerf.psd1   # Module manifest
└── PowerPerf.ps1        # CLI entry point
```

---

## Usage

### Default — show system status

```powershell
.\PowerPerf.ps1
```

Displays power source, current CPU speed, and active Power Mode.

### Show individual info

```powershell
.\PowerPerf.ps1 -ShowPowerSource   # AC or battery status
.\PowerPerf.ps1 -ShowCpu           # Current / effective / max GHz
.\PowerPerf.ps1 -ShowMode          # Active Windows 11 Power Mode
.\PowerPerf.ps1 -ListModes         # All available Power Modes
```

### Switch Power Mode

```powershell
.\PowerPerf.ps1 -SetMode BestPerformance
.\PowerPerf.ps1 -SetMode Balanced
.\PowerPerf.ps1 -SetMode BestPowerEfficiency
.\PowerPerf.ps1 -SetMode Balanced -WhatIf   # preview without changing
```

No elevation required.

### Start the CPU boost monitor

```powershell
# Run with defaults (threshold: 1 GHz, poll: 5 s, cooldown: 15 s)
.\PowerPerf.ps1 -Monitor

# Custom parameters
.\PowerPerf.ps1 -Monitor -ThresholdGHz 1.5 -IntervalSeconds 3 -CooldownSeconds 10
```

The monitor runs until `Ctrl+C`. On battery power, toggling is automatically suspended — the monitor keeps running but will not switch Power Mode until AC is restored.

### Register as a logon task (runs automatically at sign-in)

```powershell
# Register (requires elevation)
.\PowerPerf.ps1 -RegisterTask

# Register with custom monitor parameters
.\PowerPerf.ps1 -RegisterTask -RegThresholdGHz 1.5 -RegIntervalSeconds 3

# Overwrite an existing task
.\PowerPerf.ps1 -RegisterTask -Force

# Preview without making changes (no elevation needed)
.\PowerPerf.ps1 -RegisterTask -WhatIf

# Remove the task (requires elevation)
.\PowerPerf.ps1 -UnregisterTask
```

The scheduled task starts the monitor hidden at user logon and runs indefinitely.

---

## Module Functions

| Function | Description |
|---|---|
| `Get-CpuSpeed` | Returns `CurrentGHz`, `EffectiveGHz`, `MaxGHz`, `LoadPct` |
| `Get-PowerMode` | Returns the active Windows 11 Power Mode (`Name`, `KnownName`, `GUID`) |
| `Set-PowerMode` | Sets Power Mode by `-Mode` name or `-GUID`. No elevation required. Supports `-WhatIf` |
| `Get-AvailablePowerModes` | Lists all known Power Modes with `IsActive` flag |
| `Get-PowerSource` | Returns `Source` (AC/Battery), `IsOnAC`, `HasBattery`, `Charging`, `ChargePercent`, `RemainingMin`, `BatterySaver` |
| `Start-CpuBoostMonitor` | Polls CPU speed and toggles Power Mode to re-trigger boost. AC-only toggling |
| `Register-PowerPerfTask` | Registers a Task Scheduler logon task. Requires elevation. Supports `-WhatIf` |
| `Unregister-PowerPerfTask` | Removes the scheduled task. Requires elevation. Supports `-WhatIf` |

Use the module directly in other scripts:

```powershell
Import-Module .\PowerPerf

$speed  = Get-CpuSpeed
$source = Get-PowerSource

if ($source.IsOnAC -and $speed.EffectiveGHz -lt 1.0) {
    Set-PowerMode -Mode Balanced
    Set-PowerMode -Mode BestPerformance
}
```

---

## Windows 11 Power Mode vs. Power Plan

Windows has two separate concepts that are easy to confuse:

| | Power Plan | Power Mode |
|---|---|---|
| **UI location** | Control Panel → Power Options | Settings → Power & battery → Power mode |
| **API** | `powercfg /setactive` | `PowerSetActiveOverlayScheme` in `powrprof.dll` |
| **Requires admin** | Yes | No |
| **GUIDs** | `381b4222…` (Balanced), `8c5e7fda…` (High Perf) | `00000000…` (Balanced), `ded574b5…` (Best Perf) |

PowerPerf controls the **Power Mode overlay**, not the legacy power plan.

---

## License

MIT
