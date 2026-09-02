[English](CHANGELOG.md)

# 變更記錄

## 1.02.11（build 91）— 2026-09-02

本維護版新增跨平台除錯手冊，說明如何收集 macOS unified log、Windows console trace、網路／防火牆狀態與原生 DDC 報告，同時避免暴露私密憑證。

### 新增

- 說明 Windows 使用 console-only 模式收集 log，以及配對、Secure Connect 與控制權的預期檢查點。
- 說明 macOS `log stream`／`log show`、支援資訊匯出、mDNS 檢查與跨架構 DDC 診斷。

### 變更

- 將 MacKVM 與 WindowsKVM 版本 metadata 同步為 1.02.11／build 91。

## 1.02.10（build 90）— 2026-08-31

本維護版同步最新的跨 Mac 控制生命週期修正，同時保留 Windows companion 的變更。

### 修正

- 手動 `Control-Option-Command-K` 螢幕路由由使用者控制；結束該工作階段時只將鍵盤、滑鼠與觸控板控制權
  還回本機，不會意外觸發 DDC 螢幕輸入切換。
- 新增本機結束與 peer 結束手動螢幕工作階段的回歸測試。

### 變更

- 將 Windows 應用程式原始碼資料夾從 `WindowsKVM.App` 改名為
  `WindowsKVM.Desktop`，避免 macOS Finder 將追蹤中的原始碼誤認為應用程式 bundle。
  建置產物仍位於已忽略的 `dist/` 路徑。

## 1.02.09（build 89）— 2026-08-31

本版修正 Windows companion 在 P1／P2 review 中發現的問題。

### 修正

- 系統匣圖示維持 legacy callback contract，隱藏視窗仍可透過雙擊重新開啟，
  右鍵仍可顯示選單並結束程式。
- 只有明確的互動式同意才能替換已釘選的 Mac 公開金鑰；`--yes` 不再靜默替換金鑰。
- **Local Windows input only** 會停用遠端控制 admission，並立即釋放目前的 Windows 輸入控制權。

### 新增

- Windows UI 顯示所有已信任的 Mac，**Forget paired Mac** 會套用到目前選取的 peer，
  不再依賴不確定的清單順序。

## 1.02.08（build 88）— 2026-08-30

本版本為 Windows console CLI 新增檢查與移除已配對 Mac trust pin 的指令。

### 新增

- 新增 `--list-paired`，列出每個受信任 Mac 的友善名稱、完整 peer ID 與公開金鑰指紋。
- 新增 `--forget <peer-id>`，從 Windows trust store 移除指定 Mac；按 Connect 前必須重新 Pair。
- 文件說明 one-shot CLI 只會修改持久化 trust；若已有 receiver 在執行，請重新啟動它，或使用 UI 的
  Forget 動作關閉記憶體中的 active session。

## 1.02.07（build 87）— 2026-08-30

本版本加入 Windows 端的已配對 Mac 撤銷功能，避免 Forget 後留下過期 trust pin，導致下一次配對無法完成。

### 新增

- Windows UI 的 Simple mode 與 Advanced mode 都新增 **Forget paired Mac**。
- 以交易式方式從 `%LOCALAPPDATA%\\MacKVM\\trusted-peers.json` 移除選取的 Mac 公開金鑰，並關閉該 Mac 的既有 secure session。
- 啟動時載入既有 Windows trust list，因此重新啟動後仍可使用 Forget；Forget 後必須重新 Pair 才能 Connect。

## 1.02.06（build 86）— 2026-08-30

本版本讓 Mac identity 刻意重設後的重新配對變成明確且可檢查的流程，不再靜默取代已釘選的公開金鑰。

### 修正

- Secure Connect 遇到 peer key 改變時維持 fail closed。
- Windows UI 與 console 配對提示顯示取代警告；只有簽章驗證碼流程在本機獲得同意後才會取代舊 pin。

## 1.02.05（build 85）— 2026-08-30

本版本讓 Windows companion UI 能在小螢幕自動採用精簡版面，同時保留完整的 macOS 對齊診斷資訊。

### 新增

- 小螢幕自動啟用 Simple mode，並在標題列提供 Simple／Advanced 模式切換。
- Simple mode 保留 identity、就緒狀態、配對、控制權、防火牆、Refresh 與 Quit，不需長距離捲動。

## 1.02.04（build 84）— 2026-08-30

本版本讓 Windows companion UI 的資訊層級與 macOS 設定面板對齊，同時沿用相同的配對與
secure-session runtime。

### 新增

- 新增可捲動且與 macOS 對齊的 Windows 狀態面板，包含設定就緒狀態、實體輸入路徑、附近／已配對
  裝置、鍵盤滑鼠控制、螢幕說明與支援資訊區段。
- 新增原生狀態顏色、即時已配對 peer／控制狀態更新、Windows 防火牆設定入口，以及本機金鑰指紋顯示。
- 產生對應的 Windows x64 與 ARM64 UI 測試執行檔。

## 1.02.03（build 83）— 2026-08-27

本版本加入第一個可用的 Windows desktop host，同時保留 console 模式供自動化與診斷。

### 新增

- 新增原生 Win32 狀態視窗與常駐 Windows 系統匣圖示。
- 配對驗證與已認證控制同意改用原生 Windows Yes／No 對話框，不必保持 console 視窗開啟。
- 新增單一執行個體保護、關閉視窗隱藏到系統匣、明確 Quit 清理、runtime 狀態更新，以及公開的
  **複製支援資訊**。
- UI 與 CLI 共用同一套 runtime lifecycle，trust storage、mDNS 廣播、secure-session admission
  與 release-all teardown 在兩種模式保持一致。
- 新增最小權限與 per-monitor DPI 的 Windows application manifest。
- GitHub Actions 新增原生 Windows runner，驗證 x64 與 ARM64 兩種 desktop publish。

### 相容性

- Windows beta 仍不相容於 MacKVM 1.00.00；請使用會簽署 `disconnectSignalVersion` 的 Mac build
  （MacKVM 1.100.00／build 75 以上）。

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

- Windows beta 不相容於 MacKVM 1.00.00 正式版。
- 配對與 secure Connect 都需要包含簽名 `disconnectSignalVersion` capability 的 MacKVM build
  （MacKVM 1.100.00／build 75 加入）；舊 peer 會明確回報需要升級。

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
