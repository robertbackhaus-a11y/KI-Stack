#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

RELEASE="${KI_RELEASE:-1.5.5}"
REPOSITORY="${KI_SEARXNG_REPOSITORY:-https://github.com/searxng/searxng.git}"
REF="${KI_SEARXNG_REF:-277d8469c}"
BASE_URL="${KI_SEARXNG_BASE_URL:-http://localhost/searxng/}"
BACKEND_PORT="${KI_SEARXNG_BACKEND_PORT:-8888}"
ROOT="/opt/ki-stack/searxng"
INTEGRATION_ROOT="/opt/ki-stack/integration"
MARKER="${INTEGRATION_ROOT}/installation.json"
BACKUP_ROOT="${INTEGRATION_ROOT}/backups"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_DIR="${BACKUP_ROOT}/${STAMP}"

log(){ printf '[KI-Stack Integration] %s\n' "$*"; }
json_healthy(){
  local url="$1"
  curl --connect-timeout 5 --max-time 20 --fail --silent --show-error "$url" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert isinstance(d,dict); assert "results" in d' >/dev/null 2>&1
}
write_marker(){
  local mode="$1" backend="$2" changed="$3"
  install -d -m 0750 "${INTEGRATION_ROOT}"
  python3 - "$MARKER" "$RELEASE" "$mode" "$backend" "$changed" "$REF" <<'PYMARK'
import json,sys,datetime
path,release,mode,backend,changed,ref=sys.argv[1:]
data={
 "schemaVersion":"1.0","managedBy":"KI-STACK-INTEGRATION-MANAGED",
 "release":release,"installedAt":datetime.datetime.now(datetime.timezone.utc).isoformat(),
 "mode":mode,"backend":backend,"linuxChanged":changed.lower()=="true","searxngRef":ref
}
with open(path,"w",encoding="utf-8") as f: json.dump(data,f,indent=2)
PYMARK
  chmod 0640 "$MARKER"
}

# systemd is required for reliable WSL service control
if [ "$(ps -p 1 -o comm= | tr -d '[:space:]')" != "systemd" ]; then
  install -d /etc
  [ -f /etc/wsl.conf ] && cp -a /etc/wsl.conf "/etc/wsl.conf.ki-stack-${STAMP}.bak"
  if [ ! -f /etc/wsl.conf ]; then
    printf '[boot]\nsystemd=true\n' > /etc/wsl.conf
  elif grep -Eq '^[[:space:]]*systemd[[:space:]]*=' /etc/wsl.conf; then
    sed -Ei 's/^[[:space:]]*systemd[[:space:]]*=.*/systemd=true/' /etc/wsl.conf
  elif grep -Eq '^\[boot\][[:space:]]*$' /etc/wsl.conf; then
    sed -i '/^\[boot\][[:space:]]*$/a systemd=true' /etc/wsl.conf
  else
    printf '\n[boot]\nsystemd=true\n' >> /etc/wsl.conf
  fi
  log 'systemd wurde in /etc/wsl.conf aktiviert; WSL-Neustart erforderlich.'
  exit 42
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends \
  ca-certificates curl git python3 python3-venv python3-pip python3-dev \
  build-essential libxml2-dev libxslt1-dev zlib1g-dev libffi-dev libssl-dev \
  nginx uwsgi uwsgi-plugin-python3
if apt-cache show valkey-server >/dev/null 2>&1; then
  apt-get install -y --no-install-recommends valkey-server
  VALKEY_SERVICE=valkey-server
else
  log 'valkey-server ist in den aktiven Debian-Quellen nicht verfügbar.'
  exit 51
fi

# Fully healthy existing endpoint: adopt without replacing Linux configuration.
if json_healthy 'http://127.0.0.1/searxng/search?q=ki-stack&format=json'; then
  write_marker 'adopted-existing' 'http://127.0.0.1/searxng' 'false'
  log 'Vorhandener SearXNG-JSON-Endpunkt wurde übernommen.'
  exit 0
fi

install -d -m 0750 "$BACKUP_DIR"
for path in \
  /etc/nginx/sites-available/ki-stack-searxng.conf \
  /etc/nginx/sites-enabled/ki-stack-searxng.conf \
  /etc/uwsgi/apps-available/ki-stack-searxng.ini \
  /etc/systemd/system/ki-stack-searxng.service \
  /etc/searxng/ki-stack-settings.yml; do
  if [ -e "$path" ] || [ -L "$path" ]; then
    cp -a --parents "$path" "$BACKUP_DIR" 2>/dev/null || true
  fi
done

# Existing direct backend: keep it, add only the local nginx path.
DIRECT_BACKEND=false
if json_healthy "http://127.0.0.1:${BACKEND_PORT}/search?q=ki-stack&format=json"; then
  DIRECT_BACKEND=true
fi

install -d /etc/nginx/sites-available /etc/nginx/sites-enabled
cat > /etc/nginx/sites-available/ki-stack-searxng.conf <<EOFNGINX
server {
    listen 80;
    listen [::]:80;
    server_name localhost 127.0.0.1;
    access_log off;
    location = /searxng { return 301 /searxng/; }
    location /searxng {
        proxy_pass http://127.0.0.1:${BACKEND_PORT};
        proxy_set_header Host \$host;
        proxy_set_header Connection \$http_connection;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Script-Name /searxng;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOFNGINX
ln -sfn /etc/nginx/sites-available/ki-stack-searxng.conf /etc/nginx/sites-enabled/ki-stack-searxng.conf

if [ "$DIRECT_BACKEND" = false ]; then
  if ss -ltn "sport = :${BACKEND_PORT}" | grep -q LISTEN; then
    log "Port ${BACKEND_PORT} ist belegt, aber liefert keinen SearXNG-JSON-Endpunkt."
    exit 52
  fi
  if ! id -u searxng >/dev/null 2>&1; then
    useradd --system --home-dir "$ROOT" --create-home --shell /usr/sbin/nologin searxng
  fi
  install -d -o searxng -g searxng "$ROOT" "$ROOT/src" "$ROOT/venv"
  if [ -d "$ROOT/src/.git" ]; then
    if [ -n "$(git -C "$ROOT/src" status --porcelain)" ]; then
      log 'Vorhandenes verwaltetes SearXNG-Repository enthält lokale Änderungen.'
      exit 53
    fi
    git -C "$ROOT/src" fetch --depth 1 origin "$REF"
    git -C "$ROOT/src" checkout --detach FETCH_HEAD
  else
    rm -rf "$ROOT/src"
    git clone --filter=blob:none --no-checkout "$REPOSITORY" "$ROOT/src"
    git -C "$ROOT/src" fetch --depth 1 origin "$REF"
    git -C "$ROOT/src" checkout --detach FETCH_HEAD
  fi
  ACTUAL_REF="$(git -C "$ROOT/src" rev-parse HEAD)"
  case "$ACTUAL_REF" in "$REF"*) ;; *) log "SearXNG-Commit stimmt nicht: $ACTUAL_REF"; exit 54;; esac
  python3 -m venv "$ROOT/venv"
  "$ROOT/venv/bin/python" -m pip install --upgrade pip setuptools wheel
  "$ROOT/venv/bin/python" -m pip install -r "$ROOT/src/requirements.txt" -r "$ROOT/src/requirements-server.txt"
  install -d /etc/searxng /etc/uwsgi/apps-available
  SECRET="$($ROOT/venv/bin/python -c 'import secrets; print(secrets.token_urlsafe(48))')"
  cat > /etc/searxng/ki-stack-settings.yml <<EOFSETTINGS
use_default_settings: true

general:
  debug: false
  instance_name: "KI-Stack SearXNG"

search:
  safe_search: 0
  autocomplete: ""
  default_lang: "all"
  formats:
    - html
    - json

server:
  bind_address: "127.0.0.1"
  port: ${BACKEND_PORT}
  secret_key: "${SECRET}"
  limiter: true
  image_proxy: true
  base_url: "${BASE_URL}"

valkey:
  url: valkey://localhost:6379/0
EOFSETTINGS
  chmod 0640 /etc/searxng/ki-stack-settings.yml
  chown root:searxng /etc/searxng/ki-stack-settings.yml
  cat > /etc/uwsgi/apps-available/ki-stack-searxng.ini <<EOFUWSGI
[uwsgi]
plugin = python3
chdir = ${ROOT}/src/searx
module = webapp
callable = app
virtualenv = ${ROOT}/venv
env = SEARXNG_SETTINGS_PATH=/etc/searxng/ki-stack-settings.yml
env = LANG=C.UTF-8
env = LC_ALL=C.UTF-8
http-socket = 127.0.0.1:${BACKEND_PORT}
master = true
processes = 2
threads = 4
enable-threads = true
single-interpreter = true
lazy-apps = true
vacuum = true
die-on-term = true
disable-logging = true
EOFUWSGI
  cat > /etc/systemd/system/ki-stack-searxng.service <<EOFSERVICE
[Unit]
Description=KI-Stack SearXNG
After=network-online.target ${VALKEY_SERVICE}.service
Wants=network-online.target
Requires=${VALKEY_SERVICE}.service

[Service]
Type=simple
User=searxng
Group=searxng
WorkingDirectory=${ROOT}/src
ExecStart=/usr/bin/uwsgi --ini /etc/uwsgi/apps-available/ki-stack-searxng.ini
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ReadWritePaths=${ROOT} /var/cache /run

[Install]
WantedBy=multi-user.target
EOFSERVICE
  chown -R searxng:searxng "$ROOT"
  systemctl daemon-reload
  systemctl enable --now "$VALKEY_SERVICE"
  systemctl enable --now ki-stack-searxng.service
fi

nginx -t
systemctl enable --now nginx
systemctl restart nginx

for attempt in $(seq 1 30); do
  if json_healthy 'http://127.0.0.1/searxng/search?q=ki-stack&format=json'; then
    if [ "$DIRECT_BACKEND" = true ]; then
      write_marker 'adopted-backend' "http://127.0.0.1:${BACKEND_PORT}" 'true'
    else
      write_marker 'managed' "http://127.0.0.1:${BACKEND_PORT}" 'true'
    fi
    log 'SearXNG-HTML- und JSON-Endpunkt sind betriebsbereit.'
    exit 0
  fi
  sleep 1
done
systemctl --no-pager --full status ki-stack-searxng.service nginx "$VALKEY_SERVICE" || true
exit 55
