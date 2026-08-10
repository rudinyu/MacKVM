# Security status

[繁體中文](SECURITY.zh-TW.md) · [Installation guide](INSTALL.md) · [HTML manual](docs/USER_MANUAL.html)

MacKVM is an early local-network prototype. The current pairing handshake:

- requires explicit acceptance on both Macs before either peer is pinned;
- signs every pairing message with a P-256 device key;
- commits both Macs to independent random contributions before either
  contribution is revealed, then displays a six-digit code derived from those
  contributions and both device keys for users to compare;
- stores the private key in the macOS Keychain;
- pins the accepted public key to the peer UUID for future authentication.

The stored identity and Keychain private key must both exist and match. If
either item is missing or the public key does not match, MacKVM refuses to
replace the identity automatically; this prevents an incomplete Keychain
record from silently invalidating every pinned pairing.

Pairing uses signed completion and acknowledgement messages and waits for the
peer's final TCP half-close before persisting trust. This ensures each Mac has
evidence that its own completion reached the peer before it saves the pinned
key. As with any two-party protocol, a crash or final-packet loss can still
leave one side requiring a new pairing attempt; the user can forget that
partial record and pair again.

Pairing metadata and Bonjour device names remain visible on the local network.
After pairing, control-session payloads use an authenticated ephemeral P-256
key agreement, separate HKDF keys for each direction, ChaChaPoly authenticated
encryption, and strict sequence counters. A secure session is rejected unless
the signed handshake identity exactly matches the pinned public key. The
responder reports a session connected only after decrypting a fresh
key-confirmation packet, so replaying a captured signed hello is insufficient.

Remote input messages are decoded with a 16 KiB limit and strict event-specific
field validation before injection. Pointer coordinates and scroll values are
bounded, and injected events carry a private source marker so a listening peer
does not retransmit them. macOS still requires explicit Input Monitoring
permission to capture local input and Accessibility permission to inject remote
input. Pairing and secure-session wire frames are capped at 64 KiB, encrypted
session plaintext is capped at 32 KiB, and partial frames expire after five
seconds. Secure sessions also enforce bounded pending handshakes, payload
queues, and per-session packet/byte budgets; discovery applies connection and
message admission limits before decoding, including a 16-message cap per
pairing transport delivery. Pre-consent pairing keeps a separate one-request
unpaired budget and reserves the final global slot for an already-paired peer.
Secure Bonjour discovery filters candidates against the pinned key, retains a
bounded set of same-key endpoints, prefers the last endpoint that completed an
authenticated handshake, and advances to the next endpoint after any failed
or cleanly closed unauthenticated attempt. If the control or injection queue
cannot keep up, MacKVM tears down that session and releases all tracked keys
and mouse buttons instead of silently dropping a state-changing transition.

Input is never suppressed merely because the encrypted transport connected.
The controller first sends a control request, and the receiving Mac grants it
only while Accessibility permission is available. Simultaneous requests use
the paired UUIDs for deterministic arbitration. During control,
`Control-Option-Command-Escape` is consumed locally as an emergency return;
disconnect and control-end paths synthesize key-up and mouse-up events on the
receiver to avoid stuck input.

Selecting **Forget** removes the pinned public key synchronously before the
network cleanup queues run. In-flight pairing completions are generation
checked and remove the key again on the serialized discovery queue, so a peer
that is being forgotten cannot restore trust through a late completion or
reconnect during the cleanup race. The secure-session service also cancels
anonymous, unauthenticated handshakes during this operation: until the first
signed handshake identifies a peer, the context cannot be safely attributed to
another device. This can briefly interrupt an unrelated handshake, but it
prevents a revoked peer from winning an attribution race and is immediately
recoverable by reconnecting.
