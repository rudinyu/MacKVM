[English](INSTALL.md)

# MacKVM 安裝指南

本指南適用於目標雙 Mac 配置：14 吋 Apple Silicon M5 Pro MacBook Pro 以 USB-C
連接 BenQ MA270U，以及 2019 16 吋 Intel MacBook Pro 以 HDMI 連接螢幕。

## 需求

- 兩台 Mac 都使用 macOS 13 或更新版本。
- 兩台 Mac 位於同一個可信任的本機網路。
- 建置 MacKVM 的電腦安裝 Swift 6 toolchain 或 Xcode。
- 外接螢幕與線材需提供 VESA DDC/CI；若螢幕 OSD 有 DDC/CI 選項，請先開啟。

MacKVM 使用原生 IOKit DDC/CI：Apple Silicon 走 `IOAVService`，Intel 走 `IOI2C`。
不需要安裝 Homebrew 工具，兩台 Mac 都能使用自動輸入切換。

## 建置 app

建議在 M5 Pro 上建置，因為它可以產生兩種架構：

```sh
./scripts/build-app.sh --arch arm64
./scripts/build-app.sh --arch x86_64
```

把 `dist/arm64/MacKVM.app` 安裝到 M5 Pro，把 `dist/x86_64/MacKVM.app` 安裝到
Intel Mac。建置腳本會驗證 Mach-O 架構與 ad-hoc 簽章。

安裝前執行本機檢查：

```sh
./scripts/ci.sh
```

建立並驗證本機測試用 universal DMG：

```sh
./scripts/package-dmg.sh --arch universal
./scripts/verify-release.sh \
  --app dist/universal/MacKVM.app \
  --arch universal
(cd dist && shasum -a 256 -c MacKVM-0.9.5-universal.dmg.sha256)
```

ad-hoc 簽章只適合本機測試。要提供給其他 Mac，請使用 Developer ID Application、
hardened runtime，並完成 Apple notarization：

```sh
./scripts/package-dmg.sh \
  --arch universal \
  --sign "Developer ID Application: Your Name (TEAMID)" \
  --require-developer-id
```

本 repository 不應存放簽章、notarization 或 Keychain 憑證。

## 安裝並授予權限

1. 將相符架構的 app 複製到兩台 Mac 的 `/Applications`，再開啟 app。
2. 按 **Enable Local Network**，回應 macOS 提示後按 **I handled the macOS prompt**。
3. 按 **Request Input Monitoring** 並授予權限。
4. 按 **Request Accessibility** 並授予權限。
5. 若之前拒絕過權限，按相應的 **Settings** 按鈕到系統設定中開啟。
6. 第一次控制前，可按 **Enable** 開啟控制請求通知。
7. 可選擇開啟 **Launch MacKVM at Login**。

MacKVM 會以鍵盤圖示常駐在選單列，不會顯示在 Dock。正常使用時必須開啟 app
bundle，不要使用 `swift run`，因為 app bundle 包含 Bonjour 與本機網路隱私權資訊。

## 設定螢幕與實體輸入路徑

1. 用 USB-C 視訊／資料連接埠將 M5 Pro 接到 MA270U。
2. 將 Intel Mac 接 HDMI 1；若使用 HDMI 2，後續所有輸入選擇器都一致使用 HDMI 2。
3. 在兩台 Mac 都把 MA270U 設為主要顯示器。
4. 在任一台 Mac 按 **Detect DDC-capable displays**，明確選取要控制的外接螢幕，再套用
   相符的預設。
5. M5 Pro 的 **M5 / USB-C preset** 會選取本機 USB-C、另一台 HDMI 1；Intel Mac 的
   **Intel / HDMI preset** 會選取本機 HDMI 1，且同樣啟用原生 DDC/CI。
6. 鍵盤與滑鼠接在 M5 Pro 或 MA270U USB hub 時，選 **One keyboard on M5 Pro
   (USB-C)**；HDMI 不會傳送 USB 資料。
7. 用 **Show this Mac** 與 **Show other Mac** 測試切換。DDC/CI 失敗時查看診斷文字，
   並使用 MA270U OSD 手動選擇輸入。

只有在兩台 Mac 都透過實體 USB switch 看見鍵盤與滑鼠後，才選
**External USB switch (bidirectional)**。

## 配對與控制兩台 Mac

1. 完成本機網路步驟後，在兩台 Mac 開啟 MacKVM 選單。
2. 在 **Nearby Macs** 其中一台按 **Pair**。
3. 比對兩邊的六位數驗證碼與對方裝置名稱。
4. 只有驗證碼相同時，才在兩台按 **Accept**。
5. 在任一台按 **Connect**。
6. 在要使用鍵盤與滑鼠的 Mac 按 **Request control of other Mac**。
7. 在接收端按 **Allow**。選單關閉時，可用 macOS 原生通知的 Allow／Deny／Review；
   Review 會開啟 MacKVM 的明確核准對話框。
8. 用 **Return input to this Mac**、**Stop remote control**，或
   `Control-Option-Command-Escape` 結束控制。

連線中斷後 MacKVM 會以有上限的退避時間重連，但必須重新取得控制同意。
**Disconnect**、**Forget** 與 **Quit** 會清除重連意圖。

## 裝置資料與支援資訊

在 **Paired device information** 編輯並儲存友善名稱。MacKVM 會在重新啟動後保留
友善名稱、對方廣播的型號、最後成功完成驗證連線的時間，以及已釘選公開金鑰的
SHA-256 指紋。

遇到問題時按 **Copy support information**。支援報告包含公開的版本、作業系統、
裝置、指紋與連線狀態資料，不包含私密金鑰、密碼、憑證或網路端點。

## 其他文件

- [架構說明](ARCHITECTURE.zh-TW.md) · [English architecture](ARCHITECTURE.md)
- [驗收清單](MANUAL_TEST.zh-TW.md) · [English acceptance test](MANUAL_TEST.md)
- [安全說明](SECURITY.zh-TW.md) · [English security status](SECURITY.md)
- [English HTML manual](docs/USER_MANUAL.html) · [繁體中文 HTML 使用手冊](docs/USER_MANUAL.zh-TW.html)
- [English Markdown manual](docs/USER_MANUAL.md) · [繁體中文 Markdown 手冊](docs/USER_MANUAL.zh-TW.md)
