# 原生 DDC 診斷工具

[English](README.md)

`ddc-diagnostic` 是 MacKVM 使用的原生 DDC/CI bridge 之獨立診斷程式，採取
「先讀取、需要時才寫入」的設計。當螢幕回報 I2C 傳輸成功卻沒有切換輸入，或不同
螢幕韌體對同一連接埠使用不同 VCP 值時，可以用它取得可比對的資料。

它會輸出：

- macOS 版本／build、硬體型號、實際執行架構與工具編譯架構；
- 原生顯示器 selector、EDID 廠商／產品／序號／名稱與 checksum 狀態；
- 使用 Apple Silicon `IOAVService`，或 Intel `IOFramebuffer`／`IOI2C`；
- 支援讀取時，VCP `0x60`（Input Source）的目前值、最大值與型別。

## 建置

在有此 repository 的 Mac 上執行：

```sh
./scripts/build-ddc-diagnostic.sh --arch arm64
./scripts/build-ddc-diagnostic.sh --arch x86_64
./scripts/build-ddc-diagnostic.sh --arch universal
```

程式會輸出到 `dist/ddc-diagnostic-arm64`、`dist/ddc-diagnostic-x86_64` 與
`dist/ddc-diagnostic-universal`。Universal 程式可複製到兩種 Mac 執行。

## 唯讀診斷報告

請使用與 Mac 架構相符的程式，並把輸出保存下來：

```sh
./dist/ddc-diagnostic-arm64 > arm64-ddc-report.txt 2>&1
./dist/ddc-diagnostic-x86_64 > x86_64-ddc-report.txt 2>&1
```

若列出多台外接螢幕，使用 `--display 1` 指定其中一台；要讀取其他 VCP，使用
`--vcp 0x10` 等數值參數。報告只有本機系統與顯示器 metadata，不會讀取 MacKVM
身份、私鑰、密碼或網路憑證。

## 找出 Input mapping

只看「寫入成功」不可靠：螢幕可能接受 I2C 傳輸，卻靜默忽略未支援的輸入值。用
下列明確的 opt-in 掃描，工具會寫入 VCP `0x60`、讀回目前值，只有讀回與候選值
相同才輸出 `accepted=yes`，最後以 `input_scan.mapping` 彙總確認值，並嘗試還原掃描前
讀到的輸入：

```sh
./dist/ddc-diagnostic-universal --display 1 --scan-inputs \
  --values 15,16,17,18,19,27
```

只有在螢幕暫時切換輸入不會造成問題時才執行掃描。若無法讀到掃描前的 VCP 值，
工具不會宣稱候選值已支援；若螢幕完全不支援 VCP 讀取，寫入成功只代表 transport
證據，不代表 mapping 已確認。診斷工具只允許寫入 VCP `0x60`；其他 VCP 可用
`--vcp` 讀取，但不會被修改。按下 Ctrl-C 或程序收到 SIGTERM 時，工具會停止候選值
迴圈，並仍嘗試還原掃描前讀到的輸入。

本專案實測的 BenQ MA270U mapping 是 HDMI 1=`17 (0x11)`、USB-C=`19 (0x13)`。
其他螢幕型號與韌體可能不同，請先以掃描輸出作為證據，再決定是否修改 app mapping。

## ARM 與 Intel 原生路徑

這是一個依編譯架構選擇 native path 的同一套程式：Apple Silicon 使用與 app 相同的
`IOAVService`，Intel 使用與 app 相同的 `IOFramebuffer` + `IOI2CInterface`。請從
同一份 checkout 建置兩個架構，方便直接比較兩台 Mac 的報告。

## 相關專案文件

- [MacKVM 安裝指南](../../INSTALL.zh-TW.md)
- [MacKVM 架構](../../ARCHITECTURE.zh-TW.md)
- [雙 Mac 驗收清單](../../MANUAL_TEST.zh-TW.md)
- [安全狀態](../../SECURITY.zh-TW.md)
