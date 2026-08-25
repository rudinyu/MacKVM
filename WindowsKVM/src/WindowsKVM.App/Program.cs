using WindowsKVM.Protocol;
using System.Runtime.InteropServices;

namespace WindowsKVM;

/// <summary>
/// W1 console entry point. Pairing is implemented first so the Windows ARM64
/// build can establish a signed trust relationship with MacKVM before any
/// privileged Raw Input/SendInput code is introduced.
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

        if (!args.Contains("--pairing-listen", StringComparer.OrdinalIgnoreCase))
        {
            Console.WriteLine(
                $"WindowsKVM W1 pairing receiver; protocol v{ControlProtocolCompatibility.CurrentVersion}."
            );
            Console.WriteLine("Run with --pairing-listen to advertise on the local network.");
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
            var model = RuntimeInformation.OSArchitecture == Architecture.Arm64
                ? "Windows ARM64"
                : "Windows x64";
            await using var receiver = new PairingTcpReceiver(
                credentials,
                model,
                port,
                autoAccept
            );
            await receiver.RunAsync();
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
        Console.WriteLine();
        Console.WriteLine("  --pairing-listen  Advertise a signed pairing listener as _mackvm._tcp.");
        Console.WriteLine("  --name            Display name stored in the Windows identity (first run only).");
        Console.WriteLine("  --port            TCP port; 0 selects an available port (default).");
        Console.WriteLine("  --yes             Auto-accept the verification code (test-only convenience).");
        Console.WriteLine();
        Console.WriteLine("Pairing only is implemented in W1. Keyboard/mouse control is not enabled yet.");
    }
}
