#!/usr/bin/env bash
# 在一次性 Debian 容器內執行；不掛載主機的 /etc、/opt，也不公開端口。
set -Eeuo pipefail
[[ -f /.dockerenv && -r /src/outputs/tri-proxy-debian.sh ]] || { printf '只可在指定的一次性 Docker 容器內執行。\n' >&2; exit 1; }
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
    ca-certificates curl jq openssl tar iproute2 shellcheck systemd passwd >/dev/null
shellcheck --severity=warning /src/outputs/tri-proxy-debian.sh
bash -n /src/outputs/tri-proxy-debian.sh
source /src/outputs/tri-proxy-debian.sh
SB=/opt/tri-proxy/sing-box

for port in 1 443 24443 65535; do valid_port "$port"; done
for port in 0 65536 01 -1 '443;id'; do ! valid_port "$port"; done
valid_uuid 11111111-2222-4333-8444-555555555555
! valid_uuid invalid
for host in 127.0.0.1 example.com proxy.invalid; do valid_host "$host"; done
for host in 999.1.1.1 '-bad.example' 'bad..example' 'a/b' 'a"b'; do ! valid_host "$host"; done

# 用實際非 root 行程代替 systemd 啟動；保留安裝流程的其他步驟。
mkdir -p /run/systemd/system
SERVER_PID=
CLIENT_PID=
HTTP_PID=
GATEWAY_PID=
BUSY_PID=
EGRESS_HTTP_PID=
systemctl() {
    printf '%s\n' "$*" >>/tmp/tri-systemctl.log
    case $1 in
        start)
            if [[ ${2:-} == tri-proxy-argo.service ]]; then
                if ! systemctl is-active --quiet tri-proxy.service; then systemctl start tri-proxy.service || return 1; fi
                touch /tmp/tri-argo.active
                return 0
            fi
            if [[ -f /tmp/tri-fail-next-start ]]; then rm /tmp/tri-fail-next-start; return 42; fi
            runuser -u tri-proxy -- /opt/tri-proxy/sing-box run -c /etc/tri-proxy/config.json \
                >/tmp/tri-server.log 2>&1 9>&- &
            SERVER_PID=$!
            printf '%s\n' "$SERVER_PID" >/tmp/tri-service.pid ;;
        stop)
            if [[ ${2:-} == tri-proxy-argo.service ]]; then rm -f /tmp/tri-argo.active; return 0; fi
            if [[ -f /tmp/tri-service.pid ]]; then
                local pid
                pid=$(cat /tmp/tri-service.pid)
                kill "$pid" 2>/dev/null || true
                wait "$pid" 2>/dev/null || true
                rm /tmp/tri-service.pid
                sleep 0.5
            fi ;;
        restart) systemctl stop "$2"; systemctl start "$2" ;;
        is-active)
            if [[ ${*: -1} == tri-proxy-argo.service ]]; then [[ -f /tmp/tri-argo.active ]]; return $?; fi
            [[ -f /tmp/tri-service.pid ]] && kill -0 "$(cat /tmp/tri-service.pid)" 2>/dev/null ;;
        is-enabled) [[ -f /tmp/tri-enabled-${*: -1} ]] ;;
        show)
            if [[ $* == *ActiveEnterTimestamp* ]]; then printf 'current-boot\n';
            else printf 'ActiveState=active\nSubState=running\nUnitFileState=enabled\n'; fi ;;
        disable)
            for unit in "${@:2}"; do
                [[ $unit != --now ]] || continue
                rm -f "/tmp/tri-enabled-$unit"
                if [[ $* == *--now* ]]; then systemctl stop "$unit"; fi
            done ;;
        enable) for unit in "${@:2}"; do touch "/tmp/tri-enabled-$unit"; done ;;
        daemon-reload) : ;;
        *) return 1 ;;
    esac
}
journalctl() {
    if [[ $* == *--since* ]]; then
        [[ $* == *'--since current-boot'* ]] || return 1
        printf 'Tunnel ready at https://current.trycloudflare.com\n'
    else printf 'test-service-log\n'; fi
}
node -e 'const net=require("net"),udp=require("dgram");
net.createServer().listen(24443,"127.0.0.1");net.createServer().listen(24444,"127.0.0.1");
udp.createSocket("udp4").bind(24443,"127.0.0.1")' >/tmp/tri-busy.log 2>&1 &
BUSY_PID=$!
for attempt in {1..30}; do
    if ! is_port_free tcp 24443 && ! is_port_free tcp 24444 && ! is_port_free udp 24443; then break; fi
    sleep 0.1
done
! is_port_free tcp 24443
! is_port_free udp 24443
! (port_free tcp 24443 >/dev/null 2>&1)
ln -s /usr/bin/true /usr/local/bin/agsbx
if (SERVER_ADDR=127.0.0.1 main install) >/tmp/tri-command-conflict.log 2>&1; then exit 1; fi
grep -q 'agsbx 已被其他程式使用' /tmp/tri-command-conflict.log
[[ ! -e /etc/tri-proxy && $(readlink /usr/local/bin/agsbx) == /usr/bin/true ]]
rm /usr/local/bin/agsbx
SERVER_ADDR=127.0.0.1 main <<< '' >/tmp/tri-install.log 2>&1
trap - EXIT
test_cleanup() {
    local result=$?
    trap - EXIT
    [[ ! -f /tmp/tri-egress-resolv.conf ]] || cp /tmp/tri-egress-resolv.conf /etc/resolv.conf
    [[ ! -f /tmp/tri-service.pid ]] || SERVER_PID=$(cat /tmp/tri-service.pid)
    for pid in "$CLIENT_PID" "$SERVER_PID" "$HTTP_PID" "$GATEWAY_PID" "$BUSY_PID" "$EGRESS_HTTP_PID"; do
        [[ -z $pid ]] || kill "$pid" 2>/dev/null || true
    done
    if (( result != 0 )); then
        sed -n '/^錯誤：/p' /tmp/tri-install.log 2>/dev/null || true
        grep -E '錯誤|重建失敗|回復未成功|已回復' /tmp/tri-rep-*.log 2>/dev/null || true
        if [[ -f /tmp/tri-rep-argo-failure.log ]]; then
            grep -E '原服務|^rm:|^tar:|^jq:|已通過|備份|回復|錯誤' /tmp/tri-rep-argo-failure.log >&2 || true
            tail -n 30 /tmp/tri-systemctl.log >&2
        fi
        tail -n 30 /tmp/tri-server.log /tmp/tri-client.log 2>/dev/null || true
        tail -n 30 /tmp/tri-mihomo.log /tmp/tri-update-failure.log 2>/dev/null || true
        tail -n 30 /tmp/tri-egress-*.log 2>/dev/null || true
    fi
    exit "$result"
}
trap test_cleanup EXIT
trap 'printf "測試失敗：行 %s\n" "$LINENO" >&2; tail -n 25 /tmp/tri-mihomo.log /tmp/tri-update.log /tmp/tri-update-failure.log 2>/dev/null || true' ERR

[[ $(stat -c %a /etc/tri-proxy/client.json) == 600 ]]
[[ $(stat -c %a /etc/tri-proxy/clash.yaml) == 600 ]]
[[ $(stat -c %a /etc/tri-proxy/tls.key) == 640 ]]
[[ $(stat -c %a /var/lib/tri-proxy/account.id) == 600 ]]
[[ -L /usr/local/bin/tri-proxy && $(readlink /usr/local/bin/tri-proxy) == /var/lib/tri-proxy/manage.sh ]]
[[ -L /usr/local/bin/agsbx && $(readlink /usr/local/bin/agsbx) == /var/lib/tri-proxy/manage.sh ]]
/usr/local/bin/tri-proxy --help | grep -q 'uninstall/del'
! runuser -u tri-proxy -- test -r /etc/tri-proxy/client.json
systemd-analyze verify /etc/systemd/system/tri-proxy.service
if (SERVER_ADDR=127.0.0.1 main --defaults >/tmp/tri-repeat.log 2>&1); then
    printf '錯誤：重複安裝未被阻擋。\n' >&2
    exit 1
fi
load_metadata
[[ $EGRESS_MODE == auto ]]
[[ $ARGO_MODE == 0 && $REALITY_PORT != 24443 && $HY_PORT != 24443 && $WS_PORT != 24444 && $REALITY_PORT != "$WS_PORT" ]]
kill "$BUSY_PID"
wait "$BUSY_PID" || true
BUSY_PID=
printf 'PASS：Bash、ShellCheck、輸入驗證、Enter 預設安裝、TCP／UDP 端口避讓、權限、systemd 單元及拒絕覆寫。\n'

compat_rep() (
    export -f systemctl journalctl
    env SERVER_ADDR=127.0.0.1 "$@" /usr/local/bin/agsbx rep
)
(
    export -f systemctl journalctl
    /usr/local/bin/agsbx
) >/tmp/tri-compat-status.log
grep -q '參數重建' /tmp/tri-compat-status.log
! grep -q '========== 三合一代理管理' /tmp/tri-compat-status.log
before=$(sha256sum /etc/tri-proxy/{config.json,metadata.json,tls.crt,tls.key,clash.yaml})
if compat_rep >/tmp/tri-rep-no-vars.log 2>&1; then exit 1; fi
grep -q 'rep 至少要設定' /tmp/tri-rep-no-vars.log
if compat_rep vlpt= uuid=broken >/tmp/tri-rep-invalid.log 2>&1; then exit 1; fi
grep -q 'UUID 格式無效' /tmp/tri-rep-invalid.log
if compat_rep vlpt= argo=vmpt agn=edge.example.com >/tmp/tri-rep-partial-argo.log 2>&1; then exit 1; fi
grep -q '必須同時提供' /tmp/tri-rep-partial-argo.log
if compat_rep vlpt= argo=vwpt >/tmp/tri-rep-unsupported.log 2>&1; then exit 1; fi
grep -q '僅接受 argo=vmpt' /tmp/tri-rep-unsupported.log
if (
    unset REALITY_PORT HY_PORT WS_PORT
    download() { return 42; }
    SERVER_ADDR=127.0.0.1 vlpt= main rep
) >/tmp/tri-rep-download.log 2>&1; then exit 1; fi
[[ ! -e /var/lib/tri-proxy/replaced ]]
[[ $before == "$(sha256sum /etc/tri-proxy/{config.json,metadata.json,tls.crt,tls.key,clash.yaml})" ]]
systemctl is-active --quiet tri-proxy.service

touch /tmp/tri-fail-next-start
if compat_rep vlpt= >/tmp/tri-rep-failure.log 2>&1; then exit 1; fi
grep -q '已回復原配置' /tmp/tri-rep-failure.log
[[ $before == "$(sha256sum /etc/tri-proxy/{config.json,metadata.json,tls.crt,tls.key,clash.yaml})" ]]
systemctl is-active --quiet tri-proxy.service
systemctl is-enabled --quiet tri-proxy.service
[[ -L /usr/local/bin/agsbx && -L /usr/local/bin/tri-proxy ]]
systemctl disable tri-proxy.service
systemctl stop tri-proxy.service
touch /tmp/tri-fail-next-start
if compat_rep vlpt= >/tmp/tri-rep-stopped.log 2>&1; then exit 1; fi
[[ $before == "$(sha256sum /etc/tri-proxy/{config.json,metadata.json,tls.crt,tls.key,clash.yaml})" ]]
! systemctl is-active --quiet tri-proxy.service
! systemctl is-enabled --quiet tri-proxy.service
systemctl enable tri-proxy.service
systemctl start tri-proxy.service

node -e 'require("net").createServer().listen(34567,"127.0.0.1")' >/tmp/tri-busy.log 2>&1 &
BUSY_PID=$!
for attempt in {1..30}; do
    if ! is_port_free tcp 34567; then break; fi
    sleep 0.1
done
if compat_rep vlpt=34567 >/tmp/tri-rep-port-conflict.log 2>&1; then exit 1; fi
grep -q '34567/tcp 已被使用' /tmp/tri-rep-port-conflict.log
grep -q '已回復原配置' /tmp/tri-rep-port-conflict.log
[[ $before == "$(sha256sum /etc/tri-proxy/{config.json,metadata.json,tls.crt,tls.key,clash.yaml})" ]]
kill "$BUSY_PID"
wait "$BUSY_PID" || true
BUSY_PID=

old_ports=$(jq -c '[.REALITY_PORT,.HY_PORT,.WS_PORT]' /etc/tri-proxy/metadata.json)
old_uuid=$(jq -r .UUID /etc/tri-proxy/metadata.json)
compat_rep vlpt= hypt= vmpt= >/tmp/tri-rep-success.log 2>&1
[[ $old_ports == "$(jq -c '[.REALITY_PORT,.HY_PORT,.WS_PORT]' /etc/tri-proxy/metadata.json)" ]]
[[ $old_uuid != "$(jq -r .UUID /etc/tri-proxy/metadata.json)" ]]
[[ $before != "$(sha256sum /etc/tri-proxy/{config.json,metadata.json,tls.crt,tls.key,clash.yaml})" ]]
for archive in /var/lib/tri-proxy/replaced/*/install.tar.gz; do
    [[ $(stat -c %a "$archive") == 600 ]]
    tar -tzf "$archive" | grep -F usr/local/bin/agsbx >/dev/null
    (cd "$(dirname "$archive")"; sha256sum --check --status SHA256SUMS)
done
load_metadata
SERVER_PID=$(cat /tmp/tri-service.pid)
printf 'PASS：agsbx 無參數狀態入口、同名衝突拒絕、rep 參數／下載驗證、空端口沿用、完整備份；重建啟動失敗回復配置、快捷及運行／開機狀態。\n'

if [[ ${TRI_TEST_ONLY_REP:-0} != 1 ]]; then
node -e 'require("http").createServer((req,res)=>res.end("proxy-e2e-ok")).listen(25445,"127.0.0.1")' \
    >/tmp/tri-http.log 2>&1 9>&- &
HTTP_PID=$!
SB=/opt/tri-proxy/sing-box
client_start() {
    [[ -z $CLIENT_PID ]] || { kill "$CLIENT_PID"; wait "$CLIENT_PID" || true; }
    CLIENT_PID=
    "$SB" check -c /tmp/tri-client.json
    "$SB" run -c /tmp/tri-client.json >/tmp/tri-client.log 2>&1 9>&- &
    CLIENT_PID=$!
    for attempt in {1..30}; do
        [[ -z $(ss -H -ltn 'sport = :1080') ]] || return 0
        sleep 0.1
    done
    return 1
}
proxy_request() {
    curl --silent --show-error --fail --max-time 8 --noproxy '' \
        --proxy http://127.0.0.1:1080 http://127.0.0.1:25445
}
for protocol in reality hysteria2 vmess; do
    jq --arg protocol "$protocol" '.outbounds[0].default = $protocol' \
        /etc/tri-proxy/client.json >/tmp/tri-client.json
    client_start
    [[ $(proxy_request) == proxy-e2e-ok ]]
    printf 'PASS：%s 實際代理連線。\n' "$protocol"
done
source /src/work/test-egress.sh

jq '.outbounds[0].default = "hysteria2" | .outbounds[2].password = "incorrect"' \
    /etc/tri-proxy/client.json >/tmp/tri-client.json
client_start
! proxy_request >/dev/null 2>&1
jq '.outbounds[0].default = "vmess" | del(.outbounds[3].tls.certificate)' \
    /etc/tri-proxy/client.json >/tmp/tri-client.json
client_start
! proxy_request >/dev/null 2>&1
printf 'PASS：錯誤 Hysteria2 密碼、自簽憑證未受信任均拒絕連線。\n'
kill "$CLIENT_PID"
wait "$CLIENT_PID" || true
CLIENT_PID=

download https://github.com/MetaCubeX/mihomo/releases/download/v1.19.32/mihomo-linux-amd64-v1-v1.19.32.gz \
    /tmp/tri-mihomo.gz 306f81e723e60ce6b828899a6fe83e1d00e9ecefb2dc8d4d849312a5bc00efdc
gzip -dc /tmp/tri-mihomo.gz >/tmp/tri-mihomo
chmod 755 /tmp/tri-mihomo
mkdir /tmp/tri-mihomo-home
mihomo_start() {
    [[ -z $CLIENT_PID ]] || { kill "$CLIENT_PID"; wait "$CLIENT_PID" || true; }
    CLIENT_PID=
    /tmp/tri-mihomo -t -d /tmp/tri-mihomo-home -f /tmp/tri-clash.yaml >/tmp/tri-mihomo.log 2>&1
    /tmp/tri-mihomo -d /tmp/tri-mihomo-home -f /tmp/tri-clash.yaml >>/tmp/tri-mihomo.log 2>&1 9>&- &
    CLIENT_PID=$!
    for attempt in {1..30}; do
        [[ -z $(ss -H -ltn 'sport = :1080') ]] || return 0
        sleep 0.1
    done
    return 1
}
for protocol in REALITY Hysteria2 VMess-WS; do
    sed "s/MATCH,代理/MATCH,$protocol/" /etc/tri-proxy/clash.yaml >/tmp/tri-clash.yaml
    mihomo_start
    [[ $(proxy_request) == proxy-e2e-ok ]]
    printf 'PASS：Mihomo %s 實際代理連線。\n' "$protocol"
done
for protocol in Hysteria2 VMess-WS; do
    sed -E "s/MATCH,代理/MATCH,$protocol/; s/fingerprint: \"[0-9A-F]{64}\"/fingerprint: \"$(printf '%064d' 0)\"/" \
        /etc/tri-proxy/clash.yaml >/tmp/tri-clash.yaml
    mihomo_start
    ! proxy_request >/dev/null 2>&1
done
printf 'PASS：Mihomo Hysteria2／VMess 的錯誤憑證 pin 均拒絕連線。\n'
kill "$CLIENT_PID"
wait "$CLIENT_PID" || true
CLIENT_PID=

main --status >/tmp/tri-status.log
grep -q 'ActiveState=active' /tmp/tri-status.log
main --logs >/tmp/tri-logs.log
grep -q test-service-log /tmp/tri-logs.log
main --check >/tmp/tri-check.log
main <<< '' >/tmp/tri-menu.log
grep -q '4) 查看狀態' /tmp/tri-menu.log
main <<< $'99\n4\n\n8\n1\n\n0' >/tmp/tri-menu-loop.log
[[ $(grep -c '========== 三合一代理管理' /tmp/tri-menu-loop.log) -ge 3 ]]
grep -q '選項無效' /tmp/tri-menu-loop.log
grep -q test-service-log /tmp/tri-menu-loop.log
main list >/tmp/tri-alias-list.log
main res >/tmp/tri-alias-res.log
main stop >/tmp/tri-stop.log
! systemctl is-active --quiet tri-proxy.service
main start >/tmp/tri-start.log
main --restart >/tmp/tri-restart.log
SERVER_PID=$(cat /tmp/tri-service.pid)
before=$(sha256sum /etc/tri-proxy/{config.json,metadata.json,tls.crt,tls.key,clash.yaml})
cp "$SB" /tmp/tri-core-baseline
main --update 1.14.2 >/tmp/tri-update.log
SERVER_PID=$(cat /tmp/tri-service.pid)
[[ $("$SB" version | head -n1) == 'sing-box version 1.14.2' ]]
cp "$SB" /tmp/tri-core-alternate
[[ $before == "$(sha256sum /etc/tri-proxy/{config.json,metadata.json,tls.crt,tls.key,clash.yaml})" ]]
[[ $(stat -c %a /var/lib/tri-proxy/backups) == 700 ]]
main --rollback >/tmp/tri-rollback.log
SERVER_PID=$(cat /tmp/tri-service.pid)
[[ $("$SB" version | head -n1) == "sing-box version $SB_VERSION" ]]
[[ $before == "$(sha256sum /etc/tri-proxy/{config.json,metadata.json,tls.crt,tls.key,clash.yaml})" ]]
printf 'PASS：管理選單、狀態／日誌／檢查／重啟、官方核心更新及回復；身份／端口／憑證不變。\n'

# 用有真實 SHA-256 的故障核心，驗證替換後啟動失敗的交易回復。
mkdir -p /tmp/tri-update-fixture/sing-box-1.99.0-linux-amd64
cat >/tmp/tri-update-fixture/sing-box-1.99.0-linux-amd64/sing-box <<'CORE'
#!/usr/bin/env bash
case $1 in
    version) printf 'sing-box version 1.99.0\n' ;;
    run) exit 42 ;;
    *) exec /tmp/tri-core-baseline "$@" ;;
esac
CORE
chmod 755 /tmp/tri-update-fixture/sing-box-1.99.0-linux-amd64/sing-box
tar -czf /tmp/tri-update-fixture/asset.tar.gz -C /tmp/tri-update-fixture sing-box-1.99.0-linux-amd64
fixture_digest=$(sha256sum /tmp/tri-update-fixture/asset.tar.gz | cut -d' ' -f1)
jq -n --arg digest "sha256:$fixture_digest" '{draft:false,prerelease:false,tag_name:"v1.99.0",
    assets:[{name:"sing-box-1.99.0-linux-amd64.tar.gz",digest:$digest}]}' >/tmp/tri-update-fixture/release.json
fixture_curl() {
    local output= url= argument
    while (( $# > 0 )); do
        argument=$1; shift
        case $argument in -o) output=$1; shift ;; https://*) url=$argument ;; esac
    done
    [[ -n $output && -n $url ]] || return 1
    if [[ $url == https://api.github.com/* ]]; then cp /tmp/tri-update-fixture/release.json "$output";
    else cp /tmp/tri-update-fixture/asset.tar.gz "$output"; fi
}
marker=$(cat /var/lib/tri-proxy/backups/last-update)
if (curl() { fixture_curl "$@"; }; main --update 1.99.0) >/tmp/tri-update-failure.log 2>&1; then
    printf '錯誤：故障更新未失敗。\n' >&2; exit 1
fi
SERVER_PID=$(cat /tmp/tri-service.pid)
systemctl is-active --quiet tri-proxy.service
[[ $("$SB" version | head -n1) == "sing-box version $SB_VERSION" ]]
[[ $marker == "$(cat /var/lib/tri-proxy/backups/last-update)" ]]
[[ $before == "$(sha256sum /etc/tri-proxy/{config.json,metadata.json,tls.crt,tls.key,clash.yaml})" ]]
grep -q '更新失敗，已回復' /tmp/tri-update-failure.log
jq '.assets[0].digest = "sha256:'"$(printf '%064d' 0)"'"' /tmp/tri-update-fixture/release.json >/tmp/tri-update-fixture/bad.json
mv /tmp/tri-update-fixture/bad.json /tmp/tri-update-fixture/release.json
if (curl() { fixture_curl "$@"; }; main --update 1.99.0) >/tmp/tri-update-hash.log 2>&1; then
    printf '錯誤：錯誤雜湊未拒絕。\n' >&2; exit 1
fi
grep -q 'SHA-256 不符' /tmp/tri-update-hash.log
jq --arg digest "sha256:$fixture_digest" '.assets[0].digest = $digest' /tmp/tri-update-fixture/release.json >/tmp/tri-update-fixture/good.json
mv /tmp/tri-update-fixture/good.json /tmp/tri-update-fixture/release.json
cp /etc/tri-proxy/config.json /tmp/tri-original-config.json
jq '.inbounds[0].type = "invalid-protocol"' /etc/tri-proxy/config.json >/tmp/tri-incompatible-config.json
cp /tmp/tri-incompatible-config.json /etc/tri-proxy/config.json
if (curl() { fixture_curl "$@"; }; main --update 1.99.0) >/tmp/tri-update-config.log 2>&1; then
    printf '錯誤：不相容配置未拒絕。\n' >&2; exit 1
fi
cp /tmp/tri-original-config.json /etc/tri-proxy/config.json
grep -q '新版核心與伺服器配置不相容' /tmp/tri-update-config.log
[[ $marker == "$(cat /var/lib/tri-proxy/backups/last-update)" ]]
[[ $("$SB" version | head -n1) == "sing-box version $SB_VERSION" ]]
printf 'PASS：錯誤下載雜湊／不相容配置拒絕；更新啟動失敗會回復核心及原有服務。\n'

systemctl stop tri-proxy.service
SERVER_PID=
mkdir /tmp/tri-update-fixture/sing-box-1.14.2-linux-amd64
cp /tmp/tri-core-alternate /tmp/tri-update-fixture/sing-box-1.14.2-linux-amd64/sing-box
tar -czf /tmp/tri-update-fixture/asset.tar.gz -C /tmp/tri-update-fixture sing-box-1.14.2-linux-amd64
fixture_digest=$(sha256sum /tmp/tri-update-fixture/asset.tar.gz | cut -d' ' -f1)
jq -n --arg digest "sha256:$fixture_digest" '{draft:false,prerelease:false,tag_name:"v1.14.2",
    assets:[{name:"sing-box-1.14.2-linux-amd64.tar.gz",digest:$digest}]}' >/tmp/tri-update-fixture/release.json
(curl() { fixture_curl "$@"; }; main --update 1.14.2) >/tmp/tri-update-stopped.log 2>&1
! systemctl is-active --quiet tri-proxy.service
main --rollback >/tmp/tri-rollback-stopped.log
! systemctl is-active --quiet tri-proxy.service
[[ $("$SB" version | head -n1) == "sing-box version $SB_VERSION" ]]
main --restart >/tmp/tri-restart.log
SERVER_PID=$(cat /tmp/tri-service.pid)
printf 'PASS：已停用的服務在更新／回復後保持停用。\n'

cp /etc/tri-proxy/metadata.json /tmp/tri-original-metadata.json
jq '.ARGO_MODE = "1"' /tmp/tri-original-metadata.json >/etc/tri-proxy/metadata.json
touch /tmp/tri-argo.active
main --show >/tmp/tri-quick-show.log
jq -e '.outbounds[3].server == "current.trycloudflare.com"' /etc/tri-proxy/client.json >/dev/null
grep -q 'current.trycloudflare.com' /etc/tri-proxy/clash.yaml
mv /tmp/tri-original-metadata.json /etc/tri-proxy/metadata.json
rm /tmp/tri-argo.active
main --show >/tmp/tri-show.log
printf 'PASS：Quick Tunnel 只從本次服務啟動的日誌刷新網域及匯出。\n'

load_metadata
REALITY_PRIVATE=$(jq -r '.inbounds[0].tls.reality.private_key' /etc/tri-proxy/config.json)
VMESS_UUID=$(jq -r '.inbounds[2].users[0].uuid' /etc/tri-proxy/config.json)
kill "$SERVER_PID"
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=
mkdir /tmp/tri-export-test
for mode in 1 2; do
    ARGO_MODE=$mode
    make_server_config /tmp/tri-export-test
    make_exports /tmp/tri-export-test edge.example.com /etc/tri-proxy/tls.crt
    "$SB" check -c /tmp/tri-export-test/config.json
    "$SB" check -c /tmp/tri-export-test/client.json
    jq -e '.inbounds[2].listen == "127.0.0.1" and (.inbounds[2] | has("tls") | not)' \
        /tmp/tri-export-test/config.json >/dev/null
    jq -e '.outbounds[3].server == "edge.example.com" and .outbounds[3].server_port == 443
           and (.outbounds[3].tls | has("certificate") | not)' /tmp/tri-export-test/client.json >/dev/null
done
vmess_uri=$(tail -n1 /tmp/tri-export-test/links.txt)
printf '%s' "${vmess_uri#vmess://}" | base64 -d | jq -e '.net == "ws" and .tls == "tls"' >/dev/null
grep -q 'pinSHA256=' /tmp/tri-export-test/links.txt
printf 'PASS：兩種 Argo 配置、loopback 限制及匯入連結。\n'

chown root:tri-proxy /tmp/tri-export-test /tmp/tri-export-test/config.json
chmod 750 /tmp/tri-export-test
chmod 640 /tmp/tri-export-test/config.json
runuser -u tri-proxy -- "$SB" run -c /tmp/tri-export-test/config.json >/tmp/tri-server.log 2>&1 &
SERVER_PID=$!
# 用本機 TLS 前端模擬 Tunnel 的 WSS → HTTP WS 傳輸，不連 Cloudflare。
WS_PORT=$WS_PORT node -e 'const fs=require("fs"),net=require("net"),tls=require("tls");
tls.createServer({cert:fs.readFileSync("/etc/tri-proxy/tls.crt"),key:fs.readFileSync("/etc/tri-proxy/tls.key")},s=>{
const upstream=net.connect(Number(process.env.WS_PORT),"127.0.0.1");s.pipe(upstream).pipe(s);
s.on("error",()=>upstream.destroy());upstream.on("error",()=>s.destroy());
}).listen(25446,"127.0.0.1")' >/tmp/tri-gateway.log 2>&1 &
GATEWAY_PID=$!
jq --rawfile cert /etc/tri-proxy/tls.crt '.outbounds[0].default = "vmess"
    | .outbounds[3].server = "127.0.0.1" | .outbounds[3].server_port = 25446
    | .outbounds[3].tls.server_name = "proxy.invalid" | .outbounds[3].tls.certificate = [$cert]' \
    /tmp/tri-export-test/client.json >/tmp/tri-client.json
client_start
[[ $(proxy_request) == proxy-e2e-ok ]]
printf 'PASS：模擬 WSS 前端轉發至 loopback VMess WS 的實際連線。\n'
download "https://github.com/cloudflare/cloudflared/releases/download/$CF_VERSION/cloudflared-linux-amd64" \
    /tmp/tri-cloudflared d33ff2d14475178d2012c2c56beba87389ac5ded27649519f198a7d3134a99db
chmod 755 /tmp/tri-cloudflared
/tmp/tri-cloudflared --version
/tmp/tri-cloudflared tunnel run --help | grep -- '--token-file' >/dev/null
printf 'PASS：cloudflared 官方檔案 SHA-256 及 Token 檔案參數。\n'

for pid in "$CLIENT_PID" "$SERVER_PID" "$GATEWAY_PID"; do
    [[ -z $pid ]] || { kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; }
done
CLIENT_PID=; SERVER_PID=; GATEWAY_PID=
fi
main uninstall <<< '' >/tmp/tri-uninstall-cancel.log
[[ -x $SB && -f /etc/tri-proxy/config.json ]]
main del <<< UNINSTALL >/tmp/tri-uninstall.log
[[ ! -e /etc/tri-proxy && ! -e /opt/tri-proxy && ! -L /usr/local/bin/tri-proxy && ! -L /usr/local/bin/agsbx ]]
archives=(/var/lib/tri-proxy/removed/*/install.tar.gz)
[[ ${#archives[@]} == 1 && $(stat -c %a "${archives[0]}") == 600 ]]
tar -tzf "${archives[0]}" | grep -F etc/tri-proxy/metadata.json >/dev/null
(cd "$(dirname "${archives[0]}")"; sha256sum --check --status SHA256SUMS)
account_owned

# 在同一容器重裝兩種 Argo；Tunnel 管理用 stub，仍核對實際生成的服務及秘密檔案。
for mode in 1 2; do
    (
        unset REALITY_PORT HY_PORT WS_PORT REALITY_SNI ARGO_MODE ARGO_HOST CF_TUNNEL_TOKEN UUID VMESS_UUID HY_PASSWORD EGRESS_MODE
        export SERVER_ADDR=127.0.0.1 vlpt=34443 hypt=34443 vmpt=34444 reym=www.microsoft.com
        export EGRESS_MODE=prefer_ipv6
        export uuid=11111111-2222-4333-8444-555555555555 argo=vmpt
        if [[ $mode == 2 ]]; then export agn=edge.example.com agk=test-token; fi
        main install
    ) >/tmp/tri-env-install.log 2>&1
    jq -e --arg mode "$mode" '.ARGO_MODE == $mode and .REALITY_PORT == "34443" and .HY_PORT == "34443"
       and .WS_PORT == "34444" and .UUID == "11111111-2222-4333-8444-555555555555"
       and .VMESS_UUID == .UUID and .EGRESS_MODE == "prefer_ipv6"' /etc/tri-proxy/metadata.json >/dev/null
    jq -e '.inbounds[2].listen == "127.0.0.1" and (.inbounds[2] | has("tls") | not)' /etc/tri-proxy/config.json >/dev/null
    systemd-analyze verify /etc/systemd/system/tri-proxy.service /etc/systemd/system/tri-proxy-argo.service
    if [[ $mode == 1 ]]; then
        before=$(sha256sum /etc/tri-proxy/{config.json,metadata.json,tls.crt,tls.key,clash.yaml})
        touch /tmp/tri-fail-next-start
        if compat_rep vlpt= argo=vmpt >/tmp/tri-rep-argo-failure.log 2>&1; then exit 1; fi
        grep -q '已回復原配置' /tmp/tri-rep-argo-failure.log
        if [[ $before != "$(sha256sum /etc/tri-proxy/{config.json,metadata.json,tls.crt,tls.key,clash.yaml})" ]]; then
            printf 'Argo 回復雜湊不一致；原檔：\n%s\n目前：\n' "$before" >&2
            sha256sum /etc/tri-proxy/{config.json,metadata.json,tls.crt,tls.key,clash.yaml} >&2
            exit 1
        fi
        systemctl is-active --quiet tri-proxy-argo.service
        systemctl is-enabled --quiet tri-proxy-argo.service
        systemctl stop tri-proxy.service
        touch /tmp/tri-fail-next-start
        if compat_rep vlpt= argo=vmpt >/tmp/tri-rep-argo-core-stopped.log 2>&1; then exit 1; fi
        grep -q '已回復原配置' /tmp/tri-rep-argo-core-stopped.log
        ! systemctl is-active --quiet tri-proxy.service
        systemctl is-active --quiet tri-proxy-argo.service
        systemctl start tri-proxy.service
    fi
    if [[ $mode == 2 ]]; then
        [[ $(stat -c %a /etc/tri-proxy/tunnel.token) == 640 ]]
        grep -q -- '--token-file' /etc/systemd/system/tri-proxy-argo.service
        ! grep -q test-token /etc/systemd/system/tri-proxy-argo.service
        jq -e '.outbounds[3].server == "edge.example.com"' /etc/tri-proxy/client.json >/dev/null
        (
            export -f systemctl journalctl
            SERVER_ADDR=127.0.0.1 REALITY_PORT=35443 HY_PORT=35443 WS_PORT=35444 ARGO_MODE=0 \
                /usr/local/bin/tri-proxy <<< $'2\nUNINSTALL\n\n1\n\n0'
        ) >/tmp/tri-cli-reinstall.log 2>&1
        jq -e '.ARGO_MODE == "0" and .REALITY_PORT == "35443" and .WS_PORT == "35444"' /etc/tri-proxy/metadata.json >/dev/null
        [[ -L /usr/local/bin/tri-proxy && -L /usr/local/bin/agsbx ]]
    else
        jq -e '.outbounds[3].server == "current.trycloudflare.com"' /etc/tri-proxy/client.json >/dev/null
        compat_rep vlpt= hypt= vmpt= argo=vmpt agn=edge.example.com agk=test-token >/tmp/tri-rep-fixed.log 2>&1
        jq -e '.ARGO_MODE == "2" and .WS_PORT == "34444"' /etc/tri-proxy/metadata.json >/dev/null
        jq -e '.outbounds[3].server == "edge.example.com"' /etc/tri-proxy/client.json >/dev/null
        [[ $(stat -c %a /etc/tri-proxy/tunnel.token) == 640 ]]
        compat_rep vmpt= >/tmp/tri-rep-no-argo.log 2>&1
        jq -e '.ARGO_MODE == "0" and .WS_PORT == "34444" and .EGRESS_MODE == "prefer_ipv6"' /etc/tri-proxy/metadata.json >/dev/null
        [[ ! -f /etc/systemd/system/tri-proxy-argo.service && ! -e /etc/tri-proxy/tunnel.token && ! -e /opt/tri-proxy/cloudflared ]]
        jq -e '.inbounds[2].listen == "0.0.0.0" and .inbounds[2].tls.enabled' /etc/tri-proxy/config.json >/dev/null
        compat_rep REALITY_PORT=35443 vlpt=34567 EGRESS_MODE=ipv4_only >/tmp/tri-rep-custom-port.log 2>&1
        jq -e '.REALITY_PORT == "35443" and .HY_PORT == "34443" and .WS_PORT == "34444"' /etc/tri-proxy/metadata.json >/dev/null
        jq -e '.inbounds[0].listen_port == 35443 and .route.rules[0].ip_version == 6' /etc/tri-proxy/config.json >/dev/null
    fi
    main del <<< UNINSTALL >/tmp/tri-uninstall.log
done
if (
    unset EGRESS_MODE
    EGRESS_MODE=invalid SERVER_ADDR=127.0.0.1 main --defaults
) >/tmp/tri-egress-env-invalid.log 2>&1; then exit 1; fi
grep -q 'EGRESS_MODE 無效' /tmp/tri-egress-env-invalid.log
[[ ! -e /etc/tri-proxy ]]
(
    unset REALITY_PORT HY_PORT WS_PORT REALITY_SNI ARGO_MODE ARGO_HOST CF_TUNNEL_TOKEN UUID VMESS_UUID HY_PASSWORD
    SERVER_ADDR=127.0.0.1 REALITY_PORT=35443 HY_PORT=35443 WS_PORT=35444 EGRESS_MODE=prefer_ipv4 \
        main --custom <<< $'\n\n\n\n\n\n\n\n3\n'
) >/tmp/tri-egress-custom-install.log 2>&1
jq -e '.EGRESS_MODE == "prefer_ipv6"' /etc/tri-proxy/metadata.json >/dev/null
jq -e '.outbounds[0].domain_resolver.strategy == "prefer_ipv6"' /etc/tri-proxy/config.json >/dev/null
main del <<< UNINSTALL >/tmp/tri-uninstall.log
printf 'PASS：出口環境變數安裝／非法值拒絕、自訂安裝數字選擇、rep 沿用及明確覆寫。\n'
printf 'PASS：循環選單、指令別名、快捷命令、取消／備份解除安裝及帳戶保留重裝；兩種 Argo 的環境變數安裝；rep 的 Argo 回復及臨時→固定→關閉；快捷選單內解除後直接重裝。\n'
printf '未測試真實 systemd 管理器、Cloudflare Tunnel 帳戶、arm64 或公網防火牆。\n'
