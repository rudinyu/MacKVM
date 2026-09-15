namespace WindowsKVM;

/// <summary>
/// Owns the lifetime of consent requests independently from their Win32
/// presentation. Requests are serialized, cancellation wins over acceptance,
/// and completion always removes the request before the UI is dismissed. The
/// host supplies message-loop callbacks so no window is touched from a
/// receiver or cancellation thread.
/// </summary>
internal sealed class ConsentRequestCoordinator : IDisposable
{
    internal readonly record struct Prompt(long ID, string Text, string Title);

    private sealed class PendingRequest
    {
        public required long ID { get; init; }
        public required string Text { get; init; }
        public required string Title { get; init; }
        public required CancellationToken CancellationToken { get; init; }
        public required TaskCompletionSource<bool> Completion { get; init; }
        public CancellationTokenRegistration CancellationRegistration { get; set; }
        public bool CancellationRegistrationAssigned { get; set; }
        public bool Cancelled { get; set; }
    }

    private readonly object gate = new();
    private readonly Queue<long> queued = new();
    private readonly Dictionary<long, PendingRequest> pending = new();
    private readonly Func<long, bool> postRequest;
    private readonly Func<long, bool> postDismiss;
    private long nextID;
    private long activeID;
    private bool disposed;

    public ConsentRequestCoordinator(
        Func<long, bool> postRequest,
        Func<long, bool> postDismiss
    )
    {
        this.postRequest = postRequest;
        this.postDismiss = postDismiss;
    }

    public Task<bool> EnqueueAsync(
        string text,
        string title,
        CancellationToken token
    )
    {
        if (token.IsCancellationRequested)
        {
            return Task.FromResult(false);
        }

        PendingRequest request;
        lock (gate)
        {
            if (disposed)
            {
                return Task.FromResult(false);
            }

            request = new PendingRequest
            {
                ID = ++nextID,
                Text = text,
                Title = title,
                CancellationToken = token,
                Completion = new TaskCompletionSource<bool>(
                    TaskCreationOptions.RunContinuationsAsynchronously
                )
            };
            pending.Add(request.ID, request);
            queued.Enqueue(request.ID);
        }

        var registration = token.Register(
            static state =>
            {
                var callback = ((ConsentRequestCoordinator Coordinator, long ID))state!;
                callback.Coordinator.Cancel(callback.ID);
            },
            (this, request.ID)
        );

        var disposeRegistration = false;
        lock (gate)
        {
            if (pending.TryGetValue(request.ID, out var current)
                && ReferenceEquals(current, request))
            {
                request.CancellationRegistration = registration;
                request.CancellationRegistrationAssigned = true;
            }
            else
            {
                // Cancellation can run synchronously from Register when the
                // token became canceled between the initial check and here.
                disposeRegistration = true;
            }
        }

        if (disposeRegistration)
        {
            registration.Dispose();
        }

        // Posting is deliberately the last step. A cancellation that wins
        // before this call leaves no request for the UI to display; a stale
        // message is harmless because TryBeginNext checks the live table.
        if (IsPending(request.ID) && !postRequest(request.ID))
        {
            Cancel(request.ID);
        }

        return AwaitCompletionAsync(request);
    }

    /// <summary>
    /// Claims the next queued request for the UI thread. At most one prompt is
    /// active; canceled or already-completed IDs are skipped.
    /// </summary>
    public bool TryBeginNext(out Prompt prompt)
    {
        lock (gate)
        {
            if (disposed || activeID != 0)
            {
                prompt = default;
                return false;
            }

            while (queued.Count > 0)
            {
                var id = queued.Dequeue();
                if (!pending.TryGetValue(id, out var request)
                    || request.Cancelled)
                {
                    continue;
                }

                activeID = id;
                prompt = new Prompt(id, request.Text, request.Title);
                return true;
            }

            prompt = default;
            return false;
        }
    }

    /// <summary>
    /// Completes a live request. The lookup and cancellation check are
    /// serialized with cancellation so a late Yes can never revive an expired
    /// request or affect a newer prompt.
    /// </summary>
    public bool TryComplete(long id, bool accepted)
    {
        PendingRequest? request;
        var wasActive = false;
        lock (gate)
        {
            if (!pending.TryGetValue(id, out request))
            {
                return false;
            }

            // Cancellation callbacks are allowed to be delayed behind other
            // callbacks registered on the same token. Consult the token
            // itself at the acceptance boundary so a late Yes cannot win
            // merely because its callback has not run yet.
            if (request.Cancelled || request.CancellationToken.IsCancellationRequested)
            {
                request.Cancelled = true;
                accepted = false;
            }
            pending.Remove(id);

            if (activeID == id)
            {
                activeID = 0;
                wasActive = true;
            }
        }

        DisposeCancellationRegistration(request);
        request.Completion.TrySetResult(accepted);
        // Even a queued cancellation uses this callback as a UI pump. The
        // tray host dismisses only the matching active popup, then displays
        // the next still-live request.
        _ = postDismiss(wasActive ? id : 0);
        return true;
    }

    /// <summary>
    /// Expires a request from any thread. Cancellation marks the request
    /// before removal, making a concurrent UI acceptance fail closed.
    /// </summary>
    public bool Cancel(long id)
    {
        PendingRequest? request;
        var wasActive = false;
        lock (gate)
        {
            if (!pending.TryGetValue(id, out request))
            {
                return false;
            }

            request.Cancelled = true;
            pending.Remove(id);
            if (activeID == id)
            {
                activeID = 0;
                wasActive = true;
            }
        }

        DisposeCancellationRegistration(request);
        request.Completion.TrySetResult(false);
        _ = postDismiss(wasActive ? id : 0);
        return true;
    }

    public bool IsPending(long id)
    {
        lock (gate)
        {
            return pending.ContainsKey(id);
        }
    }

    public long ActiveRequestID
    {
        get
        {
            lock (gate)
            {
                return activeID;
            }
        }
    }

    public void Dispose()
    {
        List<PendingRequest> requests;
        long active;
        lock (gate)
        {
            if (disposed)
            {
                return;
            }

            disposed = true;
            active = activeID;
            activeID = 0;
            requests = pending.Values.ToList();
            pending.Clear();
            queued.Clear();
            foreach (var request in requests)
            {
                request.Cancelled = true;
            }
        }

        foreach (var request in requests)
        {
            DisposeCancellationRegistration(request);
            request.Completion.TrySetResult(false);
        }

        if (active != 0)
        {
            _ = postDismiss(active);
        }
    }

    private static async Task<bool> AwaitCompletionAsync(PendingRequest request)
    {
        try
        {
            return await request.Completion.Task.ConfigureAwait(false);
        }
        finally
        {
            // Completion removes the request; this is only a defensive no-op
            // for a host that shuts down between enqueue and message delivery.
        }
    }

    private static void DisposeCancellationRegistration(PendingRequest request)
    {
        if (request.CancellationRegistrationAssigned)
        {
            request.CancellationRegistration.Dispose();
            request.CancellationRegistrationAssigned = false;
        }
    }
}
