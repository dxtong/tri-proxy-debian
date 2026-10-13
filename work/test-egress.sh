#!/usr/bin/env bash
# 由主驗收腳本載入，共用真實三協定客戶端及一次性容器。
[[ -f /.dockerenv && -n ${SB:-} ]] || exit 1

cp /etc/resolv.conf /tmp/tri-egress-resolv.conf
TRI_DNS_UPSTREAM=$(awk '/^nameserver / {print $2; exit}' /etc/resolv.conf) \
    node /src/work/egress-fixture.cjs \
    >/tmp/tri-egress-http.log 2>&1 9>&- &
EGRESS_HTTP_PID=$!
for attempt in {1..30}; do
    if curl -gfsS --noproxy '*' http://127.0.0.1:25447 >/dev/null 2>&1 \
       && curl -gfsS --noproxy '*' 'http://[::1]:25447' >/dev/null 2>&1; then break; fi
    sleep 0.1
done
printf 'nameserver 127.0.0.1\n' >/etc/resolv.conf
systemctl restart tri-proxy.service
sleep 1
egress_request() {
    curl -gfsS --max-time 4 --noproxy '' --proxy http://127.0.0.1:1080 "http://$1:${2:-25447}"
}
egress_identity() {
    jq -Sc .inbounds /etc/tri-proxy/config.json
    jq -Sc 'del(.EGRESS_MODE)' /etc/tri-proxy/metadata.json
    sha256sum /etc/tri-proxy/{tls.crt,tls.key,client.json,clash.yaml,links.txt}
}
identity=$(egress_identity)
for mode in auto prefer_ipv4 prefer_ipv6 ipv4_only ipv6_only; do
    main egress "$mode" >/tmp/tri-egress-switch.log
    "$SB" check -c /etc/tri-proxy/config.json
    [[ $identity == "$(egress_identity)" ]]
    jq -e --arg mode "$mode" '.EGRESS_MODE == $mode' /etc/tri-proxy/metadata.json >/dev/null
    for protocol in reality hysteria2 vmess; do
        jq --arg protocol "$protocol" '.outbounds[0].default = $protocol' \
            /etc/tri-proxy/client.json >/tmp/tri-client.json
        client_start
        if [[ $mode == ipv6_only ]]; then
            ! egress_request 127.0.0.1 >/dev/null 2>&1
            ! egress_request '[::ffff:127.0.0.1]' >/dev/null 2>&1
            ! egress_request tri-v4.test >/dev/null 2>&1
        else
            [[ $(egress_request 127.0.0.1) == egress-v4 ]]
            [[ $(egress_request '[::ffff:127.0.0.1]') == egress-v4 ]]
            [[ $(egress_request tri-v4.test) == egress-v4 ]]
        fi
        if [[ $mode == ipv4_only ]]; then
            ! egress_request '[::1]' >/dev/null 2>&1
            ! egress_request tri-v6.test >/dev/null 2>&1
        else
            [[ $(egress_request '[::1]') == egress-v6 ]]
            [[ $(egress_request tri-v6.test) == egress-v6 ]]
        fi
        case $mode in
            prefer_ipv4|ipv4_only) [[ $(egress_request tri-dual.test) == egress-v4 ]] ;;
            prefer_ipv6|ipv6_only) [[ $(egress_request tri-dual.test) == egress-v6 ]] ;;
            auto) [[ $(egress_request tri-dual.test) =~ ^egress-v[46]$ ]] ;;
        esac
        if [[ $mode == prefer_ipv4 || $mode == prefer_ipv6 ]]; then
            [[ $(egress_request tri-dual.test 25448) == egress-v4 ]]
            [[ $(egress_request tri-dual.test 25449) == egress-v6 ]]
        fi
    done
    printf 'PASS：%s 三協定的網域／字面 IP、雙棧選擇、嚴格限制及 TCP 回退。\n' "$mode"
done
main egress auto >/tmp/tri-egress-switch.log
before=$(sha256sum /etc/tri-proxy/{config.json,metadata.json})
pid_before=$(cat /tmp/tri-service.pid)
main egress auto >/tmp/tri-egress-noop.log
[[ $pid_before == "$(cat /tmp/tri-service.pid)" ]]
if main egress broken >/tmp/tri-egress-invalid.log 2>&1; then exit 1; fi
if main egress auto extra >/tmp/tri-egress-invalid.log 2>&1; then exit 1; fi
[[ $before == "$(sha256sum /etc/tri-proxy/{config.json,metadata.json})" ]]

cp /etc/tri-proxy/config.json /tmp/tri-egress-original.json
for field in dns route outbounds; do
    jq --arg field "$field" 'if $field == "dns" then .dns = {servers: []}
      elif $field == "route" then .route.rules = []
      else .outbounds += [{type: "block", tag: "custom"}] end' \
      /tmp/tri-egress-original.json >/etc/tri-proxy/config.json
    before=$(sha256sum /etc/tri-proxy/{config.json,metadata.json})
    if main egress prefer_ipv4 >/tmp/tri-egress-custom.log 2>&1; then exit 1; fi
    grep -q '拒絕覆寫' /tmp/tri-egress-custom.log
    [[ $before == "$(sha256sum /etc/tri-proxy/{config.json,metadata.json})" ]]
done
cp /tmp/tri-egress-original.json /etc/tri-proxy/config.json
before=$(sha256sum /etc/tri-proxy/{config.json,metadata.json})
if (
    egress_config() {
        command jq '.outbounds = [{type: "direct", tag: "direct"}] | .route = {final: "direct"}
          | if has("inbounds") then .outbounds[0].type = "missing-outbound" else . end'
    }
    main egress prefer_ipv4
) >/tmp/tri-egress-candidate.log 2>&1; then exit 1; fi
grep -q '候選出口配置不相容' /tmp/tri-egress-candidate.log
[[ $before == "$(sha256sum /etc/tri-proxy/{config.json,metadata.json})" ]]

touch /tmp/tri-fail-next-start
if main egress prefer_ipv4 >/tmp/tri-egress-failure.log 2>&1; then exit 1; fi
grep -q '已回復原配置及運行狀態' /tmp/tri-egress-failure.log
[[ $before == "$(sha256sum /etc/tri-proxy/{config.json,metadata.json})" ]]
systemctl is-active --quiet tri-proxy.service
systemctl is-enabled --quiet tri-proxy.service

# 在 config 已替換而 Metadata 尚未替換時故障，確保兩檔均回復。
touch /tmp/tri-egress-fail-mv
if (
    mv() {
        if [[ $* == *'/etc/tri-proxy/.metadata.new'* && -f /tmp/tri-egress-fail-mv ]]; then
            rm /tmp/tri-egress-fail-mv; return 42
        fi
        command mv "$@"
    }
    main egress prefer_ipv6
) >/tmp/tri-egress-partial.log 2>&1; then exit 1; fi
grep -q '已回復原配置及運行狀態' /tmp/tri-egress-partial.log
[[ $before == "$(sha256sum /etc/tri-proxy/{config.json,metadata.json})" ]]
systemctl is-active --quiet tri-proxy.service

systemctl disable tri-proxy.service
systemctl stop tri-proxy.service
main --egress ipv6_only >/tmp/tri-egress-stopped.log
! systemctl is-active --quiet tri-proxy.service
! systemctl is-enabled --quiet tri-proxy.service
main --egress auto >/tmp/tri-egress-stopped.log
! systemctl is-active --quiet tri-proxy.service
systemctl enable tri-proxy.service
systemctl start tri-proxy.service
sleep 1

# 舊 Metadata 缺欄位仍按 auto 管理。
jq 'del(.EGRESS_MODE)' /etc/tri-proxy/metadata.json >/tmp/tri-egress-old.json
install -m 600 /tmp/tri-egress-old.json /etc/tri-proxy/metadata.json
main status >/tmp/tri-egress-status.log
grep -q '代理出口：自動（auto）' /tmp/tri-egress-status.log
(
    export -f systemctl journalctl
    /usr/local/bin/agsbx egress prefer_ipv6
) >/tmp/tri-egress-cli.log
main <<< $'8\n7\n4\n\n0' >/tmp/tri-egress-menu.log
jq -e '.EGRESS_MODE == "ipv4_only"' /etc/tri-proxy/metadata.json >/dev/null
main egress auto >/tmp/tri-egress-switch.log
[[ $identity == "$(egress_identity)" ]]
[[ $(stat -c %a /etc/tri-proxy/config.json) == 640 && $(stat -c %G /etc/tri-proxy/config.json) == tri-proxy ]]
[[ $(stat -c %a /etc/tri-proxy/metadata.json) == 600 && $(stat -c %a "$EGRESS_BACKUPS") == 700 ]]
for backup in "$EGRESS_BACKUPS"/*; do
    [[ $(stat -c %a "$backup") == 700 ]]
    for file in "$backup"/*; do [[ $(stat -c %a "$file") == 600 ]]; done
    (cd "$backup"; sha256sum --check --status SHA256SUMS)
done
cp /tmp/tri-egress-resolv.conf /etc/resolv.conf
kill "$EGRESS_HTTP_PID"
wait "$EGRESS_HTTP_PID" || true
EGRESS_HTTP_PID=
systemctl restart tri-proxy.service
sleep 1
SERVER_PID=$(cat /tmp/tri-service.pid)
printf 'PASS：出口 CLI／互動選單／舊 Metadata、身份及匯出保留、候選拒絕、私密備份、兩種故障回復及停止／開機狀態保留。\n'
