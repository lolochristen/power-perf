using Windows.Storage;

namespace PowerPerfApp;

internal static class AppSettings
{
    private const string KeyThreshold = "ThresholdGHz";

    public static double ThresholdGHz
    {
        get
        {
            var raw = ApplicationData.Current.LocalSettings.Values[KeyThreshold];
            return raw is double d ? d : PowerPerfService.FallbackThresholdGHz;
        }
        set => ApplicationData.Current.LocalSettings.Values[KeyThreshold] = value;
    }
}
