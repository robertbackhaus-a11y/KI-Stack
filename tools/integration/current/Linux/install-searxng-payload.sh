#!/usr/bin/env bash
set -Eeuo pipefail
PAYLOAD="$1"; MANIFEST="$2"; EXPECTED_SHA="$3"; RELEASE="1.5.9"
ROOT=/opt/ki-stack/searxng; SRC="$ROOT/src"; VENV="$ROOT/venv"; MARKER=/opt/ki-stack/integration/installation.json
healthy(){ curl --connect-timeout 5 --max-time 20 --fail --silent "$1" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d.get("results")' >/dev/null 2>&1; }
write_marker(){ install -d -m 0750 /opt/ki-stack/integration; python3 - "$MARKER" "$1" <<'PY'
import datetime,json,sys
json.dump({"schemaVersion":"1.0","managedBy":"KI-STACK-INTEGRATION-MANAGED","version":"1.5.9","release":"KI-Stack-Integration-Execute-v1.5.9","mode":sys.argv[2],"installedAt":datetime.datetime.now(datetime.timezone.utc).isoformat(),"payloadId":"KI-STACK-SEARXNG-SOURCE-2026.6.28"},open(sys.argv[1],"w"),indent=2)
PY
chmod 0640 "$MARKER"; }
if healthy 'http://127.0.0.1/searxng/search?q=ki-stack&format=json'; then write_marker adopted-existing; exit 0; fi
test "$(sha256sum "$PAYLOAD" | cut -d' ' -f1)" = "$EXPECTED_SHA" || { echo 'payload SHA256 mismatch' >&2; exit 61; }
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends ca-certificates curl python3 python3-venv python3-pip python3-dev build-essential libxml2-dev libxslt1-dev zlib1g-dev libffi-dev libssl-dev nginx uwsgi uwsgi-plugin-python3 unzip valkey-server
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
unzip -q "$PAYLOAD" -d "$TMP/src"
python3 - "$TMP/src" "$MANIFEST" <<'PY'
import hashlib,json,os,sys
root,manifest=sys.argv[1:]; data=json.load(open(manifest,encoding="utf-8")); actual=[]
for item in data["files"]:
 p=os.path.join(root,*item["path"].split("/"));
 if not os.path.isfile(p) or os.path.getsize(p)!=item["sizeBytes"] or hashlib.sha256(open(p,"rb").read()).hexdigest()!=item["sha256"]: actual.append(item["path"])
if actual: raise SystemExit("content mismatch: "+", ".join(actual[:10]))
PY
id -u searxng >/dev/null 2>&1 || useradd --system --home-dir "$ROOT" --create-home --shell /usr/sbin/nologin searxng
install -d -o searxng -g searxng "$ROOT"; rm -rf "$SRC"; mv "$TMP/src" "$SRC"; chown -R searxng:searxng "$SRC"
python3 -m venv "$VENV"; "$VENV/bin/python" -m pip install --upgrade pip setuptools wheel; "$VENV/bin/python" -m pip install -r "$SRC/requirements.txt" -r "$SRC/requirements-server.txt"
install -d /etc/searxng /etc/uwsgi/apps-available /etc/uwsgi/apps-enabled /etc/nginx/default.d
SECRET="$($VENV/bin/python -c 'import secrets;print(secrets.token_urlsafe(48))')"
cat > /etc/searxng/settings.yml <<EOF
use_default_settings: true
search: {formats: [html, json]}
server: {bind_address: "127.0.0.1", port: 8888, secret_key: "$SECRET", base_url: "http://localhost/searxng/"}
valkey: {url: "valkey://localhost:6379/0"}
EOF
cat > /etc/uwsgi/apps-available/searxng.ini <<EOF
[uwsgi]
plugin=python3
chdir=$SRC/searx
module=webapp
callable=app
virtualenv=$VENV
env=SEARXNG_SETTINGS_PATH=/etc/searxng/settings.yml
http-socket=127.0.0.1:8888
master=true
processes=2
threads=4
enable-threads=true
vacuum=true
die-on-term=true
EOF
ln -sfn /etc/uwsgi/apps-available/searxng.ini /etc/uwsgi/apps-enabled/searxng.ini
cat > /etc/nginx/default.d/searxng.conf <<'EOF'
location = /searxng { return 301 /searxng/; }
location /searxng { proxy_pass http://127.0.0.1:8888; proxy_set_header X-Script-Name /searxng; proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for; }
EOF
systemctl enable valkey-server uwsgi nginx; systemctl restart valkey-server uwsgi nginx
for n in $(seq 1 60); do healthy 'http://127.0.0.1/searxng/search?q=ki-stack&format=json' && { write_marker managed; exit 0; }; sleep 1; done
exit 62
