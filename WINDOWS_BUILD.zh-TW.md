[English](WINDOWS_BUILD.md)

# Windows 建置手冊

本手冊說明如何建置 MacKVM 的 Windows 分支。目前 W2 內容是 C#/.NET 8 protocol
library、簽章配對 state machine、console receiver、DPAPI identity，以及配對與 secure
Connect 的免外部套件 mDNS 廣播器；可以與 MacKVM 1.00.00 建立簽章信任關係並完成加密
session 驗證。這還不是完整 Windows KVM；WinUI 3、Raw Input、SendInput、加密控制
message、快捷鍵、tray integration 與最後的防火牆 UX 會在後續 Windows 階段實作。

## 建置需求

- Windows 10 2004（build 19041）或更新版本。
- .NET 8 SDK。使用 `dotnet --info` 確認；只有 runtime 不足以建置。
- PowerShell 5.1 或 PowerShell 7。
- 如果要在 Windows 建置主機抓取原始碼，需要 Git。

簽章配對接收端支援上述 Windows 10 基線。W2 secure Connect 另外需要
`10.0.20142` 或更新的 Windows build，因為 .NET 8 會使用 Windows CNG 的
ChaCha20-Poly1305 實作來建立加密連線。較舊版本仍可配對，但執行檔會明確
顯示 secure Connect 已停用。

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

## 啟動配對 receiver

開始測試前先確認執行檔版本：

```powershell
.\WindowsKVM.exe --version
```

目前 W2 測試 build 應顯示 `WindowsKVM 1.01.02 (build 79)`。

在 Windows publish 後啟動 W2 receiver：

```powershell
.\dist\windows\arm64\WindowsKVM.exe --pairing-listen --name "Windows ARM64"
```

Mac 連入後，CLI 會顯示傳入裝置、六位數驗證碼與明確的 `Accept pairing?` 提示；請把
驗證碼與發起配對的 Mac 畫面比對，再在 Windows 輸入 `y` 或 `yes`：

```powershell
.\dist\windows\x64\WindowsKVM.exe --pairing-listen --name "Windows x64"
```

只有在受控測試時才使用 `--yes`，它會自動接受驗證碼。receiver 會在區域網路廣播配對用的
`_mackvm._tcp` 與 Connect 用的 `_mackvm-secure._tcp`，兩個 listener 預設都使用系統分配的
TCP port。CLI 也會列出每個收到的 pairing frame，以及配對被拒絕時的詳細傳輸／protocol
錯誤。Windows Defender Firewall 可能顯示標準的 Private network 提示；只在信任的區域網路
允許此程式。程式不會偷偷新增寬鬆的防火牆規則。

配對完成後，Windows 會把 Mac 的公開 identity 寫入
`%LOCALAPPDATA%\MacKVM\trusted-peers.json`。接著在 MacKVM 選取已配對的 Windows 裝置並
按 **Connect**；Windows CLI 應依序顯示 `Incoming secure-session connection`、
`Secure handshake response sent` 與 `Secure session authenticated with ...`。W1 舊版配對不會
建立這份 trust record，第一次測試 W2 Connect 前請用 W2 executable 重新配對一次。若公開
key 改變，程式會拒絕而不會默默覆寫信任。

主機能綁定 IPv6 時，receiver 使用 dual-mode TCP listener；mDNS 廣播器只會發布與實際
listener 相符的位址記錄：IPv4 使用 A、IPv6 使用 AAAA。Windows 具有 IPv6 介面與多播
權限時，可支援 IPv6-only 區域網路；若 dual-stack 綁定失敗而回退到 IPv4，則只廣播
IPv4 discovery，避免公布無法連線的 IPv6 endpoint。

Windows peer identity 會放在 `%LOCALAPPDATA%\MacKVM`，private key 使用 Windows
DPAPI 保護，絕對不要把 `identity.json` 複製到另一台電腦。公開 peer trust list 分開保存，
不含 private key。W2 console 會在配對完成後記錄 Mac identity，供 secure Connect admission
使用；鍵盤／滑鼠控制尚未啟用。

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
  -Project WindowsKVM/src/WindowsKVM.App/WindowsKVM.App.csproj `
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

腳本本身已會拒絕錯誤的 PE machine type。W2 receiver 可以完成與 macOS 的簽章配對與
加密 Connect handshake，但尚未提供完整的 Windows 輸入控制功能。

## 常見問題

- **`dotnet was not found`**：安裝 .NET 8 SDK、重新開啟 PowerShell，並確認
  `dotnet --info` 可執行。
- **腳本顯示必須在 Windows 執行**：在 macOS 使用 `-Plan`，或在 Windows host／VM
  執行 publish。
- **Execution policy 阻擋腳本**：只對目前程序暫時放寬：
  `powershell -ExecutionPolicy Bypass -File .\scripts\build-windows.ps1 -Architecture x64`。
- **架構錯誤**：Windows x86_64 使用 `x64`，Windows ARM64 使用 `arm64`；不要傳入
  `x86` 或 `i686`。

Windows executable 尚未加入 macOS DMG packaging。W2 已驗證跨平台簽章配對與加密 Connect；
鍵盤／滑鼠接管與交還、Windows input API、快捷鍵與 tray UI 完成後，才會宣告 Windows 版可用。
