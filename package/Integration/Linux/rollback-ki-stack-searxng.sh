#!/usr/bin/env bash
set -Eeuo pipefail
MARKER=/opt/ki-stack/integration/installation.json
if [ ! -f "$MARKER" ]; then exit 0; fi
MODE="$(python3 -c 'import json; print(json.load(open("/opt/ki-stack/integration/installation.json"))["mode"])')"
if [ "$MODE" = managed ]; then
  systemctl disable --now ki-stack-searxng.service 2>/dev/null || true
  rm -f /etc/systemd/system/ki-stack-searxng.service
  rm -f /etc/uwsgi/apps-available/ki-stack-searxng.ini
  rm -f /etc/nginx/sites-enabled/ki-stack-searxng.conf /etc/nginx/sites-available/ki-stack-searxng.conf
  systemctl daemon-reload
  nginx -t >/dev/null 2>&1 && systemctl restart nginx || true
elif [ "$MODE" = adopted-backend ]; then
  rm -f /etc/nginx/sites-enabled/ki-stack-searxng.conf /etc/nginx/sites-available/ki-stack-searxng.conf
  nginx -t >/dev/null 2>&1 && systemctl restart nginx || true
fi
rm -f "$MARKER"
