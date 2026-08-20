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
(cd dist && shasum -a 256 -c MacKVM-0.12.4-universal.dmg.sha256)
```

本機 ad-hoc 簽章只能用於測試；正式散布必須使用 Developer ID、hardened runtime
與 Apple notarization。

### 1.1 建置與執行 DDC 診斷工具

從同一份 checkout 建置所有支援的診斷目標：

```sh
./scripts/build-ddc-diagnostic.sh --arch arm64
./scripts/build-ddc-diagnostic.sh --arch x86_64
./scripts/build-ddc-diagnostic.sh --arch universal
```

在實機上分別用原生架構執行並保存唯讀報告：

```sh
./dist/ddc-diagnostic-arm64 > arm64-ddc-report.txt 2>&1
./dist/ddc-diagnostic-x86_64 > x86_64-ddc-report.txt 2>&1
```

確認每份報告都包含實際執行與編譯架構、Mac 型號、macOS build、顯示器 EDID、原生
transport 與 VCP `0x60` 狀態。若型號 mapping 不明，明確執行掃描並把結果放入驗收
紀錄：

```sh
./dist/ddc-diagnostic-universal --display 1 --scan-inputs \
  --values 15,16,17,18,19,27
```

只有 `accepted=yes` 的讀回結果才算 mapping 證據。確認掃描結束後已還原原本輸入，且
工具沒有自動修改 app 原始碼。按下 Ctrl-C 或收到 SIGTERM 時會停止候選值迴圈，仍嘗試
還原開始前的輸入。本專案實測 MA270U 應得到 USB-C `19`（`0x13`）與 HDMI 1 `17`
（`0x11`）。

## 2. 線材、螢幕與實體輸入

1. M5 Pro 接 MA270U USB-C 視訊／資料／供電連接埠。
2. Intel Mac 接 HDMI 1；若使用 HDMI 2，後續所有設定都使用 HDMI 2。
3. 在兩台 Mac 將 MA270U 設為主要顯示器。
4. 部分 MA270U 韌體不會在 OSD 顯示 DDC/CI 開關；不必為了尋找該選項而
   中斷測試，請先確認線材直接連接，再讓 MacKVM 探索原生 DDC bridge。
5. 在任一台 Mac 按 **Detect DDC-capable displays**，明確選取要控制的外接螢幕。
6. M5 Pro 按 **M5 / USB-C preset**；Intel Mac 按 **Intel / HDMI preset**。
7. 鍵盤與滑鼠接 M5 Pro 或 MA270U USB hub，選 **One keyboard on M5 Pro (USB-C)**。
   HDMI 不會把 hub 的 USB 資料傳給 Intel Mac。
8. 只有在兩台 Mac 都能看見實體 USB switch 的裝置時，才選雙向模式。

預期結果：MA270U 的 EDID mapping 會讓 M5 Pro USB-C 路徑使用 VCP 19（`0x13`），Intel
HDMI 1 使用 VCP 17（`0x11`）。其他型號使用自己的 mapping；螢幕可能在 I2C 傳輸成功時
仍靜默忽略未公告的輸入值。新增型號前先執行診斷掃描。

預期結果：**Show this Mac** 顯示 USB-C，**Show other Mac** 顯示指定 HDMI；在 M5 Pro
若控制前置條件已完成，**Show other Mac** 同時開始受保護的鍵盤／滑鼠分享；若前置
條件未完成，仍只執行顯示器切換並讓實體輸入留在本機；原生 DDC/CI 失敗時五秒內回報
診斷並可用 OSD 手動切換，不能悄悄改用不明顯示器。

## 3. macOS 權限

1. 依序完成 Local Network、Input Monitoring、Accessibility。
2. 如果之前拒絕過，使用各項 **Settings** 按鈕到系統設定中允許。
3. 可在第一個控制請求前按 **Enable** 開啟通知權限。
4. 啟用 **Launch MacKVM at Login**，登出／登入後確認鍵盤圖示回來。

預期結果：權限提示不重疊；通知關閉時選單列顯示警示符號，但請求仍保留在選單。

## 4. 探索與配對

1. 兩台都開啟 MacKVM，在 **Nearby Macs** 看見對方。
2. 任一台按 **Pair**，核對兩台相同的六位數驗證碼與對方名稱。
3. 接收端在驗證碼一致時按 **Accept**；發起端比對相同驗證碼後按
   **Confirm code**。
4. 配對完成後按 **Connect**，確認顯示已建立加密連線。

預期結果：公開金鑰只在發起端 Pair／Confirm code、接收端 Accept、雙方完成簽署與 close receipt 後保存；錯誤名稱或驗證碼
不一致時按 **Decline**，不能建立信任。

## 5. 安全重連

1. 連線後拔除網路或讓 peer 暫時離線。
2. 重新連接網路，觀察 0／1／2／4…30 秒退避重連。
3. 測試 **Disconnect**、**Forget** 與退出 app。

預期結果：網路中斷立即停止遠端輸入並釋放按鍵／滑鼠按鈕；重連不需要重新配對，
已啟用無縫控制的 peer 也不需要再次按 **Allow**。手動 Disconnect、Forget 或 Quit
不會再次自動連線。

## 6. 鍵盤、滑鼠與控制同意

1. 配對完成後，在接收端的 **Paired device information** 確認該配對 Mac 的
   **Automatically allow control from this Mac** 已開啟。
2. M5 Pro 控制端按 **Show other Mac**（或明確的 **Share keyboard and mouse with [Intel Mac]**），
   確認不需再次按 Allow 即可開始控制，且螢幕與鍵盤路由一致。
3. 在接收端關閉 **Automatically allow control from this Mac**，回到本機後再次請求控制。
4. 接收端分別測試選單中的 **Allow**、**Deny**、逾時，以及選單關閉時的原生通知
   **Allow**、**Deny**、**Review in MacKVM**。
5. 鎖定接收端，確認通知的 Allow 需要 macOS 身份驗證。
6. 測試打字、移動、點擊、拖曳、滾輪、修飾鍵與四連點。
7. 控制中在控制端切換輸入法（例如開關注音，不改變實體鍵盤配置），確認連線不受
   影響、打出的字元正確。
8. 把兩台 Mac 在**系統設定 → 鍵盤 → 輸入來源**設成真正不同的實體鍵盤配置（例如
   一台 US、一台 Dvorak 或歐規 ABC）。控制中輸入字母、數字、符號，包含需要
   Shift／Option／Caps Lock 的組合，確認接收端打出的字元跟控制端想打的一致，而
   不是控制端 keyCode 在接收端配置下代表的字元。
9. 在配置不同的狀態下——最好其中一台設成字母位置真的會移動的配置，例如德文
   QWERTZ（Y／Z 跟 US 互換位置）——在控制端按 Cmd-Z 復原（undo）一個動作。
10. 在配置不同的狀態下，把控制端的 Caps Lock 打開，重複一次步驟 9 的 Cmd-Z。
11. 在配置不同的狀態下，按住控制端一個可重映射的字母鍵，等 macOS 自動連發啟動，
   連發中途放開 Shift（但不放開該字母鍵），最後再放開該字母鍵。
12. 在配置不同的狀態下，打一個接收端配置沒有對應字元的按鍵，確認遠端輸入安全
    停止（清楚的狀態訊息、沒有卡住的按鍵或滑鼠按鈕），之後重新請求控制能正常
    成功。測試後把兩台恢復成相同鍵盤配置。
13. 如果手邊有更新前（還沒做跨配置重映射）的舊版 MacKVM，跟目前版本配對，把兩台
    設成不同鍵盤配置，雙向各測一次請求控制。
14. 如果手邊有 ISO 或 JIS 實體鍵盤，把兩台設成含有該鍵盤的不同配置，控制中打該
    鍵盤特有的按鍵（例如左 Shift 旁的 ISO 鍵）。
15. 控制中按住控制端實體鍵盤的音量鍵與亮度鍵，確認只有接收端的音量／亮度改變，
    控制端本身不受影響。
16. 控制中按控制端實體鍵盤的電源鍵，確認兩台都沒有任何反應（接收端不會跳出關機
    或睡眠對話框）；按 Caps Lock 確認只切換一次、不會誤觸發兩次。
17. 連線閒置時按 `Control-Option-Command-K`，確認不開啟選單也會開始控制請求；
    控制中再按一次，確認鍵盤與滑鼠返回本機。M5 Pro 也用
    `Control-Option-Command-Escape` 中斷，再用
    **Return keyboard and mouse to this Mac** 結束控制；接收端 Intel Mac
    按 **Return keyboard and mouse to [M5 Mac]** 返回。
18. 若使用雙向 USB switch，在接收端按 `Control-Option-Command-K`，確認控制權返回
    控制端。

預期結果：`Control-Option-Command-K` 可在閒置、控制中與接收中切換正確路由；新配對且啟用無縫控制時不需再次按 Allow；關閉後，接收端按 Allow 前不會抑制本機輸入；控制結束、斷線與取消後不會留下按住
的按鍵或滑鼠按鈕；過期通知不能授權另一個請求；切換輸入法不再誤判為配置不符；
步驟 9 的 Cmd-Z 即使兩台字母位置不同，也要在接收端觸發 Undo——必須落在接收端
真正打得出「z」的按鍵上，不是寄送端原始 keyCode 在接收端配置下代表的字元（以
US 控制、德文接收為例，那會是「y」）；步驟 10 確認寄送端 Caps Lock 開著時，同一個
快捷鍵觸發結果一樣，不會變成 Cmd-Shift-Z（Redo）或其他快捷鍵；步驟 11 放開字母鍵後不會留下卡住或持續連發的字元，連發中途
放開 Shift 不會改變最後放開時對應到的本機按鍵；步驟 13 如果配置不同，目前版本
應該在同意畫面前就拒絕舊版的請求（狀態訊息會提到版本差異），而不是先授權、打第
一個字才中斷；步驟 14 的 ISO／JIS 特有按鍵要打出正確字元，不是照 ANSI 位置解讀
的結果；
只有真的找不到對應字元的按鍵才會安全中止連線；電源鍵在任何情況下都不會傳送到
接收端。

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
| 媒體／系統鍵 |  |  |  |
| 跨配置鍵盤重映射 |  |  |  |
| 控制同意／接收端停止 |  |  |  |
| DDC 螢幕偵測／原生識別碼 |  |  |  |
| ARM64／Intel 診斷報告 |  |  |  |
| VCP 0x60 mapping 掃描／還原 |  |  |  |
| 原生 DDC/CI 切換 |  |  |  |
| OSD 手動備援 |  |  |  |
