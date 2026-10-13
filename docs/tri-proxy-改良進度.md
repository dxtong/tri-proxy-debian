# 三合一腳本改良

## 已確認的範圍

使用者已確認精簡管理版、Clash／Mihomo 匯出優先、Argo 預設關閉。保留 REALITY、Hysteria2、VMess WS，以及自訂模式的臨時／固定 Tunnel。

使用者追加要求對齊參考的操作流程。已核對兩個來源的最新 Commit，差距及取捨記錄於 `tri-proxy-操作流程對照.md`。本輪加入 LONZE 前六項選單順序、循環返回、快捷命令、主要指令及環境變數別名，以及有備份的解除安裝／重新安裝。

管理功能包括選單、端口自動避讓、狀態、日誌、本機檢查、重啟、sing-box 核心更新及核心回復。憑證驗證、官方下載 SHA-256、非 root 服務及秘密檔案權限沿用現有要求。防火牆由既有 1Panel／供應商規則管理。

## 參考來源與取捨

| 來源 | 可採用的行為 | 本次取捨 |
|---|---|---|
| [LONZE.IO 文章](https://lonze.io/posts/sing-box-one-click-installer/)及其 [reality.sh](https://github.com/makessr/sing-box-installer/blob/48177fe4932c8e1dced1fa837fd4e50d51a096be/reality.sh) | 管理選單、端口避讓、狀態及更新 | 文章的第三協定是 TUIC，本次保留 VMess；TCP、UDP 分別檢查端口；更新先驗證及備份 |
| [argosbx](https://github.com/yonggekkk/argosbx/tree/29348a05feba1ba31f920dbc59fed0fec864ed70) | 參數化管理、Mihomo 匯出、兩種 Argo | 維持單個 sing-box 核心；採用私密本機匯出；不引入 WARP、公開 HTTP 訂閱服務、額外協定或自動重寫 shell 啟動檔 |
| [Mihomo TLS 實作](https://github.com/MetaCubeX/mihomo/blob/v1.19.32/component/ca/config.go)及[憑證指紋驗證](https://github.com/MetaCubeX/mihomo/blob/v1.19.32/component/ca/fingerprint.go) | 自簽憑證以 SHA-256 fingerprint 驗證 | 用真實 Mihomo 驗證三種協定及錯誤 fingerprint 拒絕連線；Argo 使用公開 CA，不套用 VPS 自簽憑證的 pin |

argosbx 的 `oap` 選項會更改 iptables 預設政策及清空規則（來源 `argosbx.sh:2627`）；卸載流程在 OpenRC 分支清空 NAT PREROUTING。這些行為不適合直接套用到已有 1Panel 限制的主機。本次只參考行為與介面，自行實作，不執行參考腳本。

## 驗收標準

1. 空白輸入仍可完成預設安裝；固定預設端口被佔用時，選擇未被佔用且不衝突的端口。
2. 生成的 Mihomo 配置可載入，三協定能實際代理請求；錯誤憑證指紋必須拒絕。
3. 已安裝後重新執行會進入管理選單；狀態／日誌不安裝套件或改動設定。
4. 更新前驗證官方資產 SHA-256 及既有配置，備份後原子替換核心；失敗回復舊核心；節點身份及端口不變。
5. Argo 後端保持 loopback；臨時網域刷新及固定網域匯出均有檢查。

## 進度

- 已完成：來源核對、設計取捨確認、用語整理、管理功能、Mihomo 匯出、操作說明及本地驗收。
- 已驗證：Enter 預設安裝、TCP／UDP 端口避讓、三種協定的 sing-box／Mihomo 實際連線、錯誤憑證指紋拒絕，以及管理選單／命令。
- 已驗證：官方核心 1.14.3 → 1.14.2 → 回復 1.14.3，設定檔雜湊不變；模擬故障核心啟動失敗會自動回復，錯誤雜湊／不相容配置被拒絕，停止狀態保留。
- 已驗證：兩種 Argo 配置、模擬本次服務日誌的臨時網域刷新、WSS → loopback WS 實際模擬轉發及 cloudflared 官方檔案／Token 檔案參數。

2026-10-13 完整測試退出碼 `0`，環境為一次性 Debian 12 amd64 容器；sing-box 1.14.3、Mihomo 1.19.32、cloudflared 2026.10.0。重跑命令：

```powershell
docker.exe run --rm --name tri-proxy-verify --mount 'type=bind,source=C:/Users/Dennis/Documents/Codex/2026-07-31/https-raw-githubusercontent-com-wei-shaw,target=/src,readonly' node:24.16.0-bookworm-slim bash /src/work/test-tri-proxy.sh
```

主要交付為 `outputs/tri-proxy-debian.sh`、`outputs/tri-proxy-使用說明.md`；測試在 `work/test-tri-proxy.sh`。沒有本地驗收阻塞或待決選項。

## 操作流程追加改良進度

- 已完成：來源重新核對及流程對照；新主選單、指令別名、快捷命令、環境變數安裝及備份解除安裝實作。
- 已完成驗證：完整測試於 2026-10-13 退出碼 `0`，包含既有連線／安全／更新回歸，以及循環選單、無效輸入、別名、啟停、取消解除安裝、快照及 SHA-256、帳戶身份核對後重裝、臨時／固定 Argo 參數安裝。
- 已完成驗證：從實際快捷命令的同一個選單解除安裝後直接重新安裝，並恢復快捷連結；管理腳本以 root 專用權限保留於 `/var/lib/tri-proxy/manage.sh`。
- 已完成：使用說明、流程對照及架構圖更新；沒有本地驗收阻塞。
- 範圍：只修改本地交付腳本及文件，不操作使用者 VPS；解除安裝及新參數流程在一次性容器內驗證。

不會在使用者 VPS 執行部署。真實 systemd 管理器、Cloudflare 帳戶、公網防火牆及 arm64 仍需要目標環境驗證。

## argosbx 操作相容追加改良

使用者已確認繼續以 argosbx 為主要命令操作基準；仍限定固定三協定、Mihomo 優先及 Argo 預設關閉。核對來源更新為 `864b0e542559514004273233f6b2927011efc969`。

本輪目標：加入 `agsbx` 相容快捷及無參數狀態入口、`rep` 參數重建、空端口沿用、`argo=vmpt` 語意及主要命令提示。現有 `tri-proxy` 選單及旗標繼續可用。

影響範圍為本地安裝器、測試、操作說明、流程對照及架構圖。不部署 VPS，不增加其他協定、Xray、WARP、公開訂閱或修改全域防火牆／shell 啟動檔。

`rep` 會短暫中斷連線，重建身份及憑證後須重新匯入客戶端；明確傳入身份時採用指定值。先驗證下載、憑證及候選配置，再保存私密完整快照；重建失敗須回復舊配置、核心、快捷、開機啟動及運行狀態。已有其他 `agsbx` 命令時拒絕覆寫。

驗收包括：兩個快捷及既有選單、無協定變數拒絕 `rep`、空端口沿用、同端口重建、錯誤參數／下載保留舊安裝、重建啟動失敗回復、原先停止的服務回復停止、Argo 開關及固定模式、半組 Token／網域拒絕，以及三協定連線回歸。

進度：命令入口、參數重建、備份及失敗回復已實作；操作說明、流程對照、用語及架構圖已更新。

2026-10-13 聚焦驗證退出碼 `0`，通過快捷衝突拒絕、無參數狀態入口、`rep` 前置驗證、空端口沿用、端口衝突回復、核心啟動失敗回復、停止／開機啟動狀態回復、Argo 的失敗回復及臨時→固定→關閉切換。亦驗證核心停止但 Argo 運行時，回復不會因 systemd `Wants` 留下被意外啟動的核心。

驗證期間修正測試替身的空白 `return`：在 `EXIT` trap 中會繼承原失敗碼，須明確返回成功或實際狀態。另將 cloudflared help 的 `grep -q` 改為完整讀取，避免 `pipefail` 下的 SIGPIPE 誤報。這些失敗不代表真實 Cloudflare 帳戶或 systemd 運行結果。

2026-10-13 最終完整驗證退出碼 `0`。通過 Bash／ShellCheck、systemd 單元靜態檢查、sing-box／Mihomo 三協定實際 HTTP 代理連線、錯誤密碼及憑證 pin 拒絕、官方核心更新及失敗回復，以及全部操作相容回歸。新增的自訂端口重建亦確認描述式變數優先，其他端口沿用。

本輪已完成本地腳本改良及文件交付，沒有本地驗收阻塞。所有本任務的一次性測試容器已清理，測試資料可透過上述命令重新生成；沒有操作使用者 VPS、1Panel／OpenResty、Cloudflare 帳戶或其他容器。

本次完整驗證的 SHA-256：

- `outputs/tri-proxy-debian.sh`：`0ac019eeeec9a3afb87c8187875ce5cf0ad7bb51972c2a4be86ea93b97e67fe5`。
- `work/test-tri-proxy.sh`：`f22a992d4cd1a22f573215cf1087e55192c6a90a4b1875ee774aa95a71033c2a`。

驗證邊界仍為 Debian 12 amd64 容器，服務管理使用替身、代理核心為真實非 root 行程。未驗證真實 systemd 管理器、VPS、公網防火牆／安全群組、Cloudflare 帳戶或 arm64；完整 argosbx 功能及所有參數不在本次交付範圍。

## GitHub 發佈

2026-10-14 使用者要求推送至 GitHub。已補上儲存庫首頁、Shell 腳本 LF 行尾規則，以及伺服器私密設定／客戶端匯出的 Git 忽略規則；已核對兩個腳本的 SHA-256 與上述完整驗證版本一致。發佈包保留原有腳本、測試及文件，沒有改動代理邏輯。

已初始化本地 `main` 分支並完成首次提交。使用者已選擇在登入的 GitHub 帳戶下新建公開儲存庫 `tri-proxy-debian`，方便直接用網址下載。

已檢查提交內的腳本與本機已測版本一致、README 本機連結有效、Git 忽略規則生效及候選檔案沒有常見的 Token／私鑰標記。發佈準備階段沒有重新執行完整容器測試。

已查證登入帳戶 `dxtong`，建立[公開儲存庫](https://github.com/dxtong/tri-proxy-debian)並推送 `main`；README 已加入免登入下載及安裝命令。Git 登入憑證由 Git Credential Manager 保管，未寫入本儲存庫。

發佈核對已通過：遠端 `main` 與本地提交一致、全部 10 個檔案的清單一致；兩個 Shell 腳本均可匿名下載（HTTP `200`），SHA-256 與上述完整驗證版本一致。首次核對的提交為 `fb6829abb173f5cb18b79c92728570d75a956cfd`；本段發佈記錄亦提交及推送至同一分支。

本輪完成 GitHub 發佈及下載核對；未部署 VPS、未重新執行完整容器測試，原有真實 systemd、Cloudflare 帳戶、公網防火牆及 arm64 的驗證邊界維持不變。
