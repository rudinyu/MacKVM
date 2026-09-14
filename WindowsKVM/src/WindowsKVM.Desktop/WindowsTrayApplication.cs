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
    private const string WindowTitle = "WindowsKVM";
    private const uint WindowMessageTray = 0x8001;
    private const uint WindowMessageStatus = 0x8002;
    private const uint WindowMessageConsent = 0x8003;
    private const uint WindowMessageConsentCancel = 0x8004;
    private const uint WindowMessageClose = 0x0010;
    private const uint WindowMessageDestroy = 0x0002;
    private const uint WindowMessageCommand = 0x0111;
    private const uint WindowMessagePaint = 0x000F;
    private const uint WindowMessageSize = 0x0005;
    private const uint WindowMessageGetMinMaxInfo = 0x0024;
    private const uint WindowMessageSetRedraw = 0x000B;
    private const uint WindowMessageHScroll = 0x0114;
    private const uint WindowMessageVScroll = 0x0115;
    private const uint WindowMessageMouseWheel = 0x020A;
    private const uint WindowMessageControlColorStatic = 0x0138;
    private const uint WindowMessageSetFont = 0x0030;
    private const uint WindowMessageKeyDown = 0x0100;
    private const uint WindowMessageLeftButtonDoubleClick = 0x0203;
    private const uint WindowMessageRightButtonUp = 0x0205;
    private const uint WindowStyleOverlappedWindow = 0x00CF0000;
    private const uint WindowStyleChild = 0x40000000;
    private const uint WindowStyleVisible = 0x10000000;
    private const uint WindowStyleVerticalScroll = 0x00200000;
    private const uint WindowStyleHorizontalScroll = 0x00100000;
    private const uint WindowStyleClipChildren = 0x02000000;
    private const uint WindowStyleClipSiblings = 0x04000000;
    private const uint WindowStyleTabStop = 0x00010000;
    private const uint WindowStyleThickFrame = 0x00040000;
    private const uint WindowStyleMinimizeBox = 0x00020000;
    private const uint WindowStyleMaximizeBox = 0x00010000;
    private const uint WindowExtendedStyleComposited = 0x02000000;
    private const uint StaticStyleLeft = 0x00000000;
    private const uint ButtonStylePushButton = 0x00000000;
    private const uint ButtonStyleAutoCheckBox = 0x00000003;
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
    private const int ControlAuthorizationButtonID = 1008;
    private const int ConsentYesButtonID = 1101;
    private const int ConsentNoButtonID = 1102;
    private const int TrayShowCommandID = 2001;
    private const int TrayQuitCommandID = 2002;
    private const uint MenuString = 0x00000000;
    private const uint TrackPopupMenuRightButton = 0x00000002;
    private const uint TrackPopupMenuReturnCommand = 0x00000100;
    private const uint TrayAdd = 0x00000000;
    private const uint TrayDelete = 0x00000002;
    private const uint TrayFlagMessage = 0x00000001;
    private const uint TrayFlagIcon = 0x00000002;
    private const uint TrayFlagTip = 0x00000004;
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
    private const uint ComboBoxGetCurrentSelection = 0x0147;
    private const uint ComboBoxGetCount = 0x0146;
    private const uint ComboBoxGetItemHeight = 0x0154;
    private const uint ComboBoxResetContent = 0x014B;
    private const uint ComboBoxSetCurrentSelection = 0x014E;
    private const uint ComboBoxSelectionChanged = 0x0001;
    private const uint EditStyleMultiline = 0x0004;
    private const uint EditStyleAutoVScroll = 0x0040;
    private const uint EditStyleReadOnly = 0x0800;
    private const uint EditStyleWantReturn = 0x1000;
    private const uint ButtonGetCheck = 0x00F0;
    private const uint ButtonSetCheck = 0x00F1;
    private const int ButtonStateChecked = 1;
    private const int ScrollBarHorizontal = 0;
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
    private const uint WindowPositionNoRedraw = 0x0008;
    private const uint WindowPositionNoActivate = 0x0010;
    private const uint WindowPositionNoZOrder = 0x0004;
    private const uint WindowPositionNoCopyBits = 0x0100;
    private const uint RedrawInvalidate = 0x0001;
    private const uint RedrawErase = 0x0004;
    private const uint RedrawAllChildren = 0x0080;
    private const uint RedrawUpdateNow = 0x0100;
    private const uint RedrawFrame = 0x0400;
    // The full SHA-256 fingerprint is intentionally rendered over two short
    // lines in Advanced mode.  A single long STATIC line wraps at an
    // implementation-dependent word boundary and used to be clipped by the
    // following support-information row.
    private const int AdvancedContentHeight = 2000;
    private const int SimpleContentHeight = 430;
    private const int ScreenMetricWidth = 0;
    private const int ScreenMetricHeight = 1;
    private const uint SystemParametersInfoGetWorkArea = 0x0030;
    private const uint MonitorDefaultToNearest = 0x00000002;
    private const int ConsentWindowWidth = 620;
    private const int ConsentWindowHeight = 330;
    private const uint ConsentWindowStyle = WindowStyleOverlappedWindow
        & ~(WindowStyleThickFrame | WindowStyleMinimizeBox | WindowStyleMaximizeBox);
    private const int VirtualKeyEscape = 0x1B;
    private const int VirtualKeyReturn = 0x0D;

    // The Advanced view uses a fixed logical canvas so every row remains
    // readable while the outer window stays comfortable on a laptop display.
    // Keep these values in one place to avoid a row growing past the canvas
    // when a future label or action is added.
    private const int AdvancedEdge = 32;
    private const int AdvancedTextWidth = 668;
    private const int AdvancedStatusX = 555;
    private const int AdvancedStatusWidth = 145;
    private const int AdvancedInputComboX = 360;
    private const int AdvancedInputComboWidth = 340;
    private const int AdvancedPeerSelectorWidth = 460;
    private const int AdvancedForgetX = 505;
    private const int AdvancedForgetWidth = 195;
    private const int AdvancedQuitX = 570;
    private const int AdvancedQuitWidth = 130;

    // A restrained slate palette keeps the status panel distinct from the
    // Windows desktop without the high-saturation blue/green blocks that the
    // stock system brush produced in the previous build.
    private static uint ThemeBackgroundColor => Rgb(247, 249, 251);
    private static uint ThemeSeparatorColor => Rgb(218, 225, 232);
    private static uint ThemePrimaryTextColor => Rgb(31, 41, 55);
    private static uint ThemeSecondaryTextColor => Rgb(100, 116, 139);
    private static uint ThemeSuccessTextColor => Rgb(21, 128, 61);
    private static uint ThemeWarningTextColor => Rgb(180, 83, 9);

    private readonly WindowsKvmRuntime runtime;
    private readonly WndProc windowProc;
    private readonly ConcurrentQueue<WindowsKVM.Protocol.PeerIdentity> pendingPairedPeers = new();
    private readonly ConsentRequestCoordinator consentRequests;
    private readonly List<ChildLayout> childLayouts = new();
    private readonly HashSet<IntPtr> advancedControls = new();
    private readonly HashSet<IntPtr> simpleControls = new();
    private readonly HashSet<IntPtr> greenLabels = new();
    private readonly HashSet<IntPtr> orangeLabels = new();
    private readonly HashSet<IntPtr> secondaryLabels = new();
    private readonly HashSet<IntPtr> redrawEnabledChildren = new();
    private IntPtr window;
    private IntPtr titleLabel;
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
    // Drop-down selector keeps every trusted peer visible and gives Forget a
    // concrete target instead of relying on the ordering of TrustStore.Snapshot().
    private IntPtr pairedPeerSelector;
    private IntPtr pairedPeerDetailsLabel;
    private IntPtr forgetButton;
    private IntPtr controlAuthorizationCheckBox;
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
    private IntPtr backgroundBrush;
    private IntPtr separatorBrush;
    private IntPtr simpleInputPathCombo;
    private IntPtr consentWindow;
    private IntPtr consentTextLabel;
    private IntPtr consentYesButton;
    private IntPtr consentNoButton;
    private IntPtr simpleStatusLabel;
    private IntPtr simpleDetailsLabel;
    private IntPtr simpleQuickSetupLabel;
    private IntPtr simpleReadinessLabel;
    private IntPtr simplePairingHeaderLabel;
    private IntPtr simplePairLabel;
    private IntPtr simplePairDetailsLabel;
    private IntPtr simpleForgetButton;
    private IntPtr simpleControlHeaderLabel;
    private IntPtr simpleControlStateLabel;
    private IntPtr simpleInputPathLabel;
    private IntPtr simpleRefreshButton;
    private IntPtr simpleQuitButton;
    private string lastStatus = "Starting WindowsKVM…";
    private string? pairedPeerName;
    private string? pairedPeerID;
    private string? pairedPeerFullID;
    private string? pairedPeerFingerprint;
    private int remoteInputEnabled = 1;
    private readonly List<Guid> pairedPeerOptions = new();
    private bool updatingPeerSelector;
    private int controlActive;
    private int scrollPosition;
    private int horizontalScrollPosition;
    private long consentWindowRequestID;
    private int statusMessagePosted;
    private int statusDirty;
    private int windowUpdateDepth;
    private int clientLayoutUpdate;
    private bool windowWasVisibleBeforeUpdate;
    private bool simpleMode = true;
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
        public required int X { get; set; }
        public required int Y { get; set; }
        public required int Width { get; set; }
        public required int Height { get; set; }
        public int ComboBoxItemHeight { get; set; }
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
        consentRequests = new ConsentRequestCoordinator(
            id => window != IntPtr.Zero
                && PostMessage(window, WindowMessageConsent, (IntPtr)id, IntPtr.Zero),
            id => window != IntPtr.Zero
                && PostMessage(
                    window,
                    WindowMessageConsentCancel,
                    (IntPtr)id,
                    IntPtr.Zero
                )
        );

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
        SetPairedPeer(runtime.TrustedPeers.FirstOrDefault());
        runtime.SetRemoteInputEnabled(enabled: true);
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
        CreateBrushes();
        RegisterWindowClass();
        var initialWindowSize = WindowsTrayLayoutPolicy.ForSimple(
            GetWorkAreaWidth(),
            GetWorkAreaHeight()
        );
        window = CreateWindow(
            WindowClassName,
            WindowTitle,
            WindowStyleOverlappedWindow
                | WindowStyleVerticalScroll
                | WindowStyleHorizontalScroll
                | WindowStyleClipChildren
                | WindowStyleClipSiblings,
            DefaultWindowCoordinate,
            DefaultWindowCoordinate,
            initialWindowSize.Width,
            initialWindowSize.Height,
            IntPtr.Zero,
            IntPtr.Zero,
            WindowExtendedStyleComposited
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
        SetWindowText(detailLabel, FormatHeaderDetails());
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

            if (consentWindow != IntPtr.Zero
                && message.Message == WindowMessageKeyDown
                && message.WParam.ToUInt64() == (ulong)VirtualKeyEscape)
            {
                // Escape is an explicit denial even when focus is inside one
                // of the child buttons; do not leave the request waiting for
                // its network timeout.
                _ = consentRequests.TryComplete(
                    consentWindowRequestID,
                    accepted: false
                );
                continue;
            }

            if (consentWindow != IntPtr.Zero
                && IsDialogMessage(consentWindow, ref message))
            {
                // IsDialogMessage provides Tab traversal and routes Enter to
                // the currently focused button. The No button is focused by
                // default below, so Enter cannot accidentally accept.
                continue;
            }

            if (consentWindow != IntPtr.Zero
                && message.Message == WindowMessageKeyDown
                && message.WParam.ToUInt64() == (ulong)VirtualKeyReturn)
            {
                _ = consentRequests.TryComplete(
                    consentWindowRequestID,
                    accepted: false
                );
                continue;
            }

            TranslateMessage(ref message);
            DispatchMessage(ref message);
        }
    }

    private void CreateFonts()
    {
        titleFont = CreateFont(
            -24,
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
            -16,
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
        captionFont = CreateFont(
            -12,
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
            -12,
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

    private void CreateBrushes()
    {
        backgroundBrush = CreateSolidBrush(ThemeBackgroundColor);
        separatorBrush = CreateSolidBrush(ThemeSeparatorColor);
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
            Background = backgroundBrush != IntPtr.Zero
                ? backgroundBrush
                : GetSysColorBrush(SystemColorWindow),
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
        titleLabel = CreateLabel(WindowTitle, AdvancedEdge, 28, 430, 40, titleFont);
        modeButton = CreateButton(
            "Simple mode",
            540,
            24,
            150,
            36,
            ViewModeButtonID
        );
        var advancedControlStart = childLayouts.Count;
        CreateLabel(
            $"This PC: {runtime.Identity.Name}",
            AdvancedEdge,
            82,
            AdvancedTextWidth,
            30,
            bodyFont
        );
        detailLabel = CreateLabel(
            FormatHeaderDetails(),
            AdvancedEdge,
            116,
            AdvancedTextWidth,
            58,
            monoFont,
            LabelColor.Secondary
        );
        statusLabel = CreateLabel(
            lastStatus,
            AdvancedEdge,
            178,
            AdvancedTextWidth,
            26,
            captionFont,
            LabelColor.Secondary
        );

        CreateLabel("Set up this PC", AdvancedEdge, 230, AdvancedTextWidth, 32, sectionFont);
        CreateLabel("Local Network", AdvancedEdge, 270, 470, 28, bodyFont);
        localNetworkStatusLabel = CreateLabel(
            "✓ Ready",
            AdvancedStatusX,
            270,
            AdvancedStatusWidth,
            28,
            bodyFont,
            LabelColor.Green
        );
        CreateLabel("Input Monitoring", AdvancedEdge, 306, 470, 28, bodyFont);
        inputMonitoringStatusLabel = CreateLabel(
            "✓ Complete",
            AdvancedStatusX,
            306,
            AdvancedStatusWidth,
            28,
            bodyFont,
            LabelColor.Green
        );
        CreateLabel("Accessibility", AdvancedEdge, 342, 470, 28, bodyFont);
        accessibilityStatusLabel = CreateLabel(
            "✓ Complete",
            AdvancedStatusX,
            342,
            AdvancedStatusWidth,
            28,
            bodyFont,
            LabelColor.Green
        );
        CreateLabel(
            "Windows does not use macOS privacy prompts. The receiver uses\r\n"
                + "DPAPI for its identity; Windows Defender Firewall may ask\r\n"
                + "for permission on the trusted Private network.",
            AdvancedEdge,
            378,
            AdvancedTextWidth,
            54,
            captionFont,
            LabelColor.Secondary
        );
        CreateButton(
            "Review Windows Firewall Settings",
            AdvancedEdge,
            442,
            310,
            36,
            FirewallButtonID
        );
        inputReadyLabel = CreateLabel(
            "✓ Input permissions ready",
            AdvancedEdge,
            488,
            500,
            28,
            bodyFont,
            LabelColor.Green
        );
        CreateLabel(
            "Control request notifications",
            AdvancedEdge,
            528,
            500,
            28,
            bodyFont
        );
        notificationsStatusLabel = CreateLabel(
            "✓ Enabled",
            AdvancedStatusX,
            528,
            AdvancedStatusWidth,
            28,
            bodyFont,
            LabelColor.Green
        );
        CreateLabel(
            "Native Windows dialogs are shown when automatic control approval\r\n"
                + "is disabled; new pairings are approved by default.",
            AdvancedEdge,
            564,
            AdvancedTextWidth,
            44,
            captionFont,
            LabelColor.Secondary
        );
        CreateButton("Refresh setup status", AdvancedEdge, 620, 230, 36, RefreshButtonID);

        CreateLabel("Physical input path", AdvancedEdge, 700, AdvancedTextWidth, 32, sectionFont);
        CreateLabel(
            "Keyboard, mouse, and trackpad",
            AdvancedEdge,
            744,
            350,
            30,
            bodyFont
        );
        inputPathCombo = CreateComboBox(
            AdvancedInputComboX,
            738,
            AdvancedInputComboWidth,
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
            AdvancedEdge,
            786,
            AdvancedTextWidth,
            58,
            captionFont,
            LabelColor.Secondary
        );

        CreateLabel("Nearby Macs", AdvancedEdge, 884, AdvancedTextWidth, 32, sectionFont);
        nearbyStatusLabel = CreateLabel(
            "Listening for MacKVM pairing requests on the local network…",
            AdvancedEdge,
            926,
            AdvancedTextWidth,
            28,
            captionFont,
            LabelColor.Secondary
        );
        pairedPeerSelector = CreateComboBox(
            AdvancedEdge,
            968,
            AdvancedPeerSelectorWidth,
            34,
            Array.Empty<string>()
        );
        pairedPeerDetailsLabel = CreateLabel(
            "Start Pair on the MacKVM peer; the verification dialog will appear here.",
            AdvancedEdge,
            1004,
            AdvancedTextWidth,
            42,
            captionFont,
            LabelColor.Secondary
        );
        forgetButton = CreateButton(
            "Forget paired Mac",
            AdvancedForgetX,
            964,
            AdvancedForgetWidth,
            36,
            ForgetButtonID
        );
        CreateLabel(
            "Pairing and Connect are initiated from MacKVM. Windows shows\r\n"
                + "the consent dialog once, then keeps the decision with the pinned peer.",
            AdvancedEdge,
            1054,
            AdvancedTextWidth,
            44,
            captionFont,
            LabelColor.Secondary
        );

        CreateLabel(
            "Keyboard, mouse, and trackpad",
            AdvancedEdge,
            1140,
            AdvancedTextWidth,
            32,
            sectionFont
        );
        CreateLabel("Input Monitoring", AdvancedEdge, 1182, 470, 28, bodyFont);
        CreateLabel("✓ Complete", AdvancedStatusX, 1182, AdvancedStatusWidth, 28, bodyFont, LabelColor.Green);
        CreateLabel("Accessibility", AdvancedEdge, 1218, 470, 28, bodyFont);
        CreateLabel("✓ Complete", AdvancedStatusX, 1218, AdvancedStatusWidth, 28, bodyFont, LabelColor.Green);
        controlStateLabel = CreateLabel(
            "Waiting for an authenticated Mac to request control.",
            AdvancedEdge,
            1260,
            AdvancedTextWidth,
            30,
            bodyFont
        );
        CreateLabel(
            "The controlling Mac must pass its own Input Monitoring and\r\n"
                + "Accessibility checks. Windows only accepts authenticated,\r\n"
                + "consented input and releases held keys when control ends.",
            AdvancedEdge,
            1300,
            AdvancedTextWidth,
            58,
            captionFont,
            LabelColor.Secondary
        );
        CreateLabel(
            "Ctrl+Alt+Shift+Esc returns keyboard and mouse control locally.",
            AdvancedEdge,
            1370,
            AdvancedTextWidth,
            28,
            captionFont,
            LabelColor.Secondary
        );

        CreateLabel("Monitor input", AdvancedEdge, 1440, AdvancedTextWidth, 32, sectionFont);
        CreateLabel(
            "External display switching is optional; pairing and remote control\r\n"
                + "work without an external display. Display input switching is\r\n"
                + "controlled from MacKVM or the monitor's OSD input menu.",
            AdvancedEdge,
            1482,
            AdvancedTextWidth,
            58,
            captionFont,
            LabelColor.Secondary
        );
        monitorStatusLabel = CreateLabel(
            "Windows monitor switching is not required for keyboard/mouse sharing.",
            AdvancedEdge,
            1552,
            AdvancedTextWidth,
            28,
            captionFont,
            LabelColor.Secondary
        );

        CreateLabel("Paired device information", AdvancedEdge, 1622, AdvancedTextWidth, 32, sectionFont);
        supportPeerLabel = CreateLabel(
            "This PC: " + runtime.Model,
            AdvancedEdge,
            1664,
            AdvancedTextWidth,
            28,
            bodyFont
        );
        supportFingerprintLabel = CreateLabel(
            WindowsTrayLayoutPolicy.FormatFingerprint(
                "Local key fingerprint",
                Fingerprint(runtime.Identity.SigningPublicKey)
            ),
            AdvancedEdge,
            1700,
            AdvancedTextWidth,
            60,
            monoFont,
            LabelColor.Secondary
        );
        CreateLabel(
            "Private keys are protected by Windows DPAPI and are never included\r\n"
                + "in support information.",
            AdvancedEdge,
            1770,
            AdvancedTextWidth,
            44,
            captionFont,
            LabelColor.Secondary
        );
        controlAuthorizationCheckBox = CreateCheckBox(
            "Automatically allow control from this paired Mac",
            AdvancedEdge,
            1818,
            620,
            30,
            ControlAuthorizationButtonID
        );
        CreateLabel(
            "Enabled by default after pairing; this approval is remembered for the pinned key.\r\n"
                + "Turn it off here when every control request should require confirmation.",
            AdvancedEdge,
            1852,
            AdvancedTextWidth,
            40,
            captionFont,
            LabelColor.Secondary
        );
        CreateButton(
            "Copy support information",
            AdvancedEdge,
            1904,
            250,
            36,
            CopyButtonID
        );
        CreateButton("Quit", AdvancedQuitX, 1904, AdvancedQuitWidth, 36, QuitButtonID);
        CreateLabel(
            "Ready on the local network. Closing this window hides WindowsKVM to the system tray.",
            AdvancedEdge,
            1960,
            AdvancedTextWidth,
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

    /// <summary>
    /// Keeps the Advanced header to three explicit lines. The status row
    /// follows immediately below this label, so including the full
    /// fingerprint or one line per TCP endpoint here would overflow the
    /// native STATIC control and make the live status text appear clipped.
    /// The complete fingerprint remains available in Paired device
    /// information and in Copy support information.
    /// </summary>
    private string FormatHeaderDetails()
    {
        var secure = runtime.SecureConnectAvailable ? "available" : "unavailable";
        return $"Version: {WindowsKvmRuntime.ApplicationVersion} "
            + $"(build {WindowsKvmRuntime.ApplicationBuild})\r\n"
            + $"Model: {runtime.Model}   Device ID: {runtime.Identity.Id.ToString()[..8]}\r\n"
            + $"Pairing TCP: {runtime.PairingPort}   Secure TCP: {runtime.SecurePort} ({secure})";
    }

    private void CreateSimpleControls()
    {
        simpleQuickSetupLabel = RegisterSimpleControl(
            CreateLabel(
                $"This PC: {runtime.Identity.Name}",
                24,
                76,
                472,
                24,
                sectionFont
            )
        );
        simpleDetailsLabel = RegisterSimpleControl(
            CreateLabel(
                $"Version {WindowsKvmRuntime.ApplicationVersion} (build {WindowsKvmRuntime.ApplicationBuild})",
                24,
                104,
                472,
                20,
                captionFont,
                LabelColor.Secondary
            )
        );
        simpleStatusLabel = RegisterSimpleControl(
            CreateLabel(
                lastStatus,
                24,
                128,
                472,
                28,
                captionFont,
                LabelColor.Secondary
            )
        );
        simpleReadinessLabel = RegisterSimpleControl(
            CreateLabel(
                "✓ Network ready • input ready • notifications on",
                24,
                158,
                472,
                28,
                bodyFont,
                LabelColor.Green
            )
        );

        simplePairingHeaderLabel = RegisterSimpleControl(
            CreateLabel("Pairing", 24, 198, 472, 24, sectionFont)
        );
        simplePairLabel = RegisterSimpleControl(
            CreateLabel("No paired Macs yet", 24, 220, 285, 26, bodyFont)
        );
        simplePairDetailsLabel = RegisterSimpleControl(
            CreateLabel(
                "Start Pair on the MacKVM peer; consent appears here.",
                24,
                248,
                472,
                30,
                captionFont,
                LabelColor.Secondary
            )
        );
        simpleForgetButton = RegisterSimpleControl(
            CreateButton("Forget paired Mac", 326, 216, 170, 30, ForgetButtonID)
        );

        simpleControlHeaderLabel = RegisterSimpleControl(
            CreateLabel("Keyboard and mouse", 24, 286, 472, 24, sectionFont)
        );
        simpleControlStateLabel = RegisterSimpleControl(
            CreateLabel(
                "Waiting for a Mac control request.",
                24,
                316,
                472,
                28,
                bodyFont,
                LabelColor.Secondary
            )
        );
        simpleInputPathLabel = RegisterSimpleControl(
            CreateLabel("Input path", 24, 350, 180, 24, captionFont, LabelColor.Secondary)
        );
        simpleInputPathCombo = RegisterSimpleControl(
            CreateComboBox(
                204,
                346,
                292,
                32,
                ["Remote input enabled", "Local Windows input only"]
            )
        );
        simpleRefreshButton = RegisterSimpleControl(
            CreateButton("Refresh", 24, 390, 110, 30, RefreshButtonID)
        );
        simpleQuitButton = RegisterSimpleControl(
            CreateButton("Quit", 386, 390, 110, 30, QuitButtonID)
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

    private IntPtr CreateCheckBox(
        string text,
        int x,
        int y,
        int width,
        int height,
        int command
    ) => CreateChild(
        "BUTTON",
        text,
        ButtonStyleAutoCheckBox | WindowStyleTabStop,
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
            ComboBoxDropDownList | ComboBoxHasStrings | WindowStyleTabStop | WindowStyleVerticalScroll,
            x,
            y,
            width,
            WindowsTrayLayoutPolicy.ComboBoxWindowHeight(height, height, values.Count),
            font: bodyFont
        );
        // Keep the logical row separate from the native expanded-list size.
        // Every later scroll/resize must retain the latter as well; fixing
        // only CreateWindowEx would shrink the list back to one row.
        var layout = childLayouts[^1];
        layout.Height = height;
        var itemHeight = (int)SendMessage(
            combo, ComboBoxGetItemHeight, IntPtr.Zero, IntPtr.Zero
        );
        layout.ComboBoxItemHeight = itemHeight > 0 ? itemHeight : height;
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

    private int CurrentContentHeight
    {
        get
        {
            if (!simpleMode)
            {
                return AdvancedContentHeight;
            }

            var clientWidth = 487;
            if (window != IntPtr.Zero
                && GetClientRect(window, out var client))
            {
                clientWidth = Math.Max(1, client.Right - client.Left);
            }

            return Math.Max(
                SimpleContentHeight,
                WindowsTrayLayoutPolicy.ForSimpleContent(clientWidth).ContentHeight
            );
        }
    }

    private void ResizeMainWindow()
    {
        if (window == IntPtr.Zero)
        {
            return;
        }

        var workArea = GetWorkArea();
        var workWidth = Math.Max(1, workArea.Right - workArea.Left);
        var workHeight = Math.Max(1, workArea.Bottom - workArea.Top);
        var size = simpleMode
            ? WindowsTrayLayoutPolicy.ForSimple(workWidth, workHeight)
            : WindowsTrayLayoutPolicy.ForAdvanced(workWidth, workHeight);
        var x = workArea.Left + Math.Max(0, (workWidth - size.Width) / 2);
        var y = workArea.Top + Math.Max(0, (workHeight - size.Height) / 2);
        _ = SetWindowPos(
            window,
            IntPtr.Zero,
            x,
            y,
            size.Width,
            size.Height,
            WindowPositionNoActivate | WindowPositionNoZOrder
        );
    }

    private void SyncInputPathSelectors()
    {
        var selection = Volatile.Read(ref remoteInputEnabled) != 0
            ? IntPtr.Zero
            : (IntPtr)1;
        foreach (var selector in new[] { inputPathCombo, simpleInputPathCombo })
        {
            if (selector != IntPtr.Zero)
            {
                _ = SendMessage(
                    selector,
                    ComboBoxSetCurrentSelection,
                    selection,
                    IntPtr.Zero
                );
            }
        }
    }

    private NativeRect GetWorkArea(IntPtr referenceWindow = default)
    {
        var monitorWindow = referenceWindow != IntPtr.Zero
            ? referenceWindow
            : window;
        if (monitorWindow != IntPtr.Zero)
        {
            var monitor = MonitorFromWindow(monitorWindow, MonitorDefaultToNearest);
            if (monitor != IntPtr.Zero)
            {
                var monitorInfo = new MonitorInfo
                {
                    Size = (uint)Marshal.SizeOf<MonitorInfo>()
                };
                if (GetMonitorInfo(monitor, ref monitorInfo))
                {
                    return monitorInfo.WorkArea;
                }
            }
        }

        var workArea = new NativeRect();
        if (SystemParametersInfo(
                SystemParametersInfoGetWorkArea,
                0,
                ref workArea,
                0
            ))
        {
            return workArea;
        }

        var width = Math.Max(1, GetSystemMetrics(ScreenMetricWidth));
        var height = Math.Max(1, GetSystemMetrics(ScreenMetricHeight));
        return new NativeRect { Right = width, Bottom = height };
    }

    private int GetWorkAreaWidth() => Math.Max(1, GetWorkArea().Right - GetWorkArea().Left);

    private int GetWorkAreaHeight() => Math.Max(1, GetWorkArea().Bottom - GetWorkArea().Top);

    private void ApplyResponsiveMode()
    {
        if (modeSelectedByUser)
        {
            ReflowClientLayout();
            return;
        }

        SetViewMode(ShouldUseSimpleMode(), userInitiated: false);
    }

    /// <summary>
    /// Reapplies client-relative child bounds after every real WM_SIZE. A
    /// resize can also change the vertical scrollbar's client width, so do a
    /// second pass after updating the scrollbar. The guard prevents a nested
    /// WM_SIZE from recursively moving the same controls while Win32 is still
    /// processing the parent resize.
    /// </summary>
    private void ReflowClientLayout()
    {
        if (window == IntPtr.Zero
            || childLayouts.Count == 0
            || Interlocked.Exchange(ref clientLayoutUpdate, 1) != 0)
        {
            return;
        }

        BeginWindowUpdate();
        try
        {
            MoveChildWindows();
            UpdateScrollBar();
            MoveChildWindows();
            // Showing/hiding the scrollbar can cross a stacking breakpoint.
            // Refresh its range from the resulting content height as well.
            UpdateScrollBar();
        }
        finally
        {
            EndWindowUpdate();
            Volatile.Write(ref clientLayoutUpdate, 0);
        }
    }

    private bool ShouldUseSimpleMode()
    {
        // Simple mode is the safe default even on a large display. Advanced
        // mode remains an explicit user choice and is retained across resize
        // notifications through modeSelectedByUser.
        return true;
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
            ReflowClientLayout();
            return;
        }

        scrollPosition = 0;
        horizontalScrollPosition = 0;
        ResizeMainWindow();
        SyncInputPathSelectors();
        BeginWindowUpdate();
        try
        {
            foreach (var layout in childLayouts)
            {
                var visible = ShouldShowChild(layout.Handle);
                _ = ShowWindow(
                    layout.Handle,
                    visible ? ShowWindowShow : ShowWindowHide
                );
            }

            MoveChildWindows();
            UpdateScrollBar();
        }
        finally
        {
            EndWindowUpdate();
        }

        UpdateForgetButtonState(pairedPeerName is not null);
        UpdateControlAuthorizationControls();
    }

    /// <summary>
    /// Suspends the parent redraw while a layout or state refresh changes many
    /// child windows. The depth counter keeps nested calls (for example a
    /// scroll-bar correction during a mode switch) from re-enabling redraw too
    /// early.
    /// </summary>
    private void BeginWindowUpdate()
    {
        if (window == IntPtr.Zero)
        {
            return;
        }

        if (windowUpdateDepth++ == 0)
        {
            // WM_SETREDRAW(FALSE) removes WS_VISIBLE from the target. Capture
            // the visible children before disabling the parent because
            // IsWindowVisible(child) also depends on the parent's visibility.
            // Do not send WM_SETREDRAW to hidden mode-specific controls: the
            // corresponding TRUE message would make them visible again.
            windowWasVisibleBeforeUpdate = IsWindowVisible(window);
            redrawEnabledChildren.Clear();
            if (windowWasVisibleBeforeUpdate)
            {
                foreach (var layout in childLayouts)
                {
                    if (IsWindowVisible(layout.Handle))
                    {
                        redrawEnabledChildren.Add(layout.Handle);
                    }
                }
            }

            _ = SendMessage(
                window,
                WindowMessageSetRedraw,
                IntPtr.Zero,
                IntPtr.Zero
            );
            foreach (var child in redrawEnabledChildren)
            {
                _ = SendMessage(
                    child,
                    WindowMessageSetRedraw,
                    IntPtr.Zero,
                    IntPtr.Zero
                );
            }
        }
    }

    private void EndWindowUpdate()
    {
        if (window == IntPtr.Zero || windowUpdateDepth == 0)
        {
            return;
        }

        if (--windowUpdateDepth == 0)
        {
            foreach (var child in redrawEnabledChildren)
            {
                // A control can have been hidden by the update itself (for
                // example when a peer is forgotten or the view mode changes).
                // Re-enabling WM_SETREDRAW on that control would otherwise
                // make it visible again, so restore the current logical
                // visibility while the parent is still redraw-disabled.
                var shouldBeVisible = ShouldShowChild(child);
                _ = SendMessage(
                    child,
                    WindowMessageSetRedraw,
                    (IntPtr)1,
                    IntPtr.Zero
                );
                if (!shouldBeVisible)
                {
                    _ = ShowWindow(child, ShowWindowHide);
                }
            }
            redrawEnabledChildren.Clear();
            _ = SendMessage(
                window,
                WindowMessageSetRedraw,
                (IntPtr)1,
                IntPtr.Zero
            );

            // DefWindowProc makes a hidden window visible when WM_SETREDRAW
            // is re-enabled. Restore the parent/tray state that existed when
            // this update transaction began before asking it to repaint.
            if (!windowWasVisibleBeforeUpdate)
            {
                _ = ShowWindow(window, ShowWindowHide);
            }
            RedrawWindowContent();
        }
    }

    private bool ShouldShowChild(IntPtr child)
    {
        var isCommon = !advancedControls.Contains(child)
            && !simpleControls.Contains(child);
        if (!isCommon)
        {
            var isModeVisible = simpleMode
                ? simpleControls.Contains(child)
                : advancedControls.Contains(child);
            if (!isModeVisible)
            {
                return false;
            }
        }

        if (child == forgetButton || child == simpleForgetButton)
        {
            return Volatile.Read(ref pairedPeerName) is not null;
        }

        return true;
    }

    /// <summary>
    /// Moves every child in one deferred-position transaction. This avoids a
    /// visible sequence of partially moved rows while the user scrolls or
    /// switches between Simple and Advanced mode.
    /// </summary>
    private void MoveChildWindows()
    {
        if (childLayouts.Count == 0)
        {
            return;
        }

        var hasClient = GetClientRect(window, out var client);
        var simpleLayout = simpleMode
            ? WindowsTrayLayoutPolicy.ForSimpleContent(
                hasClient ? Math.Max(1, client.Right - client.Left) : 487
            )
            : default;

        var deferred = BeginDeferWindowPos(childLayouts.Count);
        if (deferred != IntPtr.Zero)
        {
            var current = deferred;
            foreach (var layout in childLayouts)
            {
                var bounds = ResolveNativeChildBounds(layout, simpleLayout);
                current = DeferWindowPos(
                    current,
                    layout.Handle,
                    IntPtr.Zero,
                    bounds.X,
                    bounds.Y,
                    bounds.Width,
                    bounds.Height,
                    WindowPositionNoRedraw
                        | WindowPositionNoCopyBits
                        | WindowPositionNoActivate
                        | WindowPositionNoZOrder
                );
                if (current == IntPtr.Zero)
                {
                    break;
                }
            }

            if (current != IntPtr.Zero && EndDeferWindowPos(current))
            {
                return;
            }
        }

        // The deferred API is available on supported Windows versions, but a
        // conservative fallback keeps the UI functional if allocation fails.
        foreach (var layout in childLayouts)
        {
            var bounds = ResolveNativeChildBounds(layout, simpleLayout);
            _ = SetWindowPos(
                layout.Handle,
                IntPtr.Zero,
                bounds.X,
                bounds.Y,
                bounds.Width,
                bounds.Height,
                WindowPositionNoRedraw
                    | WindowPositionNoCopyBits
                    | WindowPositionNoActivate
                    | WindowPositionNoZOrder
            );
        }
    }

    private WindowsTrayChildBounds ResolveNativeChildBounds(
        ChildLayout layout,
        WindowsTraySimpleLayout simpleLayout
    ) => WindowsTrayLayoutPolicy.ForNativeChild(
        ResolveChildBounds(layout, simpleLayout),
        simpleMode ? 0 : horizontalScrollPosition,
        scrollPosition,
        layout.ComboBoxItemHeight,
        layout.ComboBoxItemHeight > 0
            ? (int)SendMessage(layout.Handle, ComboBoxGetCount, IntPtr.Zero, IntPtr.Zero)
            : 0
    );

    private WindowsTrayChildBounds ResolveChildBounds(
        ChildLayout layout,
        WindowsTraySimpleLayout simpleLayout
    )
    {
        if (!simpleMode)
        {
            return new WindowsTrayChildBounds(
                layout.X,
                layout.Y,
                layout.Width,
                layout.Height
            );
        }

        var control = layout.Handle switch
        {
            var handle when handle == titleLabel => WindowsTraySimpleControl.Title,
            var handle when handle == modeButton => WindowsTraySimpleControl.ModeButton,
            var handle when handle == simpleQuickSetupLabel => WindowsTraySimpleControl.QuickSetup,
            var handle when handle == simpleDetailsLabel => WindowsTraySimpleControl.Details,
            var handle when handle == simpleStatusLabel => WindowsTraySimpleControl.Status,
            var handle when handle == simpleReadinessLabel => WindowsTraySimpleControl.Readiness,
            var handle when handle == simplePairingHeaderLabel => WindowsTraySimpleControl.PairingHeader,
            var handle when handle == simplePairLabel => WindowsTraySimpleControl.PairName,
            var handle when handle == simplePairDetailsLabel => WindowsTraySimpleControl.PairDetails,
            var handle when handle == simpleForgetButton => WindowsTraySimpleControl.Forget,
            var handle when handle == simpleControlHeaderLabel => WindowsTraySimpleControl.ControlHeader,
            var handle when handle == simpleControlStateLabel => WindowsTraySimpleControl.ControlState,
            var handle when handle == simpleInputPathLabel => WindowsTraySimpleControl.InputPathLabel,
            var handle when handle == simpleInputPathCombo => WindowsTraySimpleControl.InputPathCombo,
            var handle when handle == simpleRefreshButton => WindowsTraySimpleControl.Refresh,
            var handle when handle == simpleQuitButton => WindowsTraySimpleControl.Quit,
            _ => (WindowsTraySimpleControl?)null
        };

        return control is { } value
            ? simpleLayout[value]
            : new WindowsTrayChildBounds(
                layout.X,
                layout.Y,
                layout.Width,
                layout.Height
            );
    }

    private void RedrawWindowContent()
    {
        if (window == IntPtr.Zero || !IsWindowVisible(window))
        {
            return;
        }

        _ = RedrawWindow(
            window,
            IntPtr.Zero,
            IntPtr.Zero,
            // Moving rows must discard cached pixels (SWP_NOCOPYBITS above)
            // and repaint parent, descendants, and control borders together.
            // Parent-only invalidation in Beta 3 left stale child text behind.
            RedrawInvalidate | RedrawErase | RedrawAllChildren | RedrawFrame | RedrawUpdateNow
        );
        _ = UpdateWindow(window);
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

            var background = backgroundBrush != IntPtr.Zero
                ? backgroundBrush
                : GetSysColorBrush(SystemColorWindow);
            _ = FillRect(hdc, ref client, background);

            var separator = separatorBrush != IntPtr.Zero
                ? separatorBrush
                : GetSysColorBrush(SystemColorWindow);
            if (separator != IntPtr.Zero)
            {
                var separators = simpleMode
                    ? new[] { 190, 278, 430 }
                    : new[] { 204, 674, 848, 1098, 1408, 1606, 1850 };
                foreach (var contentY in separators)
                {
                    var lineY = contentY - scrollPosition;
                    if (lineY < client.Top || lineY >= client.Bottom)
                    {
                        continue;
                    }

                    var line = new NativeRect
                    {
                        Left = 32 - (simpleMode ? 0 : horizontalScrollPosition),
                        Top = lineY,
                        Right = simpleMode
                            ? Math.Max(32, client.Right - 32)
                            : Math.Max(
                                32 - horizontalScrollPosition,
                                WindowsTrayLayoutPolicy.AdvancedContentWidth
                                    - 20
                                    - horizontalScrollPosition
                            ),
                        Bottom = lineY + 1
                    };
                    _ = FillRect(hdc, ref line, separator);
                }
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
        var color = ThemePrimaryTextColor;
        if (greenLabels.Contains(control))
        {
            color = ThemeSuccessTextColor;
        }
        else if (orangeLabels.Contains(control))
        {
            color = ThemeWarningTextColor;
        }
        else if (secondaryLabels.Contains(control))
        {
            color = ThemeSecondaryTextColor;
        }
        _ = SetTextColor(hdc, color);
        return backgroundBrush != IntPtr.Zero
            ? backgroundBrush
            : GetSysColorBrush(SystemColorWindow);
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
        UpdateHorizontalScrollBar(client.Right - client.Left);
    }

    private void UpdateHorizontalScrollBar(int clientWidth)
    {
        if (window == IntPtr.Zero)
        {
            return;
        }

        if (simpleMode)
        {
            horizontalScrollPosition = 0;
            _ = ShowScrollBar(window, ScrollBarHorizontal, false);
            return;
        }

        var page = Math.Max(1, clientWidth);
        var maximum = WindowsTrayLayoutPolicy.AdvancedHorizontalMaximum(page);
        horizontalScrollPosition = WindowsTrayLayoutPolicy.ClampHorizontalOffset(
            true,
            page,
            horizontalScrollPosition
        );
        var info = new ScrollInfo
        {
            Size = (uint)Marshal.SizeOf<ScrollInfo>(),
            Mask = ScrollInfoRange | ScrollInfoPage | ScrollInfoPosition,
            Minimum = 0,
            Maximum = Math.Max(0, WindowsTrayLayoutPolicy.AdvancedContentWidth - 1),
            Page = (uint)page,
            Position = horizontalScrollPosition
        };
        _ = SetScrollInfo(window, ScrollBarHorizontal, ref info, true);
        _ = ShowScrollBar(
            window,
            ScrollBarHorizontal,
            maximum > 0
        );
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

    private void HandleHorizontalScroll(int command)
    {
        if (simpleMode || !GetClientRect(window, out var client))
        {
            return;
        }

        var page = Math.Max(1, client.Right - client.Left);
        var maximum = WindowsTrayLayoutPolicy.AdvancedHorizontalMaximum(page);
        var next = horizontalScrollPosition;
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
                if (GetScrollInfo(window, ScrollBarHorizontal, ref info))
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

        SetHorizontalScrollPosition(Math.Clamp(next, 0, maximum));
    }

    private void SetHorizontalScrollPosition(int position)
    {
        if (simpleMode)
        {
            horizontalScrollPosition = 0;
            return;
        }

        var clientWidth = 1;
        if (window != IntPtr.Zero && GetClientRect(window, out var client))
        {
            clientWidth = Math.Max(1, client.Right - client.Left);
        }

        var next = WindowsTrayLayoutPolicy.ClampHorizontalOffset(
            true,
            clientWidth,
            position
        );
        if (next == horizontalScrollPosition)
        {
            return;
        }

        horizontalScrollPosition = next;
        BeginWindowUpdate();
        try
        {
            MoveChildWindows();
            UpdateHorizontalScrollBar(clientWidth);
        }
        finally
        {
            EndWindowUpdate();
        }
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
        BeginWindowUpdate();
        try
        {
            MoveChildWindows();
            if (window != IntPtr.Zero)
            {
                var info = new ScrollInfo
                {
                    Size = (uint)Marshal.SizeOf<ScrollInfo>(),
                    Mask = ScrollInfoPosition,
                    Position = scrollPosition
                };
                _ = SetScrollInfo(window, ScrollBarVertical, ref info, true);
            }
        }
        finally
        {
            EndWindowUpdate();
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

        // Keep the legacy NOTIFYICON callback contract. NOTIFYICON_VERSION_4
        // changes the event encoding (and uses WM_CONTEXTMENU for the right
        // button), while HandleTrayMessage intentionally handles the legacy
        // WM_LBUTTONDBLCLK/WM_RBUTTONUP values. Opting into v4 without decoding
        // its packed lParam makes the tray icon unable to reopen or quit the
        // hidden application.
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
        // WM_GETMINMAXINFO is sent during CreateWindowEx, before the new
        // HWND has been assigned to the window field. Handle that initial
        // main-window message as well as later messages for the bound HWND;
        // child/popup HWNDs continue through their normal default procedure.
        if (target != IntPtr.Zero
            && message == WindowMessageGetMinMaxInfo
            && (target == window || window == IntPtr.Zero))
        {
            ApplyMinimumWindowSize(target, lParam);
            return IntPtr.Zero;
        }

        if (target == consentWindow && target != IntPtr.Zero)
        {
            return HandleConsentWindowMessage(target, message, wParam, lParam);
        }

        // The consent popup uses the registered class only to keep one WndProc
        // alive. Its creation messages arrive before consentWindow is bound;
        // never route those HWNDs through the main window's layout handlers.
        if (target != window)
        {
            return DefWindowProcedure(target, message, wParam, lParam);
        }

        switch (message)
        {
            case WindowMessageClose:
                ShowWindow(target, ShowWindowHide);
                return IntPtr.Zero;

            case WindowMessagePaint:
                PaintBackground(target);
                return IntPtr.Zero;

            case WindowMessageSize:
                // Reflow even when the selected mode is unchanged. Dragging
                // the window narrower must update Simple child widths and
                // right-aligned actions; the old path only touched the
                // scrollbar after a user-selected mode.
                ApplyResponsiveMode();
                return IntPtr.Zero;

            case WindowMessageVScroll:
                HandleVerticalScroll(unchecked((int)wParam.ToInt64() & 0xFFFF));
                return IntPtr.Zero;

            case WindowMessageHScroll:
                HandleHorizontalScroll(unchecked((int)wParam.ToInt64() & 0xFFFF));
                return IntPtr.Zero;

            case WindowMessageMouseWheel:
                HandleMouseWheel(unchecked((short)((wParam.ToInt64() >> 16) & 0xFFFF)));
                return IntPtr.Zero;

            case WindowMessageControlColorStatic:
                return PaintStaticControl(wParam, lParam);

            case WindowMessageCommand:
                var notification = unchecked((int)((wParam.ToInt64() >> 16) & 0xFFFF));
                var command = unchecked((int)wParam.ToInt64() & 0xFFFF);
                if (notification == ComboBoxSelectionChanged
                    && (lParam == inputPathCombo || lParam == simpleInputPathCombo))
                {
                    HandleInputPathSelection();
                }
                else if (notification == ComboBoxSelectionChanged
                    && lParam == pairedPeerSelector)
                {
                    HandlePairedPeerSelection();
                }
                else
                {
                    HandleCommand(command);
                }
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

            case WindowMessageConsentCancel:
                HandleConsentCancellation(wParam.ToInt64());
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

    private void ApplyMinimumWindowSize(IntPtr target, IntPtr lParam)
    {
        if (lParam == IntPtr.Zero)
        {
            return;
        }

        var workArea = GetWorkArea(target);
        var minimum = WindowsTrayLayoutPolicy.MinimumWindowSize(
            Math.Max(1, workArea.Right - workArea.Left),
            Math.Max(1, workArea.Bottom - workArea.Top)
        );
        var info = Marshal.PtrToStructure<MinMaxInfo>(lParam);
        info.MinTrackSize.X = Math.Max(info.MinTrackSize.X, minimum.Width);
        info.MinTrackSize.Y = Math.Max(info.MinTrackSize.Y, minimum.Height);
        Marshal.StructureToPtr(info, lParam, fDeleteOld: false);
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
            case ControlAuthorizationButtonID:
                HandleControlAuthorizationSelection();
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

    private void HandleInputPathSelection()
    {
        var selector = simpleMode ? simpleInputPathCombo : inputPathCombo;
        if (selector == IntPtr.Zero)
        {
            return;
        }

        var selection = SendMessage(
            selector,
            ComboBoxGetCurrentSelection,
            IntPtr.Zero,
            IntPtr.Zero
        ).ToInt64();
        var enabled = selection != 1;
        Volatile.Write(ref remoteInputEnabled, enabled ? 1 : 0);
        runtime.SetRemoteInputEnabled(enabled);
        SyncInputPathSelectors();
        OnRuntimeStatusChanged(
            enabled
                ? "Remote keyboard and mouse input enabled."
                : "Local Windows input only; remote control requests are disabled."
        );
    }

    private void HandlePairedPeerSelection()
    {
        if (updatingPeerSelector || pairedPeerSelector == IntPtr.Zero)
        {
            return;
        }

        var selection = SendMessage(
            pairedPeerSelector,
            ComboBoxGetCurrentSelection,
            IntPtr.Zero,
            IntPtr.Zero
        ).ToInt64();
        if (selection < 0 || selection >= pairedPeerOptions.Count)
        {
            return;
        }

        var selectedID = pairedPeerOptions[(int)selection];
        var peer = runtime.TrustedPeers.FirstOrDefault(candidate => candidate.Id == selectedID);
        if (peer is null)
        {
            return;
        }

        SetPairedPeer(peer);
        OnRuntimeStatusChanged($"Selected paired Mac {peer.Name}.");
    }

    private void HandleControlAuthorizationSelection()
    {
        var peerIDText = Volatile.Read(ref pairedPeerFullID);
        if (!Guid.TryParse(peerIDText, out var peerID))
        {
            UpdateControlAuthorizationControls();
            OnRuntimeStatusChanged(
                "Select a paired Mac before changing automatic control approval."
            );
            return;
        }

        // Automatic approval is intentionally an Advanced-mode setting. The
        // compact view still exposes the current control state and Forget
        // action, but never places a hidden checkbox in the command path.
        var checkBox = controlAuthorizationCheckBox;
        var authorized = checkBox != IntPtr.Zero
            && SendMessage(
                checkBox,
                ButtonGetCheck,
                IntPtr.Zero,
                IntPtr.Zero
            ).ToInt64() == ButtonStateChecked;
        try
        {
            if (!runtime.SetControlAuthorization(peerID, authorized))
            {
                UpdateControlAuthorizationControls();
                OnRuntimeStatusChanged(
                    "The selected Mac is no longer trusted; pair it again before changing control approval."
                );
                return;
            }

            UpdateControlAuthorizationControls();
            var peerName = Volatile.Read(ref pairedPeerName) ?? "the paired Mac";
            OnRuntimeStatusChanged(
                authorized
                    ? $"Automatic control approval enabled for {peerName}."
                    : $"Automatic control approval disabled for {peerName}; confirmation is required."
            );
        }
        catch (Exception ex)
        {
            UpdateControlAuthorizationControls();
            OnRuntimeStatusChanged(
                $"Could not update automatic control approval: {ex.Message}"
            );
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
            $"{prompt}\n\nAllow this authenticated peer to control this Windows PC?\n\n"
                + "Automatic approval is enabled by default after pairing. "
                + "Uncheck automatic approval in Paired device information "
                + "to require confirmation again.",
            "WindowsKVM control request",
            token
        );

    private Task<bool> RequestConsentAsync(
        string text,
        string title,
        CancellationToken token
    )
    {
        if (window == IntPtr.Zero || token.IsCancellationRequested)
        {
            return Task.FromResult(false);
        }

        return consentRequests.EnqueueAsync(text, title, token);
    }

    private void HandleConsentRequest(long _)
    {
        PumpConsentRequests();
    }

    private void HandleConsentCancellation(long id)
    {
        // Cancellation may have completed the request before this message
        // reached the UI thread. Destroy only the popup still bound to that
        // exact request, then serialize the next queued prompt.
        DismissConsentWindow(id);
        PumpConsentRequests();
    }

    private void PumpConsentRequests()
    {
        if (consentWindow != IntPtr.Zero)
        {
            return;
        }

        if (!consentRequests.TryBeginNext(out var prompt))
        {
            return;
        }

        if (ShowConsentWindow(prompt))
        {
            return;
        }

        // A failed window creation is a visible denial to the receiver. The
        // coordinator clears the request before the next pump, so no late UI
        // callback can turn the failed request into a grant.
        consentRequests.TryComplete(prompt.ID, accepted: false);
    }

    private bool ShowConsentWindow(ConsentRequestCoordinator.Prompt prompt)
    {
        var workArea = GetWorkArea();
        var workWidth = Math.Max(1, workArea.Right - workArea.Left);
        var workHeight = Math.Max(1, workArea.Bottom - workArea.Top);
        var popupWidth = Math.Min(
            ConsentWindowWidth,
            Math.Max(320, workWidth - 32)
        );
        if (workWidth < 320)
        {
            popupWidth = workWidth;
        }

        // The consent frame is deliberately fixed-size. Its text control is
        // a read-only multiline EDIT with a vertical scrollbar, so long
        // pairing verification and key-replacement warnings remain available
        // without pushing the Allow/Deny buttons outside the client area.
        var popupHeight = Math.Min(
            Math.Max(ConsentWindowHeight, 260),
            Math.Max(260, workHeight - 24)
        );
        if (workHeight < 260)
        {
            popupHeight = workHeight;
        }

        var x = workArea.Left + Math.Max(0, (workWidth - popupWidth) / 2);
        var y = workArea.Top + Math.Max(0, (workHeight - popupHeight) / 2);
        var popup = CreateWindow(
            WindowClassName,
            prompt.Title,
            ConsentWindowStyle | WindowStyleClipChildren,
            x,
            y,
            popupWidth,
            popupHeight,
            IntPtr.Zero,
            IntPtr.Zero
        );
        if (popup == IntPtr.Zero)
        {
            return false;
        }

        consentWindow = popup;
        consentWindowRequestID = prompt.ID;
        if (!GetClientRect(popup, out var client))
        {
            DismissConsentWindow(prompt.ID);
            return false;
        }

        var clientWidth = Math.Max(1, client.Right - client.Left);
        var clientHeight = Math.Max(1, client.Bottom - client.Top);
        const int edge = 24;
        const int buttonHeight = 32;
        const int buttonGap = 12;
        const int buttonBottomGap = 16;
        var buttonY = Math.Max(
            edge,
            clientHeight - buttonBottomGap - buttonHeight
        );
        var textBottom = Math.Max(edge, buttonY - buttonGap);
        var textHeight = Math.Max(1, textBottom - edge);
        var denyX = Math.Max(edge, clientWidth - edge - 96);
        var allowX = Math.Max(edge, denyX - buttonGap - 96);
        consentTextLabel = CreateWindow(
            "EDIT",
            prompt.Text.Replace("\r\n", "\n").Replace("\n", "\r\n"),
            WindowStyleChild
                | WindowStyleVisible
                | EditStyleMultiline
                | EditStyleAutoVScroll
                | EditStyleReadOnly
                | EditStyleWantReturn
                | WindowStyleVerticalScroll,
            edge,
            edge,
            Math.Max(1, clientWidth - edge * 2),
            textHeight,
            consentWindow,
            IntPtr.Zero
        );
        consentYesButton = CreateWindow(
            "BUTTON",
            "Allow",
            WindowStyleChild | WindowStyleVisible | WindowStyleTabStop | ButtonStylePushButton,
            allowX,
            buttonY,
            96,
            buttonHeight,
            consentWindow,
            (IntPtr)ConsentYesButtonID
        );
        consentNoButton = CreateWindow(
            "BUTTON",
            "Deny",
            WindowStyleChild | WindowStyleVisible | WindowStyleTabStop | ButtonStylePushButton,
            denyX,
            buttonY,
            96,
            buttonHeight,
            consentWindow,
            (IntPtr)ConsentNoButtonID
        );
        if (consentTextLabel == IntPtr.Zero
            || consentYesButton == IntPtr.Zero
            || consentNoButton == IntPtr.Zero)
        {
            DismissConsentWindow(prompt.ID);
            return false;
        }

        if (bodyFont != IntPtr.Zero)
        {
            _ = SendMessage(consentTextLabel, WindowMessageSetFont, bodyFont, IntPtr.Zero);
        }
        if (captionFont != IntPtr.Zero)
        {
            _ = SendMessage(consentYesButton, WindowMessageSetFont, captionFont, IntPtr.Zero);
            _ = SendMessage(consentNoButton, WindowMessageSetFont, captionFont, IntPtr.Zero);
        }

        ShowWindow(consentWindow, ShowWindowShow);
        SetForegroundWindow(consentWindow);
        UpdateWindow(consentWindow);
        _ = SetFocus(consentNoButton);
        return true;
    }

    private IntPtr HandleConsentWindowMessage(
        IntPtr target,
        uint message,
        IntPtr wParam,
        IntPtr lParam
    )
    {
        switch (message)
        {
            case WindowMessageCommand:
                var command = unchecked((int)wParam.ToInt64() & 0xFFFF);
                if (command == ConsentYesButtonID || command == ConsentNoButtonID)
                {
                    consentRequests.TryComplete(
                        consentWindowRequestID,
                        accepted: command == ConsentYesButtonID
                    );
                }
                return IntPtr.Zero;

            case WindowMessageClose:
                consentRequests.TryComplete(
                    consentWindowRequestID,
                    accepted: false
                );
                return IntPtr.Zero;

            case WindowMessageDestroy:
                if (target == consentWindow)
                {
                    consentWindow = IntPtr.Zero;
                    consentWindowRequestID = 0;
                    consentTextLabel = IntPtr.Zero;
                    consentYesButton = IntPtr.Zero;
                    consentNoButton = IntPtr.Zero;
                }
                return IntPtr.Zero;

            default:
                return DefWindowProcedure(target, message, wParam, lParam);
        }
    }

    private void DismissConsentWindow(long id)
    {
        if (id == 0
            || consentWindow == IntPtr.Zero
            || consentWindowRequestID != id)
        {
            return;
        }

        _ = DestroyWindow(consentWindow);
    }

    private void ResolvePendingConsents()
    {
        consentRequests.Dispose();
        if (consentWindow != IntPtr.Zero)
        {
            DismissConsentWindow(consentWindowRequestID);
        }
    }

    private void OnRuntimeStatusChanged(string message)
    {
        Volatile.Write(ref lastStatus, message);
        Volatile.Write(ref statusDirty, 1);
        ScheduleStatusDrain();
    }

    private void OnPairingCompleted(WindowsKVM.Protocol.PeerIdentity peer)
    {
        // Pairing completes on the receiver's network task. Defer all Win32
        // control mutations to the message-loop thread; doing this directly
        // while a scroll or paint is in progress can tear the UI.
        pendingPairedPeers.Enqueue(peer);
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
        UpdateControlAuthorizationControls();
    }

    private void UpdateControlAuthorizationControls()
    {
        var peerIDText = Volatile.Read(ref pairedPeerFullID);
        var hasPeer = Guid.TryParse(peerIDText, out var peerID);
        var authorized = hasPeer && runtime.IsControlAuthorized(peerID);
        foreach (var checkBox in new[]
        {
            controlAuthorizationCheckBox
        })
        {
            if (checkBox == IntPtr.Zero)
            {
                continue;
            }

            _ = EnableWindow(checkBox, hasPeer);
            _ = SendMessage(
                checkBox,
                ButtonSetCheck,
                authorized ? (IntPtr)ButtonStateChecked : IntPtr.Zero,
                IntPtr.Zero
            );
        }
    }

    private void RefreshPairedPeerSelector(IReadOnlyList<WindowsKVM.Protocol.PeerIdentity> peers)
    {
        if (pairedPeerSelector == IntPtr.Zero)
        {
            return;
        }

        var selectedID = Volatile.Read(ref pairedPeerFullID);
        var selectedIndex = -1;
        pairedPeerOptions.Clear();
        updatingPeerSelector = true;
        try
        {
            _ = SendMessage(
                pairedPeerSelector,
                ComboBoxResetContent,
                IntPtr.Zero,
                IntPtr.Zero
            );
            foreach (var peer in peers)
            {
                pairedPeerOptions.Add(peer.Id);
                _ = SendMessage(
                    pairedPeerSelector,
                    ComboBoxAddString,
                    IntPtr.Zero,
                    $"{peer.Name} ({peer.Id.ToString("N")[..8]})"
                );
                if (string.Equals(
                        selectedID,
                        peer.Id.ToString("D"),
                        StringComparison.OrdinalIgnoreCase
                    ))
                {
                    selectedIndex = pairedPeerOptions.Count - 1;
                }
            }

            if (selectedIndex < 0 && peers.Count > 0)
            {
                // Snapshot order is deterministic and all peers remain
                // selectable; this only chooses the initial fallback when a
                // previously selected peer was removed.
                selectedIndex = 0;
                SetPairedPeer(peers[0]);
            }
            else if (peers.Count == 0 && selectedID is not null)
            {
                SetPairedPeer(null);
            }

            if (selectedIndex >= 0)
            {
                _ = SendMessage(
                    pairedPeerSelector,
                    ComboBoxSetCurrentSelection,
                    (IntPtr)selectedIndex,
                    IntPtr.Zero
                );
            }
        }
        finally
        {
            updatingPeerSelector = false;
        }
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
                SetPairedPeer(runtime.TrustedPeers.FirstOrDefault());
                OnRuntimeStatusChanged(
                    "The paired Mac was already forgotten; pair again before connecting."
                );
                return;
            }

            SetPairedPeer(runtime.TrustedPeers.FirstOrDefault());
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
        // Claim the current batch before reading it. A callback that arrives
        // while the UI is applying this snapshot leaves the dirty bit set and
        // is posted as a follow-up instead of being overwritten at the end.
        Volatile.Write(ref statusDirty, 0);
        var latestStatus = Volatile.Read(ref lastStatus);

        WindowsKVM.Protocol.PeerIdentity? latestPeer = null;
        while (pendingPairedPeers.TryDequeue(out var peer))
        {
            latestPeer = peer;
        }

        BeginWindowUpdate();
        try
        {
            if (latestStatus is not null)
            {
                SetWindowText(statusLabel, latestStatus);
            }

            if (latestPeer is not null)
            {
                SetPairedPeer(latestPeer);
            }

            var peers = runtime.TrustedPeers;
            RefreshPairedPeerSelector(peers);
            UpdateControlAuthorizationControls();
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
                SetWindowText(
                    pairedPeerDetailsLabel,
                    "Start Pair on the MacKVM peer; the verification dialog will appear here."
                );
            }
            else
            {
                SetWindowText(nearbyStatusLabel, $"Paired with {peerName}; ready for Connect.");
                SetLabelColor(nearbyStatusLabel, LabelColor.Green);
                SetWindowText(
                    pairedPeerDetailsLabel,
                    $"Device ID: {peerID}\r\nKey fingerprint: {peerFingerprint}"
                );
            }
            UpdateForgetButtonState(peerName is not null);

            var isControlActive = Volatile.Read(ref controlActive) != 0;
            var remoteInputIsEnabled = Volatile.Read(ref remoteInputEnabled) != 0;
            SetWindowText(
                controlStateLabel,
                !remoteInputIsEnabled
                    ? "Local Windows input only; remote control requests are disabled."
                    : isControlActive
                    ? "This Windows PC is receiving keyboard and mouse control."
                    : "Waiting for an authenticated Mac to request control."
            );
            SetLabelColor(
                controlStateLabel,
                !remoteInputIsEnabled
                    ? LabelColor.Orange
                    : isControlActive ? LabelColor.Green : LabelColor.Secondary
            );

            var secure = runtime.SecureConnectAvailable
                ? "Secure Connect available"
                : "Secure Connect unavailable on this Windows build";
            SetWindowText(
                detailLabel,
                FormatHeaderDetails()
            );
            SetWindowText(
                supportPeerLabel,
                peerName is null
                    ? "This PC: " + runtime.Model
                    : $"Paired Mac: {peerName}   (This PC: {runtime.Model})"
            );
            SetWindowText(
                supportFingerprintLabel,
                WindowsTrayLayoutPolicy.FormatFingerprint(
                    "Local key fingerprint",
                    Fingerprint(runtime.Identity.SigningPublicKey)
                )
            );
            SetWindowText(
                monitorStatusLabel,
                secure
                    + ". Display input switching is handled by MacKVM or the monitor OSD."
            );

            SetWindowText(simpleStatusLabel, latestStatus ?? string.Empty);
            SetWindowText(
                simpleDetailsLabel,
                $"Version {WindowsKvmRuntime.ApplicationVersion} (build {WindowsKvmRuntime.ApplicationBuild})"
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
                    ? "Start Pair on the MacKVM peer; consent appears here."
                    : "Ready for Connect from this paired Mac."
            );
            SetWindowText(
                simpleControlStateLabel,
                !remoteInputIsEnabled
                    ? "Remote control is disabled; Windows input stays local."
                    : isControlActive
                    ? "Control active on this PC."
                    : "Waiting for a Mac control request."
            );
            SetLabelColor(
                simpleControlStateLabel,
                !remoteInputIsEnabled
                    ? LabelColor.Orange
                    : isControlActive ? LabelColor.Green : LabelColor.Secondary
            );
        }
        finally
        {
            EndWindowUpdate();
        }

        // Keep the post latch while a follow-up is known to be needed. This
        // drain owns the current queued message, so posting directly avoids a
        // race with ScheduleStatusDrain observing the latch as already set.
        if (Volatile.Read(ref statusDirty) != 0 || !pendingPairedPeers.IsEmpty)
        {
            if (!PostMessage(window, WindowMessageStatus, IntPtr.Zero, IntPtr.Zero))
            {
                Volatile.Write(ref statusMessagePosted, 0);
            }
            return;
        }

        // Release the latch only after the final clean check. If a callback
        // raced that check while the latch was still held, reclaim it and post
        // one more drain; if it arrived after the release, its own callback
        // will have observed the zero latch and posted normally.
        if (Interlocked.CompareExchange(ref statusMessagePosted, 0, 1) != 1)
        {
            return;
        }

        if (Volatile.Read(ref statusDirty) != 0 || !pendingPairedPeers.IsEmpty)
        {
            if (Interlocked.CompareExchange(ref statusMessagePosted, 1, 0) == 0
                && !PostMessage(window, WindowMessageStatus, IntPtr.Zero, IntPtr.Zero))
            {
                Volatile.Write(ref statusMessagePosted, 0);
            }
        }
    }

    private void ScheduleStatusDrain()
    {
        if (window == IntPtr.Zero
            || Interlocked.Exchange(ref statusMessagePosted, 1) != 0)
        {
            return;
        }

        if (!PostMessage(window, WindowMessageStatus, IntPtr.Zero, IntPtr.Zero))
        {
            // If the window is already being destroyed, allow a future
            // status callback to make a best-effort post without leaving the
            // coalescing latch permanently set.
            Volatile.Write(ref statusMessagePosted, 0);
        }
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

        DeleteFont(ref titleFont);
        DeleteFont(ref sectionFont);
        DeleteFont(ref bodyFont);
        DeleteFont(ref captionFont);
        DeleteFont(ref monoFont);
        DeleteBrush(ref backgroundBrush);
        DeleteBrush(ref separatorBrush);
    }

    private static void DeleteFont(ref IntPtr font)
    {
        if (font != IntPtr.Zero)
        {
            _ = DeleteObject(font);
            font = IntPtr.Zero;
        }
    }

    private static void DeleteBrush(ref IntPtr brush)
    {
        if (brush != IntPtr.Zero)
        {
            _ = DeleteObject(brush);
            brush = IntPtr.Zero;
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
    private struct MonitorInfo
    {
        public uint Size;
        public NativeRect MonitorArea;
        public NativeRect WorkArea;
        public uint Flags;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MinMaxInfo
    {
        public NativePoint Reserved;
        public NativePoint MaxSize;
        public NativePoint MaxPosition;
        public NativePoint MinTrackSize;
        public NativePoint MaxTrackSize;
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
        IntPtr menu,
        uint extendedStyle = 0
    ) => CreateWindowEx(
        extendedStyle,
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
    private static extern bool IsWindowVisible(IntPtr window);

    [DllImport("user32.dll")]
    private static extern bool EnableWindow(IntPtr window, bool enable);

    [DllImport("user32.dll")]
    private static extern bool UpdateWindow(IntPtr window);

    [DllImport("user32.dll")]
    private static extern int GetSystemMetrics(int index);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr MonitorFromWindow(
        IntPtr window,
        uint flags
    );

    [DllImport("user32.dll", EntryPoint = "GetMonitorInfoW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool GetMonitorInfo(
        IntPtr monitor,
        ref MonitorInfo information
    );

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SystemParametersInfo(
        uint action,
        uint parameter,
        ref NativeRect result,
        uint update
    );

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
    private static extern IntPtr BeginDeferWindowPos(int windowCount);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr DeferWindowPos(
        IntPtr deferInfo,
        IntPtr window,
        IntPtr insertAfter,
        int x,
        int y,
        int width,
        int height,
        uint flags
    );

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool EndDeferWindowPos(IntPtr deferInfo);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool InvalidateRect(
        IntPtr window,
        IntPtr rectangle,
        bool erase
    );

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool RedrawWindow(
        IntPtr window,
        IntPtr updateRectangle,
        IntPtr updateRegion,
        uint flags
    );

    [DllImport("user32.dll", SetLastError = true)]
    private static extern int SetScrollInfo(
        IntPtr window,
        int bar,
        ref ScrollInfo information,
        bool redraw
    );

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool ShowScrollBar(
        IntPtr window,
        int bar,
        bool show
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
    private static extern IntPtr SetFocus(IntPtr window);

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
    private static extern bool IsDialogMessage(
        IntPtr dialog,
        ref NativeMessage message
    );

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
