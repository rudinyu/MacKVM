[English](SECURITY.md) · [安裝指南](INSTALL.zh-TW.md) · [HTML 手冊](docs/USER_MANUAL.zh-TW.html)

# MacKVM 安全狀態

MacKVM 是使用於可信任本機網路的早期原型。安全性依賴兩台 Mac 的明確配對、
已釘選的公開金鑰、加密控制通道，以及接收端每次控制請求的使用者同意。

## 配對與信任

- 每台 Mac 的 UUID 與 P-256 簽署金鑰由本機產生；私密金鑰只存於 macOS Keychain。
- 每個配對訊息都用裝置金鑰簽署，雙方先交換 commitment，再揭露隨機貢獻。
- 使用者比對由貢獻、request UUID、角色與兩把公開金鑰計算出的六位數驗證碼，兩端
  都按 **Accept** 後，公開金鑰才會綁定到 peer UUID。
- 已完成的訊息與 TCP half-close 都會驗證；遲到或重複的配對完成不能恢復被 Forget
  的信任。
- 後續 secure session 使用簽署的短期 P-256 金鑰交換、方向分離 HKDF、ChaChaPoly
  與嚴格序號。對方身份若不符合釘選公開金鑰，握手會被拒絕。

## 輸入控制與權限

加密連線完成不等於取得控制權。控制端必須送出 request，接收端通常按 **Allow** 後才
會抑制本機鍵盤／滑鼠並注入遠端事件。新配對完成後，接收端會對該已釘選 peer 啟用
`seamlessControlAuthorized` 本機一次性授權，讓同一條已驗證請求可沿用相同的 Accessibility
檢查與安全接受流程而不再跳提示；使用者可在 **Paired device information** 逐台關閉。
這個旗標不會放進網路訊息，Forget 或金鑰撤銷時會和 profile 一起移除。**Deny**、
**Return keyboard and mouse to [M5 Mac]**、網路中斷、Quit 與
`Control-Option-Command-Escape` 都會釋放
按住的按鍵和滑鼠按鈕。
`Control-Option-Command-K` 是本機消費的鍵盤／滑鼠路由切換快捷鍵，適用於手動選好的螢幕輸入，
不會啟動自動 DDC 螢幕路由，也不會傳送到遠端。

- Input Monitoring 只用於控制端擷取本機事件。
- Accessibility 只用於接收端注入遠端事件。
- 通知動作帶有 request ID 與裝置本機 nonce；逾時或過期的通知不能套用到新請求。
- keyboard layout、輸入事件欄位、座標、滾輪與封包大小都會在注入前重新驗證。

## 網路與可用性防護

- 配對與 secure-session frame 上限為 64 KiB；加密 session plaintext 上限為 32 KiB。
- 不完整 frame 五秒後逾時，連線數、訊息數、payload queue、封包與 bytes 都有上限。
- Bonjour 候選、同一 UUID 的 endpoint 與未配對請求都使用 bounded admission。
- 安全連線只接受已釘選金鑰；同一金鑰的多個 Bonjour endpoint 也會限制數量並在
  認證成功後偏好最後可用 endpoint。
- 控制或注入 queue 無法跟上時會結束 session 並釋放狀態，不靜默丟失 key-up 或
  mouse-up。

## 配對資料與支援資訊

Bonjour 上可看到裝置名稱、型號、UUID 與公開金鑰。配對後本機保存友善名稱、型號、
最後成功連線時間與公開金鑰的 SHA-256 指紋；指紋只供人工辨識，不取代實際的公開
金鑰驗證。

**Copy support information** 只複製版本、作業系統、公開裝置資料、UUID、指紋與
連線狀態，不包含私密金鑰、密碼、憑證或網路端點。貼到公開論壇或客服表單前，仍應
自行檢查是否有不想公開的裝置名稱。

## 原生 DDC 診斷工具

repository 的 `Tools/DDCDiagnostic` 是本機獨立工具，不會開啟網路 listener，也不會
讀取 MacKVM 身份紀錄、私密金鑰、密碼、憑證或網路端點。它只輸出系統 metadata、EDID、
原生顯示器 selector、transport 與 DDC/CI 值；一般模式是唯讀。

`--scan-inputs` 是明確的硬體變更操作，只允許寫入 VCP `0x60`，接受有界候選值，逐一
讀回，並還原開始時讀到的輸入。讀回相同才算螢幕接受該值；I2C 寫入成功本身不是證據。
使用者必須只在可以安全切換的螢幕執行，並自行確認還原成功。工具不會自動把發現的
mapping 寫入 app 或 repository。Ctrl-C 或 SIGTERM 會停止候選值迴圈並仍嘗試還原開始前
的輸入；SIGKILL 等無法攔截的終止則無法保證還原。

## 已知邊界與發佈要求

MacKVM 假設兩台 Mac 位於使用者信任的本機網路；Bonjour metadata 會在區域網路可見。
app 無法從軟體完全驗證實體 USB switch 是否存在，也無法代替使用者確認線材、螢幕
OSD 與 DDC/CI 的實體狀態。

ad-hoc 簽章只適合開發與本機測試。跨電腦正式散布應使用 Developer ID Application、
hardened runtime 與 Apple notarization；簽章、notarization、Keychain 或 API 憑證
不應提交到 repository。

若發現疑似安全問題，請先保留最少必要的重現資訊，不要在公開 issue 貼出私密金鑰、
密碼、完整支援報告或其他憑證資料。
