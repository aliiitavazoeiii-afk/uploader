#!/usr/bin/env bash
set -Eeuo pipefail
if [ "$(id -u)" -ne 0 ]; then echo 'Please run as root: sudo bash install.sh'; exit 1; fi
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST=/opt/video-share
SITE_IP="${VIDEODROP_IP:-45.142.189.66}"
if ! [[ "$SITE_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  echo "Invalid VIDEODROP_IP format: $SITE_IP" >&2
  exit 1
fi
HOST="${VIDEODROP_HOST:-${SITE_IP//./-}.sslip.io}"
if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
  echo 'Docker Engine and Docker Compose plugin are required.'
  echo 'For Ubuntu/Debian, use the official Docker installation instructions:'
  echo 'https://docs.docker.com/engine/install/'
  echo 'No services have been modified.'
  exit 1
fi
if ! docker info >/dev/null 2>&1; then echo 'Docker service is not running. Start Docker first.'; exit 1; fi
if [ "$SRC" != "$DEST" ]; then
  mkdir -p "$DEST"
  if [ -f "$DEST/server.js" ]; then
    CODE_BACKUP="$DEST/code-backups/$(date +%Y%m%d-%H%M%S)-$"
    mkdir -p "$CODE_BACKUP"
    for file in server.js index.html Dockerfile Caddyfile compose.yaml; do
      if [ -f "$DEST/$file" ]; then cp -p "$DEST/$file" "$CODE_BACKUP/$file"; fi
    done
    echo "Previous application code backed up to $CODE_BACKUP"
  fi
  cp "$SRC/server.js" "$SRC/index.html" "$SRC/Dockerfile" "$SRC/Caddyfile" "$SRC/compose.yaml" "$DEST/"
fi
cd "$DEST"
mkdir -p data/videos caddy_data caddy_config
chown -R 1000:1000 data
chmod 750 data data/videos
if [ ! -f .env ]; then
  if ! command -v openssl >/dev/null 2>&1; then echo 'OpenSSL is needed to generate credentials.'; exit 1; fi
  PASSWORD="$(openssl rand -hex 16)"
  SECRET="$(openssl rand -hex 48)"
  cat >.env <<VARS
PUBLIC_HOST=$HOST
ADMIN_PASSWORD=$PASSWORD
SESSION_SECRET=$SECRET
VARS
  chmod 600 .env
  echo '--------------------------------------------'
  echo "YOUR NEW ADMIN PASSWORD: $PASSWORD"
  echo 'Save the password privately. It is also in /opt/video-share/.env'
  echo '--------------------------------------------'
else
  echo 'Existing .env preserved. Password was NOT changed.'
  CURRENT_HOST="$(sed -n 's/^PUBLIC_HOST=//p' .env | head -n 1)"
  if [ -n "$CURRENT_HOST" ] && [ "$CURRENT_HOST" != "$HOST" ]; then
    echo "WARNING: Existing PUBLIC_HOST=$CURRENT_HOST does not match intended new host $HOST" >&2
    echo 'The existing .env was preserved. Check host before proceeding.' >&2
    exit 1
  fi
fi
if command -v getent >/dev/null 2>&1; then
  RESOLVED="$(getent ahostsv4 "$HOST" | awk 'NR==1{print $1}' || true)"
  if [ -n "$RESOLVED" ] && [ "$RESOLVED" != "$SITE_IP" ]; then
    echo "Warning: DNS resolves $HOST to $RESOLVED, not the server IP." >&2
  fi
fi
if ! docker compose ps --quiet 2>/dev/null | grep -q .; then
  if command -v ss >/dev/null 2>&1; then
    for PORT in 80 443; do
      if ss -H -ltn "sport = :$PORT" | grep -q .; then
        echo "PORT $PORT IS IN USE. No existing service has been stopped or changed." >&2
        echo 'You must free ports 80/443, or attach the app to your existing reverse proxy.' >&2
        exit 1
      fi
    done
  fi
fi
echo 'Validating Caddy configuration before deployment...'
if ! docker compose run --rm --no-deps -T web caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile; then
  echo 'Invalid Caddy configuration. Existing running containers were not restarted.' >&2
  echo 'Application code backup can be found in /opt/video-share/code-backups.' >&2
  exit 1
fi
echo 'Building and starting VideoDrop (only the video-share stack)...'
docker compose up -d --build
printf '\nSITE: https://%s\n' "$HOST"
echo 'Opening HTTPS requires incoming TCP ports 80 and 443 to be reachable.'
echo 'If UFW is enabled, allow them: ufw allow 80/tcp && ufw allow 443/tcp'
echo 'Logs: cd /opt/video-share && docker compose logs -f --tail=40'
echo 'Stored video files: /opt/video-share/data/videos'
echo 'Delete videos from the website to reclaim storage.'
df -h "$DEST"
