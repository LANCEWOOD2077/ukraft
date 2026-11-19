#!/bin/sh
# 容器启动时用环境变量生成 xray 配置，再启动 xray；有 TUNNEL_TOKEN 时同时拉起 cloudflared。
#
# 必填：UUID
# 可选：
#   WS_PATH / XHTTP_PATH      入站路径
#   INBOUND_MODE              ws | xhttp | both（默认 both）
#                               ws    只有 VLESS+WS，监听 WS_PORT
#                               xhttp 只有 VLESS+XHTTP，监听 WS_PORT（CF 路由不用改）
#                               both  WS=WS_PORT + XHTTP=XHTTP_PORT（兼容老的直连 workflow）
#   WS_PORT                   主端口，CF 隧道 Service URL 必须指向它（默认 8080）
#   XHTTP_PORT                仅 both 时用到，XHTTP 端口（默认 8081）
#   XHTTP_MODE                服务端 xhttp 模式：auto（默认）| packet-up | stream-up
#   TUNNEL_TOKEN              Cloudflare Tunnel token；不填就只跑直连
#   CF_PROTOCOL               cloudflared -> CF 边缘：http2（默认）| quic | auto
#   ARGO_DOMAIN               WS 的隧道域名，用来打印链接
#   ARGO_XHTTP_DOMAIN         XHTTP 的隧道域名；不填就用 ARGO_DOMAIN
#   PREFERRED                 逗号分隔的优选域名/IP，会为每个生成 H2/H3 链接
#   DOMAIN                    直连域名（老的直连部署才需要）
#   SUB_PORT                  >0 时在该端口用 busybox httpd 提供订阅文件（默认不启用）
#   SUB_DOMAIN                订阅用的域名，只用于在日志里打印订阅地址
#   SUB_TOKEN                 订阅路径里的密钥串；不填就用 UUID 派生
#
# 平台在外层终结 TLS 再以明文 HTTP 转进来，所以所有入站都不开 TLS、不放证书。
set -eu

UUID="${UUID:?必须设置 UUID 环境变量}"
WS_PATH="${WS_PATH:-/ws}"
XHTTP_PATH="${XHTTP_PATH:-/xhttp}"
WS_PORT="${WS_PORT:-8080}"
XHTTP_PORT="${XHTTP_PORT:-8081}"
INBOUND_MODE="${INBOUND_MODE:-both}"
XHTTP_MODE="${XHTTP_MODE:-auto}"
CF_PROTOCOL="${CF_PROTOCOL:-http2}"
DOMAIN="${DOMAIN:-}"
ARGO_DOMAIN="${ARGO_DOMAIN:-}"
ARGO_XHTTP_DOMAIN_EXPLICIT="${ARGO_XHTTP_DOMAIN:-}"
ARGO_XHTTP_DOMAIN="${ARGO_XHTTP_DOMAIN:-}"
PREFERRED="${PREFERRED:-}"
SUB_PORT="${SUB_PORT:-}"
SUB_DOMAIN="${SUB_DOMAIN:-}"
SUB_TOKEN="${SUB_TOKEN:-}"

case "$INBOUND_MODE" in
  ws|xhttp|both) ;;
  *) echo "[entrypoint] INBOUND_MODE 只能是 ws / xhttp / both，收到：$INBOUND_MODE"; exit 1 ;;
esac

# 端口分配：xhttp 单选时复用 WS_PORT，这样 CF 那条 route 一个字都不用改
case "$INBOUND_MODE" in
  ws)    WS_ON="$WS_PORT";     XHTTP_ON="" ;;
  xhttp) WS_ON="";             XHTTP_ON="$WS_PORT" ;;
  both)  WS_ON="$WS_PORT";     XHTTP_ON="$XHTTP_PORT" ;;
esac

[ -n "$ARGO_XHTTP_DOMAIN" ] || ARGO_XHTTP_DOMAIN="$ARGO_DOMAIN"

mkdir -p /etc/xray

# 入站 JSON。相比最早那版：
#   1) 去掉 sniffing：没有分流规则时它纯属额外解析，白吃 CPU。
#   2) freedom 加 sockopt keepalive：经 CF / 网关的长连接不容易被中间设备静默掐掉。
INBOUNDS=""
if [ -n "$WS_ON" ]; then
  INBOUNDS="{
      \"port\": ${WS_ON},
      \"listen\": \"0.0.0.0\",
      \"protocol\": \"vless\",
      \"settings\": {
        \"clients\": [ { \"id\": \"${UUID}\" } ],
        \"decryption\": \"none\"
      },
      \"streamSettings\": {
        \"network\": \"ws\",
        \"wsSettings\": { \"path\": \"${WS_PATH}\" }
      }
    }"
fi

if [ -n "$XHTTP_ON" ]; then
  if [ -n "$INBOUNDS" ]; then INBOUNDS="${INBOUNDS},"; fi
  INBOUNDS="${INBOUNDS}
    {
      \"port\": ${XHTTP_ON},
      \"listen\": \"0.0.0.0\",
      \"protocol\": \"vless\",
      \"settings\": {
        \"clients\": [ { \"id\": \"${UUID}\" } ],
        \"decryption\": \"none\"
      },
      \"streamSettings\": {
        \"network\": \"xhttp\",
        \"xhttpSettings\": {
          \"path\": \"${XHTTP_PATH}\",
          \"mode\": \"${XHTTP_MODE}\"
        }
      }
    }"
fi

cat > /etc/xray/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    ${INBOUNDS}
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {},
      "streamSettings": {
        "sockopt": {
          "tcpNoDelay": true,
          "tcpKeepAliveIdle": 30,
          "tcpKeepAliveInterval": 15
        }
      }
    }
  ]
}
EOF

echo "[entrypoint] inbound=${INBOUND_MODE} ws=${WS_ON:-off}${WS_PATH} xhttp=${XHTTP_ON:-off}${XHTTP_PATH} (server mode=${XHTTP_MODE})"

# ---- 可选：Cloudflare Tunnel（Argo）----
CF_PID=""
if [ -n "${TUNNEL_TOKEN:-}" ]; then
  echo "[entrypoint] cloudflared 启动：protocol=${CF_PROTOCOL}（回源地址由 CF route 决定）"
  cloudflared tunnel --no-autoupdate --protocol "$CF_PROTOCOL" --loglevel info \
    run --token "$TUNNEL_TOKEN" &
  CF_PID=$!
else
  echo "[entrypoint] 未设置 TUNNEL_TOKEN，仅直连模式"
fi

# ---- 收集 + 打印链接（订阅文件也用同一份）----
_ws="${WS_PATH#/}"
_xp="${XHTTP_PATH#/}"
LINKS=""

# 记录一条链接：打印到日志，同时攒起来给订阅用
add_link() {
  echo "[entrypoint] $1"
  if [ -n "$LINKS" ]; then
    LINKS="${LINKS}
$1"
  else
    LINKS="$1"
  fi
}

# xhttp 链接：地址、alpn、tag
xp_link() {
  add_link "$(printf 'vless://%s@%s:443?encryption=none&security=tls&sni=%s&alpn=%s&fp=chrome&type=xhttp&mode=auto&host=%s&path=%%2F%s#%s' \
    "$UUID" "$1" "$ARGO_XHTTP_DOMAIN" "$2" "$ARGO_XHTTP_DOMAIN" "$_xp" "$3")"
}

if [ -n "$DOMAIN" ]; then
  if [ -n "$WS_ON" ]; then
    add_link "vless://${UUID}@${DOMAIN}:443?encryption=none&security=tls&sni=${DOMAIN}&fp=chrome&type=ws&host=${DOMAIN}&path=%2F${_ws}#Unikraft-WS-Direct"
  fi
  if [ -n "$XHTTP_ON" ]; then
    add_link "vless://${UUID}@${DOMAIN}:8443?encryption=none&security=tls&sni=${DOMAIN}&fp=chrome&type=xhttp&host=${DOMAIN}&path=%2F${_xp}&mode=packet-up#Unikraft-XHTTP-Direct"
  fi
fi

if [ -n "$ARGO_DOMAIN" ] && [ -n "$WS_ON" ]; then
  add_link "vless://${UUID}@${ARGO_DOMAIN}:443?encryption=none&security=tls&sni=${ARGO_DOMAIN}&fp=chrome&type=ws&host=${ARGO_DOMAIN}&path=%2F${_ws}#Unikraft-Argo-WS"
fi

if [ -n "$ARGO_XHTTP_DOMAIN" ] && [ -n "$XHTTP_ON" ] \
   && { [ "$INBOUND_MODE" = "xhttp" ] || [ -n "$ARGO_XHTTP_DOMAIN_EXPLICIT" ]; }; then
  xp_link "$ARGO_XHTTP_DOMAIN" h2 "Argo-XHTTP-H2"
  xp_link "$ARGO_XHTTP_DOMAIN" h3 "Argo-XHTTP-H3"
  for p in $(echo "$PREFERRED" | tr ',' ' '); do
    [ -n "$p" ] || continue
    t2=$(printf 'Argo-H2 %s' "$p" | sed 's/ /%20/g')
    t3=$(printf 'Argo-H3 %s' "$p" | sed 's/ /%20/g')
    xp_link "$p" h2 "$t2"
    xp_link "$p" h3 "$t3"
  done
fi

# ---- 可选：订阅文件（v2rayN 直接填一个 URL）----
# 只在设置了 SUB_PORT 时启用，且必须由 CF 隧道单独路由过来，否则外部不可达。
HTTPD_PID=""
if [ -n "$SUB_PORT" ] && [ -n "$LINKS" ]; then
  if [ -z "$SUB_TOKEN" ]; then
    SUB_TOKEN=$(echo "$UUID" | tr -d '-' | cut -c1-20)
  fi
  mkdir -p /www
  # v2rayN 认 base64（换行分隔的链接列表），不加换行的 base64 最稳
  printf '%s\n' "$LINKS" | base64 | tr -d '\r\n' > "/www/${SUB_TOKEN}"
  chmod 644 "/www/${SUB_TOKEN}"
  busybox httpd -f -p "$SUB_PORT" -h /www 2>/dev/null &
  HTTPD_PID=$!
  sleep 1
  if kill -0 "$HTTPD_PID" 2>/dev/null; then
    echo "[entrypoint] 订阅已启用：http://127.0.0.1:${SUB_PORT}/${SUB_TOKEN}（共 $(printf '%s\n' "$LINKS" | wc -l) 条）"
    if [ -n "$SUB_DOMAIN" ]; then
      echo "[entrypoint] 订阅地址： https://${SUB_DOMAIN}/${SUB_TOKEN}"
    fi
    if [ -n "$TUNNEL_TOKEN" ]; then
      echo "[entrypoint] 记得在 CF 隧道里加一条路由：${SUB_DOMAIN:-<订阅域名>} -> http://localhost:${SUB_PORT}"
    fi
  else
    echo "[entrypoint] 警告：busybox httpd 没起来，订阅不可用（不影响代理）"
    HTTPD_PID=""
  fi
fi

xray run -c /etc/xray/config.json &
XRAY_PID=$!

trap 'kill "$XRAY_PID" ${CF_PID:-} ${HTTPD_PID:-} 2>/dev/null; exit 0' TERM INT QUIT

# 任一进程挂了就整机退出，交给 --restart always 拉起，避免"半死"状态
while kill -0 "$XRAY_PID" 2>/dev/null; do
  if [ -n "$CF_PID" ] && ! kill -0 "$CF_PID" 2>/dev/null; then
    echo "[entrypoint] cloudflared 已退出，容器重启"
    kill "$XRAY_PID" 2>/dev/null || true
    exit 1
  fi
  sleep 5
done

echo "[entrypoint] xray 已退出，容器重启"
kill ${CF_PID:-} ${HTTPD_PID:-} 2>/dev/null || true
exit 1
