using System.Security;
using System.Text;
using System.Text.RegularExpressions;

namespace WindowsKVM;

/// <summary>
/// A small local status log for diagnosing the resident UI without leaving
/// it to run in a console. It stores status text only, never protocol payloads,
/// verification codes, or private identity material.
/// </summary>
internal static class WindowsKvmDiagnosticLog
{
    private const long MaximumBytes = 512 * 1024;
    private static readonly object Sync = new();
    private static readonly Regex PairingCodePattern = new(
        @"(?i)((?:verification|pairing)\s+code\s*(?:is\s*)?[:=]?\s*)\d{6}",
        RegexOptions.Compiled | RegexOptions.CultureInvariant
    );

    public static string FilePath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "MacKVM",
        "logs",
        "WindowsKVM.log"
    );

    public static void WriteStatus(string message)
    {
        var safeMessage = SanitizeStatus(message);

        lock (Sync)
        {
            try
            {
                var path = FilePath;
                var directory = Path.GetDirectoryName(path);
                if (directory is null)
                {
                    return;
                }
                Directory.CreateDirectory(directory);
                if (File.Exists(path) && new FileInfo(path).Length >= MaximumBytes)
                {
                    var previous = path + ".1";
                    File.Delete(previous);
                    File.Move(path, previous);
                }

                var line = $"{DateTimeOffset.UtcNow:O} status {safeMessage}{Environment.NewLine}";
                File.AppendAllText(path, line, Encoding.UTF8);
            }
            catch (Exception ex) when (
                ex is IOException
                    or UnauthorizedAccessException
                    or SecurityException
                    or ArgumentException
                    or NotSupportedException
            )
            {
                // Logging is best-effort and must never interrupt input or UI.
            }
        }
    }

    public static string SanitizeStatus(string message)
    {
        var safeMessage = RedactCodes(message);
        return new string(safeMessage
            .Where(character => !char.IsControl(character) || character is '\t')
            .Take(1_000)
            .ToArray());
    }

    public static string ReadRecentStatuses(int maximumCharacters = 16_000)
    {
        lock (Sync)
        {
            try
            {
                if (!File.Exists(FilePath))
                {
                    return "No status events have been recorded yet.";
                }

                var contents = File.ReadAllText(FilePath, Encoding.UTF8);
                var safeContents = RedactCodes(contents);
                var limit = Math.Max(0, maximumCharacters);
                return safeContents.Length <= limit
                    ? safeContents
                    : safeContents[^limit..];
            }
            catch (Exception ex) when (
                ex is IOException
                    or UnauthorizedAccessException
                    or SecurityException
                    or ArgumentException
                    or NotSupportedException
            )
            {
                return "The local status log could not be read.";
            }
        }
    }

    private static string RedactCodes(string text)
        => PairingCodePattern.Replace(text, "$1[redacted]");
}
