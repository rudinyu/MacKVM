[English](MANUAL_TEST.md) · [安裝指南](INSTALL.zh-TW.md) · [HTML 手冊](docs/USER_MANUAL.zh-TW.html)

# 雙 Mac 實機驗收清單

本清單用於 BenQ MA270U、2019 16 吋 Intel MacBook Pro（HDMI）與 14 吋 M5 Pro
MacBook Pro（USB-C）的實機驗收。CI 無法模擬螢幕 DDC/CI、實體 USB switch 或
macOS 隱私權提示，因此仍需在兩台實機執行以下步驟。

## 1. 建置與安裝

在 M5 Pro 執行：

```sh
./scripts/ci.sh
./scripts/build-app.sh --arch arm64
./scripts/build-app.sh --arch x86_64
```

將 `dist/arm64/MacKVM.app` 複製到 M5 Pro，將 `dist/x86_64/MacKVM.app` 複製到
Intel Mac 的 `/Applications`，再開啟各自架構的 app。

預期結果：

- `lipo -archs` 分別輸出 `arm64` 與 `x86_64`。
- `codesign --verify --deep --strict` 成功。
- Finder 能顯示 app icon，選單列出現鍵盤圖示，不在 Dock 顯示。
- macOS 在需要時提出 Local Network 權限提示。

建立 release 產物：

```sh
./scripts/package-dmg.sh --arch universal
./scripts/verify-release.sh --app dist/universal/MacKVM.app --arch universal
(cd dist && shasum -a 256 -c MacKVM-0.8.0-universal.dmg.sha256)
```

本機 ad-hoc 簽章只能用於測試；正式散布必須使用 Developer ID、hardened runtime
與 Apple notarization。

## 2. 線材、螢幕與實體輸入

1. M5 Pro 接 MA270U USB-C 視訊／資料／供電連接埠。
2. Intel Mac 接 HDMI 1；若使用 HDMI 2，後續所有設定都使用 HDMI 2。
3. 在兩台 Mac 將 MA270U 設為主要顯示器。
4. 在 MA270U OSD 開啟 DDC/CI（若該選項存在）。
5. 在任一台 Mac 按 **Detect DDC-capable displays**，明確選取要控制的外接螢幕。
6. M5 Pro 按 **M5 / USB-C preset**；Intel Mac 按 **Intel / HDMI preset**。
7. 鍵盤與滑鼠接 M5 Pro 或 MA270U USB hub，選 **One keyboard on M5 Pro (USB-C)**。
   HDMI 不會把 hub 的 USB 資料傳給 Intel Mac。
8. 只有在兩台 Mac 都能看見實體 USB switch 的裝置時，才選雙向模式。

預期結果：**Show this Mac** 顯示 USB-C，**Show other Mac** 顯示指定 HDMI；原生
DDC/CI 失敗時五秒內回報診斷並可用 OSD 手動切換，不能悄悄改用不明顯示器。

## 3. macOS 權限

1. 依序完成 Local Network、Input Monitoring、Accessibility。
2. 如果之前拒絕過，使用各項 **Settings** 按鈕到系統設定中允許。
3. 可在第一個控制請求前按 **Enable** 開啟通知權限。
4. 啟用 **Launch MacKVM at Login**，登出／登入後確認鍵盤圖示回來。

預期結果：權限提示不重疊；通知關閉時選單列顯示警示符號，但請求仍保留在選單。

## 4. 探索與配對

1. 兩台都開啟 MacKVM，在 **Nearby Macs** 看見對方。
2. 任一台按 **Pair**，核對兩台相同的六位數驗證碼與對方名稱。
3. 僅在驗證碼一致時，兩端都按 **Accept**。
4. 配對完成後按 **Connect**，確認顯示已建立加密連線。

預期結果：公開金鑰只在雙方完成簽署、同意與 half-close 後保存；錯誤名稱或驗證碼
不一致時按 **Decline**，不能建立信任。

## 5. 安全重連

1. 連線後拔除網路或讓 peer 暫時離線。
2. 重新連接網路，觀察 0／1／2／4…30 秒退避重連。
3. 測試 **Disconnect**、**Forget** 與退出 app。

預期結果：網路中斷立即停止遠端輸入並釋放按鍵／滑鼠按鈕；重連不需要重新配對，
但必須再次按 **Allow**。手動 Disconnect、Forget 或 Quit 不會再次自動連線。

## 6. 鍵盤、滑鼠與控制同意

1. 控制端按 **Request control of other Mac**。
2. 接收端分別測試選單中的 **Allow**、**Deny**、逾時，以及選單關閉時的原生通知
   **Allow**、**Deny**、**Review in MacKVM**。
3. 鎖定接收端，確認通知的 Allow 需要 macOS 身份驗證。
4. 測試打字、移動、點擊、拖曳、滾輪、修飾鍵與四連點。
5. 控制中變更一台 Mac 的輸入法，確認遠端輸入安全停止。
6. 用 **Return input to this Mac**、接收端 **Stop remote control** 及
   `Control-Option-Command-Escape` 結束控制。

預期結果：接收端按 Allow 前不會抑制本機輸入；控制結束、斷線與取消後不會留下按住
的按鍵或滑鼠按鈕；過期通知不能授權另一個請求。

## 7. 配對資料與支援資訊

1. 在 **Paired device information** 查看友善名稱與型號。
2. 修改友善名稱後按 **Save**，退出並重新開啟 app，確認名稱仍保留。
3. 完成一次加密連線並重新開啟選單，確認 **Last connected** 更新。
4. 確認金鑰指紋是 32 組冒號分隔的十六進位值，重連後保持不變。
5. 按 **Copy support information**，貼到純文字編輯器。
6. 確認報告包含版本、OS、裝置名稱／型號／UUID／指紋與連線狀態，但不包含私密
   金鑰、密碼、憑證或網路端點。

## 8. 身份復原與實體發佈

在測試帳號中造成身份與 Keychain 不一致，確認錯誤畫面只提供明確的
**Reset this Mac identity**。重置後退出並重新開啟，兩台 Mac 必須重新配對，舊公開
金鑰不可再次連線。正式 DMG 另外確認 Developer ID、hardened runtime、checksum
與 Apple notarization；實體 USB switch 與 MA270U OSD 結果填回英文驗收文件的
Acceptance record。

## 驗收紀錄

| 項目 | M5 Pro | Intel 2019 | 結果／備註 |
| --- | --- | --- | --- |
| 原生 app 啟動 |  |  |  |
| 選單列鍵盤圖示 |  |  |  |
| macOS 權限 |  |  |  |
| 啟動時登入 |  |  |  |
| 探索／配對 |  |  |  |
| 裝置資料／支援複製 |  |  |  |
| 安全重連 |  |  |  |
| 鍵盤／滑鼠 |  |  |  |
| 控制同意／接收端停止 |  |  |  |
| DDC 螢幕偵測／原生識別碼 |  |  |  |
| 原生 DDC/CI 切換 |  |  |  |
| OSD 手動備援 |  |  |  |
