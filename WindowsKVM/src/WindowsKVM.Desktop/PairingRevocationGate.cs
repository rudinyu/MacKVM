namespace WindowsKVM;

/// <summary>
/// Orders pairing persistence against Forget. A pairing captures the peer
/// revocation generations when its connection starts; Forget advances that
/// peer's generation before deleting trust. A late completion from an older
/// connection can therefore never recreate the forgotten pin.
/// </summary>
internal sealed class PairingRevocationGate
{
    private readonly object sync = new();
    private readonly Dictionary<Guid, long> generations = new();

    public IReadOnlyDictionary<Guid, long> CaptureSnapshot()
    {
        lock (sync)
        {
            return new Dictionary<Guid, long>(generations);
        }
    }

    public void Revoke(Guid peerID)
    {
        if (peerID == Guid.Empty)
        {
            return;
        }

        lock (sync)
        {
            generations.TryGetValue(peerID, out var generation);
            generations[peerID] = unchecked(generation + 1);
        }
    }

    public bool TryCommit(
        Guid peerID,
        IReadOnlyDictionary<Guid, long> snapshot,
        Action commit
    )
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        ArgumentNullException.ThrowIfNull(commit);
        lock (sync)
        {
            snapshot.TryGetValue(peerID, out var capturedGeneration);
            generations.TryGetValue(peerID, out var currentGeneration);
            if (capturedGeneration != currentGeneration)
            {
                return false;
            }

            // Keep the gate through durable trust persistence. If Forget wins
            // first, this callback is rejected; if this callback wins first,
            // Forget runs afterward and removes the resulting record.
            commit();
            return true;
        }
    }
}
