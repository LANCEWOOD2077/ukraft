# Unikraft Cloud 用 xray VLESS 节点镜像：WS 主用 + XHTTP 备用 + 可选 Cloudflare Tunnel(Argo)
#
# 平台在外层终结 TLS，xray 只在容器内监听明文端口：
#   443:8080/http+tls -> VLESS+WS（主用）
#   8443:8081/tls     -> VLESS+XHTTP（备用，TCP 直通，边缘不做 HTTP 解析）
#
# v3 新增：镜像里带 cloudflared。
#   - 设了 TUNNEL_TOKEN 时，entrypoint 会启动 cloudflared 连 Cloudflare 边缘，
#     回源 http://127.0.0.1:8080（就是 xray 的 WS 入站），从而实现 Argo 固定域名。
#   - 不设 TUNNEL_TOKEN 时行为和老版本完全一样，只用直连。
#   - Argo 只需要出站 TCP，所以实例可以一个 -p 都不加（无公网入口）。
ARG XRAY_VERSION=v26.11.9
# 想钉死 cloudflared 版本就把这里换成 .../releases/download/2026.11.0/cloudflared-linux-amd64
ARG CLOUDFLARED_URL=https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64

FROM alpine:latest AS fetch
ARG XRAY_VERSION
ARG CLOUDFLARED_URL
RUN apk add --no-cache curl unzip ca-certificates \
 && curl -fsSL -o /tmp/xray.zip \
      "https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-linux-64.zip" \
 && unzip -q /tmp/xray.zip -d /tmp/xray \
 && install -m 0755 /tmp/xray/xray /usr/local/bin/xray \
 && /usr/local/bin/xray version \
 && curl -fsSL -o /usr/local/bin/cloudflared "${CLOUDFLARED_URL}" \
 && chmod 0755 /usr/local/bin/cloudflared \
 && /usr/local/bin/cloudflared --version

FROM alpine:latest
# darkhttpd：约 50KB 的静态文件服务器，用来提供 v2rayN 订阅文件（/www/<token>）。
# busybox 的 httpd applet 在 Unikraft 的 base-compat 运行时里不可用，所以显式装一个。
RUN apk add --no-cache ca-certificates \
 && (apk add --no-cache darkhttpd || echo "警告：darkhttpd 装不上，订阅功能会不可用（代理不受影响）")
COPY --from=fetch /usr/local/bin/xray /usr/local/bin/xray
COPY --from=fetch /usr/local/bin/cloudflared /usr/local/bin/cloudflared
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
# EXPOSE 在 Unikraft Cloud 上会被忽略（以 -p 发布端口为准），写在这里只作文档。
EXPOSE 8080 8081
ENTRYPOINT ["/entrypoint.sh"]
