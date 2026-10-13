# Debian 三合一代理管理腳本

目標環境為 Debian 11 或更新版本、amd64／arm64、systemd；已驗證的環境見文末。首次安裝使用 sing-box 1.14.3；啟用 Argo 時另下載 cloudflared 2026.10.0。兩者均從官方 GitHub Release 下載並核對固定 SHA-256。

將 `tri-proxy-debian.sh` 上傳至自己的 VPS，在檔案所在目錄執行：

```bash
# 出現選單後按 Enter，即使用預設安裝。
sudo bash tri-proxy-debian.sh

# 全自動，不需要輸入。
sudo bash tri-proxy-debian.sh --defaults

# 自訂入口地址、端口、憑證、Argo 及出口策略。
sudo bash tri-proxy-debian.sh --custom

# 自動辨識入口 IP 不適用時，明確指定公網 IP。
sudo env SERVER_ADDR=你的公網IP bash tri-proxy-debian.sh --defaults
```

腳本會安裝必要 Debian 套件、建立 `tri-proxy` 系統使用者及專用 systemd 服務，並設定開機啟動。不改現有 1Panel、OpenResty 或防火牆；一般安裝拒絕覆寫既有安裝，只有明確執行 `rep` 才會重建。備份解除安裝後，可核對並重用本腳本記錄的 nologin 帳戶；不接管其他同名帳戶。

首次安裝自動建立 `sudo agsbx` 及 `sudo tri-proxy` 快捷命令，不需重連 SSH。`agsbx` 不帶參數顯示狀態及命令提示，對齊 argosbx 的命令入口；`tri-proxy` 或原始腳本則開啟選單，按 Enter 查看狀態，操作完成後按 Enter 返回。輔助選單前六項保留 LONZE 的操作順序：

```text
1) 一鍵安裝
2) 解除安裝（先備份）
3) 重啟
4) 查看狀態
5) 更新核心
6) 查看配置／節點
7) 自訂安裝（含 Argo）
8) 其他管理（日誌、檢查、回復、啟停、快捷命令、出口策略）
0) 離開
```

舊版安裝要加入或更新快捷命令，將新版腳本上傳後執行：

```bash
sudo bash tri-proxy-debian.sh --install-command
sudo agsbx
sudo tri-proxy
```

預設端口被佔用時，TCP／UDP 分別選擇 30000–50000 內的可用端口；自訂模式會先提供可用的建議值，明確輸入被佔用的端口則中止。最後以安裝輸出的實際端口為準。

## 參數式一鍵安裝

可使用 argosbx 風格的主要變數組，無需互動輸入；固定安裝三種協定：

```bash
# 空白端口變數代表自動選擇；預設 Argo 關閉。
sudo env SERVER_ADDR=你的公網IP vlpt= hypt= vmpt= \
  bash tri-proxy-debian.sh install

# 自訂端口及臨時 Argo；WS 只監聽 loopback。
sudo env SERVER_ADDR=你的公網IP vlpt=24443 hypt=24443 vmpt=2080 argo=vmpt \
  bash tri-proxy-debian.sh install
```

| 描述式變數 | argosbx 風格別名 | 用途 |
|---|---|---|
| `REALITY_PORT` | `vlpt` | REALITY TCP 端口 |
| `HY_PORT` | `hypt` | Hysteria2 UDP 端口 |
| `WS_PORT` | `vmpt` | VMess WS TCP 端口 |
| `REALITY_SNI` | `reym` | REALITY 握手網域 |
| `UUID`、`VMESS_UUID`、`HY_PASSWORD` | `uuid` | 共用身份及密碼；不指定時各自生成 |
| `ARGO_MODE=0/1/2` | `argo=vmpt` | 關閉／臨時／固定；配合下兩項時使用固定模式；舊別名 `argo=yes` 亦可 |
| `ARGO_HOST` | `agn` | 固定公開網域 |
| `CF_TUNNEL_TOKEN` | `agk` | 固定 Tunnel 的 Token 字串 |
| `EGRESS_MODE` | 無 | 代理出口模式；首次預設 `auto` |

描述式變數優先。亦可指定 `TLS_SNI`、`TLS_CERT`、`TLS_KEY`。UUID 須為標準格式，Hysteria2 密碼為 16–128 個字元；單獨指定密碼時 URI 會編碼特殊字元。啟用 Argo 時只提供固定網域或 Token 其中一項會被拒絕，避免誤用臨時 Tunnel；本版不支援 `argo=vwpt`。固定 Tunnel Token 優先在自訂模式隱藏輸入；放在環境變數或命令文字中可能留下 shell 歷史／行程環境記錄。

| 協定 | 預設入口 | 使用方式 |
|---|---|---|
| VLESS REALITY | 24443/TCP | 直連 VPS 公網 IP／DNS-only 網域 |
| Hysteria2 | 24443/UDP | 直連 VPS 公網 IP／DNS-only 網域 |
| VMess WS + TLS | 24444/TCP | 直連 VPS；Mihomo 匯出含憑證 pin |
| VMess WS + Argo | 自訂模式預設 127.0.0.1:2080/TCP | 客戶端連 Tunnel 網域的 443/TLS |

1Panel 及供應商安全群組須放行上述直連端口。既有 80/443 的 Cloudflare IP 限制可以保留；REALITY／Hysteria2 的新端口須允許自己的客戶端來源 IP。Argo 模式的本機 WS 端口不用對外開放，cloudflared 需要出站 7844/TCP 或 UDP。預設入口只監聽 IPv4；入口地址指定 IPv6 時改用 `::`。

## 代理出口 IPv4／IPv6

此選項控制 VPS → 目標網站，三種協定共用；不更改客戶端 → VPS 的入口地址。首次及舊版 Metadata 缺少欄位時預設「自動」。

| 選單 | 參數 | 行為 |
|---|---|---|
| 1 自動 | `auto` | 保留原本 direct 出站的地址族選擇 |
| 2 IPv4 優先 | `prefer_ipv4` | 網域優先 IPv4；TCP 可回退 IPv6 |
| 3 IPv6 優先 | `prefer_ipv6` | 網域優先 IPv6；TCP 可回退 IPv4 |
| 4 僅 IPv4 | `ipv4_only` | 網域只取 IPv4，拒絕 IPv6 IP 目標 |
| 5 僅 IPv6 | `ipv6_only` | 網域只取 IPv6，拒絕 IPv4 IP 目標（包括 mapped IPv4） |

IPv6 地址毋須手動填入：VPS 須已配置可用 IPv6，來源地址由系統路由選用。腳本不替 VPS 配置 IPv6，亦不固定綁定某個地址。沒有可達的 IPv6 時，IPv6 優先的 TCP 可嘗試 IPv4；僅 IPv6 會失敗。僅 IPv6 亦無法連接只有 A 記錄的網站。

```bash
# 已安裝：顯示五種模式選單，Enter 保留目前模式。
sudo agsbx egress

# 直接切換；--egress 亦可。
sudo agsbx egress prefer_ipv6
sudo agsbx egress ipv6_only
sudo agsbx egress auto

# 首次非互動安裝。
sudo env EGRESS_MODE=prefer_ipv6 bash tri-proxy-debian.sh --defaults
```

亦可在「其他管理 → 7 出口策略」或自訂安裝中選擇；`agsbx status` 顯示目前策略。舊安裝須先下載新版腳本並執行 `--install-command` 更新快捷管理腳本。

切換先檢查模式、目前由腳本產生的配置及候選配置，再保存 root 專用備份與 SHA-256 到 `/var/lib/tri-proxy/egress-backups/<時間及隨機碼>/`，然後替換 config／Metadata。原本運行的核心會重啟；原本停止的核心及開機啟動設定維持原狀。UUID、密碼、端口、憑證及客戶端匯出不變，毋須重新匯入。切換及回復會中斷當前連線；替換或啟動失敗會嘗試回復原配置及運行狀態，失敗時列出備份路徑。

DNS、路由或出站經手動修改，或與 Metadata 模式不一致時，切換會拒絕覆寫。備份含密碼／私鑰，目錄 `0700`、檔案 `0600`，不會自動刪除。`--rollback` 仍只回復核心，不回復出口策略。

「優先」只影響送到 VPS 的網域；客戶端已解析的 IP 不會改寫。TCP 使用雙地址族 Fast Fallback，首選成功與否及時序都會影響結果；UDP 不保證在目標無回應時回退。DNS 使用系統 local resolver，DNS 查詢傳輸、REALITY 握手、cloudflared 及 VPS 其他程式不受此策略限制；它不等於全機禁用某地址族。

## Argo 選項

自訂安裝選 `0`：關閉，三協定直連。

選 `1`：Quick Tunnel，免網域及 Token。安裝／重啟時最多等待 30 秒取得網域；未取得時，稍後再執行：

```bash
sudo bash tri-proxy-debian.sh --show
```

Quick Tunnel 網域每次重啟可能改變，需要重新 `--show` 及更新客戶端。Cloudflare 將它定位為測試用途，不提供生產可用性保證。

選 `2`：固定網域。先在 Cloudflare 建立 remotely-managed Tunnel，取得 Token，並將其公開主機名稱指向 `HTTP → 127.0.0.1:2080`。如果修改 WS 端口，Cloudflare 中的服務端口也要一致。腳本只讀取 Token，不替你建立 Cloudflare 帳戶、Tunnel、DNS 或公開主機名稱。Token 存於受限檔案，不會出現在 systemd 的命令列。若為該主機名稱配置 Cloudflare Access，普通代理客戶端通常無法通過其登入頁。

Argo 只處理 VMess WS。REALITY 的 TLS 握手及 Hysteria2 的 UDP 不經這條公開 HTTP Tunnel；三合一同時啟用直連入口，故整台 VPS 不會是「僅 Cloudflare 可達」。

## 客戶端與憑證

安裝後的敏感檔案均在 `/etc/tri-proxy`：

- `links.txt`：三條匯入連結，包含密碼。
- `clash.yaml`：優先使用的完整 Mihomo 配置；Hysteria2／直連 VMess 以 SHA-256 指紋驗證憑證，`skip-cert-verify` 保持 `false`。
- `client.json`：完整 sing-box 客戶端配置；自簽憑證已內嵌，不關閉 TLS 驗證。
- `tls.crt`：可分發給自己的客戶端的公開憑證。
- `tls.key`、`config.json`、`metadata.json`、`tunnel.token`：留在伺服器，不對外分享。

用 SFTP 或 SCP 安全取回 `clash.yaml`，以本機配置匯入使用 Mihomo 核心的客戶端，在「代理」群組選擇節點。已驗證 Mihomo 1.19.32；舊版 Clash 核心未必支援 REALITY／Hysteria2。配置含密碼，沒有公開訂閱網址。Argo 的 VMess 使用 Cloudflare 公開憑證，不套用 VPS 自簽憑證的指紋。

也可以取回 `client.json`，在自己的電腦以相容版本的 sing-box 執行：

```bash
sing-box check -c client.json
sing-box run -c client.json
```

本機 HTTP／SOCKS 代理為 `127.0.0.1:1080`。預設使用 REALITY；要改為其他協定，修改 selector 的 `default` 為 `hysteria2` 或 `vmess`，再重啟客戶端。

直連 VMess 的自簽憑證不會只靠 `vmess://` 連結自動受信任，建議使用 `clash.yaml` 或完整 `client.json`。Hysteria2 URI 使用 `insecure=1` 配合 `pinSHA256` 固定伺服器憑證；必須使用支援該 pin 的客戶端。匯入後如沒有保留 pin，不應使用該連結；改用完整配置。

自訂模式可提供已有 PEM 憑證及無密碼私鑰；腳本會檢查網域、有效期及金鑰配對，然後複製至 `/etc/tri-proxy/tls.crt`、`tls.key`。不會申請或自動續期；後續更新須保留 `root:tri-proxy`、`0640` 權限，再執行 `sudo bash tri-proxy-debian.sh --show` 重新產生並分發客戶端的內嵌憑證／pin。

## 管理及核心更新

```bash
sudo bash tri-proxy-debian.sh              # 已安裝：管理選單
sudo bash tri-proxy-debian.sh --status
sudo bash tri-proxy-debian.sh --logs       # 最近 60 行
sudo bash tri-proxy-debian.sh --check      # 配置、憑證期限、本機端口監聽
sudo bash tri-proxy-debian.sh --show       # 刷新私密匯出；Argo 臨時網域亦會刷新
sudo bash tri-proxy-debian.sh --restart
sudo bash tri-proxy-debian.sh --start
sudo bash tri-proxy-debian.sh --stop
sudo bash tri-proxy-debian.sh --update     # 官方最新正式 sing-box 版本
sudo bash tri-proxy-debian.sh --update 1.14.3
sudo bash tri-proxy-debian.sh --rollback   # 回復最近一次成功更新前的核心
```

狀態／日誌／檢查不安裝套件。`--check` 顯示端口是否有本機監聽，不證明監聽者身份、公網可達性或 Cloudflare Tunnel 狀態。執行實際操作時會取得檔案鎖，等待選單輸入時不佔用管理鎖。

可使用參考的主要指令名稱，舊旗標亦繼續支援：

```bash
sudo agsbx                    # 狀態及命令提示
sudo agsbx list               # config / --show 亦可
sudo agsbx res                # restart / --restart 亦可
sudo agsbx ups                # update / --update 亦可
sudo agsbx update 1.14.3
sudo agsbx status
sudo tri-proxy                # 額外的互動選單
```

更新會核對官方 Release API 的 SHA-256 digest，先以候選核心檢查現有伺服器及 sing-box 客戶端配置，再備份及原子替換核心。缺少有效雜湊或配置不相容便中止；若啟動失敗，會嘗試回復舊核心及原有運行狀態。原本停止的服務在更新／回復後維持停止；運行中的服務會短暫中斷連線。

## argosbx 風格的參數重建

已安裝後，要更改端口或 Argo 模式，可以直接使用 `rep`，不用先解除安裝。至少設定一項 `vlpt`、`hypt`、`vmpt` 或其描述式變數；空值及未指定的端口沿用原端口。固定三協定仍然全部啟用。

```bash
# 以預設值重建身份／憑證，端口及入口地址沿用；Argo 預設關閉。
sudo env vlpt= hypt= vmpt= agsbx rep

# 更改端口，並改為臨時 Argo。
sudo env vlpt=24443 hypt=24443 vmpt=2080 argo=vmpt agsbx rep

# 固定 Tunnel；網域及 Token 必須成對提供。
sudo env vlpt= hypt= vmpt= argo=vmpt agn=你的Tunnel網域 \
  agk=你的TunnelToken agsbx rep

# 關閉 Argo，沿用端口；需在防火牆放行新的 VMess 直連入口。
sudo env vmpt= agsbx rep
```

`rep`／`--replace` 是明確的重建指令，不再要求互動確認。它會先下載並驗證核心、憑證及候選配置，然後保存完整私密快照及服務狀態到 `/var/lib/tri-proxy/replaced/<時間及隨機碼>/`，再停止舊服務及重建。空端口可重用原服務端口；若端口被其他行程佔用或新服務未能啟動，會嘗試回復原配置、核心、快捷命令、運行狀態及開機啟動設定。

重建成功會啟動並啟用新服務。未指定身份時會重新生成 UUID、密碼、REALITY 金鑰及 TLS 憑證；客戶端必須重新匯入。要沿用指定身份，可提供 `uuid`，或分別提供 `UUID`、`VMESS_UUID`、`HY_PASSWORD`；憑證可透過 `TLS_CERT`／`TLS_KEY` 指定。未指定 `EGRESS_MODE` 時沿用原出口策略；其餘未指定選項採用安裝預設，固定 Tunnel 網域／Token 不會自動繼承。快照含秘密，須保密；若自動回復失敗，腳本會列出快照路徑。

本版只提供三協定操作相容；不支援原版其他協定、Xray／`upx`、WARP、IPv4／IPv6 匯出切換或公開訂閱，也不會覆寫已有其他用途的 `agsbx` 快捷命令。已有舊版安裝時，先以新版原始腳本執行 `--install-command` 更新管理腳本。

備份存於 root 專用的 `/var/lib/tri-proxy/backups`，包含核心及設定快照，須保密；不會自動刪除。`--rollback` 只回復核心，保留當前身份、端口及設定；若備份核心不相容於當前設定，會拒絕回復。cloudflared 不會自動升級；快捷管理腳本可由新版檔案執行 `--install-command` 更新。

## 備份解除安裝及重裝

主選單選 `2`，或執行：

```bash
sudo agsbx del                # tri-proxy del / uninstall / --uninstall 亦可
```

只有輸入 `UNINSTALL` 才會執行；Enter 會取消。先保存並檢查完整 tar.gz 快照及 SHA-256，然後停止／停用本腳本的服務，移除專用設定、核心、服務檔案及自己的快捷連結。安裝快照存於 `/var/lib/tri-proxy/removed/<時間及隨機碼>/install.tar.gz`；root 專用目錄，檔案 `0600`，包含憑證私鑰／密碼，須保密。

專用 nologin 帳戶、帳戶身份記錄、管理腳本、先前核心備份及 Debian 套件保留。同一個選單可接續選 1／7 重裝；離開選單後可用原本上傳的腳本，或保留的 root 專用管理腳本：

```bash
sudo bash tri-proxy-debian.sh --custom
# 原始上傳檔案已移走時：
sudo bash /var/lib/tri-proxy/manage.sh --custom
```

重裝會核對並重用本腳本記錄的專用帳戶，生成新身份及憑證；客戶端須重新匯入。已在命令環境指定的身份則按指定值使用。改動既有端口／Argo 模式亦可用上述 `rep` 流程。管理腳本在 `/var/lib/tri-proxy/manage.sh`，只有 root 可讀取／執行；`tri-proxy` 及 `agsbx` 快捷連結在重新安裝後恢復。備份快照保留復原資料；不提供手動將完整快照覆蓋回運行中系統的命令，只有 `rep` 失敗時會自動回復。

## 停用

```bash
sudo systemctl status tri-proxy --no-pager
sudo journalctl -u tri-proxy -n 50 --no-pager

# 有啟用 Argo 才執行。
sudo systemctl status tri-proxy-argo --no-pager
sudo journalctl -u tri-proxy-argo -n 50 --no-pager

# 停用並取消開機啟動，保留檔案以便恢復。
sudo systemctl disable --now tri-proxy
sudo systemctl disable --now tri-proxy-argo
```

安裝失敗時會嘗試停用自己的服務；已安裝的 Debian 套件、系統使用者及新建設定檔會保留供檢查。檔案中的連結、配置及日誌可能包含敏感資訊，不要公開貼出。代理協定不會提供 Claude 帳戶免封保證。

## 已執行的驗證

2026-10-14 重新執行完整 Debian 12 amd64 容器驗收，退出碼 `0`，包含下列既有項目及新增出口驗證：

- 五種模式的 sing-box 三協定實際 HTTP 目標連線：IPv4／IPv6 字面 IP、mapped IPv4、單地址族及雙棧 DNS、優先模式的 TCP 兩方向回退，以及僅模式拒絕另一地址族。
- 出口 CLI／互動選單／自訂安裝／環境變數／非法值拒絕、舊 Metadata、`rep` 沿用及明確覆寫、私密備份權限及 SHA-256、身份／入口／憑證／客戶端匯出保留。
- 手動 DNS／路由／出站拒絕覆寫、候選配置拒絕、啟動及中途替換失敗回復，停止／開機啟動狀態保留；全部既有核心更新、Mihomo、Argo、重建及解除安裝回歸通過。

DNS 及目標 HTTP 使用本機測試服務；IPv6 為 `::1` loopback，不代表 VPS 公網 IPv6 可用。此輪主要驗證 TCP 目標，沒有驗證 UDP 目標的跨地址族回退。

2026-10-13 在一次性 Debian 12 amd64 容器內完成以下驗證，完整測試退出碼為 `0`：

- Bash 語法及 ShellCheck、Enter 預設安裝、TCP／UDP 實際端口衝突避讓、檔案權限、systemd 單元靜態驗證及拒絕重複安裝。
- sing-box 1.14.3 及 Mihomo 1.19.32 的三協定實際 HTTP 代理連線；錯誤 Hysteria2 密碼、未受信任憑證，以及 Mihomo Hysteria2／VMess 錯誤 pin 均被拒絕。
- 管理選單、狀態／日誌／本機檢查／重啟；從官方下載 1.14.2 核心、驗證雜湊後替換，再回復 1.14.3，設定檔雜湊保持一致。
- 故障核心及下載雜湊的模擬測試：啟動失敗會回復核心／運行狀態，錯誤雜湊／不相容配置在替換前被拒絕；停止的服務在更新及回復後不被啟動。
- 兩種 Argo 的生成配置檢查、以模擬本次服務日誌刷新 Quick Tunnel 網域、WSS 前端至 loopback WS 的實際模擬轉發；cloudflared 官方下載雜湊及 `--token-file` 參數。
- 循環選單／無效輸入返回、快捷命令、指令別名、啟停、取消及備份解除安裝、備份 SHA-256、專用帳戶核對後重裝、兩種 Argo 環境變數安裝，以及同一快捷選單內解除後直接重裝。
- `agsbx` 無參數狀態及命令提示、同名命令衝突拒絕、`rep` 無參數／錯誤身份／下載／半組 Argo 參數拒絕；空端口沿用、自訂端口重建及描述式變數優先；端口衝突及核心啟動失敗均回復舊配置、核心、快捷、運行及開機啟動狀態。
- `rep` 的臨時 Argo→固定 Argo→關閉切換；Argo 安裝重建失敗的完整回復，以及原本核心停止、Argo 運行時的 systemd 依賴狀態回復。

詳細流程對照見 `docs/tri-proxy-操作流程對照.md`；驗證及取捨記錄見 `docs/tri-proxy-改良進度.md`。

容器中的 systemd 啟動操作由測試程式代替，代理服務本身以真實非 root 行程運行。未在真實 systemd 管理器、你的 VPS、Cloudflare 帳戶或 arm64 硬件上驗證，也沒有驗證公網防火牆／安全群組。

參考：[LONZE.IO](https://lonze.io/posts/sing-box-one-click-installer/)、[argosbx](https://github.com/yonggekkk/argosbx)、[Mihomo VLESS](https://wiki.metacubex.one/config/proxies/vless/)、[Mihomo Hysteria2](https://wiki.metacubex.one/config/proxies/hysteria2/)、[Mihomo VMess](https://wiki.metacubex.one/config/proxies/vmess/)、[sing-box TLS](https://sing-box.sagernet.org/configuration/shared/tls/)、[Hysteria2 URI](https://v2.hysteria.network/docs/developers/URI-Scheme/)、[Quick Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/do-more-with-tunnels/trycloudflare/)、[Tunnel Token 檔案](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/configure-tunnels/tunnel-run-parameters/#token-file)。
