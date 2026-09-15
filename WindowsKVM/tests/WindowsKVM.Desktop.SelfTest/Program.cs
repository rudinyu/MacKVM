using System.Collections.Concurrent;
using System.Reflection;
using System.Security.Cryptography;
using WindowsKVM;
using WindowsKVM.Protocol;

namespace WindowsKVM.Desktop.SelfTest;

internal static class Program
{
    private static async Task<int> Main()
    {
        try
        {
            TestInputBookkeepingAndMappings();
            TestTrayLayoutPolicy();
            TestFingerprintFormatting();
            TestTrayNativeChildBounds();
            TestListenerGuardIsCrossPlatformAndAsyncSafe();
            await TestConsentCancellationAndQueueAsync();
            await TestSecureSessionLifecycleAsync();
            Console.WriteLine("WindowsKVM desktop self-test: PASS");
            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"WindowsKVM desktop self-test: FAIL\n{ex}");
            return 1;
        }
    }

    private static void TestInputBookkeepingAndMappings()
    {
        var injected = new List<WindowsInputEvent>();
        var diagnostics = new List<string>();
        using var sink = new WindowsInputSink(
            inputs =>
            {
                injected.AddRange(inputs);
                return (uint)inputs.Count;
            },
            metric => metric == 78 ? 1920 : 1080,
            diagnostics.Add
        );

        sink.Begin();
        sink.Receive(new RemoteInputEvent(RemoteInputKind.KeyDown, keyCode: 51));
        sink.Receive(new RemoteInputEvent(RemoteInputKind.KeyDown, keyCode: 51));
        Assert(injected.Count == 2, "a repeated key-down must be injected again");
        sink.Receive(new RemoteInputEvent(RemoteInputKind.KeyUp, keyCode: 51));
        Assert(
            (injected[^1].Flags & 0x0002u) != 0,
            "the cached key mapping must produce a key-up"
        );

        injected.Clear();
        sink.Receive(new RemoteInputEvent(
            RemoteInputKind.OtherMouseDown,
            location: new NormalizedPoint(0.5, 0.5),
            buttonNumber: 2,
            clickCount: 1
        ));
        Assert(
            (injected[^1].Flags & ~0xC000u) == 0x0020u
                && injected[^1].MouseData == 0,
            "Mac button 2 must map to a Windows middle-button down"
        );
        sink.Receive(new RemoteInputEvent(
            RemoteInputKind.OtherMouseUp,
            location: new NormalizedPoint(0.5, 0.5),
            buttonNumber: 2,
            clickCount: 1
        ));
        Assert(
            (injected[^1].Flags & ~0xC000u) == 0x0040u
                && injected[^1].MouseData == 0,
            "Mac button 2 cleanup must map to a Windows middle-button up"
        );
        sink.Receive(new RemoteInputEvent(
            RemoteInputKind.OtherMouseDown,
            location: new NormalizedPoint(0.5, 0.5),
            buttonNumber: 3,
            clickCount: 1
        ));
        Assert(
            (injected[^1].Flags & ~0xC000u) == 0x0080u
                && injected[^1].MouseData == 1,
            "Mac button 3 must map to Windows XBUTTON1"
        );
        sink.Receive(new RemoteInputEvent(
            RemoteInputKind.OtherMouseUp,
            location: new NormalizedPoint(0.5, 0.5),
            buttonNumber: 3,
            clickCount: 1
        ));
        sink.Receive(new RemoteInputEvent(
            RemoteInputKind.OtherMouseDown,
            location: new NormalizedPoint(0.5, 0.5),
            buttonNumber: 4,
            clickCount: 1
        ));
        Assert(
            (injected[^1].Flags & ~0xC000u) == 0x0080u
                && injected[^1].MouseData == 2,
            "Mac button 4 must map to Windows XBUTTON2"
        );

        var beforeUnsupported = injected.Count;
        sink.Receive(new RemoteInputEvent(
            RemoteInputKind.OtherMouseDown,
            location: new NormalizedPoint(0.5, 0.5),
            buttonNumber: 5,
            clickCount: 1
        ));
        sink.Receive(new RemoteInputEvent(
            RemoteInputKind.SystemDefined,
            mediaKey: MediaKey.BrightnessUp,
            isPressed: true
        ));
        sink.Receive(new RemoteInputEvent(
            RemoteInputKind.SystemDefined,
            mediaKey: MediaKey.IlluminationDown,
            isPressed: true
        ));
        Assert(
            injected.Count == beforeUnsupported,
            "unsupported mouse and brightness events must not invoke OS actions"
        );
        Assert(
            diagnostics.Count >= 3,
            "unsupported input must remain observable to the host"
        );
        sink.End();

        var releaseAttempts = 0;
        var releaseEvents = new List<WindowsInputEvent>();
        using var transientFailureSink = new WindowsInputSink(
            inputs =>
            {
                releaseAttempts++;
                releaseEvents.AddRange(inputs);
                return releaseAttempts == 2 ? 0u : (uint)inputs.Count;
            },
            metric => metric == 78 ? 1920 : 1080
        );
        transientFailureSink.Begin();
        transientFailureSink.Receive(new RemoteInputEvent(
            RemoteInputKind.FlagsChanged,
            keyCode: 59,
            isPressed: true
        ));
        AssertThrows<WindowsInputException>(
            () => transientFailureSink.Receive(new RemoteInputEvent(
                RemoteInputKind.FlagsChanged,
                keyCode: 59,
                isPressed: false
            )),
            "a failed key-up must be surfaced"
        );
        transientFailureSink.End();
        Assert(
            releaseAttempts >= 3 && (releaseEvents[^1].Flags & 0x0002u) != 0,
            "End must retry a failed key-up while retaining held state"
        );

        var partialAttempts = 0;
        using var partialUnicodeSink = new WindowsInputSink(
            inputs =>
            {
                partialAttempts++;
                return partialAttempts == 1 ? 1u : (uint)inputs.Count;
            },
            metric => metric == 78 ? 1920 : 1080
        );
        partialUnicodeSink.Begin();
        AssertThrows<WindowsInputException>(
            () => partialUnicodeSink.Receive(new RemoteInputEvent(
                RemoteInputKind.KeyDown,
                keyCode: 10,
                character: "😀"
            )),
            "a partial Unicode key-down must remain tracked"
        );
        partialUnicodeSink.End();
        Assert(partialAttempts >= 2, "Unicode teardown must retry after a partial batch");

        var persistentAttempts = 0;
        using var persistentFailureSink = new WindowsInputSink(
            _ =>
            {
                persistentAttempts++;
                return 0;
            },
            metric => metric == 78 ? 1920 : 1080
        );
        persistentFailureSink.Begin();
        AssertThrows<WindowsInputException>(
            () => persistentFailureSink.Receive(new RemoteInputEvent(
                RemoteInputKind.KeyDown,
                keyCode: 10,
                character: "Z"
            )),
            "a persistent SendInput failure must be surfaced"
        );
        persistentFailureSink.End();
        AssertThrows<WindowsInputException>(
            persistentFailureSink.Begin,
            "a new grant must be refused while cleanup remains unconfirmed"
        );
        Assert(persistentAttempts >= 4, "persistent cleanup should use bounded retries");
    }

    private static void TestListenerGuardIsCrossPlatformAndAsyncSafe()
    {
        var root = Path.Combine(Path.GetTempPath(), "mackvm-listener-" + Guid.NewGuid().ToString("N"));
        using var first = WindowsKvmListenerGuard.Acquire("self-test-user", root);
        AssertThrows<InvalidOperationException>(
            () => WindowsKvmListenerGuard.Acquire("self-test-user", root),
            "two hosts for one user must not acquire the listener lease"
        );
        Task.Run(first.Dispose).GetAwaiter().GetResult();
        using var second = WindowsKvmListenerGuard.Acquire("self-test-user", root);
        second.Dispose();
        Directory.Delete(root, recursive: true);
    }

    private static void TestTrayLayoutPolicy()
    {
        var simple = WindowsTrayLayoutPolicy.ForSimple(1440, 900);
        Assert(
            simple.Width == WindowsTrayLayoutPolicy.SimplePreferredWidth
                && simple.Height == WindowsTrayLayoutPolicy.SimplePreferredHeight,
            "simple mode should use the compact preferred dimensions"
        );
        var narrow = WindowsTrayLayoutPolicy.ForSimple(410, 390);
        Assert(
            narrow.Width <= 410 && narrow.Height <= 390,
            "simple mode must clamp to a narrow work area"
        );
        var highDpi = WindowsTrayLayoutPolicy.ForAdvanced(3200, 1800);
        Assert(
            highDpi.Width == WindowsTrayLayoutPolicy.AdvancedPreferredWidth
                && highDpi.Height == WindowsTrayLayoutPolicy.AdvancedPreferredHeight,
            "advanced mode should retain its detailed dimensions on a large work area"
        );
        var tiny = WindowsTrayLayoutPolicy.ForAdvanced(280, 240);
        Assert(
            tiny.Width == 280 && tiny.Height == 240,
            "both modes must remain inside an unusually small work area"
        );

        var nativeMinimum = WindowsTrayLayoutPolicy.MinimumWindowSize(1920, 1080);
        Assert(
            nativeMinimum.Width == 360 && nativeMinimum.Height == 320,
            "normal displays must enforce the existing usable native window floor"
        );
        // MINMAXINFO constrains the outer window, not the drawable client.
        // Cover representative frame/scrollbar widths, including scaled ones;
        // actual Win32/DPI geometry is also part of desktop acceptance testing.
        foreach (var nonClientWidth in new[] { 33, 66, 100 })
        {
            var clientWidth = nativeMinimum.Width - nonClientWidth;
            var minimumClient = WindowsTrayLayoutPolicy.ForSimpleContent(clientWidth);
            foreach (var bounds in minimumClient.Controls.Values)
            {
                Assert(
                    bounds.IsWithin(clientWidth, minimumClient.ContentHeight),
                    "the native minimum must keep every Simple child reachable after frame insets"
                );
            }
            Assert(
                clientWidth > 96
                    && minimumClient[WindowsTraySimpleControl.Title].Bottom
                        <= minimumClient[WindowsTraySimpleControl.ModeButton].Y
                    && minimumClient[WindowsTraySimpleControl.ModeButton].Bottom
                        <= minimumClient[WindowsTraySimpleControl.QuickSetup].Y
                    && minimumClient[WindowsTraySimpleControl.Title].Width >= 212
                    && minimumClient[WindowsTraySimpleControl.Quit].Right <= clientWidth,
                "narrow clients must stack the mode action below the full WindowsKVM title"
            );
        }
        var tinyNativeMinimum = WindowsTrayLayoutPolicy.MinimumWindowSize(96, 96);
        Assert(
            tinyNativeMinimum.Width == 96 && tinyNativeMinimum.Height == 96,
            "the native floor must yield to a work area smaller than the usable floor"
        );

        var normalClient = WindowsTrayLayoutPolicy.ForSimpleContent(487);
        foreach (var bounds in normalClient.Controls.Values)
        {
            Assert(
                bounds.IsWithin(487, normalClient.ContentHeight),
                "normal compact child bounds must fit the real client area"
            );
        }
        Assert(
            normalClient.ContentHeight <= WindowsTrayLayoutPolicy.SimplePreferredHeight - 40,
            "normal Simple mode content should fit without vertical scrolling"
        );
        Assert(
            normalClient[WindowsTraySimpleControl.Title].Right + 16
                <= normalClient[WindowsTraySimpleControl.ModeButton].X,
            "compact title must leave room for the mode button"
        );
        Assert(
            normalClient[WindowsTraySimpleControl.Quit].Right == 463,
            "compact Quit must be aligned to the client right edge"
        );

        // The real window can be dragged through several widths without a
        // mode switch. Recomputing from each client width must move the
        // right-aligned action, and returning to the original width must
        // restore its original bound rather than retaining stale coordinates.
        var resizedClient = WindowsTrayLayoutPolicy.ForSimpleContent(400);
        var restoredClient = WindowsTrayLayoutPolicy.ForSimpleContent(487);
        Assert(
            resizedClient[WindowsTraySimpleControl.Quit].Right <= 400
                && resizedClient[WindowsTraySimpleControl.Quit].X
                    != normalClient[WindowsTraySimpleControl.Quit].X
                && restoredClient[WindowsTraySimpleControl.Quit]
                    == normalClient[WindowsTraySimpleControl.Quit],
            "repeated client resizes must recompute and then restore child bounds"
        );

        var narrowClient = WindowsTrayLayoutPolicy.ForSimpleContent(328);
        foreach (var bounds in narrowClient.Controls.Values)
        {
            Assert(
                bounds.IsWithin(328, narrowClient.ContentHeight),
                "narrow compact child bounds must fit the real client area"
            );
        }
        Assert(
            narrowClient[WindowsTraySimpleControl.Quit].Right <= 328,
            "narrow compact Quit must not use a fixed off-screen x coordinate"
        );

        var stackedClient = WindowsTrayLayoutPolicy.ForSimpleContent(260);
        Assert(
            stackedClient[WindowsTraySimpleControl.Forget].Y
                >= stackedClient[WindowsTraySimpleControl.PairName].Bottom,
            "very narrow pairing controls must reflow vertically"
        );
        Assert(
            stackedClient[WindowsTraySimpleControl.Quit].Y
                > stackedClient[WindowsTraySimpleControl.Refresh].Y,
            "very narrow action buttons must stack instead of clipping"
        );
        foreach (var bounds in stackedClient.Controls.Values)
        {
            Assert(
                bounds.IsWithin(260, stackedClient.ContentHeight),
                "stacked compact child bounds must fit the content area"
            );
        }

        var advancedNarrow = WindowsTrayLayoutPolicy.AdvancedHorizontalMaximum(640);
        var advancedVeryNarrow = WindowsTrayLayoutPolicy.AdvancedHorizontalMaximum(400);
        Assert(
            WindowsTrayLayoutPolicy.AdvancedPreferredWidth
                >= WindowsTrayLayoutPolicy.AdvancedContentWidth + 16,
            "preferred Advanced width must leave room for non-client chrome"
        );
        Assert(
            advancedNarrow > 0
                && advancedVeryNarrow > advancedNarrow,
            "narrow Advanced clients must expose a horizontal scroll range"
        );
        Assert(
            WindowsTrayLayoutPolicy.ClampHorizontalOffset(
                true,
                640,
                int.MaxValue
            ) == advancedNarrow
                && WindowsTrayLayoutPolicy.ClampHorizontalOffset(
                    true,
                    400,
                    -1
                ) == 0,
            "Advanced horizontal offsets must clamp to the current client width"
        );
        Assert(
            WindowsTrayLayoutPolicy.ClampHorizontalOffset(
                false,
                400,
                advancedVeryNarrow
            ) == 0,
            "switching back to Simple must clear the Advanced horizontal offset"
        );
    }

    private static void TestFingerprintFormatting()
    {
        var fingerprint = string.Concat(Enumerable.Repeat("AA:", 31)) + "AA";
        var formatted = WindowsTrayLayoutPolicy.FormatFingerprint(
            "Local key fingerprint",
            fingerprint
        );
        var lines = formatted.Split("\r\n", StringSplitOptions.None);
        Assert(
            lines.Length == 3 && lines[0] == "Local key fingerprint:",
            "fingerprint formatting must keep the label on its own line"
        );
        Assert(
            lines.Skip(1).All(line => line.Length <= WindowsTrayLayoutPolicy.FingerprintDisplayChunkLength),
            "fingerprint display lines must stay within the native label width"
        );
        Assert(
            string.Concat(lines.Skip(1)) == fingerprint,
            "fingerprint formatting must preserve every character"
        );
    }

    private static void TestTrayNativeChildBounds()
    {
        var advancedCombo = new WindowsTrayChildBounds(410, 738, 380, 34);
        // Match the native CB_GETITEMHEIGHT result for ordinary and scaled
        // fonts. Two choices must fit after creation AND every move/resize.
        foreach (var itemHeight in new[] { 18, 27, 36 })
        {
            foreach (var verticalOffset in new[] { 0, 48, 720, 840, 0 })
            {
                var native = WindowsTrayLayoutPolicy.ForNativeChild(
                    advancedCombo, 190, verticalOffset, itemHeight, 2
                );
                Assert(
                    native.X == 220
                        && native.Y == 738 - verticalOffset
                        && native.Width == advancedCombo.Width
                        && native.Height >= advancedCombo.Height + itemHeight * 2 + 4,
                    "native combo placement must keep both rows while scrolling in either direction"
                );
            }
        }

        foreach (var width in new[] { 487, 400, 260, 487 })
        {
            var layout = WindowsTrayLayoutPolicy.ForSimpleContent(width);
            var visual = layout[WindowsTraySimpleControl.InputPathCombo];
            var native = WindowsTrayLayoutPolicy.ForNativeChild(visual, 0, 120, 20, 2);
            Assert(
                native.Width == visual.Width && native.Height == 76
                    && visual.Height == 32
                    && visual.Bottom < layout[WindowsTraySimpleControl.Refresh].Y,
                "Simple reflow must reserve the popup height without enlarging the collapsed row"
            );
        }

        var noPeers = WindowsTrayLayoutPolicy.ForNativeChild(advancedCombo, 0, 0, 20, 0);
        var manyPeers = WindowsTrayLayoutPolicy.ForNativeChild(advancedCombo, 0, 0, 20, 100);
        var onePeer = WindowsTrayLayoutPolicy.ForNativeChild(advancedCombo, 0, 0, 20, 1);
        Assert(
            noPeers.Height == 78 && onePeer.Height == 78 && manyPeers.Height == 198,
            "dynamic peer lists must retain a useful minimum and cap at eight visible rows"
        );
        Assert(
            WindowsTrayLayoutPolicy.ForNativeChild(advancedCombo, 80, 800)
                == new WindowsTrayChildBounds(330, -62, 380, 34),
            "non-combo controls must move without acquiring expanded-list height"
        );
    }

    private static async Task TestConsentCancellationAndQueueAsync()
    {
        var messages = new ConcurrentQueue<(long ID, bool Dismiss)>();
        using var coordinator = new ConsentRequestCoordinator(
            id =>
            {
                messages.Enqueue((id, false));
                return true;
            },
            id =>
            {
                messages.Enqueue((id, true));
                return true;
            }
        );
        var firstTask = coordinator.EnqueueAsync("first", "first", CancellationToken.None);
        Assert(coordinator.TryBeginNext(out var first), "first request should be displayed");
        var secondSource = new CancellationTokenSource();
        var secondTask = coordinator.EnqueueAsync("second", "second", secondSource.Token);
        secondSource.Cancel();
        Assert(
            coordinator.ActiveRequestID == first.ID,
            "canceling queued request B must not dismiss active request A"
        );
        Assert(coordinator.TryComplete(first.ID, true), "first request should accept once");
        Assert(await firstTask.ConfigureAwait(false), "first request result should be true");
        Assert(!await secondTask.ConfigureAwait(false), "queued cancellation should deny");
        Assert(
            messages.Any(message => message.Dismiss && message.ID == 0),
            "queued cancellation must use a pump-only UI message"
        );

        using var deadlineSource = new CancellationTokenSource();
        var deadlineCoordinator = new ConsentRequestCoordinator(
            _ => true,
            _ => true
        );
        using var blockingEntered = new ManualResetEventSlim();
        using var unblock = new ManualResetEventSlim();
        var deadlineTask = deadlineCoordinator.EnqueueAsync(
            "deadline",
            "deadline",
            deadlineSource.Token
        );
        Assert(
            deadlineCoordinator.TryBeginNext(out var deadline),
            "deadline request should be displayed"
        );
        using var blockingCallback = deadlineSource.Token.Register(
            () =>
            {
                blockingEntered.Set();
                unblock.Wait();
            }
        );
        var cancelTask = Task.Run(deadlineSource.Cancel);
        Assert(blockingEntered.Wait(TimeSpan.FromSeconds(2)), "cancel callback did not start");
        Assert(
            deadlineCoordinator.TryComplete(deadline.ID, true),
            "deadline completion should resolve the request"
        );
        Assert(!await deadlineTask.ConfigureAwait(false), "deadline acceptance must be denied");
        unblock.Set();
        await cancelTask.ConfigureAwait(false);
        deadlineCoordinator.Dispose();
    }

    private static async Task TestSecureSessionLifecycleAsync()
    {
        await TestHotKeyAndEndedRequestAsync().ConfigureAwait(false);
        await TestDisableEnableAndConsentGenerationAsync().ConfigureAwait(false);
        await TestActiveDisableEnableAndFreshGrantAsync().ConfigureAwait(false);
        await TestGrantBoundaryNotificationOrderAsync().ConfigureAwait(false);
    }

    private static async Task TestHotKeyAndEndedRequestAsync()
    {
        var harness = await SecureHarness.ConnectAsync(autoAcceptControl: true)
            .ConfigureAwait(false);
        await using (harness.ConfigureAwait(false))
        {
            var grant = await harness.RequestControlAsync().ConfigureAwait(false);
            Assert(
                grant.Kind == ControlMessageKind.ControlGranted,
                "authenticated control request should be granted"
            );
            harness.HotKey!.Trigger();
            var ended = await harness.ReadControlAsync().ConfigureAwait(false);
            Assert(
                ended.Kind == ControlMessageKind.EndControl,
                "release hotkey must notify the Mac peer"
            );
            await harness.SendControlAsync(ControlMessage.InputMessage(
                new RemoteInputEvent(RemoteInputKind.KeyDown, keyCode: 51),
                harness.CurrentRequestID
            )).ConfigureAwait(false);
            await Task.Delay(100).ConfigureAwait(false);
            Assert(!harness.Session.IsCompleted, "a known ended request must be safely ignored");
            Assert(harness.Events.Count == 0, "late ended-request input must not inject");

            await harness.SendControlAsync(ControlMessage.InputMessage(
                new RemoteInputEvent(RemoteInputKind.KeyDown, keyCode: 51),
                Guid.NewGuid()
            )).ConfigureAwait(false);
            Assert(
                await WaitForCompletionAsync(harness.Session).ConfigureAwait(false),
                "an unknown request ID must terminate the authenticated session"
            );
        }
    }

    private static async Task TestDisableEnableAndConsentGenerationAsync()
    {
        var consentReady = new TaskCompletionSource<bool>(
            TaskCreationOptions.RunContinuationsAsynchronously
        );
        var consentRelease = new TaskCompletionSource<bool>(
            TaskCreationOptions.RunContinuationsAsynchronously
        );
        SecureHarness? harness = null;
        var receiver = await SecureHarness.CreateAsync(
            async (_, token) =>
            {
                consentReady.TrySetResult(true);
                await consentRelease.Task.WaitAsync(token).ConfigureAwait(false);
                return true;
            },
            onControlStateChanged: active =>
            {
                if (active)
                {
                    harness!.Receiver.SetRemoteInputEnabled(false);
                }
            }
        ).ConfigureAwait(false);
        harness = receiver;
        await using (harness.ConfigureAwait(false))
        {
            var request = harness.NextRequestID();
            await harness.SendControlAsync(ControlMessage.RequestControl(request)).ConfigureAwait(false);
            Assert(await consentReady.Task.WaitAsync(TimeSpan.FromSeconds(2)), "consent did not start");
            harness.Receiver.SetRemoteInputEnabled(false);
            harness.Receiver.SetRemoteInputEnabled(true);
            consentRelease.TrySetResult(true);
            var denied = await harness.ReadControlAsync().ConfigureAwait(false);
            Assert(
                denied.Kind == ControlMessageKind.ControlDenied,
                "a consent callback from a retired generation must be denied"
            );
            Assert(harness.Events.Count == 0, "retired consent must not inject input");
        }
    }

    private static async Task TestActiveDisableEnableAndFreshGrantAsync()
    {
        var harness = await SecureHarness.ConnectAsync(autoAcceptControl: true)
            .ConfigureAwait(false);
        await using (harness.ConfigureAwait(false))
        {
            var grant = await harness.RequestControlAsync().ConfigureAwait(false);
            Assert(
                grant.Kind == ControlMessageKind.ControlGranted,
                "the first active grant should be accepted"
            );
            var oldRequest = harness.CurrentRequestID;
            await harness.SendControlAsync(ControlMessage.InputMessage(
                new RemoteInputEvent(RemoteInputKind.KeyDown, keyCode: 51),
                oldRequest
            )).ConfigureAwait(false);
            Assert(
                await WaitForConditionAsync(() => harness.Events.Count == 1)
                    .ConfigureAwait(false),
                "the active grant must inject input"
            );

            harness.Receiver.SetRemoteInputEnabled(false);
            harness.Receiver.SetRemoteInputEnabled(true);
            var ended = await harness.ReadControlAsync().ConfigureAwait(false);
            Assert(
                ended.Kind == ControlMessageKind.EndControl
                    && ended.RequestID == oldRequest,
                "disable must notify the peer before a fresh grant"
            );

            var eventCountAfterTeardown = harness.Events.Count;
            await harness.SendControlAsync(ControlMessage.InputMessage(
                new RemoteInputEvent(RemoteInputKind.KeyDown, keyCode: 52),
                oldRequest
            )).ConfigureAwait(false);
            await Task.Delay(100).ConfigureAwait(false);
            Assert(
                harness.Events.Count == eventCountAfterTeardown,
                "old input must stay ignored after disable->enable"
            );
            Assert(!harness.Session.IsCompleted, "active disable must keep the session alive");

            var freshGrant = await harness.RequestControlAsync().ConfigureAwait(false);
            Assert(
                freshGrant.Kind == ControlMessageKind.ControlGranted
                    && harness.CurrentRequestID != oldRequest,
                "a new request must receive a fresh grant after teardown"
            );
            await harness.SendControlAsync(ControlMessage.InputMessage(
                new RemoteInputEvent(RemoteInputKind.KeyDown, keyCode: 53),
                harness.CurrentRequestID
            )).ConfigureAwait(false);
            Assert(
                await WaitForConditionAsync(
                    () => harness.Events.Count > eventCountAfterTeardown
                ).ConfigureAwait(false),
                "fresh-grant input must not be blackholed"
            );
        }
    }

    private static async Task TestGrantBoundaryNotificationOrderAsync()
    {
        SecureHarness? harness = null;
        var boundaryReached = new TaskCompletionSource<bool>(
            TaskCreationOptions.RunContinuationsAsynchronously
        );
        var connected = await SecureHarness.ConnectAsync(
            autoAcceptControl: true,
            beforeControlGranted: () =>
            {
                boundaryReached.TrySetResult(true);
                harness!.Receiver.SetRemoteInputEnabled(false);
            }
        ).ConfigureAwait(false);
        harness = connected;
        await using (harness.ConfigureAwait(false))
        {
            var grant = await harness.RequestControlAsync().ConfigureAwait(false);
            Assert(
                await boundaryReached.Task.WaitAsync(TimeSpan.FromSeconds(2))
                    .ConfigureAwait(false),
                "grant-send boundary seam was not reached"
            );
            Assert(
                grant.Kind == ControlMessageKind.ControlGranted,
                "ControlGranted must precede a boundary teardown notification"
            );
            var ended = await harness.ReadControlAsync().ConfigureAwait(false);
            Assert(
                ended.Kind == ControlMessageKind.EndControl
                    && ended.RequestID == harness.CurrentRequestID,
                "boundary teardown must send EndControl only after ControlGranted"
            );
        }
    }

    private static async Task<bool> WaitForCompletionAsync(Task task)
    {
        var completed = await Task.WhenAny(task, Task.Delay(TimeSpan.FromSeconds(3))).ConfigureAwait(false);
        return completed == task;
    }

    private static async Task<bool> WaitForConditionAsync(
        Func<bool> condition,
        TimeSpan? timeout = null
    )
    {
        var deadline = DateTime.UtcNow + (timeout ?? TimeSpan.FromSeconds(2));
        while (!condition())
        {
            if (DateTime.UtcNow >= deadline)
            {
                return false;
            }

            await Task.Delay(10).ConfigureAwait(false);
        }

        return true;
    }

    private static void Assert(bool condition, string message)
    {
        if (!condition)
        {
            throw new InvalidOperationException(message);
        }
    }

    private static void AssertThrows<TException>(Action action, string message)
        where TException : Exception
    {
        try
        {
            action();
        }
        catch (TException)
        {
            return;
        }

        throw new InvalidOperationException(message);
    }
}
