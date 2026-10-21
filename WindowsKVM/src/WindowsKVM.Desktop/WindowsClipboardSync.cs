using System.Collections.Concurrent;
using System.Runtime.InteropServices;
using System.Text;
using WindowsKVM.Protocol;

namespace WindowsKVM;

/// <summary>
/// A narrow desktop boundary so clipboard lifecycle and filtering can be
/// exercised by the framework-neutral self-test on non-Windows hosts.
/// Implementations must treat a busy clipboard as a skipped sample.
/// </summary>
internal interface IClipboardTextBoundary : IDisposable
{
    bool IsAvailable { get; }

    bool TryReadText(CancellationToken token, out string text);

    bool TryWriteText(string text, CancellationToken token);
}

/// <summary>
/// Owns at most one active control-session clipboard synchronizer. Polling is
/// sequential, starts only after a successful control grant, and takes its
/// first readable value as a baseline so connecting never sends old contents.
/// </summary>
internal sealed class WindowsClipboardSyncCoordinator : IAsyncDisposable
{
    private readonly object gate = new();
    private readonly IClipboardTextBoundary clipboard;
    private WindowsClipboardSyncSession? activeSession;
    private readonly HashSet<WindowsClipboardSyncSession> sessions = [];
    private int disposed;

    public WindowsClipboardSyncCoordinator(IClipboardTextBoundary clipboard)
        => this.clipboard = clipboard;

    public bool IsAvailable => clipboard.IsAvailable;

    public bool Start(
        Guid requestID,
        Func<ControlMessage, CancellationToken, Task> sendClipboard
    )
    {
        lock (gate)
        {
            if (Volatile.Read(ref disposed) != 0
                || !clipboard.IsAvailable
                || activeSession is not null)
            {
                return false;
            }

            var session = new WindowsClipboardSyncSession(
                requestID,
                clipboard,
                sendClipboard
            );
            foreach (var completed in sessions.Where(item => item.Completion.IsCompleted).ToArray())
            {
                completed.Dispose();
                sessions.Remove(completed);
            }
            sessions.Add(session);
            activeSession = session;
            activeSession.Start();
            return true;
        }
    }

    /// <summary>
    /// Returns false only when the request has no active clipboard session.
    /// A busy or policy-excluded local clipboard is a normal dropped update.
    /// </summary>
    public bool Receive(Guid requestID, string text)
    {
        WindowsClipboardSyncSession? session;
        lock (gate)
        {
            session = activeSession;
            if (session is null || session.RequestID != requestID)
            {
                return false;
            }
        }

        session.ReceiveRemoteText(text);
        return true;
    }

    public void Stop(Guid requestID)
    {
        WindowsClipboardSyncSession? session = null;
        lock (gate)
        {
            if (activeSession?.RequestID == requestID)
            {
                session = activeSession;
                activeSession = null;
            }
        }

        session?.Stop();
    }

    public async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref disposed, 1) != 0)
        {
            return;
        }

        WindowsClipboardSyncSession[] ownedSessions;
        lock (gate)
        {
            activeSession = null;
            ownedSessions = sessions.ToArray();
            sessions.Clear();
        }

        foreach (var session in ownedSessions)
        {
            session.Stop();
        }
        foreach (var session in ownedSessions)
        {
            await session.Completion.ConfigureAwait(false);
            session.Dispose();
        }

        clipboard.Dispose();
    }
}

internal sealed class WindowsClipboardSyncSession : IDisposable
{
    private static readonly TimeSpan PollInterval = TimeSpan.FromMilliseconds(500);
    private readonly IClipboardTextBoundary clipboard;
    private readonly Func<ControlMessage, CancellationToken, Task> sendClipboard;
    private readonly CancellationTokenSource cancellation = new();
    private readonly object gate = new();
    private Task pollTask = Task.CompletedTask;
    private string? lastObservedText;
    private long clipboardGeneration;
    private bool hasBaseline;
    private bool started;
    private int stopped;

    public WindowsClipboardSyncSession(
        Guid requestID,
        IClipboardTextBoundary clipboard,
        Func<ControlMessage, CancellationToken, Task> sendClipboard
    )
    {
        RequestID = requestID;
        this.clipboard = clipboard;
        this.sendClipboard = sendClipboard;
    }

    public Guid RequestID { get; }

    public Task Completion => pollTask;

    public void Start()
    {
        lock (gate)
        {
            if (started || Volatile.Read(ref stopped) != 0)
            {
                return;
            }

            started = true;
            pollTask = PollAsync(cancellation.Token);
        }
    }

    public void ReceiveRemoteText(string text)
    {
        if (Volatile.Read(ref stopped) != 0)
        {
            return;
        }

        // CF_UNICODETEXT is NUL-terminated and cannot preserve embedded NULs.
        // Drop such a remote value instead of writing a truncated prefix that
        // would look like a fresh local edit on the next poll.
        if (text.IndexOf('\0') >= 0)
        {
            return;
        }

        // Invalidate any local sample already in flight. Otherwise a sample
        // captured just before this remote write could echo the old text back.
        lock (gate)
        {
            if (!started || Volatile.Read(ref stopped) != 0)
            {
                return;
            }
            clipboardGeneration++;
        }

        if (!clipboard.TryWriteText(text, cancellation.Token))
        {
            return;
        }

        lock (gate)
        {
            if (Volatile.Read(ref stopped) == 0)
            {
                lastObservedText = text;
                hasBaseline = true;
                clipboardGeneration++;
            }
        }
    }

    public void Stop()
    {
        if (Interlocked.Exchange(ref stopped, 1) != 0)
        {
            return;
        }

        try
        {
            cancellation.Cancel();
        }
        catch (ObjectDisposedException)
        {
        }
    }

    private async Task PollAsync(CancellationToken token)
    {
        try
        {
            using var timer = new PeriodicTimer(PollInterval);
            while (await timer.WaitForNextTickAsync(token).ConfigureAwait(false))
            {
                long generation;
                lock (gate)
                {
                    if (Volatile.Read(ref stopped) != 0)
                    {
                        return;
                    }
                    generation = clipboardGeneration;
                }

                if (!clipboard.TryReadText(token, out var text))
                {
                    continue;
                }

                var shouldSend = false;
                lock (gate)
                {
                    if (Volatile.Read(ref stopped) != 0
                        || generation != clipboardGeneration)
                    {
                        continue;
                    }

                    if (!hasBaseline)
                    {
                        // Never send content that was already present when
                        // control began, including when OpenClipboard was busy
                        // until a later polling tick.
                        hasBaseline = true;
                        lastObservedText = text;
                        continue;
                    }

                    if (string.Equals(lastObservedText, text, StringComparison.Ordinal))
                    {
                        continue;
                    }

                    lastObservedText = text;
                    shouldSend = true;
                }

                if (!shouldSend)
                {
                    continue;
                }

                var message = ControlMessage.ClipboardMessage(RequestID, text);
                try
                {
                    // The UTF-8 text limit is not enough: JSON escaping and
                    // envelope fields also count against the encrypted frame.
                    _ = ControlMessageCodec.Encode(message);
                }
                catch (ControlMessageException ex)
                    when (ex.Code == ControlMessageErrorCode.PayloadTooLarge)
                {
                    continue;
                }

                try
                {
                    await sendClipboard(message, token).ConfigureAwait(false);
                }
                catch (OperationCanceledException) when (token.IsCancellationRequested)
                {
                    return;
                }
                catch
                {
                    // A broken transport is not retried forever. The secure
                    // session owns reconnect and control teardown.
                    return;
                }
            }
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested)
        {
        }
    }

    public void Dispose()
    {
        Stop();
        cancellation.Dispose();
    }
}

/// <summary>
/// Windows clipboard API implementation. Clipboard calls are marshalled to a
/// dedicated STA thread through a one-item queue; a busy clipboard or saturated
/// boundary skips one sample instead of blocking callers or accumulating work.
/// </summary>
internal sealed class WindowsClipboardTextBoundary : IClipboardTextBoundary
{
    private const uint ClipboardFormatUnicodeText = 13;
    private const uint GlobalMemoryMoveable = 0x0002;
    private const uint GlobalMemoryZeroInit = 0x0040;
    private const string ExcludeMonitorProcessing = "ExcludeClipboardContentFromMonitorProcessing";
    private const string CanIncludeHistory = "CanIncludeInClipboardHistory";
    private const string CanUploadCloudClipboard = "CanUploadToCloudClipboard";
    private readonly StaClipboardExecutor executor;

    public WindowsClipboardTextBoundary()
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException("Windows clipboard access requires Windows.");
        }

        executor = new StaClipboardExecutor();
    }

    public bool IsAvailable => executor.IsAvailable;

    public bool TryReadText(CancellationToken token, out string text)
    {
        text = string.Empty;
        var ownerWindow = executor.OwnerWindow;
        if (ownerWindow == IntPtr.Zero)
        {
            return false;
        }

        if (!executor.TryInvoke(
            token =>
            {
                var succeeded = ReadTextOnSta(ownerWindow, token, out var value);
                return (succeeded, value);
            },
            token,
            out var result
        ) || !result.succeeded)
        {
            return false;
        }

        text = result.value;
        return true;
    }

    public bool TryWriteText(string text, CancellationToken token)
    {
        var ownerWindow = executor.OwnerWindow;
        return ownerWindow != IntPtr.Zero
            && executor.TryInvoke(
                token => WriteTextOnSta(text, ownerWindow, token),
                token,
                out var written
            )
            && written;
    }

    private static bool ReadTextOnSta(
        IntPtr ownerWindow,
        CancellationToken token,
        out string text
    )
    {
        text = string.Empty;
        if (token.IsCancellationRequested)
        {
            return false;
        }

        var excludeFormat = RegisterClipboardFormat(ExcludeMonitorProcessing);
        var historyFormat = RegisterClipboardFormat(CanIncludeHistory);
        var cloudFormat = RegisterClipboardFormat(CanUploadCloudClipboard);
        if (token.IsCancellationRequested
            || excludeFormat == 0 || historyFormat == 0 || cloudFormat == 0
            || !OpenClipboard(ownerWindow))
        {
            return false;
        }

        try
        {
            if (!ClipboardFormatsPermitTransfer(
                excludeFormat,
                historyFormat,
                cloudFormat,
                token
            ))
            {
                return false;
            }

            var data = GetClipboardData(ClipboardFormatUnicodeText);
            if (data == IntPtr.Zero)
            {
                return false;
            }

            var byteCount = GlobalSize(data).ToUInt64();
            if (byteCount < sizeof(char))
            {
                return false;
            }

            var memory = GlobalLock(data);
            if (memory == IntPtr.Zero)
            {
                return false;
            }

            try
            {
                var availableCharacters = (int)Math.Min(byteCount / sizeof(char), 32_769UL);
                var characters = new char[Math.Min(availableCharacters, 32_769)];
                var length = 0;
                var terminated = false;
                for (; length < characters.Length; length++)
                {
                    var character = (char)unchecked((ushort)Marshal.ReadInt16(memory, length * sizeof(char)));
                    if (character == '\0')
                    {
                        terminated = true;
                        break;
                    }
                    characters[length] = character;
                }

                if (!terminated)
                {
                    return false;
                }

                text = new string(characters, 0, length);
                if (Encoding.UTF8.GetByteCount(text) > ControlMessageCodec.MaximumClipboardTextLength)
                {
                    text = string.Empty;
                    return false;
                }

                return true;
            }
            finally
            {
                _ = GlobalUnlock(data);
            }
        }
        finally
        {
            _ = CloseClipboard();
        }
    }

    private static bool ClipboardFormatsPermitTransfer(
        uint excludeFormat,
        uint historyFormat,
        uint cloudFormat,
        CancellationToken token
    )
    {
        uint previous = 0;
        while (true)
        {
            if (token.IsCancellationRequested)
            {
                return false;
            }

            Marshal.SetLastPInvokeError(0);
            var format = EnumClipboardFormats(previous);
            var error = Marshal.GetLastWin32Error();
            if (format == 0)
            {
                return error == 0;
            }

            if (format == excludeFormat)
            {
                // This marker is an exclusion by presence; no payload value
                // can override it.
                return false;
            }

            if (format == historyFormat || format == cloudFormat)
            {
                var marker = GetClipboardData(format);
                if (marker == IntPtr.Zero)
                {
                    return false;
                }

                var size = GlobalSize(marker).ToUInt64();
                if (size < sizeof(int))
                {
                    return false;
                }

                var markerMemory = GlobalLock(marker);
                if (markerMemory == IntPtr.Zero)
                {
                    return false;
                }

                int permission;
                try
                {
                    permission = Marshal.ReadInt32(markerMemory);
                }
                finally
                {
                    _ = GlobalUnlock(marker);
                }

                // Windows defines DWORD 0 as an explicit exclusion and 1 as
                // an explicit allow. Unknown or corrupt values fail closed.
                if (permission != 1)
                {
                    return false;
                }
            }

            previous = format;
        }
    }

    private static bool WriteTextOnSta(
        string text,
        IntPtr ownerWindow,
        CancellationToken token
    )
    {
        if (token.IsCancellationRequested
            || ownerWindow == IntPtr.Zero
            || !OpenClipboard(ownerWindow))
        {
            return false;
        }

        IntPtr allocation = IntPtr.Zero;
        try
        {
            var excludeFormat = RegisterClipboardFormat(ExcludeMonitorProcessing);
            var historyFormat = RegisterClipboardFormat(CanIncludeHistory);
            var cloudFormat = RegisterClipboardFormat(CanUploadCloudClipboard);
            if (excludeFormat == 0 || historyFormat == 0 || cloudFormat == 0
                || token.IsCancellationRequested
                || !ClipboardFormatsPermitTransfer(
                    excludeFormat,
                    historyFormat,
                    cloudFormat,
                    token
                ))
            {
                return false;
            }

            var bytes = Encoding.Unicode.GetBytes(text + '\0');
            allocation = GlobalAlloc(
                GlobalMemoryMoveable | GlobalMemoryZeroInit,
                new UIntPtr((uint)bytes.Length)
            );
            if (allocation == IntPtr.Zero)
            {
                return false;
            }

            if (token.IsCancellationRequested)
            {
                return false;
            }

            var memory = GlobalLock(allocation);
            if (memory == IntPtr.Zero)
            {
                return false;
            }

            try
            {
                Marshal.Copy(bytes, 0, memory, bytes.Length);
            }
            finally
            {
                _ = GlobalUnlock(allocation);
            }

            if (token.IsCancellationRequested || !EmptyClipboard())
            {
                return false;
            }

            if (token.IsCancellationRequested)
            {
                return false;
            }

            if (SetClipboardData(ClipboardFormatUnicodeText, allocation) == IntPtr.Zero)
            {
                return false;
            }

            allocation = IntPtr.Zero; // ownership transfers to the system
            return true;
        }
        finally
        {
            if (allocation != IntPtr.Zero)
            {
                _ = GlobalFree(allocation);
            }
            _ = CloseClipboard();
        }
    }

    public void Dispose() => executor.Dispose();

    [DllImport("user32.dll", EntryPoint = "RegisterClipboardFormatW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint RegisterClipboardFormat(string format);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool OpenClipboard(IntPtr owner);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool CloseClipboard();

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint EnumClipboardFormats(uint format);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr GetClipboardData(uint format);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool EmptyClipboard();

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetClipboardData(uint format, IntPtr memory);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern UIntPtr GlobalSize(IntPtr memory);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr GlobalLock(IntPtr memory);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GlobalUnlock(IntPtr memory);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr GlobalAlloc(uint flags, UIntPtr bytes);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr GlobalFree(IntPtr memory);
}

internal sealed class NullClipboardTextBoundary : IClipboardTextBoundary
{
    public bool IsAvailable => false;

    public bool TryReadText(CancellationToken token, out string text)
    {
        text = string.Empty;
        return false;
    }

    public bool TryWriteText(string text, CancellationToken token) => false;

    public void Dispose() { }
}

internal sealed class StaClipboardExecutor : IDisposable
{
    private const int MaximumWaitMilliseconds = 250;
    private const int MessagePumpIntervalMilliseconds = 15;
    private const uint PeekMessageRemove = 0x0001;
    private const uint WindowMessageQuit = 0x0012;
    private const uint WindowStylePopup = 0x80000000;
    private static readonly IntPtr MessageOnlyWindow = new(-3);
    private readonly BlockingCollection<IClipboardWorkItem> queue = new(1);
    private readonly CancellationTokenSource shutdown = new();
    private readonly ManualResetEventSlim initialized = new(false);
    private readonly Thread worker;
    private IntPtr ownerWindow;
    private int disposed;

    public StaClipboardExecutor()
    {
        worker = new Thread(Run)
        {
            IsBackground = true,
            Name = "WindowsKVM clipboard STA"
        };
        worker.SetApartmentState(ApartmentState.STA);
        worker.Start();
        _ = initialized.Wait(MaximumWaitMilliseconds);
    }

    public IntPtr OwnerWindow
    {
        get
        {
            if (!initialized.IsSet)
            {
                return IntPtr.Zero;
            }

            return Interlocked.CompareExchange(ref ownerWindow, IntPtr.Zero, IntPtr.Zero);
        }
    }

    public bool IsAvailable => OwnerWindow != IntPtr.Zero;

    public bool TryInvoke<T>(Func<T> action, CancellationToken token, out T result)
        => TryInvoke(_ => action(), token, out result);

    public bool TryInvoke<T>(
        Func<CancellationToken, T> action,
        CancellationToken token,
        out T result
    )
    {
        result = default!;
        if (Volatile.Read(ref disposed) != 0 || token.IsCancellationRequested)
        {
            return false;
        }

        using var linked = CancellationTokenSource.CreateLinkedTokenSource(token, shutdown.Token);
        var item = new ClipboardWorkItem<T>(action, linked.Token);
        try
        {
            if (!queue.TryAdd(item))
            {
                linked.Cancel();
                return false;
            }
        }
        catch (InvalidOperationException)
        {
            linked.Cancel();
            return false;
        }

        try
        {
            result = item.Completion.Task.WaitAsync(
                TimeSpan.FromMilliseconds(MaximumWaitMilliseconds),
                token
            ).GetAwaiter().GetResult();
            return true;
        }
        catch
        {
            linked.Cancel();
            return false;
        }
    }

    private void Run()
    {
        try
        {
            ownerWindow = CreateWindowEx(
                0,
                "STATIC",
                string.Empty,
                WindowStylePopup,
                0,
                0,
                1,
                1,
                MessageOnlyWindow,
                IntPtr.Zero,
                IntPtr.Zero,
                IntPtr.Zero
            );
        }
        catch
        {
            ownerWindow = IntPtr.Zero;
        }
        finally
        {
            initialized.Set();
        }

        try
        {
            while (!queue.IsCompleted)
            {
                if (queue.TryTake(out var item, MessagePumpIntervalMilliseconds))
                {
                    item.Execute();
                }

                while (PeekMessage(
                    out var message,
                    IntPtr.Zero,
                    0,
                    0,
                    PeekMessageRemove
                ))
                {
                    if (message.Message == WindowMessageQuit)
                    {
                        queue.CompleteAdding();
                        break;
                    }

                    _ = TranslateMessage(ref message);
                    _ = DispatchMessage(ref message);
                }
            }
        }
        finally
        {
            if (ownerWindow != IntPtr.Zero)
            {
                _ = DestroyWindow(ownerWindow);
                ownerWindow = IntPtr.Zero;
            }
        }
    }

    public void Dispose()
    {
        if (Interlocked.Exchange(ref disposed, 1) != 0)
        {
            return;
        }

        shutdown.Cancel();
        queue.CompleteAdding();
        var workerStopped = Thread.CurrentThread == worker
            || worker.Join(MaximumWaitMilliseconds);
        if (workerStopped)
        {
            shutdown.Dispose();
            queue.Dispose();
            initialized.Dispose();
        }
    }

    [DllImport("user32.dll", EntryPoint = "CreateWindowExW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateWindowEx(
        uint extendedStyle,
        string className,
        string windowName,
        uint style,
        int x,
        int y,
        int width,
        int height,
        IntPtr parent,
        IntPtr menu,
        IntPtr instance,
        IntPtr parameter
    );

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool DestroyWindow(IntPtr window);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool PeekMessage(
        out NativeMessage message,
        IntPtr window,
        uint minimumMessage,
        uint maximumMessage,
        uint removeMessage
    );

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool TranslateMessage(ref NativeMessage message);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr DispatchMessage(ref NativeMessage message);

    [StructLayout(LayoutKind.Sequential)]
    private struct NativePoint
    {
        public int X;
        public int Y;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeMessage
    {
        public IntPtr Window;
        public uint Message;
        public UIntPtr WParam;
        public IntPtr LParam;
        public uint Time;
        public NativePoint Point;
        public uint Private;
    }

    private interface IClipboardWorkItem
    {
        void Execute();
    }

    private sealed class ClipboardWorkItem<T> : IClipboardWorkItem
    {
        private readonly Func<CancellationToken, T> action;
        private readonly CancellationToken token;

        public ClipboardWorkItem(
            Func<CancellationToken, T> action,
            CancellationToken token
        )
        {
            this.action = action;
            this.token = token;
        }

        public TaskCompletionSource<T> Completion { get; } =
            new(TaskCreationOptions.RunContinuationsAsynchronously);

        public void Execute()
        {
            if (token.IsCancellationRequested)
            {
                Completion.TrySetCanceled(token);
                return;
            }

            try
            {
                Completion.TrySetResult(action(token));
            }
            catch (Exception ex)
            {
                Completion.TrySetException(ex);
            }
        }
    }
}
