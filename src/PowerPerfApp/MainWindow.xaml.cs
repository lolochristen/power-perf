using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using System;
using System.Runtime.InteropServices;
using System.Windows.Input;
using Windows.Foundation;
using Windows.UI;
using ArcSeg = Microsoft.UI.Xaml.Media.ArcSegment;

namespace PowerPerfApp;

public sealed partial class MainWindow : Window
{
    // ── gauge geometry ──────────────────────────────────────────────────────────
    // Arc sweeps 270° clockwise from lower-left (135°) through top to lower-right (405°=45°).
    private const double Cx = 150, Cy = 160, Radius = 115;
    private const double TrackStart = 135, TotalSweep = 270;
    private const double StrokeW = 18;

    // ── colors ──────────────────────────────────────────────────────────────────
    private static readonly Color ColTrack     = Color.FromArgb(45,  255, 255, 255);
    private static readonly Color ColNormal    = Color.FromArgb(255,  76, 175,  80); // green
    private static readonly Color ColThrottled = Color.FromArgb(255, 255, 152,   0); // orange
    private static readonly Color ColBoosting  = Color.FromArgb(255,  41, 182, 246); // cyan-blue
    private static readonly Color ColTick      = Color.FromArgb(200, 255, 255, 255);

    // ── state ───────────────────────────────────────────────────────────────────
    private readonly PowerPerfService _service = new();
    private bool _prevIsToggling;
    private DateTime _lastBoostDoneAt = DateTime.MinValue;
    private bool _isExiting;
    private const int BoostDoneShowSec = 10;

    public MainWindow()
    {
        // Load persisted threshold
        _service.ThresholdGHz = AppSettings.ThresholdGHz;

        InitializeComponent();

        ResizeWindow(540, 880);
        ExtendsContentIntoTitleBar = true;

        this.Closed += OnWindowClosed;
        TrayIcon.LeftClickCommand = new RelayCommand(ShowWindow);

        HideWindowImmediate();

        ThresholdText.Text    = FormatThreshold(_service.ThresholdGHz);

        // Query CPU max GHz on a background thread, then set slider bounds + value.
        _ = System.Threading.Tasks.Task.Run(() =>
        {
            double maxGHz = _service.GetMaxClockGHz();
            DispatcherQueue.TryEnqueue(() =>
            {
                ThresholdSlider.Maximum = maxGHz;
                ThresholdSlider.Value   = Math.Min(_service.ThresholdGHz, maxGHz);
            });
        });

        _service.StatusChanged += OnStatusChanged;
        _service.StartMonitoring();
        ThresholdSlider.ValueChanged += ThresholdSlider_ValueChanged;
    }

    // ── tray menu ───────────────────────────────────────────────────────────────

    private void ShowWindow()
    {
        NativeMethods.ShowWindow(WindowHandle, NativeMethods.SW_SHOW);
        Activate();
    }

    private void ExitMenuItem_Click(object sender, RoutedEventArgs e)
    {
        _isExiting = true;
        _service.Dispose();
        Application.Current.Exit();
    }

    private void OnWindowClosed(object sender, WindowEventArgs e)
    {
        if (!_isExiting)
        {
            e.Handled = true; // suppress close — hide instead
            HideWindowImmediate();
        }
    }

    // ── status update ────────────────────────────────────────────────────────────

    private void OnStatusChanged(PowerStatus status)
    {
        DispatcherQueue.TryEnqueue(() =>
        {
            // This lambda runs on the UI thread, OUTSIDE the monitor loop's try/catch.
            // After sleep/resume the notification area and XAML/tray COM objects can be
            // transiently invalid, so updating the tray tooltip or visuals may throw an
            // InvalidOperationException. An unhandled throw here crashes the whole
            // process (fault in combase.dll), so the UI update must be guarded.
            try
            {
                // Detect boost completion
                if (_prevIsToggling && !status.IsToggling)
                    _lastBoostDoneAt = DateTime.UtcNow;
                _prevIsToggling = status.IsToggling;

                UpdateGauge(status);
                UpdateCards(status);
                TrayIcon.ToolTipText = BuildTooltip(status);
            }
            catch
            {
                // Transient post-resume failure — skip this tick; the next one recovers.
            }
        });
    }

    // ── gauge drawing ────────────────────────────────────────────────────────────

    private void UpdateGauge(PowerStatus status)
    {
        GaugeCanvas.Children.Clear();

        double ratio = status.MaxGHz > 0
            ? Math.Clamp(status.EffectiveGHz / status.MaxGHz, 0, 1)
            : 0;
        double thresholdRatio = status.MaxGHz > 0
            ? Math.Clamp(_service.ThresholdGHz / status.MaxGHz, 0, 1)
            : 0;

        // Background track
        DrawArc(ColTrack, TrackStart, TotalSweep, StrokeW);

        // Value arc
        Color arcColor = status.IsToggling ? ColBoosting
            : status.EffectiveGHz < _service.ThresholdGHz ? ColThrottled
            : ColNormal;

        if (ratio > 0.005)
            DrawArc(arcColor, TrackStart, ratio * TotalSweep, StrokeW);

        // Threshold tick mark
        DrawTick(TrackStart + thresholdRatio * TotalSweep, ColTick);

        // Centre text
        GhzValueText.Text = status.MaxGHz > 0 ? $"{status.EffectiveGHz:F2}" : "—";
        GhzSubText.Text = status.MaxGHz > 0 ? $"/ {status.MaxGHz:F2} GHz" : "GHz";

        // Boost spinner
        BoostRing.Visibility = status.IsToggling ? Visibility.Visible : Visibility.Collapsed;
    }

    private void DrawArc(Color color, double startDeg, double sweepDeg, double thickness)
    {
        if (Math.Abs(sweepDeg) < 0.5) return;

        var start = ArcPoint(startDeg);
        var end   = ArcPoint(startDeg + sweepDeg);

        var seg = new ArcSeg
        {
            Point            = end,
            Size             = new Size(Radius, Radius),
            SweepDirection   = SweepDirection.Clockwise,
            IsLargeArc       = sweepDeg > 180
        };

        var fig = new PathFigure { StartPoint = start, IsClosed = false };
        fig.Segments.Add(seg);

        var geo = new PathGeometry();
        geo.Figures.Add(fig);

        GaugeCanvas.Children.Add(new Path
        {
            Data                = geo,
            Stroke              = new SolidColorBrush(color),
            StrokeThickness     = thickness,
            StrokeStartLineCap  = PenLineCap.Round,
            StrokeEndLineCap    = PenLineCap.Round
        });
    }

    private void DrawTick(double angleDeg, Color color)
    {
        double rad   = angleDeg * Math.PI / 180.0;
        double cos   = Math.Cos(rad);
        double sin   = Math.Sin(rad);
        double inner = Radius - StrokeW / 2 - 2;
        double outer = Radius + StrokeW / 2 + 2;

        GaugeCanvas.Children.Add(new Line
        {
            X1              = Cx + inner * cos,
            Y1              = Cy + inner * sin,
            X2              = Cx + outer * cos,
            Y2              = Cy + outer * sin,
            Stroke          = new SolidColorBrush(color),
            StrokeThickness = 2.5
        });
    }

    private static Point ArcPoint(double deg)
    {
        double rad = deg * Math.PI / 180.0;
        return new Point(Cx + Radius * Math.Cos(rad), Cy + Radius * Math.Sin(rad));
    }

    // ── info cards ───────────────────────────────────────────────────────────────

    private void UpdateCards(PowerStatus status)
    {
        // Power source badge
        bool isAc = status.IsOnAc;
        SourceIcon.Glyph = isAc ? "" : ""; // plug / battery
        SourceText.Text  = isAc ? "AC" : $"Battery {status.BatteryPercent}%";

        // Power mode
        PowerModeText.Text = status.PowerMode switch
        {
            PowerModeType.BestPerformance      => "Best Performance",
            PowerModeType.BestPowerEfficiency  => "Best Efficiency",
            PowerModeType.Balanced             => "Balanced",
            _                                  => "Unknown"
        };

        // CPU detail
        CpuDetailText.Text = status.MaxGHz > 0
            ? $"{status.EffectiveGHz:F2} / {status.MaxGHz:F2} GHz"
            : "—";

        // Boost done notification
        double secSince = (DateTime.UtcNow - _lastBoostDoneAt).TotalSeconds;
        bool showBoost  = secSince < BoostDoneShowSec && _lastBoostDoneAt != DateTime.MinValue;
        BoostDonePanel.Visibility = showBoost ? Visibility.Visible : Visibility.Collapsed;
        if (showBoost)
            BoostTimeText.Text = $"{(int)secSince}s ago";
    }

    // ── threshold slider ─────────────────────────────────────────────────────────

    private void ThresholdSlider_ValueChanged(object sender,
        Microsoft.UI.Xaml.Controls.Primitives.RangeBaseValueChangedEventArgs e)
    {
        double val = Math.Round(e.NewValue, 1);
        _service.ThresholdGHz = val;
        AppSettings.ThresholdGHz = val;
        ThresholdText.Text = FormatThreshold(val);
    }

    private static string FormatThreshold(double ghz) => $"{ghz:F1} GHz";

    // ── tooltip ──────────────────────────────────────────────────────────────────

    private static string BuildTooltip(PowerStatus status)
    {
        var src     = status.IsOnAc ? "AC" : $"Battery {status.BatteryPercent}%";
        var mode    = status.PowerMode switch
        {
            PowerModeType.BestPerformance     => "Best Performance",
            PowerModeType.BestPowerEfficiency => "Best Efficiency",
            PowerModeType.Balanced            => "Balanced",
            _                                 => "Unknown"
        };
        var flag = status.IsToggling ? " ⚡" : "";
        return $"PowerPerf{flag}\n{src} | {mode}\nCPU {status.EffectiveGHz:F2} / {status.MaxGHz:F2} GHz";
    }

    // ── helpers ──────────────────────────────────────────────────────────────────

    private IntPtr WindowHandle => WinRT.Interop.WindowNative.GetWindowHandle(this);

    private void HideWindowImmediate() =>
        NativeMethods.ShowWindow(WindowHandle, NativeMethods.SW_HIDE);

    private void ResizeWindow(int width, int height) =>
        AppWindow.Resize(new Windows.Graphics.SizeInt32(width, height));
}

file static class NativeMethods
{
    internal const int SW_HIDE = 0;
    internal const int SW_SHOW = 5;

    [DllImport("user32.dll")]
    internal static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
}

file sealed class RelayCommand(Action execute) : ICommand
{
    public bool CanExecute(object? parameter) => true;
    public void Execute(object? parameter) => execute();
#pragma warning disable CS0067
    public event EventHandler? CanExecuteChanged;
#pragma warning restore CS0067
}
