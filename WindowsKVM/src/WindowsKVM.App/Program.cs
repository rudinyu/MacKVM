using WindowsKVM.Protocol;
using System.Runtime.InteropServices;

namespace WindowsKVM;

/// <summary>
/// W2 console entry point. Pairing and the authenticated secure-session
/// responder run together; privileged Raw Input/SendInput code is a later
/// Windows feature step.
/// </summary>
internal static class Program
{
    private const string ApplicationVersion = "1.01.02";
    private const string ApplicationBuild = "79";

    private static async Task<int> Main(string[] args)
    {
        if (!OperatingSystem.IsWindows())
        {
            Console.Error.WriteLine("WindowsKVM must run on Windows.");
            return 2;
        }

        if (args.Contains("--help", StringComparer.OrdinalIgnoreCase)
            || args.Contains("-h", StringComparer.OrdinalIgnoreCase))
        {
            PrintUsage();
            return 0;
        }

        if (args.Contains("--version", StringComparer.OrdinalIgnoreCase))
        {
            Console.WriteLine(
                $"WindowsKVM {ApplicationVersion} (build {ApplicationBuild})"
            );
            return 0;
        }

        if (!args.Contains("--pairing-listen", StringComparer.OrdinalIgnoreCase))
        {
            Console.WriteLine(
                $"WindowsKVM {ApplicationVersion} (build {ApplicationBuild}); "
                    + $"W2 secure-session receiver; protocol v{ControlProtocolCompatibility.CurrentVersion}."
            );
            Console.WriteLine(
                "Run with --pairing-listen to advertise pairing and secure Connect services."
            );
            PrintUsage();
            return 0;
        }

        var name = ReadOption(args, "--name")
            ?? Environment.MachineName;
        var portText = ReadOption(args, "--port");
        if (!int.TryParse(portText ?? "0", out var port) || port is < 0 or > 65_535)
        {
            Console.Error.WriteLine("--port must be an integer between 0 and 65535.");
            return 2;
        }

        var autoAccept = args.Contains("--yes", StringComparer.OrdinalIgnoreCase);
        try
        {
            using var credentials = WindowsIdentityStore.LoadOrCreate(name);
            var trustStore = WindowsTrustStore.Load();
            var model = RuntimeInformation.OSArchitecture == Architecture.Arm64
                ? "Windows ARM64"
                : "Windows x64";
            // ECDsa instances are not used concurrently. Both pairing and
            // secure-session responders share this short critical section.
            var signingLock = new object();
            await using var secureReceiver = SecureSessionCapabilities
                .ChaCha20Poly1305Supported
                ? new SecureSessionTcpReceiver(
                    credentials,
                    trustStore,
                    model,
                    signingLock: signingLock
                )
                : null;
            if (secureReceiver is null)
            {
                Console.Error.WriteLine(
                    "Secure Connect is disabled on this Windows build; "
                        + $"Windows build {SecureSessionCapabilities.MinimumWindowsBuild} "
                        + "or later is required for ChaCha20-Poly1305. Pairing remains available."
                );
            }
            else
            {
                secureReceiver.Start();
            }
            await using var receiver = new PairingTcpReceiver(
                credentials,
                model,
                port,
                autoAccept,
                trustStore.Record,
                signingLock
            );
            var pairingTask = receiver.RunAsync();
            if (secureReceiver is not null)
            {
                var completed = await Task.WhenAny(pairingTask, secureReceiver.Failure);
                if (completed == secureReceiver.Failure)
                {
                    await secureReceiver.Failure;
                }
                else
                {
                    // Do not turn an unexpected pairing-listener failure into
                    // a successful process exit while the secure listener is
                    // still shutting down.
                    await pairingTask;
                }
            }
            else
            {
                await pairingTask;
            }
            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"WindowsKVM pairing receiver failed: {ex.Message}");
            return 1;
        }
    }

    private static string? ReadOption(string[] args, string option)
    {
        var index = Array.FindIndex(
            args,
            value => string.Equals(value, option, StringComparison.OrdinalIgnoreCase)
        );
        return index >= 0 && index + 1 < args.Length ? args[index + 1] : null;
    }

    private static void PrintUsage()
    {
        Console.WriteLine("Usage:");
        Console.WriteLine("  WindowsKVM.exe --pairing-listen [--name <name>] [--port <port>] [--yes]");
        Console.WriteLine("  WindowsKVM.exe --version");
        Console.WriteLine();
        Console.WriteLine(
            "  --pairing-listen  Advertise signed pairing and secure Connect listeners."
        );
        Console.WriteLine("  --name            Display name stored in the Windows identity (first run only).");
        Console.WriteLine("  --port            TCP port; 0 selects an available port (default).");
        Console.WriteLine("  --yes             Auto-accept the verification code (test-only convenience).");
        Console.WriteLine("  --version         Print the WindowsKVM application version and build.");
        Console.WriteLine();
        Console.WriteLine(
            "W2 secure Connect is implemented; Windows keyboard/mouse control is not enabled yet."
        );
    }
}
