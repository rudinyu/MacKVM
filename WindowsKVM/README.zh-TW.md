[English](README.md)

# WindowsKVM

WindowsKVM 是 MacKVM 的 Windows companion。目前 Windows W3 是可在區域網路上與
MacKVM 配對、完成 secure Connect 驗證，並接收加密鍵盤／滑鼠控制的 console receiver。

## 目前功能 — 1.02.02（build 82）

W3 已包含：

- 與 MacKVM 1.00.00 以上版本相容的簽章配對；
- 與 MacKVM 1.100.00／build 75 以上版本相容的 authenticated secure Connect，包含簽名的
  `disconnectSignalVersion` capability 與加密 disconnect acknowledgement；
- 使用 DPAPI 保護的 Windows identity 儲存；
- 原子寫入且固定公開金鑰的 trusted-peer 儲存，位置為
  `%LOCALAPPDATA%\MacKVM\trusted-peers.json`；
- 不依賴外部套件的雙堆疊 mDNS，廣播 `_mackvm._tcp` 與
  `_mackvm-secure._tcp`；
- 簽章 P-256 ephemeral key exchange、HKDF-SHA256 金鑰導出與
  ChaCha20-Poly1305 key confirmation；
- 有上限的 frame、重播防護、handshake timeout 與連線 admission limit；
- 與 MacKVM protocol v2 相容且嚴格驗證 lower-camel control message 與 remote input；
- Windows `SendInput` 鍵盤、修飾鍵、Unicode fallback、滑鼠、按鍵、多媒體鍵與具 unit 區分的
  pixel／line 滾輪注入（包含 pointer pressure 與 trackpad phase metadata）；
- 在控制結束、輸入錯誤、斷線或程式結束時釋放所有按住的按鍵／滑鼠按鈕；
- 共用的 console 同意提示（測試時可用 `--yes`）；
- `Ctrl+Alt+Shift+Esc` 緊急快捷鍵，直接把控制權交還 Windows。

認證輸入使用每秒 rolling packet／byte budget，因此高 polling rate 滑鼠與 trackpad 可以持續
連線，同時避免無上限的輸入 flood。Windows `SendInput` 無法完全重現 macOS momentum phase，
但會保留 wire metadata，並將 pixel movement 轉成 high-resolution wheel unit，不再有舊版的
120 倍放大。

如果 Mac peer 沒有宣告簽名的 disconnect capability，Secure Connect 會刻意
fail closed。配對仍可使用，但必須先更新舊版 Mac，才能建立加密控制 session。

W3 刻意維持 console receiver。WinUI／tray UI、Windows Raw Input 擷取與完整的防火牆
設定精靈留待後續工作。Windows 端不接受未驗證的輸入；只有已配對且完成加密驗證的
Mac session，通過本機同意政策後才能取得控制。

## 建置與啟動

SDK 安裝、架構 publish 與疑難排解請參閱[Windows 建置手冊](../WINDOWS_BUILD.zh-TW.md)。
支援 Windows x64（`win-x64`，也稱 `x86_64`）與 Windows ARM64（`win-arm64`）；不支援
32-bit x86。

```powershell
.\scripts\build-windows.ps1 -Architecture x64
.\scripts\build-windows.ps1 -Architecture arm64
.\dist\windows\x64\WindowsKVM.exe --version
.\dist\windows\x64\WindowsKVM.exe --pairing-listen --name "Windows x64"
```

Windows ARM 請使用 ARM64 執行檔。Windows Defender Firewall 出現提示時，只允許可信任的
Private network；WindowsKVM 不會新增寬鬆或隱藏的防火牆規則。

## 配對與 Connect

1. 在 Windows 啟動 `WindowsKVM.exe --pairing-listen`。
2. 在已配對的 Mac 按 **Pair**，比較兩邊的六位數驗證碼。
3. 驗證碼一致後，在 Windows `Accept pairing?` 提示輸入 `y`。
4. 如果 Windows peer 是用舊 W1 build 配對，請重新配對一次，讓 W2/W3 建立
   `%LOCALAPPDATA%\MacKVM\trusted-peers.json`。
5. 在 MacKVM 的 Windows peer 上按 **Connect**。
6. 在 MacKVM 選 **Request keyboard and mouse control**。確認 Windows console 顯示的
   提示後輸入 `y`；測試時可用 `--yes` 自動接受。
7. 要把控制權交還 Windows，請在 Windows 按 `Ctrl+Alt+Shift+Esc`，或從 MacKVM 結束
   control。兩種路徑都會釋放按住的按鍵／滑鼠按鈕。

W3 驗證並取得控制時，Windows 應顯示：

```text
Incoming secure-session connection
Secure handshake response sent
Secure session authenticated with ...
Windows control granted for ...
```

如果 peer 公開金鑰改變，Windows 會拒絕連線，不會默默覆寫已固定的金鑰。若 identity
檔案無法解密或驗證失敗，receiver 會 fail closed；重設方式請依照[Windows 建置手冊](../WINDOWS_BUILD.zh-TW.md)。

## 相容性

簽章配對支援 Windows 10 build 19041 以上。Secure Connect 需要 Windows build 10.0.20142
以上，因為 W3 使用的 .NET ChaCha20-Poly1305 primitive 從此版本開始可用。較舊 Windows
仍可配對，但執行檔會明確顯示 secure Connect 已停用。

在 Windows 開發主機執行 protocol self-test：

```powershell
.\scripts\test-windows.ps1
```

macOS repository CI 在有 .NET 8 SDK 時也會自動執行這項 self-test。
