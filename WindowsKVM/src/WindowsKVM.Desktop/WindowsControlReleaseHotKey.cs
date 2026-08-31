using System.ComponentModel;
using System.Runtime.InteropServices;

namespace WindowsKVM;

/// <summary>
/// Registers a local emergency shortcut for returning Windows input to the
/// Windows machine. The shortcut is deliberately handled on its own message
/// thread so it remains available while the foreground application is busy.
/// </summary>
internal sealed class WindowsControlReleaseHotKey : IDisposable
{
    private const int HotKeyID = 0x4D4B; // "MK"
    private const uint ModAlt = 0x0001;
    private const uint ModControl = 0x0002;
    private const uint ModNoRepeat = 0x4000;
    private const uint ModShift = 0x0004;
    private const uint VirtualKeyEscape = 0x1B;
    private const uint WindowMessageHotKey = 0x0312;
    private const uint WindowMessageQuit = 0x0012;

    private readonly Action onPressed;
    private readonly ManualResetEventSlim ready = new(false);
    private readonly Thread thread;
    private uint threadID;
    private Exception? startupFailure;
    private int disposed;

    public WindowsControlReleaseHotKey(Action onPressed)
    {
        this.onPressed = onPressed;
        thread = new Thread(Run)
        {
            IsBackground = true,
            Name = "MacKVM Windows control release hotkey"
        };
        thread.Start();
        ready.Wait();
        if (startupFailure is not null)
        {
            ready.Dispose();
            throw startupFailure;
        }
    }

    public void Dispose()
    {
        if (Interlocked.Exchange(ref disposed, 1) != 0)
        {
            return;
        }

        if (threadID != 0)
        {
            _ = PostThreadMessage(threadID, WindowMessageQuit, UIntPtr.Zero, IntPtr.Zero);
        }

        if (thread.IsAlive && !thread.Join(TimeSpan.FromSeconds(2)))
        {
            Console.Error.WriteLine("Windows control release hotkey thread did not stop promptly.");
        }

        ready.Dispose();
    }

    private void Run()
    {
        threadID = GetCurrentThreadID();
        var modifiers = ModControl | ModAlt | ModShift | ModNoRepeat;
        if (!RegisterHotKey(IntPtr.Zero, HotKeyID, modifiers, VirtualKeyEscape))
        {
            startupFailure = new Win32Exception(Marshal.GetLastWin32Error());
            ready.Set();
            return;
        }

        ready.Set();
        try
        {
            while (GetMessage(out var message, IntPtr.Zero, 0, 0) > 0)
            {
                if (message.Message == WindowMessageHotKey
                    && message.WParam == (UIntPtr)HotKeyID
                    && Volatile.Read(ref disposed) == 0)
                {
                    try
                    {
                        onPressed();
                    }
                    catch (Exception ex)
                    {
                        Console.Error.WriteLine(
                            $"Windows control release hotkey failed: {ex.Message}"
                        );
                    }
                }
            }
        }
        finally
        {
            UnregisterHotKey(IntPtr.Zero, HotKeyID);
        }
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool RegisterHotKey(
        IntPtr hWnd,
        int id,
        uint fsModifiers,
        uint vk
    );

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool PostThreadMessage(
        uint idThread,
        uint message,
        UIntPtr wParam,
        IntPtr lParam
    );

    [DllImport("user32.dll", SetLastError = true)]
    private static extern int GetMessage(
        out NativeMessage message,
        IntPtr hWnd,
        uint filterMin,
        uint filterMax
    );

    [DllImport("kernel32.dll", EntryPoint = "GetCurrentThreadId")]
    private static extern uint GetCurrentThreadID();

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeMessage
    {
        public IntPtr HWnd;
        public uint Message;
        public UIntPtr WParam;
        public IntPtr LParam;
        public uint Time;
        public int PointX;
        public int PointY;
    }
}
