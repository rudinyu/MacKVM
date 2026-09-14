[English](CHANGELOG.md)

# 變更記錄

## WindowsKVM 1.02.25（build 105）— 2026-09-14

本次 Windows 專用 UI 微調讓預設的 Simple 模式可在單一視窗檢視區完整顯示，並同步縮小兩種模式的字級，讓狀態面板更精簡易讀。

### 變更

- 壓縮 Simple 版面與操作列，正常的 520x480 視窗可一次顯示必要的設定、配對、控制與輸入路徑資訊，不需用滑鼠滾輪。
- 統一縮小 Simple 與 Advanced 的標題、區段、本文、說明及等寬字型，同時保留窄螢幕的響應式重新排列。

### 驗證

- 仍須通過 Windows x64／ARM64 cross-build 與既有 desktop self-test；原生 DPI 顯示仍需在 Windows 實機驗收。

## WindowsKVM 1.02.24（build 104）— 2026-09-14

本次 Windows 專用 UI 微調讓 Advanced 模式更窄，並為常駐狀態視窗統一低飽和、易閱讀的視覺樣式。

### 變更

- 縮小 Advanced 畫布並重新排列狀態、輸入路徑、配對與操作列，讓詳細畫面在筆電螢幕上更容易完整顯示。
- 以 slate 背景、柔和分隔線，以及清楚區分的主要、次要、成功與警告文字色彩取代舊版白色靜態控制項的強烈對比。
- 啟用原生 Windows common-controls 視覺樣式，讓按鈕、核取方塊與下拉清單維持一致的原生外觀與既有 Win32 行為。

### 驗證

- 仍須通過 Windows x64／ARM64 cross-build 與既有 desktop self-test；原生 DPI 顯示仍需在 Windows 實機驗收。

## WindowsKVM 1.02.23（build 103）— 2026-09-14

本次 Windows 專用 UI 修正 Advanced 模式在 receiver 啟動並更新連接埠後的狀態文字顯示。
執行期資訊現在固定在三行內，避免連接埠或指紋內容溢出而覆蓋狀態列。

### 修正

- 將版本、型號、裝置 ID 與 TCP endpoint 放在有界的標題區塊；完整金鑰指紋仍保留在
  **Paired device information** 與 **Copy support information**。
- 修正 receiver 更新連接埠後，`Remote keyboard and mouse input enabled.` 狀態文字被裁切或覆蓋的問題。

### 驗證

- 仍須通過 Windows x64／ARM64 cross-build 與既有 desktop self-test；原生 DPI 顯示仍需在 Windows 實機驗收。

## WindowsKVM 1.02.22（build 102）— 2026-09-14

本次 Windows 專用 UI 修正避免 Advanced 模式的**已配對裝置資訊**中，本機金鑰指紋被截斷或被下一列覆蓋。
指紋現在使用固定斷行並配置可適應 DPI 的高度，後續控制項也會在下方重新排列。
macOS 程式碼、macOS 版本資訊與通訊協定均保持不變。

### 修正

- 在固定邊界換行 SHA-256 指紋，並增加原生標籤高度，完整指紋不會再被 DPAPI 說明文字蓋住。
- 同步調整 Advanced 內容高度與分隔線位置，確保展開後的指紋區塊與後續控制項保持間距。

### 驗證

- 仍須通過跨平台測試與 Windows x64／ARM64 建置；原生 Windows DPI 顯示仍需在目標螢幕實機驗收。

## WindowsKVM 1.02.21（build 101）— 2026-09-14

針對 **1.02.09（build 89）Beta 3** 實機測試回報修正 Windows UI。
本版也包含下列後續修正；macOS 版本資訊與通訊協定不變。

### 修正

- 捲動或調整大小時丟棄子視窗的舊像素，並整批重繪父視窗、子元件及邊框。
  Beta 3 逐個搬動子元件、僅標記父視窗重繪，會留下重複文字殘影。
- 分開處理下拉清單的原生展開高度與畫面收合列高；捲動、縮放或切換模式後仍保留展開空間。
  遠端輸入與僅使用本機輸入兩個選項均可選取；較長的已信任裝置清單使用有捲軸的有限高度清單。
- 視窗標題、主標題與隱藏至系統匣提示統一使用 **WindowsKVM**。
  窄視窗將模式按鈕移到較長的產品名稱下方。

### 驗證

- 新增跨平台回歸測試：捲動／縮放序列、不同選項列高、長裝置清單與窄版標題配置。
- 原生捲動、下拉選取及 DPI 顯示仍需 Windows x64／ARM64 桌面驗收；交叉建置不能代替畫面驗證。

## WindowsKVM 1.02.20（build 100）— 2026-09-12

本次為 Windows 專用維護更新，修正輸入、控制權生命週期及同意對話框的 review 問題。
macOS 程式碼、macOS 版本資訊與通訊協定均保持不變。

### 修正

- 原生 key-up 失敗時保留按鍵追蹤，讓控制權收尾可以再次釋放，避免修飾鍵在沒有補送的情況下持續按住。
- 忽略已結束控制請求中仍在傳送的合法輸入，不因此關閉安全連線。已結束請求的記錄有數量上限；
  未知 request ID 仍視為協定錯誤。
- 切換成僅使用本機輸入時結束目前授權並通知 Mac。快速重新啟用遠端輸入，不會恢復舊授權，
  也不會讓停用前仍在等待的同意請求取得控制權。
- 長按產生的重複 key-down 會沿用首次按下時的按鍵映射並繼續轉送。
- Mac button 2 正確對應滑鼠中鍵、3 對應 XBUTTON1、4 對應 XBUTTON2，並同步修正釋放清理；
  不支援的額外按鍵會安全忽略。
- 安全忽略尚未支援的亮度與鍵盤背光按鍵，不再觸發無關的 Windows 媒體或開啟程式動作。
- UI 同意對話框依請求身分逐一顯示，取消或逾時時會關閉，避免過期提示被同意或擋住後續請求。
- UI 與 console 接收器共用單一執行個體限制，不再從不同連接埠公告相同身分；
  查詢版本及管理配對裝置的一次性指令仍可使用。
- 將 Simple mode 縮為精簡狀態面板，例行診斷與完整身分資訊移至 Advanced mode；
  移除主視窗中重複的 Open window 按鈕，並將視窗限制在可用工作區內。
  調整大小時重新排列 Simple 控制項；較窄的 Advanced 視窗提供橫向捲動，保留完整大小的設定控制項。
  拖曳縮小時保留最小可操作尺寸，避免 Simple 控制項在極窄視窗中重疊。

### 測試與文件

- 在既有 protocol self-test 之外新增桌面回歸測試，以模擬的原生 API 驗證實際輸入與接收器流程。
- 補上 Windows x64／ARM64 實機驗收，以及 UI 與 console log 模式切換時避免重複啟動接收器的說明。

## 1.02.19（build 99）— 2026-09-05

本跨平台維護版讓 Windows secure-session receiver 具備與 MacKVM 相同的有界 peer
存活偵測行為。

### 修正

- Windows secure session 啟用 TCP keepalive（閒置五秒、probe 間隔兩秒、最多三次），並加入
  短暫的 socket liveness grace period。peer 進入休眠、被強制結束或網路路徑遺失時，現在會
  釋放 Windows 鍵盤／滑鼠控制權，不需手動重啟即可重新連線。
- 新增可重現的 Windows protocol 測試驗證 Winsock keepalive 設定，同時保留既有簽名 disconnect
  capability 與 wire 相容性。

## 1.02.18（build 98）— 2026-09-05

本維護版讓 peer 在沒有應用層流量時消失，仍能清除已認證的 stale secure session。

### 修正

- 為 secure session 啟用有界 TCP keepalive 與 Network.framework 傳輸可用性處理。peer 被強制結束、
  進入休眠或網路路徑遺失時，現在會清除舊 session，不需手動按 **Disconnect** 即可重新連線。
- 新增「控制端沒有本機鍵盤／滑鼠」的實機驗收覆蓋，確認 stale session 清理與重連流程。

## 1.02.17（build 97）— 2026-09-05

本維護版擴充合併 O 快捷鍵與手動 K 螢幕路由的驗收覆蓋範圍。

### 測試與文件

- 新增 controller 端與接收端第二次按 O 的檢查，確認螢幕與鍵盤／滑鼠控制權會正確返回。
- 明確記錄用 K、Escape 或對端 Return 結束手動 K session 時，不得觸發 DDC 切換，也不得改變手動選好的輸入。

## 1.02.16（build 96）— 2026-09-05

本維護版修正 Windows trust store 回復與系統匣視窗可見性的競態，並釐清控制同意的保存規則。

### 安全性

- Trust store 更新或回復失敗時會使快取的檔案 stamp 失效，避免拒絕的金鑰替換在另一個 process
  修改持久化決定後，仍沿用過期的控制授權。

### 修正

- 批次 Win32 重繪期間保存 parent 與 child 的可見狀態；重新啟用 `WM_SETREDRAW` 後，隱藏的系統匣
  視窗與未使用的 Simple／Advanced controls 不會再次顯示。
- 文件明確說明互動式配對會保存自動控制授權，而控制對話框的 **Allow** 與測試專用 `--yes`
  配對只適用於單次請求。

## 1.02.15（build 95）— 2026-09-04

本安全性維護版修補 Windows companion 的授權與生命週期競態，以及 Mac
輸入發送端的 session 清理問題。

### 安全性

- Windows 記住的控制授權會綁定已驗證的 Mac 公開金鑰，啟用前再次檢查金鑰；替換金鑰時撤銷既有
  session，避免舊 session 繼承新金鑰的授權。執行中的 receiver 會在輸入傳送期間重新整理持久化
  trust，因此跨 process 的 Forget、金鑰替換或 deny 不會讓舊 session 繼續有效。
- 互動式控制同意維持一次性；只有明確的配對裝置設定或 `--allow-control` 才會保存自動同意。
  無人值守的 `--yes` 配對不會保存這項授權；舊 trust 檔案在使用者明確選擇前會保持未設定。
- 忘記受信任 peer 或替換其金鑰時，立即釋放目前的 Windows 輸入控制權。

### 修正

- Mac 每次控制 session 狀態轉換都會清除延遲中的指標快照，並避免 coalescer 在結束時發生佇列自我死結。
- Windows 系統匣狀態合併更新時保留並行到達的最新狀態，不會遺失 UI 刷新通知。

## 1.02.14（build 94）— 2026-09-04

本維護版改善滑鼠指標回應，並讓 Windows companion 在配對與控制狀態快速變更時保持穩定。

### 修正

- Mac 發送端在有界的四毫秒 flush 視窗內合併連續的絕對滑鼠移動快照。鍵盤、按鍵、滾輪與生命週期訊息仍維持順序；secure connection 結束時會丟棄待送移動，避免舊指標事件漏到新 session。
- Windows 配對與 runtime 狀態 callback 不再直接碰 Win32 control；網路 callback 先排入 UI message loop，快速連續更新只套用最新狀態。
- Windows 捲動與 Simple／Advanced mode 切換改用批次 child-window 定位，交易期間暫停重繪，最後以 composited parent 搭配立即的完整 child redraw，避免列內容撕裂或只繪出一部分。

## 1.02.13（build 93）— 2026-09-04

本功能版讓使用者完成配對後，Windows 端的受信任控制預設可以無縫使用。

### 新增

- 每個新釘選的 Mac 公開金鑰預設啟用自動控制同意，後續控制切換不再被重複的確認對話框阻塞。
- Windows UI 保留 **Automatically allow control from this paired Mac** 設定，console 也保留
  `--allow-control`／`--deny-control` 指令，可關閉或恢復無縫控制。

### 安全性

- 將控制同意與配對 trust 分開保存；**Forget** 或明確同意替換公開金鑰時會先清除舊授權，
  新金鑰再依預設策略取得授權。
- 每次控制請求前重新載入原子寫入的 trust snapshot，因此可由另一個 CLI process 撤銷或恢復本機決定，
  且不會暴露 private key。測試專用的 `--yes` 仍是一次性選項，不會保存。

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
