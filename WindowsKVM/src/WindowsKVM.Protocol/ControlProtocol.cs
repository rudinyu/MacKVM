using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace WindowsKVM.Protocol;

/// <summary>
/// Wire-level constants shared with the MacKVM 1.00.00 protocol.
/// Keep this project free of Windows UI and input APIs so the same
/// compatibility tests can run on every development host.
/// </summary>
public static class ControlProtocolCompatibility
{
    /// <summary>The JSON envelope version used by the current Mac client.</summary>
    public const int MessageVersion = 1;

    /// <summary>The current negotiated control protocol version.</summary>
    public const int CurrentVersion = 2;

    /// <summary>The oldest negotiated version accepted by MacKVM 1.00.00.</summary>
    public const int MinimumCompatibleVersion = 1;
}

/// <summary>
/// Control messages understood by the MacKVM transport. The explicit
/// converter is part of the wire contract: Swift's Codable representation is
/// lower-camel strings, not numeric enum values or C# member names.
/// </summary>
[JsonConverter(typeof(ControlMessageKindJsonConverter))]
public enum ControlMessageKind
{
    RequestControl,
    ControlGranted,
    ControlDenied,
    EndControl,
    Input
}

public sealed class ControlMessageKindJsonConverter : JsonConverter<ControlMessageKind>
{
    public override ControlMessageKind Read(
        ref Utf8JsonReader reader,
        Type typeToConvert,
        JsonSerializerOptions options
    )
    {
        if (reader.TokenType != JsonTokenType.String)
        {
            throw new JsonException("Control message kind must be a string.");
        }

        return reader.GetString() switch
        {
            "requestControl" => ControlMessageKind.RequestControl,
            "controlGranted" => ControlMessageKind.ControlGranted,
            "controlDenied" => ControlMessageKind.ControlDenied,
            "endControl" => ControlMessageKind.EndControl,
            "input" => ControlMessageKind.Input,
            _ => throw new JsonException("Unknown control message kind.")
        };
    }

    public override void Write(
        Utf8JsonWriter writer,
        ControlMessageKind value,
        JsonSerializerOptions options
    )
    {
        writer.WriteStringValue(value switch
        {
            ControlMessageKind.RequestControl => "requestControl",
            ControlMessageKind.ControlGranted => "controlGranted",
            ControlMessageKind.ControlDenied => "controlDenied",
            ControlMessageKind.EndControl => "endControl",
            ControlMessageKind.Input => "input",
            _ => throw new JsonException("Unknown control message kind.")
        });
    }
}

public sealed class ControlMessage
{
    public const int CurrentVersion = ControlProtocolCompatibility.MessageVersion;

    [JsonPropertyName("version")]
    public int Version { get; }

    [JsonPropertyName("kind")]
    public ControlMessageKind Kind { get; }

    [JsonPropertyName("requestID")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public Guid? RequestID { get; }

    [JsonPropertyName("input")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public RemoteInputEvent? Input { get; }

    [JsonPropertyName("protocolVersion")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public int? ProtocolVersion { get; }

    [JsonPropertyName("minimumProtocolVersion")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public int? MinimumProtocolVersion { get; }

    [JsonPropertyName("keyboardLayoutIdentifier")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? KeyboardLayoutIdentifier { get; }

    [JsonConstructor]
    public ControlMessage(
        int version,
        ControlMessageKind kind,
        Guid? requestID,
        RemoteInputEvent? input,
        int? protocolVersion,
        int? minimumProtocolVersion,
        string? keyboardLayoutIdentifier
    )
    {
        Version = version;
        Kind = kind;
        RequestID = requestID;
        Input = input;
        ProtocolVersion = protocolVersion;
        MinimumProtocolVersion = minimumProtocolVersion;
        KeyboardLayoutIdentifier = keyboardLayoutIdentifier;
    }

    public ControlMessage(
        ControlMessageKind kind,
        Guid? requestID = null,
        RemoteInputEvent? input = null,
        int? protocolVersion = null,
        int? minimumProtocolVersion = null,
        string? keyboardLayoutIdentifier = null,
        int version = CurrentVersion
    ) : this(
        version,
        kind,
        requestID,
        input,
        protocolVersion,
        minimumProtocolVersion,
        keyboardLayoutIdentifier
    )
    {
    }

    public static ControlMessage RequestControl(
        Guid requestID,
        string? keyboardLayoutIdentifier = null
    ) => new(
        ControlMessageKind.RequestControl,
        requestID,
        protocolVersion: ControlProtocolCompatibility.CurrentVersion,
        minimumProtocolVersion: ControlProtocolCompatibility.MinimumCompatibleVersion,
        keyboardLayoutIdentifier: keyboardLayoutIdentifier
    );

    public static ControlMessage InputMessage(
        RemoteInputEvent input,
        Guid requestID
    ) => new(ControlMessageKind.Input, requestID, input);

    public ControlMessage Validated()
    {
        if (Version != CurrentVersion)
        {
            throw new ControlMessageException(
                ControlMessageErrorCode.UnsupportedVersion,
                "The control message version is not supported."
            );
        }

        switch (Kind)
        {
            case ControlMessageKind.Input:
                Require(
                    RequestID is not null
                        && Input is not null
                        && ProtocolVersion is null
                        && MinimumProtocolVersion is null
                        && KeyboardLayoutIdentifier is null
                );
                Input!.Validated();
                break;
            case ControlMessageKind.RequestControl:
                Require(
                    RequestID is not null
                        && Input is null
                        && ValidNegotiationFields
                );
                break;
            case ControlMessageKind.ControlGranted:
            case ControlMessageKind.ControlDenied:
            case ControlMessageKind.EndControl:
                Require(
                    RequestID is not null
                        && Input is null
                        && ProtocolVersion is null
                        && MinimumProtocolVersion is null
                        && KeyboardLayoutIdentifier is null
                );
                break;
            default:
                throw new ControlMessageException(
                    ControlMessageErrorCode.InvalidFields,
                    "The control message kind is not supported."
                );
        }

        return this;
    }

    private bool ValidNegotiationFields
    {
        get
        {
            if (ProtocolVersion is not null)
            {
                var minimum = MinimumProtocolVersion ?? ProtocolVersion.Value;
                if (ProtocolVersion is < 1 or > 255
                    || minimum is < 1 or > 255
                    || minimum > ProtocolVersion)
                {
                    return false;
                }
            }
            else if (MinimumProtocolVersion is not null)
            {
                return false;
            }

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

    private static void Require(bool condition)
    {
        if (!condition)
        {
            throw new ControlMessageException(
                ControlMessageErrorCode.InvalidFields,
                "The control message contains invalid fields."
            );
        }
    }
}

public enum ControlMessageErrorCode
{
    PayloadTooLarge,
    UnsupportedVersion,
    InvalidFields
}

public sealed class ControlMessageException : Exception
{
    public ControlMessageErrorCode Code { get; }

    public ControlMessageException(ControlMessageErrorCode code, string message)
        : base(message) => Code = code;
}

public static class ControlMessageCodec
{
    public const int MaximumPayloadLength = 32_768;

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull
    };

    public static byte[] Encode(ControlMessage message)
    {
        var validated = message.Validated();
        var data = JsonSerializer.SerializeToUtf8Bytes(validated, JsonOptions);
        if (data.Length > MaximumPayloadLength)
        {
            throw new ControlMessageException(
                ControlMessageErrorCode.PayloadTooLarge,
                "The control message payload is too large."
            );
        }

        return data;
    }

    public static ControlMessage Decode(ReadOnlySpan<byte> data)
    {
        if (data.Length > MaximumPayloadLength)
        {
            throw new ControlMessageException(
                ControlMessageErrorCode.PayloadTooLarge,
                "The control message payload is too large."
            );
        }

        try
        {
            var message = JsonSerializer.Deserialize<ControlMessage>(data, JsonOptions)
                ?? throw new JsonException("The control message is missing.");
            return message.Validated();
        }
        catch (ControlMessageException)
        {
            throw;
        }
        catch (JsonException ex)
        {
            throw new ControlMessageException(
                ControlMessageErrorCode.InvalidFields,
                $"The control message is invalid: {ex.Message}"
            );
        }
    }
}
