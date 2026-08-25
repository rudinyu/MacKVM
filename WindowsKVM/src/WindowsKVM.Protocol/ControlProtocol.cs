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
