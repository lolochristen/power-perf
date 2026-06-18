using System.Diagnostics;
using Microsoft.UI.Xaml;

namespace PowerPerfApp;

public partial class App : Application
{
    private MainWindow? _window;

    public App()
    {
        InitializeComponent();

        // Last-resort safety net: a long-running tray app should survive transient
        // failures (e.g. XAML/tray COM objects briefly invalid right after a
        // sleep/resume) rather than crash. Mark such exceptions handled so the
        // process keeps running.
        UnhandledException += OnUnhandledException;
    }

    private static void OnUnhandledException(object sender,
        Microsoft.UI.Xaml.UnhandledExceptionEventArgs e)
    {
        Debug.WriteLine($"[PowerPerf] Unhandled exception suppressed: {e.Exception}");
        e.Handled = true;
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        _window = new MainWindow();
        // Do not call Activate() — app lives exclusively in the system tray.
    }
}
