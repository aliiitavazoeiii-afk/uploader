#!/usr/bin/env bash
# Install VideoDrop alongside the existing Darmawear store without restarting its containers.
set -Eeuo pipefail
umask 077
[ "$(id -u)" = 0 ] || { echo "Run as root." >&2; exit 1; }
for cmd in docker curl openssl ss; do command -v "$cmd" >/dev/null || { echo "MISSING_TOOL=$cmd" >&2; exit 1; }; done
docker info >/dev/null
CADDY='darmawear-store-caddy'
NAME='videodrop-uploader'
DEST='/opt/videodrop-sidecar'
DOMAIN='45-142-189-66.sslip.io'
BEGIN_MARK='# BEGIN VIDEODROP-SIDECAR MANAGED'
END_MARK='# END VIDEODROP-SIDECAR MANAGED'

echo '=== READ-ONLY PREFLIGHT ==='
if [ "$(docker inspect -f '{{.State.Running}}' "$CADDY" 2>/dev/null || true)" != true ]; then
  echo 'STOP: darmawear-store-caddy not running; no changes made.' >&2
  exit 1
fi
if docker inspect "$NAME" >/dev/null 2>&1; then
  echo "STOP: $NAME already exists. Refusing overwrite." >&2
  exit 1
fi
if ss -H -ltn 'sport = :8789' | grep -q .; then
  echo 'STOP: 8789 is occupied; no changes made.' >&2
  exit 1
fi

# Only modify Caddyfile if it is backed by a persistent host bind mount.
FILE_MOUNT="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/etc/caddy/Caddyfile"}}{{if eq .Type "bind"}}{{.Source}}{{end}}{{end}}{{end}}' "$CADDY")"
DIR_MOUNT="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/etc/caddy"}}{{if eq .Type "bind"}}{{.Source}}{{end}}{{end}}{{end}}' "$CADDY")"
if [ -n "$FILE_MOUNT" ]; then
  CADDYFILE="$FILE_MOUNT"
elif [ -n "$DIR_MOUNT" ]; then
  CADDYFILE="$DIR_MOUNT/Caddyfile"
else
  echo 'STOP: No persistent Caddyfile bind mount. Nothing changed.' >&2
  docker inspect "$CADDY" -f '{{range .Mounts}}{{println .Type .Source "->" .Destination}}{{end}}'
  exit 1
fi
[ -f "$CADDYFILE" ] && [ -w "$CADDYFILE" ] || { echo "STOP: Caddyfile not writable: $CADDYFILE" >&2; exit 1; }
if grep -Fq "$BEGIN_MARK" "$CADDYFILE" || grep -Fq "$DOMAIN" "$CADDYFILE"; then
  echo 'STOP: Existing VideoDrop domain or managed block already present. No changes.' >&2
  exit 1
fi
NETWORK="$(docker inspect -f '{{range $name,$v := .NetworkSettings.Networks}}{{println $name}}{{end}}' "$CADDY" | grep -vE '^(bridge|host|none)?$' | head -n1)"
[ -n "$NETWORK" ] && docker network inspect "$NETWORK" >/dev/null || { echo 'STOP: No suitable Docker network.' >&2; exit 1; }
echo "STORE_NETWORK=$NETWORK"
echo "STORE_CADDYFILE=$CADDYFILE"
echo 'Store containers will NOT be stopped or recreated.'

if command -v getent >/dev/null; then
  RESOLVED="$(getent ahostsv4 "$DOMAIN" | awk 'NR==1{print $1}' || true)"
  if [ -n "$RESOLVED" ] && [ "$RESOLVED" != '45.142.189.66' ]; then
    echo "STOP: DNS mismatch: $RESOLVED" >&2; exit 1
  fi
fi
if [ -e "$DEST/.env" ]; then
  echo "STOP: Existing $DEST/.env. Won't replace credentials." >&2; exit 1
fi
echo '=== INSTALL UPLOADER APP IN SEPARATE CONTAINER ==='
mkdir -p "$DEST/data/videos"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
BASE='https://raw.githubusercontent.com/aliiitavazoeiii-afk/uploader/main'
for f in server.js index.html Dockerfile; do
  curl --retry 3 --connect-timeout 15 -fsSL "$BASE/$f" -o "$TMP/$f"
done
cp "$TMP/server.js" "$TMP/index.html" "$TMP/Dockerfile" "$DEST/"
chown -R 1000:1000 "$DEST/data"
chmod 750 "$DEST/data" "$DEST/data/videos"
PASSWORD="$(openssl rand -hex 16)"
SECRET="$(openssl rand -hex 48)"
cat > "$DEST/.env" <<EOF
ADMIN_PASSWORD=$PASSWORD
SESSION_SECRET=$SECRET
PUBLIC_BASE_URL=https://$DOMAIN
MIN_FREE_BYTES=5368709120
EOF
chmod 600 "$DEST/.env"
docker build -t videodrop-sidecar:1 "$DEST"
docker run -d --name "$NAME" --restart unless-stopped \
  --network "$NETWORK" --network-alias "$NAME" \
  -p 127.0.0.1:8789:3000 \
  --env-file "$DEST/.env" \
  --read-only --tmpfs /tmp:rw,nosuid,nodev,noexec \
  --security-opt no-new-privileges:true \
  -v "$DEST/data:/app/data" videodrop-sidecar:1 >/dev/null

APP_OK=0
for i in $(seq 1 20); do
  if curl --noproxy '*' -fsS --connect-timeout 2 --max-time 3 http://127.0.0.1:8789/healthz 2>/dev/null | grep -q '"ok":true'; then
    APP_OK=1; break
  fi
  sleep 1
done
if [ "$APP_OK" != 1 ]; then
  echo 'STOP: VideoDrop health failed. Store Caddyfile was NOT changed.' >&2
  docker logs "$NAME" --tail 40 || true
  exit 1
fi
echo 'APP_HEALTH=PASS'
echo '=== BACKUP STORE CADDY CONFIG & VALIDATE PROPOSED ROUTE ==='
BACKUP="$CADDYFILE.videodrop-backup-$(date -u +%Y%m%dT%H%M%SZ)"
cp -p "$CADDYFILE" "$BACKUP"
# Append to same inode; replacing a bind-mounted host file would not be visible inside the container.
cat >> "$CADDYFILE" <<EOF

$BEGIN_MARK
$DOMAIN {
    reverse_proxy $NAME:3000
}
$END_MARK
EOF
if ! docker exec "$CADDY" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile; then
  cat "$BACKUP" > "$CADDYFILE"
  echo "STOP: Invalid Caddy config; restored $BACKUP; store NOT reloaded." >&2
  exit 1
fi
if ! docker exec "$CADDY" caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile; then
  cat "$BACKUP" > "$CADDYFILE"
  docker exec "$CADDY" caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile || true
  echo "STOP: Caddy reload failed; reverted Caddyfile from $BACKUP." >&2
  exit 1
fi
echo 'STORE_CADDY_RELOAD=PASS'
echo '=== CHECK LOCAL PUBLIC ROUTE ==='
ROUTE_OK=0
for i in $(seq 1 12); do
  if curl --noproxy '*' -k -fsS --resolve "$DOMAIN:443:127.0.0.1" \
       --connect-timeout 3 --max-time 5 "https://$DOMAIN/healthz" 2>/dev/null | grep -q '"ok":true'; then
    ROUTE_OK=1; break
  fi
  sleep 2
done
if [ "$ROUTE_OK" = 1 ]; then echo 'HTTPS_LOCAL_ROUTE=PASS'; else echo 'HTTPS_LOCAL_ROUTE=NOT_READY'; fi
if curl --noproxy '*' -fsS --resolve "$DOMAIN:443:127.0.0.1" \
    --connect-timeout 3 --max-time 10 "https://$DOMAIN/healthz" 2>/dev/null | grep -q '"ok":true'; then
  echo 'TLS_CERTIFICATE=VALID'
else
  echo 'TLS_CERTIFICATE=NOT_READY'
fi
echo 'STORE_CONTAINERS=NOT_RESTARTED'
echo "CADDY_BACKUP=$BACKUP"
echo "SITE=https://$DOMAIN"
echo "ADMIN_PASSWORD=$PASSWORD"
echo "PASSWORD_FILE=$DEST/.env"
df -h "$DEST"
