using System.Diagnostics;
using Xunit;

namespace PowerPerfApp.Tests;

/// <summary>
/// Integration tests that exercise the real Win32 power-overlay APIs in powrprof.dll
/// (<c>PowerSetActiveOverlayScheme</c> / <c>PowerGetActualOverlayScheme</c>). These
/// tests change the actual system power mode and read it back to verify the change
/// took effect. The original mode is captured and restored when each test finishes,
/// so the machine is left exactly as it was found.
///
/// Verification uses the <b>actual</b> (selected) overlay scheme via
/// <see cref="PowerPerfService.GetActivePowerMode"/>, not the effective scheme.
/// The effective scheme (what <see cref="PowerPerfService.CollectStatus"/> reports
/// for display) can legitimately be overridden by Windows power policy — e.g. it may
/// stay pinned to "Best Performance" regardless of what is selected — so it is not a
/// reliable proof that a SetPowerMode call was honoured. The actual scheme is.
///
/// Requires Windows 10/11 with power-overlay support (every modern desktop/laptop).
/// </summary>
[Collection("PowerMode")] // serialise — these tests mutate a single global system setting
public sealed class PowerPerfServiceIntegrationTests : IDisposable
{
    private readonly PowerPerfService _service = new();
    private readonly PowerModeType _originalMode;

    public PowerPerfServiceIntegrationTests()
    {
        _originalMode = _service.GetActivePowerMode();

        // If the platform doesn't report a known overlay scheme, the power-overlay
        // API isn't available here and these integration tests can't run meaningfully.
        Assert.SkipWhen(
            _originalMode == PowerModeType.Unknown,
            "Power overlay API returned an unknown scheme — overlays not supported on this machine.");
    }

    public void Dispose()
    {
        // Restore whatever mode the machine was in before the test ran.
        if (_originalMode != PowerModeType.Unknown)
            _service.SetPowerMode(_originalMode);
        _service.Dispose();
    }

    [Theory]
    [InlineData(PowerModeType.BestPowerEfficiency)]
    [InlineData(PowerModeType.Balanced)]
    [InlineData(PowerModeType.BestPerformance)]
    public void SetPowerMode_IsReflectedInActiveOverlayScheme(PowerModeType mode)
    {
        _service.SetPowerMode(mode);

        var active = WaitForActiveMode(mode);

        Assert.Equal(mode, active);
    }

    [Fact]
    public void SetPowerMode_CanCycleThroughAllModes()
    {
        foreach (var mode in new[]
                 {
                     PowerModeType.BestPerformance,
                     PowerModeType.BestPowerEfficiency,
                     PowerModeType.Balanced,
                 })
        {
            _service.SetPowerMode(mode);
            Assert.Equal(mode, WaitForActiveMode(mode));
        }
    }

    [Fact]
    public void GetActivePowerMode_IsStableAcrossReads()
    {
        _service.SetPowerMode(PowerModeType.BestPowerEfficiency);
        WaitForActiveMode(PowerModeType.BestPowerEfficiency);

        // Two consecutive reads of the same set state must agree.
        var first = _service.GetActivePowerMode();
        var second = _service.GetActivePowerMode();

        Assert.Equal(PowerModeType.BestPowerEfficiency, first);
        Assert.Equal(first, second);
    }

    [Fact]
    public void CollectStatus_ReportsAKnownMode()
    {
        // CollectStatus reads the *effective* scheme — it may differ from the selected
        // one, but it must always resolve to a recognised overlay (never Unknown).
        var status = _service.CollectStatus();

        Assert.NotEqual(PowerModeType.Unknown, status.PowerMode);
    }

    /// <summary>
    /// Polls the actual (selected) overlay scheme until it matches
    /// <paramref name="expected"/> or the timeout elapses. The OS can take a brief
    /// moment to propagate the change, so a tight poll avoids flakiness from an
    /// immediate read-back.
    /// </summary>
    private PowerModeType WaitForActiveMode(PowerModeType expected, int timeoutMs = 3000)
    {
        var sw = Stopwatch.StartNew();
        PowerModeType current;
        do
        {
            current = _service.GetActivePowerMode();
            if (current == expected)
                return current;
            Thread.Sleep(50);
        }
        while (sw.ElapsedMilliseconds < timeoutMs);

        return current; // returns last-seen value so the assert produces a useful diff
    }
}

/// <summary>
/// Defines a non-parallel collection so power-mode tests never run concurrently —
/// they all mutate the same global Windows power overlay.
/// </summary>
[CollectionDefinition("PowerMode", DisableParallelization = true)]
public sealed class PowerModeCollection;
