using System.Buffers.Binary;
using System.Text;
using System.Net;
using WindowsKVM.Protocol;

namespace WindowsKVM.Desktop.SelfTest;

internal static class WindowsReviewRegressionTests
{
    public static void Run()
    {
        TestLogicalTextAndShortcuts();
        TestUnicodeModifierBookkeeping();
        TestOwnedMdnsQuestions();
        TestReadinessAndTrayRecovery();
    }

    private static void TestLogicalTextAndShortcuts()
    {
        var events = new List<WindowsInputEvent>();
        var layout = new IntPtr(0x407);
        var scans = 0;
        using var sink = new WindowsInputSink(
            inputs => { events.AddRange(inputs); return (uint)inputs.Count; },
            _ => 1920,
            getTargetKeyboardLayout: () => layout,
            scanCharacter: (character, targetLayout) =>
            {
                Check(targetLayout == layout, "shortcut mapping must use foreground HKL");
                scans++;
                return character == 'y' ? (short)0x59 : (short)-1;
            }
        );
        sink.Begin();
        // German Mac code 6 types y, not the ANSI table's z.
        sink.Receive(new RemoteInputEvent(RemoteInputKind.KeyDown, keyCode: 6, character: "y"));
        Check(events[^1].VirtualKey == 0 && events[^1].ScanCode == 'y'
            && events[^1].Flags == 4, "validated logical text must win over ANSI physical VK");
        layout = new IntPtr(0x409);
        sink.Receive(new RemoteInputEvent(RemoteInputKind.KeyDown, keyCode: 6, character: "z"));
        sink.Receive(new RemoteInputEvent(RemoteInputKind.KeyUp, keyCode: 6));
        Check(events[^2].ScanCode == 'y' && events[^1].ScanCode == 'y'
            && events[^1].Flags == 6, "text repeats and release must reuse the initial mapping");

        events.Clear();
        sink.Receive(new RemoteInputEvent(RemoteInputKind.FlagsChanged, keyCode: 59, isPressed: true));
        sink.Receive(new RemoteInputEvent(RemoteInputKind.FlagsChanged, keyCode: 56, isPressed: true));
        sink.Receive(new RemoteInputEvent(RemoteInputKind.KeyDown, keyCode: 6,
            character: "y", modifierFlags: (1UL << 18) | (1UL << 17)));
        Check(events[^1].VirtualKey == 0x59 && events[^1].Flags == 0
            && events.Count == 3 && scans == 1,
            "Ctrl/Shift shortcut must remap its logical VK without changing modifiers");
        layout = new IntPtr(0x407);
        sink.Receive(new RemoteInputEvent(RemoteInputKind.KeyDown, keyCode: 6,
            character: "z", modifierFlags: 1UL << 18));
        sink.Receive(new RemoteInputEvent(RemoteInputKind.KeyUp, keyCode: 6));
        Check(events[^2].VirtualKey == 0x59 && events[^1].VirtualKey == 0x59
            && events[^1].Flags == 2 && scans == 1,
            "held shortcut must survive a target layout/character change until release");
        sink.Receive(new RemoteInputEvent(RemoteInputKind.KeyDown, keyCode: 6,
            character: "é", modifierFlags: 1UL << 18));
        Check(events[^1].VirtualKey == 0x5A && (events[^1].Flags & 4) == 0,
            "unrepresentable shortcuts must fall back to physical VK, never Unicode text");
        sink.Receive(new RemoteInputEvent(RemoteInputKind.KeyUp, keyCode: 6));
        sink.End();
        Check(events.Any(input => input.VirtualKey == 0xA2 && (input.Flags & 2) != 0),
            "teardown must still release held shortcut modifiers");

        events.Clear();
        using var unavailable = new WindowsInputSink(
            inputs => { events.AddRange(inputs); return (uint)inputs.Count; }, _ => 1920,
            getTargetKeyboardLayout: () => IntPtr.Zero,
            scanCharacter: (_, _) => throw new Exception("no HKL must not be scanned"));
        unavailable.Begin();
        unavailable.Receive(new RemoteInputEvent(RemoteInputKind.KeyDown,
            keyCode: 6, character: "y", modifierFlags: 1UL << 20));
        Check(events[^1].VirtualKey == 0x5A,
            "unknown target layout must keep a safe physical shortcut fallback");
        unavailable.Receive(new RemoteInputEvent(RemoteInputKind.KeyUp, keyCode: 6));
        unavailable.Receive(new RemoteInputEvent(RemoteInputKind.KeyDown, keyCode: 6));
        Check(events[^1].VirtualKey == 0x5A, "legacy messages without a character remain physical");
        unavailable.Receive(new RemoteInputEvent(RemoteInputKind.KeyUp, keyCode: 6));
        unavailable.Receive(new RemoteInputEvent(RemoteInputKind.KeyDown,
            keyCode: 123, character: "y"));
        Check(events[^1].VirtualKey == 0x25 && (events[^1].Flags & 1) != 0,
            "navigation must retain extended virtual-key semantics");

        events.Clear();
        using var invalidNativeMapping = new WindowsInputSink(
            inputs => { events.AddRange(inputs); return (uint)inputs.Count; }, _ => 1920,
            getTargetKeyboardLayout: () => new IntPtr(1),
            scanCharacter: (_, _) => 0x00FF);
        invalidNativeMapping.Begin();
        invalidNativeMapping.Receive(new RemoteInputEvent(RemoteInputKind.KeyDown,
            keyCode: 6, character: "y", modifierFlags: 1UL << 18));
        Check(events[^1].VirtualKey == 0x5A,
            "invalid native VK outside Win32 range must use physical shortcut fallback");
    }

    private static void TestUnicodeModifierBookkeeping()
    {
        var batches = new List<WindowsInputEvent[]>();
        var failNext = false;
        using var sink = new WindowsInputSink(
            inputs =>
            {
                batches.Add(inputs.ToArray());
                if (failNext) { failNext = false; return 1; }
                return (uint)inputs.Count;
            }, _ => 1920);
        sink.Begin();
        sink.Receive(new RemoteInputEvent(RemoteInputKind.FlagsChanged, keyCode: 56, isPressed: true));
        sink.Receive(new RemoteInputEvent(RemoteInputKind.FlagsChanged, keyCode: 58, isPressed: true));
        sink.Receive(new RemoteInputEvent(RemoteInputKind.KeyDown, keyCode: 14,
            character: "é", modifierFlags: (1UL << 17) | (1UL << 19)));
        var textBatch = batches[^1];
        Check(textBatch.Length == 5 && textBatch[0].Flags == 2
            && textBatch[1].Flags == 3 && textBatch[2].ScanCode == 'é'
            && textBatch[3].VirtualKey == 0xA0 && textBatch[3].Flags == 0
            && textBatch[4].VirtualKey == 0xA4 && textBatch[4].Flags == 1,
            "text must temporarily neutralize and restore only held remote Shift/Option");
        sink.Receive(new RemoteInputEvent(RemoteInputKind.FlagsChanged, keyCode: 56, isPressed: false));
        sink.Receive(new RemoteInputEvent(RemoteInputKind.FlagsChanged, keyCode: 58, isPressed: false));
        sink.Receive(new RemoteInputEvent(RemoteInputKind.KeyDown, keyCode: 14, character: "e"));
        Check(batches[^1].Length == 1 && batches[^1][0].ScanCode == 'é',
            "repeat must not resurrect a modifier released after the first text down");
        sink.Receive(new RemoteInputEvent(RemoteInputKind.KeyUp, keyCode: 14));

        sink.Receive(new RemoteInputEvent(RemoteInputKind.FlagsChanged, keyCode: 58, isPressed: true));
        failNext = true;
        var failed = false;
        try
        {
            sink.Receive(new RemoteInputEvent(RemoteInputKind.KeyDown,
                keyCode: 6, character: "y", modifierFlags: 1UL << 19));
        }
        catch (WindowsInputException) { failed = true; }
        Check(failed, "partial modifier/text batch must surface injection failure");
        sink.End();
        Check(batches[^1].Any(input => input.VirtualKey == 0xA4 && (input.Flags & 2) != 0)
            && batches[^1].Any(input => input.ScanCode == 'y' && input.Flags == 6),
            "partial text injection must retain both modifier and text release bookkeeping");
    }

    private static void TestOwnedMdnsQuestions()
    {
        const string type = "_mackvm._tcp.local";
        const string instance = "Windows-PC._mackvm._tcp.local";
        const string host = "mackvm-00112233-4455-6677-8899-aabbccddeeff.local";
        bool Matches(byte[] packet) => MdnsAdvertiser.ContainsOwnedQuery(packet, type, instance, host);
        foreach (var qtype in new ushort[] { 1, 28, 255 })
        {
            Check(Matches(Query((host, qtype, (ushort)1))), "advertised host A/AAAA/ANY must be answered");
        }
        Check(Matches(Query((type.ToUpperInvariant(), (ushort)12, (ushort)0x8001))),
            "service PTR must match case-insensitively and accept mDNS QU class bit");
        foreach (var qtype in new ushort[] { 16, 33, 255 })
        {
            Check(Matches(Query((instance, qtype, (ushort)1))), "owned instance TXT/SRV/ANY must be answered");
        }
        Check(!Matches(Query(("unrelated._mackvm._tcp.local", (ushort)33, (ushort)1)))
            && !Matches(Query(("_mackvm-evil._tcp.local", (ushort)12, (ushort)1)))
            && !Matches(Query(("other.local", (ushort)1, (ushort)1))),
            "names merely containing _mackvm or another host must not be answered");
        Check(!Matches(Query((host, (ushort)12, (ushort)1)))
            && !Matches(Query((instance, (ushort)1, (ushort)1)))
            && !Matches(Query((type, (ushort)33, (ushort)1)))
            && !Matches(Query((host, (ushort)1, (ushort)3))),
            "owned names must still require their supported QTYPE and IN class");

        var compressed = Query((host, (ushort)12, (ushort)1)).ToList();
        // Second question references the first question's previously encoded name.
        compressed[5] = 2;
        compressed.AddRange([0xC0, 0x0C, 0, 28, 0, 1]);
        Check(Matches(compressed.ToArray()), "compressed own-host question must be answered");
        var response = Query((host, (ushort)1, (ushort)1));
        response[2] = 0x84;
        Check(!Matches(response), "announcements/responses must never trigger another response");
        var malformed = Query((host, (ushort)1, (ushort)1)).ToList();
        malformed[5] = 2;
        malformed.AddRange([0xC0, 0xFF]);
        Check(!Matches(malformed.ToArray()), "malformed later question invalidates whole query");
        var cycle = new byte[18];
        cycle[5] = 1; cycle[12] = 0xC0; cycle[13] = 12;
        Check(!Matches(cycle), "compression cycles must terminate without a response");

        const string secureType = "_mackvm-connect._tcp.local";
        Check(MdnsAdvertiser.ContainsOwnedQuery(Query((secureType, (ushort)12, (ushort)1)),
            secureType, "Windows-PC." + secureType, host),
            "secure advertiser must answer its exact owned service type too");
        Check(!MdnsAdvertiser.ContainsOwnedQuery(Query((type, (ushort)12, (ushort)1)),
            secureType, "Windows-PC." + secureType, host),
            "secure advertiser must not answer another advertiser's service query");

        using var credentials = DeviceCredentials.Create("mDNS-Test");
        var responsePacket = MdnsPacket.Build(type, instance, host, credentials.Identity,
            "test", 1234, [IPAddress.Parse("192.0.2.1"), IPAddress.Parse("2001:db8::1")]);
        var recordTypes = new List<ushort>();
        var offset = 12;
        for (var record = 0; record < BinaryPrimitives.ReadUInt16BigEndian(responsePacket.AsSpan(6, 2)); record++)
        {
            while (responsePacket[offset] != 0) { offset += responsePacket[offset] + 1; }
            offset++;
            recordTypes.Add(BinaryPrimitives.ReadUInt16BigEndian(responsePacket.AsSpan(offset, 2)));
            var dataLength = BinaryPrimitives.ReadUInt16BigEndian(responsePacket.AsSpan(offset + 8, 2));
            offset += 10 + dataLength;
        }
        Check(recordTypes.Contains(1) && recordTypes.Contains(28) && offset == responsePacket.Length,
            "host response packet must contain valid A and AAAA independently of query transport");
    }

    private static byte[] Query(params (string Name, ushort Type, ushort Class)[] questions)
    {
        using var stream = new MemoryStream();
        var header = new byte[12];
        BinaryPrimitives.WriteUInt16BigEndian(header.AsSpan(4, 2), (ushort)questions.Length);
        stream.Write(header);
        foreach (var question in questions)
        {
            foreach (var label in question.Name.Split('.'))
            {
                var bytes = Encoding.UTF8.GetBytes(label);
                stream.WriteByte((byte)bytes.Length);
                stream.Write(bytes);
            }
            stream.WriteByte(0);
            var values = new byte[4];
            BinaryPrimitives.WriteUInt16BigEndian(values.AsSpan(0, 2), question.Type);
            BinaryPrimitives.WriteUInt16BigEndian(values.AsSpan(2, 2), question.Class);
            stream.Write(values);
        }
        return stream.ToArray();
    }

    private static void TestReadinessAndTrayRecovery()
    {
        Check(!WindowsTrayRuntimePolicy.Readiness(false, true, false, true, true).IsReady,
            "Local-only must never advertise remote-input readiness");
        Check(!WindowsTrayRuntimePolicy.Readiness(true, false, false, false, false).IsReady,
            "starting listeners are not ready");
        Check(!WindowsTrayRuntimePolicy.Readiness(true, true, true, true, true).IsReady,
            "runtime failure overrides cached ports");
        Check(!WindowsTrayRuntimePolicy.Readiness(true, true, false, false, true).IsReady,
            "pairing listener failure is not ready");
        Check(!WindowsTrayRuntimePolicy.Readiness(true, true, false, true, false).IsReady,
            "secure connect unavailable is not ready");
        var ready = WindowsTrayRuntimePolicy.Readiness(true, true, false, true, true);
        Check(ready.IsReady && ready.Summary.Contains("LAN access not yet verified", StringComparison.Ordinal),
            "listener readiness must not claim proven LAN reachability");

        Check(WindowsTrayRuntimePolicy.ShouldRestoreTray(0xC123, 0xC123, true, false),
            "TaskbarCreated must restore a running main window's tray entry");
        Check(!WindowsTrayRuntimePolicy.ShouldRestoreTray(0xC123, 0xC123, false, false)
            && !WindowsTrayRuntimePolicy.ShouldRestoreTray(0xC123, 0xC123, true, true)
            && !WindowsTrayRuntimePolicy.ShouldRestoreTray(0, 0, true, false)
            && !WindowsTrayRuntimePolicy.ShouldRestoreTray(0xC122, 0xC123, true, false),
            "tray recovery must ignore child windows, shutdown, zero ID, and unrelated messages");
        var adds = 0;
        var modifies = 0;
        Check(WindowsTrayRuntimePolicy.EnsureTrayIcon(() => { adds++; return true; },
            () => { modifies++; return true; }) && modifies == 0,
            "normal add must not modify or duplicate the existing notification contract");
        Check(WindowsTrayRuntimePolicy.EnsureTrayIcon(() => { adds++; return false; },
            () => { modifies++; return true; }) && adds == 2 && modifies == 1,
            "repeated recovery delivery must accept an already-existing icon via MODIFY");
        Check(!WindowsTrayRuntimePolicy.EnsureTrayIcon(() => false, () => false),
            "failed tray recovery must remain observable so native UI can unhide the window");
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) { throw new InvalidOperationException(message); }
    }
}
