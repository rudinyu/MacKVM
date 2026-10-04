namespace WindowsKVM;

internal readonly record struct WindowsTrayReadiness(string Summary, bool IsReady);

/// <summary>State policy shared by the native tray UI and platform-neutral tests.</summary>
internal static class WindowsTrayRuntimePolicy
{
    public static WindowsTrayReadiness Readiness(
        bool remoteInputEnabled,
        bool runtimeStarted,
        bool runtimeFailed,
        bool pairingReady,
        bool secureReady
    )
    {
        if (!remoteInputEnabled)
        {
            return new("Local-only • remote control disabled", false);
        }
        if (runtimeFailed)
        {
            return new("Receiver unavailable • remote control not ready", false);
        }
        if (!runtimeStarted)
        {
            return new("Starting receiver • remote control not ready", false);
        }
        if (!pairingReady)
        {
            return new("Pairing unavailable • check receiver status", false);
        }
        if (!secureReady)
        {
            return new("Secure Connect unavailable • remote control not ready", false);
        }
        return new("Listeners active • LAN access not yet verified", true);
    }

    public static bool ShouldRestoreTray(
        uint message,
        uint taskbarCreatedMessage,
        bool isMainWindow,
        bool disposed
    ) => taskbarCreatedMessage != 0
        && message == taskbarCreatedMessage
        && isMainWindow
        && !disposed;

    // ADD fails when an icon with the same HWND/ID already exists. MODIFY
    // makes repeated TaskbarCreated delivery idempotent without deleting a
    // working entry, and retains the legacy callback contract.
    public static bool EnsureTrayIcon(Func<bool> add, Func<bool> modify)
        => add() || modify();
}
