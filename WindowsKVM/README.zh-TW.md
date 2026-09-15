[English](README.md)

# WindowsKVM

WindowsKVM 是 MacKVM 的 Windows companion。目前 Windows 版包含原生 Win32 UI／系統匣常駐
host，可在區域網路上與 MacKVM 配對、完成 secure Connect 驗證，並接收加密鍵盤／滑鼠控制；
另外保留 console 模式供自動化與防火牆診斷。

## 目前功能 — 1.02.27（build 108）

Windows host 已包含：

- 此 Windows release candidate 不支援 MacKVM 1.00.00；配對與 authenticated secure Connect 都必須使用包含簽名
  `disconnectSignalVersion` capability 的 MacKVM build（MacKVM 1.100.00／build 75 加入）；
- authenticated secure Connect 會驗證簽名的 `disconnectSignalVersion` capability，並交換
  加密 disconnect acknowledgement；
- 使用 DPAPI 保護的 Windows identity 儲存；
- 原子寫入且固定公開金鑰的 trusted-peer 儲存，位置為
  `%LOCALAPPDATA%\MacKVM\trusted-peers.json`；
- 不依賴外部套件的雙堆疊 mDNS，廣播 `_mackvm._tcp` 與
  `_mackvm-secure._tcp`；
- 簽章 P-256 ephemeral key exchange、HKDF-SHA256 金鑰導出與
  ChaCha20-Poly1305 key confirmation；
- 有上限的 frame、重播防護、handshake timeout 與連線 admission limit；
- authenticated secure session 啟用 Windows TCP keepalive（閒置五秒、probe 間隔兩秒、三次
  probe），並以五秒 grace period 監測 socket 存活；peer 沒有應用層流量卻消失時會釋放控制權，
  並允許重新連線；
- 與 MacKVM protocol v2 相容且嚴格驗證 lower-camel control message 與 remote input；
- Windows `SendInput` 鍵盤、修飾鍵、Unicode fallback、滑鼠、按鍵、多媒體鍵與具 unit 區分的
  pixel／line 滾輪注入（包含 pointer pressure 與 trackpad phase metadata）；
- 轉送長按重複事件，並正確映射中鍵與 XBUTTON1／XBUTTON2；未支援的亮度、鍵盤背光鍵與額外滑鼠按鈕
  會安全忽略，不會觸發無關的 Windows 動作；
- 在控制結束、輸入錯誤、斷線或程式結束時釋放所有按住的按鍵／滑鼠按鈕；
- UI 原生配對／控制同意對話框、常駐系統匣圖示、與 macOS 對齊且可捲動的狀態視窗，以及公開的
  **複製支援資訊**；
- Advanced mode 會將完整本機金鑰指紋以固定短行顯示，窄視窗或高 DPI 時不會被下一列 DPAPI 說明覆蓋；
- 互動式完成 Mac 配對後，已釘選的控制授權預設自動開啟（測試專用的 `--yes` 流程維持一次性）；
  **Automatically allow control from this paired Mac** 勾選框，以及 `--allow-control`／`--deny-control`
  指令可關閉或恢復這個持久決定。
  關閉自動同意後，控制對話框中的單次 **Allow** 只適用於當次請求，不會重新啟用持久授權；請用
  勾選框或 `--allow-control` 恢復；
- responsive **Simple mode／Advanced mode**：預設使用精簡 Simple mode，只保留必要的
  identity／配對／控制操作，標題列可以手動切換完整 Advanced mode；
- 裝置管理提供 **Forget paired Mac**，會移除 Windows trust pin，
  並中止該 peer 的既有 secure session；
- `--pairing-listen` 模式的共用 console 同意提示（測試時可用 `--yes`）；
- `Ctrl+Alt+Shift+Esc` 緊急快捷鍵，直接把控制權交還 Windows。

認證輸入使用每秒 rolling packet／byte budget，因此高 polling rate 滑鼠與 trackpad 可以持續
連線，同時避免無上限的輸入 flood。Windows `SendInput` 無法完全重現 macOS momentum phase，
但會保留 wire metadata，並將 pixel movement 轉成 high-resolution wheel unit，不再有舊版的
120 倍放大。

如果 Mac peer 沒有宣告簽名的 disconnect capability，Secure Connect 會刻意
fail closed。配對仍可使用，但必須先更新舊版 Mac，才能建立加密控制 session。

UI 會在啟動時開始 receiver 並常駐在 Windows 系統匣；關閉狀態視窗只會隱藏，從視窗或
系統匣選單的 **Quit WindowsKVM** 才會停止 mDNS、TCP listener 與輸入注入。Windows 端不會
接受未驗證的輸入；只有已配對且完成加密驗證的 Mac session，通過本機同意政策後才能取得
控制。互動式配對完成後，這個本機自動控制決定會預設綁定目前釘選的公開金鑰並保存；測試專用的
`--yes` 配對不會保存。若要每次控制都重新確認，可在 **Paired device information** 關閉它。Windows Raw Input 擷取與完整的防火牆
設定精靈留待後續工作。

### UI 版面

Windows 狀態視窗沿用 macOS MacKVM 面板的資訊順序，並提供兩種模式：

- **Simple mode**：預設的精簡面板，只顯示 PC 名稱、簡短的就緒／配對／控制狀態、必要操作與小型版本／build 標示。
  型號、TCP port、UUID、完整金鑰指紋與冗長的設定說明不會出現在日常畫面。
- **Advanced mode**：保留完整身分、防火牆設定、裝置管理、自動控制同意、診斷與支援資訊。
  可用標題列按鈕切換，回到 Simple 時視窗會再縮小；Advanced 可垂直捲動，視窗較窄時也會提供
  橫向捲動，確保完整大小的控制項仍可操作。

拖曳縮小時會依螢幕工作區設定最小可操作尺寸，並保留 Windows 系統本身的尺寸下限，避免 Simple 控制項在極窄視窗中重疊。
視窗標題與主標題統一為 **WindowsKVM**；窄版 Simple 會將模式按鈕移到主標題下方。
捲動採用整批搬動與完整重繪，不保留舊列的像素。

同意請求不會因為模式不同而隱藏。精簡狀態顯示錯誤時，可切至 Advanced 查看完整診斷。
系統匣選單仍可重新開啟隱藏的狀態視窗；已顯示的主視窗不再重複放置 **Open window** 按鈕。

完整 Advanced mode 的區段順序為：

1. **標題區**：WindowsKVM 品牌、本機友善名稱、裝置 ID、型號、版本／build 與公開金鑰指紋。
2. **設定這台 PC**：Local Network、Input Monitoring、Accessibility、防火牆設定、輸入就緒、
   控制請求通知與重新整理。
3. **實體輸入路徑**：鍵盤／滑鼠／觸控板擁有者摘要與 Windows `SendInput` 路徑。
   選擇 **Local Windows input only** 會停用遠端控制請求（並釋放目前控制權）；切回第一個選項
   才允許已配對的 Mac 再次請求控制。
   下拉清單展開時可同時容納兩個選項，捲動或縮放後仍保留此高度。此設定不代表支援 Windows 向 Mac 傳送輸入。
4. **附近裝置**：配對 listener 狀態與所有已信任 peer 的選擇器（包含短裝置 ID）；先選取
   peer 再使用 **Forget paired Mac**。Pair 與 Connect 仍由 MacKVM peer 發起。
5. **鍵盤、滑鼠與觸控板**：權限狀態、目前控制狀態與本機交還快捷鍵。
6. **螢幕輸入**：說明螢幕切換是選用功能，仍由 MacKVM 或螢幕 OSD 控制。
7. **已配對裝置資訊**：目前 Mac 的公開 identity、**Forget paired Mac**、**Automatically allow
   control from this paired Mac**、本機 identity 詳細資料與公開的 **複製支援資訊**功能。

配對驗證碼，以及關閉自動同意後的控制請求，使用原生 Windows Allow／Deny 對話框；互動式配對的新 peer
預設直接依照自動同意處理，測試專用的 `--yes` 配對則保持未設定。關閉後，控制對話框中的單次 **Allow** 不會改變持久設定；請用
勾選框或 `--allow-control` 恢復自動同意。系統匣選單提供 **Open WindowsKVM** 與 **Quit WindowsKVM**。

同一時間只允許一個 UI 或 console receiver。啟動 `--pairing-listen` 前，先使用 **Quit WindowsKVM**
結束原本的 receiver；隱藏視窗不會停止它。查詢版本與管理配對的指令仍可使用，且不會另外啟動 receiver。

同意對話框會綁定目前請求，同一時間只顯示一個。取消或逾時後會關閉該請求的對話框，不能事後同意。
遇到此情況，請從 MacKVM 發起新的請求，並重新核對驗證碼。

## 建置與啟動

SDK 安裝、架構 publish 與疑難排解請參閱[Windows 建置手冊](../WINDOWS_BUILD.zh-TW.md)。
支援 Windows x64（`win-x64`，也稱 `x86_64`）與 Windows ARM64（`win-arm64`）；不支援
32-bit x86。
console log 收集與跨平台問題診斷請參閱[除錯與診斷手冊](../DEBUGGING.zh-TW.md)。

```powershell
.\scripts\build-windows.ps1 -Architecture x64
.\scripts\build-windows.ps1 -Architecture arm64
.\dist\windows\x64\WindowsKVM.exe --version
.\dist\windows\x64\WindowsKVM.exe
```

每次直接 publish 都會先清理：建置前移除預設的 `dist` 產物與暫存 publish 狀態。若需要
兩種架構，請在同一批次使用 `-Architecture both`；腳本只清理一次並保留兩種輸出。

不帶參數會啟動常駐 UI 與系統匣 host；要使用 console receiver，請加上
`--pairing-listen --name "Windows x64"`。Windows ARM 請使用 ARM64 執行檔。Windows
Defender Firewall 出現提示時，只允許可信任的 Private network；WindowsKVM 不會新增寬鬆或
隱藏的防火牆規則。

要從 console 檢查或移除 Windows 端的 trust pin，請先列出已儲存的 peer ID，再把完整 ID 傳給
`--forget`：

```powershell
.\dist\windows\x64\WindowsKVM.exe --list-paired
.\dist\windows\x64\WindowsKVM.exe --forget <peer-id>
.\dist\windows\x64\WindowsKVM.exe --allow-control <peer-id>
.\dist\windows\x64\WindowsKVM.exe --deny-control <peer-id>
```

這個 one-shot CLI 指令會移除持久化 trust，按 Connect 前必須重新 Pair。執行中的 receiver 會在控制准入及
輸入傳送期間重新整理持久化 trust，因此 **Forget**、金鑰替換與 `--deny-control` 不需要重啟就會生效。
UI 的 **Forget paired Mac** 也會要求常駐 receiver 立即關閉相符的 session。`--allow-control` 與
`--deny-control` 只更新選定釘選 Mac 的本機控制同意，不會變更配對公開金鑰。

## 配對與 Connect

1. 在 Windows 啟動 `WindowsKVM.exe`（或 `WindowsKVM.exe --ui`）；UI 會啟動 pairing／secure
   listener 並加入系統匣。要做腳本測試時，改用 `WindowsKVM.exe --pairing-listen`。
2. 在已配對的 Mac 按 **Pair**，比較兩邊的六位數驗證碼。
3. UI 模式在原生配對對話框比較六位數驗證碼後按 **Allow**；console 模式則在
   `Accept pairing?` 提示輸入 `y`。
4. 如果 Windows peer 是用舊 W1 build 配對，請重新配對一次，讓 W2/W3 建立
   `%LOCALAPPDATA%\MacKVM\trusted-peers.json`。
5. 要清除 Windows 端的 trust pin，請在 Windows UI 按 **Forget paired Mac** 並確認警告。
   Forget 會中止該 Mac 的既有 secure session；之後要先從 MacKVM 重新 Pair 才能 Connect。
6. 在 MacKVM 的 Windows peer 上按 **Connect**。
7. 在 MacKVM 選 **Request keyboard and mouse control**。新配對的 Mac 預設會自動取得控制；若要每次確認，
   取消勾選 **Automatically allow control from this paired Mac**，或執行 `--deny-control <peer-id>`，
   之後 UI 會顯示原生對話框，console 則要求輸入 `y`。對話框中的單次 **Allow** 只允許當次請求，
   不會重新啟用持久授權；請重新勾選或執行 `--allow-control <peer-id>` 恢復自動控制。`--yes` 只適合
   受控測試，且不會保存自動同意。
8. 要把控制權交還 Windows，請在 Windows 按 `Ctrl+Alt+Shift+Esc`，或從 MacKVM 結束
   control。兩種路徑都會釋放按住的按鍵／滑鼠按鈕。

交還控制不會中斷已認證的 secure session；已結束請求的在途輸入會被忽略，後續控制請求必須取得新的
grant。選擇 **Local Windows input only** 也會通知 Mac 控制已結束。重新開啟遠端輸入只允許新請求，
不會默默恢復先前的控制權。

console 模式驗證並取得控制時，Windows 應顯示（UI 狀態視窗也會同步顯示）：

```text
Incoming secure-session connection
Secure handshake response sent
Secure session authenticated with ...
Windows control granted for ...
```

如果 peer 公開金鑰改變，Windows 會拒絕連線，不會默默覆寫已固定的金鑰。若是 Mac identity
重設後刻意重新配對，Windows 會顯示明確的取代警告，只有驗證碼確認後才會更新 pin。若 identity
檔案無法解密或驗證失敗，receiver 會 fail closed；重設方式請依照[Windows 建置手冊](../WINDOWS_BUILD.zh-TW.md)。

## Windows 回歸驗收

請在 Windows x64 與 ARM64，搭配相容的 MacKVM 各執行一次。輸入測試請使用可丟棄的文字文件；
模擬 native API 的自動測試不能取代這些桌面操作檢查。

1. 分別長按字母、Backspace 與方向鍵，確認持續重複、放開即停止。按住 Ctrl 或滑鼠按鈕時結束控制，
   確認之後可正常使用本機輸入，不會留下按住的修飾鍵。
2. 用五鍵滑鼠測試中鍵與兩個側鍵；中鍵不能變成上一頁，側鍵不得造成控制中斷。測試亮度／鍵盤背光鍵，
   確認不會開啟 Mail、停止播放或斷線；目前 receiver 不實作 Windows 亮度調整。
3. 持續移動滑鼠時按 Windows 交還控制熱鍵。secure connection 應保持連線，重新請求控制時不需再配對
   或重新 Connect。
4. 控制中選 **Local Windows input only**，隨即重新開啟遠端輸入；舊 grant 必須維持結束，從 MacKVM
   發起的新請求則可正常取得控制。也在同意請求仍待回應時重複此操作。
5. 關閉測試 peer 的自動控制同意，讓控制對話框超過 15 秒不回應；另一次測試則從 Mac 取消配對請求。
   過期對話框應關閉，重試只顯示新請求。也測試多個排隊請求，以及同意視窗開啟時退出 app，確認不會
   接受已失效的請求。
6. UI 常駐時在 console 啟動 `--pairing-listen`，第二個 receiver 應退出，原本 UI 仍正常；`--version`
   與 `--list-paired` 應可使用。退出 UI、改用 console receiver，再開 UI 重複驗證不能啟動第二個 receiver。
7. 在 1366×768 桌面與 150%／200% 縮放下檢查 Simple mode，必要操作必須可使用，視窗不能蓋住工作列。
   開啟 Advanced 檢查隱藏的身分與 port 資訊；在窄視窗使用橫向捲動確認右側操作仍可使用。
   再切回 Simple，確認視窗縮小且橫向捲軸消失；拖曳至最小尺寸，確認模式與配對按鈕不重疊。連線時調整大小或移動到
   不同螢幕，切換版面不得重設配對或控制權，同意對話框也必須保持可操作。
8. 確認 `--version` 為 **1.02.27（build 108）**；先前 UI 問題的測試版本為
   **1.02.09（build 89）Beta 3**，不是本版。啟動替換版前先退出舊的系統匣 receiver。
   確認視窗標題與主標題為 **WindowsKVM**，在 Advanced 快速上下捲動並拖動兩個捲軸，
   不應殘留舊文字。捲動／縮放前後展開 **Physical input path**，分別選取兩個選項；
   在 Simple 重複操作，確認兩種模式的選擇一致。恢復遠端輸入後，從 Mac 發起新的控制請求驗證功能。

## 相容性

簽章配對支援 Windows 10 build 19041 以上。Secure Connect 需要 Windows build 10.0.20142
以上，因為 W3 使用的 .NET ChaCha20-Poly1305 primitive 從此版本開始可用。較舊 Windows
仍可配對，但執行檔會明確顯示 secure Connect 已停用。

在開發主機執行 protocol 與 desktop regression self-test：

```powershell
.\scripts\test-windows.ps1
```

macOS repository CI 在有 .NET 8 SDK 或更新版本時也會自動執行這些 self-test。
Desktop 測試透過可替換的平台介面驗證程式邏輯；原生 Windows 對話框與輸入操作仍須另外驗收。
