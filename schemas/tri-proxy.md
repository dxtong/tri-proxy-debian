# 三合一管理與連線

```mermaid
flowchart LR
  官方Release[GitHub 官方 Release] -->|SHA-256 核對及配置檢查| 管理腳本
  循環主選單 --> 管理腳本
  agsbx命令及參數安裝 --> 管理腳本
  管理腳本 -->|安裝、檢查、啟停及核心更新| singbox[sing-box]
  管理腳本 -->|私密備份| 備份[核心及設定快照]
  備份 -->|核心回復| singbox
  管理腳本 -->|明確確認後備份解除安裝| 安裝快照[私密安裝快照]
  管理腳本 -->|rep 候選驗證後備份重建| 重建快照[完整安裝及服務狀態]
  重建快照 -->|重建失敗回復| 管理腳本
  管理腳本 -->|私密配置匯出| Mihomo客戶端
  Mihomo客戶端 -->|TCP REALITY| singbox
  Mihomo客戶端 -->|UDP Hysteria2| singbox
  Mihomo客戶端 -->|WSS 直連| singbox
  Mihomo客戶端 -->|可選 WSS| Cloudflare
  Cloudflare --> cloudflared
  cloudflared -->|127.0.0.1 的 HTTP WS| singbox
  管理腳本 -->|egress 候選檢查及失敗回復| 出口配置[五種出口地址族策略]
  管理腳本 -->|config／Metadata 及 SHA-256| 出口備份[私密出口備份]
  出口備份 -->|切換失敗回復| 出口配置
  singbox --> 出口配置
  出口配置 -->|系統自動選用來源地址| 目標服務
```

直連端口由 1Panel／供應商防火牆決定可達範圍。Argo 不覆蓋 REALITY 或 Hysteria2 的直連入口。

`agsbx` 無參數顯示狀態及命令，`tri-proxy` 保留循環選單。`rep` 是三協定參數重建，成功後客戶端須重新匯入；空端口沿用原端口。

`egress` 切換保留入口、身份、憑證及客戶端匯出；`rep` 未指定 `EGRESS_MODE` 時沿用原策略。出口 IPv6 毋須填入，VPS 須已配置可用 IPv6；策略不涵蓋 REALITY 握手、cloudflared、DNS 傳輸或 VPS 其他程式。
