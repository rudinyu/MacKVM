[English](USER_MANUAL.md) · [HTML](USER_MANUAL.zh-TW.html)

# MacKVM 使用手冊

MacKVM 是 macOS 選單列 app，讓 14 吋 M5 Pro MacBook Pro 與 2019 Intel MacBook Pro
共用一組鍵盤、滑鼠及 BenQ MA270U 螢幕。

## 硬體與接線

- M5 Pro 以 USB-C 連接 MA270U 的視訊／資料連接埠。
- Intel Mac 以 USB-C／Thunderbolt 轉接器連接 HDMI。
- 鍵盤與滑鼠接在 M5 Pro 或 MA270U USB hub；HDMI 不會把 USB hub 傳給 Intel Mac。
- 建議選 **One keyboard on M5 Pro (USB-C)**。只有兩台 Mac 都透過實體 USB switch
  看見鍵盤與滑鼠時，才選 **External USB switch (bidirectional)**。

## 安裝與建置

在 M5 Pro 建置兩種架構，並把相符的 app 複製到兩台 Mac 的 `/Applications`：

```sh
./scripts/build-app.sh --arch arm64
./scripts/build-app.sh --arch x86_64
```

MacKVM 使用原生 IOKit DDC/CI：Apple Silicon 走 `IOAVService`，Intel 走 `IOI2C`，
不需要安裝螢幕工具或 Homebrew 套件。螢幕與線材需提供 VESA DDC/CI；若 OSD 有此
選項，請先開啟。

建立本機測試 DMG：

```sh
./scripts/package-dmg.sh --arch universal
./scripts/verify-release.sh --app dist/universal/MacKVM.app --arch universal
```

ad-hoc 簽章只適合本機測試；正式散布需要 Developer ID、hardened runtime 與 Apple
notarization。

## 第一次啟動

在兩台 Mac 點擊選單列鍵盤圖示，完成 **Set up this Mac**：

1. 啟用 Local Network 並確認 macOS 提示。
2. 請求並授予 Input Monitoring。
3. 請求並授予 Accessibility。
4. 可選擇啟用控制請求通知與 Launch MacKVM at Login。

若之前拒絕過權限，使用對應的 **Settings** 按鈕。

## 螢幕設定

1. 在兩台 Mac 都把外接螢幕設為主要顯示器。
2. 在任一台 Mac 按 **Detect DDC-capable displays**，選取要控制的螢幕，再使用相符
   的輸入預設。
3. M5 Pro 與 Intel Mac 在驗證顯示器後都使用原生 DDC/CI。
4. 用 **Show this Mac** 與 **Show other Mac** 測試；DDC/CI 失敗時查看診斷並用
   MA270U OSD 手動切換。

## 配對與控制

1. 在 **Nearby Macs** 其中一台按 **Pair**。
2. 比對六位數驗證碼與裝置名稱，只有驗證碼一致時才在兩台按 **Accept**。
3. 按 **Connect**，再從要使用鍵盤與滑鼠的 Mac 發出控制請求。
4. 接收端必須按 **Allow**；選單關閉時可用 macOS 原生 Allow／Deny／Review 通知。
5. 用 **Return input to this Mac**、**Stop remote control** 或
   `Control-Option-Command-Escape` 結束控制。

重連使用有上限的退避時間，但每次都要重新取得控制同意。**Disconnect**、**Forget**
與 **Quit** 會清除重連意圖。

## 配對裝置與支援資訊

在 **Paired device information** 修改並儲存友善名稱。MacKVM 會保留名稱、廣播型號、
最後成功完成驗證連線的時間，以及已釘選公開金鑰的 SHA-256 指紋。

遇到問題時按 **Copy support information**。報告包含公開的版本、OS、裝置、UUID、
指紋與連線狀態，不包含私密金鑰、密碼、憑證或網路端點。

## 其他文件

- [HTML 繁體中文手冊](USER_MANUAL.zh-TW.html) · [English HTML manual](USER_MANUAL.html)
- [驗收清單](../MANUAL_TEST.zh-TW.md) · [English acceptance test](../MANUAL_TEST.md)
- [架構說明](../ARCHITECTURE.zh-TW.md) · [English architecture](../ARCHITECTURE.md)
- [安全說明](../SECURITY.zh-TW.md) · [English security](../SECURITY.md)
