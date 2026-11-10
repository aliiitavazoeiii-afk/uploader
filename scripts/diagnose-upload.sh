#!/usr/bin/env bash
# VideoDrop upload diagnosis — no application restarts, no user-file deletion.
set -u
umask 077
if [ ! -f /opt/video-share/.env ]; then
  echo "ERROR: /opt/video-share/.env not found."
  exit 1
fi
cd /opt/video-share || exit 1
if ! command -v docker >/dev/null || ! command -v curl >/dev/null; then
  echo "ERROR: Docker and curl are required."
  exit 1
fi
# Existing installer creates hex-only credentials; this is the local trusted env.
. ./.env
HOST="${PUBLIC_HOST:-185-190-53-142.sslip.io}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
echo "===== VIDEODROP UPLOAD DIAGNOSTICS ====="
echo "Target=$HOST  |  test-size=1 MiB"
echo "-- SERVICES --"
docker compose ps --format 'table {{.Service}}\t{{.Status}}\t{{.Ports}}' || true
echo "-- DISK --"
df -h /opt/video-share | tail -n 1
echo "-- APP DIRECT (inside container; bypass Caddy and Internet) --"
docker compose exec -T app node <<'NODE'
(async () => {
  const base = 'http://127.0.0.1:3000';
  let id = null;
  let cookie = '';
  const start = Date.now();
  const request = (url, opts) => fetch(base + url, {...opts, signal: AbortSignal.timeout(30000)});
  try {
    const login = await request('/api/login', {
      method: 'POST',
      headers: {'content-type':'application/json'},
      body: JSON.stringify({password:process.env.ADMIN_PASSWORD})
    });
    cookie = (login.headers.get('set-cookie') || '').split(';')[0];
    if (login.status !== 200) throw Error('login HTTP '+login.status);
    const init = await request('/api/uploads', {
      method:'POST', headers:{cookie,'content-type':'application/json'},
      body:JSON.stringify({name:'__videodrop_probe__.mp4',size:1048576})
    });
    const data = await init.json();
    if (init.status !== 201 || !data.id) throw Error('init HTTP '+init.status+' '+JSON.stringify(data));
    id = data.id;
    const upload = await request('/api/uploads/'+id+'/chunks/0', {
      method:'POST', headers:{cookie,'content-type':'application/octet-stream'},
      body:Buffer.alloc(1048576)
    });
    const body = await upload.text();
    if (upload.status !== 200) throw Error('chunk HTTP '+upload.status+' '+body);
    console.log('APP_DIRECT=PASS duration_ms='+ (Date.now()-start));
  } catch (e) {
    console.log('APP_DIRECT=FAIL reason='+e.message);
    process.exitCode = 1;
  } finally {
    if (id) try {
      await request('/api/uploads/'+id,{method:'DELETE',headers:{cookie}});
    } catch (e) { console.log('DIRECT_CLEANUP_WARNING='+e.message); }
  }
})();
NODE
echo "-- CADDY HTTPS LOCALLY (bypass client Internet) --"
printf '{"password":"%s"}' "$ADMIN_PASSWORD" > "$TMP/password.json"
head -c 1048576 /dev/zero > "$TMP/one_mb.mp4"
BASE="https://$HOST"
HTTP_OPTS=(--noproxy '*' --http1.1 --resolve "$HOST:443:127.0.0.1" --connect-timeout 8)
LOGIN_CODE=$(curl "${HTTP_OPTS[@]}" -sS --max-time 20 -c "$TMP/cookie" -o "$TMP/login-result" -w '%{http_code}' -H 'content-type: application/json' --data-binary @"$TMP/password.json" "$BASE/api/login" 2>"$TMP/login-error") || LOGIN_CODE="CURL_ERROR"
echo "PROXY_LOGIN_HTTP=$LOGIN_CODE"
if [ "$LOGIN_CODE" = 200 ]; then
  printf '{"name":"__videodrop_probe__.mp4","size":1048576}' > "$TMP/init.json"
  INIT_CODE=$(curl "${HTTP_OPTS[@]}" -sS --max-time 20 -b "$TMP/cookie" -o "$TMP/init-result" -w '%{http_code}' -H 'content-type: application/json' --data-binary @"$TMP/init.json" "$BASE/api/uploads" 2>"$TMP/init-error") || INIT_CODE="CURL_ERROR"
  echo "PROXY_INIT_HTTP=$INIT_CODE"
  ID=""
  if [ "$INIT_CODE" = 201 ]; then
    ID=$(sed -n 's/.*"id":"\([a-f0-9]\{48\}\)".*/\1/p' "$TMP/init-result" | head -n1)
  fi
  if [ -n "$ID" ]; then
    curl "${HTTP_OPTS[@]}" -sS --max-time 35 -b "$TMP/cookie" -o "$TMP/chunk-result" \
      -w 'PROXY_CHUNK_HTTP=%{http_code} duration_s=%{time_total} speed_Bps=%{speed_upload}\n' \
      -H 'content-type: application/octet-stream' --data-binary @"$TMP/one_mb.mp4" \
      "$BASE/api/uploads/$ID/chunks/0" || echo "PROXY_CHUNK_CURL_ERROR"
    curl "${HTTP_OPTS[@]}" -sS --max-time 12 -b "$TMP/cookie" -o /dev/null -X DELETE "$BASE/api/uploads/$ID" || echo "PROXY_CLEANUP_WARNING"
  else
    echo "PROXY_INIT_BODY=$(head -c 300 "$TMP/init-result" 2>/dev/null)"
  fi
else
  echo "PROXY_LOGIN_ERROR=$(head -c 200 "$TMP/login-error" 2>/dev/null)"
fi
echo "-- RECENT APP & WEB LOGS --"
docker compose logs --since=15m --tail=50 app web 2>&1 | tail -n 100
echo "===== END DIAGNOSTICS ====="
