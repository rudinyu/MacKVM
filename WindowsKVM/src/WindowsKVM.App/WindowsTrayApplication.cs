using System.Collections.Concurrent;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using WindowsKVM.Protocol;

namespace WindowsKVM;

/// <summary>
/// Small dependency-free Windows desktop host. It keeps the receiver alive in
/// the notification area, shows pairing/control consent dialogs, and exposes a
/// compact status window. The protocol and input code remain shared with the
/// console host; this class only owns Win32 presentation and lifecycle.
/// </summary>
internal sealed class WindowsTrayApplication : IDisposable
{
    private const string WindowClassName = "MacKVM.WindowsKVM.TrayHost";
    private const string WindowTitle = "MacKVM — Windows";
    private const uint WindowMessageTray = 0x8001;
    private const uint WindowMessageStatus = 0x8002;
    private const uint WindowMessageConsent = 0x8003;
    private const uint WindowMessageClose = 0x0010;
    private const uint WindowMessageDestroy = 0x0002;
    private const uint WindowMessageCommand = 0x0111;
    private const uint WindowMessagePaint = 0x000F;
    private const uint WindowMessageSize = 0x0005;
    private const uint WindowMessageVScroll = 0x0115;
    private const uint WindowMessageMouseWheel = 0x020A;
    private const uint WindowMessageControlColorStatic = 0x0138;
    private const uint WindowMessageSetFont = 0x0030;
    private const uint WindowMessageLeftButtonDoubleClick = 0x0203;
    private const uint WindowMessageRightButtonUp = 0x0205;
    private const uint WindowStyleOverlappedWindow = 0x00CF0000;
    private const uint WindowStyleChild = 0x40000000;
    private const uint WindowStyleVisible = 0x10000000;
    private const uint WindowStyleVerticalScroll = 0x00200000;
    private const uint WindowStyleClipChildren = 0x02000000;
    private const uint WindowStyleTabStop = 0x00010000;
    private const uint StaticStyleLeft = 0x00000000;
    private const uint ButtonStylePushButton = 0x00000000;
    private const int ShowWindowHide = 0;
    private const int ShowWindowShow = 5;
    private const int ShowWindowDefault = 10;
    private const int DefaultWindowCoordinate = unchecked((int)0x80000000);
    private const int OpenWindowButtonID = 1001;
    private const int FirewallButtonID = 1002;
    private const int RefreshButtonID = 1003;
    private const int CopyButtonID = 1004;
    private const int QuitButtonID = 1005;
    private const int ViewModeButtonID = 1006;
    private const int ForgetButtonID = 1007;
    private const int TrayShowCommandID = 2001;
    private const int TrayQuitCommandID = 2002;
    private const uint MenuString = 0x00000000;
    private const uint TrackPopupMenuRightButton = 0x00000002;
    private const uint TrackPopupMenuReturnCommand = 0x00000100;
    private const uint TrayAdd = 0x00000000;
    private const uint TrayDelete = 0x00000002;
    private const uint TraySetVersion = 0x00000004;
    private const uint TrayFlagMessage = 0x00000001;
    private const uint TrayFlagIcon = 0x00000002;
    private const uint TrayFlagTip = 0x00000004;
    private const uint TrayVersion = 4;
    private const int IconApplication = 32512;
    private const int CursorArrow = 32512;
    private const int SystemColorWindow = 5;
    private const uint MessageBoxYesNo = 0x00000004;
    private const uint MessageBoxQuestion = 0x00000020;
    private const uint MessageBoxDefaultButtonTwo = 0x00000100;
    private const int MessageBoxYes = 6;
    private const uint ClipboardFormatUnicodeText = 13;
    private const uint GlobalMemoryMoveable = 0x0002;
    private const uint GlobalMemoryZeroInit = 0x0040;
    private const uint ComboBoxDropDownList = 0x0003;
    private const uint ComboBoxHasStrings = 0x0200;
    private const uint ComboBoxAddString = 0x0143;
    private const uint ComboBoxSetCurrentSelection = 0x014E;
    private const int ScrollBarVertical = 1;
    private const uint ScrollInfoRange = 0x0001;
    private const uint ScrollInfoPage = 0x0002;
    private const uint ScrollInfoPosition = 0x0004;
    private const uint ScrollInfoTrackPosition = 0x0010;
    private const int ScrollCodeLineUp = 0;
    private const int ScrollCodeLineDown = 1;
    private const int ScrollCodePageUp = 2;
    private const int ScrollCodePageDown = 3;
    private const int ScrollCodeThumbPosition = 4;
    private const int ScrollCodeThumbTrack = 5;
    private const int ScrollCodeTop = 6;
    private const int ScrollCodeBottom = 7;
    private const int ScrollCodeEndScroll = 8;
    private const int AdvancedContentHeight = 1920;
    private const int SimpleContentHeight = 700;
    private const int DefaultWindowWidth = 860;
    private const int DefaultWindowHeight = 900;
    private const int ScreenMetricWidth = 0;
    private const int ScreenMetricHeight = 1;
    private const int CompactScreenWidth = 900;
    private const int CompactScreenHeight = 1120;
    private const int CompactClientWidth = 760;
    private const int CompactClientHeight = 760;

    private readonly WindowsKvmRuntime runtime;
    private readonly WndProc windowProc;
    private readonly Mutex instanceMutex;
    private readonly ConcurrentQueue<string> pendingStatuses = new();
    private readonly ConcurrentDictionary<long, ConsentRequest> pendingConsents = new();
    private readonly List<ChildLayout> childLayouts = new();
    private readonly HashSet<IntPtr> advancedControls = new();
    private readonly HashSet<IntPtr> simpleControls = new();
    private readonly HashSet<IntPtr> greenLabels = new();
    private readonly HashSet<IntPtr> orangeLabels = new();
    private readonly HashSet<IntPtr> secondaryLabels = new();
    private IntPtr window;
    private IntPtr modeButton;
    private IntPtr statusLabel;
    private IntPtr detailLabel;
    private IntPtr localNetworkStatusLabel;
    private IntPtr inputMonitoringStatusLabel;
    private IntPtr accessibilityStatusLabel;
    private IntPtr notificationsStatusLabel;
    private IntPtr inputReadyLabel;
    private IntPtr inputPathCombo;
    private IntPtr nearbyStatusLabel;
    private IntPtr pairedPeerLabel;
    private IntPtr pairedPeerDetailsLabel;
    private IntPtr forgetButton;
    private IntPtr controlStateLabel;
    private IntPtr monitorStatusLabel;
    private IntPtr supportPeerLabel;
    private IntPtr supportFingerprintLabel;
    private IntPtr trayIcon;
    private IntPtr titleFont;
    private IntPtr sectionFont;
    private IntPtr bodyFont;
    private IntPtr captionFont;
    private IntPtr monoFont;
    private IntPtr simpleStatusLabel;
    private IntPtr simpleDetailsLabel;
    private IntPtr simplePairLabel;
    private IntPtr simplePairDetailsLabel;
    private IntPtr simpleForgetButton;
    private IntPtr simpleControlStateLabel;
    private string lastStatus = "Starting WindowsKVM…";
    private string? pairedPeerName;
    private string? pairedPeerID;
    private string? pairedPeerFullID;
    private string? pairedPeerFingerprint;
    private int controlActive;
    private int scrollPosition;
    private long nextConsentID;
    private bool simpleMode;
    private bool modeSelectedByUser;
    private bool viewModeInitialized;
    private int disposed;

    private enum LabelColor
    {
        Default,
        Green,
        Orange,
        Secondary
    }

    private sealed class ChildLayout
    {
        public required IntPtr Handle { get; init; }
        public required int X { get; init; }
        public required int Y { get; init; }
        public required int Width { get; init; }
        public required int Height { get; init; }
    }

    private sealed class ConsentRequest
    {
        public required TaskCompletionSource<bool> Completion { get; init; }
        public required string Text { get; init; }
        public required string Title { get; init; }
    }

    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    private delegate IntPtr WndProc(
        IntPtr window,
        uint message,
        IntPtr wParam,
        IntPtr lParam
    );

    private WindowsTrayApplication()
    {
        windowProc = HandleWindowMessage;
        instanceMutex = new Mutex(false, @"Local\MacKVM.WindowsKVM.UI");
        try
        {
            var acquired = false;
            try
            {
                acquired = instanceMutex.WaitOne(0);
            }
            catch (AbandonedMutexException)
            {
                // WaitOne transfers ownership even when it reports that the
                // previous UI process exited without releasing the mutex.
                // Treat that stale instance as cleared and continue startup.
                acquired = true;
            }

            if (!acquired)
            {
                throw new InvalidOperationException(
                    "WindowsKVM is already running. Open it from the system tray."
                );
            }
        }
        catch
        {
            instanceMutex.Dispose();
            throw;
        }

        runtime = new WindowsKvmRuntime(
            Environment.MachineName,
            autoAccept: false,
            pairingConsent: RequestPairingConsentAsync,
            controlConsent: RequestControlConsentAsync,
            enableConsoleInput: false
        );
        runtime.StatusChanged += OnRuntimeStatusChanged;
        runtime.PairingCompleted += OnPairingCompleted;
        runtime.ControlStateChanged += OnControlStateChanged;
        SetPairedPeer(runtime.TrustedPeers.LastOrDefault());
    }

    public static int Run()
    {
        try
        {
            using var application = new WindowsTrayApplication();
            return application.RunMessageLoop();
        }
        catch (Exception ex)
        {
            MessageBox(
                IntPtr.Zero,
                $"WindowsKVM could not start:\n{ex.Message}",
                WindowTitle,
                MessageBoxQuestion
            );
            return 1;
        }
    }

    private int RunMessageLoop()
    {
        _ = FreeConsole();
        CreateFonts();
        RegisterWindowClass();
        window = CreateWindow(
            WindowClassName,
            WindowTitle,
            WindowStyleOverlappedWindow
                | WindowStyleVerticalScroll
                | WindowStyleClipChildren,
            DefaultWindowCoordinate,
            DefaultWindowCoordinate,
            DefaultWindowWidth,
            DefaultWindowHeight,
            IntPtr.Zero,
            IntPtr.Zero
        );
        if (window == IntPtr.Zero)
        {
            throw new InvalidOperationException(
                $"CreateWindowEx failed with Win32 error {Marshal.GetLastWin32Error()}."
            );
        }

        CreateControls();
        ApplyResponsiveMode();
        UpdateScrollBar();
        AddTrayIcon();
        SetWindowText(
            detailLabel,
            $"Version: {WindowsKvmRuntime.ApplicationVersion} "
                + $"(build {WindowsKvmRuntime.ApplicationBuild})\r\n"
                + $"This PC: {runtime.Identity.Name}\r\n"
                + $"Model: {runtime.Model}\r\n"
                + $"Device ID: {runtime.Identity.Id.ToString()[..8]}\r\n"
                + "Pairing and Secure Connect are starting…"
        );
        runtime.Start();
        _ = MonitorRuntimeAsync();
        ShowWindow(window, ShowWindowDefault);
        UpdateWindow(window);

        while (true)
        {
            var result = GetMessage(out var message, IntPtr.Zero, 0, 0);
            if (result <= 0)
            {
                return result < 0 ? 1 : 0;
            }

            TranslateMessage(ref message);
            DispatchMessage(ref message);
        }
    }

    private void CreateFonts()
    {
        titleFont = CreateFont(
            -28,
            0,
            0,
            0,
            700,
            0,
            0,
            0,
            1,
            0,
            0,
            5,
            0,
            "Segoe UI"
        );
        sectionFont = CreateFont(
            -19,
            0,
            0,
            0,
            600,
            0,
            0,
            0,
            1,
            0,
            0,
            5,
            0,
            "Segoe UI"
        );
        bodyFont = CreateFont(
            -17,
            0,
            0,
            0,
            400,
            0,
            0,
            0,
            1,
            0,
            0,
            5,
            0,
            "Segoe UI"
        );
        captionFont = CreateFont(
            -14,
            0,
            0,
            0,
            400,
            0,
            0,
            0,
            1,
            0,
            0,
            5,
            0,
            "Segoe UI"
        );
        monoFont = CreateFont(
            -14,
            0,
            0,
            0,
            400,
            0,
            0,
            0,
            1,
            0,
            0,
            5,
            0,
            "Consolas"
        );
    }

    private void RegisterWindowClass()
    {
        var module = GetModuleHandle(null);
        var windowClass = new WindowClass
        {
            Size = (uint)Marshal.SizeOf<WindowClass>(),
            Style = 0,
            Procedure = windowProc,
            Instance = module,
            Icon = LoadIcon(IntPtr.Zero, (IntPtr)IconApplication),
            Cursor = LoadCursor(IntPtr.Zero, (IntPtr)CursorArrow),
            Background = GetSysColorBrush(SystemColorWindow),
            ClassName = WindowClassName,
            SmallIcon = LoadIcon(IntPtr.Zero, (IntPtr)IconApplication)
        };
        if (RegisterClass(ref windowClass) == 0)
        {
            var error = Marshal.GetLastWin32Error();
            const int ClassAlreadyExists = 1410;
            if (error != ClassAlreadyExists)
            {
                throw new InvalidOperationException(
                    $"RegisterClassEx failed with Win32 error {error}."
                );
            }
        }
    }

    private void CreateControls()
    {
        // The layout intentionally follows the macOS menu panel: a compact
        // identity header, a setup checklist, physical input guidance,
        // nearby/paired devices, control state, monitor guidance, and a
        // support section. The content is taller than the window so shorter
        // Windows displays can reach every section with the vertical scroll bar.
        CreateLabel("MacKVM", 32, 28, 430, 40, titleFont);
        CreateButton(
            "Open window",
            690,
            24,
            130,
            36,
            OpenWindowButtonID
        );
        modeButton = CreateButton(
            "Simple mode",
            520,
            24,
            150,
            36,
            ViewModeButtonID
        );
        var advancedControlStart = childLayouts.Count;
        CreateLabel(
            $"This PC: {runtime.Identity.Name}",
            32,
            82,
            760,
            30,
            bodyFont
        );
        detailLabel = CreateLabel(
            $"Version: {WindowsKvmRuntime.ApplicationVersion} (build {WindowsKvmRuntime.ApplicationBuild})\r\n"
                + $"Model: {runtime.Model}   Device ID: {runtime.Identity.Id.ToString()[..8]}\r\n"
                + $"Key fingerprint: {Fingerprint(runtime.Identity.SigningPublicKey)}",
            32,
            116,
            790,
            58,
            monoFont,
            LabelColor.Secondary
        );
        statusLabel = CreateLabel(
            lastStatus,
            32,
            178,
            790,
            26,
            captionFont,
            LabelColor.Secondary
        );

        CreateLabel("Set up this PC", 32, 230, 780, 32, sectionFont);
        CreateLabel("Local Network", 32, 270, 500, 28, bodyFont);
        localNetworkStatusLabel = CreateLabel(
            "✓ Ready",
            650,
            270,
            160,
            28,
            bodyFont,
            LabelColor.Green
        );
        CreateLabel("Input Monitoring", 32, 306, 500, 28, bodyFont);
        inputMonitoringStatusLabel = CreateLabel(
            "✓ Complete",
            650,
            306,
            160,
            28,
            bodyFont,
            LabelColor.Green
        );
        CreateLabel("Accessibility", 32, 342, 500, 28, bodyFont);
        accessibilityStatusLabel = CreateLabel(
            "✓ Complete",
            650,
            342,
            160,
            28,
            bodyFont,
            LabelColor.Green
        );
        CreateLabel(
            "Windows does not use macOS privacy prompts. The receiver uses\r\n"
                + "DPAPI for its identity; Windows Defender Firewall may ask\r\n"
                + "for permission on the trusted Private network.",
            32,
            378,
            790,
            54,
            captionFont,
            LabelColor.Secondary
        );
        CreateButton(
            "Review Windows Firewall Settings",
            32,
            442,
            310,
            36,
            FirewallButtonID
        );
        inputReadyLabel = CreateLabel(
            "✓ Input permissions ready",
            32,
            488,
            500,
            28,
            bodyFont,
            LabelColor.Green
        );
        CreateLabel(
            "Control request notifications",
            32,
            528,
            500,
            28,
            bodyFont
        );
        notificationsStatusLabel = CreateLabel(
            "✓ Enabled",
            650,
            528,
            160,
            28,
            bodyFont,
            LabelColor.Green
        );
        CreateLabel(
            "Native Windows dialogs are shown whenever a paired Mac\r\n"
                + "requests keyboard, mouse, or trackpad control.",
            32,
            564,
            790,
            44,
            captionFont,
            LabelColor.Secondary
        );
        CreateButton("Refresh setup status", 32, 620, 230, 36, RefreshButtonID);

        CreateLabel("Physical input path", 32, 700, 780, 32, sectionFont);
        CreateLabel(
            "Keyboard, mouse, and trackpad",
            32,
            744,
            350,
            30,
            bodyFont
        );
        inputPathCombo = CreateComboBox(
            410,
            738,
            380,
            34,
            [
                "This Windows PC receives remote input",
                "Local Windows input only"
            ]
        );
        CreateLabel(
            "Connect the physical keyboard and mouse to the MacKVM controller.\r\n"
                + "After an authenticated request, Windows receives the input\r\n"
                + "through the encrypted session and injects it with SendInput.",
            32,
            786,
            790,
            58,
            captionFont,
            LabelColor.Secondary
        );

        CreateLabel("Nearby Macs", 32, 884, 780, 32, sectionFont);
        nearbyStatusLabel = CreateLabel(
            "Listening for MacKVM pairing requests on the local network…",
            32,
            926,
            790,
            28,
            captionFont,
            LabelColor.Secondary
        );
        pairedPeerLabel = CreateLabel(
            "No paired Macs yet",
            32,
            968,
            520,
            30,
            bodyFont
        );
        pairedPeerDetailsLabel = CreateLabel(
            "Start Pair on the MacKVM peer; the verification dialog will appear here.",
            32,
            1004,
            790,
            42,
            captionFont,
            LabelColor.Secondary
        );
        forgetButton = CreateButton(
            "Forget paired Mac",
            610,
            964,
            180,
            36,
            ForgetButtonID
        );
        CreateLabel(
            "Pairing and Connect are initiated from MacKVM. Windows shows\r\n"
                + "the consent dialog and keeps the pinned peer in its trust store.",
            32,
            1054,
            790,
            44,
            captionFont,
            LabelColor.Secondary
        );

        CreateLabel(
            "Keyboard, mouse, and trackpad",
            32,
            1140,
            780,
            32,
            sectionFont
        );
        CreateLabel("Input Monitoring", 32, 1182, 500, 28, bodyFont);
        CreateLabel("✓ Complete", 650, 1182, 160, 28, bodyFont, LabelColor.Green);
        CreateLabel("Accessibility", 32, 1218, 500, 28, bodyFont);
        CreateLabel("✓ Complete", 650, 1218, 160, 28, bodyFont, LabelColor.Green);
        controlStateLabel = CreateLabel(
            "Waiting for an authenticated Mac to request control.",
            32,
            1260,
            790,
            30,
            bodyFont
        );
        CreateLabel(
            "The controlling Mac must pass its own Input Monitoring and\r\n"
                + "Accessibility checks. Windows only accepts authenticated,\r\n"
                + "consented input and releases held keys when control ends.",
            32,
            1300,
            790,
            58,
            captionFont,
            LabelColor.Secondary
        );
        CreateLabel(
            "Ctrl+Alt+Shift+Esc returns keyboard and mouse control locally.",
            32,
            1370,
            790,
            28,
            captionFont,
            LabelColor.Secondary
        );

        CreateLabel("Monitor input", 32, 1440, 780, 32, sectionFont);
        CreateLabel(
            "External display switching is optional; pairing and remote control\r\n"
                + "work without an external display. Display input switching is\r\n"
                + "controlled from MacKVM or the monitor's OSD input menu.",
            32,
            1482,
            790,
            58,
            captionFont,
            LabelColor.Secondary
        );
        monitorStatusLabel = CreateLabel(
            "Windows monitor switching is not required for keyboard/mouse sharing.",
            32,
            1552,
            790,
            28,
            captionFont,
            LabelColor.Secondary
        );

        CreateLabel("Paired device information", 32, 1622, 780, 32, sectionFont);
        supportPeerLabel = CreateLabel(
            "This PC: " + runtime.Model,
            32,
            1664,
            790,
            28,
            bodyFont
        );
        supportFingerprintLabel = CreateLabel(
            "Local key fingerprint: " + Fingerprint(runtime.Identity.SigningPublicKey),
            32,
            1700,
            790,
            28,
            monoFont,
            LabelColor.Secondary
        );
        CreateLabel(
            "Private keys are protected by Windows DPAPI and are never included\r\n"
                + "in support information.",
            32,
            1736,
            790,
            44,
            captionFont,
            LabelColor.Secondary
        );
        CreateButton(
            "Copy support information",
            32,
            1794,
            250,
            36,
            CopyButtonID
        );
        CreateButton("Quit", 690, 1794, 130, 36, QuitButtonID);
        CreateLabel(
            "Ready on the local network. Closing this window hides MacKVM to the system tray.",
            32,
            1850,
            790,
            28,
            captionFont,
            LabelColor.Secondary
        );

        for (var index = advancedControlStart; index < childLayouts.Count; index++)
        {
            advancedControls.Add(childLayouts[index].Handle);
        }

        CreateSimpleControls();
    }

    private void CreateSimpleControls()
    {
        RegisterSimpleControl(
            CreateLabel("Quick setup", 32, 92, 790, 32, sectionFont)
        );
        simpleDetailsLabel = RegisterSimpleControl(
            CreateLabel(
                $"Version: {WindowsKvmRuntime.ApplicationVersion} (build {WindowsKvmRuntime.ApplicationBuild})\r\n"
                    + $"Model: {runtime.Model}   Device ID: {runtime.Identity.Id.ToString()[..8]}",
                32,
                132,
                790,
                52,
                monoFont,
                LabelColor.Secondary
            )
        );
        simpleStatusLabel = RegisterSimpleControl(
            CreateLabel(
                lastStatus,
                32,
                198,
                790,
                28,
                captionFont,
                LabelColor.Secondary
            )
        );
        RegisterSimpleControl(
            CreateLabel(
                "✓ Network ready    ✓ Input permissions ready\r\n"
                    + "✓ Control request notifications enabled",
                32,
                250,
                790,
                52,
                bodyFont,
                LabelColor.Green
            )
        );
        RegisterSimpleControl(
            CreateButton("Firewall settings", 32, 316, 220, 36, FirewallButtonID)
        );

        RegisterSimpleControl(
            CreateLabel("Pairing", 32, 382, 790, 32, sectionFont)
        );
        simplePairLabel = RegisterSimpleControl(
            CreateLabel("No paired Macs yet", 32, 424, 570, 30, bodyFont)
        );
        simplePairDetailsLabel = RegisterSimpleControl(
            CreateLabel(
                "Start Pair on the MacKVM peer. A verification dialog will appear here.",
                32,
                460,
                790,
                42,
                captionFont,
                LabelColor.Secondary
            )
        );
        simpleForgetButton = RegisterSimpleControl(
            CreateButton("Forget paired Mac", 630, 420, 170, 36, ForgetButtonID)
        );

        RegisterSimpleControl(
            CreateLabel("Keyboard and mouse", 32, 520, 790, 32, sectionFont)
        );
        simpleControlStateLabel = RegisterSimpleControl(
            CreateLabel(
                "Waiting for an authenticated Mac to request control.",
                32,
                562,
                790,
                30,
                bodyFont,
                LabelColor.Secondary
            )
        );
        RegisterSimpleControl(
            CreateLabel(
                "Ctrl+Alt+Shift+Esc returns keyboard and mouse control locally.",
                32,
                598,
                790,
                28,
                captionFont,
                LabelColor.Secondary
            )
        );
        RegisterSimpleControl(
            CreateButton("Refresh", 32, 638, 140, 36, RefreshButtonID)
        );
        RegisterSimpleControl(
            CreateButton("Quit", 690, 638, 130, 36, QuitButtonID)
        );
    }

    private IntPtr RegisterSimpleControl(IntPtr handle)
    {
        simpleControls.Add(handle);
        return handle;
    }

    private IntPtr CreateChild(
        string className,
        string text,
        uint style,
        int x,
        int y,
        int width,
        int height,
        IntPtr? menu = null,
        IntPtr? font = null
    )
    {
        var child = CreateWindow(
            className,
            text,
            WindowStyleChild | WindowStyleVisible | style,
            x,
            y - scrollPosition,
            width,
            height,
            window,
            menu ?? IntPtr.Zero
        );
        if (child == IntPtr.Zero)
        {
            throw new InvalidOperationException(
                $"Could not create {className} control (Win32 error {Marshal.GetLastWin32Error()})."
            );
        }

        childLayouts.Add(new ChildLayout
        {
            Handle = child,
            X = x,
            Y = y,
            Width = width,
            Height = height
        });
        if (font is not null && font.Value != IntPtr.Zero)
        {
            _ = SendMessage(child, WindowMessageSetFont, font.Value, (IntPtr)1);
        }

        return child;
    }

    private IntPtr CreateLabel(
        string text,
        int x,
        int y,
        int width,
        int height,
        IntPtr font,
        LabelColor color = LabelColor.Default
    )
    {
        var label = CreateChild(
            "STATIC",
            text,
            StaticStyleLeft,
            x,
            y,
            width,
            height,
            font: font
        );
        SetLabelColor(label, color);
        return label;
    }

    private IntPtr CreateButton(
        string text,
        int x,
        int y,
        int width,
        int height,
        int command
    ) => CreateChild(
        "BUTTON",
        text,
        ButtonStylePushButton | WindowStyleTabStop,
        x,
        y,
        width,
        height,
        (IntPtr)command,
        bodyFont
    );

    private IntPtr CreateComboBox(
        int x,
        int y,
        int width,
        int height,
        IReadOnlyList<string> values
    )
    {
        var combo = CreateChild(
            "COMBOBOX",
            "",
            ComboBoxDropDownList | ComboBoxHasStrings | WindowStyleTabStop,
            x,
            y,
            width,
            height,
            font: bodyFont
        );
        foreach (var value in values)
        {
            _ = SendMessage(
                combo,
                ComboBoxAddString,
                IntPtr.Zero,
                value
            );
        }
        _ = SendMessage(combo, ComboBoxSetCurrentSelection, IntPtr.Zero, IntPtr.Zero);
        return combo;
    }

    private void SetLabelColor(IntPtr label, LabelColor color)
    {
        greenLabels.Remove(label);
        orangeLabels.Remove(label);
        secondaryLabels.Remove(label);
        switch (color)
        {
            case LabelColor.Green:
                greenLabels.Add(label);
                break;
            case LabelColor.Orange:
                orangeLabels.Add(label);
                break;
            case LabelColor.Secondary:
                secondaryLabels.Add(label);
                break;
        }
    }

    private int CurrentContentHeight => simpleMode
        ? SimpleContentHeight
        : AdvancedContentHeight;

    private void ApplyResponsiveMode()
    {
        if (modeSelectedByUser)
        {
            UpdateScrollBar();
            return;
        }

        SetViewMode(ShouldUseSimpleMode(), userInitiated: false);
    }

    private bool ShouldUseSimpleMode()
    {
        var screenWidth = GetSystemMetrics(ScreenMetricWidth);
        var screenHeight = GetSystemMetrics(ScreenMetricHeight);
        if ((screenWidth > 0 && screenWidth < CompactScreenWidth)
            || (screenHeight > 0 && screenHeight < CompactScreenHeight))
        {
            return true;
        }

        if (window != IntPtr.Zero && GetClientRect(window, out var client))
        {
            return client.Right - client.Left < CompactClientWidth
                || client.Bottom - client.Top < CompactClientHeight;
        }

        return false;
    }

    private void SetViewMode(bool useSimpleMode, bool userInitiated)
    {
        if (userInitiated)
        {
            modeSelectedByUser = true;
        }

        var changed = !viewModeInitialized || simpleMode != useSimpleMode;
        simpleMode = useSimpleMode;
        viewModeInitialized = true;
        SetWindowText(modeButton, simpleMode ? "Advanced mode" : "Simple mode");

        if (!changed)
        {
            UpdateScrollBar();
            return;
        }

        scrollPosition = 0;
        foreach (var layout in childLayouts)
        {
            var isCommon = !advancedControls.Contains(layout.Handle)
                && !simpleControls.Contains(layout.Handle);
            var visible = isCommon
                || (simpleMode
                    ? simpleControls.Contains(layout.Handle)
                    : advancedControls.Contains(layout.Handle));
            _ = ShowWindow(layout.Handle, visible ? ShowWindowShow : ShowWindowHide);
            _ = SetWindowPos(
                layout.Handle,
                IntPtr.Zero,
                layout.X,
                layout.Y,
                0,
                0,
                0x0001 | 0x0004 | 0x0010
            );
        }

        UpdateScrollBar();
        if (window != IntPtr.Zero)
        {
            _ = InvalidateRect(window, IntPtr.Zero, false);
        }

        UpdateForgetButtonState(pairedPeerName is not null);
    }

    private void UpdateForgetButtonState(bool hasPeer)
    {
        if (forgetButton != IntPtr.Zero)
        {
            _ = EnableWindow(forgetButton, hasPeer);
            _ = ShowWindow(
                forgetButton,
                hasPeer && !simpleMode ? ShowWindowShow : ShowWindowHide
            );
        }

        if (simpleForgetButton != IntPtr.Zero)
        {
            _ = EnableWindow(simpleForgetButton, hasPeer);
            _ = ShowWindow(
                simpleForgetButton,
                hasPeer && simpleMode ? ShowWindowShow : ShowWindowHide
            );
        }
    }

    private void PaintBackground(IntPtr target)
    {
        var paint = new PaintStruct { Reserved = new byte[32] };
        var hdc = BeginPaint(target, ref paint);
        try
        {
            if (!GetClientRect(target, out var client))
            {
                return;
            }

            var background = CreateSolidBrush(Rgb(250, 250, 250));
            try
            {
                _ = FillRect(hdc, ref client, background);
            }
            finally
            {
                _ = DeleteObject(background);
            }

            var separatorBrush = CreateSolidBrush(Rgb(224, 226, 230));
            try
            {
                var separators = simpleMode
                    ? new[] { 230, 360, 506 }
                    : new[] { 204, 674, 848, 1098, 1408, 1606, 1816 };
                foreach (var contentY in separators)
                {
                    var lineY = contentY - scrollPosition;
                    if (lineY < client.Top || lineY >= client.Bottom)
                    {
                        continue;
                    }

                    var line = new NativeRect
                    {
                        Left = 32,
                        Top = lineY,
                        Right = Math.Max(32, client.Right - 32),
                        Bottom = lineY + 1
                    };
                    _ = FillRect(hdc, ref line, separatorBrush);
                }
            }
            finally
            {
                _ = DeleteObject(separatorBrush);
            }
        }
        finally
        {
            EndPaint(target, ref paint);
        }
    }

    private IntPtr PaintStaticControl(IntPtr hdc, IntPtr control)
    {
        _ = SetBkMode(hdc, 1); // TRANSPARENT
        var color = Rgb(32, 35, 40);
        if (greenLabels.Contains(control))
        {
            color = Rgb(0, 164, 72);
        }
        else if (orangeLabels.Contains(control))
        {
            color = Rgb(211, 112, 0);
        }
        else if (secondaryLabels.Contains(control))
        {
            color = Rgb(102, 108, 118);
        }
        _ = SetTextColor(hdc, color);
        return GetSysColorBrush(SystemColorWindow);
    }

    private void UpdateScrollBar()
    {
        if (window == IntPtr.Zero || !GetClientRect(window, out var client))
        {
            return;
        }

        var page = Math.Max(1, client.Bottom - client.Top);
        var contentHeight = CurrentContentHeight;
        var maximum = Math.Max(0, contentHeight - 1);
        var maxPosition = Math.Max(0, contentHeight - page);
        if (scrollPosition > maxPosition)
        {
            SetScrollPosition(maxPosition);
        }

        var info = new ScrollInfo
        {
            Size = (uint)Marshal.SizeOf<ScrollInfo>(),
            Mask = ScrollInfoRange | ScrollInfoPage | ScrollInfoPosition,
            Minimum = 0,
            Maximum = maximum,
            Page = (uint)page,
            Position = scrollPosition
        };
        _ = SetScrollInfo(window, ScrollBarVertical, ref info, true);
    }

    private void HandleVerticalScroll(int command)
    {
        if (!GetClientRect(window, out var client))
        {
            return;
        }

        var page = Math.Max(1, client.Bottom - client.Top);
        var maximum = Math.Max(0, CurrentContentHeight - page);
        var next = scrollPosition;
        switch (command)
        {
            case ScrollCodeLineUp:
                next -= 40;
                break;
            case ScrollCodeLineDown:
                next += 40;
                break;
            case ScrollCodePageUp:
                next -= page;
                break;
            case ScrollCodePageDown:
                next += page;
                break;
            case ScrollCodeThumbPosition:
            case ScrollCodeThumbTrack:
            {
                var info = new ScrollInfo
                {
                    Size = (uint)Marshal.SizeOf<ScrollInfo>(),
                    Mask = ScrollInfoTrackPosition
                };
                if (GetScrollInfo(window, ScrollBarVertical, ref info))
                {
                    next = info.TrackPosition;
                }
                break;
            }
            case ScrollCodeTop:
                next = 0;
                break;
            case ScrollCodeBottom:
                next = maximum;
                break;
            case ScrollCodeEndScroll:
                return;
            default:
                return;
        }

        SetScrollPosition(Math.Clamp(next, 0, maximum));
    }

    private void HandleMouseWheel(int delta)
    {
        if (delta == 0 || !GetClientRect(window, out var client))
        {
            return;
        }

        var page = Math.Max(1, client.Bottom - client.Top);
        var maximum = Math.Max(0, CurrentContentHeight - page);
        var lines = Math.Max(1, Math.Abs(delta) / 120);
        var next = scrollPosition - Math.Sign(delta) * lines * 48;
        SetScrollPosition(Math.Clamp(next, 0, maximum));
    }

    private void SetScrollPosition(int position)
    {
        if (position == scrollPosition && childLayouts.Count > 0)
        {
            return;
        }

        scrollPosition = position;
        const uint noSize = 0x0001;
        const uint noZOrder = 0x0004;
        const uint noActivate = 0x0010;
        foreach (var layout in childLayouts)
        {
            _ = SetWindowPos(
                layout.Handle,
                IntPtr.Zero,
                layout.X,
                layout.Y - scrollPosition,
                0,
                0,
                noSize | noZOrder | noActivate
            );
        }

        if (window != IntPtr.Zero)
        {
            var info = new ScrollInfo
            {
                Size = (uint)Marshal.SizeOf<ScrollInfo>(),
                Mask = ScrollInfoPosition,
                Position = scrollPosition
            };
            _ = SetScrollInfo(window, ScrollBarVertical, ref info, true);
            _ = InvalidateRect(window, IntPtr.Zero, false);
        }
    }

    private static uint Rgb(byte red, byte green, byte blue)
        => (uint)(red | (green << 8) | (blue << 16));

    private static string Fingerprint(byte[] publicKey)
    {
        var digest = SHA256.HashData(publicKey);
        return Convert.ToHexString(digest).Chunk(2)
            .Select(pair => string.Concat(pair))
            .Aggregate((left, right) => left + ":" + right);
    }

    private void AddTrayIcon()
    {
        trayIcon = LoadIcon(IntPtr.Zero, (IntPtr)IconApplication);
        var data = MakeTrayData(TrayFlagMessage | TrayFlagIcon | TrayFlagTip);
        if (!ShellNotifyIcon(TrayAdd, ref data))
        {
            throw new InvalidOperationException(
                $"Shell_NotifyIcon failed with Win32 error {Marshal.GetLastWin32Error()}."
            );
        }

        data.Version = TrayVersion;
        _ = ShellNotifyIcon(TraySetVersion, ref data);
    }

    private NotifyIconData MakeTrayData(uint flags) => new()
    {
        Size = (uint)Marshal.SizeOf<NotifyIconData>(),
        Window = window,
        ID = 1,
        Flags = flags,
        CallbackMessage = WindowMessageTray,
        Icon = trayIcon,
        Tip = "WindowsKVM — keyboard/mouse receiver",
        Info = "",
        InfoTitle = ""
    };

    private IntPtr HandleWindowMessage(
        IntPtr target,
        uint message,
        IntPtr wParam,
        IntPtr lParam
    )
    {
        switch (message)
        {
            case WindowMessageClose:
                ShowWindow(target, ShowWindowHide);
                return IntPtr.Zero;

            case WindowMessagePaint:
                PaintBackground(target);
                return IntPtr.Zero;

            case WindowMessageSize:
                if (!modeSelectedByUser)
                {
                    ApplyResponsiveMode();
                }
                else
                {
                    UpdateScrollBar();
                }
                return IntPtr.Zero;

            case WindowMessageVScroll:
                HandleVerticalScroll(unchecked((int)wParam.ToInt64() & 0xFFFF));
                return IntPtr.Zero;

            case WindowMessageMouseWheel:
                HandleMouseWheel(unchecked((short)((wParam.ToInt64() >> 16) & 0xFFFF)));
                return IntPtr.Zero;

            case WindowMessageControlColorStatic:
                return PaintStaticControl(wParam, lParam);

            case WindowMessageCommand:
                HandleCommand(unchecked((int)wParam.ToInt64() & 0xFFFF));
                return IntPtr.Zero;

            case WindowMessageTray:
                HandleTrayMessage(unchecked((uint)lParam.ToInt64()));
                return IntPtr.Zero;

            case WindowMessageStatus:
                DrainStatusQueue();
                return IntPtr.Zero;

            case WindowMessageConsent:
                HandleConsentRequest(wParam.ToInt64());
                return IntPtr.Zero;

            case WindowMessageDestroy:
                RemoveTrayIcon();
                ResolvePendingConsents();
                PostQuitMessage(0);
                return IntPtr.Zero;

            default:
                return DefWindowProcedure(target, message, wParam, lParam);
        }
    }

    private void HandleCommand(int command)
    {
        switch (command)
        {
            case OpenWindowButtonID:
                ShowWindow(window, ShowWindowShow);
                SetForegroundWindow(window);
                break;
            case FirewallButtonID:
                OpenFirewallSettings();
                break;
            case RefreshButtonID:
                OnRuntimeStatusChanged("Setup status refreshed; receiver is ready on the local network.");
                break;
            case CopyButtonID:
                CopySupportInformation();
                break;
            case ViewModeButtonID:
                SetViewMode(!simpleMode, userInitiated: true);
                break;
            case ForgetButtonID:
                ForgetPairedMac();
                break;
            case QuitButtonID:
            case TrayQuitCommandID:
                DestroyWindow(window);
                break;
            case TrayShowCommandID:
                ShowWindow(window, ShowWindowShow);
                SetForegroundWindow(window);
                break;
        }
    }

    private void OpenFirewallSettings()
    {
        var result = ShellExecute(
            window,
            "open",
            "ms-settings:windowsdefenderfirewall",
            null,
            null,
            1
        );
        if (result.ToInt64() <= 32)
        {
            OnRuntimeStatusChanged(
                $"Could not open Windows Firewall settings (Win32 result {result.ToInt64()})."
            );
        }
    }

    private void HandleTrayMessage(uint message)
    {
        if (message == WindowMessageLeftButtonDoubleClick)
        {
            HandleCommand(TrayShowCommandID);
            return;
        }

        if (message != WindowMessageRightButtonUp)
        {
            return;
        }

        var menu = CreatePopupMenu();
        if (menu == IntPtr.Zero)
        {
            return;
        }

        try
        {
            AppendMenu(menu, MenuString, (UIntPtr)TrayShowCommandID, "Open WindowsKVM");
            AppendMenu(menu, MenuString, (UIntPtr)TrayQuitCommandID, "Quit WindowsKVM");
            if (GetCursorPosition(out var point))
            {
                SetForegroundWindow(window);
                var command = TrackPopupMenu(
                    menu,
                    TrackPopupMenuRightButton | TrackPopupMenuReturnCommand,
                    point.X,
                    point.Y,
                    0,
                    window,
                    IntPtr.Zero
                );
                if (command != 0)
                {
                    HandleCommand(unchecked((int)command));
                }
            }
        }
        finally
        {
            DestroyMenu(menu);
        }
    }

    private Task<bool> RequestPairingConsentAsync(
        WindowsKVM.Protocol.PeerIdentity peer,
        string verificationCode,
        bool replacesExistingKey,
        CancellationToken token
    )
    {
        var replacementWarning = replacesExistingKey
            ? "Warning: this replaces the existing trusted key for this peer. "
                + "Continue only if you intentionally forgot or reset the old pairing.\n\n"
            : string.Empty;
        return RequestConsentAsync(
            $"Incoming pairing request from {peer.Name}.\n\n"
                + $"Verification code: {verificationCode}\n"
                + "Compare this code with the initiating Mac before accepting.\n\n"
                + replacementWarning
                + "Accept pairing?",
            "WindowsKVM pairing request",
            token
        );
    }

    private Task<bool> RequestControlConsentAsync(string prompt, CancellationToken token)
        => RequestConsentAsync(
            $"{prompt}\n\nAllow this authenticated peer to control this Windows PC?",
            "WindowsKVM control request",
            token
        );

    private async Task<bool> RequestConsentAsync(
        string text,
        string title,
        CancellationToken token
    )
    {
        if (window == IntPtr.Zero || token.IsCancellationRequested)
        {
            return false;
        }

        var completion = new TaskCompletionSource<bool>(
            TaskCreationOptions.RunContinuationsAsynchronously
        );
        var id = Interlocked.Increment(ref nextConsentID);
        pendingConsents[id] = new ConsentRequest
        {
            Completion = completion,
            Text = text,
            Title = title
        };

        using var cancellation = token.Register(
            static state =>
            {
                var request = ((WindowsTrayApplication Application, long ID))state!;
                request.Application.CompleteConsent(request.ID, accepted: false);
            },
            (this, id)
        );
        if (!PostMessage(window, WindowMessageConsent, (IntPtr)id, IntPtr.Zero))
        {
            CompleteConsent(id, accepted: false);
        }

        try
        {
            return await completion.Task.ConfigureAwait(false);
        }
        finally
        {
            pendingConsents.TryRemove(id, out _);
        }
    }

    private void HandleConsentRequest(long id)
    {
        if (!pendingConsents.TryGetValue(id, out var request))
        {
            return;
        }

        var result = MessageBox(
            window,
            request.Text,
            request.Title,
            MessageBoxYesNo | MessageBoxQuestion | MessageBoxDefaultButtonTwo
        );
        CompleteConsent(id, result == MessageBoxYes);
    }

    private void CompleteConsent(long id, bool accepted)
    {
        if (pendingConsents.TryRemove(id, out var request))
        {
            request.Completion.TrySetResult(accepted);
        }
    }

    private void ResolvePendingConsents()
    {
        foreach (var id in pendingConsents.Keys)
        {
            CompleteConsent(id, accepted: false);
        }
    }

    private void OnRuntimeStatusChanged(string message)
    {
        lastStatus = message;
        pendingStatuses.Enqueue(message);
        if (window != IntPtr.Zero)
        {
            _ = PostMessage(window, WindowMessageStatus, IntPtr.Zero, IntPtr.Zero);
        }
    }

    private void OnPairingCompleted(WindowsKVM.Protocol.PeerIdentity peer)
    {
        SetPairedPeer(peer);
        OnRuntimeStatusChanged($"Paired with {peer.Name}.");
    }

    private void SetPairedPeer(WindowsKVM.Protocol.PeerIdentity? peer)
    {
        Volatile.Write(ref pairedPeerName, peer?.Name);
        Volatile.Write(ref pairedPeerID, peer is null ? null : peer.Id.ToString("D")[..8]);
        Volatile.Write(ref pairedPeerFullID, peer?.Id.ToString("D"));
        Volatile.Write(
            ref pairedPeerFingerprint,
            peer is null ? null : Fingerprint(peer.SigningPublicKey)
        );
    }

    private void ForgetPairedMac()
    {
        var peerIDText = Volatile.Read(ref pairedPeerFullID);
        var peerName = Volatile.Read(ref pairedPeerName) ?? "this Mac";
        if (!Guid.TryParse(peerIDText, out var peerID))
        {
            OnRuntimeStatusChanged("There is no paired Mac to forget.");
            return;
        }

        var result = MessageBox(
            window,
            $"Forget the paired Mac {peerName}?\n\n"
                + "This removes its Windows trust pin and disconnects any active "
                + "secure session. Pair again from that Mac before connecting.",
            "Forget paired Mac",
            MessageBoxYesNo | MessageBoxQuestion | MessageBoxDefaultButtonTwo
        );
        if (result != MessageBoxYes)
        {
            return;
        }

        try
        {
            if (!runtime.ForgetPeer(peerID))
            {
                SetPairedPeer(runtime.TrustedPeers.LastOrDefault());
                OnRuntimeStatusChanged(
                    "The paired Mac was already forgotten; pair again before connecting."
                );
                return;
            }

            SetPairedPeer(runtime.TrustedPeers.LastOrDefault());
            OnRuntimeStatusChanged(
                $"Forgot {peerName}; pair again from MacKVM before connecting."
            );
        }
        catch (Exception ex)
        {
            OnRuntimeStatusChanged($"Could not forget {peerName}: {ex.Message}");
        }
    }

    private void OnControlStateChanged(bool active)
    {
        Volatile.Write(ref controlActive, active ? 1 : 0);
        OnRuntimeStatusChanged(
            active
                ? "Keyboard/mouse control is active on this Windows PC."
                : "Keyboard/mouse control is local again."
        );
    }

    private async Task MonitorRuntimeAsync()
    {
        try
        {
            await runtime.WaitForShutdownAsync(CancellationToken.None).ConfigureAwait(false);
            if (Volatile.Read(ref disposed) == 0)
            {
                OnRuntimeStatusChanged("WindowsKVM receiver stopped.");
            }
        }
        catch (Exception ex) when (Volatile.Read(ref disposed) == 0)
        {
            OnRuntimeStatusChanged($"WindowsKVM receiver failed: {ex.Message}");
        }
    }

    private void DrainStatusQueue()
    {
        while (pendingStatuses.TryDequeue(out var message))
        {
            SetWindowText(statusLabel, message);
        }

        var peerName = Volatile.Read(ref pairedPeerName);
        var peerID = Volatile.Read(ref pairedPeerID);
        var peerFingerprint = Volatile.Read(ref pairedPeerFingerprint);
        if (peerName is null)
        {
            SetWindowText(
                nearbyStatusLabel,
                "Listening for MacKVM pairing requests on the local network…"
            );
            SetLabelColor(nearbyStatusLabel, LabelColor.Secondary);
            SetWindowText(pairedPeerLabel, "No paired Macs yet");
            SetLabelColor(pairedPeerLabel, LabelColor.Default);
            SetWindowText(
                pairedPeerDetailsLabel,
                "Start Pair on the MacKVM peer; the verification dialog will appear here."
            );
        }
        else
        {
            SetWindowText(nearbyStatusLabel, $"Paired with {peerName}; ready for Connect.");
            SetLabelColor(nearbyStatusLabel, LabelColor.Green);
            SetWindowText(pairedPeerLabel, $"✓ Paired with {peerName}");
            SetLabelColor(pairedPeerLabel, LabelColor.Green);
            SetWindowText(
                pairedPeerDetailsLabel,
                $"Device ID: {peerID}\r\nKey fingerprint: {peerFingerprint}"
            );
        }
        UpdateForgetButtonState(peerName is not null);

        var isControlActive = Volatile.Read(ref controlActive) != 0;
        SetWindowText(
            controlStateLabel,
            isControlActive
                ? "This Windows PC is receiving keyboard and mouse control."
                : "Waiting for an authenticated Mac to request control."
        );
        SetLabelColor(
            controlStateLabel,
            isControlActive ? LabelColor.Green : LabelColor.Secondary
        );

        var secure = runtime.SecureConnectAvailable
            ? "Secure Connect available"
            : "Secure Connect unavailable on this Windows build";
        SetWindowText(
            detailLabel,
            $"Version: {WindowsKvmRuntime.ApplicationVersion} "
                + $"(build {WindowsKvmRuntime.ApplicationBuild})\r\n"
                + $"Model: {runtime.Model}   Device ID: {runtime.Identity.Id.ToString()[..8]}\r\n"
                + $"Pairing TCP: {runtime.PairingPort}\r\n"
                + $"Secure TCP: {runtime.SecurePort} ({secure})\r\n"
                + $"Local key fingerprint: {Fingerprint(runtime.Identity.SigningPublicKey)}"
        );
        SetWindowText(
            supportPeerLabel,
            peerName is null
                ? "This PC: " + runtime.Model
                : $"Paired Mac: {peerName}   (This PC: {runtime.Model})"
        );
        SetWindowText(
            supportFingerprintLabel,
            "Local key fingerprint: " + Fingerprint(runtime.Identity.SigningPublicKey)
        );
        SetWindowText(
            monitorStatusLabel,
            secure
                + ". Display input switching is handled by MacKVM or the monitor OSD."
        );

        SetWindowText(simpleStatusLabel, lastStatus);
        SetWindowText(
            simpleDetailsLabel,
            $"Version: {WindowsKvmRuntime.ApplicationVersion} (build {WindowsKvmRuntime.ApplicationBuild})\r\n"
                + $"Model: {runtime.Model}   Device ID: {runtime.Identity.Id.ToString()[..8]}\r\n"
                + $"Pairing TCP: {runtime.PairingPort}   Secure TCP: {runtime.SecurePort}"
        );
        SetWindowText(
            simplePairLabel,
            peerName is null ? "No paired Macs yet" : $"✓ Paired with {peerName}"
        );
        SetLabelColor(
            simplePairLabel,
            peerName is null ? LabelColor.Default : LabelColor.Green
        );
        SetWindowText(
            simplePairDetailsLabel,
            peerName is null
                ? "Start Pair on the MacKVM peer. A verification dialog will appear here."
                : $"Device ID: {peerID}\r\nKey fingerprint: {peerFingerprint}"
        );
        SetWindowText(
            simpleControlStateLabel,
            isControlActive
                ? "This Windows PC is receiving keyboard and mouse control."
                : "Waiting for an authenticated Mac to request control."
        );
        SetLabelColor(
            simpleControlStateLabel,
            isControlActive ? LabelColor.Green : LabelColor.Secondary
        );
    }

    private void CopySupportInformation()
    {
        var text = new StringBuilder()
            .AppendLine("WindowsKVM support information")
            .AppendLine($"Version: {WindowsKvmRuntime.ApplicationVersion} (build {WindowsKvmRuntime.ApplicationBuild})")
            .AppendLine($"Architecture: {RuntimeInformation.OSArchitecture}")
            .AppendLine($"Windows: {Environment.OSVersion.Version}")
            .AppendLine($"Device: {runtime.Identity.Name}")
            .AppendLine($"Model: {runtime.Model}")
            .AppendLine($"Pairing TCP: {runtime.PairingPort}")
            .AppendLine($"Secure TCP: {runtime.SecurePort}")
            .AppendLine($"Last status: {lastStatus}")
            .ToString();
        if (SetClipboardText(text))
        {
            OnRuntimeStatusChanged("Support information copied to the clipboard.");
        }
        else
        {
            OnRuntimeStatusChanged(
                $"Could not copy support information (Win32 error {Marshal.GetLastWin32Error()})."
            );
        }
    }

    private void RemoveTrayIcon()
    {
        if (trayIcon == IntPtr.Zero || window == IntPtr.Zero)
        {
            return;
        }

        var data = MakeTrayData(0);
        _ = ShellNotifyIcon(TrayDelete, ref data);
        trayIcon = IntPtr.Zero;
    }

    public void Dispose()
    {
        if (Interlocked.Exchange(ref disposed, 1) != 0)
        {
            return;
        }

        runtime.StatusChanged -= OnRuntimeStatusChanged;
        runtime.PairingCompleted -= OnPairingCompleted;
        runtime.ControlStateChanged -= OnControlStateChanged;
        ResolvePendingConsents();
        try
        {
            runtime.DisposeAsync().AsTask().GetAwaiter().GetResult();
        }
        catch (Exception ex)
        {
            // Shutdown has no user-facing retry path; leave a diagnostic in
            // the console if one was attached, but never resurrect the tray.
            Console.Error.WriteLine($"WindowsKVM shutdown failed: {ex.Message}");
        }

        try
        {
            instanceMutex.ReleaseMutex();
        }
        catch (ApplicationException)
        {
            // The mutex may already have been abandoned during a failed
            // startup; disposing it is still sufficient for this process.
        }
        finally
        {
            instanceMutex.Dispose();
            DeleteFont(ref titleFont);
            DeleteFont(ref sectionFont);
            DeleteFont(ref bodyFont);
            DeleteFont(ref captionFont);
            DeleteFont(ref monoFont);
        }
    }

    private static void DeleteFont(ref IntPtr font)
    {
        if (font != IntPtr.Zero)
        {
            _ = DeleteObject(font);
            font = IntPtr.Zero;
        }
    }

    private static bool SetClipboardText(string text)
    {
        if (!OpenClipboard(IntPtr.Zero))
        {
            return false;
        }

        IntPtr allocation = IntPtr.Zero;
        try
        {
            if (!EmptyClipboard())
            {
                return false;
            }

            var bytes = Encoding.Unicode.GetBytes(text + "\0");
            allocation = GlobalAlloc(GlobalMemoryMoveable | GlobalMemoryZeroInit, (UIntPtr)bytes.Length);
            if (allocation == IntPtr.Zero)
            {
                return false;
            }

            var destination = GlobalLock(allocation);
            if (destination == IntPtr.Zero)
            {
                return false;
            }

            try
            {
                Marshal.Copy(bytes, 0, destination, bytes.Length);
            }
            finally
            {
                GlobalUnlock(allocation);
            }

            if (SetClipboardData(ClipboardFormatUnicodeText, allocation) == IntPtr.Zero)
            {
                return false;
            }

            allocation = IntPtr.Zero;
            return true;
        }
        finally
        {
            if (allocation != IntPtr.Zero)
            {
                GlobalFree(allocation);
            }

            CloseClipboard();
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

    [StructLayout(LayoutKind.Sequential)]
    private struct PaintStruct
    {
        public IntPtr DeviceContext;
        public int Erase;
        public NativeRect PaintRectangle;
        public int Restore;
        public int IncUpdate;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 32)]
        public byte[] Reserved;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ScrollInfo
    {
        public uint Size;
        public uint Mask;
        public int Minimum;
        public int Maximum;
        public uint Page;
        public int Position;
        public int TrackPosition;
    }

    private static IntPtr CreateWindow(
        string className,
        string title,
        uint style,
        int x,
        int y,
        int width,
        int height,
        IntPtr parent,
        IntPtr menu
    ) => CreateWindowEx(
        0,
        className,
        title,
        style,
        x,
        y,
        width,
        height,
        parent,
        menu,
        GetModuleHandle(null),
        IntPtr.Zero
    );

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct WindowClass
    {
        public uint Size;
        public uint Style;
        public WndProc? Procedure;
        public int ClassExtra;
        public int WindowExtra;
        public IntPtr Instance;
        public IntPtr Icon;
        public IntPtr Cursor;
        public IntPtr Background;
        public string? MenuName;
        public string ClassName;
        public IntPtr SmallIcon;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct NotifyIconData
    {
        public uint Size;
        public IntPtr Window;
        public uint ID;
        public uint Flags;
        public uint CallbackMessage;
        public IntPtr Icon;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string Tip;
        public uint State;
        public uint StateMask;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
        public string Info;
        public uint Version;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)]
        public string InfoTitle;
        public uint InfoFlags;
        public Guid ItemGuid;
        public IntPtr BalloonIcon;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeMessage
    {
        public IntPtr Window;
        public uint Message;
        public UIntPtr WParam;
        public IntPtr LParam;
        public uint Time;
        public int PointX;
        public int PointY;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativePoint
    {
        public int X;
        public int Y;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool FreeConsole();

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr GetModuleHandle(string? moduleName);

    [DllImport("user32.dll", EntryPoint = "RegisterClassExW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern ushort RegisterClass(ref WindowClass windowClass);

    [DllImport("user32.dll", EntryPoint = "CreateWindowExW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateWindowEx(
        uint extendedStyle,
        string className,
        string title,
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

    [DllImport("user32.dll", EntryPoint = "DefWindowProcW", CharSet = CharSet.Unicode)]
    private static extern IntPtr DefWindowProcedure(
        IntPtr window,
        uint message,
        IntPtr wParam,
        IntPtr lParam
    );

    [DllImport("user32.dll", EntryPoint = "SetWindowTextW", CharSet = CharSet.Unicode)]
    private static extern bool SetWindowText(IntPtr window, string text);

    [DllImport("user32.dll", EntryPoint = "SendMessageW", CharSet = CharSet.Unicode)]
    private static extern IntPtr SendMessage(
        IntPtr window,
        uint message,
        IntPtr wParam,
        IntPtr lParam
    );

    [DllImport("user32.dll", EntryPoint = "SendMessageW", CharSet = CharSet.Unicode)]
    private static extern IntPtr SendMessage(
        IntPtr window,
        uint message,
        IntPtr wParam,
        string lParam
    );

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool DestroyWindow(IntPtr window);

    [DllImport("user32.dll")]
    private static extern bool ShowWindow(IntPtr window, int command);

    [DllImport("user32.dll")]
    private static extern bool EnableWindow(IntPtr window, bool enable);

    [DllImport("user32.dll")]
    private static extern bool UpdateWindow(IntPtr window);

    [DllImport("user32.dll")]
    private static extern int GetSystemMetrics(int index);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool GetClientRect(IntPtr window, out NativeRect rectangle);

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
    private static extern bool InvalidateRect(
        IntPtr window,
        IntPtr rectangle,
        bool erase
    );

    [DllImport("user32.dll", SetLastError = true)]
    private static extern int SetScrollInfo(
        IntPtr window,
        int bar,
        ref ScrollInfo information,
        bool redraw
    );

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool GetScrollInfo(
        IntPtr window,
        int bar,
        ref ScrollInfo information
    );

    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr window);

    [DllImport("user32.dll")]
    private static extern int GetMessage(
        out NativeMessage message,
        IntPtr window,
        uint minimumMessage,
        uint maximumMessage
    );

    [DllImport("user32.dll")]
    private static extern bool TranslateMessage(ref NativeMessage message);

    [DllImport("user32.dll")]
    private static extern IntPtr DispatchMessage(ref NativeMessage message);

    [DllImport("user32.dll")]
    private static extern void PostQuitMessage(int exitCode);

    [DllImport("user32.dll")]
    private static extern bool PostMessage(
        IntPtr window,
        uint message,
        IntPtr wParam,
        IntPtr lParam
    );

    [DllImport("user32.dll")]
    private static extern IntPtr LoadIcon(IntPtr instance, IntPtr iconName);

    [DllImport("user32.dll")]
    private static extern IntPtr LoadCursor(IntPtr instance, IntPtr cursorName);

    [DllImport("user32.dll")]
    private static extern IntPtr GetSysColorBrush(int index);

    [DllImport("shell32.dll", EntryPoint = "Shell_NotifyIconW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool ShellNotifyIcon(uint message, ref NotifyIconData data);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr CreatePopupMenu();

    [DllImport("user32.dll", EntryPoint = "AppendMenuW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool AppendMenu(
        IntPtr menu,
        uint flags,
        UIntPtr command,
        string text
    );

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint TrackPopupMenu(
        IntPtr menu,
        uint flags,
        int x,
        int y,
        int reserved,
        IntPtr window,
        IntPtr rectangle
    );

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool DestroyMenu(IntPtr menu);

    [DllImport("user32.dll", EntryPoint = "GetCursorPos", SetLastError = true)]
    private static extern bool GetCursorPosition(out NativePoint point);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr BeginPaint(
        IntPtr window,
        ref PaintStruct paint
    );

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool EndPaint(
        IntPtr window,
        ref PaintStruct paint
    );

    [DllImport("gdi32.dll", SetLastError = true)]
    private static extern IntPtr CreateSolidBrush(uint color);

    [DllImport("gdi32.dll", SetLastError = true)]
    private static extern bool DeleteObject(IntPtr objectHandle);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern int FillRect(
        IntPtr deviceContext,
        ref NativeRect rectangle,
        IntPtr brush
    );

    [DllImport("gdi32.dll", SetLastError = true)]
    private static extern int SetBkMode(IntPtr deviceContext, int mode);

    [DllImport("gdi32.dll", SetLastError = true)]
    private static extern uint SetTextColor(IntPtr deviceContext, uint color);

    [DllImport("user32.dll", EntryPoint = "MessageBoxW", CharSet = CharSet.Unicode)]
    private static extern int MessageBox(
        IntPtr window,
        string text,
        string caption,
        uint type
    );

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool OpenClipboard(IntPtr owner);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool EmptyClipboard();

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetClipboardData(uint format, IntPtr data);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool CloseClipboard();

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr GlobalAlloc(uint flags, UIntPtr bytes);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr GlobalLock(IntPtr memory);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GlobalUnlock(IntPtr memory);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr GlobalFree(IntPtr memory);

    [DllImport("gdi32.dll", EntryPoint = "CreateFontW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateFont(
        int height,
        int width,
        int escapement,
        int orientation,
        int weight,
        byte italic,
        byte underline,
        byte strikeOut,
        byte characterSet,
        byte outputPrecision,
        byte clipPrecision,
        byte quality,
        byte pitchAndFamily,
        string faceName
    );

    [DllImport("shell32.dll", EntryPoint = "ShellExecuteW", CharSet = CharSet.Unicode)]
    private static extern IntPtr ShellExecute(
        IntPtr window,
        string operation,
        string file,
        string? parameters,
        string? directory,
        int showCommand
    );
}
