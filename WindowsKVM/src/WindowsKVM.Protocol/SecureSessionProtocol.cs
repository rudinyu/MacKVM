using System.Buffers;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace WindowsKVM.Protocol;

/// <summary>
/// Runtime capability checks for the authenticated secure-session transport.
/// Older Windows 10 builds can still use signed pairing, but cannot establish
/// W3 without the platform ChaCha20-Poly1305 primitive.
/// </summary>
public static class SecureSessionCapabilities
{
    public static bool ChaCha20Poly1305Supported =>
        ChaCha20Poly1305.IsSupported;

    public const string MinimumWindowsBuild = "10.0.20142";
}

/// <summary>
/// The authenticated secure-session protocol shared with MacKVM. W3 carries
/// validated control messages over the encrypted channel; Windows-specific
/// input injection remains in the application layer.
/// </summary>
[JsonConverter(typeof(SecureSessionRoleJsonConverter))]
public enum SecureSessionRole
{
    Initiator,
    Responder
}

internal sealed class SecureSessionRoleJsonConverter : JsonConverter<SecureSessionRole>
{
    public override SecureSessionRole Read(
        ref Utf8JsonReader reader,
        Type typeToConvert,
        JsonSerializerOptions options
    )
    {
        if (reader.TokenType != JsonTokenType.String)
        {
            throw new JsonException("Secure-session role must be a string.");
        }

        return reader.GetString() switch
        {
            "initiator" => SecureSessionRole.Initiator,
            "responder" => SecureSessionRole.Responder,
            _ => throw new JsonException("Unknown secure-session role.")
        };
    }

    public override void Write(
        Utf8JsonWriter writer,
        SecureSessionRole value,
        JsonSerializerOptions options
    ) => writer.WriteStringValue(value == SecureSessionRole.Initiator
        ? "initiator"
        : "responder");
}

[JsonConverter(typeof(SecureSessionWireKindJsonConverter))]
internal enum SecureSessionWireKind
{
    Handshake,
    Packet
}

internal sealed class SecureSessionWireKindJsonConverter
    : JsonConverter<SecureSessionWireKind>
{
    public override SecureSessionWireKind Read(
        ref Utf8JsonReader reader,
        Type typeToConvert,
        JsonSerializerOptions options
    )
    {
        if (reader.TokenType != JsonTokenType.String)
        {
            throw new JsonException("Secure-session wire kind must be a string.");
        }

        return reader.GetString() switch
        {
            "handshake" => SecureSessionWireKind.Handshake,
            "packet" => SecureSessionWireKind.Packet,
            _ => throw new JsonException("Unknown secure-session wire kind.")
        };
    }

    public override void Write(
        Utf8JsonWriter writer,
        SecureSessionWireKind value,
        JsonSerializerOptions options
    ) => writer.WriteStringValue(value == SecureSessionWireKind.Handshake
        ? "handshake"
        : "packet");
}

public sealed class SecureSessionHandshake
{
    public const int CurrentDisconnectSignalVersion = 1;

    [JsonPropertyName("sessionID")]
    public Guid SessionID { get; }

    [JsonPropertyName("role")]
    public SecureSessionRole Role { get; }

    [JsonPropertyName("sender")]
    public PeerIdentity Sender { get; }

    [JsonPropertyName("senderModel")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? SenderModel { get; }

    /// <summary>
    /// Signed secure-session close capability. The value is optional on the
    /// wire so the decoder can produce an explicit upgrade error for legacy
    /// peers instead of silently downgrading to EOF teardown.
    /// </summary>
    [JsonIgnore]
    public int? DisconnectSignalVersion { get; }

    [JsonPropertyName("ephemeralPublicKey")]
    public byte[] EphemeralPublicKey { get; }

    [JsonPropertyName("nonce")]
    public byte[] Nonce { get; }

    [JsonConstructor]
    public SecureSessionHandshake(
        Guid sessionID,
        SecureSessionRole role,
        PeerIdentity? sender,
        string? senderModel,
        byte[]? ephemeralPublicKey,
        byte[]? nonce,
        int? disconnectSignalVersion = CurrentDisconnectSignalVersion
    )
    {
        SessionID = sessionID;
        Role = role;
        Sender = sender ?? throw new JsonException("The secure-session sender is missing.");
        SenderModel = senderModel is null
            ? null
            : PeerMetadataValidation.ValidatedModel(senderModel);
        DisconnectSignalVersion = disconnectSignalVersion;
        EphemeralPublicKey = ephemeralPublicKey?.ToArray()
            ?? throw new JsonException("The ephemeral public key is missing.");
        Nonce = nonce?.ToArray()
            ?? throw new JsonException("The secure-session nonce is missing.");
    }

    public static SecureSessionHandshake Create(
        Guid sessionID,
        SecureSessionRole role,
        PeerIdentity sender,
        string? senderModel,
        ECDiffieHellman ephemeralKey,
        int? disconnectSignalVersion = CurrentDisconnectSignalVersion
    )
    {
        var parameters = ephemeralKey.ExportParameters(includePrivateParameters: false);
        return new SecureSessionHandshake(
            sessionID,
            role,
            sender,
            senderModel,
            PairingCrypto.ToX963(parameters.Q),
            PairingVerificationCode.MakeContribution(),
            disconnectSignalVersion
        );
    }
}

/// <summary>
/// Authenticated control markers used by the secure transport itself. They
/// are encrypted inside a SecurePacket and are not ControlMessage payloads.
/// </summary>
public static class SecureSessionControlSignal
{
    private static readonly byte[] DisconnectBytes =
        Encoding.UTF8.GetBytes("MacKVM secure session disconnect v1");
    private static readonly byte[] DisconnectAcknowledgementBytes =
        Encoding.UTF8.GetBytes(
            "MacKVM secure session disconnect acknowledgement v1"
        );

    public static ReadOnlyMemory<byte> Disconnect => DisconnectBytes;
    public static ReadOnlyMemory<byte> DisconnectAcknowledgement
        => DisconnectAcknowledgementBytes;

    public static bool IsDisconnect(ReadOnlySpan<byte> payload)
        => payload.SequenceEqual(DisconnectBytes);

    public static bool IsDisconnectAcknowledgement(ReadOnlySpan<byte> payload)
        => payload.SequenceEqual(DisconnectAcknowledgementBytes);
}

public sealed class SecurePacket
{
    [JsonPropertyName("sessionID")]
    public Guid SessionID { get; }

    [JsonPropertyName("sequence")]
    public ulong Sequence { get; }

    [JsonPropertyName("sealedData")]
    public byte[] SealedData { get; }

    [JsonConstructor]
    public SecurePacket(Guid sessionID, ulong sequence, byte[]? sealedData)
    {
        SessionID = sessionID;
        Sequence = sequence;
        SealedData = sealedData?.ToArray()
            ?? throw new JsonException("The secure packet data is missing.");
    }

}

public enum SecureSessionWireMessageKind
{
    Handshake,
    Packet
}

public sealed class SecureSessionWireMessage
{
    public SecureSessionWireMessageKind Kind { get; }
    public SecureSessionHandshake? Handshake { get; }
    public SecurePacket? Packet { get; }

    private SecureSessionWireMessage(
        SecureSessionWireMessageKind kind,
        SecureSessionHandshake? handshake,
        SecurePacket? packet
    )
    {
        Kind = kind;
        Handshake = handshake;
        Packet = packet;
    }

    public static SecureSessionWireMessage FromHandshake(
        SecureSessionHandshake handshake
    ) => new(SecureSessionWireMessageKind.Handshake, handshake, null);

    public static SecureSessionWireMessage FromPacket(SecurePacket packet)
        => new(SecureSessionWireMessageKind.Packet, null, packet);
}

public enum SecureSessionWireErrorCode
{
    InvalidFrame,
    InvalidHandshake,
    InvalidSignature,
    InvalidIdentityName,
    InvalidModel,
    UnsupportedCapability,
    UnexpectedMessage,
    PayloadTooLarge
}

public sealed class SecureSessionWireException : Exception
{
    public SecureSessionWireErrorCode Code { get; }

    public SecureSessionWireException(
        SecureSessionWireErrorCode code,
        string message
    ) : base(message) => Code = code;
}

internal sealed class SecureSessionWireEnvelope
{
    [JsonPropertyName("kind")]
    public SecureSessionWireKind Kind { get; }

    [JsonPropertyName("handshake")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public SecureSessionHandshake? Handshake { get; }

    [JsonPropertyName("signature")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public byte[]? Signature { get; }

    [JsonPropertyName("senderModel")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? SenderModel { get; }

    [JsonPropertyName("senderModelSignature")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public byte[]? SenderModelSignature { get; }

    [JsonPropertyName("disconnectSignalVersion")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public int? DisconnectSignalVersion { get; }

    [JsonPropertyName("disconnectSignalVersionSignature")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public byte[]? DisconnectSignalVersionSignature { get; }

    [JsonPropertyName("packet")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public SecurePacket? Packet { get; }

    [JsonConstructor]
    public SecureSessionWireEnvelope(
        SecureSessionWireKind kind,
        SecureSessionHandshake? handshake,
        byte[]? signature,
        string? senderModel,
        byte[]? senderModelSignature,
        SecurePacket? packet,
        int? disconnectSignalVersion = null,
        byte[]? disconnectSignalVersionSignature = null
    )
    {
        Kind = kind;
        Handshake = handshake;
        Signature = signature?.ToArray();
        SenderModel = senderModel;
        SenderModelSignature = senderModelSignature?.ToArray();
        DisconnectSignalVersion = disconnectSignalVersion;
        DisconnectSignalVersionSignature =
            disconnectSignalVersionSignature?.ToArray();
        Packet = packet;
    }
}

internal sealed record SecureSessionModelExtension(
    [property: JsonPropertyName("sessionID")] Guid SessionID,
    [property: JsonPropertyName("role")] SecureSessionRole Role,
    [property: JsonPropertyName("senderID")] Guid SenderID,
    [property: JsonPropertyName("model")] string Model
);

internal sealed record SecureSessionDisconnectExtension(
    [property: JsonPropertyName("sessionID")] Guid SessionID,
    [property: JsonPropertyName("role")] SecureSessionRole Role,
    [property: JsonPropertyName("senderID")] Guid SenderID,
    [property: JsonPropertyName("version")] int Version
);

public static class SecureSessionWireCodec
{
    public const int MaximumFramePayloadLength = 64 * 1024;
    public const int MaximumFramesPerDecode = 16;

    public static bool HasCompleteFrame(ReadOnlySpan<byte> buffer)
        => LengthPrefixedFrameCodec.HasCompleteFrame(
            buffer,
            MaximumFramePayloadLength
        );

    public static bool HasCompleteFrame(IReadOnlyList<byte> buffer)
        => LengthPrefixedFrameCodec.HasCompleteFrame(
            buffer,
            MaximumFramePayloadLength
        );

    public static byte[] Encode(
        SecureSessionHandshake handshake,
        ECDsa signingKey
    )
    {
        var baseHandshake = new SecureSessionHandshake(
            handshake.SessionID,
            handshake.Role,
            handshake.Sender,
            senderModel: null,
            handshake.EphemeralPublicKey,
            handshake.Nonce,
            disconnectSignalVersion: null
        );
        var handshakeData = CanonicalJson.Serialize(baseHandshake);
        var signature = signingKey.SignData(
            handshakeData,
            HashAlgorithmName.SHA256,
            DSASignatureFormat.Rfc3279DerSequence
        );
        byte[]? modelSignature = null;
        if (handshake.SenderModel is not null)
        {
            var modelData = CanonicalJson.Serialize(new SecureSessionModelExtension(
                handshake.SessionID,
                handshake.Role,
                handshake.Sender.Id,
                handshake.SenderModel
            ));
            modelSignature = signingKey.SignData(
                modelData,
                HashAlgorithmName.SHA256,
                DSASignatureFormat.Rfc3279DerSequence
            );
        }

        byte[]? disconnectCapabilitySignature = null;
        if (handshake.DisconnectSignalVersion is { } version)
        {
            var extensionData = CanonicalJson.Serialize(
                new SecureSessionDisconnectExtension(
                    handshake.SessionID,
                    handshake.Role,
                    handshake.Sender.Id,
                    version
                )
            );
            disconnectCapabilitySignature = signingKey.SignData(
                extensionData,
                HashAlgorithmName.SHA256,
                DSASignatureFormat.Rfc3279DerSequence
            );
        }

        return EncodeEnvelope(new SecureSessionWireEnvelope(
            SecureSessionWireKind.Handshake,
            baseHandshake,
            signature,
            handshake.SenderModel,
            modelSignature,
            null,
            handshake.DisconnectSignalVersion,
            disconnectCapabilitySignature
        ));
    }

    public static byte[] Encode(SecurePacket packet)
        => EncodeEnvelope(new SecureSessionWireEnvelope(
            SecureSessionWireKind.Packet,
            null,
            null,
            null,
            null,
            packet,
            disconnectSignalVersion: null,
            disconnectSignalVersionSignature: null
        ));

    public static IReadOnlyList<SecureSessionWireMessage> DecodeAvailableFrames(
        List<byte> buffer,
        int maximumFrameCount = MaximumFramesPerDecode
    )
    {
        IReadOnlyList<byte[]> payloads;
        try
        {
            payloads = LengthPrefixedFrameCodec.DecodeAvailablePayloads(
                buffer,
                MaximumFramePayloadLength,
                maximumFrameCount,
                rejectExcessFrames: false
            );
        }
        catch (LengthPrefixedFrameException ex)
        {
            throw new SecureSessionWireException(
                ex.Code == LengthPrefixedFrameErrorCode.TooManyMessages
                    ? SecureSessionWireErrorCode.InvalidFrame
                    : SecureSessionWireErrorCode.PayloadTooLarge,
                ex.Message
            );
        }

        var messages = new List<SecureSessionWireMessage>(payloads.Count);
        foreach (var payload in payloads)
        {
            SecureSessionWireEnvelope envelope;
            try
            {
                envelope = JsonSerializer.Deserialize<SecureSessionWireEnvelope>(
                    payload,
                    CanonicalJson.Options
                ) ?? throw new JsonException("The secure-session envelope was null.");
            }
            catch (JsonException ex)
            {
                throw new SecureSessionWireException(
                    SecureSessionWireErrorCode.InvalidFrame,
                    $"The secure-session envelope is invalid: {ex.Message}"
                );
            }

            messages.Add(Decode(envelope));
        }

        return messages;
    }

    private static SecureSessionWireMessage Decode(
        SecureSessionWireEnvelope envelope
    )
    {
        if (envelope.Kind == SecureSessionWireKind.Packet)
        {
            if (envelope.Packet is null
                || envelope.Handshake is not null
                || envelope.Signature is not null
                || envelope.SenderModel is not null
                || envelope.SenderModelSignature is not null
                || envelope.DisconnectSignalVersion is not null
                || envelope.DisconnectSignalVersionSignature is not null)
            {
                throw new SecureSessionWireException(
                    SecureSessionWireErrorCode.InvalidFrame,
                    "The secure packet envelope contains invalid fields."
                );
            }

            return SecureSessionWireMessage.FromPacket(envelope.Packet);
        }

        if (envelope.Handshake is null
            || envelope.Packet is not null
            || envelope.Signature is null
            || envelope.Handshake.SessionID == Guid.Empty
            || envelope.Handshake.EphemeralPublicKey.Length != 65
            || envelope.Handshake.Nonce.Length != PairingVerificationCode.ContributionLength)
        {
            throw new SecureSessionWireException(
                SecureSessionWireErrorCode.InvalidHandshake,
                "The secure handshake envelope is incomplete."
            );
        }

        if (!PeerIdentity.IsValidDisplayName(envelope.Handshake.Sender.Name))
        {
            throw new SecureSessionWireException(
                SecureSessionWireErrorCode.InvalidIdentityName,
                "The secure handshake identity name is invalid."
            );
        }

        using var publicKey = ImportSigningPublicKey(
            envelope.Handshake.Sender.SigningPublicKey
        );
        var handshakeData = CanonicalJson.Serialize(new SecureSessionHandshake(
            envelope.Handshake.SessionID,
            envelope.Handshake.Role,
            envelope.Handshake.Sender,
            senderModel: null,
            envelope.Handshake.EphemeralPublicKey,
            envelope.Handshake.Nonce,
            disconnectSignalVersion: null
        ));
        if (!publicKey.VerifyData(
                handshakeData,
                envelope.Signature,
                HashAlgorithmName.SHA256,
                DSASignatureFormat.Rfc3279DerSequence
            ))
        {
            throw new SecureSessionWireException(
                SecureSessionWireErrorCode.InvalidSignature,
                "The secure handshake signature is invalid."
            );
        }

        var model = ValidateModelExtension(envelope, publicKey);
        var disconnectSignalVersion = ValidateDisconnectCapability(
            envelope,
            publicKey
        );
        return SecureSessionWireMessage.FromHandshake(new SecureSessionHandshake(
            envelope.Handshake.SessionID,
            envelope.Handshake.Role,
            envelope.Handshake.Sender,
            model,
            envelope.Handshake.EphemeralPublicKey,
            envelope.Handshake.Nonce,
            disconnectSignalVersion
        ));
    }

    private static string? ValidateModelExtension(
        SecureSessionWireEnvelope envelope,
        ECDsa publicKey
    )
    {
        if (envelope.SenderModel is null && envelope.SenderModelSignature is null)
        {
            return null;
        }

        if (envelope.SenderModel is null
            || envelope.SenderModelSignature is null
            || PeerMetadataValidation.ValidatedModel(envelope.SenderModel)
                != envelope.SenderModel)
        {
            throw new SecureSessionWireException(
                SecureSessionWireErrorCode.InvalidModel,
                "The secure handshake model extension is invalid."
            );
        }

        var modelData = CanonicalJson.Serialize(new SecureSessionModelExtension(
            envelope.Handshake!.SessionID,
            envelope.Handshake.Role,
            envelope.Handshake.Sender.Id,
            envelope.SenderModel
        ));
        if (!publicKey.VerifyData(
                modelData,
                envelope.SenderModelSignature,
                HashAlgorithmName.SHA256,
                DSASignatureFormat.Rfc3279DerSequence
            ))
        {
            throw new SecureSessionWireException(
                SecureSessionWireErrorCode.InvalidSignature,
                "The secure handshake model signature is invalid."
            );
        }

        return envelope.SenderModel;
    }

    private static int? ValidateDisconnectCapability(
        SecureSessionWireEnvelope envelope,
        ECDsa publicKey
    )
    {
        if (envelope.DisconnectSignalVersion is null
            && envelope.DisconnectSignalVersionSignature is null)
        {
            return null;
        }

        if (envelope.DisconnectSignalVersion is not { } version
            || envelope.DisconnectSignalVersionSignature is null)
        {
            throw new SecureSessionWireException(
                SecureSessionWireErrorCode.InvalidHandshake,
                "The secure-session disconnect capability is incomplete."
            );
        }

        var extensionData = CanonicalJson.Serialize(
            new SecureSessionDisconnectExtension(
                envelope.Handshake!.SessionID,
                envelope.Handshake.Role,
                envelope.Handshake.Sender.Id,
                version
            )
        );
        if (!publicKey.VerifyData(
                extensionData,
                envelope.DisconnectSignalVersionSignature,
                HashAlgorithmName.SHA256,
                DSASignatureFormat.Rfc3279DerSequence
            ))
        {
            throw new SecureSessionWireException(
                SecureSessionWireErrorCode.InvalidSignature,
                "The secure-session disconnect capability signature is invalid."
            );
        }

        return version;
    }

    private static ECDsa ImportSigningPublicKey(byte[] key)
    {
        try
        {
            return PairingCrypto.ImportPublicKey(key);
        }
        catch (CryptographicException ex)
        {
            throw new SecureSessionWireException(
                SecureSessionWireErrorCode.InvalidSignature,
                $"The secure handshake public key is invalid: {ex.Message}"
            );
        }
    }

    private static byte[] EncodeEnvelope(SecureSessionWireEnvelope envelope)
    {
        var payload = CanonicalJson.Serialize(envelope);
        try
        {
            return LengthPrefixedFrameCodec.Encode(
                payload,
                MaximumFramePayloadLength
            );
        }
        catch (LengthPrefixedFrameException ex)
        {
            throw new SecureSessionWireException(
                SecureSessionWireErrorCode.PayloadTooLarge,
                ex.Message
            );
        }
    }
}

public sealed class SecureSessionChannel : IDisposable
{
    public const int MaximumPlaintextLength = 32 * 1024;
    public const int MaximumSealedDataLength = MaximumPlaintextLength + 12 + 16;
    public static readonly byte[] KeyConfirmation =
        Encoding.UTF8.GetBytes("MacKVM encrypted key confirmation v1");

    public Guid SessionID { get; }

    private readonly byte[] sendingKey;
    private readonly byte[] receivingKey;
    private ulong nextSendingSequence;
    private ulong nextReceivingSequence;
    private int disposed;

    public SecureSessionChannel(
        SecureSessionRole localRole,
        ECDiffieHellman localEphemeralKey,
        SecureSessionHandshake initiator,
        SecureSessionHandshake responder
    )
    {
        if (initiator.Role != SecureSessionRole.Initiator
            || responder.Role != SecureSessionRole.Responder
            || initiator.SessionID != responder.SessionID)
        {
            throw new SecureSessionWireException(
                SecureSessionWireErrorCode.InvalidHandshake,
                "The secure-session roles or session IDs are invalid."
            );
        }

        using var remoteKey = ImportKeyAgreementPublicKey(
            localRole == SecureSessionRole.Initiator
                ? responder.EphemeralPublicKey
                : initiator.EphemeralPublicKey
        );
        var sharedSecret = localEphemeralKey.DeriveRawSecretAgreement(
            remoteKey.PublicKey
        );
        var transcript = Transcript(initiator, responder);
        var initiatorToResponder = HkdfSha256(
            sharedSecret,
            transcript,
            Encoding.UTF8.GetBytes("MacKVM secure session i2r v1"),
            32
        );
        var responderToInitiator = HkdfSha256(
            sharedSecret,
            transcript,
            Encoding.UTF8.GetBytes("MacKVM secure session r2i v1"),
            32
        );
        SessionID = initiator.SessionID;
        sendingKey = localRole == SecureSessionRole.Initiator
            ? initiatorToResponder
            : responderToInitiator;
        receivingKey = localRole == SecureSessionRole.Initiator
            ? responderToInitiator
            : initiatorToResponder;
    }

    public SecurePacket Seal(ReadOnlySpan<byte> plaintext)
    {
        ThrowIfDisposed();
        if (plaintext.Length > MaximumPlaintextLength
            || nextSendingSequence == ulong.MaxValue)
        {
            throw new SecureSessionWireException(
                SecureSessionWireErrorCode.InvalidFrame,
                "The secure plaintext is too large or the sequence is exhausted."
            );
        }

        var nonce = new byte[12];
        RandomNumberGenerator.Fill(nonce);
        var ciphertext = new byte[plaintext.Length];
        var tag = new byte[16];
        var sequence = nextSendingSequence;
        using var cipher = new ChaCha20Poly1305(sendingKey);
        cipher.Encrypt(
            nonce,
            plaintext,
            ciphertext,
            tag,
            AuthenticatedData(sequence)
        );
        nextSendingSequence++;
        var sealedData = new byte[nonce.Length + ciphertext.Length + tag.Length];
        Buffer.BlockCopy(nonce, 0, sealedData, 0, nonce.Length);
        Buffer.BlockCopy(ciphertext, 0, sealedData, nonce.Length, ciphertext.Length);
        Buffer.BlockCopy(
            tag,
            0,
            sealedData,
            nonce.Length + ciphertext.Length,
            tag.Length
        );
        return new SecurePacket(SessionID, sequence, sealedData);
    }

    public byte[] Open(SecurePacket packet)
    {
        ThrowIfDisposed();
        if (packet.SessionID != SessionID || packet.Sequence != nextReceivingSequence)
        {
            throw new SecureSessionWireException(
                SecureSessionWireErrorCode.UnexpectedMessage,
                "The secure packet sequence or session ID is unexpected."
            );
        }
        if (packet.SealedData.Length < 12 + 16
            || packet.SealedData.Length > MaximumSealedDataLength)
        {
            throw new SecureSessionWireException(
                SecureSessionWireErrorCode.InvalidFrame,
                "The secure packet is outside the supported size."
            );
        }

        var ciphertextLength = packet.SealedData.Length - 12 - 16;
        var nonce = packet.SealedData.AsSpan(0, 12).ToArray();
        var ciphertext = packet.SealedData.AsSpan(12, ciphertextLength).ToArray();
        var tag = packet.SealedData.AsSpan(12 + ciphertextLength, 16).ToArray();
        var plaintext = new byte[ciphertextLength];
        try
        {
            using var cipher = new ChaCha20Poly1305(receivingKey);
            cipher.Decrypt(
                nonce,
                ciphertext,
                tag,
                plaintext,
                AuthenticatedData(packet.Sequence)
            );
        }
        catch (CryptographicException ex)
        {
            throw new SecureSessionWireException(
                SecureSessionWireErrorCode.InvalidSignature,
                $"The secure packet authentication failed: {ex.Message}"
            );
        }

        if (nextReceivingSequence == ulong.MaxValue)
        {
            throw new SecureSessionWireException(
                SecureSessionWireErrorCode.UnexpectedMessage,
                "The receive sequence is exhausted."
            );
        }
        nextReceivingSequence++;
        return plaintext;
    }

    public void Dispose()
    {
        if (Interlocked.Exchange(ref disposed, 1) != 0)
        {
            return;
        }

        CryptographicOperations.ZeroMemory(sendingKey);
        CryptographicOperations.ZeroMemory(receivingKey);
    }

    private byte[] AuthenticatedData(ulong sequence)
    {
        using var data = new MemoryStream();
        WriteUtf8(data, "MacKVM packet v1");
        WriteUtf8(data, SessionID.ToString("D").ToUpperInvariant());
        WriteUInt64BigEndian(data, sequence);
        return data.ToArray();
    }

    private static byte[] Transcript(
        SecureSessionHandshake initiator,
        SecureSessionHandshake responder
    )
    {
        using var data = new MemoryStream();
        WriteUtf8(data, "MacKVM secure transcript v1");
        WriteUtf8(data, initiator.SessionID.ToString("D").ToUpperInvariant());
        data.Write(initiator.Sender.SigningPublicKey);
        data.Write(responder.Sender.SigningPublicKey);
        data.Write(initiator.EphemeralPublicKey);
        data.Write(responder.EphemeralPublicKey);
        data.Write(initiator.Nonce);
        data.Write(responder.Nonce);
        return SHA256.HashData(data.ToArray());
    }

    private static byte[] HkdfSha256(
        byte[] inputKeyMaterial,
        byte[] salt,
        byte[] info,
        int outputLength
    )
    {
        var normalizedSalt = salt.Length == 0 ? new byte[32] : salt;
        using var extract = new HMACSHA256(normalizedSalt);
        var pseudorandomKey = extract.ComputeHash(inputKeyMaterial);
        var result = new byte[outputLength];
        var previous = Array.Empty<byte>();
        var written = 0;
        byte counter = 1;
        while (written < outputLength)
        {
            using var expand = new HMACSHA256(pseudorandomKey);
            var input = new byte[previous.Length + info.Length + 1];
            Buffer.BlockCopy(previous, 0, input, 0, previous.Length);
            Buffer.BlockCopy(info, 0, input, previous.Length, info.Length);
            input[^1] = counter;
            previous = expand.ComputeHash(input);
            var copy = Math.Min(previous.Length, outputLength - written);
            Buffer.BlockCopy(previous, 0, result, written, copy);
            written += copy;
            counter++;
        }

        return result;
    }

    private static ECDiffieHellman ImportKeyAgreementPublicKey(byte[] key)
    {
        if (key.Length != 65 || key[0] != 0x04)
        {
            throw new SecureSessionWireException(
                SecureSessionWireErrorCode.InvalidHandshake,
                "Expected an uncompressed P-256 ephemeral public key."
            );
        }

        try
        {
            return ECDiffieHellman.Create(new ECParameters
            {
                Curve = ECCurve.NamedCurves.nistP256,
                Q = new ECPoint
                {
                    X = key[1..33],
                    Y = key[33..65]
                }
            });
        }
        catch (CryptographicException ex)
        {
            throw new SecureSessionWireException(
                SecureSessionWireErrorCode.InvalidHandshake,
                $"The ephemeral public key is invalid: {ex.Message}"
            );
        }
    }

    private static void WriteUtf8(Stream stream, string value)
    {
        var bytes = Encoding.UTF8.GetBytes(value);
        stream.Write(bytes);
    }

    private static void WriteUInt64BigEndian(Stream stream, ulong value)
    {
        Span<byte> bytes = stackalloc byte[8];
        System.Buffers.Binary.BinaryPrimitives.WriteUInt64BigEndian(bytes, value);
        stream.Write(bytes);
    }

    private void ThrowIfDisposed()
    {
        if (Volatile.Read(ref disposed) != 0)
        {
            throw new ObjectDisposedException(nameof(SecureSessionChannel));
        }
    }
}
