using System.Security.Cryptography;
using WindowsKVM.Protocol;

namespace WindowsKVM;

/// <summary>
/// Windows desktop and console entry point. Pairing, authenticated Connect,
/// Windows SendInput, and the emergency local-release shortcut run together.
/// </summary>
internal static class Program
{
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
                $"WindowsKVM {WindowsKvmRuntime.ApplicationVersion} "
                    + $"(build {WindowsKvmRuntime.ApplicationBuild})"
            );
            return 0;
        }

        if (args.Contains("--list-paired", StringComparer.OrdinalIgnoreCase))
        {
            return ListPairedPeers();
        }

        if (args.Contains("--forget", StringComparer.OrdinalIgnoreCase))
        {
            var peerIDText = ReadOption(args, "--forget");
            if (!Guid.TryParse(peerIDText, out var peerID))
            {
                Console.Error.WriteLine(
                    "--forget requires a complete peer UUID. Run --list-paired first."
                );
                return 2;
            }

            return ForgetPairedPeer(peerID);
        }

        var allowControl = args.Contains(
            "--allow-control",
            StringComparer.OrdinalIgnoreCase
        );
        var denyControl = args.Contains(
            "--deny-control",
            StringComparer.OrdinalIgnoreCase
        );
        if (allowControl || denyControl)
        {
            if (allowControl && denyControl)
            {
                Console.Error.WriteLine(
                    "Use only one of --allow-control or --deny-control."
                );
                return 2;
            }

            var option = allowControl ? "--allow-control" : "--deny-control";
            var peerIDText = ReadOption(args, option);
            if (!Guid.TryParse(peerIDText, out var peerID))
            {
                Console.Error.WriteLine(
                    $"{option} requires a complete peer UUID. Run --list-paired first."
                );
                return 2;
            }

            return SetControlAuthorization(peerID, authorized: allowControl);
        }

        if (args.Length == 0 || args.Contains("--ui", StringComparer.OrdinalIgnoreCase))
        {
            return WindowsTrayApplication.Run();
        }

        if (!args.Contains("--pairing-listen", StringComparer.OrdinalIgnoreCase))
        {
            Console.WriteLine(
                $"WindowsKVM {WindowsKvmRuntime.ApplicationVersion} "
                    + $"(build {WindowsKvmRuntime.ApplicationBuild}); "
                    + $"W3 secure-session receiver; protocol v{ControlProtocolCompatibility.CurrentVersion}."
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
            await using var runtime = new WindowsKvmRuntime(
                name,
                autoAccept,
                enableConsoleInput: true,
                pairingPort: port
            );
            // The runtime owns listener and advertiser shutdown. Console mode
            // only supplies the lifecycle wait; consent remains the shared
            // receiver prompt so pairing and control cannot race stdin.
            runtime.Start();
            if (!runtime.SecureConnectAvailable)
            {
                Console.Error.WriteLine(
                    "Secure Connect is disabled on this Windows build; "
                        + $"Windows build {SecureSessionCapabilities.MinimumWindowsBuild} "
                        + "or later is required for ChaCha20-Poly1305. Pairing remains available."
                );
            }
            await runtime.WaitForShutdownAsync(CancellationToken.None);
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

    private static int ListPairedPeers()
    {
        try
        {
            var peers = WindowsTrustStore.Load().Snapshot();
            if (peers.Count == 0)
            {
                Console.WriteLine("No paired Macs are stored on this Windows account.");
                return 0;
            }

            foreach (var peer in peers)
            {
                Console.WriteLine(
                    $"{peer.Name}\t{peer.Id:D}\t{Fingerprint(peer.SigningPublicKey)}"
                );
            }

            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"Could not read paired Macs: {ex.Message}");
            return 1;
        }
    }

    private static int ForgetPairedPeer(Guid peerID)
    {
        try
        {
            var store = WindowsTrustStore.Load();
            var peer = store.Snapshot().FirstOrDefault(candidate => candidate.Id == peerID);
            if (!store.Remove(peerID))
            {
                Console.Error.WriteLine(
                    $"No paired Mac with ID {peerID:D} is stored on this Windows account."
                );
                return 1;
            }

            Console.WriteLine(
                $"Forgot paired Mac {peer?.Name ?? peerID.ToString("D")}. "
                    + "Pair again from MacKVM before connecting."
            );
            Console.WriteLine(
                "If another WindowsKVM receiver is already running, restart it "
                    + "or use its UI Forget action to revoke an active session."
            );
            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"Could not forget paired Mac: {ex.Message}");
            return 1;
        }
    }

    private static int SetControlAuthorization(Guid peerID, bool authorized)
    {
        try
        {
            var store = WindowsTrustStore.Load();
            var peer = store.Snapshot().FirstOrDefault(candidate => candidate.Id == peerID);
            if (!store.SetControlAuthorization(peerID, authorized))
            {
                Console.Error.WriteLine(
                    $"No paired Mac with ID {peerID:D} is stored on this Windows account."
                );
                return 1;
            }

            Console.WriteLine(
                authorized
                    ? $"Automatic control approval enabled for {peer?.Name ?? peerID.ToString("D")}."
                    : $"Automatic control approval disabled for {peer?.Name ?? peerID.ToString("D")}; confirmation is required."
            );
            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine(
                $"Could not update automatic control approval: {ex.Message}"
            );
            return 1;
        }
    }

    private static string Fingerprint(byte[] publicKey)
        => string.Join(
            ":",
            SHA256.HashData(publicKey)
                .Select(value => value.ToString("X2"))
        );

    private static void PrintUsage()
    {
        Console.WriteLine("Usage:");
        Console.WriteLine("  WindowsKVM.exe                 Start the resident Windows UI and tray icon.");
        Console.WriteLine("  WindowsKVM.exe --ui             Start the resident Windows UI and tray icon.");
        Console.WriteLine("  WindowsKVM.exe --pairing-listen [--name <name>] [--port <port>] [--yes]");
        Console.WriteLine("  WindowsKVM.exe --list-paired");
        Console.WriteLine("  WindowsKVM.exe --forget <peer-id>");
        Console.WriteLine("  WindowsKVM.exe --allow-control <peer-id>");
        Console.WriteLine("  WindowsKVM.exe --deny-control <peer-id>");
        Console.WriteLine("  WindowsKVM.exe --version");
        Console.WriteLine();
        Console.WriteLine(
            "  --pairing-listen  Advertise signed pairing and secure Connect listeners."
        );
        Console.WriteLine("  --name            Display name stored in the Windows identity (first run only).");
        Console.WriteLine("  --port            TCP port; 0 selects an available port (default).");
        Console.WriteLine(
            "  --yes             Auto-accept pairing and control requests (test-only convenience)."
        );
        Console.WriteLine(
            "  --list-paired     List trusted Mac IDs and public-key fingerprints."
        );
        Console.WriteLine(
            "  --forget          Remove one trusted Mac ID; pair again before connecting."
        );
        Console.WriteLine(
            "  --allow-control   Remember control approval for one trusted Mac."
        );
        Console.WriteLine(
            "  --deny-control    Require confirmation for one trusted Mac again."
        );
        Console.WriteLine("  --version         Print the WindowsKVM application version and build.");
        Console.WriteLine();
        Console.WriteLine(
            "W3 secure Connect receives authenticated Mac input via SendInput."
        );
        Console.WriteLine(
            "  Ctrl+Alt+Shift+Esc returns keyboard/mouse control to Windows."
        );
    }
}
