[English](README.md)

# WindowsKVM

WindowsKVM 是 MacKVM 的 Windows companion。目前 Windows W2 是可在區域網路上與
MacKVM 配對，並完成 secure Connect 驗證的 console receiver。

## 目前功能 — 1.01.02（build 79）

W2 已包含：

- 與 MacKVM 1.00.00 以上版本相容的簽章配對；
- 使用 DPAPI 保護的 Windows identity 儲存；
- 原子寫入且固定公開金鑰的 trusted-peer 儲存，位置為
  `%LOCALAPPDATA%\MacKVM\trusted-peers.json`；
- 不依賴外部套件的雙堆疊 mDNS，廣播 `_mackvm._tcp` 與
  `_mackvm-secure._tcp`；
- 簽章 P-256 ephemeral key exchange、HKDF-SHA256 金鑰導出與
  ChaCha20-Poly1305 key confirmation；
- 有上限的 frame、重播防護、handshake timeout 與連線 admission limit；
- 可在 macOS 或 Windows 執行的 protocol self-test。

W2 已驗證加密傳輸，但還不會在 Windows 注入輸入，也尚未完成最終的鍵盤／滑鼠交接。
WinUI／tray UI、Raw Input、SendInput、加密控制訊息、全域快捷鍵與最小權限防火牆 UX
屬於 W3 工作。

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
4. 如果 Windows peer 是用舊 W1 build 配對，請重新配對一次，讓 W2 建立
   `%LOCALAPPDATA%\MacKVM\trusted-peers.json`。
5. 在 MacKVM 的 Windows peer 上按 **Connect**。

W2 驗證成功時，Windows 應顯示：

```text
Incoming secure-session connection
Secure handshake response sent
Secure session authenticated with ...
```

如果 peer 公開金鑰改變，Windows 會拒絕連線，不會默默覆寫已固定的金鑰。若 identity
檔案無法解密或驗證失敗，receiver 會 fail closed；重設方式請依照[Windows 建置手冊](../WINDOWS_BUILD.zh-TW.md)。

## 相容性

簽章配對支援 Windows 10 build 19041 以上。Secure Connect 需要 Windows build 10.0.20142
以上，因為 W2 使用的 .NET ChaCha20-Poly1305 primitive 從此版本開始可用。較舊 Windows
仍可配對，但執行檔會明確顯示 secure Connect 已停用。

在 Windows 開發主機執行 protocol self-test：

```powershell
.\scripts\test-windows.ps1
```

macOS repository CI 在有 .NET 8 SDK 時也會自動執行這項 self-test。
