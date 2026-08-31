[English](WINDOWS_BUILD.md)

# Windows 建置手冊

本手冊說明如何建置 MacKVM 的 Windows 分支。目前內容是 C#/.NET 8 protocol library、簽章
配對 state machine、原生 Win32 狀態視窗與系統匣常駐 host、DPAPI identity、配對與 secure
Connect 的免外部套件 mDNS 廣播器、嚴格 control／input 驗證、Windows SendInput 注入、
釋放所有輸入狀態，以及緊急交還快捷鍵。Windows Raw Input 擷取與最後的防火牆 UX 會在
後續 Windows 階段實作。

## 建置需求

- Windows 10 2004（build 19041）或更新版本。
- .NET 8 SDK。使用 `dotnet --info` 確認；只有 runtime 不足以建置。
- PowerShell 5.1 或 PowerShell 7。
- 如果要在 Windows 建置主機抓取原始碼，需要 Git。

簽章配對接收端支援上述 Windows 10 基線。W3 secure Connect 另外需要
`10.0.20142` 或更新的 Windows build，因為 .NET 8 會使用 Windows CNG 的
ChaCha20-Poly1305 實作來建立加密連線。較舊版本仍可配對，但執行檔會明確
顯示 secure Connect 已停用。

此 Windows beta 不相容於 MacKVM 1.00.00 正式版。Mac peer 必須使用包含簽名的
`disconnectSignalVersion` capability 的 MacKVM build（MacKVM 1.100.00／build 75 加入），
才能進行配對與 secure Connect。舊 peer 會明確回報需要升級，不會靜默降級成未認證的 EOF
關閉。

支援的 native publish 目標是 Windows x64（`win-x64`，也稱 `x86_64`）與
Windows ARM64（`win-arm64`）。不支援 32-bit `i686`。

## 取得原始碼

請使用 Windows 開發分支，不要使用穩定的 macOS 分支：

```powershell
git clone https://github.com/rudinyu/MacKVM.git
Set-Location MacKVM
git switch feature/windows-w0-scaffold
```

如果分支尚未 push，請把含有 Windows scaffold 的工作目錄複製到 Windows
建置主機，或改用實際存在的 Windows 分支名稱。

## 建置單一架構

在 repository 根目錄執行腳本。腳本會產生 self-contained、single-file executable，
並在成功前驗證 PE machine type：

```powershell
.\scripts\build-windows.ps1 -Architecture x64
.\scripts\build-windows.ps1 -Architecture arm64
```

需要明確指定 release configuration 時：

```powershell
.\scripts\build-windows.ps1 -Architecture x64 -Configuration release
```

產物會放在 `dist\windows`：

```text
dist\windows\x64\WindowsKVM.exe
dist\windows\arm64\WindowsKVM.exe
```

中間的 `bin`／`obj` 狀態會放在系統暫存目錄，不會寫進 repository。腳本也會隔離
reference graph 中的每個 project，避免 `net8.0` protocol library 與
`net8.0-windows` app 共用 restore 狀態而互相覆蓋。

## 同時建置兩種架構

```powershell
.\scripts\build-windows.ps1 -Architecture both
```

腳本在第一個 publish 失敗時停止。成功時會列出每個 executable 偵測到的 PE 架構
（`x64` 或 `arm64`）。
repository CI 也會在 Windows runner 重複兩種 publish，因此本機 cross-build 不會是唯一的
Windows 建置檢查。

## 啟動配對 receiver

開始測試前先確認執行檔版本：

```powershell
.\WindowsKVM.exe --version
```

目前 UI 測試 build 應顯示 `WindowsKVM 1.02.10 (build 90)`。

在 Windows publish 後啟動常駐 UI：

```powershell
.\dist\windows\arm64\WindowsKVM.exe
```

UI 會加入 Windows 系統匣圖示、啟動兩個 listener，並以原生 Yes／No 對話框處理配對與
控制同意。關閉狀態視窗只會隱藏；從視窗或系統匣選單選 **Quit WindowsKVM** 才會停止
所有 listener。要做腳本測試時，使用 `--pairing-listen`；`--yes` 只適合受控測試，會自動
接受配對與控制：

狀態視窗沿用 macOS 面板順序，並提供兩種模式。螢幕小於 900×1120 像素，或視窗可用區域較窄／較矮時，
會自動使用 **Simple mode**，保留 identity、就緒狀態、配對、控制權、防火牆、Refresh 與 Quit。
**Advanced mode** 顯示完整的標題、**設定這台 PC**、**實體輸入路徑**、**附近的 Mac**、
**鍵盤／滑鼠／觸控板**、**螢幕輸入**與**已配對裝置資訊**，小螢幕仍可捲動。標題列按鈕可在兩種模式間切換。
Pair 與 Connect 仍由 MacKVM peer 發起，Windows 顯示相對應的同意對話框與即時狀態。

若使用 console 模式，Mac 連入後 CLI 會顯示傳入裝置、六位數驗證碼與明確的
`Accept pairing?` 提示；請把驗證碼與發起配對的 Mac 畫面比對，再在 Windows 輸入 `y` 或 `yes`：

```powershell
.\dist\windows\x64\WindowsKVM.exe --pairing-listen --name "Windows x64"
```

只有在受控測試時才使用 `--yes`，它會自動接受驗證碼。receiver 會在區域網路廣播配對用的
`_mackvm._tcp` 與 Connect 用的 `_mackvm-secure._tcp`，兩個 listener 預設都使用系統分配的
TCP port。console 模式會列出每個收到的 pairing frame，以及配對被拒絕時的詳細傳輸／protocol
錯誤；UI 模式則將主要狀態顯示在狀態視窗。Windows Defender Firewall 可能顯示標準的
Private network 提示；只在信任的區域網路允許此程式。程式不會偷偷新增寬鬆的防火牆規則。

要從 console 檢查或移除 Windows 端的 trust pin，請先用 `--list-paired` 列出的完整 peer ID：

```powershell
.\dist\windows\x64\WindowsKVM.exe --list-paired
.\dist\windows\x64\WindowsKVM.exe --forget <peer-id>
```

`--forget` 是一次性的持久化 trust-store 操作；按 Connect 前必須從 MacKVM 重新 Pair。
如果另一個 WindowsKVM receiver 已經在執行，CLI 操作後請重新啟動它以重新載入 trust store，或改用
UI 的 **Forget paired Mac** 關閉該 peer 的 active session。

配對完成後，Windows 會把 Mac 的公開 identity 寫入
`%LOCALAPPDATA%\MacKVM\trusted-peers.json`。接著在 MacKVM 選取已配對的 Windows 裝置並
按 **Connect**；console 模式的 Windows 應依序顯示 `Incoming secure-session connection`、
`Secure handshake response sent` 與 `Secure session authenticated with ...`。W1 舊版配對不會
建立這份 trust record，第一次測試 W3 Connect 前請用 W3 executable 重新配對一次。若公開
key 改變，程式會拒絕而不會默默覆寫信任。若要在 Windows 端清除配對，請在 UI 的
**Forget paired Mac** 按鈕操作；這會移除 Windows 端的 trust pin，之後必須從 Mac 重新 Pair
才能 Connect。若 Mac identity key 也被重設，Windows 會在驗證碼對話框明確警告即將取代舊 pin，
只有使用者確認後才會寫入；Secure Connect 或未同意的寫入永遠不會自動取代 key。

Connect 後，在 MacKVM 選 **Request keyboard and mouse control**。UI 模式會顯示原生控制
同意對話框；console 模式則要求本機輸入 `y`／`yes`（測試時可用 `--yes` 自動接受）。取得控制後會顯示
`Windows control granted`，並用 `SendInput` 注入已驗證的 Mac 輸入。在 Windows 按
`Ctrl+Alt+Shift+Esc` 會釋放所有按住的輸入並把控制權交回本機；從 MacKVM 結束 control
也有相同的 release-all 行為。

如果 Mac 顯示 `peer-upgrade-required`，或 Windows 顯示 peer 不支援 authenticated
disconnect signal，請先把兩端更新到目前 branch／build 再測試 Connect。只有配對相容
並不代表 secure Connect 相容。

主機能綁定 IPv6 時，receiver 使用 dual-mode TCP listener；mDNS 廣播器只會發布與實際
listener 相符的位址記錄：IPv4 使用 A、IPv6 使用 AAAA。Windows 具有 IPv6 介面與多播
權限時，可支援 IPv6-only 區域網路；若 dual-stack 綁定失敗而回退到 IPv4，則只廣播
IPv4 discovery，避免公布無法連線的 IPv6 endpoint。

Windows peer identity 會放在 `%LOCALAPPDATA%\MacKVM`，private key 使用 Windows
DPAPI 保護，絕對不要把 `identity.json` 複製到另一台電腦。公開 peer trust list 分開保存，
不含 private key。W3 console 會在配對完成後記錄 Mac identity，供 secure Connect admission
使用，並在加密 control message 通過驗證後注入鍵盤／滑鼠。

如果既有 identity 無法解密或驗證失敗，receiver 會 fail closed，不會默默產生新的
identity。請先在所有曾信任這台 Windows 的 Mac 忘記舊 peer，再明確刪除損壞的
`%LOCALAPPDATA%\MacKVM\identity.json`，然後重新啟動 receiver 產生新的 identity。
這可避免 key／UUID 未通知就輪換，導致原有配對無聲失效。

在 Windows 開發主機可執行 protocol self-test：

```powershell
.\scripts\test-windows.ps1
```

在 M5 Pro 只預覽指令：

```sh
pwsh ./scripts/test-windows.ps1 -Plan
```

## 在 M5 Pro 預覽建置指令

publish 腳本刻意要求 Windows 建置主機。在 macOS 上可使用 `-Plan` 預覽指令，
不呼叫 .NET，也不產生 Windows executable：

```sh
pwsh ./scripts/build-windows.ps1 -Architecture both -Plan
```

Plan 模式不會建立 `dist/windows`。

## 選用參數

腳本支援自訂 project 與輸出目錄，方便測試：

```powershell
.\scripts\build-windows.ps1 `
  -Project WindowsKVM/src/WindowsKVM.Desktop/WindowsKVM.Desktop.csproj `
  -OutputDirectory dist/windows-local `
  -Architecture x64
```

自訂 project 必須使用 `net8.0-windows10.0.19041.0` 或相容的 Windows target
framework，且必須是 Windows executable project，讓腳本能驗證 publish 後的 PE 產物。

## 驗證產物

在 Windows 上可用 PowerShell 或 Visual Studio 工具檢查檔案：

```powershell
Get-Item .\dist\windows\x64\WindowsKVM.exe
Get-Item .\dist\windows\arm64\WindowsKVM.exe
```

腳本本身已會拒絕錯誤的 PE machine type。W3 receiver 可以完成與 macOS 的簽章配對、
加密 Connect handshake、control message 驗證與 Windows 輸入控制；仍需在真實 Windows
主機驗證 `SendInput` 與全域交還快捷鍵。

## 常見問題

- **`dotnet was not found`**：安裝 .NET 8 SDK、重新開啟 PowerShell，並確認
  `dotnet --info` 可執行。
- **腳本顯示必須在 Windows 執行**：在 macOS 使用 `-Plan`，或在 Windows host／VM
  執行 publish。
- **Execution policy 阻擋腳本**：只對目前程序暫時放寬：
  `powershell -ExecutionPolicy Bypass -File .\scripts\build-windows.ps1 -Architecture x64`。
- **架構錯誤**：Windows x86_64 使用 `x64`，Windows ARM64 使用 `arm64`；不要傳入
  `x86` 或 `i686`。

Windows executable 尚未加入 macOS DMG packaging。Windows UI 與 console host 共用跨平台
簽章配對、加密 Connect 及鍵盤／滑鼠接管；仍需在 Windows 實機完成視覺、系統匣、防火牆與
輸入注入驗收。
