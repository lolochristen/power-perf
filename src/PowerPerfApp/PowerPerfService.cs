using System;
using System.Diagnostics;
using System.Management;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;

namespace PowerPerfApp;

public enum PowerModeType
{
    BestPowerEfficiency,
    Balanced,
    BestPerformance,
    Unknown
}

public sealed record PowerStatus(
    bool IsOnAc,
    int BatteryPercent,
    PowerModeType PowerMode,
    double EffectiveGHz,
    double MaxGHz,
    bool IsToggling);

public sealed class PowerPerfService : IDisposable
{
    private static readonly Guid GuidBestPowerEfficiency = new("961cc777-2547-4f9d-8174-7d86181b8a7a");
    private static readonly Guid GuidBalanced = new("00000000-0000-0000-0000-000000000000");
    private static readonly Guid GuidBestPerformance = new("ded574b5-45a0-4f42-8737-46345c09c238");

    public const double FallbackThresholdGHz = 1.0;
    public double ThresholdGHz { get; set; } = FallbackThresholdGHz;
    private const int IntervalMs = 5000;
    private const int CooldownMs = 15000;

    private PerformanceCounter _perfCounter;
    private CancellationTokenSource? _cts;
    private DateTime _lastToggle = DateTime.MinValue;
    private double _cachedMaxGHz;
    private bool _isToggling;

    public event Action<PowerStatus>? StatusChanged;

    // Win32: DWORD PowerSetActiveOverlayScheme(GUID OverlaySchemeGuid) — the GUID is
    // passed BY VALUE (a single argument), matching the PowerPerf PowerShell module.
    // Declaring it with an extra UserRootPowerKey/ref parameter (the legacy power-PLAN
    // signature) makes the call silently no-op on x64.
    [DllImport("powrprof.dll")]
    private static extern uint PowerSetActiveOverlayScheme(Guid OverlaySchemeGuid);

    [DllImport("powrprof.dll")]
    private static extern uint PowerGetEffectiveOverlayScheme(out Guid ActiveOverlayGuid);

    [DllImport("powrprof.dll")]
    private static extern uint PowerGetActualOverlayScheme(out Guid ActualOverlayGuid);

    [StructLayout(LayoutKind.Sequential)]
    private struct SYSTEM_POWER_STATUS
    {
        public byte ACLineStatus;
        public byte BatteryFlag;
        public byte BatteryLifePercent;
        public byte SystemStatusFlag;
        public uint BatteryLifeTime;
        public uint BatteryFullLifeTime;
    }

    [DllImport("kernel32.dll")]
    private static extern bool GetSystemPowerStatus(out SYSTEM_POWER_STATUS lpSystemPowerStatus);

    public PowerPerfService()
    {
        _perfCounter = CreatePerfCounter();
    }

    private static PerformanceCounter CreatePerfCounter()
    {
        var counter = new PerformanceCounter("Processor Information", "% Processor Performance", "_Total");
        try { counter.NextValue(); } catch { /* first call is always 0; ignore */ }
        return counter;
    }

    /// <summary>
    /// Reads the processor-performance counter, self-healing if the instance has been
    /// invalidated. PerformanceCounter handles become unusable across sleep/resume and
    /// session switches; without recreating it the monitor would silently stop updating
    /// after the machine wakes. Returns 0 on the tick where the counter is recreated
    /// (its first read is always 0); the next tick returns real data.
    /// </summary>
    private float ReadProcessorPerformancePercent()
    {
        try
        {
            return _perfCounter.NextValue();
        }
        catch
        {
            try { _perfCounter.Dispose(); } catch { }
            _perfCounter = CreatePerfCounter();
            return 0f;
        }
    }

    public void StartMonitoring()
    {
        _cts = new CancellationTokenSource();
        _ = MonitorLoopAsync(_cts.Token);
    }

    public void StopMonitoring()
    {
        _cts?.Cancel();
    }

    private async Task MonitorLoopAsync(CancellationToken ct)
    {
        // Allow perf counter to warm up
        await Task.Delay(1000, ct).ConfigureAwait(false);

        while (!ct.IsCancellationRequested)
        {
            try
            {
                var status = CollectStatus();
                StatusChanged?.Invoke(status);

                if (status.IsOnAc && !_isToggling && ShouldToggle(status))
                {
                    _isToggling = true;
                    StatusChanged?.Invoke(status with { IsToggling = true });
                    await ToggleBoostAsync(ct).ConfigureAwait(false);
                    _lastToggle = DateTime.UtcNow;
                    _isToggling = false;
                }
            }
            catch (OperationCanceledException) { break; }
            catch { /* swallow transient errors */ }

            await Task.Delay(IntervalMs, ct).ConfigureAwait(false);
        }
    }

    private bool ShouldToggle(PowerStatus status) =>
        (DateTime.UtcNow - _lastToggle).TotalMilliseconds >= CooldownMs
        && status.EffectiveGHz < ThresholdGHz;

    private async Task ToggleBoostAsync(CancellationToken ct)
    {
        PowerSetActiveOverlayScheme(GuidBalanced);
        await Task.Delay(200, ct).ConfigureAwait(false);
        PowerSetActiveOverlayScheme(GuidBestPerformance);
    }

    public PowerStatus CollectStatus()
    {
        GetSystemPowerStatus(out var ps);
        bool isOnAc = ps.ACLineStatus == 1;
        int batteryPct = ps.BatteryLifePercent == 255 ? 0 : (int)ps.BatteryLifePercent;

        PowerGetEffectiveOverlayScheme(out var modeGuid);
        var mode = GuidToMode(modeGuid);

        float perfPct = ReadProcessorPerformancePercent();
        double maxGHz = GetMaxClockGHz();
        double effectiveGHz = maxGHz * perfPct / 100.0;

        return new PowerStatus(isOnAc, batteryPct, mode, effectiveGHz, maxGHz, _isToggling);
    }

    public double GetMaxClockGHz()
    {
        if (_cachedMaxGHz > 0) return _cachedMaxGHz;
        try
        {
            using var searcher = new ManagementObjectSearcher("SELECT MaxClockSpeed FROM Win32_Processor");
            foreach (ManagementObject obj in searcher.Get())
            {
                _cachedMaxGHz = Convert.ToDouble(obj["MaxClockSpeed"]) / 1000.0;
                break;
            }
        }
        catch { _cachedMaxGHz = 4.0; }
        return _cachedMaxGHz;
    }

    public void SetPowerMode(PowerModeType mode)
    {
        var guid = mode switch
        {
            PowerModeType.BestPowerEfficiency => GuidBestPowerEfficiency,
            PowerModeType.BestPerformance => GuidBestPerformance,
            _ => GuidBalanced
        };
        PowerSetActiveOverlayScheme(guid);
    }

    /// <summary>
    /// Returns the power overlay that is currently <em>selected</em> — i.e. what was
    /// last applied via <see cref="SetPowerMode"/>. Unlike the effective scheme
    /// (<see cref="CollectStatus"/>), this value is not subject to OS power-policy
    /// overrides, so it is the correct value to confirm a <see cref="SetPowerMode"/>
    /// call actually took effect.
    /// </summary>
    public PowerModeType GetActivePowerMode()
    {
        PowerGetActualOverlayScheme(out var guid);
        return GuidToMode(guid);
    }

    private static PowerModeType GuidToMode(Guid guid)
    {
        if (guid == GuidBestPowerEfficiency) return PowerModeType.BestPowerEfficiency;
        if (guid == GuidBestPerformance) return PowerModeType.BestPerformance;
        if (guid == GuidBalanced) return PowerModeType.Balanced;
        return PowerModeType.Unknown;
    }

    public void Dispose()
    {
        _cts?.Cancel();
        _perfCounter.Dispose();
    }
}
