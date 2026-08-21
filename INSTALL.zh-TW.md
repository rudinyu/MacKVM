[English](INSTALL.md)

# MacKVM 安裝指南

本指南適用於目標雙 Mac 配置：14 吋 Apple Silicon M5 Pro MacBook Pro 以 USB-C
連接 BenQ MA270U，以及 2019 16 吋 Intel MacBook Pro 以 HDMI 連接螢幕。

## 需求

- 兩台 Mac 都使用 macOS 13 或更新版本。
- 兩台 Mac 位於同一個可信任的本機網路。
- 建置 MacKVM 的電腦安裝 Swift 6 toolchain 或 Xcode。
- 外接螢幕與線材需提供 VESA DDC/CI。部分 MA270U 韌體不會在 OSD 顯示
  DDC/CI 開關；MacKVM 會在 macOS 暴露顯示器時使用原生 bridge。

MacKVM 使用原生 IOKit DDC/CI：Apple Silicon 走 `IOAVService`，Intel 走 `IOI2C`。
不需要安裝 Homebrew 工具，兩台 Mac 都能使用自動輸入切換。MA270U 的 USB-C 會依
EDID mapping 使用 `19`／`0x13`；其他型號保留通用值，或先執行診斷掃描再加入 mapping。

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

### 建置原生 DDC 診斷工具

repository 同時提供獨立的 `ddc-diagnostic` 原始碼與建置腳本。可在兩台 Mac 建置
各自架構，或直接在 M5 Pro 建置 universal 版本：

```sh
./scripts/build-ddc-diagnostic.sh --arch arm64
./scripts/build-ddc-diagnostic.sh --arch x86_64
./scripts/build-ddc-diagnostic.sh --arch universal
```

工具會輸出實際執行架構、編譯架構、Mac 型號、macOS build、顯示器 EDID 身份、原生
transport 與 VCP `0x60` 輸入狀態。唯讀報告可保存為：

```sh
./dist/ddc-diagnostic-arm64 > arm64-ddc-report.txt 2>&1
./dist/ddc-diagnostic-x86_64 > x86_64-ddc-report.txt 2>&1
```

當螢幕回報 I2C 寫入成功卻沒有切換畫面時，可明確啟用 mapping 掃描。工具會依序將
候選值寫入 VCP `0x60`、讀回驗證，只把讀回相同的值標記為 accepted，最後還原開始前
的輸入：

```sh
./dist/ddc-diagnostic-universal --display 1 --scan-inputs \
  --values 15,16,17,18,19,27
```

掃描會暫時切換螢幕輸入，只有在可以安全切換並還原原本輸入時才執行。工具不會自動
修改 app mapping。本專案實測 BenQ MA270U 的 USB-C 是 VCP `19`（`0x13`），HDMI 1
是 VCP `17`（`0x11`）；其他型號與韌體必須以掃描結果確認。請參閱[診斷工具說明](Tools/DDCDiagnostic/README.zh-TW.md)
與[原始碼](Tools/DDCDiagnostic/ddc-diagnostic.m)。按下 Ctrl-C 或收到 SIGTERM 時會停止
候選值迴圈，仍嘗試還原開始前的輸入。

建立並驗證本機測試用 universal DMG：

```sh
./scripts/package-dmg.sh --arch universal
./scripts/verify-release.sh \
  --app dist/universal/MacKVM.app \
  --arch universal
(cd dist && shasum -a 256 -c MacKVM-0.12.30-universal.dmg.sha256)
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

MacKVM 會以 KVM／雙螢幕圖示常駐在選單列，也會顯示在 Dock 並提供一般控制視窗。
正常使用時必須開啟 app bundle，不要使用 `swift run`，因為 app bundle 包含 Bonjour
與本機網路隱私權資訊。沒有外接螢幕仍可配對與遠端控制；DDC 切換與跨螢幕指標定位
才需要螢幕。
若由登入項目自動啟動，MacKVM 會隱藏完整視窗以免登入時搶走焦點；需要時可從選單列
KVM 圖示或 Dock 重新開啟。

## 設定螢幕與實體輸入路徑

1. 用 USB-C 視訊／資料連接埠將 M5 Pro 接到 MA270U。
2. 將 Intel Mac 接 HDMI 1；若使用 HDMI 2，後續所有輸入選擇器都一致使用 HDMI 2。
3. 在兩台 Mac 都把 MA270U 設為主要顯示器。
4. 在任一台 Mac 按 **Detect DDC-capable displays**，明確選取要控制的外接螢幕，再套用
   相符的預設。
5. M5 Pro 的 **M5 / USB-C preset** 會選取邏輯上的 USB-C 與另一台 HDMI 1（VCP 17）。
   MA270U 的 EDID mapping 會把 USB-C 傳成 VCP 19／`0x13`；其他型號請先用診斷掃描。
   Intel Mac 的 **Intel / HDMI preset** 會選取本機 HDMI 1，且同樣啟用原生 DDC/CI。
   Intel 新安裝會以 HDMI 1 作為本機預設；從舊版升級且曾保存 USB-C 設定時，請再次套用
   Intel 預設。輸入值會依螢幕型號與韌體而不同。
6. 鍵盤與滑鼠接在 M5 Pro 或 MA270U USB hub 時，選 **One keyboard on M5 Pro
   (USB-C)**；HDMI 不會傳送 USB 資料。
7. 用 **Show other Mac** 測試切換。部分 MA270U 韌體沒有 DDC/CI OSD 開關；若原生
   探索失敗，查看診斷文字、確認線材直接連接，再使用 MA270U OSD 手動選擇輸入。
   若只是切換了螢幕，可按 **Return display to this Mac**；控制中的緊急快速鍵或接收端的
   **Return keyboard and mouse to [M5 Mac]** 操作可恢復本機路由。
   在 M5 Pro 按 **Show other Mac** 時，若控制前置條件已完成，也會開始受保護的鍵盤／滑鼠
   分享；**Share keyboard and mouse with [Intel Mac]** 仍可作為明確的等效操作。Intel Mac
   只有在未啟用該配對裝置的無縫控制時才需按 **Allow**。

只有在兩台 Mac 都透過實體 USB switch 看見鍵盤與滑鼠後，才選
**External USB switch (bidirectional)**。

## 配對與控制兩台 Mac

1. 完成本機網路步驟後，在兩台 Mac 開啟 MacKVM 選單。
2. 在 **Nearby Macs** 其中一台按 **Pair**。
3. 比對兩邊的六位數驗證碼與對方裝置名稱。
4. 接收端確認驗證碼相同後按 **Accept**；發起端比對相同驗證碼後按
   **Confirm code**。
   任一台 Mac 都可以發起。若接收端出現 macOS Firewall 提示，先允許 incoming
   connections；發起端若停在等待狀態，完成規則後按 **Cancel pairing** 再按
   **Retry pairing**。在 M5／Intel 配置中，也可以由 Intel Mac 發起，作為 Intel 尚未允許
   外部連入時的 workaround。
5. 兩邊的簽署決定都完成後，MacKVM 會自動嘗試建立加密連線；若狀態仍是 idle，
   可在已配對裝置列按 **Connect**。
6. 新配對的接收端會自動啟用該已釘選 Mac 的無縫控制。若要每次控制都重新按
   **Allow**，請在 **Paired device information** 關閉
   **Automatically allow control from this Mac**。
7. 在 M5 Pro 按 **Share keyboard and mouse with [Intel Mac]**。這會先把 MA270U
   切到 Intel Mac，再開始鍵盤與滑鼠控制請求。
8. 若接收端已啟用無縫控制，請求會自動核准；否則在接收端按 **Allow**。選單關閉時，
   可用 macOS 原生通知的 Allow／Deny／Review；Review 會開啟 MacKVM 的明確核准對話框。
9. M5 Pro 可隨時按 `Control-Option-Command-Escape` 中斷共享。要從 Intel Mac
   切回 M5 Pro，請在 Intel Mac 按 **Return keyboard and mouse to [M5 Mac]**；
   控制端也可按 **Return keyboard and mouse to this Mac**。全域
   `Control-Option-Command-K` 不必開啟選單即可切換：閒置時開始請求，控制中或接收中
   會把鍵盤與滑鼠返回本機／控制端。`Control-Option-Command-O` 沿用受保護的
   **Show other Mac** 流程：會先切換螢幕，再請求鍵盤／滑鼠控制；如果本機正在接收控制，
   則結束接收並把螢幕與輸入還給控制端。

連線中斷後 MacKVM 會以有上限的退避時間重連；已啟用無縫控制的配對裝置不需再次按
Allow，關閉該選項的裝置才需要重新取得控制同意。**Disconnect**、**Forget** 與
**Quit** 會清除重連意圖。

## 裝置資料與支援資訊

在 **Paired device information** 編輯並儲存友善名稱。MacKVM 會在重新啟動後保留
友善名稱、對方廣播的型號、最後成功完成驗證連線的時間，以及已釘選公開金鑰的
SHA-256 指紋。
新配對的 Mac 預設會啟用無縫控制；可在這裡關閉每台配對裝置的授權。

遇到問題時按 **Copy support information**。支援報告包含公開的版本、作業系統、
裝置、指紋與連線狀態資料，不包含私密金鑰、密碼、憑證或網路端點。

## 其他文件

- [架構說明](ARCHITECTURE.zh-TW.md) · [English architecture](ARCHITECTURE.md)
- [驗收清單](MANUAL_TEST.zh-TW.md) · [English acceptance test](MANUAL_TEST.md)
- [安全說明](SECURITY.zh-TW.md) · [English security status](SECURITY.md)
- [English HTML manual](docs/USER_MANUAL.html) · [繁體中文 HTML 使用手冊](docs/USER_MANUAL.zh-TW.html)
- [English Markdown manual](docs/USER_MANUAL.md) · [繁體中文 Markdown 手冊](docs/USER_MANUAL.zh-TW.md)
