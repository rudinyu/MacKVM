[English](CHANGELOG.md)

# 變更記錄

## 1.100.05（build 80）— 2026-09-07

### 修正

- 為配對流程的 Accept 與 Confirm 階段提供獨立且有界的使用者決策逾時，並保留
  認證前傳輸階段較短的逾時限制。
- 已記錄 contribution 後忽略重複的 reveal 與 confirmation frame，避免未配對的
  request 無限延長佔用中的配對時段。

## 1.100.04（build 79）— 2026-09-04

### 新增

- 新增獨立的 Developer ID release script，會簽署 app 與 DMG、上傳 Apple
  notarization、staple 通過的 ticket、驗證結果，並在最後重新產生 checksum；
  repository 不會保存任何憑證。

### 變更

- 使用 Developer ID identity 時一律要求 secure timestamp；本機預設打包流程仍維持
  ad-hoc 簽章。

## 1.100.03（build 78）— 2026-09-04

### 修正

- 即使 peer 沒有本機鍵盤或滑鼠，也能透過有界 TCP keepalive 與傳輸可用性
  處理偵測加密工作階段遺失。stale session 會被清除，選取的 peer 不必手動按
  **Disconnect** 就能重新連線。

## 1.100.02（build 77）— 2026-08-31

### 修正

- 結束 `Control-Option-Command-K` session 時——不論用 K、Escape 或對端的返回
  動作——不再觸發 DDC 螢幕切換。手動螢幕 session 現在被標記為不管理螢幕路由，
  只有一般請求與合併流程（`Control-Option-Command-O`）會在控制結束時還原本機
  螢幕，符合 K「只移動輸入」的文件契約。
- 補上只有共用鍵盤時控制端第二次按下
  `Control-Option-Command-O` 的手動驗收流程，並註明接收端快捷鍵測試需要接有實體鍵盤。

## 1.100.01（build 76）— 2026-08-26

本修正版強化 1.100.00 發布後的跨 Mac 輸入與安全工作階段拆除流程。

### 修正

- 讓水平與垂直捲動增量符合遠端輸入協定攜帶的單一單位，也涵蓋傾斜滾輪事件。
- 對回報的指標 pressure 進行限制，不再丟棄可能造成遠端按鈕狀態不成對的事件。
- 配對完成與進行中的握手競態時保留重連意圖，並避免明確 disconnect 重新啟動正在進行的關閉流程。
- 即使已清除選取的 peer，也會在明確 disconnect 後抑制自動重連。

## 1.100.00（build 75）— 2026-08-26

本版本完成 Apple Silicon 與 Intel Mac 之間的本機鍵盤、滑鼠與觸控板共享，並保留
外接 USB 接線拓撲的既有說明與驗證。

### 修正

- 支援觸控板相容的指標輸入，包括點按、次要點按、硬體可提供時的拖曳壓力、高解析度
  雙軸滾動、滾動相位、慣性，以及 line／pixel 單位。
- 允許任一台 Mac 以本機鍵盤、滑鼠與觸控板發起控制；需要共享外接裝置時，仍另外驗證
  實體 USB switch 的接線拓撲。
- 避免休眠／喚醒拆除與明確 disconnect 處理讓 peer 工作階段或 Hotkey 路徑卡住。

## 1.00.00（build 74）— 2026-08-24

這是 MacKVM 的第一個正式版本，包含 0.12.x 系列完成的安全配對、跨架構原生
DDC/CI、鍵盤／滑鼠交接、復原機制與權限感知控制流程。

### 修正

- 讓 `Control-Option-Command-K` 成為手動選擇螢幕輸入後的鍵盤／滑鼠控制切換鍵。它不再
  啟動先切螢幕的自動 DDC 路由；`Control-Option-Command-O` 負責自動切螢幕並同步交接
  螢幕與輸入。
- 在系統休眠前關閉安全傳輸，並在喚醒後恢復原先選取的 peer，讓另一台 Mac 釋放遠端
  輸入，不會因半開工作階段而卡住 Hotkey 切換。

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
