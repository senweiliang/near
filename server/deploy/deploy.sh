#!/usr/bin/env bash
# 交叉编译 Linux 版协调服务器并部署到目标主机（systemd）。
# 用法：server/deploy/deploy.sh root@101.200.167.45
# 首次部署会在服务器上生成自签证书（10 年），并打印客户端要固定的证书 SHA-256。
set -euo pipefail
HOST="${1:?usage: deploy.sh user@host}"
# 额外 ssh 参数，如复用已有连接：SSH_OPTS="-o ControlPath=/tmp/cm.sock"
SSH_OPTS="${SSH_OPTS:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT

(cd "$HERE/.." && dart pub get >/dev/null && \
  dart compile exe bin/near_signal.dart --target-os linux --target-arch x64 -o "$BUILD/near_signal")

ssh $SSH_OPTS "$HOST" 'mkdir -p /opt/near-signal'
scp $SSH_OPTS "$BUILD/near_signal" "$HOST:/opt/near-signal/near_signal.new"
scp $SSH_OPTS "$HERE/near-signal.service" "$HOST:/etc/systemd/system/near-signal.service"

ssh $SSH_OPTS "$HOST" 'bash -s' <<'REMOTE'
set -euo pipefail
cd /opt/near-signal
mv near_signal.new near_signal
chmod 755 near_signal
if [ ! -f cert.pem ]; then
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -days 3650 -subj /CN=near-signal -keyout key.pem -out cert.pem 2>/dev/null
fi
id near-signal >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin near-signal
chown root:near-signal cert.pem key.pem
chmod 644 cert.pem
chmod 640 key.pem
if command -v ufw >/dev/null && ufw status | grep -q active; then
  ufw allow 7443/tcp >/dev/null; ufw allow 3478/udp >/dev/null
fi
if command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
  firewall-cmd --permanent --add-port=7443/tcp --add-port=3478/udp >/dev/null
  firewall-cmd --reload >/dev/null
fi
systemctl daemon-reload
systemctl enable near-signal >/dev/null 2>&1
systemctl restart near-signal
sleep 1
systemctl --no-pager --lines=5 status near-signal || true
echo "cert sha256 (pin this in lib/signaling.dart):"
openssl x509 -in cert.pem -outform der | sha256sum | cut -d' ' -f1
REMOTE
