[English](README.md)

# RemoteMac self-hosted relay

MacKVM 是原生 macOS 應用程式，提供選單列入口與一般控制視窗，讓兩台位於同一本機
網路的 Mac 共用一組鍵盤、滑鼠，並可選擇切換 BenQ MA270U 螢幕。配對與控制都需要
兩台 Mac 明確同意，控制資料會透過加密連線傳送。

## 功能

- 選單列常駐 KVM／雙螢幕圖示，並提供 Dock 與一般控制視窗；有待處理的控制請求時
  顯示警示符號。
- 保存本機裝置身份、Bonjour 探索與雙方簽署的配對流程。
- 六位數裝置金鑰驗證碼與已配對公開金鑰釘選。
- 保存配對裝置的友善名稱、型號、最後成功連線時間與 SHA-256 金鑰指紋。
- 每台已配對 Mac 的無縫控制授權；配對完成時自動啟用，也可在
  **Paired device information** 撤銷。
- **複製支援資訊**只匯出公開診斷資料，不包含私密金鑰、憑證、密碼或網路端點。
- 使用短期 P-256 金鑰交換、方向分離 HKDF、ChaChaPoly 與序號計數器的加密連線。
- 驗證後的鍵盤、滑鼠、滾輪與修飾鍵轉送，以及明確的 Allow／Deny 控制同意。
- Local Network、Input Monitoring、Accessibility 的循序設定檢查。
- Launch MacKVM at Login、通知 Allow／Deny／Review、斷線安全返回與自動重連。
- 防止 HDMI-only Intel Mac 誤宣稱具備雙向實體輸入的拓撲模式。
- 透過 IOKit 原生 DDC/CI 在 Apple Silicon 與 Intel 切換螢幕輸入、探索支援 DDC 的
  顯示器、保存穩定識別碼、顯示診斷，並在螢幕不支援時提供 OSD 備援。

外接螢幕不是配對或遠端控制的必要條件；只有自動切換螢幕輸入與跨螢幕指標定位時才需要。

## 硬體接法

- M5 Pro 14 吋 MacBook Pro：USB-C 連接 BenQ MA270U。
- 2019 16 吋 Intel MacBook Pro：USB-C／Thunderbolt 3 轉 HDMI 連接螢幕。
- 鍵盤與滑鼠：接在 M5 Pro，或接到 MA270U USB hub；HDMI 不會傳送 USB hub。
- 目前建議選 **One keyboard on M5 Pro (USB-C)**，由 M5 Pro 發起控制，Intel Mac
  接收控制。只有在兩台 Mac 都透過實體 USB switch 看見裝置時，才使用雙向模式。

## 需求

- macOS 13 或更新版本。
- Swift 6 toolchain；若要使用完整 Xcode 產物可安裝 Xcode。
- 若要自動切換螢幕輸入，外接螢幕與線材需提供 VESA DDC/CI；若螢幕 OSD 有 DDC/CI
  選項，請先開啟。沒有外接螢幕仍可配對與遠端控制。

MacKVM 在 Apple Silicon 透過 `IOAVService`、在 Intel 透過 `IOI2C` 直接傳送 DDC/CI
指令，不需要 Homebrew 工具或其他外部執行檔，兩種架構都能使用自動切換。
MA270U 的 USB-C 輸入使用 VCP 0x60 值 `19 (0x13)`；MacKVM 會依 EDID 套用這個型號特例，
其他螢幕保留通用的 USB-C 值。不同螢幕型號與韌體的輸入值可能不同，請用診斷掃描確認。

## 建置與打包

請參閱完整的[繁體中文安裝指南](INSTALL.zh-TW.md)。常用指令如下：

```sh
# Apple Silicon 版本
./scripts/build-app.sh --arch arm64

# 2019 Intel Mac 可用的 Intel 版本
./scripts/build-app.sh --arch x86_64

# 同時支援兩種架構的 DMG
./scripts/package-dmg.sh --arch universal
```

產物位於 `dist/`。本機測試使用 ad-hoc 簽章；要提供給其他 Mac 正式安裝，請用
Developer ID Application、hardened runtime，並在公開發佈前完成 Apple notarization。

### Windows 開發（Windows 分支）

完整建置流程請參閱獨立的 [Windows 建置手冊](WINDOWS_BUILD.zh-TW.md)。

Windows 端改用 C#/.NET 8，不用 Swift 處理 Windows UI、常駐列、輸入 API 或防火牆設定。
W1 已包含跨平台 protocol library、簽章配對 state machine、console receiver、DPAPI
保護的 identity 與免外部套件的 `_mackvm._tcp` mDNS 廣播器；可以和 MacKVM 1.00.00
建立信任關係，但還不是完整可用的 Windows KVM。W2 會加入 WinUI 3、Raw Input、SendInput、
加密控制 session、全域快捷鍵與最小權限的 Windows Firewall UX，同時維持相同 wire protocol。

支援的建置目標是 Windows x64（`win-x64`，也稱 `x86_64`）與 Windows ARM64（`win-arm64`），
刻意不支援 32-bit `i686`。請在安裝 .NET 8 SDK 的 Windows 建置主機上執行（後續加入 WinUI
後，建議使用含 Windows App SDK workload 的 Visual Studio 2022）：

```powershell
.\scripts\build-windows.ps1 -Architecture x64
.\scripts\build-windows.ps1 -Architecture arm64
```

若要同時發布兩種架構，可使用 `-Architecture both`；腳本會驗證 PE machine type。建置後可
啟動 Windows 端配對 receiver：

```powershell
.\dist\windows\arm64\WindowsKVM.exe --pairing-listen --name "Windows ARM64"
```

它會在區域網路廣播 `_mackvm._tcp`，顯示六位數驗證碼，並在比較 Mac 畫面後要求輸入 `y`。
只有受控測試才使用 `--yes` 自動接受。Windows Defender Firewall 只會出現標準 Private
network 提示，程式不會新增寬鬆規則。protocol self-test 可用
`./scripts/test-windows.ps1`（Windows）執行。

從 M5 Pro 只想預覽完整指令、不呼叫 .NET toolchain、也不產生執行檔，可使用：

```sh
pwsh ./scripts/build-windows.ps1 -Architecture both -Plan
```

準備 Windows 建置主機時，請參閱官方的
[Windows app development](https://learn.microsoft.com/en-us/windows/apps/) 與
[.NET deployment](https://learn.microsoft.com/en-us/dotnet/core/deploying/) 說明。

W1 receiver 使用 dual-mode TCP listener；主機有可用介面時，會透過 IPv4／IPv6 mDNS
廣播 A 與 AAAA 記錄。若主機沒有可用 IPv6 介面，會回退到 IPv4。macOS 的
`scripts/ci.sh` 在找到 `dotnet` 時會自動執行 Windows 檢查；沒有 Windows SDK 的 Mac
會略過這部分。使用 `RUN_WINDOWS_CI=1 ./scripts/ci.sh` 可將 Windows 檢查設為必要。

### 原生 DDC 診斷工具

當螢幕的 input mapping 不明，或 I2C 回報寫入成功但畫面沒有切換時，可建置跨架構
診斷工具：

```sh
./scripts/build-ddc-diagnostic.sh --arch arm64
./scripts/build-ddc-diagnostic.sh --arch x86_64
./scripts/build-ddc-diagnostic.sh --arch universal
```

請參閱[診斷工具說明](Tools/DDCDiagnostic/README.zh-TW.md)、[診斷原始碼](Tools/DDCDiagnostic/ddc-diagnostic.m)
與[診斷建置腳本](scripts/build-ddc-diagnostic.sh)。工具會輸出本機系統、EDID、Apple
Silicon／Intel transport 與 VCP `0x60` 讀值；明確執行 input scan 時會讀回每個候選值
並嘗試還原起始輸入，不能只把 I2C 寫入成功視為螢幕接受該值。這些檔案已納入本
repository，正常 CI 也會建置三種診斷目標。按下 Ctrl-C 或收到 SIGTERM 時會停止
候選值迴圈，仍嘗試還原起始輸入。

## 第一次使用

1. 在兩台 Mac 安裝並啟動相符架構的 `MacKVM.app`。
2. 依畫面順序授予 Local Network、Input Monitoring 與 Accessibility 權限。
3. 在 **Nearby Macs** 找到另一台 Mac，按 **Pair** 並核對兩邊的六位數驗證碼。
4. 接收端確認驗證碼相同後按 **Accept**；發起端比對相同驗證碼後按
   **Confirm code**。兩邊的簽署決定都完成後，MacKVM 會自動嘗試建立加密連線；若
   狀態仍是 idle，可在已配對裝置列按 **Connect**。控制端（接有鍵盤與滑鼠的 Mac）需要 Input
   Monitoring 與 Accessibility，再選擇 **Request keyboard and mouse control**；接收端也
   需要 Accessibility；新配對的接收端會自動允許該已釘選 Mac，未啟用無縫控制時才需
   按 **Allow** 才會開始遠端輸入。
   任一台 Mac 都可以發起配對。若接收端出現 macOS Firewall 提示，先在接收端允許
   incoming connections；若發起端停在等待狀態，請按 **Cancel pairing**，完成防火牆規則後
   再按 **Retry pairing**。常見的 M5／Intel 配置可改由 Intel Mac 發起，讓 M5 Pro 作為接收端；
   這是防火牆環境的操作 workaround，不是架構上的固定限制。
5. 在 **Paired device information** 查看或修改友善名稱；型號、最後成功連線時間
   與金鑰指紋會保存到本機。新配對的 Mac 會自動啟用無縫控制；若要每次都按 Allow，
   可在這裡關閉 **Automatically allow control from this Mac**。需要回報問題時按
   **Copy support information**。
6. 在任一台 Mac 選取 **Detect DDC-capable displays**，明確選取要控制的外接螢幕；
   M5 Pro 套用 **M5 / USB-C preset**，Intel Mac 套用 **Intel / HDMI preset**。
   Intel 新安裝會以 HDMI 1 作為本機預設；若從舊版升級並保存了 USB-C 設定，請再次套用
   Intel 預設修正本機路由。
   在 M5 Pro 按 **Show other Mac** 時，若控制前置條件已完成，也會開始受保護的鍵盤／滑鼠
   分享；**Share keyboard and mouse with [Intel Mac]** 仍可作為明確的等效操作。Intel Mac
   只有在未啟用該配對裝置的無縫控制時才需要按 **Allow**。若只是切換了螢幕而尚未共享輸入，
   可按 **Return display to this Mac** 恢復本機畫面。
   控制中可隨時按 `Control-Option-Command-Escape` 中斷並把鍵盤與滑鼠還給 M5 Pro。
   `Control-Option-Command-K` 適用於已手動選好螢幕輸入的情況，只切換鍵盤／滑鼠控制權，
   不會啟動自動 DDC 螢幕切換；閒置時會開始請求，控制中或接收中會返回本機／控制端。
   `Control-Option-Command-O` 會沿用 **Show other Mac** 的受保護先切螢幕流程，將螢幕與
   鍵盤／滑鼠一起交給另一台 Mac；如果本機正在接收控制，按下後會結束接收並把螢幕與
   輸入還給控制端。需要在手動螢幕路由下切換鍵盤／滑鼠控制權時，使用
   `Control-Option-Command-K`；`Control-Option-Command-O` 則用於自動切螢幕並同步交接控制權。
   若要從 Intel Mac 切回 M5 Pro，請在 Intel Mac 按 **Return keyboard and mouse to
   [M5 Mac]**；接收端會釋放輸入，螢幕路由也會返回 M5 Pro。
7. 若通知被停用，仍可從選單列 KVM 圖示或 Dock／一般視窗開啟並處理控制請求。
   若啟用登入時自動啟動，登入項目只會啟動背景服務，不會搶焦點開啟完整視窗；
   需要時可從選單列 KVM 圖示或 Dock 重新開啟。

## 文件

- [繁體中文安裝指南](INSTALL.zh-TW.md) · [English installation guide](INSTALL.md)
- [繁體中文架構](ARCHITECTURE.zh-TW.md) · [English architecture](ARCHITECTURE.md)
- [繁體中文驗收清單](MANUAL_TEST.zh-TW.md) · [English acceptance test](MANUAL_TEST.md)
- [繁體中文安全說明](SECURITY.zh-TW.md) · [English security status](SECURITY.md)
- [繁體中文路線圖](ROADMAP.zh-TW.md) · [English roadmap](ROADMAP.md)
- [繁體中文變更記錄](CHANGELOG.zh-TW.md) · [English changelog](CHANGELOG.md)
- [English HTML manual](docs/USER_MANUAL.html) · [繁體中文 HTML 使用手冊](docs/USER_MANUAL.zh-TW.html)
- [English Markdown manual](docs/USER_MANUAL.md) · [繁體中文 Markdown 手冊](docs/USER_MANUAL.zh-TW.md)
