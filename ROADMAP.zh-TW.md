[English](ROADMAP.md) · [繁體中文架構](ARCHITECTURE.zh-TW.md) · [繁體中文安裝指南](INSTALL.zh-TW.md)

# MacKVM 開發路線圖

本路線圖以 0.9.0 程式碼為基準。配對、公開金鑰釘選、加密連線、輸入驗證、
接收端明確同意、權限引導與有界佇列已完成；後續項目主要改善日常使用體驗。

## 目前狀態

| 領域 | 目前行為 |
| --- | --- |
| 輸入轉送 | 鍵盤、滑鼠與滾輪；媒體鍵仍待擴充 |
| 控制切換 | 選單請求，接收端 Allow／Deny，逾時 15 秒 |
| 游標對應 | 目前以主要顯示器為基準 |
| 裝置數量 | 一次一台 peer，使用 UUID 仲裁 |
| 螢幕切換 | 原生 DDC/CI：Apple Silicon 使用 IOAVService，Intel 使用 IOI2C；不支援時回到 OSD |

## 優先順序

| ID | 功能 | 影響 | 階段 |
| --- | --- | --- | --- |
| F1 | 剪貼簿同步 | 高 | P0 |
| F2 | 邊緣穿越與預先授權 peer | 高 | P0 |
| F3 | 媒體鍵與系統鍵轉送 | 高 | P0 |
| F4 | 多螢幕游標對應 | 中 | P1 |
| F5 | 滾輪相位與慣性 | 中 | P1 |
| F6 | 鍵盤配置重新映射 | 中 | P1 |
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

## 其餘 P0 項目

### F1 剪貼簿同步

初版只同步 `public.utf8-plain-text`，上限沿用 32 KiB，並拒絕帶有
`org.nspasteboard.ConcealedType` 的密碼管理器內容；功能預設關閉且需要使用者明確
開啟。圖片與檔案留待 F12。

### F2 邊緣穿越與預先授權

目前仍需每次請求控制。邊緣穿越會改變控制同意模型，實作前需先記錄威脅模型與
預先授權的撤銷方式，並保留 `Control-Option-Command-Escape` 緊急返回。

### F3 媒體與系統鍵

目前擷取遮罩只涵蓋一般鍵盤、滑鼠與滾輪。新增系統鍵時，應使用明確的 subtype／key
code allowlist，不可直接允許任意 `NSSystemDefined` 注入。

## P1 與 P2

- F4 交換兩端顯示器拓撲，將游標映射到對應螢幕。
- F5 傳送滾輪 phase 與 momentum phase，恢復 macOS 慣性手感。
- F6 以 `UCKeyTranslate` 支援輸入法切換；無法映射時保留目前的安全中止行為。
- F8 需要重新設計多 peer 仲裁與選單，不適合在雙 Mac MVP 前提下直接擴充。
- F9 在公開散布前需要 Developer ID、hardened runtime 與 Apple notarization。
- F10 加入延遲、jitter 與有界事件紀錄，避免支援只能依賴靜態資訊快照。

## P3 研究項目

觸控板手勢可能需要受限或私有 API；檔案傳輸會擴大攻擊面並需要分片與背壓；睡眠
喚醒則需要 Wake-on-LAN 或保持目標 Mac 喚醒。這些項目應先完成可行性研究再排期。

## 建議順序

先完成 F1 與 F3，再處理會改變同意模型的 F2；F4 至 F6 依實際使用痛點排序。F7
已完成，兩台 Mac 都可先用 **Detect DDC-capable displays** 驗證螢幕，再使用原生
DDC/CI 切換輸入來源。
