#Requires -Version 5.1
<#
.SYNOPSIS
    Reads current CPU speed and manages the active Windows power plan.
.DESCRIPTION
    Imports the PowerPerf module and exposes a simple CLI interface for:
      - Displaying current CPU clock speed in GHz
      - Displaying the current active power plan
      - Switching the active power plan
      - Listing all available power plans
      - Monitoring CPU speed and auto-triggering boost when throttling is detected
.PARAMETER ShowPowerSource
    Display whether the system is on AC power or battery.
.PARAMETER ShowCpu
    Display current CPU speed.
.PARAMETER ShowMode
    Display the current active power plan.
.PARAMETER SetMode
    Set the active power plan. Accepts: PowerSaver, Balanced, HighPerformance.
.PARAMETER ListModes
    List all power plans available on this system.
.PARAMETER Monitor
    Monitor CPU speed continuously and toggle the power plan when throttling is detected.
.PARAMETER ThresholdGHz
    (Monitor) Effective GHz below which a boost toggle is fired. Default: 1.0
.PARAMETER IntervalSeconds
    (Monitor) Polling interval in seconds. Default: 5
.PARAMETER CooldownSeconds
    (Monitor) Minimum seconds between consecutive toggles. Default: 15
.PARAMETER All
    Show CPU speed and current power mode (default when no parameters given).
.EXAMPLE
    .\PowerPerf.ps1
    Show CPU speed and current power mode.
.EXAMPLE
    .\PowerPerf.ps1 -SetMode HighPerformance
    Switch to Best Performance power plan.
.EXAMPLE
    .\PowerPerf.ps1 -ListModes
    List all available power plans.
.EXAMPLE
    .\PowerPerf.ps1 -Monitor
    Start continuous monitoring and auto-boost. Requires elevation.
.PARAMETER RegisterTask
    Register a Windows Task Scheduler task to run the monitor at user logon. Requires elevation.
.PARAMETER UnregisterTask
    Remove the PowerPerf Monitor scheduled task. Requires elevation.
.PARAMETER TaskName
    Task name used by -RegisterTask and -UnregisterTask. Default: 'PowerPerf Monitor'
.PARAMETER Force
    (RegisterTask) Overwrite the task if it already exists.
.EXAMPLE
    .\PowerPerf.ps1 -Monitor -ThresholdGHz 1.5 -IntervalSeconds 3
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
    Justification = 'Switch parameters select the active ParameterSet; dispatch is done via $PSCmdlet.ParameterSetName')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
    Justification = 'Intentional colored section headers for interactive CLI output')]
[CmdletBinding(DefaultParameterSetName = 'All', SupportsShouldProcess)]
param(
    [Parameter(ParameterSetName = 'All')]
    [switch]$All,

    [Parameter(ParameterSetName = 'PowerSource')]
    [switch]$ShowPowerSource,

    [Parameter(ParameterSetName = 'Cpu')]
    [switch]$ShowCpu,

    [Parameter(ParameterSetName = 'Mode')]
    [switch]$ShowMode,

    [Parameter(ParameterSetName = 'Set', Mandatory)]
    [ValidateSet('BestPowerEfficiency', 'Balanced', 'BestPerformance')]
    [string]$SetMode,

    [Parameter(ParameterSetName = 'List')]
    [switch]$ListModes,

    [Parameter(ParameterSetName = 'Monitor')]
    [switch]$Monitor,

    [Parameter(ParameterSetName = 'Monitor')]
    [double]$ThresholdGHz = 1.0,

    [Parameter(ParameterSetName = 'Monitor')]
    [int]$IntervalSeconds = 5,

    [Parameter(ParameterSetName = 'Monitor')]
    [int]$CooldownSeconds = 15,

    [Parameter(ParameterSetName = 'RegisterTask')]
    [switch]$RegisterTask,

    [Parameter(ParameterSetName = 'RegisterTask')]
    [double]$RegThresholdGHz = 1.0,

    [Parameter(ParameterSetName = 'RegisterTask')]
    [int]$RegIntervalSeconds = 5,

    [Parameter(ParameterSetName = 'RegisterTask')]
    [int]$RegCooldownSeconds = 15,

    [Parameter(ParameterSetName = 'RegisterTask')]
    [Parameter(ParameterSetName = 'UnregisterTask')]
    [string]$TaskName = 'PowerPerf Monitor',

    [Parameter(ParameterSetName = 'RegisterTask')]
    [switch]$Force,

    [Parameter(ParameterSetName = 'UnregisterTask')]
    [switch]$UnregisterTask
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Import module ────────────────────────────────────────────────────────────
$moduleRoot = Join-Path $PSScriptRoot 'PowerPerf'
Import-Module $moduleRoot -Force

# ── Actions ──────────────────────────────────────────────────────────────────
switch ($PSCmdlet.ParameterSetName) {

    'PowerSource' {
        Get-PowerSource | Format-List
    }

    'Cpu' {
        Get-CpuSpeed | Format-Table -AutoSize
    }

    'Mode' {
        Get-PowerMode | Format-List
    }

    'Set' {
        Set-PowerMode -Mode $SetMode -Verbose:($VerbosePreference -eq 'Continue') | Format-List
    }

    'List' {
        Get-AvailablePowerModes | Format-Table -AutoSize
    }

    'Monitor' {
        Start-CpuBoostMonitor `
            -ThresholdGHz    $ThresholdGHz `
            -IntervalSeconds $IntervalSeconds `
            -CooldownSeconds $CooldownSeconds `
            -Verbose:($VerbosePreference -eq 'Continue')
    }

    'RegisterTask' {
        Register-PowerPerfTask `
            -ScriptPath    $PSCommandPath `
            -TaskName      $TaskName `
            -ThresholdGHz  $RegThresholdGHz `
            -IntervalSeconds $RegIntervalSeconds `
            -CooldownSeconds $RegCooldownSeconds `
            -Force:$Force `
            -Verbose:($VerbosePreference -eq 'Continue') | Format-List
    }

    'UnregisterTask' {
        Unregister-PowerPerfTask `
            -TaskName $TaskName `
            -Verbose:($VerbosePreference -eq 'Continue')
    }

    default {
        Write-Host "`n=== Power Source ===" -ForegroundColor Cyan
        Get-PowerSource | Format-List

        Write-Host "=== CPU Speed ===" -ForegroundColor Cyan
        Get-CpuSpeed | Format-Table -AutoSize

        Write-Host "=== Active Power Mode ===" -ForegroundColor Cyan
        Get-PowerMode | Format-List
    }
}
