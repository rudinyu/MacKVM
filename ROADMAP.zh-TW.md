[English](ROADMAP.md) · [繁體中文架構](ARCHITECTURE.zh-TW.md) · [繁體中文安裝指南](INSTALL.zh-TW.md)

# MacKVM 開發路線圖

本路線圖以 0.12.33 程式碼為基準。配對、公開金鑰釘選、加密連線、輸入驗證、
接收端明確同意、權限引導與有界佇列已完成；後續項目主要改善日常使用體驗。

## 目前狀態

| 領域 | 目前行為 |
| --- | --- |
| 輸入轉送 | 鍵盤（含跨配置重映射）、滑鼠、滾輪（含相位／慣性）與白名單媒體鍵；剪貼簿仍待補上 |
| 配對傳輸 | 任一台 Mac 都可發起；Firewall／listener 等待中的配對可取消並重試，不必重啟 App |
| 控制切換 | 新配對 peer 使用本機一次性授權；關閉授權時仍是 Allow／Deny、逾時 15 秒 |
| 游標對應 | 目前以主要顯示器為基準 |
| 裝置數量 | 一次一台 peer，使用 UUID 仲裁 |
| 螢幕切換 | 原生 DDC/CI：Apple Silicon 使用 IOAVService，Intel 使用 IOI2C；不支援時回到 OSD |
| DDC 診斷 | 跨架構 CLI 輸出系統／EDID／transport／VCP 資料，並可讀回驗證與還原 VCP 0x60 mapping |

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

repository 另提供獨立的
[`Tools/DDCDiagnostic/ddc-diagnostic.m`](Tools/DDCDiagnostic/ddc-diagnostic.m)。它可建置
arm64、x86_64 或 universal，輸出執行／編譯架構、Mac 與 macOS 身份、EDID/checksum、
原生 transport 與 VCP `0x60` 狀態。明確啟用 `--scan-inputs` 時會寫入候選值、讀回驗證，
只將相同讀值標記為 accepted，最後還原原本輸入。這能產生可重現的型號 mapping 證據，
不會把 I2C 傳輸成功誤當成韌體一定接受。本專案實測 MA270U 使用 USB-C `19`（`0x13`）
與 HDMI 1 `17`（`0x11`）；其他型號請用自己的報告與掃描確認。

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
     `KeyboardLayoutReverseMap`（每次配置變更才重建一次），查出本機哪個按鍵能產生
     相同字元，而不是照搬寄送端的 keyCode。之後怎麼決定要送出去的 flags，看有沒有
     按著 Cmd 或 Control：一般打字時，Shift／Option／Caps Lock 會換成本機配置產生
     該字元所需的組合；按著 Cmd 或 Control 的按鍵，查表時固定用「無 Shift、無
     Option、無 CapsLock」的基礎字元去找——Shift 跟 CapsLock 完全不影響查到哪個
     按鍵——而寄送端原本的 flags（包含真的按著的 Shift，這會決定選到 Redo 還是
     Undo 這類不同快捷鍵）原封不動送出去，只有 keyCode 是查表來的。這樣 Cmd-Z
     在字母位置真的不同的配置（例如 Y／Z 互換的德文 QWERTZ）才會落在真正打得出
     "z" 的鍵上，同時又不會因為寄送端 CapsLock 剛好開著，就把 Cmd-C 誤植成
     Cmd-Shift-C。`ControlCoordinator` 只有在請求方的協定版本低於支援重映射的 v2
     時，才會因配置不同直接拒絕（v1 peer 不會送字元欄位，硬放行只會在第一個可
     重映射按鍵時中斷連線）；v2 peer 配置不同不會被拒絕，交給 `RemoteInputSink`
     處理，只有在某個按鍵真的在本機配置上找不到對應時才會中止連線（沿用原本的
     保底行為）。按住某鍵觸發的 macOS 自動連發（auto-repeat）會沿用第一次
     keyDown 算出的結果，不會每次連發都重算——避免連發中途修飾鍵改變導致目標
     按鍵被換掉，原本按下的鍵收不到對應的放開事件而卡住。

  上線前兩輪 review 一共抓到 5 個真實的問題，都已修正：v1 peer 配置不同時會先
  授權、第一個可重映射按鍵才中斷（改用上述協定版本檢查修正）；auto-repeat 可能
  換掉重映射目標導致卡鍵（改用上述「沿用第一次結果」修正）；`UCKeyTranslate`
  原本固定傳入鍵盤類型 `0`，在 ISO／JIS 等非 ANSI 實體鍵盤上會悄悄選錯對應表
  （改成讀取 `LMGetKbdType()`）；Cmd／Control 快捷鍵則是修了兩次——第一次發現
  會被 Caps Lock 或 Option 影響變成別的快捷鍵，當時的修法是完全跳過重映射；
  結果第二次發現這樣反而會在字母位置真的不同的配置上打錯鍵（因為跳過重映射
  連 keyCode 翻譯也一起跳過了），最後改成上述「只重映射 keyCode、flags 完全
  不動」的做法才兩個問題一起解決。

  reverse-map 的查表邏輯已有
  [`KeyboardLayoutRemapTests.swift`](Tests/MacKVMCoreTests/KeyboardLayoutRemapTests.swift)
  搭配假配置驗證。第三輪 review 又抓到兩個問題：

  - `RemoteInputSink` 這層的 remap 解析邏輯（`KeyInjectionTarget`、
    `resolveKeyInjectionTarget`、`computeKeyInjectionTarget`、`eventFlags` 的
    remap 分支）原本全部是 `private`，`@testable import MacKVM` 完全碰不到——
    偏偏這正是前面 5 個真實 bug 藏身的地方。改成 internal 可見度，並新增
    [`RemoteInputSinkKeyRemapTests.swift`](Tests/MacKVMTests/RemoteInputSinkKeyRemapTests.swift)，
    搭配假的 `KeyboardLayoutProviding` 涵蓋 auto-repeat 沿用結果、快捷鍵／一般
    打字的 flags 分流、以及查不到對應字元時回傳 nil 這幾條路徑，不用依賴跑測試
    的機器實際裝了什麼鍵盤配置。
  - `RemoteInputSink` 是從背景的注入佇列呼叫 `CarbonKeyboardLayout`，但擷取端
    是從主執行緒（event tap callback 裡）呼叫同一批 Text Input Source API——
    Apple 沒有文件保證這些 API 執行緒安全，兩條執行緒同時碰 Carbon 的 TIS 狀態
    是真實的當機／卡住風險。現在改成透過可替換的 `KeyboardLayoutProviding`
    取得鍵盤配置，正式環境的實作 `CarbonKeyboardLayoutProvider` 用
    `DispatchQueue.main.sync` 把每次呼叫都轉送到主執行緒；同一個介面也是讓
    上面新測試能塞假配置進去的原因。

  另外還有一個不影響安全性、只值得記一筆的邊角案例：`UCKeyTranslate` 用
  `kUCKeyTranslateNoDeadKeysBit` 執行，所以重映射後的按鍵有可能剛好落在接收端
  配置的死鍵（dead key）上（例如德文／法文／西班牙文的重音鍵），結果會卡在
  組字狀態，打不出寄送端原本要的字元。範圍很窄，如果之後兩台 Mac 真的會用到
  死鍵密集的配置，值得補一輪實機測試，不需要為此改程式碼。

  `UCKeyTranslate`／`TISCopyCurrentKeyboardLayoutInputSource` 本身沒有實機
  無法測試，仍需要在兩台真正使用不同實體配置（不只是切輸入法）的 Mac
  上實測，確認 Shift／Option／Caps Lock 組合、按住連發都正確；在字母位置真的
  不同的配置（如德文 QWERTZ）上測 Cmd-Z 這類快捷鍵是否落在正確按鍵，以及 Cmd
  快捷鍵不受寄送端 CapsLock 影響；有 ISO／JIS 實體鍵盤的話也一併驗證。

## 剩餘的 P0／P1

- **F1 剪貼簿同步**：初版只同步 `public.utf8-plain-text`，上限沿用 32 KiB，並拒絕
  帶有 `org.nspasteboard.ConcealedType` 的密碼管理器內容；功能預設關閉且需要使用者
  明確開啟。圖片與檔案留待 F12。
- **F2 邊緣穿越與預先授權**：預先授權層已完成；新配對的 peer 預設啟用接收端一次性
  授權，可在 **Paired device information** 逐台關閉。關閉後仍需每次 Allow。邊緣穿越會改變控制同意模型，
  實作前需先記錄威脅模型與預先授權的撤銷方式，並保留
  `Control-Option-Command-Escape` 緊急返回。
- **F4 多螢幕游標對應**：目前只映射主要顯示器，其餘螢幕的座標會被夾到邊緣。需要
  交換兩端顯示器拓撲（各螢幕 bounds 與排列），把游標映射到對應的遠端螢幕。

## P2 剩餘項目

- F8 需要重新設計多 peer 仲裁與選單，不適合在雙 Mac MVP 前提下直接擴充。
- F9 在公開散布前需要 Developer ID、hardened runtime 與 Apple notarization。
- F10 執行期連線診斷仍待加入延遲、jitter 與有界事件紀錄；原生 DDC 診斷工具已能
  提供系統／顯示器 transport 與 input mapping 證據。

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
