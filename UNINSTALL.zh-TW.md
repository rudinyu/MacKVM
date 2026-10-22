[English](UNINSTALL.md)

# 解除安裝 MacKVM

一般解除安裝時，先結束 MacKVM，再於仍掛載的發行映像檔中雙擊
**Uninstall MacKVM.command**。helper 只會移除通過驗證的
`/Applications/MacKVM.app`，並保留配對信任、身分金鑰、偏好設定與 macOS 隱私權限。
也可以在 Finder 將「應用程式」中的 `MacKVM.app` 移到垃圾桶。

若已啟用 **Launch MacKVM at Login**，請到**系統設定 > 一般 > 登入項目**移除 MacKVM。
macOS 也可能保留本機網路、通知與防火牆項目，需手動確認。

## 明確清除保存資料

選用的清除模式會永久移除目前帳號的 MacKVM 信任與偏好設定、指定的身分 Keychain 項目，
以及受支援的 TCC 權限。重新安裝後，其他裝置仍保存舊配對 pin；請在那些裝置按
**Forget**，再重新配對。重新安裝無法復原已刪除的資料。

若要先預覽清除範圍，保持發行映像檔掛載，開啟 Terminal，並在映像檔根目錄執行：

```sh
./scripts/uninstall-app.sh --purge --dry-run
./scripts/uninstall-app.sh --purge
```

除非加上 `--yes`，清除流程會要求另外確認。**不要對整個 script 使用 `sudo`**；偏好設定、
Keychain 項目與權限都屬於目前登入的使用者。完整清除範圍與 macOS 後續處理請見
[INSTALL.zh-TW.md](INSTALL.zh-TW.md)。
