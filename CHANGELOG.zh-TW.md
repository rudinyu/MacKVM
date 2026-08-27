[English](CHANGELOG.md)

# 變更記錄

## 1.02.02（build 82）— 2026-08-27

本次修補完成 network recovery、鍵盤配置切換、版本文件與回歸測試的最後整理。

### 修正

- Bonjour recovery 最多只排程五次；兩個 Bonjour 服務都實際 ready 後會重設退避週期。
- Carbon keyboard layout snapshot 暫時失效時，對需要重映射的 key-down、重複事件與
  對應 key-up 採 fail-closed，不再以可能錯誤的 raw keycode 傳送。
- 安裝手冊、驗收手冊與 Windows W3 文件同步到 1.02.02／build 82 及目前功能。

### 測試

- 新增重試上限／退避策略與 stale keyboard layout capture 的 deterministic regression tests。

## 1.02.01（build 81）— 2026-08-26

本版本讓 Windows W3 receiver 與目前 macOS secure-session contract 對齊，並把相對應的
macOS lifecycle 修正同步到 Windows 開發分支。

### 新增

- 兩端以獨立 handshake extension 簽名與驗證 `disconnectSignalVersion` secure-session capability。
- 交換已認證、加密的 disconnect 與 acknowledgement marker，刻意結束時不再退回語意不明的 EOF 關閉。
- 新增 Windows capability round-trip 與 exact control signal matching protocol self-test。
- 同步目前 Mac build line 所需的 macOS secure-session 睡眠／喚醒、disconnect policy、input topology、
  trackpad scroll 與 protocol tests。

### 修正

- Windows 認證輸入 session 改用每秒封包／位元組 rolling budget，不再累計 256 個封包後誤斷線。
- 修正 Apple function／navigation／keypad 到 Windows `SendInput` 的對應，包含 End、PageUp／PageDown、Forward Delete 與 F1–F20。
- Windows protocol 保留 scroll unit、phase、momentum 與 pointer pressure；pixel scroll 不再被放大成完整 120 單位滾輪。
- 同步 Windows hotkey teardown 狀態，且 secure Bonjour 的 listener 與 browser 都實際 `.ready` 後才重設 network recovery backoff。
- macOS 改用 notification-driven forward keyboard-layout cache，擷取每個 keyDown 不再查詢 Carbon。

### 相容性

- 簽章配對仍與 MacKVM 1.00.00 以上版本相容。
- Secure Connect 需要 MacKVM 1.100.00／build 75 以上；舊 peer 會明確回報需要升級。

## 1.01.02（build 79）— 2026-08-26

本次修補補齊 Windows W2 交付文件，並統一 macOS 與 Windows build metadata 中的版本。

### 文件

- 新增英文與繁體中文 WindowsKVM component README，說明 secure Connect、信任儲存、
  相容性、建置與測試步驟。
- 在 repository 根目錄文件加入 component README 連結。

## 1.01.01（build 78）— 2026-08-26

本次修補依 review 結果強化 Windows W2 secure-session responder。

- 限制未認證 secure-session 的連線嘗試，避免閒置 TCP client 佔滿八個 handshake slot。
- 以有上限的 batch drain 合併傳入的加密 frame；單次 read 超過 16 個 frame 不再誤斷線。
- pairing 與 secure-session responder 共用 ECDSA signing lock。
- Windows trust record 改為交易式寫入，且在送出最後 pairing-completion frame 前先持久化。
- 認證後的 partial frame 五秒後逾時，並將 mDNS／listener task 的非預期失敗回報到 console entry point。

## 1.01.00（build 77）— 2026-08-26

本次功能版本加入 Windows W2 secure Connect responder，並維持與 MacKVM 1.00.00
相容的簽章配對 protocol。

### 新增

- 廣播獨立的 `_mackvm-secure._tcp` service，只接受完成配對流程後記錄的 Mac
  公開 identity。
- 完成簽章的 ephemeral P-256 handshake，使用 HKDF-SHA256 產生雙向金鑰，並以
  ChaCha20-Poly1305 驗證加密 key confirmation 與序號防重播。
- 將已配對 Mac 的公開 identity 原子寫入
  `%LOCALAPPDATA%\MacKVM\trusted-peers.json`；identity key 改變時拒絕連線。
- 新增雙向加密、重播拒絕與竄改 handshake 的 protocol self-test。

### 限制

- Windows Raw Input／SendInput、加密 control message、tray UI、全域快捷鍵與最後的
  防火牆 UX 尚未在此 build 啟用。

## 1.00.02（build 76）— 2026-08-25

本次修補讓 Windows CLI 配對流程可觀察且更可靠。

### 修正

- 不再使用可能過時的 `TcpClient.Connected` 快照判斷已 accept 的配對連線；改以
  `ReadAsync` 的 EOF／錯誤結果判斷連線狀態。
- Windows CLI 會顯示傳入裝置、驗證碼與明確的 **Accept pairing?** 提示，並記錄每個
  收到的 pairing frame 與拒絕原因，方便排查防火牆與傳輸問題。

## 1.00.01（build 75）— 2026-08-25

本次修補強化 Windows 配對 scaffold 與本機驗證流程。

### 修正

- 序列化 Windows 第一次建立 identity 的流程，避免同時啟動 receiver 時互相覆寫
  憑證資料。
- 廣播所有實際可連線的 mDNS 位址 family，支援只有 IPv6 的區域網路；沒有可用的
  .NET SDK 時，macOS 本機 CI 仍可完成其餘檢查。
- 維持 Windows protocol 與 MacKVM 1.00.00 相容，同時保留有上限且安全的配對流程。

## 1.00.00（build 74）— 2026-08-24

這是 MacKVM 的第一個正式版本，包含 0.12.x 系列完成的安全配對、跨架構原生
DDC/CI、鍵盤／滑鼠交接、復原機制與權限感知控制流程。

### 修正

- 讓 `Control-Option-Command-K` 成為手動選擇螢幕輸入後的鍵盤／滑鼠控制切換鍵。它不再
  啟動先切螢幕的自動 DDC 路由；`Control-Option-Command-O` 負責自動切螢幕並同步交接
  螢幕與輸入。

## 0.12.31（build 71）— 2026-08-24

本版本整理 v0.12.4 之後的可靠性、螢幕路由與控制流程修正，並改善配對進行中的
操作提示。

### 配對與控制

- 將配對進度、接收端的 **Accept** 請求，以及發起端的 **Confirm code** 操作放在
  同一個選單頂部區塊。確認按鈕不再被螢幕與裝置區塊隔開，因此等待下一個操作時，
  兩步驟配對流程會清楚顯示，不會看起來像卡住。
- 強化配對完成與逾時處理；只有 request、peer、generation 都相符，且配對資料已
  保存後，才會把工作階段視為已配對。
- 讓 `Control-Option-Command-O` 先切換螢幕，再沿用 **Show other Mac** 的受保護
  控制交接與本機返回流程。
- 改善鍵盤／滑鼠返回路徑、緊急快捷鍵、建立輸入事件失敗時的輸入釋放，以及控制請求
  的狀態回饋。

### 可靠性與螢幕支援

- 加入有上限的網路服務恢復；只有真正 ready 才重置退避，並在熱插拔重新探索時保留
  已選取的螢幕路由。
- 讓選單列場景與主視窗共用設定狀態，並分開表示「登入時啟動」已啟用與等待核准。
- 驗證修飾鍵旗標、防止重複釋放 admission reservation，並拒絕無效的 peer arbitration
  輸入。
- 持續使用 Apple Silicon（`IOAVService`）與 Intel（`IOI2C`）的原生 DDC/CI，並提供
  跨架構診斷工具與更安全的螢幕選取。

### 文件與驗證

- 同步 app 版本、build 編號、DMG checksum 檔名、路線圖，以及英文／繁體中文 HTML
  和 Markdown 文件。
- 本機 CI 已通過 268 個測試，並成功建置 arm64 與 x86_64 app bundle。
