[English](ROADMAP.md) · [繁體中文架構](ARCHITECTURE.zh-TW.md) · [繁體中文安裝指南](INSTALL.zh-TW.md)

# MacKVM 開發路線圖

本路線圖以 0.9.0 程式碼為基準。配對、公開金鑰釘選、加密連線、輸入驗證、
接收端明確同意、權限引導與有界佇列已完成；後續項目主要改善日常使用體驗。

## 目前狀態

| 領域 | 目前行為 |
| --- | --- |
| 輸入轉送 | 鍵盤（含跨配置重映射）、滑鼠、滾輪（含相位／慣性）與白名單媒體鍵；剪貼簿仍待補上 |
| 控制切換 | 選單請求，接收端 Allow／Deny，逾時 15 秒 |
| 游標對應 | 目前以主要顯示器為基準 |
| 裝置數量 | 一次一台 peer，使用 UUID 仲裁 |
| 螢幕切換 | 原生 DDC/CI：Apple Silicon 使用 IOAVService，Intel 使用 IOI2C；不支援時回到 OSD |

## 優先順序

| ID | 功能 | 影響 | 階段 |
| --- | --- | --- | --- |
| F1 | 剪貼簿同步 | 高 | P0 |
| F2 | 邊緣穿越與預先授權 peer | 高 | P0 |
| F3 | 媒體鍵與系統鍵轉送（已完成） | 高 | **完成** |
| F4 | 多螢幕游標對應 | 中 | P1 |
| F5 | 滾輪相位與慣性（已完成） | 中 | **完成** |
| F6 | 鍵盤配置重新映射（已完成） | 中 | **完成** |
| F7 | 原生 DDC/CI（已完成） | 中 | **完成** |
| F8 | 三台以上 Mac | 低 | P2 |
| F9 | Notarized 發佈與更新 | 低 | P2 |
| F10 | 連線診斷 | 低 | P2 |
| F11 | 觸控板手勢 | 中 | P3 |
| F12 | 檔案傳輸與拖放 | 低 | P3 |
| F13 | 喚醒睡眠中的 Mac | 低 | P3 |

## F7 原生 DDC/CI — 已完成

MacKVM 現在透過原生 IOKit bridge 探索外接顯示器，直接傳送 DDC/CI 的 VCP 0x60
輸入來源指令，不再啟動 Homebrew 工具或其他外部執行檔：

- Apple Silicon 透過顯示器的 `IOAVService` 寫入 DDC/CI。
- Intel 透過 `IOI2C` bus interface 寫入 DDC/CI。
- 顯示器選擇使用有界的原生識別碼，不再比對 MA270U 型號，也不接受會隨拓撲改變的
  數字索引。
- 若螢幕或線材沒有提供 DDC/CI，介面顯示診斷，使用者可明確改用螢幕 OSD。
- arm64 與 x86_64 都由同一份 Swift/C 原生橋接編譯，Intel 不再是手動切換專用路徑。

## F3、F5、F6 — 已完成

- **F3 媒體與系統鍵**：新增 `RemoteInputKind.systemDefined` 搭配白名單 `MediaKey`
  （音量、亮度、播放、換曲、鍵盤背光，共 13 個）。擷取端透過 `NSEvent(cgEvent:)`
  讀取 `NSSystemDefined`（`CGEventType` 沒有對應 case 的 raw type 14）的
  subtype／data1，只轉送 `NX_SUBTYPE_AUX_CONTROL_BUTTONS` 且在白名單內的按鍵。
  電源鍵與 Caps Lock 刻意排除——前者避免遠端觸發關機或睡眠，後者已經走
  `flagsChanged` 路徑。詳見 [`SECURITY.md`](SECURITY.md)。
- **F5 滾輪相位與慣性**：`RemoteInputEvent` 新增可選的 `scrollPhase`／
  `scrollMomentumPhase`，缺欄位代表「無相位」，滑鼠滾輪與舊版 peer 的封包完全不變；
  只有觸控板的相位捲動才會帶上這兩個欄位，讓接收端重現 macOS 慣性手感。
- **F6 鍵盤配置重新映射**：拆成兩個各自獨立的問題都已修正：
  1. 輸入法誤判斷線——原本讀 UserDefaults 的鍵盤配置實際上反映的是「輸入法」
     （如 `com.apple.inputmethod.TCIM.Zhuyin`），切注音就被誤判成配置改變。
     `KeyboardLayoutIdentifier.current()` 現在改用
     `TISCopyCurrentKeyboardLayoutInputSource`
     （[`CarbonKeyboardLayout.swift`](Sources/MacKVM/CarbonKeyboardLayout.swift)），
     回傳輸入法底下的實體硬體配置，切換輸入法不再影響這個值。
  2. 真正不同的實體配置——可重映射的按鍵（字母／數字／符號，`RemappableKeyCodes.all`，
     方向鍵、Return、Tab、所有修飾鍵都排除在外，因為這些鍵在任何配置下意義都相同）
     的 `keyDown` 現在會帶上寄送端配置產生的字元；接收端配置不同時，建立一份
     `KeyboardLayoutReverseMap`（每次配置變更才重建一次），查出本機哪個按鍵＋
     Shift／Option／Caps Lock 組合能產生相同字元，而不是照搬寄送端的 keyCode。
     Cmd／Control 原樣保留，應用程式快捷鍵不受影響。`ControlCoordinator` 不再因為
     配置不同就在請求階段直接拒絕；只有在某個按鍵真的在本機配置上找不到對應時，
     才會中止連線（沿用原本的保底行為）。

  reverse-map 的查表邏輯已有
  [`KeyboardLayoutRemapTests.swift`](Tests/MacKVMCoreTests/KeyboardLayoutRemapTests.swift)
  搭配假配置驗證；`UCKeyTranslate`／`TISCopyCurrentKeyboardLayoutInputSource`
  本身沒有實機無法測試，仍需要在兩台真正使用不同實體配置（不只是切輸入法）的 Mac
  上實測，確認 Shift／Option／Caps Lock 組合與 Cmd 快捷鍵都正確。

## 剩餘的 P0／P1

- **F1 剪貼簿同步**：初版只同步 `public.utf8-plain-text`，上限沿用 32 KiB，並拒絕
  帶有 `org.nspasteboard.ConcealedType` 的密碼管理器內容；功能預設關閉且需要使用者
  明確開啟。圖片與檔案留待 F12。
- **F2 邊緣穿越與預先授權**：目前仍需每次請求控制。邊緣穿越會改變控制同意模型，
  實作前需先記錄威脅模型與預先授權的撤銷方式，並保留
  `Control-Option-Command-Escape` 緊急返回。
- **F4 多螢幕游標對應**：目前只映射主要顯示器，其餘螢幕的座標會被夾到邊緣。需要
  交換兩端顯示器拓撲（各螢幕 bounds 與排列），把游標映射到對應的遠端螢幕。

## P2 剩餘項目

- F8 需要重新設計多 peer 仲裁與選單，不適合在雙 Mac MVP 前提下直接擴充。
- F9 在公開散布前需要 Developer ID、hardened runtime 與 Apple notarization。
- F10 加入延遲、jitter 與有界事件紀錄，避免支援只能依賴靜態資訊快照。

## P3 研究項目

觸控板手勢可能需要受限或私有 API；檔案傳輸會擴大攻擊面並需要分片與背壓；睡眠
喚醒則需要 Wake-on-LAN 或保持目標 Mac 喚醒。這些項目應先完成可行性研究再排期。

## 建議順序

F3、F5、F6、F7 都已完成。下一步是 **F1**：範圍獨立、不動控制狀態機，而且
F3／F5／F6 這幾次都是「新增一個 protocol 欄位」的形式，剪貼簿同步可以延續同樣的
節奏。

接著處理 **F2**——這是對使用體驗影響最大的一步，但因為會改動同意模型，動手前應該
先寫一份獨立的設計文件，討論安全性取捨。

P1 只剩 **F4**，等到有人掀著筆電螢幕用（而不是兩台都以 MA270U 當主螢幕）才會真的
浮現。兩台 Mac 都可先用 **Detect DDC-capable displays** 驗證螢幕，再使用原生
DDC/CI 切換輸入來源。
