namespace WindowsKVM;

internal readonly record struct WindowsTrayWindowSize(int Width, int Height);

internal enum WindowsTraySimpleControl
{
    Title,
    ModeButton,
    QuickSetup,
    Details,
    Status,
    Readiness,
    PairingHeader,
    PairName,
    PairDetails,
    Forget,
    ControlHeader,
    ControlState,
    InputPathLabel,
    InputPathCombo,
    Refresh,
    Quit
}

internal readonly record struct WindowsTrayChildBounds(
    int X,
    int Y,
    int Width,
    int Height
)
{
    public int Right => X + Width;
    public int Bottom => Y + Height;

    public bool IsWithin(int clientWidth, int contentHeight)
        => X >= 0
            && Y >= 0
            && Width >= 0
            && Height >= 0
            && Right <= clientWidth
            && Bottom <= contentHeight;
}

internal readonly record struct WindowsTraySimpleLayout(
    int ContentHeight,
    IReadOnlyDictionary<WindowsTraySimpleControl, WindowsTrayChildBounds> Controls
)
{
    public WindowsTrayChildBounds this[WindowsTraySimpleControl control]
        => Controls[control];
}

/// <summary>
/// Keeps the resident status window usable on small displays and high-DPI
/// work areas. The policy is pure so clamping and mode dimensions can be
/// regression-tested without starting a Win32 desktop process.
/// </summary>
internal static class WindowsTrayLayoutPolicy
{
    public const int SimplePreferredWidth = 520;
    public const int SimplePreferredHeight = 500;
    // Leave enough client width for the fixed Advanced rows after the
    // overlapped frame and the always-present vertical scrollbar. Narrower
    // work areas still use the horizontal range below.
    public const int AdvancedPreferredWidth = 880;
    public const int AdvancedPreferredHeight = 900;
    // Advanced controls use coordinates through x=822 and retain their
    // readable widths. Eight pixels of intentional right padding keeps the
    // final labels/buttons reachable without an unnecessary scrollbar at the
    // preferred outer size.
    public const int AdvancedContentWidth = 830;
    // Keep long identity strings within a predictable native STATIC width.
    // The formatter is pure so the UI can be regression-tested without a
    // Windows desktop or a real DPAPI identity.
    public const int FingerprintDisplayChunkLength = 48;
    private const int SmallestUsableWidth = 360;
    private const int SmallestUsableHeight = 320;

    public static WindowsTrayWindowSize ForSimple(int workAreaWidth, int workAreaHeight)
        => Fit(
            SimplePreferredWidth,
            SimplePreferredHeight,
            workAreaWidth,
            workAreaHeight
        );

    public static WindowsTrayWindowSize ForAdvanced(int workAreaWidth, int workAreaHeight)
        => Fit(
            AdvancedPreferredWidth,
            AdvancedPreferredHeight,
            workAreaWidth,
            workAreaHeight
        );

    /// <summary>
    /// Returns the native outer-size floor used by WM_GETMINMAXINFO. A
    /// work area smaller than the normal floor wins so the window can still
    /// be placed entirely on an unusually small display.
    /// </summary>
    public static WindowsTrayWindowSize MinimumWindowSize(
        int workAreaWidth,
        int workAreaHeight
    )
        => new(
            FitMinimum(SmallestUsableWidth, workAreaWidth),
            FitMinimum(SmallestUsableHeight, workAreaHeight)
        );

    public static int AdvancedHorizontalMaximum(int clientWidth)
        => Math.Max(0, AdvancedContentWidth - Math.Max(1, clientWidth));

    public static string FormatFingerprint(string label, string fingerprint)
    {
        var lines = fingerprint
            .Chunk(FingerprintDisplayChunkLength)
            .Select(chars => new string(chars));
        return label + ":\r\n" + string.Join("\r\n", lines);
    }

    public static int ClampHorizontalOffset(
        bool advancedMode,
        int clientWidth,
        int requestedOffset
    )
    {
        if (!advancedMode)
        {
            return 0;
        }

        return Math.Clamp(
            requestedOffset,
            0,
            AdvancedHorizontalMaximum(clientWidth)
        );
    }

    /// <summary>
    /// Win32 interprets a drop-list HWND's height as the selection field plus
    /// its expanded list. Layout rows still use only the collapsed height.
    /// Use the control's measured item height, and bound long peer lists so
    /// their vertical scrollbar can expose the remaining items.
    /// </summary>
    public static int ComboBoxWindowHeight(int collapsedHeight, int itemHeight, int itemCount)
        => collapsedHeight
            + Math.Max(1, itemHeight) * Math.Clamp(itemCount, 2, 8)
            + 4;

    public static WindowsTrayChildBounds ForNativeChild(
        WindowsTrayChildBounds visualBounds,
        int horizontalOffset,
        int verticalOffset,
        int comboBoxItemHeight = 0,
        int comboBoxItemCount = 0
    ) => visualBounds with
    {
        X = visualBounds.X - horizontalOffset,
        Y = visualBounds.Y - verticalOffset,
        Height = comboBoxItemHeight > 0
            ? ComboBoxWindowHeight(visualBounds.Height, comboBoxItemHeight, comboBoxItemCount)
            : visualBounds.Height
    };

    /// <summary>
    /// Computes the compact child rectangles from the actual client width.
    /// The native window has borders and (on short displays) a vertical scroll
    /// bar, so the outer preferred width is not a safe coordinate system.
    /// Keeping this policy pure makes narrow/high-DPI reflow deterministic in
    /// the portable desktop self-test.
    /// </summary>
    public static WindowsTraySimpleLayout ForSimpleContent(int clientWidth)
    {
        var width = Math.Max(1, clientWidth);
        var edge = width >= 96 ? 24 : Math.Max(4, width / 8);
        var available = Math.Max(1, width - edge * 2);
        var modeWidth = available < 108
            ? available
            : Math.Min(150, Math.Max(108, available / 3));
        var modeX = Math.Max(edge, width - edge - modeWidth);
        // WindowsKVM is longer than the old MacKVM heading. Stack the mode
        // action on narrow clients instead of clipping the product name.
        var headerStacked = available < 360;
        var headerShift = headerStacked ? 44 : 0;
        var titleWidth = headerStacked ? available : Math.Max(1, modeX - edge - 16);

        var pairStacked = available < 250;
        var pairGap = pairStacked ? 0 : 8;
        var forgetWidth = Math.Min(
            170,
            Math.Max(96, pairStacked ? available : available / 2 - pairGap / 2)
        );
        if (!pairStacked)
        {
            forgetWidth = Math.Min(forgetWidth, available);
        }

        var pairNameWidth = pairStacked
            ? available
            : Math.Max(1, available - pairGap - forgetWidth);
        var pairNameY = 258;
        var forgetY = pairStacked ? 290 : 254;
        var pairDetailsY = pairStacked ? 330 : 290;
        var pairDetailsHeight = pairStacked ? 42 : 36;

        var controlHeaderY = pairDetailsY + pairDetailsHeight + 8;
        var controlStateY = controlHeaderY + 32;
        var inputLabelY = controlStateY + 38;
        var inputStacked = available < 220;
        var inputLabelWidth = inputStacked
            ? available
            : Math.Min(180, Math.Max(92, available / 3));
        var inputComboX = inputStacked
            ? edge
            : Math.Min(
                width - edge - 1,
                edge + inputLabelWidth + 8
            );
        var inputComboY = inputStacked ? inputLabelY + 28 : inputLabelY - 4;
        var inputComboWidth = inputStacked
            ? available
            : Math.Max(1, width - edge - inputComboX);
        var inputBottom = inputComboY + 32;
        var buttonY = inputBottom + 16;
        var buttonsStacked = available < 250;
        var buttonWidth = buttonsStacked
            ? available
            : Math.Clamp((available - 16) / 2, 96, 140);
        var quitX = width - edge - buttonWidth;
        var quitY = buttonsStacked ? buttonY + 40 : buttonY;
        var contentHeight = Math.Max(500, quitY + 32 + 16);

        var controls = new Dictionary<WindowsTraySimpleControl, WindowsTrayChildBounds>
        {
            [WindowsTraySimpleControl.Title] = new(edge, 28, titleWidth, 40),
            [WindowsTraySimpleControl.ModeButton] = new(modeX, headerStacked ? 72 : 24, modeWidth, 36),
            [WindowsTraySimpleControl.QuickSetup] = new(edge, 82, available, 28),
            [WindowsTraySimpleControl.Details] = new(edge, 114, available, 22),
            [WindowsTraySimpleControl.Status] = new(edge, 140, available, 32),
            [WindowsTraySimpleControl.Readiness] = new(edge, 176, available, 40),
            [WindowsTraySimpleControl.PairingHeader] = new(edge, 226, available, 28),
            [WindowsTraySimpleControl.PairName] = new(edge, pairNameY, pairNameWidth, 28),
            [WindowsTraySimpleControl.PairDetails] = new(edge, pairDetailsY, available, pairDetailsHeight),
            [WindowsTraySimpleControl.Forget] = new(width - edge - forgetWidth, forgetY, forgetWidth, 32),
            [WindowsTraySimpleControl.ControlHeader] = new(edge, controlHeaderY, available, 28),
            [WindowsTraySimpleControl.ControlState] = new(edge, controlStateY, available, 32),
            [WindowsTraySimpleControl.InputPathLabel] = new(edge, inputLabelY, inputLabelWidth, 28),
            [WindowsTraySimpleControl.InputPathCombo] = new(inputComboX, inputComboY, inputComboWidth, 32),
            [WindowsTraySimpleControl.Refresh] = new(edge, buttonY, buttonWidth, 32),
            [WindowsTraySimpleControl.Quit] = new(quitX, quitY, buttonWidth, 32)
        };

        if (headerStacked)
        {
            foreach (var control in controls.Keys.ToArray())
            {
                if (control is not WindowsTraySimpleControl.Title
                    and not WindowsTraySimpleControl.ModeButton)
                {
                    controls[control] = controls[control] with
                    {
                        Y = controls[control].Y + headerShift
                    };
                }
            }
        }

        return new WindowsTraySimpleLayout(contentHeight + headerShift, controls);
    }

    private static WindowsTrayWindowSize Fit(
        int preferredWidth,
        int preferredHeight,
        int workAreaWidth,
        int workAreaHeight
    )
    {
        return new WindowsTrayWindowSize(
            FitDimension(preferredWidth, SmallestUsableWidth, workAreaWidth),
            FitDimension(preferredHeight, SmallestUsableHeight, workAreaHeight)
        );
    }

    private static int FitDimension(int preferred, int minimum, int available)
    {
        if (available <= 0)
        {
            return preferred;
        }

        // If the work area is smaller than the minimum, use every available
        // pixel rather than creating a window that cannot be reached.
        return available < minimum ? available : Math.Min(preferred, available);
    }

    private static int FitMinimum(int minimum, int available)
        => available <= 0 ? minimum : Math.Min(minimum, available);
}
