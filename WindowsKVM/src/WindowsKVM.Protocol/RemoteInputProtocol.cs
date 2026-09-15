using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace WindowsKVM.Protocol;

/// <summary>
/// The input event names are part of the wire contract shared with MacKVM.
/// </summary>
[JsonConverter(typeof(RemoteInputKindJsonConverter))]
public enum RemoteInputKind
{
    KeyDown,
    KeyUp,
    FlagsChanged,
    SystemDefined,
    MouseMoved,
    LeftMouseDown,
    LeftMouseUp,
    LeftMouseDragged,
    RightMouseDown,
    RightMouseUp,
    RightMouseDragged,
    OtherMouseDown,
    OtherMouseUp,
    OtherMouseDragged,
    Scroll
}

internal sealed class RemoteInputKindJsonConverter : JsonConverter<RemoteInputKind>
{
    public override RemoteInputKind Read(
        ref Utf8JsonReader reader,
        Type typeToConvert,
        JsonSerializerOptions options
    )
    {
        if (reader.TokenType != JsonTokenType.String)
        {
            throw new JsonException("Remote input kind must be a string.");
        }

        return reader.GetString() switch
        {
            "keyDown" => RemoteInputKind.KeyDown,
            "keyUp" => RemoteInputKind.KeyUp,
            "flagsChanged" => RemoteInputKind.FlagsChanged,
            "systemDefined" => RemoteInputKind.SystemDefined,
            "mouseMoved" => RemoteInputKind.MouseMoved,
            "leftMouseDown" => RemoteInputKind.LeftMouseDown,
            "leftMouseUp" => RemoteInputKind.LeftMouseUp,
            "leftMouseDragged" => RemoteInputKind.LeftMouseDragged,
            "rightMouseDown" => RemoteInputKind.RightMouseDown,
            "rightMouseUp" => RemoteInputKind.RightMouseUp,
            "rightMouseDragged" => RemoteInputKind.RightMouseDragged,
            "otherMouseDown" => RemoteInputKind.OtherMouseDown,
            "otherMouseUp" => RemoteInputKind.OtherMouseUp,
            "otherMouseDragged" => RemoteInputKind.OtherMouseDragged,
            "scroll" => RemoteInputKind.Scroll,
            _ => throw new JsonException("Unknown remote input kind.")
        };
    }

    public override void Write(
        Utf8JsonWriter writer,
        RemoteInputKind value,
        JsonSerializerOptions options
    )
    {
        writer.WriteStringValue(value switch
        {
            RemoteInputKind.KeyDown => "keyDown",
            RemoteInputKind.KeyUp => "keyUp",
            RemoteInputKind.FlagsChanged => "flagsChanged",
            RemoteInputKind.SystemDefined => "systemDefined",
            RemoteInputKind.MouseMoved => "mouseMoved",
            RemoteInputKind.LeftMouseDown => "leftMouseDown",
            RemoteInputKind.LeftMouseUp => "leftMouseUp",
            RemoteInputKind.LeftMouseDragged => "leftMouseDragged",
            RemoteInputKind.RightMouseDown => "rightMouseDown",
            RemoteInputKind.RightMouseUp => "rightMouseUp",
            RemoteInputKind.RightMouseDragged => "rightMouseDragged",
            RemoteInputKind.OtherMouseDown => "otherMouseDown",
            RemoteInputKind.OtherMouseUp => "otherMouseUp",
            RemoteInputKind.OtherMouseDragged => "otherMouseDragged",
            RemoteInputKind.Scroll => "scroll",
            _ => throw new JsonException("Unknown remote input kind.")
        });
    }
}

public sealed class NormalizedPoint
{
    [JsonPropertyName("x")]
    public double X { get; }

    [JsonPropertyName("y")]
    public double Y { get; }

    [JsonConstructor]
    public NormalizedPoint(double x, double y)
    {
        X = x;
        Y = y;
    }
}

/// <summary>
/// Numeric values mirror the macOS MediaKey enum. The allowlist intentionally
/// excludes power, caps lock, eject, and other system-management keys.
/// </summary>
public enum MediaKey
{
    SoundUp = 0,
    SoundDown = 1,
    BrightnessUp = 2,
    BrightnessDown = 3,
    Mute = 7,
    Play = 16,
    Next = 17,
    Previous = 18,
    Fast = 19,
    Rewind = 20,
    IlluminationUp = 21,
    IlluminationDown = 22,
    IlluminationToggle = 23
}

public enum ScrollPhase
{
    Began = 1,
    Changed = 2,
    Ended = 4,
    Cancelled = 8,
    MayBegin = 128
}

public enum ScrollMomentumPhase
{
    Begin = 1,
    Continue = 2,
    End = 3
}

/// <summary>
/// Matches macOS ScrollEventUnit's Codable integer values. A missing value is
/// treated as Pixel for backwards compatibility with older MacKVM peers.
/// </summary>
public enum ScrollEventUnit
{
    Pixel = 0,
    Line = 1
}

public sealed class RemoteInputEvent
{
    [JsonPropertyName("kind")]
    public RemoteInputKind Kind { get; }

    [JsonPropertyName("keyCode")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public ushort? KeyCode { get; }

    [JsonPropertyName("isPressed")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public bool? IsPressed { get; }

    [JsonPropertyName("modifierFlags")]
    public ulong ModifierFlags { get; }

    [JsonPropertyName("location")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public NormalizedPoint? Location { get; }

    [JsonPropertyName("buttonNumber")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public int? ButtonNumber { get; }

    [JsonPropertyName("clickCount")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public int? ClickCount { get; }

    [JsonPropertyName("pressure")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public double? Pressure { get; }

    [JsonPropertyName("scrollDeltaX")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public double? ScrollDeltaX { get; }

    [JsonPropertyName("scrollDeltaY")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public double? ScrollDeltaY { get; }

    [JsonPropertyName("scrollPhase")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public ScrollPhase? ScrollPhase { get; }

    [JsonPropertyName("scrollMomentumPhase")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public ScrollMomentumPhase? ScrollMomentumPhase { get; }

    [JsonPropertyName("scrollEventUnit")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public ScrollEventUnit? ScrollEventUnit { get; }

    [JsonPropertyName("mediaKey")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public MediaKey? MediaKey { get; }

    [JsonPropertyName("character")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? Character { get; }

    [JsonPropertyName("keyboardLayoutIdentifier")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? KeyboardLayoutIdentifier { get; }

    [JsonConstructor]
    public RemoteInputEvent(
        RemoteInputKind kind,
        ushort? keyCode = null,
        bool? isPressed = null,
        ulong modifierFlags = 0,
        NormalizedPoint? location = null,
        int? buttonNumber = null,
        int? clickCount = null,
        double? pressure = null,
        double? scrollDeltaX = null,
        double? scrollDeltaY = null,
        ScrollPhase? scrollPhase = null,
        ScrollMomentumPhase? scrollMomentumPhase = null,
        ScrollEventUnit? scrollEventUnit = null,
        MediaKey? mediaKey = null,
        string? character = null,
        string? keyboardLayoutIdentifier = null
    )
    {
        Kind = kind;
        KeyCode = keyCode;
        IsPressed = isPressed;
        ModifierFlags = modifierFlags;
        Location = location;
        ButtonNumber = buttonNumber;
        ClickCount = clickCount;
        Pressure = pressure;
        ScrollDeltaX = scrollDeltaX;
        ScrollDeltaY = scrollDeltaY;
        ScrollPhase = scrollPhase;
        ScrollMomentumPhase = scrollMomentumPhase;
        ScrollEventUnit = scrollEventUnit;
        MediaKey = mediaKey;
        Character = character;
        KeyboardLayoutIdentifier = keyboardLayoutIdentifier;
    }

    public RemoteInputEvent Validated()
    {
        if (!ValidModifierFlags)
        {
            throw new RemoteInputException(
                RemoteInputErrorCode.InvalidFields,
                "Unknown modifier flags are not accepted."
            );
        }

        switch (Kind)
        {
            case RemoteInputKind.KeyDown:
                Require(
                    KeyCode is not null && IsPressed is null && Location is null
                        && ButtonNumber is null && ClickCount is null
                        && Pressure is null
                        && ScrollDeltaX is null && ScrollDeltaY is null
                        && HasNoScrollPhase && MediaKey is null
                        && ValidCharacter && ValidKeyboardLayoutIdentifier
                );
                break;
            case RemoteInputKind.KeyUp:
                Require(
                    KeyCode is not null && IsPressed is null && Location is null
                        && ButtonNumber is null && ClickCount is null
                        && Pressure is null
                        && ScrollDeltaX is null && ScrollDeltaY is null
                        && HasNoScrollPhase && MediaKey is null
                        && Character is null && ValidKeyboardLayoutIdentifier
                );
                break;
            case RemoteInputKind.FlagsChanged:
                Require(
                    KeyCode is not null && Location is null
                        && ButtonNumber is null && ClickCount is null
                        && Pressure is null
                        && ScrollDeltaX is null && ScrollDeltaY is null
                        && HasNoScrollPhase && MediaKey is null
                        && Character is null && ValidKeyboardLayoutIdentifier
                );
                break;
            case RemoteInputKind.SystemDefined:
                Require(
                    MediaKey is not null && ValidMediaKey && IsPressed is not null
                        && KeyCode is null && Location is null
                        && ButtonNumber is null && ClickCount is null
                        && Pressure is null
                        && ScrollDeltaX is null && ScrollDeltaY is null
                        && HasNoScrollPhase && Character is null
                        && KeyboardLayoutIdentifier is null
                );
                break;
            case RemoteInputKind.MouseMoved:
                Require(
                    ValidLocation() && KeyCode is null && IsPressed is null
                        && ButtonNumber is null && ClickCount is null
                        && Pressure is null
                        && ScrollDeltaX is null && ScrollDeltaY is null
                        && HasNoScrollPhase && MediaKey is null
                        && Character is null && KeyboardLayoutIdentifier is null
                );
                break;
            case RemoteInputKind.LeftMouseDown:
            case RemoteInputKind.LeftMouseUp:
            case RemoteInputKind.LeftMouseDragged:
                Require(ValidPointer(0, 0));
                break;
            case RemoteInputKind.RightMouseDown:
            case RemoteInputKind.RightMouseUp:
            case RemoteInputKind.RightMouseDragged:
                Require(ValidPointer(1, 1));
                break;
            case RemoteInputKind.OtherMouseDown:
            case RemoteInputKind.OtherMouseUp:
            case RemoteInputKind.OtherMouseDragged:
                Require(ValidPointer(2, 31));
                break;
            case RemoteInputKind.Scroll:
                Require(
                    Location is null && KeyCode is null && IsPressed is null
                        && ButtonNumber is null && ClickCount is null
                        && Pressure is null && MediaKey is null && Character is null
                        && KeyboardLayoutIdentifier is null
                        && ScrollDeltaX is not null && ScrollDeltaY is not null
                        && ValidPressure
                        && double.IsFinite(ScrollDeltaX.Value)
                        && double.IsFinite(ScrollDeltaY.Value)
                        && Math.Abs(ScrollDeltaX.Value) <= 10_000
                        && Math.Abs(ScrollDeltaY.Value) <= 10_000
                        && ValidScrollPhase
                        && ValidScrollMomentumPhase
                        && ValidScrollEventUnit
                );
                break;
            default:
                throw new RemoteInputException(
                    RemoteInputErrorCode.InvalidFields,
                    "Unknown remote input kind."
                );
        }

        return this;
    }

    private bool ValidModifierFlags =>
        (ModifierFlags & ~ValidModifierFlagsMask) == 0;

    private bool HasNoScrollPhase =>
        ScrollPhase is null && ScrollMomentumPhase is null && ScrollEventUnit is null;

    private bool ValidPressure =>
        Pressure is null || (double.IsFinite(Pressure.Value) && Pressure.Value is >= 0 and <= 1);

    private bool ValidScrollEventUnit =>
        ScrollEventUnit is null
            or global::WindowsKVM.Protocol.ScrollEventUnit.Pixel
            or global::WindowsKVM.Protocol.ScrollEventUnit.Line;

    private bool ValidScrollPhase =>
        this.ScrollPhase is null || this.ScrollPhase.Value switch
        {
            global::WindowsKVM.Protocol.ScrollPhase.Began
                or global::WindowsKVM.Protocol.ScrollPhase.Changed
                or global::WindowsKVM.Protocol.ScrollPhase.Ended
                or global::WindowsKVM.Protocol.ScrollPhase.Cancelled
                or global::WindowsKVM.Protocol.ScrollPhase.MayBegin => true,
            _ => false
        };

    private bool ValidScrollMomentumPhase =>
        this.ScrollMomentumPhase is null || this.ScrollMomentumPhase.Value switch
        {
            global::WindowsKVM.Protocol.ScrollMomentumPhase.Begin
                or global::WindowsKVM.Protocol.ScrollMomentumPhase.Continue
                or global::WindowsKVM.Protocol.ScrollMomentumPhase.End => true,
            _ => false
        };

    private bool ValidMediaKey =>
        this.MediaKey is null || this.MediaKey.Value switch
        {
            global::WindowsKVM.Protocol.MediaKey.SoundUp
                or global::WindowsKVM.Protocol.MediaKey.SoundDown
                or global::WindowsKVM.Protocol.MediaKey.BrightnessUp
                or global::WindowsKVM.Protocol.MediaKey.BrightnessDown
                or global::WindowsKVM.Protocol.MediaKey.Mute
                or global::WindowsKVM.Protocol.MediaKey.Play
                or global::WindowsKVM.Protocol.MediaKey.Next
                or global::WindowsKVM.Protocol.MediaKey.Previous
                or global::WindowsKVM.Protocol.MediaKey.Fast
                or global::WindowsKVM.Protocol.MediaKey.Rewind
                or global::WindowsKVM.Protocol.MediaKey.IlluminationUp
                or global::WindowsKVM.Protocol.MediaKey.IlluminationDown
                or global::WindowsKVM.Protocol.MediaKey.IlluminationToggle => true,
            _ => false
        };

    private bool ValidCharacter
    {
        get
        {
            if (Character is null)
            {
                return true;
            }

            var runes = Character.EnumerateRunes().ToArray();
            return runes.Length == 1
                && runes[0].Value >= 0x20
                && runes[0].Value != 0x7F;
        }
    }

    private bool ValidKeyboardLayoutIdentifier
    {
        get
        {
            if (KeyboardLayoutIdentifier is null)
            {
                return true;
            }

            var trimmed = KeyboardLayoutIdentifier.Trim();
            return trimmed.Length > 0
                && Encoding.UTF8.GetByteCount(trimmed) <= 256
                && trimmed.All(character => character >= ' ' && character != '\x7F');
        }
    }

    private bool ValidLocation()
        => Location is not null
            && double.IsFinite(Location.X)
            && double.IsFinite(Location.Y)
            && Location.X is >= 0 and < 1
            && Location.Y is >= 0 and < 1;

    private bool ValidPointer(int minimumButton, int maximumButton)
        => ValidLocation()
            && KeyCode is null
            && IsPressed is null
            && ButtonNumber is not null
            && ButtonNumber.Value >= minimumButton
            && ButtonNumber.Value <= maximumButton
            && ClickCount is not null
            && ClickCount.Value is >= 0 and <= 255
            && ValidPressure
            && KeyboardLayoutIdentifier is null
            && ScrollDeltaX is null
            && ScrollDeltaY is null
            && HasNoScrollPhase
            && MediaKey is null
            && Character is null;

    private static void Require(bool condition)
    {
        if (!condition)
        {
            throw new RemoteInputException(
                RemoteInputErrorCode.InvalidFields,
                "The remote input event contains invalid fields."
            );
        }
    }

    public static ulong NormalizeModifierFlags(ulong flags)
        => flags & PublicModifierFlagsMask;

    private const ulong PublicModifierFlagsMask = 0x0000_0000_00FF_0100UL;
    private const ulong DeviceModifierFlagsMask = 0x0000_0000_0100_20FFUL;
    private const ulong ValidModifierFlagsMask =
        PublicModifierFlagsMask | DeviceModifierFlagsMask;
}

public enum RemoteInputErrorCode
{
    PayloadTooLarge,
    InvalidFields
}

public sealed class RemoteInputException : Exception
{
    public RemoteInputErrorCode Code { get; }

    public RemoteInputException(RemoteInputErrorCode code, string message)
        : base(message) => Code = code;
}

public static class RemoteInputCodec
{
    public const int MaximumPayloadLength = 16_384;

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull
    };

    public static byte[] Encode(RemoteInputEvent input)
    {
        var validated = input.Validated();
        var data = JsonSerializer.SerializeToUtf8Bytes(validated, JsonOptions);
        if (data.Length > MaximumPayloadLength)
        {
            throw new RemoteInputException(
                RemoteInputErrorCode.PayloadTooLarge,
                "The remote input payload is too large."
            );
        }

        return data;
    }

    public static RemoteInputEvent Decode(ReadOnlySpan<byte> data)
    {
        if (data.Length > MaximumPayloadLength)
        {
            throw new RemoteInputException(
                RemoteInputErrorCode.PayloadTooLarge,
                "The remote input payload is too large."
            );
        }

        try
        {
            var input = JsonSerializer.Deserialize<RemoteInputEvent>(data, JsonOptions)
                ?? throw new JsonException("The remote input event is missing.");
            return input.Validated();
        }
        catch (RemoteInputException)
        {
            throw;
        }
        catch (JsonException ex)
        {
            throw new RemoteInputException(
                RemoteInputErrorCode.InvalidFields,
                $"The remote input event is invalid: {ex.Message}"
            );
        }
    }
}
