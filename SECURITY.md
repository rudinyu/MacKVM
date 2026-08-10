# Security status

MacKVM is an early local-network prototype. The current pairing handshake:

- requires explicit acceptance on both Macs before either peer is pinned;
- signs every pairing message with a P-256 device key;
- commits both Macs to independent random contributions before either
  contribution is revealed, then displays a six-digit code derived from those
  contributions and both device keys for users to compare;
- stores the private key in the macOS Keychain;
- pins the accepted public key to the peer UUID for future authentication.

## 繁體中文安全說明

MacKVM 是在本機網路使用的早期原型。以下摘要說明信任邊界、資料保存方式與
使用者需要注意的安全行為；英文段落保留較完整的協定細節。

### 配對與信任

- 每台 Mac 的 UUID 與 P-256 私密金鑰由本機產生，私密金鑰只存於 macOS Keychain。
- 配對訊息皆簽署，雙方必須核對相同的六位數驗證碼並明確接受，公開金鑰才會
  綁定到 peer UUID。
- 後續連線會驗證簽署的短期金鑰交換、使用方向分離的 HKDF 金鑰與 ChaChaPoly，
  並拒絕不符合已釘選公開金鑰的對端。重放舊握手不能直接建立新會話。
- 按 **Forget** 會先同步移除公開金鑰，再清理連線與未完成配對，避免舊信任被
  延遲的完成訊息恢復。

### 輸入控制與權限

加密連線建立不代表自動取得控制權。控制端必須送出請求，接收端按 **Allow** 後
才會抑制本機輸入並注入遠端事件；**Deny**、**Stop remote control**、網路中斷與
緊急快捷鍵都會釋放按住的按鍵／滑鼠按鈕。Input Monitoring 只用於本機擷取，
Accessibility 只用於接收端注入，兩項 macOS 權限都由使用者授予。

### 配對資料與支援資訊

Bonjour 上可看到裝置名稱、型號、UUID 與公開金鑰。配對後本機另存友善名稱、型號、
最後成功連線時間與公開金鑰的 SHA-256 指紋；這些資料用於辨識與支援，不取代真正
的公開金鑰驗證。**Copy support information** 只複製版本、作業系統、公開裝置資料
與連線狀態，不包含私密金鑰、密碼、憑證或網路端點；貼到公開地方前仍應自行檢查。

### 已知邊界

本工具假設兩台 Mac 位於使用者信任的本機網路。Bonjour 名稱與配對 metadata 會在
區域網路可見；實體 USB switch 是否真的存在、螢幕線材與 DDC/CI 是否正確，app
無法從軟體完全驗證。正式跨電腦散布應使用 Developer ID、hardened runtime 與
Apple notarization；ad-hoc 簽章只適合開發與本機測試。

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
