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
            var value = key?.GetValue(RemoteInputValue);
            return ResolveRemoteInputEnabled(value is not null, value);
        }
        catch (Exception ex) when (
            ex is IOException or UnauthorizedAccessException or SecurityException
        )
        {
            // A failed read must never silently override a prior local-only
            // decision by enabling remote input.
            return false;
        }
    }

    public static bool ResolveRemoteInputEnabled(bool hasValue, object? value)
    {
        if (!hasValue)
        {
            return true;
        }

        return value is int storedValue && storedValue != 0;
    }

    public static bool SaveRemoteInputEnabled(bool enabled)
    {
        try
        {
            using var key = Registry.CurrentUser.CreateSubKey(RegistryPath);
            if (key is null)
            {
                return false;
            }
            key.SetValue(
                RemoteInputValue,
                enabled ? 1 : 0,
                RegistryValueKind.DWord
            );
            return true;
        }
        catch (Exception ex) when (
            ex is IOException or UnauthorizedAccessException or SecurityException
        )
        {
            // Let the UI report that this choice will not survive restart.
            return false;
        }
    }
}
