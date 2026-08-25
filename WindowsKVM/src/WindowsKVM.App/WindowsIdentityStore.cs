using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.Json;
using WindowsKVM.Protocol;

namespace WindowsKVM;

/// <summary>
/// Stores the Windows peer identity under the current user's LocalAppData.
/// The P-256 private key is protected with Windows DPAPI and is never written
/// as plaintext. This is deliberately separate from the protocol project so
/// protocol tests remain runnable on macOS/Linux.
/// </summary>
internal static class WindowsIdentityStore
{
    private const string ApplicationDirectory = "MacKVM";
    private const string IdentityFileName = "identity.json";
    // A named mutex is required in addition to the temporary-file rename:
    // two first-run processes could otherwise both observe a missing file,
    // keep different credentials in memory, and let the last rename win.
    // The Local namespace scopes the lock to this interactive Windows session
    // while still coordinating independently launched copies of the app.
    private const string IdentityCreationMutexName = @"Local\MacKVM.IdentityCreation";

    public static DeviceCredentials LoadOrCreate(string requestedName)
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException("Windows DPAPI is required for the Windows identity store.");
        }

        var directory = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            ApplicationDirectory
        );
        var path = Path.Combine(directory, IdentityFileName);
        using var creationMutex = new Mutex(
            initiallyOwned: false,
            name: IdentityCreationMutexName
        );
        var ownsCreationMutex = false;
        try
        {
            try
            {
                creationMutex.WaitOne();
                ownsCreationMutex = true;
            }
            catch (AbandonedMutexException)
            {
                // An abandoned mutex is still owned by this process after
                // WaitOne throws, so the serialized first-run path is safe.
                ownsCreationMutex = true;
            }

            if (File.Exists(path))
            {
                try
                {
                    return Load(path);
                }
                catch (Exception ex) when (ex is ArgumentNullException
                    or CryptographicException
                    or FormatException
                    or JsonException
                    or IOException
                    or InvalidDataException)
                {
                    // A persisted identity may already be pinned by a Mac
                    // peer. Never replace it implicitly after a decrypt,
                    // parse, or key mismatch: that would strand the old
                    // pairing and silently change this machine's security
                    // identity. Require the user to move the file aside
                    // deliberately after forgetting the old peer everywhere.
                    throw new InvalidDataException(
                        "The saved Windows identity is invalid or cannot be decrypted. "
                            + "Forget the old Windows peer on paired Macs, then explicitly remove "
                            + $"'{path}' before pairing again.",
                        ex
                    );
                }
            }

            var credentials = DeviceCredentials.Create(requestedName);
            Save(path, credentials);
            return credentials;
        }
        finally
        {
            if (ownsCreationMutex)
            {
                creationMutex.ReleaseMutex();
            }
        }
    }

    private static DeviceCredentials Load(string path)
    {
        var document = JsonSerializer.Deserialize<StoredIdentity>(
            File.ReadAllBytes(path)
        ) ?? throw new InvalidDataException("Identity file is empty.");
        var privateKeyBytes = Unprotect(Convert.FromBase64String(document.ProtectedPrivateKey));
        using var imported = ECDsa.Create();
        imported.ImportPkcs8PrivateKey(privateKeyBytes, out _);
        var parameters = imported.ExportParameters(includePrivateParameters: false);
        var publicKey = PairingCryptoAccess.ToX963(parameters.Q);
        var storedPublicKey = Convert.FromBase64String(document.SigningPublicKey);
        if (!CryptographicOperations.FixedTimeEquals(publicKey, storedPublicKey))
        {
            throw new CryptographicException("The saved identity key does not match its private key.");
        }

        var retained = ECDsa.Create();
        retained.ImportPkcs8PrivateKey(privateKeyBytes, out _);
        return DeviceCredentialsAccess.FromStored(
            new PeerIdentity(document.Id, document.Name, storedPublicKey),
            retained
        );
    }

    private static void Save(string path, DeviceCredentials credentials)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var privateKey = credentials.PrivateKey.ExportPkcs8PrivateKey();
        var stored = new StoredIdentity(
            credentials.Identity.Id,
            credentials.Identity.Name,
            Convert.ToBase64String(credentials.Identity.SigningPublicKey),
            Convert.ToBase64String(Protect(privateKey))
        );
        var temporary = path + $".{Environment.ProcessId}.tmp";
        File.WriteAllBytes(temporary, JsonSerializer.SerializeToUtf8Bytes(stored));
        File.Move(temporary, path, overwrite: true);
    }

    private static byte[] Protect(byte[] value)
        => Dpapi.Protect(value);

    private static byte[] Unprotect(byte[] value)
        => Dpapi.Unprotect(value);

    private sealed record StoredIdentity(
        Guid Id,
        string Name,
        string SigningPublicKey,
        string ProtectedPrivateKey
    );
}

/// <summary>Small bridge for the protocol assembly's intentionally private key constructor.</summary>
internal static class DeviceCredentialsAccess
{
    public static DeviceCredentials FromStored(PeerIdentity identity, ECDsa privateKey)
        => DeviceCredentials.FromStored(identity, privateKey);
}

internal static class PairingCryptoAccess
{
    public static byte[] ToX963(ECPoint point)
    {
        if (point.X is null || point.Y is null
            || point.X.Length != 32 || point.Y.Length != 32)
        {
            throw new CryptographicException("Expected a P-256 public key.");
        }

        return [0x04, .. point.X, .. point.Y];
    }
}

internal static class Dpapi
{
    [StructLayout(LayoutKind.Sequential)]
    private struct DataBlob
    {
        public int Length;
        public IntPtr Data;
    }

    [DllImport("crypt32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool CryptProtectData(
        ref DataBlob dataIn,
        IntPtr description,
        IntPtr optionalEntropy,
        IntPtr reserved,
        IntPtr prompt,
        int flags,
        out DataBlob dataOut
    );

    [DllImport("crypt32.dll", SetLastError = true)]
    private static extern bool CryptUnprotectData(
        ref DataBlob dataIn,
        IntPtr description,
        IntPtr optionalEntropy,
        IntPtr reserved,
        IntPtr prompt,
        int flags,
        out DataBlob dataOut
    );

    [DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr memory);

    public static byte[] Protect(byte[] value)
        => Transform(value, CryptProtectData);

    public static byte[] Unprotect(byte[] value)
        => Transform(value, CryptUnprotectData);

    private delegate bool ProtectDelegate(
        ref DataBlob input,
        IntPtr description,
        IntPtr entropy,
        IntPtr reserved,
        IntPtr prompt,
        int flags,
        out DataBlob output
    );

    private static byte[] Transform(byte[] value, ProtectDelegate transform)
    {
        var input = new DataBlob
        {
            Length = value.Length,
            Data = Marshal.AllocHGlobal(value.Length)
        };
        try
        {
            Marshal.Copy(value, 0, input.Data, value.Length);
            if (!transform(
                    ref input,
                    IntPtr.Zero,
                    IntPtr.Zero,
                    IntPtr.Zero,
                    IntPtr.Zero,
                    0,
                    out var output
                ))
            {
                throw new CryptographicException(Marshal.GetLastWin32Error());
            }

            try
            {
                var result = new byte[output.Length];
                Marshal.Copy(output.Data, result, 0, result.Length);
                return result;
            }
            finally
            {
                LocalFree(output.Data);
            }
        }
        finally
        {
            Marshal.FreeHGlobal(input.Data);
        }
    }
}
