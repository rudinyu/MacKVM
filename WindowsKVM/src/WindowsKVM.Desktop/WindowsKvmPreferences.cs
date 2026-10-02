using System.Security;
using Microsoft.Win32;

namespace WindowsKVM;

/// <summary>
/// Non-secret per-user preferences for the Windows receiver. Trust keys and
/// peer approvals remain in the separate DPAPI-protected trust store.
/// </summary>
internal static class WindowsKvmPreferences
{
    private const string RegistryPath = @"Software\MacKVM";
    private const string RemoteInputValue = "RemoteInputEnabled";

    public static bool LoadRemoteInputEnabled()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(RegistryPath);
            return key?.GetValue(RemoteInputValue) switch
            {
                int value => value != 0,
                _ => true
            };
        }
        catch (Exception ex) when (
            ex is IOException or UnauthorizedAccessException or SecurityException
        )
        {
            // A preference-store failure must not prevent the receiver from
            // starting. The first-run default remains the existing behavior.
            return true;
        }
    }

    public static void SaveRemoteInputEnabled(bool enabled)
    {
        try
        {
            using var key = Registry.CurrentUser.CreateSubKey(RegistryPath);
            key?.SetValue(
                RemoteInputValue,
                enabled ? 1 : 0,
                RegistryValueKind.DWord
            );
        }
        catch (Exception ex) when (
            ex is IOException or UnauthorizedAccessException or SecurityException
        )
        {
            // The live choice still takes effect. A later launch will use the
            // safe first-run default if Windows could not persist it.
        }
    }
}
