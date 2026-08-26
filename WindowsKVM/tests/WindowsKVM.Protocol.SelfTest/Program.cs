using System.Security.Cryptography;
using System.Text;
using WindowsKVM.Protocol;

namespace WindowsKVM.Protocol.SelfTest;

internal static class Program
{
    private static int Main()
    {
        try
        {
            TestPairingRoundTripAndFragmentation();
            TestMalformedEnvelopeIsRejectedAsInvalidFrame();
            TestTamperingIsRejected();
            TestCapabilityDowngradeIsRejected();
            TestLengthPrefixLimits();
            TestFrameLimitPreservesPartialFrame();
            TestVerificationCodeIsDeterministic();
            TestFoundationJsonEscaping();
            TestDefaultInitiatorGetsFreshRequestID();
            TestDisplayNameRejectsBidiFormat();
            TestCloseBarrierRequiresMutualCompletionProof();
            TestCompletePairingStateMachine();
            TestRejectedDecisionIsTerminal();
            TestSecureSessionHandshakeRoundTrip();
            TestSecureSessionChannelEncryptsBothDirections();
            TestSecureSessionRejectsTamperedHandshake();
            TestSecureSessionDrainsCoalescedFrames();
            Console.WriteLine("WindowsKVM protocol self-test: PASS");
            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"WindowsKVM protocol self-test: FAIL\n{ex}");
            return 1;
        }
    }

    private static void TestPairingRoundTripAndFragmentation()
    {
        using var sender = DeviceCredentials.Create("Windows ARM64");
        var requestID = Guid.Parse("00112233-4455-6677-8899-AABBCCDDEEFF");
        var contribution = Enumerable.Range(0, PairingVerificationCode.ContributionLength)
            .Select(index => (byte)index)
            .ToArray();
        var commitment = PairingVerificationCode.Commitment(
            requestID,
            sender.Identity.SigningPublicKey,
            contribution
        );
        var message = PairingEnvelope.Request(
            sender.Identity,
            requestID,
            commitment,
            senderModel: "Windows ARM64"
        );
        var frame = PairingWireCodec.Encode(message, sender.PrivateKey);
        Assert(frame.Length > 4, "encoded pairing frame should contain a payload");
        Assert(PairingWireCodec.HasCompleteFrame(frame), "complete frame was not detected");
        var payload = Encoding.UTF8.GetString(frame, 4, frame.Length - 4);
        Assert(
            !payload.Contains("\"ServiceName\"", StringComparison.Ordinal),
            "computed ServiceName must not change the macOS wire signature"
        );

        var buffer = new List<byte>();
        var decoded = new List<PairingEnvelope>();
        foreach (var byteValue in frame)
        {
            buffer.Add(byteValue);
            if (!PairingWireCodec.HasCompleteFrame(buffer.ToArray()))
            {
                continue;
            }

            decoded.AddRange(PairingWireCodec.DecodeAvailableFrames(buffer));
        }

        Assert(decoded.Count == 1, "one pairing message should decode");
        var result = decoded[0];
        Assert(result.Kind == PairingMessageKind.Request, "message kind changed");
        Assert(result.RequestID == requestID, "request ID changed");
        Assert(result.Sender.Id == sender.Identity.Id, "sender ID changed");
        Assert(result.SenderModel == "Windows ARM64", "signed model changed");
        Assert(
            CryptographicOperations.FixedTimeEquals(
                result.VerificationCommitment!,
                commitment
            ),
            "commitment changed"
        );
        Assert(
            PairingVerificationCode.Verifies(
                result.VerificationCommitment!,
                requestID,
                result.Sender.SigningPublicKey,
                contribution
            ),
            "commitment should verify"
        );
    }

    private static void TestTamperingIsRejected()
    {
        using var sender = DeviceCredentials.Create("Windows x64");
        var message = PairingEnvelope.Request(
            sender.Identity,
            Guid.NewGuid(),
            PairingVerificationCode.MakeContribution(),
            senderModel: "Windows x64"
        );
        var frame = PairingWireCodec.Encode(message, sender.PrivateKey);
        var payload = Encoding.UTF8.GetString(frame, 4, frame.Length - 4);
        const string signaturePrefix = "\"signature\":\"";
        var signatureStart = payload.IndexOf(signaturePrefix, StringComparison.Ordinal)
            + signaturePrefix.Length;
        Assert(signatureStart > signaturePrefix.Length, "signed frame has no signature");
        var signatureBytes = Encoding.UTF8.GetBytes(payload);
        signatureBytes[signatureStart] = signatureBytes[signatureStart] == (byte)'A'
            ? (byte)'B'
            : (byte)'A';
        Buffer.BlockCopy(signatureBytes, 0, frame, 4, signatureBytes.Length);
        var buffer = frame.ToList();
        AssertThrows(
            () => PairingWireCodec.DecodeAvailableFrames(buffer),
            PairingWireErrorCode.InvalidSignature,
            "tampered signature/payload must be rejected"
        );
    }

    private static void TestMalformedEnvelopeIsRejectedAsInvalidFrame()
    {
        var frame = LengthPrefixedFrameCodec.Encode(
            Encoding.UTF8.GetBytes("{}"),
            PairingWireCodec.MaximumFramePayloadLength
        );
        AssertThrows(
            () => PairingWireCodec.DecodeAvailableFrames(frame.ToList()),
            PairingWireErrorCode.InvalidFrame,
            "a signed envelope without required fields must be rejected as an invalid frame"
        );
    }

    private static void TestCapabilityDowngradeIsRejected()
    {
        using var sender = DeviceCredentials.Create("Windows x64");
        var message = new PairingEnvelope(
            PairingMessageKind.Request,
            Guid.NewGuid(),
            sender.Identity,
            verificationCommitment: new byte[] { 1 },
            supportsCompletionClose: false
        );
        AssertThrows(
            () => PairingWireCodec.Encode(message, sender.PrivateKey),
            PairingWireErrorCode.UnsupportedCapability,
            "a capability downgrade must not be emitted"
        );
    }

    private static void TestLengthPrefixLimits()
    {
        var buffer = new List<byte> { 0, 1, 0, 0 };
        AssertThrowsFrame(
            () => LengthPrefixedFrameCodec.DecodeAvailablePayloads(buffer, 64),
            LengthPrefixedFrameErrorCode.InvalidLength,
            "invalid frame length must be rejected"
        );

        var payload = Encoding.UTF8.GetBytes("ok");
        var first = LengthPrefixedFrameCodec.Encode(payload, 64);
        var second = LengthPrefixedFrameCodec.Encode(payload, 64);
        var twoFrames = first.Concat(second).ToList();
        var decoded = LengthPrefixedFrameCodec.DecodeAvailablePayloads(twoFrames, 64, 2);
        Assert(decoded.Count == 2 && twoFrames.Count == 0, "two frames should decode");
    }

    private static void TestFrameLimitPreservesPartialFrame()
    {
        var buffer = new List<byte>();
        for (var index = 0; index < PairingWireCodec.MaximumFramesPerDecode; index++)
        {
            buffer.AddRange(LengthPrefixedFrameCodec.Encode(
                [(byte)index],
                PairingWireCodec.MaximumFramePayloadLength
            ));
        }

        var nextFrame = LengthPrefixedFrameCodec.Encode(
            [0xEE, 0xFF],
            PairingWireCodec.MaximumFramePayloadLength
        );
        buffer.AddRange(nextFrame[..5]);

        var decoded = LengthPrefixedFrameCodec.DecodeAvailablePayloads(
            buffer,
            PairingWireCodec.MaximumFramePayloadLength,
            PairingWireCodec.MaximumFramesPerDecode
        );
        Assert(
            decoded.Count == PairingWireCodec.MaximumFramesPerDecode,
            "the frame limit should decode the complete first batch"
        );
        Assert(
            buffer.SequenceEqual(nextFrame[..5]),
            "an incomplete next frame must remain buffered"
        );

        var completeBatch = new List<byte>();
        for (var index = 0; index <= PairingWireCodec.MaximumFramesPerDecode; index++)
        {
            completeBatch.AddRange(LengthPrefixedFrameCodec.Encode(
                [(byte)index],
                PairingWireCodec.MaximumFramePayloadLength
            ));
        }

        AssertThrowsFrame(
            () => LengthPrefixedFrameCodec.DecodeAvailablePayloads(
                completeBatch,
                PairingWireCodec.MaximumFramePayloadLength,
                PairingWireCodec.MaximumFramesPerDecode
            ),
            LengthPrefixedFrameErrorCode.TooManyMessages,
            "a complete frame beyond the per-delivery limit must be rejected"
        );
    }

    private static void TestVerificationCodeIsDeterministic()
    {
        var requestID = Guid.Parse("00112233-4455-6677-8899-AABBCCDDEEFF");
        var initiatorKey = Enumerable.Range(1, 65).Select(index => (byte)index).ToArray();
        var responderKey = Enumerable.Range(66, 65).Select(index => (byte)index).ToArray();
        var initiatorContribution = Enumerable.Repeat((byte)0x11, 32).ToArray();
        var responderContribution = Enumerable.Repeat((byte)0x22, 32).ToArray();
        var code = PairingVerificationCode.Make(
            requestID,
            initiatorKey,
            responderKey,
            initiatorContribution,
            responderContribution
        );
        Assert(code.Length == 6 && code.All(char.IsDigit), "verification code must be six digits");
        Assert(
            code == PairingVerificationCode.Make(
                requestID,
                initiatorKey,
                responderKey,
                initiatorContribution,
                responderContribution
            ),
            "verification code must be deterministic"
        );
    }

    private static void TestSecureSessionHandshakeRoundTrip()
    {
        using var fixture = SecureFixture.Create();
        var frame = SecureSessionWireCodec.Encode(
            fixture.InitiatorHandshake,
            fixture.InitiatorSigningKey
        );
        var buffer = frame.ToList();
        var messages = SecureSessionWireCodec.DecodeAvailableFrames(buffer);
        Assert(messages.Count == 1, "one secure handshake should decode");
        Assert(
            messages[0].Kind == SecureSessionWireMessageKind.Handshake,
            "secure handshake kind changed"
        );
        Assert(
            messages[0].Handshake!.Sender.Id == fixture.InitiatorHandshake.Sender.Id,
            "secure handshake sender changed"
        );
        Assert(buffer.Count == 0, "secure handshake frame was not consumed");
    }

    private static void TestSecureSessionChannelEncryptsBothDirections()
    {
        using var fixture = SecureFixture.Create();
        using var initiatorChannel = new SecureSessionChannel(
            SecureSessionRole.Initiator,
            fixture.InitiatorEphemeralKey,
            fixture.InitiatorHandshake,
            fixture.ResponderHandshake
        );
        using var responderChannel = new SecureSessionChannel(
            SecureSessionRole.Responder,
            fixture.ResponderEphemeralKey,
            fixture.InitiatorHandshake,
            fixture.ResponderHandshake
        );

        var packet = initiatorChannel.Seal("connect"u8);
        Assert(
            Encoding.UTF8.GetString(responderChannel.Open(packet)) == "connect",
            "responder could not decrypt the initiator packet"
        );
        AssertThrowsSecure(
            () => responderChannel.Open(packet),
            SecureSessionWireErrorCode.UnexpectedMessage,
            "secure packet replay should be rejected"
        );

        var response = responderChannel.Seal("ready"u8);
        Assert(
            Encoding.UTF8.GetString(initiatorChannel.Open(response)) == "ready",
            "initiator could not decrypt the responder packet"
        );
    }

    private static void TestSecureSessionRejectsTamperedHandshake()
    {
        using var fixture = SecureFixture.Create();
        var frame = SecureSessionWireCodec.Encode(
            fixture.InitiatorHandshake,
            fixture.InitiatorSigningKey
        );
        var payload = Encoding.UTF8.GetString(frame, 4, frame.Length - 4);
        const string signaturePrefix = "\"signature\":\"";
        var signatureStart = payload.IndexOf(signaturePrefix, StringComparison.Ordinal)
            + signaturePrefix.Length;
        Assert(signatureStart > signaturePrefix.Length, "secure signature is missing");
        var bytes = Encoding.UTF8.GetBytes(payload);
        bytes[signatureStart] = bytes[signatureStart] == (byte)'A'
            ? (byte)'B'
            : (byte)'A';
        Buffer.BlockCopy(bytes, 0, frame, 4, bytes.Length);
        AssertThrowsSecure(
            () => SecureSessionWireCodec.DecodeAvailableFrames(frame.ToList()),
            SecureSessionWireErrorCode.InvalidSignature,
            "tampered secure handshake should be rejected"
        );
    }

    private static void TestSecureSessionDrainsCoalescedFrames()
    {
        var buffer = new List<byte>();
        for (var index = 0; index < SecureSessionWireCodec.MaximumFramesPerDecode + 1; index++)
        {
            buffer.AddRange(SecureSessionWireCodec.Encode(
                new SecurePacket(Guid.NewGuid(), (ulong)index, [0x01])
            ));
        }

        var firstBatch = SecureSessionWireCodec.DecodeAvailableFrames(buffer);
        Assert(
            firstBatch.Count == SecureSessionWireCodec.MaximumFramesPerDecode,
            "secure decoder should return one bounded batch"
        );
        Assert(
            SecureSessionWireCodec.HasCompleteFrame(buffer),
            "secure decoder should retain a coalesced complete frame"
        );

        var secondBatch = SecureSessionWireCodec.DecodeAvailableFrames(buffer);
        Assert(secondBatch.Count == 1, "secure decoder should drain the retained frame");
        Assert(buffer.Count == 0, "all coalesced secure frames should be consumed");
    }

    private static void AssertThrowsSecure(
        Action action,
        SecureSessionWireErrorCode expected,
        string message
    )
    {
        try
        {
            action();
        }
        catch (SecureSessionWireException ex) when (ex.Code == expected)
        {
            return;
        }
        catch (Exception ex)
        {
            throw new InvalidOperationException(
                $"{message}; got {ex.GetType().Name}: {ex.Message}",
                ex
            );
        }

        throw new InvalidOperationException(message);
    }

    private static void TestFoundationJsonEscaping()
    {
        using var sender = DeviceCredentials.Create("Windows/ARM64");
        var message = PairingEnvelope.Request(
            sender.Identity,
            Guid.NewGuid(),
            new byte[32],
            senderModel: "Windows/ARM64 😀"
        );
        var frame = PairingWireCodec.Encode(message, sender.PrivateKey);
        var payload = Encoding.UTF8.GetString(frame, 4, frame.Length - 4);
        Assert(
            payload.Contains("Windows\\/ARM64 😀", StringComparison.Ordinal),
            "Foundation-compatible JSON must escape solidus characters"
        );
        Assert(
            !payload.Contains("\\uD83D\\uDE00", StringComparison.Ordinal),
            "Foundation-compatible JSON must preserve supplementary Unicode"
        );
    }

    private static void TestCompletePairingStateMachine()
    {
        using var initiatorCredentials = DeviceCredentials.Create("M5 Pro");
        using var responderCredentials = DeviceCredentials.Create("Windows ARM64");
        var initiator = new PairingSession(
            PairingSessionRole.Initiator,
            initiatorCredentials.Identity,
            initiatorCredentials.PrivateKey,
            expectedPeer: responderCredentials.Identity,
            localModel: "M5 Pro"
        );
        var responder = new PairingSession(
            PairingSessionRole.Responder,
            responderCredentials.Identity,
            responderCredentials.PrivateKey,
            localModel: "Windows ARM64"
        );

        var requestResult = initiator.Start();
        Assert(
            requestResult.Outbound.Single().SenderModel == "M5 Pro",
            "initiator model was not signed into the request"
        );
        var challengeResult = responder.Receive(requestResult.Outbound.Single());
        Assert(
            challengeResult.Outbound.Single().SenderModel == "Windows ARM64",
            "responder model was not signed into the challenge"
        );
        var revealResult = initiator.Receive(challengeResult.Outbound.Single());
        var confirmationResult = responder.Receive(revealResult.Outbound.Single());
        var initiatorCodeResult = initiator.Receive(confirmationResult.Outbound.Single());
        Assert(
            confirmationResult.VerificationCode == initiatorCodeResult.VerificationCode,
            "both peers must calculate the same verification code"
        );

        Pump(responder, initiator, responder, responder.Respond(accepted: true));
        Pump(initiator, initiator, responder, initiator.Confirm(accepted: true));
        Assert(initiator.IsCompleted, "initiator did not cross the close barrier");
        Assert(responder.IsCompleted, "responder did not cross the close barrier");
    }

    private static void TestRejectedDecisionIsTerminal()
    {
        using var initiatorCredentials = DeviceCredentials.Create("Mac");
        using var responderCredentials = DeviceCredentials.Create("Windows");
        var initiator = new PairingSession(
            PairingSessionRole.Initiator,
            initiatorCredentials.Identity,
            initiatorCredentials.PrivateKey,
            expectedPeer: responderCredentials.Identity
        );
        var responder = new PairingSession(
            PairingSessionRole.Responder,
            responderCredentials.Identity,
            responderCredentials.PrivateKey
        );

        var request = initiator.Start().Outbound.Single();
        var challenge = responder.Receive(request).Outbound.Single();
        var reveal = initiator.Receive(challenge).Outbound.Single();
        var confirmation = responder.Receive(reveal).Outbound.Single();
        _ = initiator.Receive(confirmation);

        var responderDecision = responder.Respond(accepted: false);
        Assert(responderDecision.Terminal, "a local rejection must be terminal");
        var initiatorDecision = initiator.Receive(responderDecision.Outbound.Single());
        Assert(initiatorDecision.Terminal, "a peer rejection must be terminal");
        AssertThrowsSession(
            () => initiator.Receive(
                PairingEnvelope.Decision(
                    request,
                    responderCredentials.Identity,
                    accepted: true
                )
            ),
            "a rejected pairing must not resume after a contradictory acceptance"
        );
    }

    private static void TestDefaultInitiatorGetsFreshRequestID()
    {
        using var credentials = DeviceCredentials.Create("Windows");
        using var peerKey = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var parameters = peerKey.ExportParameters(false);
        var peer = new PeerIdentity(
            Guid.NewGuid(),
            "Mac",
            [0x04, .. parameters.Q.X!, .. parameters.Q.Y!]
        );
        var first = new PairingSession(
            PairingSessionRole.Initiator,
            credentials.Identity,
            credentials.PrivateKey,
            expectedPeer: peer
        );
        var second = new PairingSession(
            PairingSessionRole.Initiator,
            credentials.Identity,
            credentials.PrivateKey,
            expectedPeer: peer
        );
        Assert(first.RequestID != Guid.Empty, "default initiator request ID is empty");
        Assert(first.RequestID != second.RequestID, "default initiator request IDs collided");
    }

    private static void TestDisplayNameRejectsBidiFormat()
    {
        Assert(
            !PeerIdentity.IsValidDisplayName("Mac\u202Eevil"),
            "bidi format controls must not be accepted in identity names"
        );
        Assert(
            PeerIdentity.IsValidDisplayName("Mac\uFE0F"),
            "variation selectors should remain compatible with macOS validation"
        );
    }

    private static void TestCloseBarrierRequiresMutualCompletionProof()
    {
        using var first = DeviceCredentials.Create("First");
        using var second = DeviceCredentials.Create("Second");
        var initiatorCredentials = string.Compare(
            first.Identity.Id.ToString("D"),
            second.Identity.Id.ToString("D"),
            StringComparison.OrdinalIgnoreCase
        ) < 0 ? first : second;
        var responderCredentials = ReferenceEquals(initiatorCredentials, first)
            ? second
            : first;
        var initiator = new PairingSession(
            PairingSessionRole.Initiator,
            initiatorCredentials.Identity,
            initiatorCredentials.PrivateKey
        );
        var responder = new PairingSession(
            PairingSessionRole.Responder,
            responderCredentials.Identity,
            responderCredentials.PrivateKey
        );

        var requestResult = initiator.Start();
        var request = requestResult.Outbound.Single();
        var challengeResult = responder.Receive(request);
        var revealResult = initiator.Receive(challengeResult.Outbound.Single());
        var confirmationResult = responder.Receive(revealResult.Outbound.Single());
        _ = initiator.Receive(confirmationResult.Outbound.Single());

        var forgedClose = PairingEnvelope.CompletionClose(
            request,
            initiatorCredentials.Identity
        );
        AssertThrowsSession(
            () => responder.Receive(forgedClose),
            "a close barrier must not complete before both decisions and acknowledgements"
        );
        Assert(!responder.IsCompleted, "forged close completed the responder");
    }

    private static void Pump(
        PairingSession source,
        PairingSession initiator,
        PairingSession responder,
        PairingSessionResult result
    )
    {
        var queue = new Queue<(PairingSession Sender, PairingSessionResult Result)>();
        queue.Enqueue((source, result));
        while (queue.Count > 0)
        {
            var (sender, current) = queue.Dequeue();
            var receiver = ReferenceEquals(sender, initiator) ? responder : initiator;
            foreach (var message in current.Outbound)
            {
                var next = receiver.Receive(message);
                if (next.Outbound.Count > 0)
                {
                    queue.Enqueue((receiver, next));
                }
            }
        }
    }

    private static void AssertThrows(
        Action action,
        PairingWireErrorCode expected,
        string message
    )
    {
        try
        {
            action();
        }
        catch (PairingWireException ex) when (ex.Code == expected)
        {
            return;
        }

        throw new InvalidOperationException(message);
    }

    private static void AssertThrowsFrame(
        Action action,
        LengthPrefixedFrameErrorCode expected,
        string message
    )
    {
        try
        {
            action();
        }
        catch (LengthPrefixedFrameException ex) when (ex.Code == expected)
        {
            return;
        }

        throw new InvalidOperationException(message);
    }

    private static void AssertThrowsSession(Action action, string message)
    {
        try
        {
            action();
        }
        catch (PairingSessionException)
        {
            return;
        }

        throw new InvalidOperationException(message);
    }

    private static void Assert(bool condition, string message)
    {
        if (!condition)
        {
            throw new InvalidOperationException(message);
        }
    }

    private sealed class SecureFixture : IDisposable
    {
        public ECDsa InitiatorSigningKey { get; }
        public ECDsa ResponderSigningKey { get; }
        public ECDiffieHellman InitiatorEphemeralKey { get; }
        public ECDiffieHellman ResponderEphemeralKey { get; }
        public SecureSessionHandshake InitiatorHandshake { get; }
        public SecureSessionHandshake ResponderHandshake { get; }

        private SecureFixture(
            ECDsa initiatorSigningKey,
            ECDsa responderSigningKey,
            ECDiffieHellman initiatorEphemeralKey,
            ECDiffieHellman responderEphemeralKey,
            SecureSessionHandshake initiatorHandshake,
            SecureSessionHandshake responderHandshake
        )
        {
            InitiatorSigningKey = initiatorSigningKey;
            ResponderSigningKey = responderSigningKey;
            InitiatorEphemeralKey = initiatorEphemeralKey;
            ResponderEphemeralKey = responderEphemeralKey;
            InitiatorHandshake = initiatorHandshake;
            ResponderHandshake = responderHandshake;
        }

        public static SecureFixture Create()
        {
            var initiatorSigningKey = ECDsa.Create(ECCurve.NamedCurves.nistP256);
            var responderSigningKey = ECDsa.Create(ECCurve.NamedCurves.nistP256);
            var initiatorEphemeralKey = ECDiffieHellman.Create(
                ECCurve.NamedCurves.nistP256
            );
            var responderEphemeralKey = ECDiffieHellman.Create(
                ECCurve.NamedCurves.nistP256
            );
            var initiator = new PeerIdentity(
                Guid.NewGuid(),
                "Windows Initiator",
                PairingCryptoAccess.ToX963(
                    initiatorSigningKey.ExportParameters(false).Q
                )
            );
            var responder = new PeerIdentity(
                Guid.NewGuid(),
                "Windows Responder",
                PairingCryptoAccess.ToX963(
                    responderSigningKey.ExportParameters(false).Q
                )
            );
            var sessionID = Guid.NewGuid();
            return new SecureFixture(
                initiatorSigningKey,
                responderSigningKey,
                initiatorEphemeralKey,
                responderEphemeralKey,
                SecureSessionHandshake.Create(
                    sessionID,
                    SecureSessionRole.Initiator,
                    initiator,
                    "Windows x64",
                    initiatorEphemeralKey
                ),
                SecureSessionHandshake.Create(
                    sessionID,
                    SecureSessionRole.Responder,
                    responder,
                    "Windows ARM64",
                    responderEphemeralKey
                )
            );
        }

        public void Dispose()
        {
            InitiatorSigningKey.Dispose();
            ResponderSigningKey.Dispose();
            InitiatorEphemeralKey.Dispose();
            ResponderEphemeralKey.Dispose();
        }
    }
}

internal static class PairingCryptoAccess
{
    public static byte[] ToX963(ECPoint point)
    {
        if (point.X is null || point.Y is null)
        {
            throw new CryptographicException("The P-256 public point is missing.");
        }

        return [0x04, .. point.X, .. point.Y];
    }
}
