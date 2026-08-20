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
5. 在 **Paired device information** 查看或修改友善名稱；型號、最後成功連線時間
   與金鑰指紋會保存到本機。新配對的 Mac 會自動啟用無縫控制；若要每次都按 Allow，
   可在這裡關閉 **Automatically allow control from this Mac**。需要回報問題時按
   **Copy support information**。
6. 在任一台 Mac 選取 **Detect DDC-capable displays**，明確選取要控制的外接螢幕；
   M5 Pro 套用 **M5 / USB-C preset**，Intel Mac 套用 **Intel / HDMI preset**。
   在 M5 Pro 可按 **Share keyboard and mouse with [Intel Mac]**，一次切換畫面並
   分享鍵盤與滑鼠；Intel Mac 只有在未啟用該配對裝置的無縫控制時才需要按 **Allow**。
   控制中可隨時按 `Control-Option-Command-Escape` 中斷並把鍵盤與滑鼠還給 M5 Pro。
   `Control-Option-Command-K` 可在分享與本機控制之間切換；閒置時會開始請求，
   控制中或接收中會返回本機／控制端。
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
- [English HTML manual](docs/USER_MANUAL.html) · [繁體中文 HTML 使用手冊](docs/USER_MANUAL.zh-TW.html)
- [English Markdown manual](docs/USER_MANUAL.md) · [繁體中文 Markdown 手冊](docs/USER_MANUAL.zh-TW.md)
