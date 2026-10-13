#!/usr/bin/env bash
# Debian 11+：VLESS REALITY、Hysteria2、VMess WS；可選 Cloudflare Tunnel。
# 官方資產及 SHA-256；保留既有防火牆，管理操作只處理本腳本的安裝。

SB_VERSION=1.14.3
CF_VERSION=2026.10.0
BASE=/etc/tri-proxy
BIN=/opt/tri-proxy
BACKUPS=/var/lib/tri-proxy/backups
COMMAND=/usr/local/bin/tri-proxy
COMPAT_COMMAND=/usr/local/bin/agsbx
ACCOUNT=/var/lib/tri-proxy/account.id
MANAGER=/var/lib/tri-proxy/manage.sh

die() { printf '錯誤：%s\n' "$*" >&2; exit 1; }

valid_port() { [[ $1 =~ ^[1-9][0-9]{0,4}$ ]] && (( 10#$1 <= 65535 )); }
valid_uuid() { [[ $1 =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; }

valid_host() {
    local host=$1 label octet
    [[ -n $host && ${#host} -le 253 ]] || return 1
    if [[ $host == *:* ]]; then
        [[ $host =~ ^[0-9a-fA-F:]+$ ]] && getent ahosts "$host" >/dev/null
    elif [[ $host =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        local -a octets
        IFS=. read -r -a octets <<< "$host"
        for octet in "${octets[@]}"; do
            [[ ${#octet} -le 3 ]] && (( 10#$octet <= 255 )) || return 1
        done
    else
        [[ $host =~ ^[A-Za-z0-9.-]+$ && $host != .* && $host != *. ]] || return 1
        local -a labels
        IFS=. read -r -a labels <<< "$host"
        for label in "${labels[@]}"; do
            [[ ${#label} -ge 1 && ${#label} -le 63 && $label != -* && $label != *- ]] || return 1
        done
    fi
}

ask() {
    local variable=$1 prompt=$2 fallback=$3 answer
    read -r -p "$prompt [$fallback]：" answer || die '輸入中斷；非互動安裝請用 --defaults。'
    printf -v "$variable" '%s' "${answer:-$fallback}"
}

download() {
    curl --fail --location --silent --show-error --retry 3 --connect-timeout 15 \
        --max-time 300 --proto '=https' --proto-redir '=https' "$1" -o "$2"
    printf '%s  %s\n' "$3" "$2" | sha256sum --check --status || die '下載檔案 SHA-256 不符。'
}

is_port_free() {
    local protocol=$1 port=$2 result
    if [[ $protocol == tcp ]]; then
        result=$(ss -H -ltn "sport = :$port") || die '無法檢查 TCP 端口。'
    else
        result=$(ss -H -lun "sport = :$port") || die '無法檢查 UDP 端口。'
    fi
    [[ -z $result ]]
}

port_free() {
    is_port_free "$1" "$2" || die "$2/$1 已被使用，請選擇其他端口。"
}

choose_port() {
    local protocol=$1 preferred=$2 reserved=${3:-0} candidate attempt
    if [[ $preferred != "$reserved" ]] && is_port_free "$protocol" "$preferred"; then
        printf '%s\n' "$preferred"
        return
    fi
    for attempt in {1..100}; do
        candidate=$(shuf -i 30000-50000 -n 1)
        if [[ $candidate != "$reserved" ]] && is_port_free "$protocol" "$candidate"; then
            printf '端口 %s/%s 不可用，自動改用 %s。\n' "$preferred" "$protocol" "$candidate" >&2
            printf '%s\n' "$candidate"
            return
        fi
    done
    die '未找到可用端口。'
}

make_server_config() {
    local directory=$1 listen=0.0.0.0 ws_listen=0.0.0.0
    [[ $SERVER_ADDR != *:* ]] || listen=::
    ws_listen=$listen
    [[ $ARGO_MODE == 0 ]] || ws_listen=127.0.0.1
    jq -n --arg listen "$listen" --arg ws_listen "$ws_listen" \
        --argjson rp "$REALITY_PORT" --argjson hp "$HY_PORT" --argjson wp "$WS_PORT" \
        --arg uuid "$UUID" --arg vmess "$VMESS_UUID" --arg password "$HY_PASSWORD" \
        --arg sni "$REALITY_SNI" --arg private "$REALITY_PRIVATE" --arg sid "$REALITY_SID" \
        --arg path "$WS_PATH" --arg base "$BASE" --arg mode "$ARGO_MODE" '
        {
          log: {level: "warn", timestamp: true},
          inbounds: [
            {type: "vless", tag: "reality", listen: $listen, listen_port: $rp,
             users: [{uuid: $uuid, flow: "xtls-rprx-vision"}],
             tls: {enabled: true, server_name: $sni, reality: {enabled: true,
                   handshake: {server: $sni, server_port: 443},
                   private_key: $private, short_id: [$sid]}}},
            {type: "hysteria2", tag: "hysteria2", listen: $listen, listen_port: $hp,
             users: [{password: $password}], ignore_client_bandwidth: true,
             tls: {enabled: true, alpn: ["h3"], certificate_path: ($base + "/tls.crt"),
                   key_path: ($base + "/tls.key")}},
            ({type: "vmess", tag: "vmess", listen: $ws_listen, listen_port: $wp,
              users: [{uuid: $vmess, alterId: 0}], transport: {type: "ws", path: $path}}
             + if $mode == "0" then
                 {tls: {enabled: true, certificate_path: ($base + "/tls.crt"),
                        key_path: ($base + "/tls.key")}}
               else {} end)
          ],
          outbounds: [{type: "direct", tag: "direct"}],
          route: {final: "direct"}
        }' > "$directory/config.json"
}

make_exports() {
    local directory=$1 vmess_host=$2 cert=$3 uri_host=$SERVER_ADDR vmess_port=$WS_PORT
    local vmess_sni=$TLS_SNI fingerprint vmess_json uri_password
    [[ $uri_host != *:* ]] || uri_host="[$uri_host]"
    if [[ $ARGO_MODE != 0 ]]; then
        vmess_port=443
        vmess_sni=$vmess_host
    fi
    fingerprint=$(openssl x509 -in "$cert" -noout -fingerprint -sha256)
    fingerprint=${fingerprint#*=}
    fingerprint=${fingerprint//:/}
    uri_password=$(jq -rn --arg password "$HY_PASSWORD" '$password | @uri')
    jq -n --arg server "$SERVER_ADDR" --arg vh "$vmess_host" \
        --argjson rp "$REALITY_PORT" --argjson hp "$HY_PORT" --argjson wp "$vmess_port" \
        --arg uuid "$UUID" --arg vmess "$VMESS_UUID" --arg password "$HY_PASSWORD" \
        --arg sni "$REALITY_SNI" --arg public "$REALITY_PUBLIC" --arg sid "$REALITY_SID" \
        --arg tls_sni "$TLS_SNI" --arg vsni "$vmess_sni" --arg path "$WS_PATH" \
        --arg mode "$ARGO_MODE" --rawfile cert "$cert" '
        {
          log: {level: "info"},
          inbounds: [{type: "mixed", tag: "local", listen: "127.0.0.1", listen_port: 1080}],
          outbounds: [
            {type: "selector", tag: "select", outbounds: ["reality", "hysteria2", "vmess"],
             default: "reality"},
            {type: "vless", tag: "reality", server: $server, server_port: $rp,
             uuid: $uuid, flow: "xtls-rprx-vision", tls: {enabled: true, server_name: $sni,
               utls: {enabled: true, fingerprint: "chrome"},
               reality: {enabled: true, public_key: $public, short_id: $sid}}},
            {type: "hysteria2", tag: "hysteria2", server: $server, server_port: $hp,
             password: $password, tls: {enabled: true, server_name: $tls_sni,
               alpn: ["h3"], certificate: [$cert]}},
            {type: "vmess", tag: "vmess", server: $vh, server_port: $wp,
             uuid: $vmess, security: "auto", alter_id: 0,
             tls: ({enabled: true, server_name: $vsni}
                   + if $mode == "0" then {certificate: [$cert]} else {} end),
             transport: {type: "ws", path: $path, headers: {Host: $vh}}}
          ],
          route: {final: "select"}
        }' > "$directory/client.json"
    vmess_json=$(jq -nc --arg host "$vmess_host" --arg port "$vmess_port" \
        --arg id "$VMESS_UUID" --arg path "$WS_PATH" --arg sni "$vmess_sni" '
        {v: "2", ps: "VMess-WS", add: $host, port: $port, id: $id, aid: "0",
         scy: "auto", net: "ws", type: "none", host: $host, path: $path,
         tls: "tls", sni: $sni}')
    {
        printf 'vless://%s@%s:%s?encryption=none&security=reality&type=tcp&flow=xtls-rprx-vision&sni=%s&fp=chrome&pbk=%s&sid=%s#REALITY\n' \
            "$UUID" "$uri_host" "$REALITY_PORT" "$REALITY_SNI" "$REALITY_PUBLIC" "$REALITY_SID"
        printf 'hysteria2://%s@%s:%s/?sni=%s&insecure=1&pinSHA256=%s#Hysteria2\n' \
            "$uri_password" "$uri_host" "$HY_PORT" "$TLS_SNI" "$fingerprint"
        printf 'vmess://%s\n' "$(printf '%s' "$vmess_json" | base64 -w0)"
    } > "$directory/links.txt"
    make_clash "$directory" "$vmess_host" "$vmess_port" "$vmess_sni" "$fingerprint"
}

make_clash() {
    local directory=$1 vmess_host=$2 vmess_port=$3 vmess_sni=$4 fingerprint=$5
    jq -nr --arg server "$SERVER_ADDR" --arg vh "$vmess_host" \
        --arg rp "$REALITY_PORT" --arg hp "$HY_PORT" --arg wp "$vmess_port" \
        --arg uuid "$UUID" --arg vmess "$VMESS_UUID" --arg password "$HY_PASSWORD" \
        --arg sni "$REALITY_SNI" --arg public "$REALITY_PUBLIC" --arg sid "$REALITY_SID" \
        --arg tls_sni "$TLS_SNI" --arg vsni "$vmess_sni" --arg path "$WS_PATH" \
        --arg mode "$ARGO_MODE" --arg pin "$fingerprint" '
"mixed-port: 1080
allow-lan: false
mode: rule
log-level: info
proxies:
  - name: REALITY
    type: vless
    server: \($server | tojson)
    port: \($rp)
    uuid: \($uuid | tojson)
    udp: true
    tls: true
    servername: \($sni | tojson)
    flow: xtls-rprx-vision
    client-fingerprint: chrome
    reality-opts:
      public-key: \($public | tojson)
      short-id: \($sid | tojson)
  - name: Hysteria2
    type: hysteria2
    server: \($server | tojson)
    port: \($hp)
    password: \($password | tojson)
    sni: \($tls_sni | tojson)
    skip-cert-verify: false
    fingerprint: \($pin | tojson)
    alpn: [h3]
  - name: VMess-WS
    type: vmess
    server: \($vh | tojson)
    port: \($wp)
    uuid: \($vmess | tojson)
    alterId: 0
    cipher: auto
    udp: true
    tls: true
    servername: \($vsni | tojson)
    skip-cert-verify: false
\(if $mode == "0" then "    fingerprint: " + ($pin | tojson) + "\n" else "" end)    network: ws
    ws-opts:
      path: \($path | tojson)
      headers:
        Host: \($vh | tojson)
proxy-groups:
  - name: 代理
    type: select
    proxies: [REALITY, Hysteria2, VMess-WS, DIRECT]
rules:
  - MATCH,代理
"' > "$directory/clash.yaml"
}

show_config() {
    [[ -f $BASE/metadata.json ]] || die '未找到本腳本的安裝。'
    local hostname since mode exports attempt
    mode=$(jq -r .ARGO_MODE "$BASE/metadata.json")
    if [[ $mode == 1 ]]; then
        systemctl is-active --quiet tri-proxy-argo.service || die 'Argo 服務未運行。'
        since=$(systemctl show tri-proxy-argo.service -p ActiveEnterTimestamp --value)
        [[ -n $since ]] || die 'Argo 服務未運行。'
        for (( attempt=0; attempt<30; attempt++ )); do
            hostname=$(journalctl -u tri-proxy-argo.service --since "$since" -n 500 -o cat --no-pager \
                | sed -nE 's@.*https://([a-z0-9-]+\.trycloudflare\.com).*@\1@p' | tail -n1)
            [[ -z $hostname ]] || break
            sleep 1
        done
        [[ -n $hostname ]] || die 'Argo 網域尚未產生；稍後再執行 --show 並查看 Argo 日誌。'
    fi
    load_metadata
    if [[ $mode == 0 ]]; then hostname=$SERVER_ADDR; fi
    if [[ $mode == 2 ]]; then hostname=$ARGO_HOST; fi
    if [[ -z ${WORK:-} ]]; then
        WORK=$(mktemp -d /tmp/tri-proxy.XXXXXXXX)
        trap cleanup EXIT
    fi
    exports=$(mktemp -d "$WORK/exports.XXXXXXXX")
    make_exports "$exports" "$hostname" "$BASE/tls.crt"
    install -m 600 "$exports/client.json" "$BASE/client.json"
    install -m 600 "$exports/links.txt" "$BASE/links.txt"
    install -m 600 "$exports/clash.yaml" "$BASE/clash.yaml"
    rm -f -- "$exports/client.json" "$exports/links.txt" "$exports/clash.yaml"
    rmdir -- "$exports"
    printf '\n客戶端連結（包含密碼，請保密）：\n'
    cat "$BASE/links.txt"
    printf '\nsing-box 客戶端配置：%s/client.json\n' "$BASE"
    printf 'Clash／Mihomo 配置：%s/clash.yaml（含憑證指紋，請安全取回後以本機檔案匯入）。\n' "$BASE"
    printf '預設本機 HTTP/SOCKS 代理：127.0.0.1:1080；selector 的 default 可改成 hysteria2 或 vmess。\n'
    printf '直連 VMess 使用本機憑證：其他客戶端須信任 tls.crt；client.json 已包含憑證。\n'
    printf 'Hysteria2 連結須由支援 pinSHA256 的客戶端使用；client.json 會驗證憑證。\n'
}

load_metadata() {
    local variable
    for variable in SERVER_ADDR REALITY_PORT HY_PORT WS_PORT UUID VMESS_UUID HY_PASSWORD \
        REALITY_SNI REALITY_PUBLIC REALITY_SID WS_PATH TLS_SNI ARGO_MODE ARGO_HOST; do
        printf -v "$variable" '%s' "$(jq -er --arg key "$variable" '.[$key]' "$BASE/metadata.json")"
    done
}

cleanup() {
    local status=$?
    trap - EXIT
    if (( status != 0 && REPLACING == 1 )); then
        if restore_replacement; then
            printf '重建失敗，已回復原配置、核心、快捷及服務狀態；備份：%s/install.tar.gz\n' "$INSTALL_SNAPSHOT" >&2
        else
            printf '自動回復未成功，完整備份保留在 %s/install.tar.gz；請查看服務日誌。\n' "$INSTALL_SNAPSHOT" >&2
        fi
    elif (( status != 0 && COMMITTED == 1 )); then
        systemctl disable --now tri-proxy-argo.service tri-proxy.service >/dev/null 2>&1 || true
        printf '\n安裝未完成，已嘗試停用本腳本的服務。新建檔案保留在 %s、%s，請檢查日誌。\n' "$BASE" "$BIN" >&2
    fi
    if (( status != 0 && UPDATING == 1 )); then
        if replace_core "$ROLLBACK_DIR/sing-box" && restart_if_running; then
            printf '更新失敗，已回復原有 sing-box 核心。\n' >&2
        else
            printf '自動回復未成功，舊核心保留在 %s/sing-box；請查看服務日誌。\n' "$ROLLBACK_DIR" >&2
        fi
    fi
    if [[ ${WORK:-} =~ ^/tmp/tri-proxy\.[A-Za-z0-9]+$ ]]; then
        rm -rf -- "$WORK"
    fi
    exit "$status"
}

require_install() {
    [[ -x $BIN/sing-box && -f $BASE/config.json && -f $BASE/metadata.json \
       && -f /etc/systemd/system/tri-proxy.service ]] || die '未找到完整的三合一安裝。'
}

account_owned() {
    [[ -f $ACCOUNT ]] && getent passwd tri-proxy >/dev/null \
        && [[ $(cat "$ACCOUNT") == "$(id -u tri-proxy):$(id -g tri-proxy)" \
              && $(getent passwd tri-proxy | cut -d: -f6-7) == /nonexistent:/usr/sbin/nologin \
              && $(id -nG tri-proxy) == tri-proxy ]]
}

record_account() {
    local uid
    uid=$(id -u tri-proxy)
    [[ $uid -ge 100 && $uid -lt 1000 \
       && $(getent passwd tri-proxy | cut -d: -f6-7) == /nonexistent:/usr/sbin/nologin \
       && $(id -nG tri-proxy) == tri-proxy ]] || die '專用帳戶屬性已改變，請先檢查。'
    install -d -m 700 /var/lib/tri-proxy
    printf '%s:%s\n' "$uid" "$(id -g tri-proxy)" > "$ACCOUNT"
    chmod 600 "$ACCOUNT"
}

check_shortcuts() {
    local command
    for command in "$COMMAND" "$COMPAT_COMMAND"; do
        if [[ -e $command || -L $command ]]; then
            [[ -L $command && $(readlink "$command") == "$MANAGER" ]] || die "$command 已被其他程式使用。"
        fi
    done
}

setup_manager() {
    require_install
    check_shortcuts
    local source command
    source=${BASH_SOURCE[0]}
    [[ -e $source ]] || source=$MANAGER
    install -d -m 700 /var/lib/tri-proxy
    if [[ $(realpath -e "$source") != "$MANAGER" ]]; then
        install -m 700 "$source" /var/lib/tri-proxy/.manage.new
        mv -f -- /var/lib/tri-proxy/.manage.new "$MANAGER"
    fi
    [[ -d /usr/local/bin ]] || install -d -m 755 /usr/local/bin
    for command in "$COMMAND" "$COMPAT_COMMAND"; do
        [[ -L $command ]] || ln -s "$MANAGER" "$command"
    done
    printf '快捷命令已可使用：sudo agsbx（狀態／命令）；sudo tri-proxy（選單）。\n'
}

snapshot_install() {
    require_install
    local kind=$1 command
    local -a paths=(etc/tri-proxy opt/tri-proxy etc/systemd/system/tri-proxy.service)
    [[ $(realpath -e "$BASE") == /etc/tri-proxy && $(realpath -e "$BIN") == /opt/tri-proxy \
       && ! -L /etc/systemd/system/tri-proxy.service ]] || die '安裝路徑已改變，拒絕移除。'
    record_account
    [[ $kind == removed || $kind == replaced ]] || die '備份類型無效。'
    install -d -m 700 "/var/lib/tri-proxy/$kind"
    INSTALL_SNAPSHOT=$(mktemp -d "/var/lib/tri-proxy/$kind/$(date -u +%Y%m%dT%H%M%SZ)-XXXXXXXX")
    if [[ -f /etc/systemd/system/tri-proxy-argo.service ]]; then
        [[ ! -L /etc/systemd/system/tri-proxy-argo.service ]] || die 'Argo 服務檔案為外部連結，拒絕解除安裝。'
        paths+=(etc/systemd/system/tri-proxy-argo.service)
    fi
    [[ ! -f $MANAGER ]] || paths+=(var/lib/tri-proxy/manage.sh)
    for command in "$COMMAND" "$COMPAT_COMMAND"; do
        if [[ -L $command && $(readlink "$command") == "$MANAGER" ]]; then paths+=("${command#/}"); fi
    done
    tar -czf "$INSTALL_SNAPSHOT/install.tar.gz" -C / -- "${paths[@]}"
    tar -tzf "$INSTALL_SNAPSHOT/install.tar.gz" >/dev/null
    (cd "$INSTALL_SNAPSHOT"; sha256sum install.tar.gz > SHA256SUMS; sha256sum --check --status SHA256SUMS)
}

remove_install() {
    local command
    local -a units=()
    [[ ! -f /etc/systemd/system/tri-proxy.service ]] || units+=(tri-proxy.service)
    [[ ! -f /etc/systemd/system/tri-proxy-argo.service ]] || units+=(tri-proxy-argo.service)
    if (( ${#units[@]} > 0 )); then systemctl disable --now "${units[@]}" || return 1; fi
    rm -f -- /etc/systemd/system/tri-proxy.service /etc/systemd/system/tri-proxy-argo.service || return 1
    for command in "$COMMAND" "$COMPAT_COMMAND"; do
        if [[ -L $command && $(readlink "$command") == "$MANAGER" ]]; then rm -f -- "$command" || return 1; fi
    done
    rm -rf -- /etc/tri-proxy /opt/tri-proxy || return 1
    systemctl daemon-reload || return 1
}

manage_uninstall() {
    require_install
    local answer
    printf '解除安裝會停止本腳本的服務，備份後移除設定、核心及快捷命令。\n'
    read -r -p '輸入 UNINSTALL 確認；其他輸入取消：' answer || answer=
    if [[ $answer != UNINSTALL ]]; then printf '已取消解除安裝。\n'; return; fi
    snapshot_install removed
    remove_install
    printf '已解除安裝；私密備份：%s/install.tar.gz\n' "$INSTALL_SNAPSHOT"
    printf '專用 nologin 帳戶、管理腳本及既有核心備份保留；可重新安裝。\n'
}

begin_replacement() {
    local unit active enabled
    snapshot_install replaced
    printf '{}\n' > "$INSTALL_SNAPSHOT/services.json"
    for unit in tri-proxy.service tri-proxy-argo.service; do
        [[ -f /etc/systemd/system/$unit ]] || continue
        active=false; enabled=false
        if systemctl is-active --quiet "$unit"; then active=true; fi
        if systemctl is-enabled --quiet "$unit"; then enabled=true; fi
        jq --arg unit "$unit" --argjson active "$active" --argjson enabled "$enabled" \
            '. + {($unit): {active: $active, enabled: $enabled}}' "$INSTALL_SNAPSHOT/services.json" \
            > "$INSTALL_SNAPSHOT/.services.new"
        mv -f -- "$INSTALL_SNAPSHOT/.services.new" "$INSTALL_SNAPSHOT/services.json"
    done
    (cd "$INSTALL_SNAPSHOT"; sha256sum install.tar.gz services.json > SHA256SUMS; sha256sum --check --status SHA256SUMS)
    printf '候選配置已通過；重建會短暫中斷連線，完整備份：%s/install.tar.gz\n' "$INSTALL_SNAPSHOT"
    REPLACING=1
    remove_install
}

restore_replacement() {
    [[ $INSTALL_SNAPSHOT == /var/lib/tri-proxy/replaced/* \
       && $(realpath -e "$INSTALL_SNAPSHOT") == "$INSTALL_SNAPSHOT" ]] || return 1
    (cd "$INSTALL_SNAPSHOT"; sha256sum --check --status SHA256SUMS) || return 1
    remove_install || return 1
    tar -xzf "$INSTALL_SNAPSHOT/install.tar.gz" -C / || return 1
    systemctl daemon-reload || return 1
    local unit
    for unit in tri-proxy.service tri-proxy-argo.service; do
        jq -e --arg unit "$unit" 'has($unit)' "$INSTALL_SNAPSHOT/services.json" >/dev/null || continue
        if jq -e --arg unit "$unit" '.[$unit].enabled' "$INSTALL_SNAPSHOT/services.json" >/dev/null; then
            systemctl enable "$unit" || return 1
        else systemctl disable "$unit" || return 1; fi
        if jq -e --arg unit "$unit" '.[$unit].active' "$INSTALL_SNAPSHOT/services.json" >/dev/null; then
            systemctl start "$unit" || { printf '原服務 %s 啟動失敗。\n' "$unit" >&2; return 1; }
            sleep 2
            systemctl is-active --quiet "$unit" || { printf '原服務 %s 未恢復運行。\n' "$unit" >&2; return 1; }
        fi
    done
    # Argo 的 Wants 可能連帶啟動核心，最後還原原先停止的服務。
    for unit in tri-proxy-argo.service tri-proxy.service; do
        if jq -e --arg unit "$unit" 'has($unit) and (.[$unit].active | not)' "$INSTALL_SNAPSHOT/services.json" >/dev/null; then
            systemctl stop "$unit" || return 1
        fi
    done
}

menu() {
    local choice option version result installed
    while true; do
        installed=0
        [[ ! -f $BASE/metadata.json ]] || installed=1
        printf '\n========== 三合一代理管理 ==========\n'
        printf '系統：%s；架構：%s\n' "$(. /etc/os-release; printf '%s' "$PRETTY_NAME")" "$(uname -m)"
        if (( installed == 1 )); then
            printf '已安裝：'
            "$BIN/sing-box" version 2>/dev/null | sed -n '1p' || true
            if systemctl is-active --quiet tri-proxy.service; then printf '核心狀態：運行中\n';
            else printf '核心狀態：已停止或異常\n'; fi
            printf 'Enter 預設查看狀態。\n'
        else printf '尚未安裝；Enter 預設一鍵安裝，Argo 關閉。\n'; fi
        printf '1) 一鍵安裝\n2) 解除安裝（先備份）\n3) 重啟\n4) 查看狀態\n5) 更新核心\n6) 查看配置／節點\n7) 自訂安裝（含 Argo）\n8) 其他管理\n0) 離開\n'
        if ! read -r -p '請選擇 [0–8]：' choice; then return; fi
        if [[ -z $choice ]]; then
            if (( installed == 1 )); then choice=4; else choice=1; fi
        fi
        version=
        case $choice in
            0) return ;;
            1|7)
                if (( installed == 1 )); then printf '已安裝；可用端口變數配合 agsbx rep 重建，或先選 2 備份解除安裝。\n'; continue; fi
                if [[ $choice == 1 ]]; then option=--defaults; else option=--custom; fi ;;
            2) option=--uninstall ;; 3) option=--restart ;; 4) option=--status ;;
            5) option=--update; read -r -p '正式版本 [latest]：' version || return ;;
            6) option=--show ;;
            8)
                printf '1) 日誌\n2) 本機檢查\n3) 回復核心\n4) 啟動\n5) 停止\n6) 安裝／更新快捷命令\n0) 返回\n'
                if ! read -r -p '請選擇 [0–6]：' choice; then return; fi
                case $choice in
                    0|'') continue ;; 1) option=--logs ;; 2) option=--check ;;
                    3) option=--rollback ;; 4) option=--start ;; 5) option=--stop ;;
                    6) option=--install-command ;; *) printf '選項無效。\n'; continue ;;
                esac ;;
            *) printf '選項無效，請重新選擇。\n'; continue ;;
        esac
        # 選單捕捉子行程退出碼；子行程保留自己的 errexit 及失敗回復。
        set +e
        if [[ $option == --update ]]; then main "$option" "${version:-latest}";
        else main "$option"; fi
        result=$?
        set -e
        if (( result != 0 )); then printf '操作未完成（退出碼 %s）；可查看日誌後再試。\n' "$result"; fi
        if ! read -r -p '按 Enter 返回主選單：'; then return; fi
    done
}

replace_core() {
    install -m 755 "$1" "$BIN/.sing-box.new" || return 1
    mv -f -- "$BIN/.sing-box.new" "$BIN/sing-box"
}

remember_running() {
    WAS_RUNNING=0
    if systemctl is-active --quiet tri-proxy.service; then WAS_RUNNING=1; fi
}

restart_if_running() {
    if (( WAS_RUNNING == 1 )); then
        systemctl restart tri-proxy.service || return 1
        sleep 2
        systemctl is-active --quiet tri-proxy.service || return 1
    fi
}

manage_update() {
    require_install
    local wanted=${1:-latest} arch asset version digest current
    [[ $wanted == latest || $wanted =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die '請指定正式版本，例如 1.14.3。'
    case $(uname -m) in x86_64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; *) die '不支援的 CPU 架構。' ;; esac
    WORK=$(mktemp -d /tmp/tri-proxy.XXXXXXXX)
    trap cleanup EXIT
    local url=https://api.github.com/repos/SagerNet/sing-box/releases/latest
    [[ $wanted == latest ]] || url="https://api.github.com/repos/SagerNet/sing-box/releases/tags/v$wanted"
    curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
        --connect-timeout 15 --max-time 60 "$url" -o "$WORK/release.json"
    version=$(jq -er 'select(.draft == false and .prerelease == false) | .tag_name' "$WORK/release.json")
    version=${version#v}
    [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die '官方版本格式不符。'
    current=$("$BIN/sing-box" version | awk '/^sing-box version / {print $3}')
    if [[ $version == "$current" ]]; then printf '已是 sing-box %s，沒有更改。\n' "$current"; return; fi
    asset="sing-box-$version-linux-$arch.tar.gz"
    digest=$(jq -er --arg name "$asset" '.assets[] | select(.name == $name) | .digest' "$WORK/release.json")
    [[ $digest =~ ^sha256:[0-9a-fA-F]{64}$ ]] || die '官方資產未提供有效的 SHA-256；中止更新。'
    download "https://github.com/SagerNet/sing-box/releases/download/v$version/$asset" "$WORK/sb.tar.gz" "${digest#sha256:}"
    tar -xzf "$WORK/sb.tar.gz" -C "$WORK" --no-same-owner "sing-box-$version-linux-$arch/sing-box"
    local candidate="$WORK/sing-box-$version-linux-$arch/sing-box"
    "$candidate" check -c "$BASE/config.json" || die '新版核心與伺服器配置不相容。'
    "$candidate" check -c "$BASE/client.json" || die '新版核心與客戶端配置不相容。'
    ROLLBACK_DIR="$BACKUPS/$(date -u +%Y%m%dT%H%M%SZ)-$(openssl rand -hex 4)"
    install -d -m 700 "$BACKUPS" "$ROLLBACK_DIR"
    install -m 700 "$BIN/sing-box" "$ROLLBACK_DIR/sing-box"
    cp -a -- "$BASE" "$ROLLBACK_DIR/config"
    remember_running
    UPDATING=1
    replace_core "$candidate"
    restart_if_running || die '新版核心未能正常啟動。'
    "$BIN/sing-box" check -c "$BASE/config.json"
    printf '%s\n' "$ROLLBACK_DIR" > "$WORK/last-update"
    install -m 600 "$WORK/last-update" "$BACKUPS/.last-update.new"
    mv -f -- "$BACKUPS/.last-update.new" "$BACKUPS/last-update"
    UPDATING=0
    printf 'sing-box %s → %s；備份：%s\n' "$current" "$version" "$ROLLBACK_DIR"
    printf '節點身份、端口及設定保留；cloudflared 不在本次核心更新範圍。\n'
}

manage_rollback() {
    require_install
    [[ -f $BACKUPS/last-update ]] || die '尚未有成功更新的備份。'
    local backup
    backup=$(cat "$BACKUPS/last-update")
    [[ $backup == "$BACKUPS/"* && ${backup#"$BACKUPS/"} =~ ^[A-Za-z0-9-]+$ \
       && -f $backup/sing-box && $(realpath -e "$backup") == "$backup" ]] || die '備份路徑無效。'
    "$backup/sing-box" check -c "$BASE/config.json" || die '備份核心與當前配置不相容。'
    remember_running
    WORK=$(mktemp -d /tmp/tri-proxy.XXXXXXXX)
    trap cleanup EXIT
    ROLLBACK_DIR="$BACKUPS/restore-$(date -u +%Y%m%dT%H%M%SZ)-$(openssl rand -hex 4)"
    install -d -m 700 "$ROLLBACK_DIR"
    install -m 700 "$BIN/sing-box" "$ROLLBACK_DIR/sing-box"
    UPDATING=1
    replace_core "$backup/sing-box"
    restart_if_running || die '備份核心未能正常啟動。'
    UPDATING=0
    printf '已回復 sing-box 核心；現有節點設定保留。\n'
    "$BIN/sing-box" version | head -n1
}

manage() {
    require_install
    case $1 in
        --status)
            "$BIN/sing-box" version | head -n1
            systemctl show tri-proxy.service -p ActiveState -p SubState -p UnitFileState
            if [[ -x $BIN/cloudflared ]]; then
                "$BIN/cloudflared" --version
                systemctl show tri-proxy-argo.service -p ActiveState -p SubState -p UnitFileState
            fi
            printf '\n命令：agsbx list（節點）／res（重啟）／ups（更新）／del（備份解除安裝）。\n'
            printf '參數重建：sudo env vlpt= hypt= vmpt= agsbx rep；選單：sudo tri-proxy。\n' ;;
        --logs) journalctl -u tri-proxy.service -u tri-proxy-argo.service -n 60 --no-pager ;;
        --check)
            "$BIN/sing-box" check -c "$BASE/config.json"
            load_metadata
            openssl x509 -in "$BASE/tls.crt" -noout -enddate -checkend 0
            for protocol in "tcp:$REALITY_PORT" "udp:$HY_PORT" "tcp:$WS_PORT"; do
                if is_port_free "${protocol%%:*}" "${protocol#*:}"; then
                    printf '%s 沒有監聽，請查看服務狀態。\n' "$protocol"
                else printf '%s 已有本機監聽。\n' "$protocol"; fi
            done
            printf '以上為本機檢查；不代表公網或 Cloudflare Tunnel 已可達。\n' ;;
        --stop)
            if [[ -x $BIN/cloudflared ]]; then systemctl stop tri-proxy-argo.service; fi
            systemctl stop tri-proxy.service
            printf '服務已停止；開機啟動設定保留。\n' ;;
        --start|--restart)
            "$BIN/sing-box" check -c "$BASE/config.json"
            systemctl "${1#--}" tri-proxy.service
            sleep 2
            systemctl is-active --quiet tri-proxy.service || die '服務重啟失敗。'
            if [[ -x $BIN/cloudflared ]]; then
                systemctl "${1#--}" tri-proxy-argo.service
                sleep 2
                systemctl is-active --quiet tri-proxy-argo.service || die 'Argo 服務重啟失敗。'
            fi
            show_config ;;
    esac
}

main() (
    set -Eeuo pipefail
    umask 077
    local option=${1:-menu} arch sb_hash cf_hash detected pair ws_requested
    COMMITTED=0
    UPDATING=0
    REPLACING=0
    WORK=
    if [[ $# == 0 && ${0##*/} == agsbx && -f $BASE/metadata.json ]]; then option=--status; fi
    case $option in
        install) option=--defaults ;; uninstall|del) option=--uninstall ;;
        restart|res) option=--restart ;; status) option=--status ;;
        update|ups) option=--update ;; config|list) option=--show ;;
        start) option=--start ;; stop) option=--stop ;;
        rep) option=--replace ;;
    esac
    [[ $# -le 1 || ( $option == --update && $# == 2 ) ]] || die '參數過多；請用 --help。'
    case $option in
        --help|-h)
            printf '用法：bash %s [--defaults|--custom|--replace|--show|--status|--logs|--check|--start|--stop|--restart|--update [版本]|--rollback|--uninstall|--install-command]\n' "$0"
            printf '不帶選項：選單，按 Enter 使用預設。--defaults：非互動；可用 SERVER_ADDR 指定入口 IP。\n'
            printf '亦接受：install、rep、uninstall/del、restart/res、status、update/ups、config/list、start、stop。\n'
            printf 'rep 至少設定一項端口變數（空值沿用）；argo=vmpt 啟用 VMess Tunnel，搭配 agn/agk 使用固定網域。\n'
            return ;;
        menu|--defaults|--custom|--replace|--show|--status|--logs|--check|--start|--stop|--restart|--update|--rollback|--uninstall|--install-command) ;;
        *) die '未知選項；請用 --help。' ;;
    esac
    [[ $EUID == 0 ]] || die '請用 sudo bash 執行。'
    if [[ $option == menu ]]; then menu; return; fi
    exec 9>/run/tri-proxy.lock
    flock -n 9 || die '另一個三合一管理操作正在執行。'
    trap 'exit 130' INT
    trap 'exit 143' TERM
    case $option in
        --show) require_install; show_config; return ;;
        --update) manage_update "${2:-latest}"; return ;;
        --rollback) manage_rollback; return ;;
        --uninstall) manage_uninstall; return ;;
        --install-command) setup_manager; return ;;
        --status|--logs|--check|--start|--stop|--restart) manage "$option"; return ;;
    esac
    [[ -r /etc/os-release ]] || die '無法識別作業系統。'
    # shellcheck disable=SC1091
    . /etc/os-release
    [[ $ID == debian && ${VERSION_ID%%.*} -ge 11 ]] || die '僅支援 Debian 11 或更新版本。'
    [[ -d /run/systemd/system ]] || die '需要正常運行 systemd 的 Debian VPS。'
    check_shortcuts
    if [[ $option == --replace ]]; then
        require_install
        account_owned || die '無法確認本腳本的專用帳戶，拒絕重建。'
        [[ -n ${vlpt+x}${hypt+x}${vmpt+x}${REALITY_PORT+x}${HY_PORT+x}${WS_PORT+x} ]] \
            || die 'rep 至少要設定 vlpt、hypt 或 vmpt（亦接受描述式端口變數）；空值沿用原端口。'
    else
        for pair in "$BASE" "$BIN" /etc/systemd/system/tri-proxy.service /etc/systemd/system/tri-proxy-argo.service; do
            [[ ! -e $pair && ! -L $pair ]] || die "$pair 已存在；本腳本不覆寫。"
        done
        for pair in tri-proxy.service tri-proxy-argo.service; do
            if systemctl cat "$pair" >/dev/null 2>&1; then die "$pair 已存在；本腳本不覆寫。"; fi
        done
    fi
    if ! account_owned; then
        ! getent passwd tri-proxy >/dev/null || die 'tri-proxy 使用者已存在，請先檢查既有安裝。'
        ! getent group tri-proxy >/dev/null || die 'tri-proxy 群組已存在，請先檢查既有安裝。'
        [[ ! -e $BACKUPS ]] || die '備份目錄已存在，但無法確認專用帳戶。'
    fi
    case $(uname -m) in
        x86_64)
            arch=amd64
            sb_hash=e2bdf179c15a3652955dc44867e33ca0965c9c9b91b34267dcc5a5d639a5feee
            cf_hash=d33ff2d14475178d2012c2c56beba87389ac5ded27649519f198a7d3134a99db ;;
        aarch64|arm64)
            arch=arm64
            sb_hash=29dae24d76bea3bc62d07dd3e60cfc12003de7debbd6b768df9be9c68360174e
            cf_hash=e6422b9d4f72d3194bc5a38676f13667c06666523217b842a877d72a80b5ac08 ;;
        *) die '僅支援 amd64、arm64。' ;;
    esac
    printf '安裝必要套件……\n'
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
        ca-certificates curl jq openssl tar iproute2
    detected=$(curl --noproxy '*' -4fsS --max-time 8 https://api.ipify.org \
        || curl --noproxy '*' -6fsS --max-time 8 https://api64.ipify.org || true)
    if [[ $option == --replace ]]; then
        SERVER_ADDR=${SERVER_ADDR:-$(jq -er .SERVER_ADDR "$BASE/metadata.json")}
        REALITY_PORT=${REALITY_PORT:-${vlpt:-$(jq -er .REALITY_PORT "$BASE/metadata.json")}}
        HY_PORT=${HY_PORT:-${hypt:-$(jq -er .HY_PORT "$BASE/metadata.json")}}
        WS_PORT=${WS_PORT:-${vmpt:-$(jq -er .WS_PORT "$BASE/metadata.json")}}
    fi
    SERVER_ADDR=${SERVER_ADDR:-$detected}
    ws_requested=${WS_PORT:-${vmpt:-}}
    REALITY_PORT=${REALITY_PORT:-${vlpt:-}}
    HY_PORT=${HY_PORT:-${hypt:-}}
    WS_PORT=${WS_PORT:-${vmpt:-}}
    REALITY_SNI=${REALITY_SNI:-${reym:-www.microsoft.com}}
    TLS_SNI=${TLS_SNI:-proxy.invalid}
    TLS_CERT=${TLS_CERT:-}
    TLS_KEY=${TLS_KEY:-}
    ARGO_HOST=${ARGO_HOST:-${agn:-}}
    CF_TUNNEL_TOKEN=${CF_TUNNEL_TOKEN:-${agk:-}}
    if [[ -z ${ARGO_MODE:-} && -n ${argo:-} ]]; then
        [[ $argo == vmpt || $argo == yes ]] || die '本版 Argo 僅接受 argo=vmpt；舊別名 argo=yes 亦可。'
        if [[ -n $ARGO_HOST && -n $CF_TUNNEL_TOKEN ]]; then ARGO_MODE=2; else ARGO_MODE=1; fi
    fi
    ARGO_MODE=${ARGO_MODE:-0}
    for pair in "$REALITY_PORT" "$HY_PORT" "$WS_PORT"; do
        [[ -z $pair ]] || valid_port "$pair" || die '指定端口須為 1–65535，不能帶前置 0。'
    done
    REALITY_PORT=${REALITY_PORT:-$(choose_port tcp 24443)}
    HY_PORT=${HY_PORT:-$(choose_port udp 24443)}
    if [[ $ARGO_MODE == 0 ]]; then WS_PORT=${WS_PORT:-$(choose_port tcp 24444 "$REALITY_PORT")};
    else WS_PORT=${WS_PORT:-$(choose_port tcp 2080 "$REALITY_PORT")}; fi
    if [[ $option == --custom ]]; then
        ask SERVER_ADDR 'VPS 公網 IP 或直連網域（不可填橙雲網域）' "$SERVER_ADDR"
        ask REALITY_PORT 'REALITY TCP 端口' "$REALITY_PORT"
        ask HY_PORT 'Hysteria2 UDP 端口' "$HY_PORT"
        ask REALITY_SNI 'REALITY TLS 1.3 握手網域' "$REALITY_SNI"
        printf 'Argo：0=關閉；1=臨時網域，重啟會變；2=固定網域，需要 Tunnel Token。\n'
        ask ARGO_MODE 'Argo 模式' "$ARGO_MODE"
        [[ $ARGO_MODE == 0 || -n $ws_requested ]] || WS_PORT=$(choose_port tcp 2080 "$REALITY_PORT")
        ask WS_PORT 'VMess TCP 端口（Argo 模式只綁定 127.0.0.1）' "$WS_PORT"
        ask TLS_SNI '憑證網域（自簽憑證可保留預設）' "$TLS_SNI"
        ask TLS_CERT '已有 PEM 憑證完整路徑（留空自簽）' ''
        if [[ -n $TLS_CERT ]]; then ask TLS_KEY 'PEM 私鑰完整路徑' ''; fi
        if [[ $ARGO_MODE == 2 ]]; then
            ask ARGO_HOST 'Cloudflare Tunnel 固定公開網域' "$ARGO_HOST"
            read -r -s -p 'Tunnel Token（輸入隱藏；留空保留已指定 Token）：' pair || die '未能讀取 Token。'
            CF_TUNNEL_TOKEN=${pair:-$CF_TUNNEL_TOKEN}
            printf '\n'
        fi
    fi
    valid_host "$SERVER_ADDR" || die '入口地址無效；可使用 SERVER_ADDR=你的公網IP bash 腳本 --defaults。'
    valid_host "$REALITY_SNI" && [[ $REALITY_SNI != *:* ]] || die 'REALITY 握手網域無效。'
    valid_host "$TLS_SNI" && [[ $TLS_SNI != *:* ]] || die 'TLS 憑證網域無效。'
    [[ $ARGO_MODE =~ ^[012]$ ]] || die 'Argo 模式須為 0、1 或 2。'
    for pair in "$REALITY_PORT" "$HY_PORT" "$WS_PORT"; do valid_port "$pair" || die '端口須為 1–65535，不能帶前置 0。'; done
    [[ $REALITY_PORT != "$WS_PORT" ]] || die 'REALITY 與 VMess 不能使用相同 TCP 端口。'
    if [[ $ARGO_MODE != 0 && ( -n $ARGO_HOST || -n $CF_TUNNEL_TOKEN ) ]]; then
        [[ -n $ARGO_HOST && -n $CF_TUNNEL_TOKEN ]] || die '固定 Tunnel 必須同時提供 agn/ARGO_HOST 及 agk/CF_TUNNEL_TOKEN。'
    fi
    if [[ $ARGO_MODE == 2 ]]; then
        valid_host "$ARGO_HOST" && [[ $ARGO_HOST == *.* && $ARGO_HOST != *:* ]] || die 'Argo 固定網域無效。'
        [[ $CF_TUNNEL_TOKEN =~ ^[A-Za-z0-9._+/=-]+$ ]] || die 'Tunnel Token 格式無效；請只貼 Token。'
        printf 'Cloudflare Tunnel 的公開主機名稱：%s → HTTP → 127.0.0.1:%s\n' "$ARGO_HOST" "$WS_PORT"
    fi
    if [[ $option != --replace ]]; then
        port_free tcp "$REALITY_PORT"
        port_free udp "$HY_PORT"
        port_free tcp "$WS_PORT"
    fi
    printf '檢查 REALITY 握手目標……\n'
    timeout 15 openssl s_client -connect "$REALITY_SNI:443" -servername "$REALITY_SNI" \
        -tls1_3 -verify_return_error -verify_hostname "$REALITY_SNI" </dev/null >/dev/null 2>&1 \
        || die 'REALITY 握手目標無法完成 TLS 1.3 連線，請更換網域或檢查網絡。'
    COMMITTED=0
    WORK=$(mktemp -d /tmp/tri-proxy.XXXXXXXX)
    trap cleanup EXIT
    download "https://github.com/SagerNet/sing-box/releases/download/v$SB_VERSION/sing-box-$SB_VERSION-linux-$arch.tar.gz" "$WORK/sb.tar.gz" "$sb_hash"
    tar -xzf "$WORK/sb.tar.gz" -C "$WORK" --no-same-owner "sing-box-$SB_VERSION-linux-$arch/sing-box"
    local sb="$WORK/sing-box-$SB_VERSION-linux-$arch/sing-box"
    if [[ $ARGO_MODE != 0 ]]; then
        download "https://github.com/cloudflare/cloudflared/releases/download/$CF_VERSION/cloudflared-linux-$arch" "$WORK/cloudflared" "$cf_hash"
    fi
    UUID=${UUID:-${uuid:-$(cat /proc/sys/kernel/random/uuid)}}
    VMESS_UUID=${VMESS_UUID:-${uuid:-$(cat /proc/sys/kernel/random/uuid)}}
    HY_PASSWORD=${HY_PASSWORD:-${uuid:-$(openssl rand -hex 24)}}
    valid_uuid "$UUID" && valid_uuid "$VMESS_UUID" || die '指定 UUID 格式無效。'
    [[ ${#HY_PASSWORD} -ge 16 && ${#HY_PASSWORD} -le 128 ]] || die 'Hysteria2 密碼須為 16–128 個字元。'
    WS_PATH=/$(openssl rand -hex 16)
    REALITY_SID=$(openssl rand -hex 4)
    pair=$("$sb" generate reality-keypair)
    REALITY_PRIVATE=$(sed -n 's/^PrivateKey: //p' <<< "$pair")
    REALITY_PUBLIC=$(sed -n 's/^PublicKey: //p' <<< "$pair")
    [[ -n $REALITY_PRIVATE && -n $REALITY_PUBLIC ]] || die 'REALITY 金鑰產生失敗。'
    if [[ -z $TLS_CERT ]]; then
        openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 \
            -subj "/CN=$TLS_SNI" -addext "subjectAltName=DNS:$TLS_SNI" \
            -keyout "$WORK/tls.key" -out "$WORK/tls.crt" >/dev/null 2>&1
    else
        [[ -f $TLS_CERT && -f $TLS_KEY ]] || die '憑證或私鑰檔案不存在。'
        cp -- "$TLS_CERT" "$WORK/tls.crt"
        cp -- "$TLS_KEY" "$WORK/tls.key"
        openssl x509 -in "$WORK/tls.crt" -noout -checkhost "$TLS_SNI" | grep -q 'does match certificate' \
            || die '憑證與 TLS 網域不符。'
    fi
    openssl x509 -in "$WORK/tls.crt" -checkend 86400 -noout >/dev/null || die '憑證已過期或即將過期。'
    [[ $(openssl x509 -in "$WORK/tls.crt" -pubkey -noout | openssl pkey -pubin -outform DER | sha256sum) \
       == "$(openssl pkey -in "$WORK/tls.key" -passin pass: -pubout -outform DER | sha256sum)" ]] \
        || die '憑證與私鑰不匹配，或私鑰需要密碼。'
    local final_base=$BASE
    BASE=$WORK
    make_server_config "$WORK"
    "$sb" check -c "$WORK/config.json"
    BASE=$final_base
    make_server_config "$WORK"
    make_exports "$WORK" "${ARGO_HOST:-$SERVER_ADDR}" "$WORK/tls.crt"
    "$sb" check -c "$WORK/client.json"
    jq -n --arg SERVER_ADDR "$SERVER_ADDR" --arg REALITY_PORT "$REALITY_PORT" \
        --arg HY_PORT "$HY_PORT" --arg WS_PORT "$WS_PORT" --arg UUID "$UUID" \
        --arg VMESS_UUID "$VMESS_UUID" --arg HY_PASSWORD "$HY_PASSWORD" \
        --arg REALITY_SNI "$REALITY_SNI" --arg REALITY_PUBLIC "$REALITY_PUBLIC" \
        --arg REALITY_SID "$REALITY_SID" --arg WS_PATH "$WS_PATH" \
        --arg TLS_SNI "$TLS_SNI" --arg ARGO_MODE "$ARGO_MODE" --arg ARGO_HOST "$ARGO_HOST" \
        '$ARGS.named' > "$WORK/metadata.json"
    if [[ $option == --replace ]]; then begin_replacement; fi
    port_free tcp "$REALITY_PORT"
    port_free udp "$HY_PORT"
    port_free tcp "$WS_PORT"
    if ! account_owned; then
        useradd --system --user-group --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin tri-proxy
    fi
    COMMITTED=1
    install -d -m 755 "$BIN"
    install -d -m 750 -o root -g tri-proxy "$BASE"
    install -m 755 "$sb" "$BIN/sing-box"
    for pair in config.json tls.crt tls.key; do install -m 640 -o root -g tri-proxy "$WORK/$pair" "$BASE/$pair"; done
    for pair in client.json clash.yaml links.txt metadata.json; do install -m 600 "$WORK/$pair" "$BASE/$pair"; done
    cat > /etc/systemd/system/tri-proxy.service <<UNIT
[Unit]
Description=REALITY Hysteria2 VMess WS
After=network-online.target
Wants=network-online.target

[Service]
User=tri-proxy
Group=tri-proxy
ExecStart=$BIN/sing-box run -c $BASE/config.json
Restart=on-failure
RestartSec=3
UMask=0077
LimitNOFILE=65536
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK

[Install]
WantedBy=multi-user.target
UNIT
    chmod 644 /etc/systemd/system/tri-proxy.service
    if [[ $ARGO_MODE != 0 ]]; then
        install -m 755 "$WORK/cloudflared" "$BIN/cloudflared"
        local cf_command="$BIN/cloudflared tunnel --no-autoupdate --url http://127.0.0.1:$WS_PORT"
        if [[ $ARGO_MODE == 2 ]]; then
            printf '%s' "$CF_TUNNEL_TOKEN" > "$BASE/tunnel.token"
            chown root:tri-proxy "$BASE/tunnel.token"
            chmod 640 "$BASE/tunnel.token"
            cf_command="$BIN/cloudflared tunnel --no-autoupdate run --token-file $BASE/tunnel.token"
        fi
        cat > /etc/systemd/system/tri-proxy-argo.service <<UNIT
[Unit]
Description=Cloudflare Tunnel for VMess WS
After=network-online.target tri-proxy.service
Wants=network-online.target tri-proxy.service

[Service]
User=tri-proxy
Group=tri-proxy
ExecStart=$cf_command
Restart=on-failure
RestartSec=5
UMask=0077
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK

[Install]
WantedBy=multi-user.target
UNIT
        chmod 644 /etc/systemd/system/tri-proxy-argo.service
    fi
    systemctl daemon-reload
    systemctl start tri-proxy.service
    sleep 2
    systemctl is-active --quiet tri-proxy.service || die 'sing-box 啟動失敗；查看 journalctl -u tri-proxy。'
    "$BIN/sing-box" check -c "$BASE/config.json"
    systemctl enable tri-proxy.service
    if [[ $ARGO_MODE != 0 ]]; then
        systemctl start tri-proxy-argo.service
        sleep 2
        systemctl is-active --quiet tri-proxy-argo.service || die 'Argo 啟動失敗；查看 journalctl -u tri-proxy-argo。'
        systemctl enable tri-proxy-argo.service
    fi
    record_account
    setup_manager
    COMMITTED=0
    printf '\n本機服務已啟動；公網可達性仍需從另一部電腦驗證。\n'
    printf '1Panel／供應商防火牆：允許 %s/TCP（REALITY）、%s/UDP（Hysteria2）。\n' "$REALITY_PORT" "$HY_PORT"
    if [[ $ARGO_MODE == 0 ]]; then
        printf '另允許 %s/TCP（VMess WS TLS）。\n' "$WS_PORT"
    else
        printf 'VMess 只綁定 127.0.0.1:%s；不需開放該入口端口。Argo 需出站 7844/TCP 或 UDP。\n' "$WS_PORT"
    fi
    show_config
    if [[ $option == --replace ]]; then
        REPLACING=0
        printf '參數重建完成；請重新匯入客戶端配置。舊安裝備份：%s/install.tar.gz\n' "$INSTALL_SNAPSHOT"
    fi
)

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
