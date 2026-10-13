# 三合一操作流程對照

2026-10-13 核對兩個來源，LONZE 所連來源沿用原 Commit，argosbx 操作核對更新至 `864b0e5`：

- [LONZE.IO 文章](https://lonze.io/posts/sing-box-one-click-installer/)所連的 [reality.sh](https://github.com/makessr/sing-box-installer/blob/48177fe4932c8e1dced1fa837fd4e50d51a096be/reality.sh)。
- [argosbx.sh](https://github.com/yonggekkk/argosbx/blob/864b0e542559514004273233f6b2927011efc969/argosbx.sh)。初版曾參考 `29348a0`；新 Commit 移除 `systemd-resolved` 安裝，相關命令入口沒有改變。

兩者的操作入口不同：LONZE 使用反覆返回的數字主選單；argosbx 使用環境變數組及快捷命令。本版以 `agsbx` 命令入口、參數重建及三協定的 Argo 參數對齊後者；`tri-proxy` 保留前者的輔助選單。這是三協定操作相容，不是完整功能或所有參數的 1:1 相容實作。

## 流程差距與改良

| 操作 | 參考流程 | 改良前 | 改良後 |
|---|---|---|---|
| 主選單 1–6 | LONZE：安裝、卸載、重啟、狀態、更新、配置 | 已安裝選單從狀態開始，順序不同 | 前六項操作及順序一致 |
| 返回主選單 | LONZE：操作後返回，可接續操作 | 每次只操作一項便退出 | 按 Enter 返回；錯誤及無效選項也可繼續 |
| 首次安裝 | LONZE 選 1；argosbx 使用變數組 | 預設／自訂兩種旗標 | 保留 Enter 預設安裝；7 為自訂／Argo；亦可用變數組 |
| 解除安裝 | 兩者均有卸載入口 | 沒有 | 選 2 或 `uninstall`／`del`，輸入 `UNINSTALL` 後先備份再移除 |
| 重新安裝 | 解除後可重新安裝 | 沒有完整流程 | 保留已記錄的專用 nologin 帳戶，核對身份後可重新安裝 |
| 快捷命令 | argosbx：`agsbx`，無參數顯示狀態／提示 | 需找回原始腳本 | 自動安裝 `agsbx` 及 `tri-proxy`；前者顯示狀態／命令，後者開啟選單；舊安裝可用 `--install-command` 加入 |
| 配置匯出 | LONZE：`config`；argosbx：`list` | `--show` | 同時接受 `config`、`list`、`--show` |
| 核心更新 | LONZE：`update`；argosbx：`ups` | `--update` | 同時接受 `update`、`ups`；選單可輸入版本 |
| 重啟 | LONZE：`restart`；argosbx：`res` | `--restart` | 同時接受 `restart`、`res` |
| 參數安裝 | argosbx：`vlpt`、`hypt`、`vmpt`、`reym`、`uuid`、`argo`、`agn`、`agk` | 只提供入口地址變數 | 支援上述變數；描述式變數名稱優先 |
| 參數重建 | argosbx：端口變數組配合 `rep`；至少設定一項，空端口沿用 | 須解除後重裝 | `agsbx rep`／`--replace`；空端口沿用，候選配置先驗證，完整備份後重建；失敗回復舊安裝及服務狀態 |
| Argo | argosbx：`argo=vmpt`；`agn/agk` 同時非空為固定入口 | 僅互動自訂安裝 | 互動及 `argo=vmpt` 均支援；保留舊 `argo=yes` 別名；預設關閉；半組固定參數拒絕 |
| 安裝完成 | 參考顯示節點及後續命令 | 顯示連結及配置路徑 | 另顯示快捷命令；互動模式可接續查看狀態／配置 |

## 保留的差異

固定提供 REALITY、Hysteria2、VMess WS。LONZE 的 TUIC／配置缺失自動修復，argosbx 的其他協定、WARP、Xray／`upx`、IPv4／IPv6 匯出切換及公開訂閱服務不在本版範圍。`rep` 重建成功後會生成未指定的身份及憑證；客戶端須匯入新配置。固定三協定必定啟用，所以 `argo=vmpt` 不要求額外以變數選擇 VMess；`argo=vwpt` 不支援。

上游首次空端口隨機選擇 10000–65535；本版保留已確認的預設端口及 30000–50000 避讓。上游只有其中一項固定 Tunnel 參數時會使用臨時入口；本版拒絕半組參數。上游 `rep` 會清理並重建，不能把它稱為保留全部設定的局部修改；本版額外在候選配置驗證後備份，失敗回復原安裝。`rep` 本身已是明確的重建指令，不再增加互動確認。

參考的卸載及一鍵開放端口操作會影響全域防火牆或 shell 設定。本版維持既有 1Panel／OpenResty 防火牆、DNS 及 shell 啟動檔，將兩個快捷命令放在 `/usr/local/bin`，已有其他用途的同名命令時拒絕覆寫；解除安裝使用明確確認及私密備份。

## 驗證

驗收涵蓋選單返回／無效輸入、兩個快捷命令及衝突拒絕、無參數狀態入口、指令別名、開始／停止、取消解除安裝、備份完整性、專用帳戶核對後重裝、臨時／固定 Argo 的環境變數安裝，以及 `rep` 前置驗證、空端口沿用和故障回復。各輪驗證結果記錄於 `tri-proxy-改良進度.md`。
