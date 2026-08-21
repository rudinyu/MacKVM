[English](USER_MANUAL.md) · [HTML](USER_MANUAL.zh-TW.html)

# MacKVM 使用手冊

MacKVM 是 macOS app，提供選單列入口與一般控制視窗，讓 14 吋 M5 Pro MacBook Pro
與 2019 Intel MacBook Pro 共用一組鍵盤、滑鼠，並可選擇切換 BenQ MA270U 螢幕。

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
不需要安裝螢幕工具或 Homebrew 套件。螢幕與線材需提供 VESA DDC/CI；部分 MA270U
韌體不會在 OSD 顯示 DDC/CI 開關，MacKVM 會在 macOS 暴露顯示器時使用原生 bridge。

建立本機測試 DMG：

```sh
./scripts/package-dmg.sh --arch universal
./scripts/verify-release.sh --app dist/universal/MacKVM.app --arch universal
```

ad-hoc 簽章只適合本機測試；正式散布需要 Developer ID、hardened runtime 與 Apple
notarization。

## 第一次啟動

在兩台 Mac 點擊選單列 KVM／雙螢幕圖示，或從 Dock／一般視窗開啟 MacKVM，完成
**Set up this Mac**：

1. 啟用 Local Network 並確認 macOS 提示。
2. 請求並授予 Input Monitoring。
3. 請求並授予 Accessibility。
4. 可選擇啟用控制請求通知與 Launch MacKVM at Login。

若之前拒絕過權限，使用對應的 **Settings** 按鈕。

沒有外接螢幕仍可配對與遠端控制；只有自動 DDC 輸入切換與跨螢幕指標定位才需要螢幕。
若由登入項目自動啟動，完整視窗會保持隱藏以免登入時搶走焦點；需要時可從選單列圖示
或 Dock 重新開啟。

## 螢幕設定

1. 在兩台 Mac 都把外接螢幕設為主要顯示器。
2. 在任一台 Mac 按 **Detect DDC-capable displays**，選取要控制的螢幕，再使用相符
   的輸入預設。
3. M5 Pro 與 Intel Mac 在驗證顯示器後都使用原生 DDC/CI。
   MA270U 的 EDID mapping 會把 USB-C 傳成 VCP 19（`0x13`），HDMI 1 傳成 VCP 17（`0x11`）；
   其他型號使用自己的韌體 mapping。依賴新型號前先執行診斷掃描。
   Intel 新安裝會以 HDMI 1 作為本機路由；舊版若保存了 USB-C 設定，請重新套用 Intel 預設。
4. 用 **Show other Mac** 測試；若原生探索或切換失敗，查看診斷、確認線材直接連接，再用
   MA270U OSD 手動切換。若只是切換螢幕，可按 **Return display to this Mac**；控制中的
   緊急快速鍵或接收端的 **Return keyboard and mouse to [M5 Mac]** 操作可恢復本機路由。
   在 M5 Pro 按 **Show other Mac** 時，若控制前置條件已完成，也會使用先切畫面的流程
   分享鍵盤滑鼠；**Share keyboard and mouse with [Intel Mac]** 仍是明確的等效操作。Intel
   Mac 只有在未啟用該配對裝置的無縫控制時才需要按 **Allow**。

### 找出不同螢幕的 input mapping

repository 提供 ARM 與 Intel 共用原生 bridge 的診斷工具：

```sh
./scripts/build-ddc-diagnostic.sh --arch arm64
./scripts/build-ddc-diagnostic.sh --arch x86_64
./scripts/build-ddc-diagnostic.sh --arch universal
```

用相符架構保存系統、EDID、transport 與 VCP `0x60` 資料：

```sh
./dist/ddc-diagnostic-arm64 > arm64-ddc-report.txt 2>&1
./dist/ddc-diagnostic-x86_64 > x86_64-ddc-report.txt 2>&1
```

若螢幕接受 I2C 寫入卻沒有切換，明確啟用 mapping 掃描。它會寫入候選值、讀回驗證，
將相同讀值標記為 `accepted=yes`，並還原開始前的輸入：

```sh
./dist/ddc-diagnostic-universal --display 1 --scan-inputs \
  --values 15,16,17,18,19,27
```

掃描會暫時切換輸入，只有在可以安全切換與還原時才執行；它不會自動修改 MacKVM 的
mapping 原始碼。按下 Ctrl-C 或收到 SIGTERM 時會停止候選值迴圈，仍嘗試還原開始前的
輸入。本專案實測 MA270U 使用 USB-C VCP `19`（`0x13`）與 HDMI 1 VCP `17`（`0x11`）；
其他型號需要自己的掃描。請參閱[診斷工具說明](../Tools/DDCDiagnostic/README.zh-TW.md)。

## 配對與控制

1. 在 **Nearby Macs** 其中一台按 **Pair**。
2. 比對六位數驗證碼與裝置名稱；接收端確認驗證碼一致後按 **Accept**，發起端比對
   相同驗證碼後按 **Confirm code**。
   任一台 Mac 都可以發起配對。若接收端出現 macOS Firewall 提示，先允許 incoming
   connections；發起端若停在等待狀態，完成規則後按 **Cancel pairing**，再按
   **Retry pairing**。在 M5／Intel 配置中，由 Intel Mac 發起可作為 Intel 尚未允許外部
   連入時的 workaround；配對協定本身不綁定架構。
3. 兩邊的簽署決定都完成後，MacKVM 會自動嘗試建立加密連線；若狀態仍是 idle，
   可在已配對裝置列按 **Connect**。鍵盤與滑鼠接在 M5 Pro 時，請按
   **Show other Mac** 或 **Share keyboard and mouse with [Intel Mac]**；在 M5 Pro 兩者
   都會先切換螢幕，再送出控制請求。
4. 新配對的接收端會自動啟用該已釘選 Mac 的無縫控制。若要每次控制都重新按
   **Allow**，請在 **Paired device information** 關閉
   **Automatically allow control from this Mac**。未啟用時，控制端需要 Input Monitoring
   與 Accessibility，接收端也需要 Accessibility，然後按 **Allow**；選單關閉時可用
   macOS 原生 Allow／Deny／Review 通知。
5. M5 Pro 可隨時按 `Control-Option-Command-Escape` 中斷共享；全域
   `Control-Option-Command-K` 不必開啟選單即可切換，閒置時開始請求、控制中或接收中
   返回本機／控制端。`Control-Option-Command-O` 沿用 **Show other Mac** 的受保護流程，
   先切換螢幕再請求鍵盤／滑鼠控制；如果本機正在接收控制，則結束接收並把螢幕與輸入
   還給控制端。要從 Intel Mac
   切回 M5 Pro，請在 Intel Mac 按 **Return keyboard and mouse to [M5 Mac]**；
   控制端也可按 **Return keyboard and mouse to this Mac**。

重連使用有上限的退避時間；已啟用無縫控制的配對裝置不需再次按 Allow，關閉該選項的
裝置才需要重新取得控制同意。**Disconnect**、**Forget** 與 **Quit** 會清除重連意圖。

## 配對裝置與支援資訊

在 **Paired device information** 修改並儲存友善名稱。MacKVM 會保留名稱、廣播型號、
最後成功完成驗證連線的時間，以及已釘選公開金鑰的 SHA-256 指紋。新配對的 Mac 預設
會啟用無縫控制；可在每台配對裝置旁關閉此授權。

遇到問題時按 **Copy support information**。報告包含公開的版本、OS、裝置、UUID、
指紋與連線狀態，不包含私密金鑰、密碼、憑證或網路端點。

## 其他文件

- [HTML 繁體中文手冊](USER_MANUAL.zh-TW.html) · [English HTML manual](USER_MANUAL.html)
- [驗收清單](../MANUAL_TEST.zh-TW.md) · [English acceptance test](../MANUAL_TEST.md)
- [架構說明](../ARCHITECTURE.zh-TW.md) · [English architecture](../ARCHITECTURE.md)
- [安全說明](../SECURITY.zh-TW.md) · [English security](../SECURITY.md)
