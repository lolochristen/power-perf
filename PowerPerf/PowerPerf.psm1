#Requires -Version 5.1

# ── Windows APIs ──────────────────────────────────────────────────────────────
# PowerSourceApi is the newest type — if it's missing, (re-)load all types.
# If Add-Type fails because older types already exist, the session must be restarted.
if (-not ([System.Management.Automation.PSTypeName]'PowerSourceApi').Type) {
    try {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public class PowerModeApi {
    [DllImport("powrprof.dll")]
    public static extern uint PowerSetActiveOverlayScheme(Guid OverlaySchemeGuid);

    [DllImport("powrprof.dll")]
    public static extern uint PowerGetEffectiveOverlayScheme(out Guid EffectiveOverlayGuid);
}

public struct SystemPowerStatus {
    public byte  ACLineStatus;
    public byte  BatteryFlag;
    public byte  BatteryLifePercent;
    public byte  SystemStatusFlag;
    public uint  BatteryLifeTime;
    public uint  BatteryFullLifeTime;
}

public class PowerSourceApi {
    [DllImport("kernel32.dll")]
    public static extern bool GetSystemPowerStatus(out SystemPowerStatus lpSystemPowerStatus);
}
"@
    } catch {
        if ($_.Exception.Message -match 'already exists') {
            throw "PowerPerf type definitions have changed. Please start a new PowerShell session and try again."
        }
        throw
    }
}

# Windows 11 Power Mode overlay GUIDs (Settings > System > Power & battery > Power mode)
$script:PowerModes = [ordered]@{
    BestPowerEfficiency = '961cc777-2547-4f9d-8174-7d86181b8a7a'
    Balanced            = '00000000-0000-0000-0000-000000000000'
    BestPerformance     = 'ded574b5-45a0-4f42-8737-46345c09c238'
}

function Get-CpuSpeed {
    <#
    .SYNOPSIS
        Returns the current CPU clock speed in GHz for each physical processor.
    .DESCRIPTION
        Reads CurrentClockSpeed and MaxClockSpeed from Win32_Processor via CIM.
        Also samples the Windows performance counter "% Processor Performance"
        to derive a more accurate effective speed.
    .EXAMPLE
        Get-CpuSpeed
    .EXAMPLE
        Get-CpuSpeed -Verbose
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param()

    $processors = Get-CimInstance -ClassName Win32_Processor

    # Sample % Processor Performance counter for a more accurate effective speed
    try {
        $counter = (Get-Counter '\Processor Information(_Total)\% Processor Performance' -ErrorAction Stop).CounterSamples[0].CookedValue
        $perfPct = [Math]::Round($counter / 100.0, 4)
    } catch {
        Write-Verbose "Performance counter unavailable, falling back to CIM CurrentClockSpeed"
        $perfPct = $null
    }

    foreach ($cpu in $processors) {
        $maxGHz     = [Math]::Round($cpu.MaxClockSpeed  / 1000.0, 2)
        $currentGHz = [Math]::Round($cpu.CurrentClockSpeed / 1000.0, 2)
        $effectiveGHz = if ($null -ne $perfPct) {
            [Math]::Round($maxGHz * $perfPct, 2)
        } else {
            $currentGHz
        }

        [PSCustomObject]@{
            PSTypeName    = 'PowerPerf.CpuSpeed'
            Name          = $cpu.Name.Trim()
            CurrentGHz    = $currentGHz
            EffectiveGHz  = $effectiveGHz
            MaxGHz        = $maxGHz
            LoadPct       = if ($null -ne $perfPct) { [Math]::Round($perfPct * 100, 1) } else { $null }
        }
    }
}

function Get-PowerMode {
    <#
    .SYNOPSIS
        Returns the current Windows 11 Power Mode (the overlay shown in Settings > Power & battery).
    .EXAMPLE
        Get-PowerMode
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param()

    $guid = [Guid]::Empty
    $ret  = [PowerModeApi]::PowerGetEffectiveOverlayScheme([ref]$guid)
    if ($ret -ne 0) {
        Write-Error ("PowerGetEffectiveOverlayScheme failed with code 0x{0:X8}" -f $ret)
        return
    }

    $guidStr  = $guid.ToString().ToLower()
    $modeName = $script:PowerModes.GetEnumerator() |
                    Where-Object { $_.Value -eq $guidStr } |
                    Select-Object -First 1 -ExpandProperty Key

    [PSCustomObject]@{
        PSTypeName = 'PowerPerf.PowerMode'
        Mode       = if ($modeName) { $modeName } else { 'Custom' }
        GUID       = $guidStr
    }
}

function Set-PowerMode {
    <#
    .SYNOPSIS
        Sets the Windows 11 Power Mode (Settings > System > Power & battery > Power mode).
    .DESCRIPTION
        Accepts a named mode (BestPowerEfficiency, Balanced, BestPerformance) or a raw GUID.
        Uses the PowerSetActiveOverlayScheme Windows API — no elevation required.
    .PARAMETER Mode
        Named power mode to activate.
    .PARAMETER GUID
        Raw overlay GUID to activate (use for custom modes).
    .EXAMPLE
        Set-PowerMode -Mode BestPerformance
    .EXAMPLE
        Set-PowerMode -Mode Balanced -WhatIf
    .EXAMPLE
        Set-PowerMode -GUID 'ded574b5-45a0-4f42-8737-46345c09c238'
    #>
    [CmdletBinding(DefaultParameterSetName = 'Named', SupportsShouldProcess)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Named', Position = 0)]
        [ValidateSet('BestPowerEfficiency', 'Balanced', 'BestPerformance')]
        [string]$Mode,

        [Parameter(Mandatory, ParameterSetName = 'GUID', Position = 0)]
        [ValidatePattern('^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$')]
        [string]$GUID
    )

    $targetGUID = if ($PSCmdlet.ParameterSetName -eq 'Named') {
        $script:PowerModes[$Mode]
    } else {
        $GUID.ToLower()
    }

    $label = if ($PSCmdlet.ParameterSetName -eq 'Named') { $Mode } else { $GUID }

    if ($PSCmdlet.ShouldProcess("Windows 11 Power Mode", "Set to '$label' ($targetGUID)")) {
        $ret = [PowerModeApi]::PowerSetActiveOverlayScheme([Guid]$targetGUID)
        if ($ret -ne 0) {
            Write-Error ("PowerSetActiveOverlayScheme failed with code 0x{0:X8}" -f $ret)
            return
        }
        Write-Verbose "Power mode set to '$label'"
        Get-PowerMode
    }
}

function Get-AvailablePowerModes {
    <#
    .SYNOPSIS
        Lists the Windows 11 Power Mode options available on this system.
    .EXAMPLE
        Get-AvailablePowerModes
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Intentionally plural — returns a collection of modes')]
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param()

    $current = (Get-PowerMode).GUID

    foreach ($entry in $script:PowerModes.GetEnumerator()) {
        [PSCustomObject]@{
            PSTypeName = 'PowerPerf.PowerMode'
            Mode       = $entry.Key
            GUID       = $entry.Value
            IsActive   = ($entry.Value -eq $current)
        }
    }
}

function Start-CpuBoostMonitor {
    <#
    .SYNOPSIS
        Monitors CPU speed and toggles the power mode to re-activate CPU boost when throttling is detected.
    .DESCRIPTION
        Polls CPU effective speed every IntervalSeconds seconds. When effective speed drops below
        ThresholdGHz, briefly switches to Balanced then back to BestPerformance — forcing Windows
        to re-evaluate and re-trigger CPU boost.

        Boost toggling only occurs while on AC power. If the system switches to battery mid-session,
        toggling is suspended and a warning is shown. It resumes automatically when AC is restored.

        Switches to BestPerformance before monitoring starts (if not already active).
        Press Ctrl+C to stop; the original power mode is restored on exit.
    .PARAMETER ThresholdGHz
        Effective CPU speed (GHz) below which a boost toggle is fired. Default: 1.0
    .PARAMETER IntervalSeconds
        Target polling interval in seconds. Default: 5
    .PARAMETER ToggleDelayMs
        Milliseconds to hold Balanced before switching back to BestPerformance. Default: 500
    .PARAMETER CooldownSeconds
        Minimum seconds between consecutive boost toggles to prevent thrashing. Default: 15
    .EXAMPLE
        Start-CpuBoostMonitor
    .EXAMPLE
        Start-CpuBoostMonitor -ThresholdGHz 1.5 -Verbose
    .EXAMPLE
        Start-CpuBoostMonitor -IntervalSeconds 3 -CooldownSeconds 10
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Intentional colored console output for interactive monitoring UI')]
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [double] $ThresholdGHz    = 1.0,
        [int]    $IntervalSeconds = 5,
        [int]    $ToggleDelayMs   = 500,
        [int]    $CooldownSeconds = 15
    )

    $originalMode = Get-PowerMode

    # In WhatIf mode: describe intent and return — don't cascade WhatIf into the polling loop
    if ($WhatIfPreference) {
        Write-Host "What if: Start-CpuBoostMonitor would:" -ForegroundColor Cyan
        Write-Host ("  Poll CPU speed every ~{0}s" -f $IntervalSeconds)
        Write-Host ("  When effective speed < {0} GHz AND on AC: toggle Balanced ({1}ms) -> BestPerformance" -f $ThresholdGHz, $ToggleDelayMs)
        Write-Host ("  Cooldown between toggles: {0}s" -f $CooldownSeconds)
        Write-Host "  No toggling when running on battery"
        Write-Host "  Restore '$($originalMode.Mode)' on exit"
        return
    }

    if ($originalMode.Mode -ne 'BestPerformance') {
        Write-Host "Switching to BestPerformance before monitoring..." -ForegroundColor Cyan
        [PowerModeApi]::PowerSetActiveOverlayScheme([Guid]$script:PowerModes['BestPerformance']) | Out-Null
    }

    Write-Host ""
    Write-Host "  CPU Boost Monitor started" -ForegroundColor Green
    Write-Host ("  Threshold : {0} GHz  |  Interval : {1}s  |  Cooldown : {2}s" -f $ThresholdGHz, $IntervalSeconds, $CooldownSeconds) -ForegroundColor DarkGray
    Write-Host "  Boost toggling suspended on battery" -ForegroundColor DarkGray
    Write-Host "  Original mode will be restored on Ctrl+C" -ForegroundColor DarkGray
    Write-Host ""

    $lastToggle      = [datetime]::MinValue
    $toggleCount     = 0
    $wasOnBattery    = $false
    # Get-CpuSpeed calls Get-Counter which consumes ~1s sampling; subtract it from sleep
    $sleepSeconds    = [Math]::Max(1, $IntervalSeconds - 1)

    try {
        while ($true) {
            $cpu          = Get-CpuSpeed
            $effectiveGHz = ($cpu | Measure-Object -Property EffectiveGHz -Average).Average
            $maxGHz       = $cpu[0].MaxGHz
            $now          = [datetime]::Now
            $onAC         = (Get-PowerSource).IsOnAC
            $elapsedSec   = if ($lastToggle -eq [datetime]::MinValue) { $CooldownSeconds } `
                            else { [int][Math]::Floor(($now - $lastToggle).TotalSeconds) }
            $cooldownLeft = [Math]::Max(0, $CooldownSeconds - $elapsedSec)
            $pct          = if ($maxGHz -gt 0) { $effectiveGHz / $maxGHz * 100 } else { 0 }

            if (-not $onAC) {
                # Warn once when switching to battery
                if (-not $wasOnBattery) {
                    Write-Host ""
                    Write-Host "  [battery] Boost toggling suspended — unplugged from AC" -ForegroundColor Yellow
                    Write-Host ""
                    $wasOnBattery = $true
                }
                $statusNote  = 'battery  boost suspended'
                $statusColor = 'DarkYellow'
            } elseif ($effectiveGHz -lt $ThresholdGHz) {
                # Notify once when AC is restored after battery
                if ($wasOnBattery) {
                    Write-Host ""
                    Write-Host "  [AC] Back on AC power — boost toggling resumed" -ForegroundColor Green
                    Write-Host ""
                    $wasOnBattery = $false
                }

                if ($cooldownLeft -gt 0) {
                    $statusNote  = "throttled  cooldown ${cooldownLeft}s"
                    $statusColor = 'Yellow'
                } else {
                    $toggleCount++
                    $statusNote  = "throttled  triggering boost #${toggleCount}"
                    $statusColor = 'Red'

                    if ($PSCmdlet.ShouldProcess("Power Mode", "Toggle Balanced -> BestPerformance to trigger CPU boost")) {
                        [PowerModeApi]::PowerSetActiveOverlayScheme([Guid]$script:PowerModes['Balanced'])        | Out-Null
                        Start-Sleep -Milliseconds $ToggleDelayMs
                        [PowerModeApi]::PowerSetActiveOverlayScheme([Guid]$script:PowerModes['BestPerformance']) | Out-Null
                        $lastToggle = $now
                    }
                }
            } else {
                if ($wasOnBattery) {
                    Write-Host ""
                    Write-Host "  [AC] Back on AC power — boost toggling resumed" -ForegroundColor Green
                    Write-Host ""
                    $wasOnBattery = $false
                }
                $statusNote  = 'ok'
                $statusColor = 'Green'
            }

            $sourceTag = if ($onAC) { 'AC' } else { 'BAT' }
            Write-Host ('[{0:HH:mm:ss}][{1}] {2:F2} GHz  ({3:F0}% of {4:F2} GHz max)  [{5}]' -f `
                $now, $sourceTag, $effectiveGHz, $pct, $maxGHz, $statusNote) -ForegroundColor $statusColor

            Start-Sleep -Seconds $sleepSeconds
        }
    } finally {
        Write-Host ""
        Write-Host "Restoring original power mode: $($originalMode.Mode)..." -ForegroundColor Cyan
        [PowerModeApi]::PowerSetActiveOverlayScheme([Guid]$originalMode.GUID) | Out-Null
        Write-Host ("Monitor stopped. Boost was triggered {0} time(s)." -f $toggleCount) -ForegroundColor Green
    }
}

function Get-PowerSource {
    <#
    .SYNOPSIS
        Returns whether the system is running on AC power or battery, plus battery charge details.
    .EXAMPLE
        Get-PowerSource
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param()

    $status = [SystemPowerStatus]::new()
    if (-not [PowerSourceApi]::GetSystemPowerStatus([ref]$status)) {
        Write-Error "GetSystemPowerStatus failed."
        return
    }

    $source = switch ($status.ACLineStatus) {
        0       { 'Battery' }
        1       { 'AC' }
        default { 'Unknown' }
    }

    $chargePct = if ($status.BatteryLifePercent -eq 255) { $null } else { $status.BatteryLifePercent }

    # BatteryFlag bit field: 128 = no battery present
    $hasBattery = -not ($status.BatteryFlag -band 128)

    $charging   = [bool]($status.BatteryFlag -band 8)

    $lifeTimeLong = [long]$status.BatteryLifeTime
    $remainingSec = if ($lifeTimeLong -eq 0xFFFFFFFFL) { $null } else { $lifeTimeLong }
    $remainingMin = if ($null -ne $remainingSec) { [Math]::Round($remainingSec / 60) } else { $null }

    [PSCustomObject]@{
        PSTypeName   = 'PowerPerf.PowerSource'
        Source       = $source
        IsOnAC       = ($source -eq 'AC')
        HasBattery   = $hasBattery
        Charging     = if ($hasBattery) { $charging } else { $null }
        ChargePercent = $chargePct
        RemainingMin  = $remainingMin
        BatterySaver  = [bool]$status.SystemStatusFlag
    }
}

function Register-PowerPerfTask {
    <#
    .SYNOPSIS
        Registers a Windows Task Scheduler task that runs the PowerPerf monitor at user logon.
    .DESCRIPTION
        Creates a scheduled task under the current user that launches PowerPerf.ps1 -Monitor
        in a hidden window whenever the user logs on. Requires an elevated session.

        The monitor parameters (ThresholdGHz, IntervalSeconds, CooldownSeconds) are baked into
        the task's command line at registration time. Re-run with -Force to update them.
    .PARAMETER ScriptPath
        Full path to PowerPerf.ps1. Resolved automatically when called from the script.
    .PARAMETER TaskName
        Name of the scheduled task. Default: 'PowerPerf Monitor'
    .PARAMETER ThresholdGHz
        Passed to -Monitor. Default: 1.0
    .PARAMETER IntervalSeconds
        Passed to -Monitor. Default: 5
    .PARAMETER CooldownSeconds
        Passed to -Monitor. Default: 15
    .PARAMETER Force
        Overwrite the task if it already exists.
    .EXAMPLE
        Register-PowerPerfTask -ScriptPath 'C:\Tools\PowerPerf\PowerPerf.ps1'
    .EXAMPLE
        Register-PowerPerfTask -ScriptPath 'C:\Tools\PowerPerf\PowerPerf.ps1' -ThresholdGHz 1.5 -Force
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path $_ -PathType Leaf })]
        [string]$ScriptPath,

        [string]$TaskName     = 'PowerPerf Monitor',
        [double]$ThresholdGHz = 1.0,
        [int]$IntervalSeconds = 5,
        [int]$CooldownSeconds = 15,
        [switch]$Force
    )

    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin -and -not $WhatIfPreference) {
        Write-Error 'Registering a scheduled task requires an elevated (Administrator) session.'
        return
    }

    $existing = Get-ScheduledTask -TaskName $TaskName -TaskPath '\' -ErrorAction SilentlyContinue
    if (-not $existing) {
        # fallback: search all paths (task may have been registered in a sub-folder)
        $existing = Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -eq $TaskName } | Select-Object -First 1
    }
    if ($existing -and -not $Force) {
        Write-Error "Task '$TaskName' already exists. Use -Force to overwrite."
        return
    }

    # Use the same PowerShell host that is running this session
    $psExe      = (Get-Process -Id $PID).Path
    $workDir    = Split-Path -Parent (Resolve-Path $ScriptPath)
    $taskArgs   = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden " +
                  "-File `"$ScriptPath`" -Monitor " +
                  "-ThresholdGHz $ThresholdGHz " +
                  "-IntervalSeconds $IntervalSeconds " +
                  "-CooldownSeconds $CooldownSeconds"

    $action    = New-ScheduledTaskAction  -Execute $psExe -Argument $taskArgs -WorkingDirectory $workDir
    $trigger   = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $settings  = New-ScheduledTaskSettingsSet `
                     -ExecutionTimeLimit      ([TimeSpan]::Zero) `
                     -MultipleInstances       IgnoreNew `
                     -StartWhenAvailable `
                     -AllowStartIfOnBatteries `
                     -DontStopIfGoingOnBatteries
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
    $task      = New-ScheduledTask `
                     -Action      $action `
                     -Trigger     $trigger `
                     -Settings    $settings `
                     -Principal   $principal `
                     -Description 'PowerPerf CPU boost monitor — auto-switches power mode to overcome CPU throttling at logon.'

    if ($PSCmdlet.ShouldProcess($TaskName, 'Register scheduled task')) {
        Register-ScheduledTask -TaskName $TaskName -InputObject $task -Force:$Force | Out-Null
        Write-Verbose "Task '$TaskName' registered."

        [PSCustomObject]@{
            PSTypeName    = 'PowerPerf.ScheduledTask'
            TaskName      = $TaskName
            ScriptPath    = $ScriptPath
            Trigger       = "At logon ($env:USERNAME)"
            ThresholdGHz  = $ThresholdGHz
            IntervalSec   = $IntervalSeconds
            CooldownSec   = $CooldownSeconds
            Status        = 'Registered'
        }
    }
}

function Unregister-PowerPerfTask {
    <#
    .SYNOPSIS
        Removes the PowerPerf Monitor scheduled task.
    .PARAMETER TaskName
        Name of the task to remove. Default: 'PowerPerf Monitor'
    .EXAMPLE
        Unregister-PowerPerfTask
    .EXAMPLE
        Unregister-PowerPerfTask -TaskName 'My PowerPerf Task'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$TaskName = 'PowerPerf Monitor'
    )

    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin -and -not $WhatIfPreference) {
        Write-Error 'Removing a scheduled task requires an elevated (Administrator) session.'
        return
    }

    $task = Get-ScheduledTask -TaskName $TaskName -TaskPath '\' -ErrorAction SilentlyContinue
    if (-not $task) {
        # fallback: search all paths
        $task = Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -eq $TaskName } | Select-Object -First 1
    }
    if (-not $task) {
        Write-Warning "Task '$TaskName' not found — nothing to remove."
        return
    }

    if ($PSCmdlet.ShouldProcess($TaskName, 'Unregister scheduled task')) {
        Unregister-ScheduledTask -TaskName $TaskName -TaskPath $task.TaskPath -Confirm:$false
        Write-Verbose "Task '$TaskName' removed."
        Write-Information "Task '$TaskName' successfully removed." -InformationAction Continue
    }
}

Export-ModuleMember -Function Get-CpuSpeed, Get-PowerMode, Set-PowerMode, Get-AvailablePowerModes, `
                               Get-PowerSource, Start-CpuBoostMonitor, `
                               Register-PowerPerfTask, Unregister-PowerPerfTask
