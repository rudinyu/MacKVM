# MacKVM 除錯與診斷手冊

[English](DEBUGGING.md)

本手冊說明如何從 macOS 與 Windows 兩端收集 MacKVM 工作階段的診斷資料，適用於配對、Secure Connect、鍵盤／滑鼠控制或螢幕輸入切換異常。

## 收集報告前

- 一次只重現一個問題，記下發生時間與時區。
- 先確認兩端實際執行的 MacKVM／WindowsKVM 版本與架構。
- 一般配對或控制測試不要使用 `--yes`；它會略過本機同意流程，可能掩蓋通知或權限問題。
- 絕對不要公開 private key、`identity.json`、密碼、access token 或未遮蔽的 IP。MacKVM unified log 會刻意排除私鑰、驗證碼與 wire payload；Windows console 輸出可能包含六位數配對碼、peer ID、裝置名稱與 endpoint，分享前請遮蔽。

## macOS

### 確認安裝版本

MacKVM 視窗標題區會顯示版本與 build；bundle metadata 是可由指令讀取的準確來源：

```sh
plutil -p /Applications/MacKVM.app/Contents/Info.plist \
  | grep -E 'CFBundleShortVersionString|CFBundleVersion|CFBundleIdentifier'
```

### 收集配對、Secure Connect 與螢幕 log

MacKVM 透過三個公開 category 寫入 unified log：`pairing`、`secure-session` 與 `monitor`。請先啟動即時串流，再重現問題：

```sh
log stream --style compact --level debug \
  --predicate 'subsystem == "app.mackvm.MacKVM" AND (category == "pairing" OR category == "secure-session" OR category == "monitor")' \
  | tee "$HOME/Desktop/MacKVM-live-$(date +%Y%m%d-%H%M%S).log"
```

重現失敗後按 `Control-C` 停止。若要取得 unified log 內已存在的事件：

```sh
log show --last 30m --style compact --info --debug \
  --predicate 'subsystem == "app.mackvm.MacKVM" AND (category == "pairing" OR category == "secure-session" OR category == "monitor")' \
  > "$HOME/Desktop/MacKVM-last-30m-$(date +%Y%m%d-%H%M%S).log"
```

重要階段通常包含 `phase=pairing.*`、`phase=handshake.*`、`phase=transport.*`、`phase=input.*` 與 `phase=monitor.*`。log 只記錄縮短的 request／peer ID 與結果，不會記錄六位數驗證碼或加密 payload。

### 複製公開支援資訊

在 MacKVM 視窗按 **Copy support information**，把結果與 log 一起保存。內容只有公開的版本、OS、硬體、顯示器與配對 metadata；公開貼出前仍應檢查名稱、短 ID 與網路資訊。

### 分開測試原生 DDC

如果問題是螢幕 input switching，先取得唯讀報告：

```sh
./scripts/build-ddc-diagnostic.sh --arch universal
./dist/ddc-diagnostic-universal \
  > "$HOME/Desktop/MacKVM-ddc-$(date +%Y%m%d-%H%M%S).log" 2>&1
```

若要明確測試 mapping（螢幕會暫時切換輸入）：

```sh
./dist/ddc-diagnostic-universal --display 1 --scan-inputs \
  --values 15,16,17,18,19,20,21,22,23,24,25,26,27
```

只有在暫時切換螢幕輸入安全時才執行 scan。Apple Silicon 的 `IOAVService` 與 Intel 的 `IOFramebuffer`／`IOI2CInterface` 路徑，請參閱[原生 DDC 說明](Tools/DDCDiagnostic/README.zh-TW.md)。

### 檢查探索與實體連線

如果 Mac 找不到 peer，可執行以下唯讀指令：

```sh
dns-sd -B _mackvm._tcp local
dns-sd -B _mackvm-secure._tcp local
system_profiler SPDisplaysDataType
ifconfig
```

確認兩台 Mac 在同一個可信任網路、MacKVM 已獲 Local Network 權限，且 MA270U 線材路徑使用正確的 USB-C 或 HDMI 輸入。DDC 寫入成功不代表螢幕真的接受該輸入，請以讀回／scan 報告確認。

## Windows

### 為何除錯時建議使用 console

Windows UI 會顯示即時狀態與原生同意對話框，但啟動時會脫離 console。目前 Windows app 沒有持久化檔案 logger，也沒有 Event Viewer provider。除錯時請以 console 模式啟動同一個 receiver，以保留 pairing、mDNS、TCP、handshake 與 input 訊息。

### 確認執行檔並保存完整 log

請在 repository 根目錄執行，或把 `$exe` 改成實際複製的執行檔路徑：

```powershell
$exe = ".\dist\windows\arm64\WindowsKVM.exe"
$log = Join-Path $env:USERPROFILE `
    ("Desktop\WindowsKVM-debug-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))

& $exe --version
& $exe --pairing-listen --name "Windows ARM64" 2>&1 |
    Tee-Object -FilePath $log
```

Windows x86_64 請使用 `dist\windows\x64\WindowsKVM.exe`。保持這個視窗開啟，重現一次 Pair 與一次 Connect；完成後按 `Enter` 或 `Control-C` 停止。除非測試確實需要自動同意，否則不要加 `--yes`。

啟動輸出應包含 pairing 與 Secure Connect 的 TCP port：

```text
Pairing listener ready on TCP ...
Advertised as _mackvm._tcp ...
Secure session listener ready on TCP ...
Advertised as _mackvm-secure._tcp ...
```

### 預期檢查點

配對應看到：

```text
Incoming pairing connection from ...
Verification code: ...
Paired with ...
```

Secure Connect 與控制權應看到：

```text
Incoming secure-session connection from ...
Secure handshake response sent to ...
Secure session authenticated with ...
Windows control granted for ...
```

常見失敗訊息包括 `mDNS ... network error`、`Pairing connection timed out`、`peer is not paired`、`does not support the authenticated disconnect signal` 與 `Secure session connection closed`。請保留錯誤前後的行，完整順序通常比單一錯誤字串更有用。

### 檢查 Windows 網路與防火牆

receiver 執行期間可執行以下唯讀指令：

```powershell
Get-NetConnectionProfile |
    Format-Table Name,InterfaceAlias,NetworkCategory,IPv4Connectivity,IPv6Connectivity

Get-NetFirewallProfile |
    Format-Table Name,Enabled,DefaultInboundAction,DefaultOutboundAction

Get-NetTCPConnection -State Listen |
    Sort-Object LocalPort |
    Format-Table LocalAddress,LocalPort,OwningProcess,State

ipconfig /all
```

顯示標準 Windows Defender Firewall 提示時，作用中的網路應為 `Private`。只允許 WindowsKVM 在可信任 Private network 使用；receiver 會列出隨機分配的 port，從 Mac 測試連線時使用那些值。不要為了讓探索成功而新增寬鬆的 inbound rule。

WindowsKVM 執行時，可在 Mac 檢查 mDNS 是否可見：

```sh
dns-sd -B _mackvm._tcp local
dns-sd -B _mackvm-secure._tcp local
```

若沒有 service，先檢查 VM 的網路模式、多播支援、VPN／Little Snitch 規則與 Windows Private-network firewall，再修改 pairing code。

### 檢查 trust 狀態（不要暴露私密資料）

```powershell
& $exe --list-paired
& $exe --allow-control <peer-id>
& $exe --deny-control <peer-id>
```

這會列出已信任 Mac 的名稱、完整 peer ID 與公開金鑰指紋。Windows identity private key 以 DPAPI 保護，位於 `%LOCALAPPDATA%\MacKVM`；不要複製或附加 `identity.json`。只有在確定要撤銷配對時才使用 `--forget <peer-id>`，之後必須重新 Pair 才能 Connect。`--allow-control` 與 `--deny-control` 只會變更選定釘選 Mac 的本機控制同意決定；常駐 receiver 會在下一個控制請求前重新載入原子寫入的 trust 檔案，因此可由另一個 CLI process 撤銷或恢復，而不需暴露 private key。

## 判讀跨平台報告

- Windows 沒有 `Incoming pairing connection`：配對 protocol 尚未開始，先查 discovery、多播或 firewall。
- Windows 配對完成但沒有 `Incoming secure-session connection`：Mac 使用了過期 endpoint，或 Secure Connect listener 被阻擋。
- 已送出 handshake response 但 authentication 失敗：比對兩端版本、signed capability 與 pinned public key。
- authentication 成功但沒有取得控制權：檢查本機同意對話框、Windows input admission 與 Mac 權限狀態。
- 配對／控制正常但螢幕切換失敗：附上原生 DDC 報告，確認該螢幕實際的 VCP `0x60` mapping。

回報問題時請包含確切版本／架構、重現步驟、Windows console log、macOS unified-log 節錄與 DDC 報告。公開前請遮蔽驗證碼、完整 ID、IP、名稱與所有憑證／帳密資料。

## 相關文件

- [Windows 建置手冊](WINDOWS_BUILD.zh-TW.md)
- [原生 DDC 診斷工具](Tools/DDCDiagnostic/README.zh-TW.md)
- [MacKVM 架構](ARCHITECTURE.zh-TW.md)
- [雙 Mac 驗收測試](MANUAL_TEST.zh-TW.md)
