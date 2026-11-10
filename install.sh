#!/usr/bin/env bash
set -Eeuo pipefail
if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root: sudo bash install.sh"
  exit 1
fi
if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required."
  exit 1
fi
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
BASE="https://raw.githubusercontent.com/aliiitavazoeiii-afk/uploader/main"
for file in server.js index.html Dockerfile Caddyfile compose.yaml; do
  curl --retry 3 --connect-timeout 15 -fsSL "$BASE/$file" -o "$TMP/$file"
done
curl --retry 3 --connect-timeout 15 -fsSL "$BASE/scripts/install-from-source.sh" -o "$TMP/install.sh"
bash "$TMP/install.sh"
