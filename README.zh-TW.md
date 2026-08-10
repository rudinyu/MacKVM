[English](README.md)

# RemoteMac self-hosted relay

MacKVM 是原生 macOS 選單列應用程式，讓兩台位於同一本機網路的 Mac 共用一組
鍵盤、滑鼠與 BenQ MA270U 螢幕。配對與控制都需要兩台 Mac 明確同意，控制資料
會透過加密連線傳送。

## 功能

- 選單列常駐鍵盤圖示；有待處理的控制請求時顯示警示符號。
- 保存本機裝置身份、Bonjour 探索與雙方簽署的配對流程。
- 六位數裝置金鑰驗證碼與已配對公開金鑰釘選。
- 保存配對裝置的友善名稱、型號、最後成功連線時間與 SHA-256 金鑰指紋。
- **複製支援資訊**只匯出公開診斷資料，不包含私密金鑰、憑證、密碼或網路端點。
- 使用短期 P-256 金鑰交換、方向分離 HKDF、ChaChaPoly 與序號計數器的加密連線。
- 驗證後的鍵盤、滑鼠、滾輪與修飾鍵轉送，以及明確的 Allow／Deny 控制同意。
- Local Network、Input Monitoring、Accessibility 的循序設定檢查。
- Launch MacKVM at Login、通知 Allow／Deny／Review、斷線安全返回與自動重連。
- 防止 HDMI-only Intel Mac 誤宣稱具備雙向實體輸入的拓撲模式。
- BenQ MA270U 的 m1ddc 輸入切換、穩定顯示器識別碼、DDC 診斷與 OSD 備援。

## 硬體接法

- M5 Pro 14 吋 MacBook Pro：USB-C 連接 BenQ MA270U。
- 2019 16 吋 Intel MacBook Pro：USB-C／Thunderbolt 3 轉 HDMI 連接螢幕。
- 鍵盤與滑鼠：接在 M5 Pro，或接到 MA270U USB hub；HDMI 不會傳送 USB hub。
- 目前建議選 **One keyboard on M5 Pro (USB-C)**，由 M5 Pro 發起控制，Intel Mac
  接收控制。只有在兩台 Mac 都透過實體 USB switch 看見裝置時，才使用雙向模式。

## 需求

- macOS 13 或更新版本。
- Swift 6 toolchain；若要使用完整 Xcode 產物可安裝 Xcode。
- M5 Pro 可選擇安裝 `m1ddc` 以自動切換 MA270U：

  ```sh
  brew install m1ddc
  ```

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

## 第一次使用

1. 在兩台 Mac 安裝並啟動相符架構的 `MacKVM.app`。
2. 依畫面順序授予 Local Network、Input Monitoring 與 Accessibility 權限。
3. 在 **Nearby Macs** 找到另一台 Mac，按 **Pair** 並核對兩邊的六位數驗證碼。
4. 配對完成後按 **Connect**；控制端選擇 **Request control of other Mac**，接收端
   按 **Allow** 才會開始遠端輸入。
5. 在 **Paired device information** 查看或修改友善名稱；型號、最後成功連線時間
   與金鑰指紋會保存到本機。需要回報問題時按 **Copy support information**。
6. 在 M5 Pro 選取 **Detect MA270U**，確認顯示器為 MA270U 後套用 **M5 / USB-C
   preset**；Intel Mac 套用 **Intel / HDMI preset**。
7. 若通知被停用，仍可從選單列鍵盤圖示開啟選單並處理控制請求。

## 文件

- [繁體中文安裝指南](INSTALL.zh-TW.md) · [English installation guide](INSTALL.md)
- [繁體中文架構](ARCHITECTURE.zh-TW.md) · [English architecture](ARCHITECTURE.md)
- [繁體中文驗收清單](MANUAL_TEST.zh-TW.md) · [English acceptance test](MANUAL_TEST.md)
- [繁體中文安全說明](SECURITY.zh-TW.md) · [English security status](SECURITY.md)
- [English HTML manual](docs/USER_MANUAL.html) · [繁體中文 HTML 使用手冊](docs/USER_MANUAL.zh-TW.html)
- [English Markdown manual](docs/USER_MANUAL.md) · [繁體中文 Markdown 手冊](docs/USER_MANUAL.zh-TW.md)
