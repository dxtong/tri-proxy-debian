# Debian 三合一代理管理

單個 sing-box 核心提供 VLESS REALITY、Hysteria2 及 VMess WS，支援選用 Cloudflare Tunnel。預設 Argo 關閉，客戶端匯出優先使用 Clash／Mihomo。

目標環境為 Debian 11+、amd64／arm64 及 systemd。本儲存庫為公開，可在自己的 VPS 免登入下載並執行：

```bash
curl -fL https://raw.githubusercontent.com/dxtong/tri-proxy-debian/main/outputs/tri-proxy-debian.sh -o tri-proxy-debian.sh && sudo bash tri-proxy-debian.sh
```

首次按 Enter 使用預設安裝；自訂安裝可執行 `sudo bash tri-proxy-debian.sh --custom`。

若下載了整個儲存庫，在 VPS 的儲存庫目錄執行：

```bash
# 首次按 Enter 使用預設安裝。
sudo bash outputs/tri-proxy-debian.sh

# 自訂端口、憑證及 Argo。
sudo bash outputs/tri-proxy-debian.sh --custom
```

安裝後以 `sudo agsbx` 查看狀態及命令提示，或以 `sudo tri-proxy` 開啟循環管理選單。提供端口避讓、狀態／日誌、啟停、重啟、有備份的核心更新／回復、參數重建及備份解除安裝。

代理出口提供「自動、IPv4 優先、IPv6 優先、僅 IPv4、僅 IPv6」，預設自動。IPv6 來源地址由 VPS 自動選用，毋須填入；VPS 須已有可用 IPv6。已安裝可互動選擇或直接切換：

```bash
sudo agsbx egress
sudo agsbx egress prefer_ipv6
sudo agsbx egress ipv4_only
sudo agsbx egress auto
```

舊版安裝先重新下載腳本，再執行 `sudo bash tri-proxy-debian.sh --install-command`。切換保留身份及客戶端匯出，運行中的連線會短暫中斷；失敗嘗試回復。詳見[出口策略及限制](outputs/tri-proxy-使用說明.md#代理出口-ipv4ipv6)。

腳本不修改現有 1Panel／OpenResty、防火牆或 DNS。請按[完整使用說明](outputs/tri-proxy-使用說明.md)設定入口端口；Argo 只轉發 VMess WS，REALITY／Hysteria2 仍是直連入口。這是固定三協定的操作相容實作，並非完整 argosbx 1:1。

## 文件與驗證

- [使用說明](outputs/tri-proxy-使用說明.md)：安裝、客戶端、Argo、管理及回復。
- [操作流程對照](docs/tri-proxy-操作流程對照.md)：與 argosbx／LONZE 的相容範圍及差異。
- [改良進度](docs/tri-proxy-改良進度.md)：來源、決策、驗收結果及測試重跑命令。
- [架構圖](schemas/tri-proxy.md)。
- [容器驗證程式](work/test-tri-proxy.sh)：只可在指定的一次性 Docker 容器內執行。

2026-10-14 的完整 Debian 12 amd64 容器驗證退出碼為 `0`，包括五種出口模式的三協定 TCP 目標連線、雙棧 DNS／IP 限制與回退、出口切換及失敗回復，以及 sing-box／Mihomo 連線、錯誤密碼／憑證 pin、核心更新、Argo 及參數重建回歸。服務管理使用測試替身；IPv6 為 loopback 測試，未驗證公網 IPv6、真實 systemd、VPS、公網防火牆、Cloudflare 帳戶或 arm64。

預設版本為 sing-box 1.14.3；Argo 使用 cloudflared 2026.10.0。憑證私鑰、Token、客戶端配置及安裝備份均包含敏感資料，應保留在自己的伺服器，不提交至 GitHub。代理協定不提供帳戶免封保證。

參考：[argosbx](https://github.com/yonggekkk/argosbx)、[LONZE.IO](https://lonze.io/posts/sing-box-one-click-installer/)。
