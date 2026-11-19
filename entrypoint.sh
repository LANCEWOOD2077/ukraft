#!/bin/sh
# 容器启动时用环境变量生成 xray 配置，再启动 xray；有 TUNNEL_TOKEN 时同时拉起 cloudflared。
#
# 必填：UUID
# 可选：WS_PATH / XHTTP_PATH / DOMAIN / ARGO_DOMAIN
#       TUNNEL_TOKEN   Cloudflare Tunnel 的 token；不填就只跑直连，行为和 v2 完全一样
#       CF_PROTOCOL    cloudflared 到 Cloudflare 边缘的协议：http2（默认，稳）| quic | auto
#
# 端口：${WS_PORT:-8080} = VLESS+WS（主用，Argo 也回源到这里），8081 = VLESS+XHTTP（备用）。
# 平台在外层终结 TLS 再以明文 HTTP 转进来，所以两个入站都不开 TLS、不放证书。
set -eu

UUID="${UUID:?必须设置 UUID 环境变量}"
WS_PATH="${WS_PATH:-/ws}"
XHTTP_PATH="${XHTTP_PATH:-/xhttp}"
# 本地 WS 端口。CF 隧道里那条 Public hostname 的 Service URL 必须指向它
# （例如 Service URL = http://localhost:39201 就设 WS_PORT=39201）。
WS_PORT="${WS_PORT:-8080}"
CF_PROTOCOL="${CF_PROTOCOL:-http2}"

mkdir -p /etc/xray
# 相比 v2 只改了两处：
#   1) 去掉 sniffing：没有分流规则时它纯属额外解析，白吃 CPU；这里全部走 freedom，不需要。
#   2) freedom 加 sockopt keepalive：经 CF / 网关的长连接不容易被中间设备静默掐掉。
cat > /etc/xray/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "port": ${WS_PORT},
      "listen": "0.0.0.0",
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "${UUID}" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "${WS_PATH}" }
      }
    },
    {
      "port": 8081,
      "listen": "0.0.0.0",
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "${UUID}" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "xhttpSettings": { "path": "${XHTTP_PATH}", "mode": "auto" }
      }
    }
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

echo "[entrypoint] xray: ${WS_PORT} ws ${WS_PATH} / 8081 xhttp ${XHTTP_PATH}"

# ---- 可选：Cloudflare Tunnel（Argo）----
CF_PID=""
if [ -n "${TUNNEL_TOKEN:-}" ]; then
  echo "[entrypoint] cloudflared 启动：protocol=${CF_PROTOCOL} -> http://127.0.0.1:${WS_PORT}"
  cloudflared tunnel --no-autoupdate --protocol "$CF_PROTOCOL" --loglevel info \
    run --token "$TUNNEL_TOKEN" &
  CF_PID=$!
else
  echo "[entrypoint] 未设置 TUNNEL_TOKEN，仅直连模式"
fi

# 日志里打印链接，方便在控制台 Logs 页直接复制
if [ -n "${DOMAIN:-}" ]; then
  _ws="${WS_PATH#/}"
  _xhttp="${XHTTP_PATH#/}"
  echo "[entrypoint] vless://${UUID}@${DOMAIN}:443?encryption=none&security=tls&sni=${DOMAIN}&fp=chrome&type=ws&host=${DOMAIN}&path=%2F${_ws}#Unikraft-WS-Direct"
  echo "[entrypoint] vless://${UUID}@${DOMAIN}:8443?encryption=none&security=tls&sni=${DOMAIN}&fp=chrome&type=xhttp&host=${DOMAIN}&path=%2F${_xhttp}&mode=packet-up#Unikraft-XHTTP-Direct"
fi
if [ -n "${ARGO_DOMAIN:-}" ]; then
  _ws="${WS_PATH#/}"
  echo "[entrypoint] vless://${UUID}@${ARGO_DOMAIN}:443?encryption=none&security=tls&sni=${ARGO_DOMAIN}&fp=chrome&type=ws&host=${ARGO_DOMAIN}&path=%2F${_ws}#Unikraft-Argo-WS"
fi

xray run -c /etc/xray/config.json &
XRAY_PID=$!

trap 'kill "$XRAY_PID" ${CF_PID:-} 2>/dev/null; exit 0' TERM INT QUIT

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
kill "$CF_PID" 2>/dev/null || true
exit 1
