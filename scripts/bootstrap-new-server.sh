#!/usr/bin/env bash
# One-command bootstrap for a fresh Ubuntu/Debian VPS.
# Installs prerequisites only when needed. Does not delete application data.
set -Eeuo pipefail

if [ "$(id -u)" -ne 0 ]; then echo "Run as root (sudo bash)." >&2; exit 1; fi
if [ ! -r /etc/os-release ]; then echo "Unsupported OS (missing /etc/os-release)." >&2; exit 1; fi
. /etc/os-release
case "${ID:-}" in
  ubuntu|debian) ;;
  *) echo "This installer supports Ubuntu and Debian only. Detected: ${ID:-unknown}" >&2; exit 1;;
esac

VIDEODROP_IP="${VIDEODROP_IP:-45.142.189.66}"
if ! [[ "$VIDEODROP_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then echo "Bad IP: $VIDEODROP_IP" >&2; exit 1; fi
export VIDEODROP_IP

# Never take over occupied HTTP/HTTPS ports.
if command -v ss >/dev/null 2>&1; then
  for port in 80 443; do
    if ss -H -ltn "sport = :$port" | grep -q .; then
      echo "TCP port $port already in use; refusing automatic installation." >&2
      echo "Existing services have not been stopped." >&2
      exit 1
    fi
  done
fi

export DEBIAN_FRONTEND=noninteractive
echo "=== Installing base tools (Ubuntu/Debian) ==="
apt-get update
apt-get install -y ca-certificates curl openssl iproute2

if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
  echo "=== Installing Docker Engine and Compose ==="
  curl --retry 3 --connect-timeout 15 -fsSL https://get.docker.com -o /root/get-docker-videodrop.sh
  sh /root/get-docker-videodrop.sh
fi

systemctl enable --now docker
docker info >/dev/null
docker compose version

# Check ports a second time after installing prerequisites.
if command -v ss >/dev/null 2>&1; then
  for port in 80 443; do
    if ss -H -ltn "sport = :$port" | grep -q .; then
      echo "TCP port $port already in use. Refusing to replace any service." >&2
      exit 1
    fi
  done
fi

echo "=== Installing VideoDrop from GitHub ==="
curl --retry 3 --connect-timeout 15 -fsSL \
  https://raw.githubusercontent.com/aliiitavazoeiii-afk/uploader/main/install.sh \
  -o /root/video-share-install.sh
bash /root/video-share-install.sh

echo "=== Docker containers ==="
cd /opt/video-share
docker compose ps

echo "=== Application health ==="
docker compose exec -T app node -e \
  "fetch('http://127.0.0.1:3000/healthz', {signal: AbortSignal.timeout(10000)}).then(r=>{console.log('APP_HEALTH_HTTP='+r.status);process.exit(r.ok?0:1)}).catch(e=>{console.error(e.message);process.exit(1)})"

echo "=== Local HTTPS health ==="
HOST="${VIDEODROP_HOST:-${VIDEODROP_IP//./-}.sslip.io}"
ready=0
for i in $(seq 1 12); do
  if curl --noproxy '*' -k -fsS --connect-timeout 4 --max-time 8 \
      --resolve "$HOST:443:127.0.0.1" \
      "https://$HOST/healthz" | grep -q '"ok":true'; then
    ready=1
    break
  fi
  sleep 2
done
if [ "$ready" -eq 1 ]; then
  echo "LOCAL_HTTPS=PASS"
else
  echo "LOCAL_HTTPS=NOT_READY; check docker compose logs --tail=80 web"
fi

echo "=== Public HTTPS certificate check ==="
if curl --noproxy '*' -fsS --connect-timeout 5 --max-time 12 \
     --resolve "$HOST:443:127.0.0.1" "https://$HOST/healthz" | grep -q '"ok":true'; then
  echo "HTTPS_CERT=VALID"
else
  echo "HTTPS_CERT=NOT_READY; TCP 80/443 accessibility and certificate issuance should be checked."
fi

echo "SITE=https://$HOST"
echo "Keep your first-install admin password safe. It is also saved in /opt/video-share/.env"
echo "Existing completed videos, if any, remain in /opt/video-share/data/videos"
