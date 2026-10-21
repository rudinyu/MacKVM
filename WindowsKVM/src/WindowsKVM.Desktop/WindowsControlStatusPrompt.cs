using System.Runtime.InteropServices;

namespace WindowsKVM;

/// <summary>
/// Small topmost status prompt that is shown without taking keyboard focus.
/// It is owned by the tray host and is only called on that host's UI thread.
/// </summary>
internal sealed class WindowsControlStatusPrompt : IDisposable
{
    private const uint WindowStylePopup = 0x80000000;
    private const uint StaticStyleCenter = 0x00000001;
    private const uint StaticStyleCenterImage = 0x00000200;
    private const uint WindowExtendedStyleTopmost = 0x00000008;
    private const uint WindowExtendedStyleToolWindow = 0x00000080;
    private const uint WindowExtendedStyleNoActivate = 0x08000000;
    private const int ShowWindowHide = 0;
    private const int ShowWindowShowNoActivate = 4;
    private const uint SetWindowPositionNoActivate = 0x0010;
    private const uint SetWindowPositionShowWindow = 0x0040;
    private const uint GetWorkArea = 0x0030;
    private const int PromptWidth = 420;
    private const int PromptHeight = 72;
    private static readonly IntPtr TopmostWindow = new(-1);
    private readonly IntPtr owner;
    private IntPtr window;

    public WindowsControlStatusPrompt(IntPtr owner)
        => this.owner = owner;

    public void Show(string message)
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        if (window == IntPtr.Zero)
        {
            window = CreateWindowEx(
                WindowExtendedStyleTopmost
                    | WindowExtendedStyleToolWindow
                    | WindowExtendedStyleNoActivate,
                "STATIC",
                message,
                WindowStylePopup | StaticStyleCenter | StaticStyleCenterImage,
                0,
                0,
                PromptWidth,
                PromptHeight,
                owner,
                IntPtr.Zero,
                IntPtr.Zero,
                IntPtr.Zero
            );
        }

        if (window == IntPtr.Zero)
        {
            return;
        }

        _ = SetWindowText(window, message);
        var workArea = new NativeRect();
        if (!SystemParametersInfo(GetWorkArea, 0, ref workArea, 0))
        {
            workArea.Right = GetSystemMetrics(0);
            workArea.Bottom = GetSystemMetrics(1);
        }

        var x = Math.Max(workArea.Left, workArea.Right - PromptWidth - 24);
        var y = Math.Max(workArea.Top, workArea.Bottom - PromptHeight - 24);
        _ = SetWindowPos(
            window,
            TopmostWindow,
            x,
            y,
            PromptWidth,
            PromptHeight,
            SetWindowPositionNoActivate | SetWindowPositionShowWindow
        );
        _ = ShowWindow(window, ShowWindowShowNoActivate);
    }

    public void Hide()
    {
        if (window != IntPtr.Zero)
        {
            _ = ShowWindow(window, ShowWindowHide);
        }
    }

    public void Dispose()
    {
        if (window != IntPtr.Zero)
        {
            _ = DestroyWindow(window);
            window = IntPtr.Zero;
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeRect
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [DllImport("user32.dll", EntryPoint = "CreateWindowExW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateWindowEx(
        uint extendedStyle,
        string className,
        string windowName,
        uint style,
        int x,
        int y,
        int width,
        int height,
        IntPtr parent,
        IntPtr menu,
        IntPtr instance,
        IntPtr parameter
    );

    [DllImport("user32.dll", EntryPoint = "SetWindowTextW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool SetWindowText(IntPtr window, string text);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool ShowWindow(IntPtr window, int command);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool DestroyWindow(IntPtr window);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SetWindowPos(
        IntPtr window,
        IntPtr insertAfter,
        int x,
        int y,
        int width,
        int height,
        uint flags
    );

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SystemParametersInfo(
        uint action,
        uint parameter,
        ref NativeRect value,
        uint update
    );

    [DllImport("user32.dll", SetLastError = true)]
    private static extern int GetSystemMetrics(int index);
}
