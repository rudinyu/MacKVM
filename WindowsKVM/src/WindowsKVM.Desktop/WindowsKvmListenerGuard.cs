using System.Security.Principal;

namespace WindowsKVM;

/// <summary>
/// Process-wide listener lease shared by the resident UI and console host.
/// The lease is a per-user file opened with FileShare.None. Unlike a named
/// Mutex, a FileStream can be released from any async continuation, and the
/// operating system closes it automatically if the process exits.
/// </summary>
internal sealed class WindowsKvmListenerGuard : IDisposable
{
    private const string LeaseFilePrefix = "MacKVM.WindowsKVM.Listener.";
    private readonly FileStream lease;
    private int disposed;

    private WindowsKvmListenerGuard(FileStream lease)
    {
        this.lease = lease;
    }

    public static WindowsKvmListenerGuard Acquire(
        string? userScope = null,
        string? rootDirectory = null
    )
    {
        var scope = SanitizeScope(userScope ?? CurrentUserScope());
        var directory = rootDirectory ?? ResolveLeaseDirectory();
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, LeaseFilePrefix + scope + ".lock");

        try
        {
            // Keep this handle open for the lifetime of the runtime. The file
            // is intentionally never deleted: opening it with FileShare.None
            // makes acquisition atomic and avoids a delete/recreate race.
            var lease = new FileStream(
                path,
                FileMode.OpenOrCreate,
                FileAccess.ReadWrite,
                FileShare.None,
                bufferSize: 1,
                options: FileOptions.None
            );
            return new WindowsKvmListenerGuard(lease);
        }
        catch (IOException ex)
        {
            throw new InvalidOperationException(
                "WindowsKVM is already running for this Windows account, "
                    + "or its listener lease is unavailable. Close the resident "
                    + "UI or console receiver first.",
                ex
            );
        }
    }

    public void Dispose()
    {
        if (Interlocked.Exchange(ref disposed, 1) != 0)
        {
            return;
        }

        // FileStream disposal is not tied to the thread that acquired the
        // lease, which is required when IAsyncDisposable resumes elsewhere.
        lease.Dispose();
    }

    private static string ResolveLeaseDirectory()
    {
        var localData = Environment.GetFolderPath(
            Environment.SpecialFolder.LocalApplicationData,
            Environment.SpecialFolderOption.Create
        );
        if (string.IsNullOrWhiteSpace(localData))
        {
            localData = Path.GetTempPath();
        }

        return Path.Combine(localData, "MacKVM");
    }

    private static string CurrentUserScope()
    {
        if (!OperatingSystem.IsWindows())
        {
            return Environment.UserName;
        }

        try
        {
            return WindowsIdentity.GetCurrent().User?.Value
                ?? Environment.UserName;
        }
        catch (PlatformNotSupportedException)
        {
            // Keeps the production-path self-test runnable on macOS while
            // Windows uses the stable SID rather than a display name.
            return Environment.UserName;
        }
    }

    private static string SanitizeScope(string scope)
    {
        if (string.IsNullOrWhiteSpace(scope))
        {
            return "unknown-user";
        }

        var sanitized = new string(
            scope.Select(character =>
                char.IsLetterOrDigit(character) || character is '-' or '_' or '.'
                    ? character
                    : '_')
                .ToArray()
        );
        return sanitized.Length == 0 ? "unknown-user" : sanitized;
    }
}
