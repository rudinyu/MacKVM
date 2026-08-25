using System.Buffers;
using System.Security.Cryptography;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace WindowsKVM.Protocol;

/// <summary>
/// The authenticated pairing wire protocol shared with MacKVM 1.00.00.
/// This file intentionally has no Windows dependencies so it can be tested
/// on the M5 build machine before a Windows ARM device is available.
/// </summary>
public enum PairingMessageKind
{
    Request,
    Challenge,
    Reveal,
    Confirmation,
    Decision,
    Completion,
    CompletionAcknowledgement,
    CompletionClose,
    CompletionCloseAcknowledgement
}

public sealed class PairingMessageKindJsonConverter : JsonConverter<PairingMessageKind>
{
    public override PairingMessageKind Read(
        ref Utf8JsonReader reader,
        Type typeToConvert,
        JsonSerializerOptions options
    )
    {
        if (reader.TokenType != JsonTokenType.String)
        {
            throw new JsonException("Pairing message kind must be a string.");
        }

        return reader.GetString() switch
        {
            "request" => PairingMessageKind.Request,
            "challenge" => PairingMessageKind.Challenge,
            "reveal" => PairingMessageKind.Reveal,
            "confirmation" => PairingMessageKind.Confirmation,
            "decision" => PairingMessageKind.Decision,
            "completion" => PairingMessageKind.Completion,
            "completionAcknowledgement" => PairingMessageKind.CompletionAcknowledgement,
            "completionClose" => PairingMessageKind.CompletionClose,
            "completionCloseAcknowledgement" => PairingMessageKind.CompletionCloseAcknowledgement,
            _ => throw new JsonException("Unknown pairing message kind.")
        };
    }

    public override void Write(
        Utf8JsonWriter writer,
        PairingMessageKind value,
        JsonSerializerOptions options
    )
    {
        writer.WriteStringValue(value switch
        {
            PairingMessageKind.Request => "request",
            PairingMessageKind.Challenge => "challenge",
            PairingMessageKind.Reveal => "reveal",
            PairingMessageKind.Confirmation => "confirmation",
            PairingMessageKind.Decision => "decision",
            PairingMessageKind.Completion => "completion",
            PairingMessageKind.CompletionAcknowledgement => "completionAcknowledgement",
            PairingMessageKind.CompletionClose => "completionClose",
            PairingMessageKind.CompletionCloseAcknowledgement => "completionCloseAcknowledgement",
            _ => throw new JsonException("Unknown pairing message kind.")
        });
    }
}

/// <summary>UUID JSON converter matching Foundation's UUID string form.</summary>
public sealed class UppercaseGuidJsonConverter : JsonConverter<Guid>
{
    public override Guid Read(
        ref Utf8JsonReader reader,
        Type typeToConvert,
        JsonSerializerOptions options
    )
    {
        if (reader.TokenType != JsonTokenType.String
            || !Guid.TryParse(reader.GetString(), out var value))
        {
            throw new JsonException("Expected a UUID string.");
        }

        return value;
    }

    public override void Write(
        Utf8JsonWriter writer,
        Guid value,
        JsonSerializerOptions options
    ) => writer.WriteStringValue(value.ToString("D").ToUpperInvariant());
}

public sealed class PeerIdentity
{
    public const int MaximumDisplayNameBytes = 64;

    [JsonPropertyName("id")]
    public Guid Id { get; }

    [JsonPropertyName("name")]
    public string Name { get; }

    [JsonPropertyName("signingPublicKey")]
    public byte[] SigningPublicKey { get; }

    [JsonConstructor]
    public PeerIdentity(Guid id, string? name, byte[]? signingPublicKey)
    {
        Id = id;
        Name = name ?? throw new JsonException("The peer display name is missing.");
        SigningPublicKey = signingPublicKey?.ToArray()
            ?? throw new JsonException("The peer signing key is missing.");
    }

    [JsonIgnore]
    public string ServiceName =>
        "MacKVM-" + Id.ToString("D").ToUpperInvariant();

    public static bool IsValidDisplayName(string? name)
    {
        if (string.IsNullOrWhiteSpace(name)
            || Encoding.UTF8.GetByteCount(name) > MaximumDisplayNameBytes)
        {
            return false;
        }

        foreach (var rune in name.EnumerateRunes())
        {
            var value = rune.Value;
            var category = Rune.GetUnicodeCategory(rune);
            if (value < 0x20 || value == 0x7f
                || (value is >= 0x80 and <= 0x9f)
                || value is 0x2028 or 0x2029
                || !IsAllowedDisplayCategory(category, value))
            {
                return false;
            }
        }

        // A string made only from combining marks/format characters is not a
        // useful identity and can render as an invisible menu item.
        return name.EnumerateRunes().Any(rune =>
        {
            var category = Rune.GetUnicodeCategory(rune);
            return category is not System.Globalization.UnicodeCategory.NonSpacingMark
                and not System.Globalization.UnicodeCategory.SpacingCombiningMark
                and not System.Globalization.UnicodeCategory.EnclosingMark
                and not System.Globalization.UnicodeCategory.Format;
        });
    }

    private static bool IsAllowedDisplayCategory(
        System.Globalization.UnicodeCategory category,
        int value
    ) => category switch
    {
        System.Globalization.UnicodeCategory.UppercaseLetter
            or System.Globalization.UnicodeCategory.LowercaseLetter
            or System.Globalization.UnicodeCategory.TitlecaseLetter
            or System.Globalization.UnicodeCategory.ModifierLetter
            or System.Globalization.UnicodeCategory.OtherLetter
            or System.Globalization.UnicodeCategory.NonSpacingMark
            or System.Globalization.UnicodeCategory.SpacingCombiningMark
            or System.Globalization.UnicodeCategory.EnclosingMark
            or System.Globalization.UnicodeCategory.DecimalDigitNumber
            or System.Globalization.UnicodeCategory.LetterNumber
            or System.Globalization.UnicodeCategory.OtherNumber
            or System.Globalization.UnicodeCategory.ConnectorPunctuation
            or System.Globalization.UnicodeCategory.DashPunctuation
            or System.Globalization.UnicodeCategory.OpenPunctuation
            or System.Globalization.UnicodeCategory.ClosePunctuation
            or System.Globalization.UnicodeCategory.InitialQuotePunctuation
            or System.Globalization.UnicodeCategory.FinalQuotePunctuation
            or System.Globalization.UnicodeCategory.OtherPunctuation
            or System.Globalization.UnicodeCategory.MathSymbol
            or System.Globalization.UnicodeCategory.CurrencySymbol
            or System.Globalization.UnicodeCategory.ModifierSymbol
            or System.Globalization.UnicodeCategory.OtherSymbol
            or System.Globalization.UnicodeCategory.SpaceSeparator => true,
        System.Globalization.UnicodeCategory.Format =>
            value is >= 0xFE00 and <= 0xFE0F,
        _ => false
    };
}

public static class PeerMetadataValidation
{
    public const int MaximumModelBytes = 64;
    public const string UnknownModel = "Unknown Mac";

    public static string ValidatedModel(string? model)
    {
        if (model is null)
        {
            return UnknownModel;
        }

        var trimmed = model.Trim();
        return Encoding.UTF8.GetByteCount(trimmed) <= MaximumModelBytes
            && PeerIdentity.IsValidDisplayName(trimmed)
            ? trimmed
            : UnknownModel;
    }
}

/// <summary>A signed pairing frame before it is decoded into an authenticated envelope.</summary>
public sealed class PairingEnvelope
{
    [JsonPropertyName("kind")]
    public PairingMessageKind Kind { get; }

    [JsonPropertyName("requestID")]
    public Guid RequestID { get; }

    [JsonPropertyName("sender")]
    public PeerIdentity Sender { get; }

    [JsonPropertyName("senderModel")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? SenderModel { get; }

    [JsonPropertyName("verificationCommitment")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public byte[]? VerificationCommitment { get; }

    [JsonPropertyName("verificationContribution")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public byte[]? VerificationContribution { get; }

    [JsonPropertyName("accepted")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public bool? Accepted { get; }

    [JsonPropertyName("supportsCompletionClose")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public bool? SupportsCompletionClose { get; }

    [JsonConstructor]
    public PairingEnvelope(
        PairingMessageKind kind,
        Guid requestID,
        PeerIdentity? sender,
        string? senderModel = null,
        byte[]? verificationCommitment = null,
        byte[]? verificationContribution = null,
        bool? accepted = null,
        // Keep the decoder's absent optional field as nil. Factory methods
        // below pass true explicitly for current protocol messages.
        bool? supportsCompletionClose = null
    )
    {
        Kind = kind;
        RequestID = requestID;
        Sender = sender ?? throw new JsonException("The pairing sender is missing.");
        SenderModel = senderModel is null
            ? null
            : PeerMetadataValidation.ValidatedModel(senderModel);
        VerificationCommitment = verificationCommitment?.ToArray();
        VerificationContribution = verificationContribution?.ToArray();
        Accepted = accepted;
        SupportsCompletionClose = supportsCompletionClose;
    }

    public static PairingEnvelope Request(
        PeerIdentity sender,
        Guid requestID,
        byte[] commitment,
        string? senderModel = null
    ) => new(
        PairingMessageKind.Request,
        requestID,
        sender,
        senderModel,
        verificationCommitment: commitment,
        supportsCompletionClose: true
    );

    public static PairingEnvelope Challenge(
        PairingEnvelope message,
        PeerIdentity sender,
        byte[] commitment,
        string? senderModel = null
    ) => new(
        PairingMessageKind.Challenge,
        message.RequestID,
        sender,
        senderModel,
        verificationCommitment: commitment,
        supportsCompletionClose: true
    );

    public static PairingEnvelope Reveal(
        PairingEnvelope message,
        PeerIdentity sender,
        byte[] contribution,
        string? senderModel = null
    ) => new(
        PairingMessageKind.Reveal,
        message.RequestID,
        sender,
        senderModel,
        verificationContribution: contribution,
        supportsCompletionClose: true
    );

    public static PairingEnvelope Confirmation(
        PairingEnvelope message,
        PeerIdentity sender,
        byte[] contribution,
        string? senderModel = null
    ) => new(
        PairingMessageKind.Confirmation,
        message.RequestID,
        sender,
        senderModel,
        verificationContribution: contribution,
        supportsCompletionClose: true
    );

    public static PairingEnvelope Decision(
        PairingEnvelope message,
        PeerIdentity sender,
        bool accepted,
        string? senderModel = null
    ) => new(
        PairingMessageKind.Decision,
        message.RequestID,
        sender,
        senderModel,
        accepted: accepted,
        supportsCompletionClose: true
    );

    public static PairingEnvelope Completion(
        PairingEnvelope message,
        PeerIdentity sender,
        string? senderModel = null
    ) => new(PairingMessageKind.Completion, message.RequestID, sender, senderModel,
        supportsCompletionClose: true);

    public static PairingEnvelope CompletionAcknowledgement(
        PairingEnvelope message,
        PeerIdentity sender,
        string? senderModel = null
    ) => new(
        PairingMessageKind.CompletionAcknowledgement,
        message.RequestID,
        sender,
        senderModel,
        supportsCompletionClose: true
    );

    public static PairingEnvelope CompletionClose(
        PairingEnvelope message,
        PeerIdentity sender,
        string? senderModel = null
    ) => new(PairingMessageKind.CompletionClose, message.RequestID, sender, senderModel,
        supportsCompletionClose: true);

    public static PairingEnvelope CompletionCloseAcknowledgement(
        PairingEnvelope message,
        PeerIdentity sender,
        string? senderModel = null
    ) => new(
        PairingMessageKind.CompletionCloseAcknowledgement,
        message.RequestID,
        sender,
        senderModel,
        supportsCompletionClose: true
    );
}

public sealed class DeviceCredentials : IDisposable
{
    public PeerIdentity Identity { get; }
    public ECDsa PrivateKey { get; }

    private DeviceCredentials(PeerIdentity identity, ECDsa privateKey)
    {
        Identity = identity;
        PrivateKey = privateKey;
    }

    public static DeviceCredentials Create(string name)
    {
        if (!PeerIdentity.IsValidDisplayName(name))
        {
            throw new ArgumentException("The display name is not valid.", nameof(name));
        }

        using var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var parameters = key.ExportParameters(includePrivateParameters: true);
        var publicKey = PairingCrypto.ToX963(parameters.Q);
        var retainedKey = ECDsa.Create(parameters);
        return new DeviceCredentials(
            new PeerIdentity(Guid.NewGuid(), name, publicKey),
            retainedKey
        );
    }

    /// <summary>
    /// Rehydrates a key protected by a platform credential store. Callers
    /// must verify that the public key matches before invoking this method.
    /// </summary>
    public static DeviceCredentials FromStored(PeerIdentity identity, ECDsa privateKey)
    {
        if (!PeerIdentity.IsValidDisplayName(identity.Name)
            || !CryptographicOperations.FixedTimeEquals(
                identity.SigningPublicKey,
                PairingCrypto.ToX963(privateKey.ExportParameters(false).Q)
            ))
        {
            privateKey.Dispose();
            throw new CryptographicException("The stored identity is invalid.");
        }

        return new DeviceCredentials(identity, privateKey);
    }

    public void Dispose() => PrivateKey.Dispose();
}

public static class PairingVerificationCode
{
    public const int ContributionLength = 32;

    public static byte[] MakeContribution()
    {
        var contribution = new byte[ContributionLength];
        RandomNumberGenerator.Fill(contribution);
        return contribution;
    }

    public static byte[] Commitment(
        Guid requestID,
        byte[] publicKey,
        byte[] contribution
    ) => Sha256(
        "MacKVM pairing commitment v1"u8.ToArray(),
        Encoding.UTF8.GetBytes(requestID.ToString("D").ToUpperInvariant()),
        publicKey,
        contribution
    );

    public static bool Verifies(
        byte[] commitment,
        Guid requestID,
        byte[] publicKey,
        byte[] contribution
    ) => contribution.Length == ContributionLength
        && CryptographicOperations.FixedTimeEquals(
            commitment,
            Commitment(requestID, publicKey, contribution)
        );

    public static string Make(
        Guid requestID,
        byte[] initiatorPublicKey,
        byte[] responderPublicKey,
        byte[] initiatorContribution,
        byte[] responderContribution
    )
    {
        var digest = Sha256(
            "MacKVM pairing verification v1"u8.ToArray(),
            Encoding.UTF8.GetBytes(requestID.ToString("D").ToUpperInvariant()),
            initiatorPublicKey,
            responderPublicKey,
            initiatorContribution,
            responderContribution
        );
        var numericCode = ((uint)digest[0] << 24)
            | ((uint)digest[1] << 16)
            | ((uint)digest[2] << 8)
            | digest[3];
        return (numericCode % 1_000_000u).ToString("D6");
    }

    private static byte[] Sha256(params byte[][] parts)
    {
        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        foreach (var part in parts)
        {
            hash.AppendData(part);
        }

        return hash.GetHashAndReset();
    }
}

internal static class PairingCrypto
{
    public static byte[] ToX963(ECPoint point)
    {
        if (point.X is null || point.Y is null
            || point.X.Length != 32 || point.Y.Length != 32)
        {
            throw new CryptographicException("Expected a P-256 public key.");
        }

        return [0x04, .. point.X, .. point.Y];
    }

    public static ECDsa ImportPublicKey(byte[] x963)
    {
        if (x963.Length != 65 || x963[0] != 0x04)
        {
            throw new CryptographicException("Expected an uncompressed P-256 key.");
        }

        return ECDsa.Create(new ECParameters
        {
            Curve = ECCurve.NamedCurves.nistP256,
            Q = new ECPoint
            {
                X = x963[1..33],
                Y = x963[33..65]
            }
        });
    }
}

public enum PairingWireErrorCode
{
    PayloadTooLarge,
    TooManyMessages,
    UnsupportedCapability,
    InvalidSignature,
    InvalidIdentityName,
    InvalidModel,
    InvalidFrame
}

public sealed class PairingWireException : Exception
{
    public PairingWireErrorCode Code { get; }

    public PairingWireException(PairingWireErrorCode code, string message)
        : base(message) => Code = code;
}

public static class PairingWireCodec
{
    public const int MaximumFramePayloadLength = 64 * 1024;
    public const int MaximumFramesPerDecode = 16;

    public static bool HasCompleteFrame(ReadOnlySpan<byte> buffer)
        => LengthPrefixedFrameCodec.HasCompleteFrame(
            buffer,
            MaximumFramePayloadLength
        );

    public static byte[] Encode(PairingEnvelope message, ECDsa signingKey)
    {
        if (message.SupportsCompletionClose != true)
        {
            throw new PairingWireException(
                PairingWireErrorCode.UnsupportedCapability,
                "The completion-close capability is required."
            );
        }

        var baseMessage = new PairingEnvelope(
            message.Kind,
            message.RequestID,
            message.Sender,
            verificationCommitment: message.VerificationCommitment,
            verificationContribution: message.VerificationContribution,
            accepted: message.Accepted,
            supportsCompletionClose: null
        );
        var messageData = CanonicalJson.Serialize(baseMessage);
        var signature = signingKey.SignData(
            messageData,
            HashAlgorithmName.SHA256,
            DSASignatureFormat.Rfc3279DerSequence
        );

        byte[]? modelSignature = null;
        if (message.SenderModel is not null)
        {
            var modelData = CanonicalJson.Serialize(new PairingModelExtension(
                message.Kind,
                message.RequestID,
                message.Sender.Id,
                message.SenderModel
            ));
            modelSignature = signingKey.SignData(
                modelData,
                HashAlgorithmName.SHA256,
                DSASignatureFormat.Rfc3279DerSequence
            );
        }

        var featureData = CanonicalJson.Serialize(new PairingFeatureExtension(
            message.Kind,
            message.RequestID,
            message.Sender.Id,
            true
        ));
        var featureSignature = signingKey.SignData(
            featureData,
            HashAlgorithmName.SHA256,
            DSASignatureFormat.Rfc3279DerSequence
        );
        var signed = new SignedPairingEnvelope(
            baseMessage,
            signature,
            message.SenderModel,
            modelSignature,
            true,
            featureSignature
        );
        var payload = CanonicalJson.Serialize(signed);
        try
        {
            return LengthPrefixedFrameCodec.Encode(
                payload,
                MaximumFramePayloadLength
            );
        }
        catch (LengthPrefixedFrameException)
        {
            throw new PairingWireException(
                PairingWireErrorCode.PayloadTooLarge,
                "The pairing payload is too large."
            );
        }
    }

    public static IReadOnlyList<PairingEnvelope> DecodeAvailableFrames(
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
                maximumFrameCount
            );
        }
        catch (LengthPrefixedFrameException ex)
        {
            var code = ex.Code == LengthPrefixedFrameErrorCode.TooManyMessages
                ? PairingWireErrorCode.TooManyMessages
                : PairingWireErrorCode.PayloadTooLarge;
            throw new PairingWireException(code, ex.Message);
        }

        var messages = new List<PairingEnvelope>(payloads.Count);
        foreach (var payload in payloads)
        {
            SignedPairingEnvelope signed;
            try
            {
                signed = JsonSerializer.Deserialize<SignedPairingEnvelope>(
                    payload,
                    CanonicalJson.Options
                ) ?? throw new JsonException("The pairing envelope was null.");
            }
            catch (JsonException ex)
            {
                throw new PairingWireException(
                    PairingWireErrorCode.InvalidFrame,
                    $"The pairing envelope is invalid: {ex.Message}"
                );
            }

            messages.Add(Verify(signed));
        }

        return messages;
    }

    private static PairingEnvelope Verify(SignedPairingEnvelope signed)
    {
        if (signed.Message.SenderModel is not null)
        {
            throw new PairingWireException(
                PairingWireErrorCode.InvalidModel,
                "The base signed message contains an unsigned model."
            );
        }

        if (!PeerIdentity.IsValidDisplayName(signed.Message.Sender.Name))
        {
            throw new PairingWireException(
                PairingWireErrorCode.InvalidIdentityName,
                "The peer display name is invalid."
            );
        }

        ECDsa publicKey;
        try
        {
            publicKey = PairingCrypto.ImportPublicKey(
                signed.Message.Sender.SigningPublicKey
            );
        }
        catch (CryptographicException ex)
        {
            throw new PairingWireException(
                PairingWireErrorCode.InvalidSignature,
                $"The peer public key is invalid: {ex.Message}"
            );
        }

        using (publicKey)
        {
            var messageData = CanonicalJson.Serialize(signed.Message);
            if (!publicKey.VerifyData(
                    messageData,
                    signed.Signature,
                    HashAlgorithmName.SHA256,
                    DSASignatureFormat.Rfc3279DerSequence
                ))
            {
                throw new PairingWireException(
                    PairingWireErrorCode.InvalidSignature,
                    "The pairing message signature is invalid."
                );
            }

            string? model;
            if (signed.SenderModel is null && signed.SenderModelSignature is null)
            {
                model = null;
            }
            else if (signed.SenderModel is not null
                && signed.SenderModelSignature is not null
                && PeerMetadataValidation.ValidatedModel(signed.SenderModel)
                    == signed.SenderModel)
            {
                var modelData = CanonicalJson.Serialize(new PairingModelExtension(
                    signed.Message.Kind,
                    signed.Message.RequestID,
                    signed.Message.Sender.Id,
                    signed.SenderModel
                ));
                if (!publicKey.VerifyData(
                        modelData,
                        signed.SenderModelSignature,
                        HashAlgorithmName.SHA256,
                        DSASignatureFormat.Rfc3279DerSequence
                    ))
                {
                    throw new PairingWireException(
                        PairingWireErrorCode.InvalidSignature,
                        "The model extension signature is invalid."
                    );
                }

                model = signed.SenderModel;
            }
            else
            {
                throw new PairingWireException(
                    PairingWireErrorCode.InvalidModel,
                    "The model extension is incomplete or invalid."
                );
            }

            if (signed.SupportsCompletionClose != true
                || signed.CompletionFeatureSignature is null)
            {
                throw new PairingWireException(
                    PairingWireErrorCode.UnsupportedCapability,
                    "The signed completion-close capability is missing."
                );
            }

            var featureData = CanonicalJson.Serialize(new PairingFeatureExtension(
                signed.Message.Kind,
                signed.Message.RequestID,
                signed.Message.Sender.Id,
                true
            ));
            if (!publicKey.VerifyData(
                    featureData,
                    signed.CompletionFeatureSignature,
                    HashAlgorithmName.SHA256,
                    DSASignatureFormat.Rfc3279DerSequence
                ))
            {
                throw new PairingWireException(
                    PairingWireErrorCode.InvalidSignature,
                    "The completion-close capability signature is invalid."
                );
            }

            return new PairingEnvelope(
                signed.Message.Kind,
                signed.Message.RequestID,
                signed.Message.Sender,
                model,
                signed.Message.VerificationCommitment,
                signed.Message.VerificationContribution,
                signed.Message.Accepted,
                true
            );
        }
    }
}

public enum PairingSessionRole
{
    Initiator,
    Responder
}

public sealed class PairingSessionException : Exception
{
    public PairingSessionException(string message) : base(message) { }
}

/// <summary>
/// Transport-independent pairing state machine. It mirrors the MacKVM flow:
/// the responder sends a signed confirmation after showing its code, the
/// initiator confirms the matching code, and both signed decisions are
/// required before the completion/close barrier can persist trust.
/// </summary>
public sealed class PairingSession
{
    private readonly PairingSessionRole role;
    private readonly PeerIdentity localIdentity;
    private readonly ECDsa signingKey;
    private readonly string? localModel;
    private Guid requestID;
    private bool requestIDAssigned;
    private readonly byte[] localContribution;
    private readonly PairingEnvelope? localRequest;
    private PeerIdentity? peer;
    private byte[]? peerCommitment;
    private byte[]? peerContribution;
    private bool localAccepted;
    private bool remoteAccepted;
    private bool localCompletionSent;
    private bool remoteCompletionReceived;
    private bool localAcknowledgementSent;
    private bool remoteAcknowledgementReceived;
    private bool closeSent;
    private bool closeReceived;
    private bool closeAcknowledgementSent;
    private bool closeAcknowledgementReceived;
    private bool terminal;
    private bool completed;

    public PairingSession(
        PairingSessionRole role,
        PeerIdentity localIdentity,
        ECDsa signingKey,
        Guid? requestID = null,
        PeerIdentity? expectedPeer = null,
        string? localModel = null
    )
    {
        this.role = role;
        this.localIdentity = localIdentity;
        this.signingKey = signingKey;
        this.localModel = localModel;
        requestIDAssigned = role == PairingSessionRole.Initiator;
        if (requestIDAssigned)
        {
            this.requestID = requestID is null || requestID == Guid.Empty
                ? Guid.NewGuid()
                : requestID.Value;
        }
        else
        {
            this.requestID = Guid.Empty;
        }
        this.peer = expectedPeer;
        localContribution = PairingVerificationCode.MakeContribution();
        if (role == PairingSessionRole.Initiator)
        {
            localRequest = PairingEnvelope.Request(
                localIdentity,
                this.requestID,
                PairingVerificationCode.Commitment(
                    this.requestID,
                    localIdentity.SigningPublicKey,
                    localContribution
                ),
                senderModel: localModel
            );
        }
    }

    public Guid RequestID => requestID;
    public PeerIdentity? Peer => peer;
    public bool IsCompleted => completed;
    public bool IsTerminal => terminal || completed;

    public PairingSessionResult Start()
    {
        if (role != PairingSessionRole.Initiator || localRequest is null)
        {
            throw new PairingSessionException(
                "Only an initiator can start a pairing session."
            );
        }

        return Result([localRequest]);
    }

    public PairingSessionResult Receive(PairingEnvelope message)
    {
        if (IsTerminal)
        {
            throw new PairingSessionException("The pairing session is complete.");
        }

        if (role == PairingSessionRole.Responder
            && !requestIDAssigned
            && message.Kind == PairingMessageKind.Request)
        {
            requestID = message.RequestID;
            requestIDAssigned = true;
        }

        if (!requestIDAssigned
            || message.RequestID != requestID
            || message.SupportsCompletionClose != true)
        {
            throw new PairingSessionException("The pairing request ID or capability is invalid.");
        }

        return message.Kind switch
        {
            PairingMessageKind.Request => ReceiveRequest(message),
            PairingMessageKind.Challenge => ReceiveChallenge(message),
            PairingMessageKind.Reveal => ReceiveReveal(message),
            PairingMessageKind.Confirmation => ReceiveConfirmation(message),
            PairingMessageKind.Decision => ReceiveDecision(message),
            PairingMessageKind.Completion => ReceiveCompletion(message),
            PairingMessageKind.CompletionAcknowledgement => ReceiveAcknowledgement(message),
            PairingMessageKind.CompletionClose => ReceiveClose(message),
            PairingMessageKind.CompletionCloseAcknowledgement => ReceiveCloseAcknowledgement(message),
            _ => throw new PairingSessionException("Unknown pairing message.")
        };
    }

    /// <summary>Accepts or declines the code shown on a responder.</summary>
    public PairingSessionResult Respond(bool accepted)
    {
        if (role != PairingSessionRole.Responder || peer is null || peerContribution is null)
        {
            throw new PairingSessionException("The responder has no pending code.");
        }

        localAccepted = accepted;
        var decision = PairingEnvelope.Decision(
            localRequest ?? new PairingEnvelope(
                PairingMessageKind.Request,
                requestID,
                peer,
                supportsCompletionClose: true
            ),
            localIdentity,
            accepted,
            senderModel: localModel
        );
        if (!accepted)
        {
            terminal = true;
            return Result([decision], terminal: true);
        }

        return Advance([decision]);
    }

    /// <summary>Confirms or declines the code shown on an initiator.</summary>
    public PairingSessionResult Confirm(bool accepted)
    {
        if (role != PairingSessionRole.Initiator || peer is null || peerContribution is null)
        {
            throw new PairingSessionException("The initiator has no pending code.");
        }

        localAccepted = accepted;
        var decision = PairingEnvelope.Decision(
            localRequest!,
            localIdentity,
            accepted,
            senderModel: localModel
        );
        if (!accepted)
        {
            terminal = true;
            return Result([decision], terminal: true);
        }

        return Advance([decision]);
    }

    private PairingSessionResult ReceiveRequest(PairingEnvelope message)
    {
        if (role != PairingSessionRole.Responder
            || peer is not null
            || message.Sender.Id == localIdentity.Id
            || message.VerificationCommitment is null
            || message.VerificationCommitment.Length != SHA256.HashData([]).Length)
        {
            throw new PairingSessionException("Unexpected pairing request.");
        }

        peer = message.Sender;
        peerCommitment = message.VerificationCommitment;
        var challenge = PairingEnvelope.Challenge(
            message,
            localIdentity,
            PairingVerificationCode.Commitment(
                requestID,
                localIdentity.SigningPublicKey,
                localContribution
            ),
            senderModel: localModel
        );
        return Result([challenge]);
    }

    private PairingSessionResult ReceiveChallenge(PairingEnvelope message)
    {
        if (role != PairingSessionRole.Initiator
            || localRequest is null
            || message.Sender.Id == localIdentity.Id
            || message.VerificationCommitment is null
            || message.VerificationCommitment.Length != SHA256.HashData([]).Length
            || !MatchesPeer(message.Sender))
        {
            throw new PairingSessionException("Unexpected pairing challenge.");
        }

        peerCommitment = message.VerificationCommitment;
        var reveal = PairingEnvelope.Reveal(
            localRequest,
            localIdentity,
            localContribution,
            senderModel: localModel
        );
        return Result([reveal]);
    }

    private PairingSessionResult ReceiveReveal(PairingEnvelope message)
    {
        if (role != PairingSessionRole.Responder
            || peer is null
            || peerCommitment is null
            || message.Sender.Id != peer.Id
            || !PublicKeysEqual(message.Sender, peer)
            || message.VerificationContribution is null
            || !PairingVerificationCode.Verifies(
                peerCommitment,
                requestID,
                peer.SigningPublicKey,
                message.VerificationContribution
            ))
        {
            throw new PairingSessionException("Invalid pairing reveal.");
        }

        peerContribution = message.VerificationContribution;
        var request = new PairingEnvelope(
            PairingMessageKind.Request,
            requestID,
            peer,
            supportsCompletionClose: true
        );
        var confirmation = PairingEnvelope.Confirmation(
            request,
            localIdentity,
            localContribution,
            senderModel: localModel
        );
        return Result(
            [confirmation],
            VerificationCode()
        );
    }

    private PairingSessionResult ReceiveConfirmation(PairingEnvelope message)
    {
        if (role != PairingSessionRole.Initiator
            || localRequest is null
            || peer is null
            || peerCommitment is null
            || message.Sender.Id != peer.Id
            || !PublicKeysEqual(message.Sender, peer)
            || message.VerificationContribution is null
            || !PairingVerificationCode.Verifies(
                peerCommitment,
                requestID,
                peer.SigningPublicKey,
                message.VerificationContribution
            ))
        {
            throw new PairingSessionException("Invalid pairing confirmation.");
        }

        peerContribution = message.VerificationContribution;
        return Result([], VerificationCode());
    }

    private PairingSessionResult ReceiveDecision(PairingEnvelope message)
    {
        RequirePeer(message);
        if (peerContribution is null || message.Accepted is null)
        {
            throw new PairingSessionException("Invalid pairing decision.");
        }

        remoteAccepted = message.Accepted.Value;
        if (!remoteAccepted)
        {
            // A signed rejection is a terminal decision. Do not leave the
            // state machine resumable if a peer keeps the TCP stream open and
            // sends a contradictory acceptance later.
            terminal = true;
            return Result([], terminal: true);
        }

        return Advance([]);
    }

    private PairingSessionResult ReceiveCompletion(PairingEnvelope message)
    {
        RequirePeer(message);
        if (!localAccepted || !remoteAccepted)
        {
            throw new PairingSessionException("Completion arrived before both decisions.");
        }

        remoteCompletionReceived = true;
        return Advance([]);
    }

    private PairingSessionResult ReceiveAcknowledgement(PairingEnvelope message)
    {
        RequirePeer(message);
        if (!localCompletionSent || !remoteCompletionReceived)
        {
            throw new PairingSessionException("Completion acknowledgement is out of order.");
        }

        remoteAcknowledgementReceived = true;
        return Advance([]);
    }

    private PairingSessionResult ReceiveClose(PairingEnvelope message)
    {
        RequirePeer(message);
        if (IsCloser || !HasMutualCompletionProof)
        {
            throw new PairingSessionException(
                "The close barrier arrived before the mutual completion proof."
            );
        }

        closeReceived = true;
        return Advance([]);
    }

    private PairingSessionResult ReceiveCloseAcknowledgement(PairingEnvelope message)
    {
        RequirePeer(message);
        if (!IsCloser || !closeSent || !HasMutualCompletionProof)
        {
            throw new PairingSessionException("Unexpected close acknowledgement.");
        }

        closeAcknowledgementReceived = true;
        return Advance([]);
    }

    private PairingSessionResult Advance(IEnumerable<PairingEnvelope> initialMessages)
    {
        var outbound = new List<PairingEnvelope>(initialMessages);
        var changed = true;
        while (changed)
        {
            changed = false;
            if (localAccepted && remoteAccepted && !localCompletionSent)
            {
                var request = localRequest ?? new PairingEnvelope(
                    PairingMessageKind.Request,
                    requestID,
                    peer!,
                    supportsCompletionClose: true
                );
                outbound.Add(PairingEnvelope.Completion(
                    request,
                    localIdentity,
                    senderModel: localModel
                ));
                localCompletionSent = true;
                changed = true;
            }

            if (localCompletionSent && remoteCompletionReceived
                && !localAcknowledgementSent)
            {
                var request = localRequest ?? new PairingEnvelope(
                    PairingMessageKind.Request,
                    requestID,
                    peer!,
                    supportsCompletionClose: true
                );
                outbound.Add(PairingEnvelope.CompletionAcknowledgement(
                    request,
                    localIdentity,
                    senderModel: localModel
                ));
                localAcknowledgementSent = true;
                changed = true;
            }

            if (localCompletionSent && remoteCompletionReceived
                && localAcknowledgementSent && remoteAcknowledgementReceived
                && IsCloser && !closeSent)
            {
                var request = localRequest ?? new PairingEnvelope(
                    PairingMessageKind.Request,
                    requestID,
                    peer!,
                    supportsCompletionClose: true
                );
                outbound.Add(PairingEnvelope.CompletionClose(
                    request,
                    localIdentity,
                    senderModel: localModel
                ));
                closeSent = true;
                changed = true;
            }

            if (closeReceived && !IsCloser && !closeAcknowledgementSent)
            {
                var request = localRequest ?? new PairingEnvelope(
                    PairingMessageKind.Request,
                    requestID,
                    peer!,
                    supportsCompletionClose: true
                );
                outbound.Add(PairingEnvelope.CompletionCloseAcknowledgement(
                    request,
                    localIdentity,
                    senderModel: localModel
                ));
                closeAcknowledgementSent = true;
                changed = true;
            }
        }

        if (HasMutualCompletionProof && IsCloser && closeSent
            && closeAcknowledgementReceived)
        {
            completed = true;
        }
        else if (HasMutualCompletionProof && !IsCloser && closeReceived
            && closeAcknowledgementSent)
        {
            completed = true;
        }

        return Result(outbound);
    }

    private PairingSessionResult Result(
        IReadOnlyList<PairingEnvelope> outbound,
        string? verificationCode = null,
        bool terminal = false
    ) => new(outbound, verificationCode, completed, terminal);

    private string VerificationCode()
    {
        if (peer is null || peerContribution is null)
        {
            throw new PairingSessionException("The verification code is not ready.");
        }

        return role == PairingSessionRole.Initiator
            ? PairingVerificationCode.Make(
                requestID,
                localIdentity.SigningPublicKey,
                peer.SigningPublicKey,
                localContribution,
                peerContribution
            )
            : PairingVerificationCode.Make(
                requestID,
                peer.SigningPublicKey,
                localIdentity.SigningPublicKey,
                peerContribution,
                localContribution
            );
    }

    private bool IsCloser => peer is not null
        && string.Compare(
            localIdentity.Id.ToString("D"),
            peer.Id.ToString("D"),
            StringComparison.OrdinalIgnoreCase
        ) < 0;

    private bool HasMutualCompletionProof =>
        localAccepted
            && remoteAccepted
            && localCompletionSent
            && remoteCompletionReceived
            && localAcknowledgementSent
            && remoteAcknowledgementReceived;

    private bool MatchesPeer(PeerIdentity candidate)
    {
        if (peer is null)
        {
            peer = candidate;
            return true;
        }

        return peer.Id == candidate.Id && PublicKeysEqual(peer, candidate);
    }

    private void RequirePeer(PairingEnvelope message)
    {
        if (peer is null || message.Sender.Id != peer.Id
            || !PublicKeysEqual(message.Sender, peer))
        {
            throw new PairingSessionException("The pairing peer identity changed.");
        }
    }

    private static bool PublicKeysEqual(PeerIdentity lhs, PeerIdentity rhs)
        => CryptographicOperations.FixedTimeEquals(
            lhs.SigningPublicKey,
            rhs.SigningPublicKey
        );
}

public sealed record PairingSessionResult(
    IReadOnlyList<PairingEnvelope> Outbound,
    string? VerificationCode,
    bool Completed,
    bool Terminal = false
);

internal sealed class SignedPairingEnvelope
{
    [JsonPropertyName("message")]
    public PairingEnvelope Message { get; }

    [JsonPropertyName("signature")]
    public byte[] Signature { get; }

    [JsonPropertyName("senderModel")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? SenderModel { get; }

    [JsonPropertyName("senderModelSignature")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public byte[]? SenderModelSignature { get; }

    [JsonPropertyName("supportsCompletionClose")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public bool? SupportsCompletionClose { get; }

    [JsonPropertyName("completionFeatureSignature")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public byte[]? CompletionFeatureSignature { get; }

    [JsonConstructor]
    public SignedPairingEnvelope(
        PairingEnvelope? message,
        byte[]? signature,
        string? senderModel,
        byte[]? senderModelSignature,
        bool? supportsCompletionClose,
        byte[]? completionFeatureSignature
    )
    {
        Message = message ?? throw new JsonException("The signed pairing message is missing.");
        Signature = signature?.ToArray()
            ?? throw new JsonException("The pairing signature is missing.");
        SenderModel = senderModel;
        SenderModelSignature = senderModelSignature;
        SupportsCompletionClose = supportsCompletionClose;
        CompletionFeatureSignature = completionFeatureSignature;
    }
}

internal sealed record PairingModelExtension(
    [property: JsonPropertyName("kind")] PairingMessageKind Kind,
    [property: JsonPropertyName("requestID")] Guid RequestID,
    [property: JsonPropertyName("senderID")] Guid SenderID,
    [property: JsonPropertyName("model")] string Model
);

internal sealed record PairingFeatureExtension(
    [property: JsonPropertyName("kind")] PairingMessageKind Kind,
    [property: JsonPropertyName("requestID")] Guid RequestID,
    [property: JsonPropertyName("senderID")] Guid SenderID,
    [property: JsonPropertyName("supportsCompletionClose")] bool SupportsCompletionClose
);

internal static class CanonicalJson
{
    public static JsonSerializerOptions Options { get; } = CreateOptions();

    public static byte[] Serialize<T>(T value)
    {
        var raw = JsonSerializer.SerializeToUtf8Bytes(value, Options);
        using var document = JsonDocument.Parse(raw);
        var output = new ArrayBufferWriter<byte>();
        using (var writer = new Utf8JsonWriter(output, new JsonWriterOptions
        {
            Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
            Indented = false
        }))
        {
            WriteSorted(document.RootElement, writer);
        }

        return EscapeSolidusLikeFoundation(output.WrittenSpan);
    }

    private static JsonSerializerOptions CreateOptions()
    {
        var options = new JsonSerializerOptions
        {
            Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
            DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
            PropertyNamingPolicy = null,
            WriteIndented = false
        };
        options.Converters.Add(new UppercaseGuidJsonConverter());
        options.Converters.Add(new PairingMessageKindJsonConverter());
        return options;
    }

    private static void WriteSorted(JsonElement element, Utf8JsonWriter writer)
    {
        switch (element.ValueKind)
        {
            case JsonValueKind.Object:
                writer.WriteStartObject();
                foreach (var property in element.EnumerateObject()
                             .OrderBy(property => property.Name, StringComparer.Ordinal))
                {
                    writer.WritePropertyName(property.Name);
                    WriteSorted(property.Value, writer);
                }

                writer.WriteEndObject();
                break;
            case JsonValueKind.Array:
                writer.WriteStartArray();
                foreach (var item in element.EnumerateArray())
                {
                    WriteSorted(item, writer);
                }

                writer.WriteEndArray();
                break;
            case JsonValueKind.String:
                writer.WriteStringValue(element.GetString());
                break;
            case JsonValueKind.Number:
                writer.WriteRawValue(element.GetRawText(), skipInputValidation: true);
                break;
            case JsonValueKind.True:
                writer.WriteBooleanValue(true);
                break;
            case JsonValueKind.False:
                writer.WriteBooleanValue(false);
                break;
            case JsonValueKind.Null:
                writer.WriteNullValue();
                break;
            default:
                throw new JsonException("Unsupported JSON value.");
        }
    }

    /// Foundation's JSONEncoder escapes a solidus inside strings (for
    /// example, `Mac/Windows` becomes `Mac\/Windows`). System.Text.Json does
    /// not, so apply that one-byte-compatible transformation after the
    /// object keys have been sorted. Foundation also emits supplementary
    /// Unicode scalars as UTF-8, while Utf8JsonWriter emits them as UTF-16
    /// surrogate escapes. Normalize valid surrogate pairs here so a model or
    /// display name containing an emoji has the same signed bytes on both
    /// platforms. No structural JSON solidus exists here; the scanner still
    /// tracks string state to avoid changing future JSON extensions
    /// accidentally.
    private static byte[] EscapeSolidusLikeFoundation(ReadOnlySpan<byte> input)
    {
        var output = new ArrayBufferWriter<byte>(input.Length + 8);
        var inString = false;
        var escaped = false;
        for (var index = 0; index < input.Length; index++)
        {
            var value = input[index];
            if (inString
                && !escaped
                && value == (byte)'\\'
                && TryReadUnicodeEscape(input, index, out var firstCodeUnit)
                && char.IsHighSurrogate((char)firstCodeUnit)
                && TryReadUnicodeEscape(
                    input,
                    index + 6,
                    out var secondCodeUnit
                )
                && char.IsLowSurrogate((char)secondCodeUnit))
            {
                var scalar = char.ConvertToUtf32(
                    (char)firstCodeUnit,
                    (char)secondCodeUnit
                );
                var scalarBytes = Encoding.UTF8.GetBytes(
                    char.ConvertFromUtf32(scalar)
                );
                foreach (var scalarByte in scalarBytes)
                {
                    output.GetSpan(1)[0] = scalarByte;
                    output.Advance(1);
                }

                // Each JSON \uXXXX escape occupies six bytes.
                index += 11;
                escaped = false;
                continue;
            }

            if (inString && value == (byte)'/' && !escaped)
            {
                output.GetSpan(1)[0] = (byte)'\\';
                output.Advance(1);
            }

            output.GetSpan(1)[0] = value;
            output.Advance(1);
            if (value == (byte)'"' && !escaped)
            {
                inString = !inString;
            }

            if (inString && value == (byte)'\\' && !escaped)
            {
                escaped = true;
            }
            else
            {
                escaped = false;
            }
        }

        return output.WrittenSpan.ToArray();
    }

    private static bool TryReadUnicodeEscape(
        ReadOnlySpan<byte> input,
        int index,
        out int codeUnit
    )
    {
        codeUnit = 0;
        if (index < 0 || index + 6 > input.Length
            || input[index] != (byte)'\\'
            || input[index + 1] != (byte)'u')
        {
            return false;
        }

        for (var offset = 2; offset < 6; offset++)
        {
            var nibble = HexValue(input[index + offset]);
            if (nibble < 0)
            {
                codeUnit = 0;
                return false;
            }

            codeUnit = (codeUnit << 4) | nibble;
        }

        return true;
    }

    private static int HexValue(byte value)
    {
        return value switch
        {
            >= (byte)'0' and <= (byte)'9' => value - (byte)'0',
            >= (byte)'a' and <= (byte)'f' => value - (byte)'a' + 10,
            >= (byte)'A' and <= (byte)'F' => value - (byte)'A' + 10,
            _ => -1
        };
    }
}

public enum LengthPrefixedFrameErrorCode
{
    InvalidLength,
    TooManyMessages
}

public sealed class LengthPrefixedFrameException : Exception
{
    public LengthPrefixedFrameErrorCode Code { get; }

    public LengthPrefixedFrameException(
        LengthPrefixedFrameErrorCode code,
        string message
    ) : base(message) => Code = code;
}

public static class LengthPrefixedFrameCodec
{
    public static byte[] Encode(byte[] payload, int maximumPayloadLength)
    {
        if (payload.Length == 0 || payload.Length > maximumPayloadLength
            || maximumPayloadLength <= 0)
        {
            throw new LengthPrefixedFrameException(
                LengthPrefixedFrameErrorCode.InvalidLength,
                "The frame payload length is invalid."
            );
        }

        var frame = new byte[payload.Length + 4];
        frame[0] = (byte)(payload.Length >> 24);
        frame[1] = (byte)(payload.Length >> 16);
        frame[2] = (byte)(payload.Length >> 8);
        frame[3] = (byte)payload.Length;
        Buffer.BlockCopy(payload, 0, frame, 4, payload.Length);
        return frame;
    }

    public static IReadOnlyList<byte[]> DecodeAvailablePayloads(
        List<byte> buffer,
        int maximumPayloadLength,
        int? maximumFrameCount = null
    )
    {
        if (maximumPayloadLength <= 0
            || maximumFrameCount is <= 0)
        {
            throw new LengthPrefixedFrameException(
                LengthPrefixedFrameErrorCode.InvalidLength,
                "The frame decoder limits are invalid."
            );
        }

        var payloads = new List<byte[]>();
        while (buffer.Count >= 4)
        {
            if (maximumFrameCount.HasValue
                && payloads.Count >= maximumFrameCount.Value)
            {
                // A TCP read may end after the next frame's four-byte header.
                // Keep that incomplete frame for the next read; only reject a
                // delivery once another complete frame is actually present.
                var pendingLength = (buffer[0] << 24)
                    | (buffer[1] << 16)
                    | (buffer[2] << 8)
                    | buffer[3];
                if (pendingLength <= 0 || pendingLength > maximumPayloadLength)
                {
                    throw new LengthPrefixedFrameException(
                        LengthPrefixedFrameErrorCode.InvalidLength,
                        "The frame payload length is invalid."
                    );
                }

                if (buffer.Count < pendingLength + 4)
                {
                    break;
                }

                throw new LengthPrefixedFrameException(
                    LengthPrefixedFrameErrorCode.TooManyMessages,
                    "Too many frames were received in one delivery."
                );
            }

            var length = (buffer[0] << 24)
                | (buffer[1] << 16)
                | (buffer[2] << 8)
                | buffer[3];
            if (length <= 0 || length > maximumPayloadLength)
            {
                throw new LengthPrefixedFrameException(
                    LengthPrefixedFrameErrorCode.InvalidLength,
                    "The frame payload length is invalid."
                );
            }

            var frameLength = length + 4;
            if (buffer.Count < frameLength)
            {
                break;
            }

            payloads.Add(buffer.GetRange(4, length).ToArray());
            buffer.RemoveRange(0, frameLength);
        }

        return payloads;
    }

    public static bool HasCompleteFrame(
        ReadOnlySpan<byte> buffer,
        int maximumPayloadLength
    )
    {
        if (buffer.Length < 4 || maximumPayloadLength <= 0)
        {
            return false;
        }

        var length = (buffer[0] << 24)
            | (buffer[1] << 16)
            | (buffer[2] << 8)
            | buffer[3];
        return length > 0
            && length <= maximumPayloadLength
            && buffer.Length >= length + 4;
    }
}
