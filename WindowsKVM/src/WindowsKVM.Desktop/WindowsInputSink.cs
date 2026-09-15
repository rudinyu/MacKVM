using System.Runtime.InteropServices;
using WindowsKVM.Protocol;

namespace WindowsKVM;

internal enum WindowsInputEventKind
{
    Keyboard,
    Mouse
}

/// <summary>
/// A platform-neutral description of one input event. The production sink
/// converts this shape to Win32 INPUT immediately before calling SendInput;
/// tests can inject a recorder/failure seam without loading user32.dll.
/// </summary>
internal readonly record struct WindowsInputEvent(
    WindowsInputEventKind Kind,
    ushort VirtualKey,
    ushort ScanCode,
    uint Flags,
    int X,
    int Y,
    uint MouseData
);

/// <summary>
/// Converts the authenticated MacKVM input protocol into Windows SendInput
/// calls. All state is kept per receiver and every control teardown releases
/// the keys/buttons that were successfully pressed, so a lost connection
/// cannot leave a modifier or mouse button held indefinitely.
/// </summary>
internal sealed class WindowsInputSink : IDisposable
{
    private const uint InputMouse = 0;
    private const uint InputKeyboard = 1;

    private const uint KeyEventKeyUp = 0x0002;
    private const uint KeyEventUnicode = 0x0004;
    private const uint KeyEventExtended = 0x0001;

    private const uint MouseMove = 0x0001;
    private const uint MouseLeftDown = 0x0002;
    private const uint MouseLeftUp = 0x0004;
    private const uint MouseRightDown = 0x0008;
    private const uint MouseRightUp = 0x0010;
    private const uint MouseMiddleDown = 0x0020;
    private const uint MouseMiddleUp = 0x0040;
    private const uint MouseXDown = 0x0080;
    private const uint MouseXUp = 0x0100;
    private const uint MouseWheel = 0x0800;
    private const uint MouseHWheel = 0x1000;
    private const uint MouseAbsolute = 0x8000;
    private const uint MouseVirtualDesktop = 0x4000;

    private const int SmCxVirtualScreen = 78;
    private const int SmCyVirtualScreen = 79;

    private readonly object gate = new();
    private readonly Dictionary<ushort, InjectedKey> pressedKeys = [];
    private readonly HashSet<int> pressedMouseButtons = [];
    private readonly Func<IReadOnlyList<WindowsInputEvent>, uint> sendInputs;
    private readonly Func<int, int> getSystemMetrics;
    private readonly Action<string>? reportUnsupported;
    private double verticalScrollRemainder;
    private double horizontalScrollRemainder;
    private bool active;
    private bool disposed;

    public WindowsInputSink(
        Func<IReadOnlyList<WindowsInputEvent>, uint>? sendInputs = null,
        Func<int, int>? getSystemMetrics = null,
        Action<string>? reportUnsupported = null
    )
    {
        this.sendInputs = sendInputs ?? SendNativeInputs;
        this.getSystemMetrics = getSystemMetrics ?? GetSystemMetrics;
        this.reportUnsupported = reportUnsupported;
    }

    public bool IsActive
    {
        get
        {
            lock (gate)
            {
                return active;
            }
        }
    }

    public void Begin()
    {
        lock (gate)
        {
            ThrowIfDisposed();
            if (!ReleaseAllInputsLocked())
            {
                throw new WindowsInputException(
                    "Windows input cleanup did not complete; refusing a new control grant."
                );
            }
            active = true;
        }
    }

    public void Receive(RemoteInputEvent input)
    {
        lock (gate)
        {
            ThrowIfDisposed();
            if (!active)
            {
                throw new WindowsInputException(
                    "An input event arrived before Windows control was granted."
                );
            }

            input.Validated();
            switch (input.Kind)
            {
                case RemoteInputKind.KeyDown:
                    PressKey(input);
                    break;
                case RemoteInputKind.KeyUp:
                    ReleaseKey(input);
                    break;
                case RemoteInputKind.FlagsChanged:
                    ChangeModifier(input);
                    break;
                case RemoteInputKind.SystemDefined:
                    SendMediaKey(input);
                    break;
                case RemoteInputKind.MouseMoved:
                    MoveMouse(input);
                    break;
                case RemoteInputKind.LeftMouseDown:
                case RemoteInputKind.LeftMouseUp:
                case RemoteInputKind.LeftMouseDragged:
                case RemoteInputKind.RightMouseDown:
                case RemoteInputKind.RightMouseUp:
                case RemoteInputKind.RightMouseDragged:
                case RemoteInputKind.OtherMouseDown:
                case RemoteInputKind.OtherMouseUp:
                case RemoteInputKind.OtherMouseDragged:
                    HandleMouseButton(input);
                    break;
                case RemoteInputKind.Scroll:
                    Scroll(input);
                    break;
                default:
                    throw new WindowsInputException("Unsupported remote input kind.");
            }
        }
    }

    public void End()
    {
        lock (gate)
        {
            if (disposed)
            {
                return;
            }

            ReleaseAllInputsLocked();
            active = false;
        }
    }

    public void Dispose()
    {
        lock (gate)
        {
            if (disposed)
            {
                return;
            }

            ReleaseAllInputsLocked();
            active = false;
            disposed = true;
        }
    }

    private void PressKey(RemoteInputEvent input)
    {
        var keyCode = input.KeyCode
            ?? throw new WindowsInputException("A keyDown event has no key code.");
        if (pressedKeys.TryGetValue(keyCode, out var held))
        {
            // macOS sends another key-down for auto-repeat. Reuse the first
            // mapping (including Unicode units) so a changed character field
            // cannot make a held key release incorrectly later.
            SendInputs(held.KeyDownInputs());
            return;
        }

        InjectedKey injected;
        var events = new List<WindowsInputEvent>();
        if (TryMapMacKey(keyCode, out var virtualKey, out var extended))
        {
            injected = InjectedKey.Virtual(virtualKey, extended);
            events.Add(KeyboardInput(virtualKey, 0, extended ? KeyEventExtended : 0));
        }
        else if (!string.IsNullOrEmpty(input.Character))
        {
            var units = input.Character!.ToCharArray();
            injected = InjectedKey.Unicode(units);
            events.AddRange(units.Select(unit =>
                KeyboardInput(0, unit, KeyEventUnicode)));
        }
        else
        {
            throw new WindowsInputException(
                $"Mac key code {keyCode} has no safe Windows mapping."
            );
        }

        pressedKeys[keyCode] = injected;
        try
        {
            SendInputs(events);
        }
        catch
        {
            // Keep the mapping when a partial/failed key-down may have
            // reached Windows. End() can then issue a conservative key-up.
            throw;
        }
    }

    private void ReleaseKey(RemoteInputEvent input)
    {
        var keyCode = input.KeyCode
            ?? throw new WindowsInputException("A keyUp event has no key code.");
        if (!pressedKeys.TryGetValue(keyCode, out var injected))
        {
            // A duplicate or legacy keyUp must not create a new held key. If
            // the physical mapping is known, send a best-effort release.
            if (TryMapMacKey(keyCode, out var virtualKey, out var extended))
            {
                SendInputs([
                    KeyboardInput(
                        virtualKey,
                        0,
                        (extended ? KeyEventExtended : 0) | KeyEventKeyUp
                    )
                ]);
            }
            return;
        }

        SendInputs(injected.KeyUpInputs());
        // Do not lose teardown bookkeeping until the native release has
        // succeeded. A transient SendInput failure must be retried by End().
        pressedKeys.Remove(keyCode);
    }

    private void ChangeModifier(RemoteInputEvent input)
    {
        var keyCode = input.KeyCode
            ?? throw new WindowsInputException("A flagsChanged event has no key code.");
        if (!TryMapMacModifier(keyCode, out var virtualKey, out var extended))
        {
            throw new WindowsInputException(
                $"Mac modifier key code {keyCode} has no safe Windows mapping."
            );
        }

        var pressed = input.IsPressed ?? !pressedKeys.ContainsKey(keyCode);
        if (pressed)
        {
            if (pressedKeys.ContainsKey(keyCode))
            {
                SendInputs(pressedKeys[keyCode].KeyDownInputs());
                return;
            }

            var injected = InjectedKey.Virtual(virtualKey, extended);
            pressedKeys[keyCode] = injected;
            try
            {
                SendInputs(injected.KeyDownInputs());
            }
            catch
            {
                // Preserve the held mapping so teardown can retry the release
                // when only part of a modifier transition was injected.
                throw;
            }
        }
        else
        {
            ReleaseKey(input);
        }
    }

    private void SendMediaKey(RemoteInputEvent input)
    {
        var mediaKey = input.MediaKey
            ?? throw new WindowsInputException("A systemDefined event has no media key.");
        if (!TryMapMediaKey(mediaKey, out var virtualKey))
        {
            ReportUnsupported(
                $"Media key {mediaKey} is not implemented by Windows input injection; ignored."
            );
            return;
        }

        SendInputs([
            KeyboardInput(
                virtualKey,
                0,
                (KeyEventExtended | (input.IsPressed == true ? 0 : KeyEventKeyUp))
            )
        ]);
    }

    private static bool TryMapMediaKey(MediaKey mediaKey, out ushort virtualKey)
    {
        virtualKey = mediaKey switch
        {
            MediaKey.SoundUp => VkVolumeUp,
            MediaKey.SoundDown => VkVolumeDown,
            MediaKey.Mute => VkVolumeMute,
            MediaKey.Play => VkMediaPlayPause,
            MediaKey.Next => VkMediaNextTrack,
            MediaKey.Previous => VkMediaPreviousTrack,
            MediaKey.Fast => VkMediaNextTrack,
            MediaKey.Rewind => VkMediaPreviousTrack,
            _ => 0
        };
        return virtualKey != 0;
    }

    private void MoveMouse(RemoteInputEvent input)
    {
        var location = input.Location
            ?? throw new WindowsInputException("A mouseMoved event has no location.");
        SendInputs([MouseInputForLocation(location, MouseMove)]);
    }

    private void HandleMouseButton(RemoteInputEvent input)
    {
        var button = input.ButtonNumber
            ?? throw new WindowsInputException("A mouse event has no button number.");
        var isRelease = input.Kind is RemoteInputKind.LeftMouseUp
            or RemoteInputKind.RightMouseUp
            or RemoteInputKind.OtherMouseUp;
        if (!TryMapMouseButton(button, input.Kind, out var flags, out var mouseData))
        {
            ReportUnsupported(
                $"Mouse button {button} is not supported by Windows input injection; ignored."
            );
            return;
        }

        if (input.Kind is RemoteInputKind.LeftMouseDragged
            or RemoteInputKind.RightMouseDragged
            or RemoteInputKind.OtherMouseDragged)
        {
            flags = MouseMove;
            mouseData = 0;
        }

        SendInputs([
            MouseInputForLocation(
                input.Location
                    ?? throw new WindowsInputException("A mouse event has no location."),
                flags,
                mouseData
            )
        ]);

        if (isRelease)
        {
            pressedMouseButtons.Remove(button);
        }
        else if (input.Kind is RemoteInputKind.LeftMouseDown
            or RemoteInputKind.RightMouseDown
            or RemoteInputKind.OtherMouseDown)
        {
            pressedMouseButtons.Add(button);
        }
    }

    private static bool TryMapMouseButton(
        int button,
        RemoteInputKind kind,
        out uint flags,
        out uint mouseData
    )
    {
        var isDown = kind is RemoteInputKind.LeftMouseDown
            or RemoteInputKind.RightMouseDown
            or RemoteInputKind.OtherMouseDown;
        var isUp = kind is RemoteInputKind.LeftMouseUp
            or RemoteInputKind.RightMouseUp
            or RemoteInputKind.OtherMouseUp;
        var isDragged = kind is RemoteInputKind.LeftMouseDragged
            or RemoteInputKind.RightMouseDragged
            or RemoteInputKind.OtherMouseDragged;
        if (isDragged && button is >= 0 and <= 4)
        {
            flags = MouseMove;
            mouseData = 0;
            return true;
        }

        flags = button switch
        {
            0 when isDown => MouseLeftDown,
            0 when isUp => MouseLeftUp,
            1 when isDown => MouseRightDown,
            1 when isUp => MouseRightUp,
            2 when isDown => MouseMiddleDown,
            2 when isUp => MouseMiddleUp,
            3 or 4 when isDown => MouseXDown,
            3 or 4 when isUp => MouseXUp,
            _ => 0
        };
        mouseData = button switch
        {
            3 => 1u,
            4 => 2u,
            _ => 0u
        };
        return flags != 0 && (button <= 1 || button is 2 or 3 or 4);
    }

    private void Scroll(RemoteInputEvent input)
    {
        // Windows SendInput accepts wheel units. A line event is one logical
        // wheel line (120 units); a pixel event uses one high-resolution unit
        // per pixel and carries fractional residue to the next packet. This
        // keeps a 1-pixel trackpad delta from becoming a full 120-unit notch.
        var multiplier = input.ScrollEventUnit == ScrollEventUnit.Line ? 120d : 1d;
        var vertical = ConsumeScroll(
            ref verticalScrollRemainder,
            input.ScrollDeltaY ?? 0,
            multiplier
        );
        var horizontal = ConsumeScroll(
            ref horizontalScrollRemainder,
            input.ScrollDeltaX ?? 0,
            multiplier
        );
        var events = new List<WindowsInputEvent>(2);
        if (vertical != 0)
        {
            events.Add(MouseInput(0, unchecked((uint)vertical), MouseWheel));
        }
        if (horizontal != 0)
        {
            events.Add(MouseInput(0, unchecked((uint)horizontal), MouseHWheel));
        }
        if (events.Count > 0)
        {
            SendInputs(events);
        }
    }

    private bool ReleaseAllInputsLocked()
    {
        var events = new List<WindowsInputEvent>(pressedKeys.Count + pressedMouseButtons.Count);
        foreach (var injected in pressedKeys.Values)
        {
            events.AddRange(injected.KeyUpInputs());
        }
        foreach (var button in pressedMouseButtons)
        {
            events.Add(button switch
            {
                0 => MouseInput(0, 0, MouseLeftUp),
                1 => MouseInput(0, 0, MouseRightUp),
                2 => MouseInput(0, 0, MouseMiddleUp),
                3 => MouseInput(0, 1, MouseXUp),
                4 => MouseInput(0, 2, MouseXUp),
                _ => default
            });
        }

        if (events.Count > 0)
        {
            for (var attempt = 0; attempt < 3; attempt++)
            {
                try
                {
                    SendInputs(events);
                    break;
                }
                catch (WindowsInputException) when (attempt < 2)
                {
                    // Retry a transient/partial SendInput result while the
                    // complete held-state map is still available.
                }
                catch (WindowsInputException)
                {
                    // Keep all bookkeeping on a persistent failure. A later
                    // End()/Begin() can retry, and Begin() refuses to hand
                    // the sink to a new grant until cleanup succeeds.
                    return false;
                }
            }
        }

        pressedKeys.Clear();
        pressedMouseButtons.Clear();
        verticalScrollRemainder = 0;
        horizontalScrollRemainder = 0;
        return true;
    }

    private static int ConsumeScroll(ref double remainder, double delta, double multiplier)
    {
        var scaled = delta * multiplier + remainder;
        var whole = scaled >= 0 ? Math.Floor(scaled) : Math.Ceiling(scaled);
        remainder = scaled - whole;
        if (whole is > int.MaxValue or < int.MinValue)
        {
            throw new WindowsInputException("Scroll delta is outside the Windows range.");
        }
        return (int)whole;
    }

    private static WindowsInputEvent KeyboardInput(
        ushort virtualKey,
        ushort scanCode,
        uint flags
    )
        => new()
        {
            Kind = WindowsInputEventKind.Keyboard,
            VirtualKey = virtualKey,
            ScanCode = scanCode,
            Flags = flags
        };

    private static WindowsInputEvent MouseInput(uint dx, uint data, uint flags)
        => new()
        {
            Kind = WindowsInputEventKind.Mouse,
            X = unchecked((int)dx),
            MouseData = data,
            Flags = flags
        };

    private WindowsInputEvent MouseInputForLocation(
        NormalizedPoint location,
        uint flags,
        uint mouseData = 0
    )
    {
        var width = Math.Max(1, getSystemMetrics(SmCxVirtualScreen));
        var height = Math.Max(1, getSystemMetrics(SmCyVirtualScreen));
        var x = Math.Clamp(
            (int)Math.Round(location.X * (width - 1)),
            0,
            width - 1
        );
        var y = Math.Clamp(
            (int)Math.Round(location.Y * (height - 1)),
            0,
            height - 1
        );
        var absoluteX = (uint)Math.Clamp(
            (int)Math.Round(x * 65_535d / Math.Max(1, width - 1)),
            0,
            65_535
        );
        var absoluteY = (uint)Math.Clamp(
            (int)Math.Round(y * 65_535d / Math.Max(1, height - 1)),
            0,
            65_535
        );
        return MouseInputWithCoordinates(
            absoluteX,
            absoluteY,
            mouseData,
            flags | MouseAbsolute | MouseVirtualDesktop
        );
    }

    private static WindowsInputEvent MouseInputWithCoordinates(
        uint x,
        uint y,
        uint data,
        uint flags
    )
        => new()
        {
            Kind = WindowsInputEventKind.Mouse,
            X = unchecked((int)x),
            Y = unchecked((int)y),
            MouseData = data,
            Flags = flags
        };

    private void SendInputs(IReadOnlyList<WindowsInputEvent> inputs)
    {
        if (inputs.Count == 0)
        {
            return;
        }

        var sent = sendInputs(inputs);
        if (sent != inputs.Count)
        {
            throw new WindowsInputException(
                $"SendInput injected {sent} of {inputs.Count} events (Win32 {Marshal.GetLastWin32Error()})."
            );
        }
    }

    private static uint SendNativeInputs(IReadOnlyList<WindowsInputEvent> inputs)
    {
        var nativeInputs = inputs.Select(ToNativeInput).ToArray();
        return SendInput(
            (uint)nativeInputs.Length,
            nativeInputs,
            Marshal.SizeOf<INPUT>()
        );
    }

    private static INPUT ToNativeInput(WindowsInputEvent input)
    {
        if (input.Kind == WindowsInputEventKind.Keyboard)
        {
            return new INPUT
            {
                Type = InputKeyboard,
                Data = new InputUnion
                {
                    Keyboard = new KEYBDINPUT
                    {
                        VirtualKey = input.VirtualKey,
                        ScanCode = input.ScanCode,
                        Flags = input.Flags,
                        Time = 0,
                        ExtraInfo = UIntPtr.Zero
                    }
                }
            };
        }

        return new INPUT
        {
            Type = InputMouse,
            Data = new InputUnion
            {
                Mouse = new MOUSEINPUT
                {
                    Dx = input.X,
                    Dy = input.Y,
                    MouseData = input.MouseData,
                    Flags = input.Flags,
                    Time = 0,
                    ExtraInfo = UIntPtr.Zero
                }
            }
        };
    }

    private void ReportUnsupported(string message)
    {
        Console.Error.WriteLine($"Windows input ignored: {message}");
        try
        {
            reportUnsupported?.Invoke(message);
        }
        catch
        {
            // Diagnostics are best effort and must not tear down an
            // authenticated control session.
        }
    }

    private static bool TryMapMacModifier(
        ushort keyCode,
        out ushort virtualKey,
        out bool extended
    )
    {
        if (MacVirtualKeyMap.TryGetModifier(keyCode, out var mapping))
        {
            virtualKey = mapping.VirtualKey;
            extended = mapping.Extended;
            return true;
        }

        virtualKey = 0;
        extended = false;
        return false;
    }

    private static bool TryMapMacKey(
        ushort keyCode,
        out ushort virtualKey,
        out bool extended
    )
    {
        if (MacVirtualKeyMap.TryGet(keyCode, out var mapping))
        {
            virtualKey = mapping.VirtualKey;
            extended = mapping.Extended;
            return true;
        }
        virtualKey = 0;
        extended = false;
        return false;
    }

    private void ThrowIfDisposed()
    {
        if (disposed)
        {
            throw new ObjectDisposedException(nameof(WindowsInputSink));
        }
    }

    private readonly record struct InjectedKey(
        ushort VirtualKey,
        ushort[] UnicodeUnits,
        bool IsUnicode,
        bool Extended
    )
    {
        public static InjectedKey Virtual(ushort key, bool extended)
            => new(key, [], false, extended);

        public static InjectedKey Unicode(char[] units)
            => new(0, units.Select(unit => (ushort)unit).ToArray(), true, false);

        public IReadOnlyList<WindowsInputEvent> KeyDownInputs()
        {
            if (IsUnicode)
            {
                return UnicodeUnits
                    .Select(unit => KeyboardInput(0, unit, KeyEventUnicode))
                    .ToArray();
            }

            return [KeyboardInput(VirtualKey, 0, Extended ? KeyEventExtended : 0)];
        }

        public IReadOnlyList<WindowsInputEvent> KeyUpInputs()
        {
            if (IsUnicode)
            {
                return UnicodeUnits
                    .Reverse()
                    .Select(unit => KeyboardInput(0, unit, KeyEventUnicode | KeyEventKeyUp))
                    .ToArray();
            }

            return [
                KeyboardInput(
                    VirtualKey,
                    0,
                    (Extended ? KeyEventExtended : 0) | KeyEventKeyUp
                )
            ];
        }
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint numberOfInputs, INPUT[] inputs, int size);

    [DllImport("user32.dll")]
    private static extern int GetSystemMetrics(int index);

    [StructLayout(LayoutKind.Sequential)]
    private struct INPUT
    {
        public uint Type;
        public InputUnion Data;
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct InputUnion
    {
        [FieldOffset(0)] public MOUSEINPUT Mouse;
        [FieldOffset(0)] public KEYBDINPUT Keyboard;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MOUSEINPUT
    {
        public int Dx;
        public int Dy;
        public uint MouseData;
        public uint Flags;
        public uint Time;
        public UIntPtr ExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KEYBDINPUT
    {
        public ushort VirtualKey;
        public ushort ScanCode;
        public uint Flags;
        public uint Time;
        public UIntPtr ExtraInfo;
    }

    private const ushort VkLShift = 0xA0;
    private const ushort VkRShift = 0xA1;
    private const ushort VkLControl = 0xA2;
    private const ushort VkRControl = 0xA3;
    private const ushort VkLMenu = 0xA4;
    private const ushort VkRMenu = 0xA5;
    private const ushort VkLWin = 0x5B;
    private const ushort VkRWin = 0x5C;
    private const ushort VkCapital = 0x14;
    private const ushort VkVolumeMute = 0xAD;
    private const ushort VkVolumeDown = 0xAE;
    private const ushort VkVolumeUp = 0xAF;
    private const ushort VkMediaNextTrack = 0xB0;
    private const ushort VkMediaPreviousTrack = 0xB1;
    private const ushort VkMediaPlayPause = 0xB3;
    private const ushort VkBrightnessDown = 0xB2;
    private const ushort VkBrightnessUp = 0xB4;
}

internal sealed class WindowsInputException : Exception
{
    public WindowsInputException(string message) : base(message) { }
}
