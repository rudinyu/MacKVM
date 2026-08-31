using System.Runtime.InteropServices;
using WindowsKVM.Protocol;

namespace WindowsKVM;

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
    private double verticalScrollRemainder;
    private double horizontalScrollRemainder;
    private bool active;
    private bool disposed;

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
            ReleaseAllInputsLocked();
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
        if (pressedKeys.ContainsKey(keyCode))
        {
            return;
        }

        InjectedKey injected;
        var events = new List<INPUT>();
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

        SendInputs(events);
        pressedKeys[keyCode] = injected;
    }

    private void ReleaseKey(RemoteInputEvent input)
    {
        var keyCode = input.KeyCode
            ?? throw new WindowsInputException("A keyUp event has no key code.");
        if (!pressedKeys.Remove(keyCode, out var injected))
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
                return;
            }

            SendInputs([
                KeyboardInput(virtualKey, 0, extended ? KeyEventExtended : 0)
            ]);
            pressedKeys[keyCode] = InjectedKey.Virtual(virtualKey, extended);
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
        var virtualKey = mediaKey switch
        {
            MediaKey.SoundUp => VkVolumeUp,
            MediaKey.SoundDown => VkVolumeDown,
            MediaKey.BrightnessUp => VkBrightnessUp,
            MediaKey.BrightnessDown => VkBrightnessDown,
            MediaKey.Mute => VkVolumeMute,
            MediaKey.Play => VkMediaPlayPause,
            MediaKey.Next => VkMediaNextTrack,
            MediaKey.Previous => VkMediaPreviousTrack,
            MediaKey.Fast => VkMediaNextTrack,
            MediaKey.Rewind => VkMediaPreviousTrack,
            _ => throw new WindowsInputException(
                $"Media key {mediaKey} is not supported by Windows input injection."
            )
        };

        SendInputs([
            KeyboardInput(
                virtualKey,
                0,
                (KeyEventExtended | (input.IsPressed == true ? 0 : KeyEventKeyUp))
            )
        ]);
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
        var flags = input.Kind switch
        {
            RemoteInputKind.LeftMouseDown => MouseLeftDown,
            RemoteInputKind.LeftMouseUp => MouseLeftUp,
            // The button is already held from the matching down event. A
            // dragged event must move the pointer without synthesizing a
            // second down edge on every mouse-move packet.
            RemoteInputKind.LeftMouseDragged => MouseMove,
            RemoteInputKind.RightMouseDown => MouseRightDown,
            RemoteInputKind.RightMouseUp => MouseRightUp,
            RemoteInputKind.RightMouseDragged => MouseMove,
            RemoteInputKind.OtherMouseDown => MouseXDown,
            RemoteInputKind.OtherMouseUp => MouseXUp,
            RemoteInputKind.OtherMouseDragged => MouseMove,
            _ => throw new WindowsInputException("Unsupported mouse button event.")
        };
        var mouseData = button switch
        {
            2 => 1u,
            3 => 2u,
            _ => 0u
        };
        if (button >= 2 && button > 3)
        {
            throw new WindowsInputException(
                $"Windows supports only XBUTTON1 and XBUTTON2; got button {button}."
            );
        }

        var isRelease = input.Kind is RemoteInputKind.LeftMouseUp
            or RemoteInputKind.RightMouseUp
            or RemoteInputKind.OtherMouseUp;
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
        else
        {
            pressedMouseButtons.Add(button);
        }
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
        var events = new List<INPUT>(2);
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

    private void ReleaseAllInputsLocked()
    {
        var events = new List<INPUT>(pressedKeys.Count + pressedMouseButtons.Count);
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
                2 => MouseInput(0, 1, MouseXUp),
                3 => MouseInput(0, 2, MouseXUp),
                _ => default
            });
        }

        if (events.Count > 0)
        {
            try
            {
                SendInputs(events);
            }
            catch (WindowsInputException)
            {
                // Teardown is best effort. Clearing the state is still safer
                // than replaying stale releases into a later session.
            }
        }

        pressedKeys.Clear();
        pressedMouseButtons.Clear();
        verticalScrollRemainder = 0;
        horizontalScrollRemainder = 0;
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

    private static INPUT KeyboardInput(ushort virtualKey, ushort scanCode, uint flags)
        => new()
        {
            Type = InputKeyboard,
            Data = new InputUnion
            {
                Keyboard = new KEYBDINPUT
                {
                    VirtualKey = virtualKey,
                    ScanCode = scanCode,
                    Flags = flags,
                    Time = 0,
                    ExtraInfo = UIntPtr.Zero
                }
            }
        };

    private static INPUT MouseInput(uint dx, uint data, uint flags)
        => new()
        {
            Type = InputMouse,
            Data = new InputUnion
            {
                Mouse = new MOUSEINPUT
                {
                    Dx = unchecked((int)dx),
                    Dy = 0,
                    MouseData = data,
                    Flags = flags,
                    Time = 0,
                    ExtraInfo = UIntPtr.Zero
                }
            }
        };

    private static INPUT MouseInputForLocation(
        NormalizedPoint location,
        uint flags,
        uint mouseData = 0
    )
    {
        var width = Math.Max(1, GetSystemMetrics(SmCxVirtualScreen));
        var height = Math.Max(1, GetSystemMetrics(SmCyVirtualScreen));
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

    private static INPUT MouseInputWithCoordinates(
        uint x,
        uint y,
        uint data,
        uint flags
    )
        => new()
        {
            Type = InputMouse,
            Data = new InputUnion
            {
                Mouse = new MOUSEINPUT
                {
                    Dx = unchecked((int)x),
                    Dy = unchecked((int)y),
                    MouseData = data,
                    Flags = flags,
                    Time = 0,
                    ExtraInfo = UIntPtr.Zero
                }
            }
        };

    private static void SendInputs(IReadOnlyList<INPUT> inputs)
    {
        if (inputs.Count == 0)
        {
            return;
        }

        var sent = SendInput(
            (uint)inputs.Count,
            inputs.ToArray(),
            Marshal.SizeOf<INPUT>()
        );
        if (sent != inputs.Count)
        {
            throw new WindowsInputException(
                $"SendInput injected {sent} of {inputs.Count} events (Win32 {Marshal.GetLastWin32Error()})."
            );
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

        public IReadOnlyList<INPUT> KeyUpInputs()
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
