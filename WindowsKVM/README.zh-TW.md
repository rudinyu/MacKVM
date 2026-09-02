[English](README.md)

# WindowsKVM

WindowsKVM 是 MacKVM 的 Windows companion。目前 Windows 版包含原生 Win32 UI／系統匣常駐
host，可在區域網路上與 MacKVM 配對、完成 secure Connect 驗證，並接收加密鍵盤／滑鼠控制；
另外保留 console 模式供自動化與防火牆診斷。

## 目前功能 — 1.02.11（build 91）

Windows host 已包含：

- 此 beta 不支援 MacKVM 1.00.00；配對與 authenticated secure Connect 都必須使用包含簽名
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
- 與 MacKVM protocol v2 相容且嚴格驗證 lower-camel control message 與 remote input；
- Windows `SendInput` 鍵盤、修飾鍵、Unicode fallback、滑鼠、按鍵、多媒體鍵與具 unit 區分的
  pixel／line 滾輪注入（包含 pointer pressure 與 trackpad phase metadata）；
- 在控制結束、輸入錯誤、斷線或程式結束時釋放所有按住的按鍵／滑鼠按鈕；
- UI 原生配對／控制同意對話框、常駐系統匣圖示、與 macOS 對齊且可捲動的狀態視窗，以及公開的
  **複製支援資訊**；
- responsive **Simple mode／Advanced mode**：小螢幕自動使用 Simple mode，只保留必要的
  identity／配對／控制操作，標題列可以手動切換完整 Advanced mode；
- Simple mode 與 Advanced mode 都提供 **Forget paired Mac**，會移除 Windows trust pin，
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
控制。Windows Raw Input 擷取與完整的防火牆設定精靈留待後續工作。

### UI 版面

Windows 狀態視窗沿用 macOS MacKVM 面板的資訊順序，並提供兩種模式：

- **Simple mode**：當螢幕小於 900×1120 像素，或視窗可用區域較窄／較矮時自動啟用。
  它保留版本、網路／輸入就緒、配對狀態、控制權、防火牆設定、Refresh 與 Quit，不需要長距離捲動。
- **Advanced mode**：保留完整診斷與支援資訊。可用標題列按鈕切換；小螢幕下仍可捲動查看完整內容。

完整 Advanced mode 的區段順序為：

1. **標題區**：MacKVM 品牌、本機友善名稱、裝置 ID、型號、版本／build 與公開金鑰指紋。
2. **設定這台 PC**：Local Network、Input Monitoring、Accessibility、防火牆設定、輸入就緒、
   控制請求通知與重新整理。
3. **實體輸入路徑**：鍵盤／滑鼠／觸控板擁有者摘要與 Windows `SendInput` 路徑。
   選擇 **Local Windows input only** 會停用遠端控制請求（並釋放目前控制權）；切回第一個選項
   才允許已配對的 Mac 再次請求控制。
4. **附近的 Mac**：配對 listener 狀態與所有已信任 Mac 的選擇器（包含短裝置 ID）；先選取
   peer 再使用 **Forget paired Mac**。Pair 與 Connect 仍由 MacKVM peer 發起。
5. **鍵盤、滑鼠與觸控板**：權限狀態、目前控制狀態與本機交還快捷鍵。
6. **螢幕輸入**：說明螢幕切換是選用功能，仍由 MacKVM 或螢幕 OSD 控制。
7. **已配對裝置資訊**：目前 Mac 的公開 identity、**Forget paired Mac**、本機 identity 詳細資料與公開的
   **複製支援資訊**功能。

配對驗證碼與控制同意使用原生 Windows Yes／No 對話框；系統匣選單提供
**Open WindowsKVM** 與 **Quit WindowsKVM**。

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

不帶參數會啟動常駐 UI 與系統匣 host；要使用 console receiver，請加上
`--pairing-listen --name "Windows x64"`。Windows ARM 請使用 ARM64 執行檔。Windows
Defender Firewall 出現提示時，只允許可信任的 Private network；WindowsKVM 不會新增寬鬆或
隱藏的防火牆規則。

要從 console 檢查或移除 Windows 端的 trust pin，請先列出已儲存的 peer ID，再把完整 ID 傳給
`--forget`：

```powershell
.\dist\windows\x64\WindowsKVM.exe --list-paired
.\dist\windows\x64\WindowsKVM.exe --forget <peer-id>
```

這個 one-shot CLI 指令會移除持久化 trust，按 Connect 前必須重新 Pair。它無法關閉另一個已在執行
receiver process 所持有的 active session；需要時請重新啟動 receiver 讓它重新載入 trust store，或使用
UI 的 **Forget paired Mac** 來撤銷 active session。

## 配對與 Connect

1. 在 Windows 啟動 `WindowsKVM.exe`（或 `WindowsKVM.exe --ui`）；UI 會啟動 pairing／secure
   listener 並加入系統匣。要做腳本測試時，改用 `WindowsKVM.exe --pairing-listen`。
2. 在已配對的 Mac 按 **Pair**，比較兩邊的六位數驗證碼。
3. UI 模式在原生配對對話框比較六位數驗證碼後按 **Yes**；console 模式則在
   `Accept pairing?` 提示輸入 `y`。
4. 如果 Windows peer 是用舊 W1 build 配對，請重新配對一次，讓 W2/W3 建立
   `%LOCALAPPDATA%\MacKVM\trusted-peers.json`。
5. 要清除 Windows 端的 trust pin，請在 Windows UI 按 **Forget paired Mac** 並確認警告。
   Forget 會中止該 Mac 的既有 secure session；之後要先從 MacKVM 重新 Pair 才能 Connect。
6. 在 MacKVM 的 Windows peer 上按 **Connect**。
7. 在 MacKVM 選 **Request keyboard and mouse control**。UI 模式在 Windows 原生控制對話框
   按允許；console 模式確認提示後輸入 `y`；測試時可用 `--yes` 自動接受。
8. 要把控制權交還 Windows，請在 Windows 按 `Ctrl+Alt+Shift+Esc`，或從 MacKVM 結束
   control。兩種路徑都會釋放按住的按鍵／滑鼠按鈕。

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

## 相容性

簽章配對支援 Windows 10 build 19041 以上。Secure Connect 需要 Windows build 10.0.20142
以上，因為 W3 使用的 .NET ChaCha20-Poly1305 primitive 從此版本開始可用。較舊 Windows
仍可配對，但執行檔會明確顯示 secure Connect 已停用。

在 Windows 開發主機執行 protocol self-test：

```powershell
.\scripts\test-windows.ps1
```

macOS repository CI 在有 .NET 8 SDK 時也會自動執行這項 self-test。
