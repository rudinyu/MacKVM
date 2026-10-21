namespace WindowsKVM;

/// <summary>
/// Suppresses startup and duplicate status notifications. The first visible
/// prompt can only follow a confirmed control grant, and an end prompt can
/// only follow that same active grant.
/// </summary>
internal sealed class ControlStatusNotificationPolicy
{
    private bool confirmedControlActive;

    public string? Observe(bool active)
    {
        if (active == confirmedControlActive)
        {
            return null;
        }

        confirmedControlActive = active;
        return active
            ? "Mac control is active on this Windows PC."
            : "Windows control has returned locally.";
    }
}
